# Title:        LCA Model Fitting and Stability Assessment (poLCA)
# Purpose:      Functions for running latent class analysis with multiple
#               random starts using poLCA, assessing convergence stability,
#               and recommending optimal class counts
# Date created: 2026-04-14
# Dependencies: adldata, poLCA, furrr, future, progressr, purrr, dplyr,
#               cli, tibble, vctrs, tidyr

# ==============================================================================
# Setup
# ==============================================================================

library(poLCA) # LCA engine with true random starts
library(furrr) # Parallel purrr using future backend
library(future) # Parallel backend
library(progressr) # Progress bars for parallel workers
library(purrr) # Typed map helpers
library(dplyr) # Data wrangling
library(cli) # User facing messages and warnings
library(tibble) # Tibble construction for label lookups


# Parallel configuration

# Use all cores minus one so the machine stays responsive.
plan(
  multisession,
  workers = max(1, parallel::detectCores() - 1)
)


# ==============================================================================
# Helper Functions
# ==============================================================================

# Build a poLCA formula (cbind(y1, y2, ...) ~ 1) from a data frame.
make_lca_formula <- function(data) {
  vars <- names(data)
  as.formula(
    paste0("cbind(", paste(vars, collapse = ", "), ") ~ 1")
  )
}


# Coerce indicator variables to integer codes starting at 1.
#
# poLCA requires that manifest variables be integers with no zeros and no gaps.
# This helper converts factors and characters, and shifts zero-based codings
# up by one so they meet that requirement.
#
# Args:
#   data: Data frame of indicator variables
#
# Returns:
#   Data frame with every column coerced to integer in [1, K].
prepare_lca_data <- function(data) {
  out <- data

  for (v in names(out)) {
    x <- out[[v]]

    if (is.factor(x)) {
      x <- as.integer(x)
    } else if (is.character(x)) {
      x <- as.integer(as.factor(x))
    } else if (!is.integer(x)) {
      x <- as.integer(x)
    }

    min_val <- suppressWarnings(min(x, na.rm = TRUE))

    if (is.finite(min_val) && min_val < 1L) {
      x <- x - min_val + 1L
      cli::cli_alert_info(
        paste0(
          "Shifted variable '",
          v,
          "' so codes start at 1 (was ",
          min_val,
          ")."
        )
      )
    }

    out[[v]] <- x
  }

  out
}


# Compute relative, normalized entropy for a fitted LCA.
#
# Args:
#   model: A fitted poLCA model
#
# Returns:
#   Numeric scalar in [0, 1], where 1 means perfect class separation.
rel_entropy <- function(model) {
  if (is.null(model) || is.null(model$posterior)) {
    return(NA_real_)
  }

  post <- as.matrix(model$posterior)
  n_class <- ncol(post)

  if (n_class < 2 || nrow(post) == 0) {
    return(NA_real_)
  }

  # Offset prevents log(0).
  num <- -sum(post * log(post + 1e-10), na.rm = TRUE)
  deno <- nrow(post) * log(n_class)

  1 - (num / deno)
}


# Extract class conditional response probabilities from a fitted poLCA model.
#
# poLCA already stores $probs as a named list of matrices where rows are
# classes and columns are response categories, so no reshaping is needed.
#
# Args:
#   model: A fitted poLCA model
#
# Returns:
#   Named list of numeric matrices, one per indicator.
#   Row i is class i, column j is P(category j | class i).
extract_class_probs_poLCA <- function(model) {
  if (is.null(model) || is.null(model$probs)) {
    stop("Model has no probs component.")
  }

  lapply(model$probs, function(mat) {
    out <- as.matrix(mat)
    dimnames(out) <- NULL
    out
  })
}


