# Title:        LCA Model Fitting and Stability Assessment
# Purpose:      Functions for running latent class analysis
#               with multiple random starts, assessing
#               convergence stability and recommending
#               optimal class counts
# Date created: [TODO: fill in creation date]
# Dependencies: adldata, OpenMx, tidySEM, furrr, future,
#               progressr, purrr, dplyr, cli, tibble,
#               vctrs, tidyr

# ==============================================================================
# Setup
# ==============================================================================

# Libraries

library(adldata)
library(OpenMx) # SEM engine used by tidySEM
library(tidySEM) # LCA model fitting and diagnostics
library(furrr) # Parallel purrr using future backend
library(future) # Parallel backend
library(progressr) # Progress bars for parallel workers
library(purrr) # Typed map helpers
library(dplyr) # Data wrangling
library(cli) # User facing messages and warnings
library(tibble) # Tibble construction for label lookups


# Parallel configuration

# Use all cores minus one so the machine stays responsive.
# max(1, ...) ensures at least one worker.
plan(
  multisession,
  workers = max(1, parallel::detectCores() - 1)
)

# Limit OpenMx to one thread per model so parallel workers do not compete
# with each other.
mxOption(NULL, "Number of Threads", 1)


# ==============================================================================
# Helper Functions
# ==============================================================================

# Safely extract a single value from a data frame row.
#
# Args:
#   df: A data frame, possibly with zero rows
#   col: Column name to extract
#
# Returns:
#   The first value in the requested column, or NA_real_ if the data frame is
#   empty or the column does not exist.
safe_extract <- function(df, col) {
  if (nrow(df) > 0 && col %in% names(df)) {
    df[[col]][1]
  } else {
    NA_real_
  }
}


# Compute relative, normalized entropy for a fitted LCA.
#
# Args:
#   model: A fitted tidySEM / OpenMx LCA model
#
# Returns:
#   Numeric scalar in [0, 1], where 1 means perfect class separation and
#   0 means no separation.
rel_entropy <- function(model) {
  # Extract posterior class membership probabilities.
  # cp$individual is an n by k matrix.
  cp <- class_prob(model)
  post <- as.matrix(cp$individual)
  n_class <- ncol(post)

  # Observed entropy.
  # The small offset prevents log(0).
  num <- -sum(post * log(post + 1e-10), na.rm = TRUE)

  # Maximum possible entropy for n observations and k classes.
  deno <- nrow(post) * log(n_class)

  # Values near 1 indicate well separated classes.
  1 - (num / deno)
}


# Extract class conditional response probabilities from a fitted model.
#
# This uses tidySEM::table_prob() to convert thresholds into proper response
# probabilities, then reshapes them into one matrix per indicator.
#
# Args:
#   model: A fitted tidySEM / OpenMx LCA model
#
# Returns:
#   Named list of numeric matrices, one per indicator.
#   Row i is class i, column j is P(category j | class i).
extract_class_probs_tidysem <- function(model) {
  tp <- tryCatch(
    table_prob(model),
    error = function(e) {
      stop("table_prob() failed: ", e$message)
    }
  )

  if (is.null(tp) || nrow(tp) == 0) {
    stop("table_prob() returned no data.")
  }

  required_cols <- c("Variable", "Category", "Probability", "group")

  if (!all(required_cols %in% names(tp))) {
    stop(
      "Unexpected table_prob() columns. Expected: ",
      paste(required_cols, collapse = ", "),
      " Got: ",
      paste(names(tp), collapse = ", ")
    )
  }

  # Parse class number from strings like "class3".
  tp$class_num <- as.integer(
    gsub("class", "", tolower(tp$group), fixed = TRUE)
  )

  if (any(is.na(tp$class_num))) {
    stop("Could not parse class numbers from group column.")
  }

  var_names <- unique(tp$Variable)
  result <- vector("list", length(var_names))
  names(result) <- var_names

  for (v in var_names) {
    v_data <- tp[tp$Variable == v, ]
    n_cls <- max(v_data$class_num)
    n_cats <- max(as.integer(v_data$Category))

    mat <- matrix(
      NA_real_,
      nrow = n_cls,
      ncol = n_cats
    )

    for (row_i in seq_len(nrow(v_data))) {
      mat[
        v_data$class_num[row_i],
        as.integer(v_data$Category[row_i])
      ] <- v_data$Probability[row_i]
    }

    result[[v]] <- mat
  }

  result
}


