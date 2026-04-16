# Title:        LCA Model Fitting and Stability Assessment
# Purpose:      Functions for running latent class analysis with multiple
#               random starts, assessing convergence stability, and
#               recommending optimal class counts. Supports two engines:
#               poLCA (default) and tidySEM (OpenMx).
# Date created: 2026-04-15
# Dependencies: furrr, future, progressr, purrr, dplyr, cli, tibble,
#               vctrs, tidyr, and one of:
#                 - poLCA (method = "poLCA")
#                 - OpenMx + tidySEM (method = "tidySEM")

# ==============================================================================
# Setup
# ==============================================================================

library(furrr) # Parallel purrr using future backend
library(future) # Parallel backend
library(progressr) # Progress bars for parallel workers
library(purrr) # Typed map helpers
library(dplyr) # Data wrangling
library(cli) # User facing messages and warnings
library(tibble) # Tibble construction for label lookups

# Use all cores minus one so the machine stays responsive.
plan(
  multisession,
  workers = max(1, parallel::detectCores() - 1)
)


# ==============================================================================
# Shared Helper Functions
# ==============================================================================

# Safely extract a single value from a data frame row.
safe_extract <- function(df, col) {
  if (nrow(df) > 0 && col %in% names(df)) {
    df[[col]][1]
  } else {
    NA_real_
  }
}

safe_min <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  min(x)
}

safe_max <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  max(x)
}

safe_mean <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_real_)
  mean(x)
}

safe_sd <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) < 2) return(NA_real_)
  sd(x)
}

safe_range_diff <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) < 2) return(NA_real_)
  diff(range(x))
}


# Generate all permutations of a vector (Heap's non recursive algorithm).
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
# Backend Dispatch Helpers
# ==============================================================================
#
# Each of the following helpers dispatches to a backend specific implementation
# based on the class of the fitted model. poLCA returns an object with class
# "poLCA"; tidySEM/OpenMx returns an object that inherits from "MxModel".

detect_backend <- function(model) {
  if (inherits(model, "poLCA")) {
    "poLCA"
  } else if (inherits(model, "MxModel")) {
    "tidySEM"
  } else {
    NA_character_
  }
}


# ---- optimizer_converged -----------------------------------------------------

# A poLCA fit is considered converged if the EM loop stopped before hitting
# maxiter and produced a finite log likelihood.
optimizer_converged_polca <- function(model) {
  if (is.null(model)) return(FALSE)
  if (is.null(model$numiter) || is.null(model$maxiter)) return(FALSE)
  if (is.null(model$llik) || !is.finite(model$llik)) return(FALSE)
  isTRUE(model$numiter < model$maxiter)
}

# tidySEM/OpenMx convergence is reported via output$status$code; 0 means clean
# convergence.
optimizer_converged_tidysem <- function(model) {
  code <- model_status_code_tidysem(model)
  !is.na(code) && code == 0L
}

optimizer_converged <- function(model) {
  if (is.null(model)) return(FALSE)
  switch(
    detect_backend(model),
    poLCA = optimizer_converged_polca(model),
    tidySEM = optimizer_converged_tidysem(model),
    FALSE
  )
}


# ---- model_status_code -------------------------------------------------------

# Crude numeric status code: 0 = converged, 1 = not converged, NA = no model.
model_status_code_polca <- function(model) {
  if (is.null(model)) return(NA_integer_)
  if (optimizer_converged_polca(model)) 0L else 1L
}

model_status_code_tidysem <- function(model) {
  tryCatch(
    {
      code <- model$output$status$code
      if (length(code) == 0 || is.null(code)) {
        NA_integer_
      } else {
        as.integer(code[[1]])
      }
    },
    error = function(e) NA_integer_
  )
}

model_status_code <- function(model) {
  if (is.null(model)) return(NA_integer_)
  switch(
    detect_backend(model),
    poLCA = model_status_code_polca(model),
    tidySEM = model_status_code_tidysem(model),
    NA_integer_
  )
}


# ---- model_ll ----------------------------------------------------------------

model_ll_polca <- function(model) {
  if (is.null(model) || is.null(model$llik)) return(NA_real_)
  as.numeric(model$llik)
}

# OpenMx stores minus two times the log likelihood in output$fit.
model_ll_tidysem <- function(model) {
  tryCatch(-0.5 * model$output$fit, error = function(e) NA_real_)
}