# Generate all permutations of a vector (Heap's algorithm).
permn <- function(x, fun = NULL, ...) {
  if (is.numeric(x) && length(x) == 1 && x > 0 && trunc(x) == x) {
    x <- seq(x)
  }

  n <- length(x)
  nofun <- is.null(fun)

  out <- vector("list", gamma(n + 1))

  p <- ip <- seqn <- 1:n
  d <- rep(-1L, n)
  d[1] <- 0L

  m <- n + 1L
  p <- c(m, p, m)
  i <- 1L
  use <- -c(1L, n + 2L)

  while (m != 1L) {
    out[[i]] <- if (nofun) {
      x[p[use]]
    } else {
      fun(x[p[use]], ...)
    }
    i <- i + 1L

    m <- n
    chk <- (p[ip + d + 1L] > seqn)
    m <- max(seqn[!chk])

    if (m < n) {
      d[(m + 1L):n] <- -d[(m + 1L):n]
    }

    index1 <- ip[m] + 1L
    index2 <- p[index1] <- p[index1 + d[m]]
    p[index1 + d[m]] <- m

    tmp <- ip[index2]
    ip[index2] <- ip[m]
    ip[m] <- tmp
  }

  out
}


# Find the best class label alignment between two runs.
find_best_class_match <- function(probs1, probs2) {
  first_var <- names(probs1)[1]
  n1 <- nrow(probs1[[first_var]])
  n2 <- nrow(probs2[[first_var]])

  if (n1 != n2) {
    return(list(
      permutation = NULL,
      distance = Inf,
      error = paste("Different classes:", n1, "vs", n2)
    ))
  }

  if (!identical(sort(names(probs1)), sort(names(probs2)))) {
    return(list(
      permutation = NULL,
      distance = Inf,
      error = "Variable names do not match"
    ))
  }

  for (vn in names(probs1)) {
    if (!identical(dim(probs1[[vn]]), dim(probs2[[vn]]))) {
      return(list(
        permutation = NULL,
        distance = Inf,
        error = paste("Dimension mismatch:", vn)
      ))
    }
  }

  tryCatch(
    {
      perms <- permn(1:n1)
      best_match <- NULL
      min_dist <- Inf

      for (perm in perms) {
        d <- sum(map_dbl(
          names(probs1),
          \(vn) {
            sum(
              (probs1[[vn]] - probs2[[vn]][perm, , drop = FALSE])^2,
              na.rm = TRUE
            )
          }
        ))

        if (d < min_dist) {
          min_dist <- d
          best_match <- perm
        }
      }

      list(
        permutation = best_match,
        distance = min_dist,
        error = NULL
      )
    },
    error = function(e) {
      list(
        permutation = NULL,
        distance = Inf,
        error = paste("Permutation error:", e$message)
      )
    }
  )
}


# ==============================================================================
# poLCA Convergence Helpers
# ==============================================================================

# A poLCA fit is considered converged if the EM loop stopped before hitting
# maxiter and produced a finite log likelihood.
optimizer_converged <- function(model) {
  if (is.null(model)) {
    return(FALSE)
  }
  if (is.null(model$numiter) || is.null(model$maxiter)) {
    return(FALSE)
  }
  if (is.null(model$llik) || !is.finite(model$llik)) {
    return(FALSE)
  }
  isTRUE(model$numiter < model$maxiter)
}


# Crude numeric status code to mirror the tidySEM version:
#   0 = converged, 1 = not converged, NA = no model.
model_status_code <- function(model) {
  if (is.null(model)) {
    return(NA_integer_)
  }
  if (optimizer_converged(model)) 0L else 1L
}


model_ll <- function(model) {
  if (is.null(model) || is.null(model$llik)) {
    return(NA_real_)
  }
  as.numeric(model$llik)
}


model_aic <- function(model) {
  if (is.null(model) || is.null(model$aic)) {
    return(NA_real_)
  }
  as.numeric(model$aic)
}


model_bic <- function(model) {
  if (is.null(model) || is.null(model$bic)) {
    return(NA_real_)
  }
  as.numeric(model$bic)
}


# Estimated smallest class proportion.
model_prob_min <- function(model) {
  if (is.null(model) || is.null(model$P)) {
    return(NA_real_)
  }
  min(model$P, na.rm = TRUE)
}


# Smallest class size using modal posterior assignment.
model_n_min <- function(model) {
  if (is.null(model) || is.null(model$predclass) || is.null(model$P)) {
    return(NA_real_)
  }
  n_class <- length(model$P)
  min(tabulate(model$predclass, nbins = n_class))
}


# Safe summaries.
safe_min <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) {
    return(NA_real_)
  }
  min(x)
}

safe_max <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) {
    return(NA_real_)
  }
  max(x)
}

safe_mean <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) {
    return(NA_real_)
  }
  mean(x)
}