# Generate all permutations of a vector.
#
# Uses Heap's non recursive algorithm. This is used to enumerate every possible
# class relabeling when resolving label switching.
#
# Args:
#   x: Vector to permute, or a single integer n which is treated as seq(n)
#   fun: Optional function applied to each permutation
#   ...: Additional arguments passed to fun
#
# Returns:
#   List of all permutations.
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
#
# This tries every permutation of the class labels in probs2 and returns the one
# that minimizes the total squared difference relative to probs1.
#
# Args:
#   probs1: Reference probability list from extract_class_probs_tidysem()
#   probs2: Comparison probability list
#
# Returns:
#   A list with:
#     permutation: Best class relabeling
#     distance: Total squared distance after relabeling
#     error: Error message if matching failed
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
# Strict LCA Helpers
# ==============================================================================

# Get the OpenMx optimizer status code from a fitted model.
#
# Args:
#   model: A fitted tidySEM / OpenMx LCA model
#
# Returns:
#   Integer status code, or NA if unavailable.
#   Status code 0 usually means clean optimizer convergence.
model_status_code <- function(model) {
  tryCatch(
    {
      code <- model$output$status$code
      if (length(code) == 0 || is.null(code)) {
        NA_integer_
      } else {
        as.integer(code[[1]])
      }
    },
    error = function(e) {
      NA_integer_
    }
  )
}


# Check whether a fitted model converged cleanly.
#
# Args:
#   model: A fitted tidySEM / OpenMx LCA model
#
# Returns:
#   TRUE if the optimizer status code is 0, otherwise FALSE.
optimizer_converged <- function(model) {
  code <- model_status_code(model)
  !is.na(code) && code == 0L
}


# Extract model log likelihood from an OpenMx model.
#
# Args:
#   model: A fitted tidySEM / OpenMx LCA model
#
# Returns:
#   Numeric log likelihood, or NA if unavailable.
#   OpenMx stores minus two times the log likelihood in output$fit.
model_ll <- function(model) {
  tryCatch(
    {
      -0.5 * model$output$fit
    },
    error = function(e) {
      NA_real_
    }
  )
}


# Try to extract AIC directly from a fitted model.
#
# Args:
#   model: A fitted tidySEM / OpenMx LCA model
#
# Returns:
#   Numeric AIC, or NA if unavailable.
model_aic <- function(model) {
  tryCatch(
    {
      as.numeric(stats::AIC(model))
    },
    error = function(e) {
      NA_real_
    }
  )
}


# Try to extract BIC directly from a fitted model.
#
# Args:
#   model: A fitted tidySEM / OpenMx LCA model
#
# Returns:
#   Numeric BIC, or NA if unavailable.
model_bic <- function(model) {
  tryCatch(
    {
      as.numeric(stats::BIC(model))
    },
    error = function(e) {
      NA_real_
    }
  )
}


# Estimate the smallest class proportion from a fitted model.
#
# Args:
#   model: A fitted tidySEM / OpenMx LCA model
#
# Returns:
#   Smallest estimated class probability, or NA if unavailable.
model_prob_min <- function(model) {
  tryCatch(
    {
      cp <- class_prob(model)
      if (!is.null(cp$model) && "Probability" %in% names(cp$model)) {
        min(cp$model$Probability, na.rm = TRUE)
      } else {
        NA_real_
      }
    },
    error = function(e) {
      NA_real_
    }
  )
}


# Estimate the smallest assigned class size using posterior modal assignment.
#
# Args:
#   model: A fitted tidySEM / OpenMx LCA model
#
# Returns:
#   Smallest class size based on modal posterior assignment, or NA if unavailable.
model_n_min <- function(model) {
  tryCatch(
    {
      cp <- class_prob(model)
      post <- as.matrix(cp$individual)

      if (nrow(post) == 0 || ncol(post) == 0) {
        return(NA_real_)
      }

      class_id <- max.col(post, ties.method = "first")
      min(tabulate(class_id, nbins = ncol(post)))
    },
    error = function(e) {
      NA_real_
    }
  )
}


# Safe summaries that return NA instead of erroring on empty inputs.
#
# Args:
#   x: Numeric vector
#
# Returns:
#   Scalar summary value, or NA when the input is empty or too short.
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