model_ll <- function(model) {
  if (is.null(model)) return(NA_real_)
  switch(
    detect_backend(model),
    poLCA = model_ll_polca(model),
    tidySEM = model_ll_tidysem(model),
    NA_real_
  )
}


# ---- model_aic / model_bic ---------------------------------------------------

model_aic_polca <- function(model) {
  if (is.null(model) || is.null(model$aic)) return(NA_real_)
  as.numeric(model$aic)
}

model_bic_polca <- function(model) {
  if (is.null(model) || is.null(model$bic)) return(NA_real_)
  as.numeric(model$bic)
}

model_aic_tidysem <- function(model) {
  tryCatch(as.numeric(stats::AIC(model)), error = function(e) NA_real_)
}

model_bic_tidysem <- function(model) {
  tryCatch(as.numeric(stats::BIC(model)), error = function(e) NA_real_)
}

model_aic <- function(model) {
  if (is.null(model)) return(NA_real_)
  switch(
    detect_backend(model),
    poLCA = model_aic_polca(model),
    tidySEM = model_aic_tidysem(model),
    NA_real_
  )
}

model_bic <- function(model) {
  if (is.null(model)) return(NA_real_)
  switch(
    detect_backend(model),
    poLCA = model_bic_polca(model),
    tidySEM = model_bic_tidysem(model),
    NA_real_
  )
}


# ---- model_prob_min / model_n_min --------------------------------------------

model_prob_min_polca <- function(model) {
  if (is.null(model) || is.null(model$P)) return(NA_real_)
  min(model$P, na.rm = TRUE)
}

model_n_min_polca <- function(model) {
  if (is.null(model) || is.null(model$predclass) || is.null(model$P)) {
    return(NA_real_)
  }
  n_class <- length(model$P)
  min(tabulate(model$predclass, nbins = n_class))
}

model_prob_min_tidysem <- function(model) {
  tryCatch(
    {
      cp <- tidySEM::class_prob(model)
      if (!is.null(cp$model) && "Probability" %in% names(cp$model)) {
        min(cp$model$Probability, na.rm = TRUE)
      } else {
        NA_real_
      }
    },
    error = function(e) NA_real_
  )
}

model_n_min_tidysem <- function(model) {
  tryCatch(
    {
      cp <- tidySEM::class_prob(model)
      post <- as.matrix(cp$individual)
      if (nrow(post) == 0 || ncol(post) == 0) return(NA_real_)
      class_id <- max.col(post, ties.method = "first")
      min(tabulate(class_id, nbins = ncol(post)))
    },
    error = function(e) NA_real_
  )
}

model_prob_min <- function(model) {
  if (is.null(model)) return(NA_real_)
  switch(
    detect_backend(model),
    poLCA = model_prob_min_polca(model),
    tidySEM = model_prob_min_tidysem(model),
    NA_real_
  )
}

model_n_min <- function(model) {
  if (is.null(model)) return(NA_real_)
  switch(
    detect_backend(model),
    poLCA = model_n_min_polca(model),
    tidySEM = model_n_min_tidysem(model),
    NA_real_
  )
}


# ---- rel_entropy -------------------------------------------------------------

# Compute relative, normalized entropy for a fitted LCA.
# 1 means perfect class separation, 0 means no separation.
rel_entropy_polca <- function(model) {
  if (is.null(model) || is.null(model$posterior)) return(NA_real_)

  post <- as.matrix(model$posterior)
  n_class <- ncol(post)

  if (n_class < 2 || nrow(post) == 0) return(NA_real_)

  num <- -sum(post * log(post + 1e-10), na.rm = TRUE)
  deno <- nrow(post) * log(n_class)

  1 - (num / deno)
}

rel_entropy_tidysem <- function(model) {
  cp <- tidySEM::class_prob(model)
  post <- as.matrix(cp$individual)
  n_class <- ncol(post)

  num <- -sum(post * log(post + 1e-10), na.rm = TRUE)
  deno <- nrow(post) * log(n_class)

  1 - (num / deno)
}

rel_entropy <- function(model) {
  if (is.null(model)) return(NA_real_)
  switch(
    detect_backend(model),
    poLCA = rel_entropy_polca(model),
    tidySEM = rel_entropy_tidysem(model),
    NA_real_
  )
}