safe_sd <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) < 2) {
    return(NA_real_)
  }
  sd(x)
}

safe_range_diff <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) < 2) {
    return(NA_real_)
  }
  diff(range(x))
}


# ==============================================================================
# Per Run Model Fitting
# ==============================================================================

# Fit one random start across the full class range using poLCA.
#
# Args:
#   data: Integer coded data frame (output of prepare_lca_data)
#   formula: LCA formula, e.g. cbind(y1, y2, y3) ~ 1
#   min_classes: Smallest number of classes to fit
#   max_classes: Largest number of classes to fit
#   run: Integer run number, used to set the seed
#   base_seed: Base seed so run i uses base_seed + i
#   maxiter: Maximum EM iterations per fit
#   tol: Convergence tolerance for poLCA
#   nrep_per_call: Internal random starts per poLCA call. Default 1 so the
#     external run index fully controls variation across runs.
#   verbose: If TRUE, print run level warnings
#
# Returns:
#   A list with run number, list of fitted models, vector of class counts,
#   and a list of one-row fit data frames.
fit_one_poLCA_run <- function(
  data,
  formula,
  min_classes,
  max_classes,
  run,
  base_seed = 42,
  maxiter = 3000,
  tol = 1e-10,
  nrep_per_call = 1,
  verbose = FALSE
) {
  requested_classes <- min_classes:max_classes

  models <- vector("list", length(requested_classes))
  names(models) <- as.character(requested_classes)

  for (i in seq_along(requested_classes)) {
    k <- requested_classes[i]

    # Re-seed per (run, k) so each cell is reproducible and the runs actually
    # differ from each other.
    set.seed(base_seed + run * 1000L + k)

    model <- tryCatch(
      suppressWarnings(
        poLCA::poLCA(
          formula = formula,
          data = data,
          nclass = k,
          nrep = nrep_per_call,
          maxiter = maxiter,
          tol = tol,
          verbose = FALSE,
          calc.se = FALSE,
          graphs = FALSE,
          na.rm = TRUE
        )
      ),
      error = function(e) {
        if (verbose) {
          message(
            "Run ",
            run,
            " class ",
            k,
            " failed: ",
            conditionMessage(e)
          )
        }
        NULL
      }
    )

    models[[i]] <- model
  }

  # Build one-row fit data frames per class count.
  fit_rows <- purrr::map2(
    seq_along(models),
    requested_classes,
    function(i, k) {
      mod <- models[[i]]

      if (is.null(mod)) {
        return(data.frame(
          run = run,
          classes = k,
          status_code = NA_integer_,
          optimizer_converged = FALSE,
          LL = NA_real_,
          AIC = NA_real_,
          BIC = NA_real_,
          Entropy = NA_real_,
          n_min = NA_real_,
          prob_min = NA_real_
        ))
      }

      conv <- optimizer_converged(mod)

      ent_val <- if (conv) {
        tryCatch(rel_entropy(mod), error = function(e) NA_real_)
      } else {
        NA_real_
      }

      data.frame(
        run = run,
        classes = k,
        status_code = if (conv) 0L else 1L,
        optimizer_converged = conv,
        LL = model_ll(mod),
        AIC = model_aic(mod),
        BIC = model_bic(mod),
        Entropy = ent_val,
        n_min = model_n_min(mod),
        prob_min = model_prob_min(mod)
      )
    }
  )

  list(
    run = run,
    models = models,
    class_ids = requested_classes,
    fit_rows = fit_rows
  )
}


# ==============================================================================
# Stability Assessment
# ==============================================================================