# Fit one random start across the full class range.
#
# Args:
#   data: Data frame used for LCA
#   min_classes: Smallest number of classes to fit
#   max_classes: Largest number of classes to fit
#   run: Integer run number, used to set the seed
#   base_seed: Base seed so run i uses base_seed + i
#   try_hard: If TRUE, retry nonconverged models with mxTryHard()
#   extra_tries: Number of extra tries passed to mxTryHard()
#   verbose: If TRUE, print run level warnings
#
# Returns:
#   A list with:
#     run: Run number
#     models: Fitted model list for this run
#     fit_rows: List of one row data frames, one per class count
fit_one_lca_run <- function(
  data,
  min_classes,
  max_classes,
  run,
  base_seed = 42,
  try_hard = FALSE,
  extra_tries = 20,
  verbose = FALSE
) {
  set.seed(base_seed + run)

  library(OpenMx)
  library(tidySEM)

  mxOption(NULL, "Number of Threads", 1)

  requested_classes <- min_classes:max_classes

  raw_models <- tryCatch(
    {
      models <- NULL

      invisible(capture.output(
        suppressMessages({
          models <- lapply(
            requested_classes,
            function(k) mx_lca(data, classes = k)
          )
          attr(models, "tidySEM") <- "list"
          class(models) <- c("mixture_list", class(models))
        })
      ))

      models
    },
    error = function(e) e
  )

  if (inherits(raw_models, "error")) {
    if (verbose) {
      message("Run ", run, " failed: ", conditionMessage(raw_models))
    }
    return(NULL)
  }

  if (!is.list(raw_models) || length(raw_models) == 0) {
    if (verbose) {
      message(
        "Run ",
        run,
        " returned an unexpected object of class: ",
        paste(class(raw_models), collapse = ", ")
      )
    }
    return(NULL)
  }

  models <- raw_models

  for (i in seq_along(models)) {
    mod <- models[[i]]

    if (is.null(mod)) {
      next
    }

    if (!optimizer_converged(mod) && try_hard) {
      mod <- tryCatch(
        mxTryHard(
          mod,
          extraTries = extra_tries,
          silent = TRUE
        ),
        error = function(e) mod
      )
    }

    models[[i]] <- mod
  }

  fit_table <- tryCatch(
    table_fit(models),
    error = function(e) NULL
  )

  returned_classes <- NULL

  if (!is.null(fit_table) && "Classes" %in% names(fit_table)) {
    returned_classes <- fit_table$Classes
  }

  if (is.null(returned_classes) || length(returned_classes) != length(models)) {
    model_names <- names(models)
    model_names_num <- suppressWarnings(as.integer(model_names))

    if (
      length(model_names_num) == length(models) &&
        all(!is.na(model_names_num))
    ) {
      returned_classes <- model_names_num
    }
  }

  if (is.null(returned_classes) || length(returned_classes) != length(models)) {
    if (length(models) == length(requested_classes)) {
      returned_classes <- requested_classes
    } else {
      returned_classes <- requested_classes[seq_len(length(models))]
    }
  }

  keep_idx <- which(
    !is.na(returned_classes) &
      returned_classes >= min_classes &
      returned_classes <= max_classes
  )

  if (length(keep_idx) == 0) {
    if (verbose) {
      message(
        "Run ",
        run,
        " returned no models in requested class range ",
        min_classes,
        " to ",
        max_classes,
        "."
      )
    }
    return(NULL)
  }

  models <- models[keep_idx]
  returned_classes <- returned_classes[keep_idx]

  fit_rows <- purrr::map2(
    seq_along(models),
    returned_classes,
    function(i, k) {
      mod <- models[[i]]

      if (is.null(mod)) {
        return(NULL)
      }

      fit_row_raw <- if (
        !is.null(fit_table) && "Classes" %in% names(fit_table)
      ) {
        fit_table[fit_table$Classes == k, , drop = FALSE]
      } else {
        data.frame()
      }

      aic_val <- safe_extract(fit_row_raw, "AIC")
      bic_val <- safe_extract(fit_row_raw, "BIC")
      ent_val <- safe_extract(fit_row_raw, "Entropy")
      n_min_val <- safe_extract(fit_row_raw, "n_min")
      prob_min_val <- safe_extract(fit_row_raw, "prob_min")

      if (is.na(aic_val)) {
        aic_val <- model_aic(mod)
      }
      if (is.na(bic_val)) {
        bic_val <- model_bic(mod)
      }
      if (is.na(ent_val) && optimizer_converged(mod)) {
        ent_val <- tryCatch(
          rel_entropy(mod),
          error = function(e) NA_real_
        )
      }
      if (is.na(n_min_val)) {
        n_min_val <- model_n_min(mod)
      }
      if (is.na(prob_min_val)) {
        prob_min_val <- model_prob_min(mod)
      }

      data.frame(
        run = run,
        classes = k,
        status_code = model_status_code(mod),
        optimizer_converged = optimizer_converged(mod),
        LL = model_ll(mod),
        AIC = aic_val,
        BIC = bic_val,
        Entropy = ent_val,
        n_min = n_min_val,
        prob_min = prob_min_val
      )
    }
  )

  list(
    run = run,
    models = models,
    class_ids = returned_classes,
    fit_rows = fit_rows
  )
}