# ---- extract_class_probs -----------------------------------------------------

# Named list of numeric matrices, one per indicator.
# Row i is class i, column j is P(category j | class i).
extract_class_probs_polca <- function(model) {
  if (is.null(model) || is.null(model$probs)) {
    stop("Model has no probs component.")
  }
  lapply(model$probs, function(mat) {
    out <- as.matrix(mat)
    dimnames(out) <- NULL
    out
  })
}

extract_class_probs_tidysem <- function(model) {
  tp <- tryCatch(
    tidySEM::table_prob(model),
    error = function(e) stop("table_prob() failed: ", e$message)
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

    mat <- matrix(NA_real_, nrow = n_cls, ncol = n_cats)

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

extract_class_probs <- function(model) {
  switch(
    detect_backend(model),
    poLCA = extract_class_probs_polca(model),
    tidySEM = extract_class_probs_tidysem(model),
    stop("Unknown model backend in extract_class_probs().")
  )
}


# ---- predict_lca_class -------------------------------------------------------

# Modal class assignments (integer vector, one per row of the data used to
# fit the model).
predict_lca_class_polca <- function(model) {
  if (is.null(model) || is.null(model$predclass)) {
    stop("Model has no predclass component.")
  }
  as.integer(model$predclass)
}

predict_lca_class_tidysem <- function(model) {
  cp <- tidySEM::class_prob(model)
  post <- as.matrix(cp$individual)
  if (nrow(post) == 0 || ncol(post) == 0) {
    stop("class_prob() returned an empty posterior matrix.")
  }
  as.integer(max.col(post, ties.method = "first"))
}

predict_lca_class <- function(model) {
  switch(
    detect_backend(model),
    poLCA = predict_lca_class_polca(model),
    tidySEM = predict_lca_class_tidysem(model),
    stop("Unknown model backend in predict_lca_class().")
  )
}


# ---- model_class_probs -------------------------------------------------------

# Class prevalence (mixing proportions) as a numeric vector.
model_class_probs_polca <- function(model) {
  if (is.null(model) || is.null(model$P)) return(NA_real_)
  as.numeric(model$P)
}

model_class_probs_tidysem <- function(model) {
  cp <- tidySEM::class_prob(model)
  as.numeric(cp$model$Probability)
}

model_class_probs <- function(model) {
  switch(
    detect_backend(model),
    poLCA = model_class_probs_polca(model),
    tidySEM = model_class_probs_tidysem(model),
    stop("Unknown model backend in model_class_probs().")
  )
}


# ==============================================================================
# poLCA backend
# ==============================================================================

# Build a poLCA formula (cbind(y1, y2, ...) ~ 1) from a data frame.
make_lca_formula <- function(data) {
  vars <- names(data)
  as.formula(
    paste0("cbind(", paste(vars, collapse = ", "), ") ~ 1")
  )
}


# Coerce indicator variables to integer codes starting at 1.
# poLCA requires integers with no zeros and no gaps.
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


# Fit one random start across the full class range using poLCA.
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

    # Re-seed per (run, k) so each cell is reproducible and runs differ.
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
            "Run ", run, " class ", k, " failed: ", conditionMessage(e)
          )
        }
        NULL
      }
    )

    models[[i]] <- model
  }

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

      conv <- optimizer_converged_polca(mod)

      ent_val <- if (conv) {
        tryCatch(rel_entropy_polca(mod), error = function(e) NA_real_)
      } else {
        NA_real_
      }

      data.frame(
        run = run,
        classes = k,
        status_code = if (conv) 0L else 1L,
        optimizer_converged = conv,
        LL = model_ll_polca(mod),
        AIC = model_aic_polca(mod),
        BIC = model_bic_polca(mod),
        Entropy = ent_val,
        n_min = model_n_min_polca(mod),
        prob_min = model_prob_min_polca(mod)
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
# tidySEM backend
# ==============================================================================

# Fit one random start across the full class range using tidySEM::mx_lca.
fit_one_tidysem_run <- function(
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

  requireNamespace("OpenMx", quietly = TRUE)
  requireNamespace("tidySEM", quietly = TRUE)

  # Keep OpenMx single threaded so parallel workers do not compete.
  OpenMx::mxOption(NULL, "Number of Threads", 1)

  requested_classes <- min_classes:max_classes

  raw_models <- tryCatch(
    {
      models <- NULL

      invisible(capture.output(
        suppressMessages({
          models <- lapply(
            requested_classes,
            function(k) tidySEM::mx_lca(data, classes = k)
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
        "Run ", run, " returned an unexpected object of class: ",
        paste(class(raw_models), collapse = ", ")
      )
    }
    return(NULL)
  }

  models <- raw_models

  for (i in seq_along(models)) {
    mod <- models[[i]]

    if (is.null(mod)) next

    if (!optimizer_converged_tidysem(mod) && try_hard) {
      mod <- tryCatch(
        OpenMx::mxTryHard(
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
    tidySEM::table_fit(models),
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
        "Run ", run,
        " returned no models in requested class range ",
        min_classes, " to ", max_classes, "."
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

      if (is.null(mod)) return(NULL)

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

      if (is.na(aic_val)) aic_val <- model_aic_tidysem(mod)
      if (is.na(bic_val)) bic_val <- model_bic_tidysem(mod)
      if (is.na(ent_val) && optimizer_converged_tidysem(mod)) {
        ent_val <- tryCatch(
          rel_entropy_tidysem(mod),
          error = function(e) NA_real_
        )
      }
      if (is.na(n_min_val)) n_min_val <- model_n_min_tidysem(mod)
      if (is.na(prob_min_val)) prob_min_val <- model_prob_min_tidysem(mod)

      data.frame(
        run = run,
        classes = k,
        status_code = model_status_code_tidysem(mod),
        optimizer_converged = optimizer_converged_tidysem(mod),
        LL = model_ll_tidysem(mod),
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
# Stability Assessment (backend agnostic)
# ==============================================================================

# Compare only the runs that reached the best log likelihood and check whether
# their class specific response probabilities are similar after class labels are
# aligned.
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
    extract_class_probs(best_models[[1]]),
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
      extract_class_probs(best_models[[i]]),
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

  if (length(models) == 0) return(out_empty)

  conv_mask <- purrr::map_lgl(models, optimizer_converged)
  conv_models <- models[conv_mask]
  conv_runs <- run_idx[conv_mask]

  if (length(conv_models) == 0) return(out_empty)

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
#   data: Data frame of indicator variables. When method = "poLCA" these are
#     coerced to integers with prepare_lca_data(). When method = "tidySEM" they
#     should already be ordered factors as tidySEM::mx_lca() requires.
#   method: Which backend to use, "poLCA" (default) or "tidySEM".
#   min_classes / max_classes: Class count range to fit.
#   n_runs: Number of random start runs.
#   base_seed: Base seed so runs are reproducible.
#   entropy_threshold: Entropy cutoff used only when use_entropy_filter is TRUE.
#   param_threshold: Largest acceptable probability cell difference among
#     replicated best runs.
#   return_fit_table: If TRUE, include the full per run fit table.
#   verbose: If TRUE, print detailed diagnostics.
#   loglik_tol: Tolerance for deciding whether two log likelihoods match. If
#     NULL, defaults to 1e-4 for poLCA and 1e-6 for tidySEM.
#   min_best_replications: Minimum best LL replications for a stable model.
#   min_replication_rate: Minimum fraction of converged runs reaching best LL.
#   use_entropy_filter: If TRUE, apply entropy_threshold as a hard gatekeeper.
#
# poLCA-only args:
#   maxiter, tol, nrep_per_call
#
# tidySEM-only args:
#   try_hard, extra_tries, convergence_distance (kept for backward compat)
#
# Returns:
#   List with recommended_classes, recommendation_reason, best_model, summary,
#   stability_details, all_models, method, and optionally fit_table.
check_lca <- function(
  data,
  method = c("poLCA", "tidySEM"),
  min_classes = 2,
  max_classes = 7,
  n_runs = 25,
  base_seed = 42,
  entropy_threshold = 0.80,
  param_threshold = 0.05,
  return_fit_table = FALSE,
  verbose = FALSE,
  loglik_tol = NULL,
  min_best_replications = 5,
  min_replication_rate = 0.50,
  use_entropy_filter = FALSE,
  # poLCA-only
  maxiter = 3000,
  tol = 1e-10,
  nrep_per_call = 1,
  # tidySEM-only
  try_hard = FALSE,
  extra_tries = 20,
  convergence_distance = 0.1
) {
  method <- match.arg(method)

  if (method == "poLCA" && !requireNamespace("poLCA", quietly = TRUE)) {
    cli::cli_abort("Package 'poLCA' is required for method = 'poLCA'.")
  }
  if (method == "tidySEM") {
    if (!requireNamespace("tidySEM", quietly = TRUE)) {
      cli::cli_abort("Package 'tidySEM' is required for method = 'tidySEM'.")
    }
    if (!requireNamespace("OpenMx", quietly = TRUE)) {
      cli::cli_abort("Package 'OpenMx' is required for method = 'tidySEM'.")
    }
    OpenMx::mxOption(NULL, "Number of Threads", 1)
  }

  if (is.null(loglik_tol)) {
    loglik_tol <- switch(method, poLCA = 1e-4, tidySEM = 1e-6)
  }

  # Prepare data and any backend specific state.
  fit_args <- switch(
    method,
    poLCA = {
      data_prepped <- prepare_lca_data(data)
      formula <- make_lca_formula(data_prepped)
      list(data = data_prepped, formula = formula)
    },
    tidySEM = list(data = data)
  )

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

        switch(
          method,
          poLCA = fit_one_poLCA_run(
            data = fit_args$data,
            formula = fit_args$formula,
            min_classes = min_classes,
            max_classes = max_classes,
            run = run,
            base_seed = base_seed,
            maxiter = maxiter,
            tol = tol,
            nrep_per_call = nrep_per_call,
            verbose = verbose
          ),
          tidySEM = fit_one_tidysem_run(
            data = fit_args$data,
            min_classes = min_classes,
            max_classes = max_classes,
            run = run,
            base_seed = base_seed,
            try_hard = try_hard,
            extra_tries = extra_tries,
            verbose = verbose
          )
        )
      },
      .options = furrr::furrr_options(seed = TRUE)
    )
  })

  fit_rows_list <- list()
  fit_idx <- 0L

  for (res in run_results) {
    if (is.null(res)) next

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
      if (is.null(row_obj)) next
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
  cat(sprintf("Backend                       : %s\n", method))
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
    all_models = all_models,
    method = method
  )

  if (return_fit_table) {
    result$fit_table <- all_results
  }

  invisible(result)
}


# ==============================================================================
# Class Assignment
# ==============================================================================

# Add predicted LCA class membership as a new column to a data frame.
#
# Modal class labels are attached to model_data first (row aligned with the
# model's predicted classes), then joined onto data using the indicator
# columns shared by both frames. Rows in data whose indicator pattern is not
# present in model_data get NA.
#
# Args:
#   model: A check_lca() result list or a fitted LCA model (e.g.,
#     check_lca_result$best_model, a poLCA or MxModel object).
#   data: Data frame to add the predicted class column to.
#   model_data: Data frame of indicators passed to check_lca(). All columns
#     are used as join keys and must also exist in data. Row order must
#     match the model (do not reorder or drop rows after fitting).
#   var_name: Name of the new column to create in data.
#   class_names: Optional named numeric vector mapping human readable labels
#     to expected class prevalences. Each label is matched to the model's
#     estimated class proportions by minimizing total absolute difference
#     across all permutations. If NULL, labels default to "Class 1",
#     "Class 2", etc.
#
# Returns:
#   data with a new factor column named var_name. Non matching rows are NA.
add_lca_class <- function(
  model,
  data,
  model_data,
  var_name,
  class_names = NULL
) {
  fitted <- if (inherits(model, "poLCA") || inherits(model, "MxModel")) {
    model
  } else if (is.list(model) && "best_model" %in% names(model)) {
    model$best_model
  } else {
    NULL
  }

  if (is.null(fitted)) {
    cli::cli_abort("No fitted LCA model found in `model`.")
  }

  backend <- detect_backend(fitted)
  if (is.na(backend)) {
    cli::cli_abort("Unknown model backend. Expected a poLCA or MxModel object.")
  }

  pred_class <- predict_lca_class(fitted)

  if (length(pred_class) != nrow(model_data)) {
    cli::cli_abort(paste0(
      "model_data has ", nrow(model_data), " rows but the model produced ",
      length(pred_class), " predicted classes. Pass the exact data frame ",
      "used in check_lca() with the same rows."
    ))
  }

  join_cols <- names(model_data)
  missing_cols <- setdiff(join_cols, names(data))
  if (length(missing_cols) > 0) {
    cli::cli_abort(paste0(
      "`data` is missing columns from `model_data`: ",
      paste(missing_cols, collapse = ", ")
    ))
  }

  n_class <- length(model_class_probs(fitted))

  labels <- if (is.null(class_names)) {
    paste0("Class ", seq_len(n_class))
  } else {
    if (length(class_names) != n_class) {
      cli::cli_abort(paste0(
        "`class_names` has ", length(class_names), " entries but the model ",
        "has ", n_class, " classes."
      ))
    }
    if (is.null(names(class_names)) || any(names(class_names) == "")) {
      cli::cli_abort("`class_names` must be a fully named vector.")
    }

    model_probs <- model_class_probs(fitted)
    user_probs <- as.numeric(class_names)
    user_names <- names(class_names)

    # Find the permutation of user labels that best matches model prevalences.
    perms <- permn(seq_len(n_class))
    best_perm <- seq_len(n_class)
    min_dist <- Inf

    for (perm in perms) {
      d <- sum(abs(model_probs - user_probs[perm]))
      if (d < min_dist) {
        min_dist <- d
        best_perm <- perm
      }
    }

    user_names[best_perm]
  }

  md_joined <- model_data[, join_cols, drop = FALSE]
  md_joined[[var_name]] <- factor(labels[pred_class], levels = labels)

  # Align factor/ordered class with data so the join does not fail on
  # cosmetically different but semantically identical factor types.
  for (col in join_cols) {
    x_col <- data[[col]]
    y_col <- md_joined[[col]]
    if (
      is.factor(x_col) && is.factor(y_col) &&
        (!identical(levels(x_col), levels(y_col)) ||
          is.ordered(x_col) != is.ordered(y_col))
    ) {
      md_joined[[col]] <- factor(
        as.character(y_col),
        levels = levels(x_col),
        ordered = is.ordered(x_col)
      )
    }
  }

  dup_mask <- duplicated(md_joined[, join_cols, drop = FALSE])
  md_joined <- md_joined[!dup_mask, , drop = FALSE]

  dplyr::left_join(data, md_joined, by = join_cols)
}


# ==============================================================================
# Output Formatting
# ==============================================================================

# Format LCA class probabilities as a labeled wide table.
tidy_lca_probs <- function(model, data) {
  switch(
    detect_backend(model),
    poLCA = tidy_lca_probs_polca(model, data),
    tidySEM = tidy_lca_probs_tidysem(model, data),
    stop("Unknown model backend in tidy_lca_probs().")
  )
}


tidy_lca_probs_polca <- function(model, data) {
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
        if (!var %in% names(data)) return(var)
        label <- attr_var_label(data[[var]])
        if (is.null(label) || label == "" || is.na(label)) var else label
      }
    )
  )

  value_label_lookup_list <- purrr::map(
    unique(df$variable),
    \(x) {
      if (!x %in% names(data)) return(NULL)
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


tidy_lca_probs_tidysem <- function(model, data) {
  df <- tidySEM::table_prob(model) |>
    dplyr::rename(
      variable = Variable,
      outcome = Category,
      estimate = Probability,
      class = group
    ) |>
    dplyr::mutate(outcome = as.integer(outcome))

  variable_label_lookup <- tibble::tibble(
    variable = unique(df$variable),
    variable_label = sapply(
      unique(df$variable),
      \(var) {
        label <- attr_var_label(data[[var]])
        if (is.null(label) || label == "" || is.na(label)) var else label
      }
    )
  )

  value_label_lookup_list <- purrr::map(
    unique(df$variable),
    \(x) {
      labels <- attr_val_labels(data[[x]])

      if (!is.null(labels)) {
        tibble::tibble(
          variable = x,
          outcome = unname(labels),
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

  value_label_lookup <- vctrs::vec_rbind(!!!value_label_lookup_list)

  df <- df |>
    dplyr::left_join(variable_label_lookup, by = "variable") |>
    dplyr::left_join(value_label_lookup, by = c("variable", "outcome")) |>
    dplyr::mutate(
      class = gsub("class", "Class ", class, fixed = TRUE),
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