# Compare the runs that reached the best log likelihood and check whether
# their class conditional probabilities agree after class labels are aligned.
assess_best_run_agreement <- function(
  best_models,
  param_threshold = 0.05
) {
  if (length(best_models) < 2) {
    return(list(
      param_stable = NA,
      param_max_diff = NA_real_,
      param_mean_diff = NA_real_,
      details = "Only one best log likelihood run"
    ))
  }

  ref_probs <- tryCatch(
    extract_class_probs_poLCA(best_models[[1]]),
    error = function(e) NULL
  )

  if (is.null(ref_probs)) {
    return(list(
      param_stable = NA,
      param_max_diff = NA_real_,
      param_mean_diff = NA_real_,
      details = "Could not extract probabilities from reference run"
    ))
  }

  max_diff <- 0
  all_diffs <- numeric(0)
  errors <- character(0)

  for (i in 2:length(best_models)) {
    cur_probs <- tryCatch(
      extract_class_probs_poLCA(best_models[[i]]),
      error = function(e) NULL
    )

    if (is.null(cur_probs)) {
      errors <- c(
        errors,
        paste("Comparison", i, "probability extraction failed")
      )
      next
    }

    mr <- find_best_class_match(ref_probs, cur_probs)

    if (is.null(mr$permutation)) {
      errors <- c(errors, paste("Comparison", i, mr$error))
      next
    }

    perm <- mr$permutation

    for (vn in names(ref_probs)) {
      diffs <- abs(
        ref_probs[[vn]] -
          cur_probs[[vn]][perm, , drop = FALSE]
      )
      all_diffs <- c(all_diffs, as.vector(diffs))
      max_diff <- max(max_diff, diffs, na.rm = TRUE)
    }
  }

  if (length(all_diffs) == 0) {
    return(list(
      param_stable = FALSE,
      param_max_diff = Inf,
      param_mean_diff = Inf,
      details = paste(errors, collapse = "; ")
    ))
  }

  list(
    param_stable = max_diff < param_threshold,
    param_max_diff = max_diff,
    param_mean_diff = mean(all_diffs, na.rm = TRUE),
    details = if (length(errors) > 0) paste(errors, collapse = "; ") else ""
  )
}


# Strict stability check for one class count.
#
# loglik_tol is looser than in the OpenMx version because poLCA reports the
# log likelihood in floating point and equality checks at 1e-6 can be too
# strict. 1e-4 is a good default for survey-scale data.
check_model_stability <- function(
  fit_results,
  class_num,
  lca_models_for_class,
  model_run_indices,
  loglik_tol = 1e-4,
  param_threshold = 0.05,
  min_best_replications = 5,
  min_replication_rate = 0.50
) {
  out_empty <- list(
    best_LL = NA_real_,
    n_optimizer_converged = 0L,
    n_best_LL = 0L,
    best_LL_replication_rate = NA_real_,
    best_runs = integer(0),
    fit_stable = NA,
    bic_range_best = NA_real_,
    entropy_range_best = NA_real_,
    loglik_range_best = NA_real_,
    mean_BIC_best = NA_real_,
    mean_AIC_best = NA_real_,
    mean_entropy_best = NA_real_,
    param_stable = NA,
    param_max_diff = NA_real_,
    param_mean_diff = NA_real_,
    param_details = "No optimizer converged runs",
    stable = FALSE
  )

  non_null_mask <- !purrr::map_lgl(lca_models_for_class, is.null)
  models <- lca_models_for_class[non_null_mask]
  run_idx <- model_run_indices[non_null_mask]

  if (length(models) == 0) {
    return(out_empty)
  }

  conv_mask <- purrr::map_lgl(models, optimizer_converged)
  conv_models <- models[conv_mask]
  conv_runs <- run_idx[conv_mask]

  if (length(conv_models) == 0) {
    return(out_empty)
  }

  ll_vals <- purrr::map_dbl(conv_models, model_ll)
  best_ll <- safe_max(ll_vals)

  best_mask <- !is.na(ll_vals) & abs(ll_vals - best_ll) <= loglik_tol
  best_models <- conv_models[best_mask]
  best_runs <- conv_runs[best_mask]

  n_conv <- length(conv_models)
  n_best <- length(best_models)
  rep_rate <- n_best / n_conv

  fit_best <- fit_results[
    fit_results$classes == class_num &
      fit_results$optimizer_converged &
      fit_results$run %in% best_runs,
    ,
    drop = FALSE
  ]

  bic_range_best <- safe_range_diff(fit_best$BIC)
  entropy_range_best <- safe_range_diff(fit_best$Entropy)
  loglik_range_best <- safe_range_diff(fit_best$LL)

  fit_stable <- if (nrow(fit_best) >= 2) {
    isTRUE(loglik_range_best <= loglik_tol)
  } else {
    NA
  }

  param_check <- assess_best_run_agreement(
    best_models = best_models,
    param_threshold = param_threshold
  )

  stable <- (n_best >= min_best_replications) &&
    (rep_rate >= min_replication_rate) &&
    (is.na(param_check$param_stable) || isTRUE(param_check$param_stable))

  list(
    best_LL = best_ll,
    n_optimizer_converged = n_conv,
    n_best_LL = n_best,
    best_LL_replication_rate = rep_rate,
    best_runs = best_runs,
    fit_stable = fit_stable,
    bic_range_best = bic_range_best,
    entropy_range_best = entropy_range_best,
    loglik_range_best = loglik_range_best,
    mean_BIC_best = safe_mean(fit_best$BIC),
    mean_AIC_best = safe_mean(fit_best$AIC),
    mean_entropy_best = safe_mean(fit_best$Entropy),
    param_stable = param_check$param_stable,
    param_max_diff = param_check$param_max_diff,
    param_mean_diff = param_check$param_mean_diff,
    param_details = param_check$details,
    stable = stable
  )
}