# ==============================================================================
# Stability Assessment
# ==============================================================================

# Compare only the runs that reached the best log likelihood and check whether
# their class specific response probabilities are similar after class labels are
# aligned.
#
# Args:
#   best_models: List of fitted models that all reached the best log likelihood
#   param_threshold: Largest acceptable absolute difference in any probability
#     cell after class labels have been aligned
#
# Returns:
#   A list with parameter stability information.
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
    extract_class_probs_tidysem(best_models[[1]]),
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
      extract_class_probs_tidysem(best_models[[i]]),
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
# What this function evaluates:
#   1. Keep only optimizer converged runs
#   2. Find the best log likelihood among them
#   3. Count how many converged runs replicated that best value within tolerance
#   4. Check whether the replicated best runs agree on parameters
#
# Args:
#   fit_results: Full per run fit table for all runs and class counts
#   class_num: Integer class count k being evaluated
#   lca_models_for_class: List of all fitted models for this k, including NULLs
#   model_run_indices: Integer vector linking list positions to run numbers
#   loglik_tol: Tolerance for deciding whether two log likelihood values match
#   param_threshold: Largest acceptable probability cell difference
#   min_best_replications: Minimum number of best log likelihood replications
#     required to call a model stable
#   min_replication_rate: Minimum fraction of converged runs that must reach the
#     best log likelihood to call a model stable
#
# Returns:
#   A named list summarizing strict stability for this class count.
check_model_stability <- function(
  fit_results,
  class_num,
  lca_models_for_class,
  model_run_indices,
  loglik_tol = 1e-6,
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

  # Replication means matching the best log likelihood within tolerance.
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
#   data: Data frame of indicator variables
#   min_classes: Smallest class count to fit
#   max_classes: Largest class count to fit
#   n_runs: Number of random start runs
#   base_seed: Base seed so run i uses base_seed + i
#   entropy_threshold: Optional entropy cutoff used only if use_entropy_filter is
#     TRUE. Kept here for backward compatibility with the earlier function.
#   param_threshold: Largest acceptable probability cell difference among the
#     replicated best runs
#   convergence_distance: Kept only for backward compatibility. It is not used in
#     this stricter version because stability is based on best log likelihood
#     replication rather than distance to a reference solution.
#   try_hard: If TRUE, retry nonconverged models with mxTryHard()
#   return_fit_table: If TRUE, include the full per run fit table in the output
#   verbose: If TRUE, print detailed diagnostics
#   extra_tries: Number of extra tries passed to mxTryHard()
#   loglik_tol: Tolerance for deciding whether two log likelihood values match
#   min_best_replications: Minimum number of times the best log likelihood must
#     be replicated to call a model stable
#   min_replication_rate: Minimum proportion of converged runs that must reach
#     the best log likelihood to call a model stable
#   use_entropy_filter: If TRUE, apply entropy_threshold as a hard filter during
#     model selection. If FALSE, entropy is reported but not used as a gatekeeper
#
# Returns:
#   A list with:
#     recommended_classes
#     recommendation_reason
#     best_model
#     summary
#     stability_details
#     all_models
#     fit_table, if requested
check_lca <- function(
  data,
  min_classes = 2,
  max_classes = 7,
  n_runs = 25,
  base_seed = 42,
  entropy_threshold = 0.80,
  param_threshold = 0.05,
  convergence_distance = 0.1,
  try_hard = FALSE,
  return_fit_table = FALSE,
  verbose = FALSE,
  extra_tries = 20,
  loglik_tol = 1e-6,
  min_best_replications = 5,
  min_replication_rate = 0.50,
  use_entropy_filter = FALSE
) {
  class_values <- min_classes:max_classes

  # Preallocate model storage.
  all_models <- stats::setNames(
    vector("list", length(class_values)),
    as.character(class_values)
  )

  for (k in class_values) {
    all_models[[as.character(k)]] <- vector("list", n_runs)
  }

  # Keep OpenMx single threaded so parallel random starts do not compete for
  # the same CPU threads.
  mxOption(NULL, "Number of Threads", 1)

  # Fit one full set of class solutions per run in parallel.
  with_progress({
    p <- progressor(steps = n_runs)

    run_results <- furrr::future_map(
      seq_len(n_runs),
      function(run) {
        p(message = sprintf("Run %d/%d", run, n_runs))

        fit_one_lca_run(
          data = data,
          min_classes = min_classes,
          max_classes = max_classes,
          run = run,
          base_seed = base_seed,
          try_hard = try_hard,
          extra_tries = extra_tries,
          verbose = verbose
        )
      },
      .options = furrr::furrr_options(seed = TRUE)
    )
  })

  # Collect model objects and fit rows.
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

  # Summarize only the runs that truly converged according to OpenMx.
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

  # Assess stability separately for each class count.
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

  # Pull one field from each stability result into the summary table.
  pull_stability <- function(name) {
    sapply(summary_stats$classes, function(k) {
      x <- stability_results[[as.character(k)]]
      if (is.null(x) || is.null(x[[name]])) {
        NA
      } else {
        x[[name]]
      }
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

  # Use entropy from the replicated best runs when available.
  # Otherwise use entropy from all optimizer converged runs.
  summary_stats$selection_entropy <- ifelse(
    is.na(summary_stats$mean_entropy_best),
    summary_stats$mean_entropy_converged,
    summary_stats$mean_entropy_best
  )

  # Model selection logic:
  # Tier 1, strictly stable solutions
  # Tier 2, some best log likelihood replication
  # Tier 3, any optimizer converged solution
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

  # Choose a representative fitted model for the recommended class count.
  # Prefer a run that matched the best log likelihood.
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

  # Print compact recommendation summary.
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

# Format LCA class probabilities as a labeled table.
#
# This extracts class conditional response probabilities, joins variable and
# value labels from the original data and pivots to a wide format for reporting.
#
# Args:
#   model: A fitted tidySEM / OpenMx LCA model
#   data: Data frame used for fitting, which supplies variable and value labels
#
# Returns:
#   Wide tibble with variable_label, value_label and one column per class.
tidy_lca_probs <- function(model, data) {
  df <- table_prob(model) |>
    rename(
      variable = Variable,
      outcome = Category,
      estimate = Probability,
      class = group
    ) |>
    mutate(outcome = as.integer(outcome))

  variable_label_lookup <- tibble(
    variable = unique(df$variable),
    variable_label = sapply(
      unique(df$variable),
      \(var) {
        label <- attr_var_label(data[[var]])
        if (is.null(label) || label == "" || is.na(label)) {
          var
        } else {
          label
        }
      }
    )
  )

  value_label_lookup_list <- map(
    unique(df$variable),
    \(x) {
      labels <- attr_val_labels(data[[x]])

      if (!is.null(labels)) {
        tibble(
          variable = x,
          outcome = unname(labels),
          value_label = names(labels)
        )
      } else if (is.factor(data[[x]])) {
        factor_levels <- levels(data[[x]])
        tibble(
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

  value_label_lookup <- vctrs::vec_rbind(
    !!!value_label_lookup_list
  )

  df <- df |>
    left_join(
      variable_label_lookup,
      by = "variable"
    ) |>
    left_join(
      value_label_lookup,
      by = c("variable", "outcome")
    ) |>
    mutate(
      class = gsub(
        "class",
        "Class ",
        class,
        fixed = TRUE
      ),
      estimate = make_percent(estimate, decimals = 1),
      value_label = ifelse(
        is.na(value_label),
        as.character(outcome),
        value_label
      )
    )

  attr(df$value_label, "label") <- "Response Options"

  df |>
    select(
      variable_label,
      value_label,
      class,
      estimate
    ) |>
    tidyr::pivot_wider(
      names_from = class,
      values_from = estimate
    )
}


# Print a compact LCA summary table.
#
# Args:
#   x: Either a full result object returned by check_lca(), or the summary data
#      frame stored in result$summary
#   digits: Number of digits used when rounding numeric columns
#
# Returns:
#   Invisibly returns the formatted table that was printed.
print_lca_summary <- function(x, digits = 3) {
  summary_df <- if (is.list(x) && !is.null(x$summary)) {
    x$summary
  } else {
    x
  }

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