# ==============================================================================
# Main LCA Workflow
# ==============================================================================

# Run and evaluate a latent class analysis using strict stability rules.
#
# Args:
#   data: Data frame of indicator variables. Will be coerced to integers via
#     prepare_lca_data().
#   min_classes: Smallest class count to fit
#   max_classes: Largest class count to fit
#   n_runs: Number of random start runs
#   base_seed: Base seed so run i uses base_seed + i
#   entropy_threshold: Entropy cutoff used only when use_entropy_filter is TRUE
#   param_threshold: Largest acceptable probability cell difference among
#     replicated best runs
#   maxiter: Maximum EM iterations per fit
#   tol: poLCA convergence tolerance
#   nrep_per_call: Internal random starts per poLCA call. Keep at 1 so
#     stability depends on the external run index, not on hidden restarts.
#   return_fit_table: If TRUE, include the full per run fit table
#   verbose: If TRUE, print detailed diagnostics
#   loglik_tol: Tolerance for deciding whether two log likelihoods match
#   min_best_replications: Minimum best LL replications for a stable model
#   min_replication_rate: Minimum fraction of converged runs reaching best LL
#   use_entropy_filter: If TRUE, apply entropy_threshold as a hard gatekeeper
#
# Returns:
#   List with recommended_classes, recommendation_reason, best_model, summary,
#   stability_details, all_models, and optionally fit_table.
check_lca <- function(
  data,
  min_classes = 2,
  max_classes = 7,
  n_runs = 25,
  base_seed = 42,
  entropy_threshold = 0.80,
  param_threshold = 0.05,
  maxiter = 3000,
  tol = 1e-10,
  nrep_per_call = 1,
  return_fit_table = FALSE,
  verbose = FALSE,
  loglik_tol = 1e-4,
  min_best_replications = 5,
  min_replication_rate = 0.50,
  use_entropy_filter = FALSE
) {
  data_prepped <- prepare_lca_data(data)
  formula <- make_lca_formula(data_prepped)

  class_values <- min_classes:max_classes

  all_models <- stats::setNames(
    vector("list", length(class_values)),
    as.character(class_values)
  )

  for (k in class_values) {
    all_models[[as.character(k)]] <- vector("list", n_runs)
  }

  with_progress({
    p <- progressor(steps = n_runs)

    run_results <- furrr::future_map(
      seq_len(n_runs),
      function(run) {
        p(message = sprintf("Run %d/%d", run, n_runs))

        fit_one_poLCA_run(
          data = data_prepped,
          formula = formula,
          min_classes = min_classes,
          max_classes = max_classes,
          run = run,
          base_seed = base_seed,
          maxiter = maxiter,
          tol = tol,
          nrep_per_call = nrep_per_call,
          verbose = verbose
        )
      },
      .options = furrr::furrr_options(seed = TRUE)
    )
  })

  fit_rows_list <- list()
  fit_idx <- 0L

  for (res in run_results) {
    if (is.null(res)) {
      next
    }

    run <- res$run
    models <- res$models
    class_ids <- res$class_ids

    for (i in seq_along(models)) {
      k <- class_ids[i]
      if (!is.na(k) && as.character(k) %in% names(all_models)) {
        all_models[[as.character(k)]][[run]] <- models[[i]]
      }
    }

    for (row_obj in res$fit_rows) {
      if (is.null(row_obj)) {
        next
      }
      fit_idx <- fit_idx + 1L
      fit_rows_list[[fit_idx]] <- row_obj
    }
  }

  if (fit_idx == 0L) {
    cli::cli_abort(
      paste(
        "No models were returned.",
        "Check your data and model specification."
      )
    )
  }

  all_results <- vctrs::vec_rbind(!!!fit_rows_list)

  summary_stats <- all_results |>
    dplyr::group_by(classes) |>
    dplyr::summarise(
      n_runs_attempted = n_runs,
      n_models_returned = dplyr::n(),
      n_optimizer_converged = sum(optimizer_converged, na.rm = TRUE),
      best_LL = safe_max(LL[optimizer_converged]),
      min_BIC_converged = safe_min(BIC[optimizer_converged]),
      mean_BIC_converged = safe_mean(BIC[optimizer_converged]),
      sd_BIC_converged = safe_sd(BIC[optimizer_converged]),
      mean_AIC_converged = safe_mean(AIC[optimizer_converged]),
      mean_entropy_converged = safe_mean(Entropy[optimizer_converged]),
      sd_entropy_converged = safe_sd(Entropy[optimizer_converged]),
      mean_prob_min_converged = safe_mean(prob_min[optimizer_converged]),
      .groups = "drop"
    )

  stability_results <- vector("list", length(class_values))
  names(stability_results) <- as.character(class_values)

  for (k in class_values) {
    k_model_list <- all_models[[as.character(k)]]
    run_indices_k <- seq_along(k_model_list)

    stability_results[[as.character(k)]] <- check_model_stability(
      fit_results = all_results,
      class_num = k,
      lca_models_for_class = k_model_list,
      model_run_indices = run_indices_k,
      loglik_tol = loglik_tol,
      param_threshold = param_threshold,
      min_best_replications = min_best_replications,
      min_replication_rate = min_replication_rate
    )
  }

  pull_stability <- function(name) {
    sapply(summary_stats$classes, function(k) {
      x <- stability_results[[as.character(k)]]
      if (is.null(x) || is.null(x[[name]])) NA else x[[name]]
    })
  }

  summary_stats$n_best_LL <- pull_stability("n_best_LL")
  summary_stats$best_LL_replication_rate <- pull_stability(
    "best_LL_replication_rate"
  )
  summary_stats$mean_BIC_best <- pull_stability("mean_BIC_best")
  summary_stats$mean_AIC_best <- pull_stability("mean_AIC_best")
  summary_stats$mean_entropy_best <- pull_stability("mean_entropy_best")
  summary_stats$fit_stable <- pull_stability("fit_stable")
  summary_stats$param_stable <- pull_stability("param_stable")
  summary_stats$param_max_diff <- pull_stability("param_max_diff")
  summary_stats$overall_stable <- pull_stability("stable")

  summary_stats$selection_entropy <- ifelse(
    is.na(summary_stats$mean_entropy_best),
    summary_stats$mean_entropy_converged,
    summary_stats$mean_entropy_best
  )

  # Tier 1: strictly stable solutions
  stable_candidates <- summary_stats[
    summary_stats$overall_stable %in% TRUE,
    ,
    drop = FALSE
  ]

  if (use_entropy_filter) {
    stable_candidates <- stable_candidates[
      !is.na(stable_candidates$selection_entropy) &
        stable_candidates$selection_entropy >= entropy_threshold,
      ,
      drop = FALSE
    ]
  }

  if (nrow(stable_candidates) > 0) {
    recommended_classes <- stable_candidates$classes[
      which.min(stable_candidates$min_BIC_converged)
    ]
    reason <- paste(
      "Lowest BIC among models whose best log likelihood replicated often",
      "enough and passed parameter checks."
    )
  } else {
    # Tier 2: partial replication
    replicated_candidates <- summary_stats[
      summary_stats$n_best_LL >= 2 &
        summary_stats$n_optimizer_converged >= 2,
      ,
      drop = FALSE
    ]

    if (use_entropy_filter) {
      replicated_candidates <- replicated_candidates[
        !is.na(replicated_candidates$selection_entropy) &
          replicated_candidates$selection_entropy >= entropy_threshold,
        ,
        drop = FALSE
      ]
    }

    if (nrow(replicated_candidates) > 0) {
      recommended_classes <- replicated_candidates$classes[
        which.min(replicated_candidates$min_BIC_converged)
      ]
      reason <- paste(
        "No model met the strict stability rule.",
        "Selected the lowest BIC among solutions whose best log likelihood",
        "replicated at least twice."
      )
    } else {
      # Tier 3: any converged solution
      converged_candidates <- summary_stats[
        summary_stats$n_optimizer_converged > 0,
        ,
        drop = FALSE
      ]

      if (nrow(converged_candidates) == 0) {
        cli::cli_abort("No optimizer converged models were found.")
      }

      recommended_classes <- converged_candidates$classes[
        which.min(converged_candidates$min_BIC_converged)
      ]
      reason <- paste(
        "WARNING: No solution showed best log likelihood replication.",
        "Selected the lowest BIC among optimizer converged models only."
      )
    }
  }

  rec_k_chr <- as.character(recommended_classes)
  rec_stability <- stability_results[[rec_k_chr]]

  best_model <- NULL

  if (!is.null(rec_stability) && length(rec_stability$best_runs) > 0) {
    best_model <- all_models[[rec_k_chr]][[rec_stability$best_runs[1]]]
  } else {
    k_models <- all_models[[rec_k_chr]]
    k_models <- k_models[!purrr::map_lgl(k_models, is.null)]
    k_models <- k_models[purrr::map_lgl(k_models, optimizer_converged)]

    if (length(k_models) > 0) {
      lls <- purrr::map_dbl(k_models, model_ll)
      best_model <- k_models[[which.max(lls)]]
    }
  }

  cat("\n=== LCA Model Selection Results ===\n")
  cat(sprintf("Recommended number of classes : %d\n", recommended_classes))
  cat(sprintf("Reason                        : %s\n", reason))

  if (!is.null(rec_stability)) {
    cat(sprintf(
      "Optimizer converged runs      : %d\n",
      rec_stability$n_optimizer_converged
    ))
    cat(sprintf(
      "Best LL replications          : %d\n",
      rec_stability$n_best_LL
    ))
    cat(sprintf(
      "Best LL replication rate      : %.0f%%\n",
      100 * rec_stability$best_LL_replication_rate
    ))
    if (!is.na(rec_stability$param_max_diff)) {
      cat(sprintf(
        "Max parameter diff            : %.4f\n",
        rec_stability$param_max_diff
      ))
    }
    cat(sprintf(
      "Overall stable                : %s\n",
      rec_stability$stable
    ))
  }

  if (verbose) {
    cat("\nSummary by class count:\n")
    print(as.data.frame(summary_stats), digits = 4)

    cat("\nStability details:\n")
    for (k_chr in names(stability_results)) {
      s <- stability_results[[k_chr]]
      cat(sprintf(
        paste(
          "k=%s | optimizer converged=%d | best LL reps=%d |",
          "replication rate=%s | param stable=%s | overall stable=%s\n"
        ),
        k_chr,
        s$n_optimizer_converged,
        s$n_best_LL,
        ifelse(
          is.na(s$best_LL_replication_rate),
          "NA",
          sprintf("%.2f", s$best_LL_replication_rate)
        ),
        as.character(s$param_stable),
        as.character(s$stable)
      ))
    }
  }

  result <- list(
    recommended_classes = recommended_classes,
    recommendation_reason = reason,
    best_model = best_model,
    summary = summary_stats,
    stability_details = stability_results,
    all_models = all_models
  )

  if (return_fit_table) {
    result$fit_table <- all_results
  }

  invisible(result)
}


# ==============================================================================
# Output Formatting
# ==============================================================================

# Format LCA class probabilities as a labeled wide table.
#
# Args:
#   model: A fitted poLCA model
#   data: Data frame used for fitting, which supplies variable and value labels
#
# Returns:
#   Wide tibble with variable_label, value_label and one column per class.
tidy_lca_probs <- function(model, data) {
  if (is.null(model) || is.null(model$probs)) {
    stop("Model has no probs component.")
  }

  long_rows <- purrr::imap(model$probs, function(mat, varname) {
    mat <- as.matrix(mat)
    n_cls <- nrow(mat)
    n_cat <- ncol(mat)

    tibble::tibble(
      variable = varname,
      class = rep(seq_len(n_cls), times = n_cat),
      outcome = rep(seq_len(n_cat), each = n_cls),
      estimate = as.vector(mat)
    )
  })

  df <- vctrs::vec_rbind(!!!long_rows)

  variable_label_lookup <- tibble::tibble(
    variable = unique(df$variable),
    variable_label = sapply(
      unique(df$variable),
      \(var) {
        if (!var %in% names(data)) {
          return(var)
        }
        label <- attr_var_label(data[[var]])
        if (is.null(label) || label == "" || is.na(label)) var else label
      }
    )
  )

  value_label_lookup_list <- purrr::map(
    unique(df$variable),
    \(x) {
      if (!x %in% names(data)) {
        return(NULL)
      }
      labels <- attr_val_labels(data[[x]])

      if (!is.null(labels)) {
        tibble::tibble(
          variable = x,
          outcome = unname(as.integer(labels)),
          value_label = names(labels)
        )
      } else if (is.factor(data[[x]])) {
        factor_levels <- levels(data[[x]])
        tibble::tibble(
          variable = x,
          outcome = seq_along(factor_levels),
          value_label = factor_levels
        )
      } else {
        NULL
      }
    }
  )

  value_label_lookup_list <- value_label_lookup_list[
    !sapply(value_label_lookup_list, is.null)
  ]

  value_label_lookup <- if (length(value_label_lookup_list) > 0) {
    vctrs::vec_rbind(!!!value_label_lookup_list)
  } else {
    tibble::tibble(
      variable = character(0),
      outcome = integer(0),
      value_label = character(0)
    )
  }

  df <- df |>
    dplyr::left_join(variable_label_lookup, by = "variable") |>
    dplyr::left_join(value_label_lookup, by = c("variable", "outcome")) |>
    dplyr::mutate(
      class = paste0("Class ", class),
      estimate = make_percent(estimate, decimals = 1),
      value_label = ifelse(
        is.na(value_label),
        as.character(outcome),
        value_label
      )
    )

  attr(df$value_label, "label") <- "Response Options"

  df |>
    dplyr::select(variable_label, value_label, class, estimate) |>
    tidyr::pivot_wider(names_from = class, values_from = estimate)
}


# Print a compact LCA summary table.
print_lca_summary <- function(x, digits = 3) {
  summary_df <- if (is.list(x) && !is.null(x$summary)) x$summary else x

  if (!is.data.frame(summary_df)) {
    stop("x must be either a check_lca() result or a summary data frame.")
  }

  recommended_k <- if (is.list(x) && !is.null(x$recommended_classes)) {
    x$recommended_classes
  } else {
    NA_integer_
  }

  fmt_flag <- function(z) {
    ifelse(is.na(z), "", ifelse(z, "yes", "no"))
  }

  out <- summary_df |>
    dplyr::arrange(classes) |>
    dplyr::mutate(
      recommended = ifelse(
        !is.na(recommended_k) & classes == recommended_k,
        "yes",
        ""
      ),
      replication_rate = ifelse(
        is.na(best_LL_replication_rate),
        NA_character_,
        sprintf("%.0f%%", 100 * best_LL_replication_rate)
      ),
      best_LL = round(best_LL, digits),
      min_BIC_converged = round(min_BIC_converged, digits),
      mean_BIC_converged = round(mean_BIC_converged, digits),
      mean_AIC_converged = round(mean_AIC_converged, digits),
      mean_entropy_converged = round(mean_entropy_converged, digits),
      mean_entropy_best = round(mean_entropy_best, digits),
      mean_prob_min_converged = round(mean_prob_min_converged, digits),
      param_max_diff = round(param_max_diff, digits),
      param_stable = fmt_flag(param_stable),
      overall_stable = fmt_flag(overall_stable)
    ) |>
    dplyr::select(
      recommended,
      classes,
      n_optimizer_converged,
      n_best_LL,
      replication_rate,
      best_LL,
      min_BIC_converged,
      mean_BIC_converged,
      mean_AIC_converged,
      mean_entropy_converged,
      mean_entropy_best,
      mean_prob_min_converged,
      param_stable,
      param_max_diff,
      overall_stable
    )

  cat("\n=== LCA Summary Table ===\n")
  print(as.data.frame(out), row.names = FALSE)

  invisible(out)
}
