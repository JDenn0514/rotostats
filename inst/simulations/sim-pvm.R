#!/usr/bin/env Rscript
# sim-pvm.R
# Monte Carlo Simulation Harness for pvm()
#
# Implements four studies per sim-spec.md for request pvm-2026-04-23:
#
#   Study 1 — Sum-to-1 invariant under pool-size variation (rate_pool = "ip_weighted")
#   Study 2 — Pool denominator signal under rate_pool variation (all three options)
#   Study 3 — Sub-replacement sensitivity (clip vs negative parity)
#   Study 4 — Concentration warning threshold calibration
#
# Usage:
#   Rscript inst/simulations/sim-pvm.R
#
# Environment variables:
#   STATSCLAW_RUN_DIR  — where simulation.md is written
#   SIM_PVM_PRECHECK_ONLY — if "1", run only small-R pre-checks (default: full run)
#
# Requires: devtools::load_all() to expose pvm() and league_config().
#
# Seeds: Master seed 20260423. Per-replication seed:
#   master_seed + scenario_index * 1000 + replication_index
# (per sim-spec.md §Seed Strategy)

# ---------------------------------------------------------------------------
# 0. Setup
# ---------------------------------------------------------------------------

SCRIPT_DIR <- tryCatch(
  normalizePath(dirname(sys.frame(1L)$ofile), mustWork = FALSE),
  error = function(e) ""
)
if (!nzchar(SCRIPT_DIR)) {
  SCRIPT_DIR <- normalizePath("inst/simulations", mustWork = FALSE)
}
REPO_ROOT <- normalizePath(file.path(SCRIPT_DIR, "../.."), mustWork = FALSE)

# Load the package so pvm() and league_config() are available.
# Use tryCatch to survive load-time execution errors in sgp.R (a transient
# builder-side issue where sgp() is called at package top-level in R/sgp.R).
# Once builder fixes that and adds R/pvm.R, load_all() will succeed cleanly.
pkg_loaded <- tryCatch({
  if (requireNamespace("devtools", quietly = TRUE)) {
    devtools::load_all(REPO_ROOT, quiet = TRUE)
    TRUE
  } else {
    library(rotostats)
    TRUE
  }
}, error = function(e) {
  message("Note: devtools::load_all() failed (", conditionMessage(e),
          "). Falling back to partial source load.")
  FALSE
})

if (!pkg_loaded) {
  # Partial fallback: source only the subset of R/ files needed by the DGP
  # and the pvm() interface. This allows smoke runs to proceed for DGP testing
  # even when the full package has transient load errors.
  r_files_needed <- c(
    "R/inverse-categories.R",
    "R/league-config.R"
    # R/pvm.R is sourced separately below when available
  )
  for (f in r_files_needed) {
    fp <- file.path(REPO_ROOT, f)
    if (file.exists(fp)) {
      tryCatch(source(fp), error = function(e)
        message("  Could not source ", f, ": ", conditionMessage(e)))
    }
  }
  # Try sourcing pvm.R if builder has written it
  pvm_path <- file.path(REPO_ROOT, "R", "pvm.R")
  if (file.exists(pvm_path)) {
    tryCatch(source(pvm_path), error = function(e)
      message("  Could not source R/pvm.R: ", conditionMessage(e)))
  }
}

# Source DGP helper (pvm-specific)
source(file.path(SCRIPT_DIR, "dgp", "dgp_pvm.R"))

# Run directory for output artifacts
RUN_DIR <- Sys.getenv(
  "STATSCLAW_RUN_DIR",
  unset = "/Users/jacobdennen/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/pvm-2026-04-23"
)

# ---------------------------------------------------------------------------
# 1. Constants and seed helpers
# ---------------------------------------------------------------------------

MASTER_SEED <- 20260423L
R_STUDY1    <- 200L   # replications per scenario, Study 1
R_STUDY2    <- 200L   # replications per scenario, Study 2
R_STUDY3    <- 100L   # replications per scenario, Study 3
R_STUDY4    <- 100L   # replications per scenario, Study 4

PRECHECK_R1 <- 50L    # Study 1 pre-check R
PRECHECK_R2 <- 30L    # Study 2 pre-check R
PRECHECK_R3 <- 20L    # Study 3 pre-check R
PRECHECK_R4 <- 25L    # Study 4 pre-check R

BASELINE_FIXED <- c(ERA = 4.20, WHIP = 1.30, AVG = 0.265)

PRECHECK_ONLY <- isTRUE(Sys.getenv("SIM_PVM_PRECHECK_ONLY") == "1")

#' Derive per-replication seed deterministically.
#'
#' @param scenario_index Integer scenario index (1-based across all scenarios
#'   within the study).
#' @param replication Integer replication index.
#' @return Integer seed.
#' @noRd
rep_seed <- function(scenario_index, replication) {
  MASTER_SEED + as.integer(scenario_index) * 1000L + as.integer(replication)
}

# ---------------------------------------------------------------------------
# 2. Safe pvm() wrapper
# ---------------------------------------------------------------------------

#' Run pvm() and return a list with result, warnings fired, and failure flag.
#'
#' Captures conditions so warning fire rates can be measured without aborting.
#'
#' @param ... Arguments forwarded to pvm().
#' @return List: result (NULL on error), failed (logical), warnings (character
#'   vector of warning class names), error_msg (character or NULL).
#' @noRd
safe_pvm <- function(...) {
  warnings_seen <- character(0)

  result <- withCallingHandlers(
    tryCatch(
      pvm(...),
      error = function(e) {
        structure(list(error_msg = conditionMessage(e), failed = TRUE),
                  class = "pvm_error_result")
      }
    ),
    warning = function(w) {
      cls <- class(w)
      warnings_seen <<- c(warnings_seen, cls)
      invokeRestart("muffleWarning")
    }
  )

  if (inherits(result, "pvm_error_result")) {
    return(list(result = NULL, failed = TRUE,
                warnings = warnings_seen,
                error_msg = result$error_msg))
  }

  list(result = result, failed = FALSE, warnings = warnings_seen,
       error_msg = NULL)
}

#' Check whether a specific warning class was fired.
#'
#' @param warnings_vec Character vector of warning class names.
#' @param class_name Character scalar.
#' @return Logical.
#' @noRd
warning_fired <- function(warnings_vec, class_name) {
  any(class_name %in% warnings_vec)
}

# ---------------------------------------------------------------------------
# 3. Study 1 — Sum-to-1 Invariant Under Pool Size Variation
# ---------------------------------------------------------------------------

run_study_1 <- function(R = R_STUDY1, label = "FULL") {
  message(sprintf("\n== Study 1: Sum-to-1 invariant [%s, R=%d per scenario] ==", label, R))
  t0 <- proc.time()["elapsed"]

  n_teams_vals    <- c(8L, 10L, 12L, 14L, 16L)
  sub_rep_vals    <- c("clip", "negative")
  cat_pct_vals    <- c("auto", "equal")

  scenarios <- expand.grid(
    n_teams         = n_teams_vals,
    sub_replacement = sub_rep_vals,
    cat_pct         = cat_pct_vals,
    stringsAsFactors = FALSE
  )
  scenarios$scenario_id <- paste0("S1_n", scenarios$n_teams, "_",
                                   scenarios$sub_replacement, "_",
                                   scenarios$cat_pct)
  n_scenarios <- nrow(scenarios)

  results <- vector("list", n_scenarios)

  for (si in seq_len(n_scenarios)) {
    sc   <- scenarios[si, ]
    sc_n <- sc$n_teams
    sc_s <- sc$sub_replacement
    sc_c <- sc$cat_pct

    if ((si - 1L) %% 5L == 0L) {
      message(sprintf("  Scenario %d/%d: n=%d sub=%s cat=%s",
                      si, n_scenarios, sc_n, sc_s, sc_c))
    }

    sum_dev_clip     <- matrix(NA_real_, nrow = R, ncol = 10L)
    pos_sum_dev_neg  <- matrix(NA_real_, nrow = R, ncol = 10L)
    warn_sum_fired   <- logical(R)
    pvm_errors       <- logical(R)

    for (r in seq_len(R)) {
      seed_r <- rep_seed(si, r)
      repl   <- tryCatch(
        dgp_pvm(seed_r, n_teams = sc_n),
        error = function(e) NULL
      )
      if (is.null(repl)) {
        pvm_errors[r] <- TRUE
        next
      }

      res <- safe_pvm(
        replacement     = repl,
        include_raw     = FALSE,
        cat_pct         = sc_c,
        rate_pool       = "ip_weighted",
        sub_replacement = sc_s
      )

      if (res$failed) {
        pvm_errors[r] <- TRUE
        next
      }

      pvm_df <- res$result
      warn_sum_fired[r] <- warning_fired(res$warnings,
                                          "rotostats_warning_pvm_sum")

      # Extract pvm columns (columns named pvm_*)
      pvm_cols <- grep("^pvm_", names(pvm_df), value = TRUE)
      n_cats   <- length(pvm_cols)
      if (n_cats == 0L) {
        pvm_errors[r] <- TRUE
        next
      }
      # Resize storage if needed
      if (ncol(sum_dev_clip) != n_cats) {
        sum_dev_clip    <- matrix(NA_real_, nrow = R, ncol = n_cats)
        pos_sum_dev_neg <- matrix(NA_real_, nrow = R, ncol = n_cats)
      }

      for (ci in seq_len(n_cats)) {
        col_vals <- pvm_df[[pvm_cols[ci]]]
        if (sc_s == "clip") {
          sum_dev_clip[r, ci] <- abs(sum(col_vals, na.rm = TRUE) - 1.0)
        } else {
          # negative mode: check sum of positive contributors
          pos_vals <- col_vals[!is.na(col_vals) & col_vals > 0]
          if (length(pos_vals) > 0L) {
            pos_sum_dev_neg[r, ci] <- abs(sum(pos_vals) - 1.0)
          } else {
            pos_sum_dev_neg[r, ci] <- NA_real_
          }
        }
      }
    }

    max_sum_dev_clip    <- if (sc_s == "clip") {
      max(sum_dev_clip, na.rm = TRUE)
    } else NA_real_
    max_pos_sum_dev_neg <- if (sc_s == "negative") {
      max(pos_sum_dev_neg, na.rm = TRUE)
    } else NA_real_

    results[[si]] <- list(
      scenario_id         = sc$scenario_id,
      n_teams             = sc_n,
      sub_replacement     = sc_s,
      cat_pct             = sc_c,
      R                   = R,
      sum_dev_clip        = sum_dev_clip,
      pos_sum_dev_neg     = pos_sum_dev_neg,
      max_sum_dev_clip    = max_sum_dev_clip,
      max_pos_sum_dev_neg = max_pos_sum_dev_neg,
      warn_sum_fire_rate  = mean(warn_sum_fired, na.rm = TRUE),
      error_rate          = mean(pvm_errors)
    )
  }

  elapsed <- as.numeric(proc.time()["elapsed"] - t0)
  list(scenarios = scenarios, results = results, elapsed_sec = elapsed)
}

# ---------------------------------------------------------------------------
# 4. Acceptance evaluation — Study 1
# ---------------------------------------------------------------------------

evaluate_study_1 <- function(res1) {
  rlist <- res1$results
  n     <- length(rlist)

  # Aggregate across all scenarios
  all_max_clip <- vapply(rlist, function(x) {
    if (is.na(x$max_sum_dev_clip)) -1 else x$max_sum_dev_clip
  }, numeric(1L))
  all_max_neg <- vapply(rlist, function(x) {
    if (is.na(x$max_pos_sum_dev_neg)) -1 else x$max_pos_sum_dev_neg
  }, numeric(1L))
  all_warn_rate  <- vapply(rlist, `[[`, numeric(1L), "warn_sum_fire_rate")
  all_error_rate <- vapply(rlist, `[[`, numeric(1L), "error_rate")

  clip_pass <- all(all_max_clip[all_max_clip >= 0] < 1e-10)
  neg_pass  <- all(all_max_neg[all_max_neg >= 0] < 1e-10)
  warn_pass <- all(all_warn_rate == 0.0)
  err_pass  <- all(all_error_rate == 0.0)

  list(
    clip_pass   = clip_pass,
    neg_pass    = neg_pass,
    warn_pass   = warn_pass,
    err_pass    = err_pass,
    overall     = clip_pass && neg_pass && warn_pass && err_pass,
    max_clip_deviation  = max(all_max_clip[all_max_clip >= 0], na.rm = TRUE),
    max_neg_deviation   = max(all_max_neg[all_max_neg >= 0],   na.rm = TRUE),
    max_warn_rate       = max(all_warn_rate),
    max_error_rate      = max(all_error_rate)
  )
}

# ---------------------------------------------------------------------------
# 5. Study 2 — Pool Denominator Signal Under rate_pool Variation
# ---------------------------------------------------------------------------

run_study_2 <- function(R = R_STUDY2, label = "FULL") {
  message(sprintf("\n== Study 2: Pool denominator signal [%s, R=%d per scenario] ==",
                  label, R))
  t0 <- proc.time()["elapsed"]

  rate_pool_vals  <- c("ip_weighted", "pool_average", "fixed_baseline")
  sub_rep_vals    <- c("clip", "negative")
  n_teams_vals    <- c(10L, 12L, 14L)

  scenarios <- expand.grid(
    rate_pool       = rate_pool_vals,
    sub_replacement = sub_rep_vals,
    n_teams         = n_teams_vals,
    stringsAsFactors = FALSE
  )
  scenarios$scenario_id <- paste0("S2_", scenarios$rate_pool, "_",
                                   scenarios$sub_replacement, "_n",
                                   scenarios$n_teams)
  n_scenarios <- nrow(scenarios)

  results <- vector("list", n_scenarios)

  for (si in seq_len(n_scenarios)) {
    sc      <- scenarios[si, ]
    sc_n    <- sc$n_teams
    sc_s    <- sc$sub_replacement
    sc_rp   <- sc$rate_pool

    if ((si - 1L) %% 6L == 0L) {
      message(sprintf("  Scenario %d/%d: rate_pool=%s sub=%s n=%d",
                      si, n_scenarios, sc_rp, sc_s, sc_n))
    }

    sum_dev     <- matrix(NA_real_, nrow = R, ncol = 10L)
    pvm_errors  <- logical(R)

    for (r in seq_len(R)) {
      # offset scenario index to avoid seed collision with Study 1
      seed_r <- rep_seed(100L + si, r)
      repl   <- tryCatch(
        dgp_pvm(seed_r, n_teams = sc_n,
                baseline = if (sc_rp == "fixed_baseline") BASELINE_FIXED else NULL),
        error = function(e) NULL
      )
      if (is.null(repl)) {
        pvm_errors[r] <- TRUE
        next
      }

      bl_arg <- if (sc_rp == "fixed_baseline") BASELINE_FIXED else NULL

      res <- safe_pvm(
        replacement     = repl,
        include_raw     = FALSE,
        cat_pct         = "auto",
        rate_pool       = sc_rp,
        sub_replacement = sc_s,
        baseline        = bl_arg
      )

      if (res$failed) {
        pvm_errors[r] <- TRUE
        next
      }

      pvm_df   <- res$result
      pvm_cols <- grep("^pvm_", names(pvm_df), value = TRUE)
      n_cats   <- length(pvm_cols)
      if (n_cats == 0L) {
        pvm_errors[r] <- TRUE
        next
      }
      if (ncol(sum_dev) != n_cats) {
        sum_dev <- matrix(NA_real_, nrow = R, ncol = n_cats)
      }

      for (ci in seq_len(n_cats)) {
        col_vals <- pvm_df[[pvm_cols[ci]]]
        if (sc_s == "clip") {
          sum_dev[r, ci] <- abs(sum(col_vals[!is.na(col_vals) & col_vals >= 0]) - 1.0)
        } else {
          pos_vals <- col_vals[!is.na(col_vals) & col_vals > 0]
          if (length(pos_vals) > 0L) {
            sum_dev[r, ci] <- abs(sum(pos_vals) - 1.0)
          } else {
            sum_dev[r, ci] <- NA_real_
          }
        }
      }
    }

    results[[si]] <- list(
      scenario_id     = sc$scenario_id,
      n_teams         = sc_n,
      rate_pool       = sc_rp,
      sub_replacement = sc_s,
      R               = R,
      sum_dev         = sum_dev,
      max_sum_dev     = max(sum_dev, na.rm = TRUE),
      error_rate      = mean(pvm_errors)
    )
  }

  elapsed <- as.numeric(proc.time()["elapsed"] - t0)
  list(scenarios = scenarios, results = results, elapsed_sec = elapsed)
}

# ---------------------------------------------------------------------------
# 6. Acceptance evaluation — Study 2
# ---------------------------------------------------------------------------

evaluate_study_2 <- function(res2) {
  rlist <- res2$results

  by_option <- lapply(c("ip_weighted", "pool_average", "fixed_baseline"), function(opt) {
    opt_res <- Filter(function(x) x$rate_pool == opt, rlist)
    max_dev <- max(vapply(opt_res, `[[`, numeric(1L), "max_sum_dev"), na.rm = TRUE)
    err_rate <- max(vapply(opt_res, `[[`, numeric(1L), "error_rate"))
    list(
      rate_pool    = opt,
      max_sum_dev  = max_dev,
      pass_sum     = max_dev < 1e-10,
      max_err_rate = err_rate,
      pass_err     = err_rate == 0.0
    )
  })
  names(by_option) <- vapply(by_option, `[[`, character(1L), "rate_pool")

  overall <- all(vapply(by_option, function(x) x$pass_sum && x$pass_err, logical(1L)))

  list(by_option = by_option, overall = overall)
}

# ---------------------------------------------------------------------------
# 7. Study 3 — Sub-Replacement Sensitivity
# ---------------------------------------------------------------------------

run_study_3 <- function(R = R_STUDY3, label = "FULL") {
  message(sprintf("\n== Study 3: Sub-replacement sensitivity [%s, R=%d per scenario] ==",
                  label, R))
  t0 <- proc.time()["elapsed"]

  n_teams_vals   <- c(10L, 12L)
  rate_pool_vals <- c("ip_weighted", "pool_average")

  scenarios <- expand.grid(
    n_teams   = n_teams_vals,
    rate_pool = rate_pool_vals,
    stringsAsFactors = FALSE
  )
  scenarios$scenario_id <- paste0("S3_n", scenarios$n_teams, "_", scenarios$rate_pool)
  n_scenarios <- nrow(scenarios)

  results <- vector("list", n_scenarios)

  for (si in seq_len(n_scenarios)) {
    sc    <- scenarios[si, ]
    sc_n  <- sc$n_teams
    sc_rp <- sc$rate_pool

    message(sprintf("  Scenario %d/%d: n=%d rate_pool=%s",
                    si, n_scenarios, sc_n, sc_rp))

    max_abs_diff_all  <- numeric(R)
    clip_subr_nonzero <- logical(R)  # clip sub-replacement pvm != 0
    neg_subr_positive <- logical(R)  # negative sub-replacement pvm >= 0
    pvm_errors        <- logical(R)

    for (r in seq_len(R)) {
      seed_r <- rep_seed(200L + si, r)
      repl   <- tryCatch(
        dgp_pvm(seed_r, n_teams = sc_n),
        error = function(e) NULL
      )
      if (is.null(repl)) {
        pvm_errors[r] <- TRUE
        next
      }

      res_clip <- safe_pvm(replacement = repl, rate_pool = sc_rp,
                            sub_replacement = "clip",   cat_pct = "auto")
      res_neg  <- safe_pvm(replacement = repl, rate_pool = sc_rp,
                            sub_replacement = "negative", cat_pct = "auto")

      if (res_clip$failed || res_neg$failed) {
        pvm_errors[r] <- TRUE
        next
      }

      clip_df <- res_clip$result
      neg_df  <- res_neg$result

      pvm_cols <- grep("^pvm_", names(clip_df), value = TRUE)
      if (length(pvm_cols) == 0L) {
        pvm_errors[r] <- TRUE
        next
      }

      # Per-category comparison per sim-spec §3.4:
      # For each category c, above-replacement = clip_df[i, c] > 0.
      # Those players must have identical pvm in clip vs negative (< 1e-12).
      # Sub-replacement = clip_df[i, c] == 0 → clip must be 0, neg must be < 0.
      cat_diffs    <- numeric(0L)
      any_clip_nonzero_sub <- FALSE
      any_neg_pos_sub      <- FALSE

      for (col_nm in pvm_cols) {
        clip_vals <- clip_df[[col_nm]]
        neg_vals  <- neg_df[[col_nm]]
        if (is.null(clip_vals) || is.null(neg_vals)) next

        above_mask_cat <- !is.na(clip_vals) & clip_vals > 0
        sub_mask_cat   <- !is.na(clip_vals) & clip_vals == 0

        if (any(above_mask_cat)) {
          cat_diffs <- c(cat_diffs,
            abs(clip_vals[above_mask_cat] - neg_vals[above_mask_cat]))
        }
        if (any(sub_mask_cat)) {
          # Under clip: sub-replacement must be exactly 0
          if (any(clip_vals[sub_mask_cat] != 0, na.rm = TRUE))
            any_clip_nonzero_sub <- TRUE
          # Under negative: sub-replacement must be strictly <= 0 (not positive).
          # Players exactly at replacement (contrib = 0) have pvm = 0 in BOTH
          # modes and are not violations — they are neither above nor below.
          # Per spec §3.4, only strictly-below-replacement players get negative
          # pvm under "negative" mode. We check that no sub-repl player is
          # STRICTLY POSITIVE (> 0), which would be a genuine violation.
          neg_sub_vals <- neg_vals[sub_mask_cat]
          if (any(!is.na(neg_sub_vals) & neg_sub_vals > 0))
            any_neg_pos_sub <- TRUE
        }
      }

      max_abs_diff_all[r]  <- if (length(cat_diffs) > 0L) max(cat_diffs) else NA_real_
      clip_subr_nonzero[r] <- any_clip_nonzero_sub
      neg_subr_positive[r] <- any_neg_pos_sub
    }

    results[[si]] <- list(
      scenario_id           = sc$scenario_id,
      n_teams               = sc_n,
      rate_pool             = sc_rp,
      R                     = R,
      max_abs_diff_all      = max_abs_diff_all,
      overall_max_abs_diff  = max(max_abs_diff_all, na.rm = TRUE),
      clip_subr_nonzero     = clip_subr_nonzero,
      neg_subr_positive     = neg_subr_positive,
      error_rate            = mean(pvm_errors)
    )
  }

  elapsed <- as.numeric(proc.time()["elapsed"] - t0)
  list(scenarios = scenarios, results = results, elapsed_sec = elapsed)
}

# ---------------------------------------------------------------------------
# 8. Acceptance evaluation — Study 3
# ---------------------------------------------------------------------------

evaluate_study_3 <- function(res3) {
  rlist <- res3$results

  all_max_diff       <- vapply(rlist, `[[`, numeric(1L), "overall_max_abs_diff")
  all_clip_nonzero   <- vapply(rlist,
    function(x) any(x$clip_subr_nonzero, na.rm = TRUE), logical(1L))
  all_neg_pos        <- vapply(rlist,
    function(x) any(x$neg_subr_positive, na.rm = TRUE), logical(1L))
  all_err_rate       <- vapply(rlist, `[[`, numeric(1L), "error_rate")

  diff_pass  <- all(all_max_diff < 1e-12, na.rm = TRUE)
  clip_pass  <- !any(all_clip_nonzero)
  neg_pass   <- !any(all_neg_pos)
  err_pass   <- all(all_err_rate == 0.0)

  list(
    diff_pass          = diff_pass,
    clip_subr_zero     = clip_pass,
    neg_subr_negative  = neg_pass,
    err_pass           = err_pass,
    overall            = diff_pass && clip_pass && neg_pass && err_pass,
    max_abs_diff       = max(all_max_diff, na.rm = TRUE)
  )
}

# ---------------------------------------------------------------------------
# 9. Study 4 — Concentration Warning Threshold
# ---------------------------------------------------------------------------

run_study_4 <- function(R = R_STUDY4, label = "FULL") {
  message(sprintf("\n== Study 4: Concentration warning threshold [%s, R=%d per scenario] ==",
                  label, R))
  t0 <- proc.time()["elapsed"]

  target_shares <- c(0.20, 0.24, 0.26, 0.30, 0.40)
  n_teams_vals  <- c(10L, 12L)

  scenarios <- expand.grid(
    target_share = target_shares,
    n_teams      = n_teams_vals,
    stringsAsFactors = FALSE
  )
  scenarios$scenario_id <- paste0("S4_ts", scenarios$target_share * 100L,
                                   "_n", scenarios$n_teams)
  n_scenarios <- nrow(scenarios)

  results <- vector("list", n_scenarios)

  for (si in seq_len(n_scenarios)) {
    sc   <- scenarios[si, ]
    sc_n <- sc$n_teams
    sc_t <- sc$target_share

    message(sprintf("  Scenario %d/%d: target_share=%.2f n=%d",
                    si, n_scenarios, sc_t, sc_n))

    conc_fired <- logical(R)
    pvm_errors <- logical(R)

    for (r in seq_len(R)) {
      seed_r <- rep_seed(300L + si, r)
      repl   <- tryCatch(
        dgp_pvm_study4(seed_r, n_teams = sc_n, target_share = sc_t),
        error = function(e) NULL
      )
      if (is.null(repl)) {
        pvm_errors[r] <- TRUE
        next
      }

      res <- safe_pvm(
        replacement     = repl,
        include_raw     = FALSE,
        cat_pct         = "auto",
        rate_pool       = "ip_weighted",
        sub_replacement = "clip"
      )

      if (res$failed) {
        pvm_errors[r] <- TRUE
        next
      }

      conc_fired[r] <- warning_fired(res$warnings,
                                      "rotostats_warning_pvm_concentration")
    }

    results[[si]] <- list(
      scenario_id  = sc$scenario_id,
      n_teams      = sc_n,
      target_share = sc_t,
      R            = R,
      conc_fired   = conc_fired,
      fire_rate    = mean(conc_fired, na.rm = TRUE),
      error_rate   = mean(pvm_errors)
    )
  }

  elapsed <- as.numeric(proc.time()["elapsed"] - t0)
  list(scenarios = scenarios, results = results, elapsed_sec = elapsed)
}

# ---------------------------------------------------------------------------
# 10. Acceptance evaluation — Study 4
# ---------------------------------------------------------------------------

evaluate_study_4 <- function(res4) {
  rlist <- res4$results

  # Per sim-spec §4.6
  get_fire_rate <- function(ts) {
    idx <- which(vapply(rlist, function(x) x$target_share == ts, logical(1L)))
    if (length(idx) == 0L) return(NA_real_)
    mean(vapply(rlist[idx], `[[`, numeric(1L), "fire_rate"))
  }

  fr_020 <- get_fire_rate(0.20)
  fr_024 <- get_fire_rate(0.24)
  fr_026 <- get_fire_rate(0.26)
  fr_030 <- get_fire_rate(0.30)
  fr_040 <- get_fire_rate(0.40)

  pass_020 <- !is.na(fr_020) && fr_020 < 0.05
  pass_024 <- !is.na(fr_024) && fr_024 < 0.05
  pass_026 <- !is.na(fr_026) && fr_026 > 0.90
  pass_030 <- !is.na(fr_030) && fr_030 > 0.95
  pass_040 <- !is.na(fr_040) && fr_040 == 1.00

  list(
    fire_rate_020 = fr_020,
    fire_rate_024 = fr_024,
    fire_rate_026 = fr_026,
    fire_rate_030 = fr_030,
    fire_rate_040 = fr_040,
    pass_020 = pass_020,
    pass_024 = pass_024,
    pass_026 = pass_026,
    pass_030 = pass_030,
    pass_040 = pass_040,
    overall  = pass_020 && pass_024 && pass_026 && pass_030 && pass_040
  )
}

# ---------------------------------------------------------------------------
# 11. Pre-check gate runner
# ---------------------------------------------------------------------------

#' Run a pre-check gate and abort with a BLOCK message if it fails.
#'
#' @param study_fn Function that runs the study.
#' @param eval_fn Function that evaluates acceptance criteria.
#' @param R_precheck Integer. Pre-check replications.
#' @param study_label Character. Study label for messages.
#' @param run_dir Character. Run directory for mailbox.md append.
#' @return The study results list if gate passes.
#' @noRd
run_precheck_gate <- function(study_fn, eval_fn, R_precheck,
                               study_label, run_dir) {
  message(sprintf("\n--- Pre-check gate: %s (R=%d) ---", study_label, R_precheck))

  res   <- study_fn(R = R_precheck, label = "PRE-CHECK")
  eval_ <- eval_fn(res)

  if (!eval_$overall) {
    msg <- sprintf(
      "BLOCK: %s pre-check FAILED.\nAcceptance: %s",
      study_label,
      paste(capture.output(print(eval_)), collapse = "\n")
    )
    message(msg)
    cat(sprintf(
      "\n---\n**Timestamp:** %s UTC\n**From:** simulator\n**Type:** HOLD_REQUEST\n**Subject:** %s pre-check gate failed\n\n%s\n",
      format(Sys.time(), "%Y-%m-%d %H:%M"),
      study_label,
      msg
    ), file = file.path(run_dir, "mailbox.md"), append = TRUE)
    stop(msg)
  }

  message(sprintf("  Pre-check PASSED for %s.", study_label))
  res
}

# ---------------------------------------------------------------------------
# 12. Summary CSV builder
# ---------------------------------------------------------------------------

#' Build a row for the summary CSV.
#' @noRd
make_csv_rows <- function(study, scenario_id, n_teams, rate_pool, sub_replacement,
                           cat_pct, target_share = NA_real_, n_replications,
                           metric, value_mean, value_max, value_min, pass) {
  data.frame(
    study           = study,
    scenario_id     = scenario_id,
    n_teams         = n_teams,
    rate_pool       = rate_pool,
    sub_replacement = sub_replacement,
    cat_pct         = cat_pct,
    target_share    = target_share,
    n_replications  = n_replications,
    metric          = metric,
    value_mean      = value_mean,
    value_max       = value_max,
    value_min       = value_min,
    pass            = pass,
    stringsAsFactors = FALSE
  )
}

collect_summary_csv <- function(res1, res2, res3, res4,
                                 eval1, eval2, eval3, eval4) {
  rows <- list()

  # Study 1
  for (x in res1$results) {
    dev_vals <- if (x$sub_replacement == "clip") {
      c(x$sum_dev_clip)
    } else {
      c(x$pos_sum_dev_neg)
    }
    dev_vals <- dev_vals[!is.na(dev_vals)]
    metric_nm <- if (x$sub_replacement == "clip") "sum_dev_clip" else "pos_sum_dev_neg"
    rows[[length(rows) + 1L]] <- make_csv_rows(
      study = 1L, scenario_id = x$scenario_id,
      n_teams = x$n_teams, rate_pool = "ip_weighted",
      sub_replacement = x$sub_replacement, cat_pct = x$cat_pct,
      n_replications = x$R, metric = metric_nm,
      value_mean = if (length(dev_vals) > 0L) mean(dev_vals) else NA_real_,
      value_max  = if (length(dev_vals) > 0L) max(dev_vals)  else NA_real_,
      value_min  = if (length(dev_vals) > 0L) min(dev_vals)  else NA_real_,
      pass = if (x$sub_replacement == "clip") eval1$clip_pass else eval1$neg_pass
    )
    rows[[length(rows) + 1L]] <- make_csv_rows(
      study = 1L, scenario_id = x$scenario_id,
      n_teams = x$n_teams, rate_pool = "ip_weighted",
      sub_replacement = x$sub_replacement, cat_pct = x$cat_pct,
      n_replications = x$R, metric = "warn_sum_fire_rate",
      value_mean = x$warn_sum_fire_rate, value_max = x$warn_sum_fire_rate,
      value_min = x$warn_sum_fire_rate, pass = eval1$warn_pass
    )
  }

  # Study 2
  for (x in res2$results) {
    dev_vals <- c(x$sum_dev)
    dev_vals <- dev_vals[!is.na(dev_vals)]
    opt_eval <- eval2$by_option[[x$rate_pool]]
    rows[[length(rows) + 1L]] <- make_csv_rows(
      study = 2L, scenario_id = x$scenario_id,
      n_teams = x$n_teams, rate_pool = x$rate_pool,
      sub_replacement = x$sub_replacement, cat_pct = "auto",
      n_replications = x$R, metric = "sum_dev",
      value_mean = if (length(dev_vals) > 0L) mean(dev_vals) else NA_real_,
      value_max  = if (length(dev_vals) > 0L) max(dev_vals)  else NA_real_,
      value_min  = if (length(dev_vals) > 0L) min(dev_vals)  else NA_real_,
      pass = opt_eval$pass_sum
    )
  }

  # Study 3
  for (x in res3$results) {
    diff_vec <- x$max_abs_diff_all
    diff_vec <- diff_vec[!is.na(diff_vec)]
    rows[[length(rows) + 1L]] <- make_csv_rows(
      study = 3L, scenario_id = x$scenario_id,
      n_teams = x$n_teams, rate_pool = x$rate_pool,
      sub_replacement = "clip_vs_negative", cat_pct = "auto",
      n_replications = x$R, metric = "max_abs_diff_above_repl",
      value_mean = if (length(diff_vec) > 0L) mean(diff_vec) else NA_real_,
      value_max  = if (length(diff_vec) > 0L) max(diff_vec)  else NA_real_,
      value_min  = if (length(diff_vec) > 0L) min(diff_vec)  else NA_real_,
      pass = eval3$diff_pass
    )
  }

  # Study 4
  for (x in res4$results) {
    rows[[length(rows) + 1L]] <- make_csv_rows(
      study = 4L, scenario_id = x$scenario_id,
      n_teams = x$n_teams, rate_pool = "ip_weighted",
      sub_replacement = "clip", cat_pct = "auto",
      target_share = x$target_share,
      n_replications = x$R, metric = "concentration_fire_rate",
      value_mean = x$fire_rate, value_max = x$fire_rate,
      value_min = x$fire_rate,
      pass = switch(
        as.character(x$target_share),
        "0.2"  = eval4$pass_020,
        "0.24" = eval4$pass_024,
        "0.26" = eval4$pass_026,
        "0.3"  = eval4$pass_030,
        "0.4"  = eval4$pass_040,
        NA
      )
    )
  }

  do.call(rbind, rows)
}

# ---------------------------------------------------------------------------
# 13. simulation.md writer
# ---------------------------------------------------------------------------

fmt_val <- function(x, digits = 8) {
  if (is.null(x) || (length(x) == 1L && is.na(x))) return("NA")
  if (is.logical(x))  return(if (x) "TRUE" else "FALSE")
  if (is.integer(x))  return(as.character(x))
  formatC(x, digits = digits, format = "g")
}

write_simulation_md <- function(res1, res2, res3, res4,
                                 eval1, eval2, eval3, eval4,
                                 pre_res1, pre_res2, pre_res3, pre_res4,
                                 pre_eval1, pre_eval2, pre_eval3, pre_eval4,
                                 run_dir, run_date, mode_label) {
  pass_or_fail <- function(b) if (isTRUE(b)) "PASS" else "FAIL"

  lines <- c(
    "# Simulation Results: pvm()",
    "",
    paste0("Request ID: pvm-2026-04-23"),
    paste0("Date: ", run_date),
    paste0("Mode: ", mode_label),
    paste0("Master seed: ", MASTER_SEED),
    paste0("Sim-spec version: pvm-2026-04-23"),
    "",
    "---",
    "",
    "## Simulation Design Summary",
    "",
    "### DGP",
    "",
    "All four studies use synthetic projection pools generated by `dgp_pvm()` in",
    "`inst/simulations/dgp/dgp_pvm.R`. The DGP is a pure function: given the same",
    "`(seed, n_teams)`, it produces identical output.",
    "",
    "**Hitter stats:**",
    "- HR, R, RBI, SB ~ Poisson(lambda) where lambda ~ Uniform per player (per sim-spec §1.2)",
    "- AVG ~ Beta(5,5) rescaled to [.220, .330]; AB ~ round(Uniform(350, 600))",
    "",
    "**Pitcher stats:**",
    "- W, K ~ Poisson; SV ~ Poisson (top 20% of RPs have saves)",
    "- ERA ~ Uniform(2.80, 5.80); WHIP ~ Uniform(0.95, 1.65)",
    "- IP ~ round(Uniform(40, 220))",
    "",
    "**Pool size:** `total_players = ceiling(n_rostered * 1.5)` per player type.",
    "**Roster structure:** 9 hitter slots (C/1B/2B/3B/SS/3×OF/UTIL), 8 pitcher slots (5 SP / 3 RP).",
    "**Scored categories:** HR, R, RBI, SB, AVG, W, K, SV, ERA, WHIP.",
    "",
    "### Estimator Interface",
    "",
    "```r",
    "result <- pvm(",
    "  replacement      = replacement_obj,",
    "  include_raw      = FALSE,",
    "  cat_pct          = cat_pct_val,",
    "  rate_pool        = rate_pool_val,",
    "  sub_replacement  = sub_rep_val,",
    "  baseline         = baseline_val",
    ")",
    "```",
    "",
    "### Scenario Grid",
    "",
    sprintf("| Study | Dimensions | Scenarios | R (full) | Total draws |"),
    "|-------|-----------|-----------|----------|------------|",
    sprintf("| 1 | n_teams×5, sub_replacement×2, cat_pct×2 | 20 | %d | %d |",
            R_STUDY1, 20L * R_STUDY1),
    sprintf("| 2 | rate_pool×3, sub_replacement×2, n_teams×3 | 18 | %d | %d |",
            R_STUDY2, 18L * R_STUDY2),
    sprintf("| 3 | n_teams×2, rate_pool×2 | 4 | %d | %d |",
            R_STUDY3, 4L * R_STUDY3),
    sprintf("| 4 | target_share×5, n_teams×2 | 10 | %d | %d |",
            R_STUDY4, 10L * R_STUDY4),
    sprintf("| **Total** | | **52** | — | **%d** |",
            20L * R_STUDY1 + 18L * R_STUDY2 + 4L * R_STUDY3 + 10L * R_STUDY4),
    "",
    "### Seed Strategy",
    "",
    paste0("- Master seed: ", MASTER_SEED),
    "- Per-replication seed: `master_seed + scenario_index * 1000 + replication_index`",
    "- RNG: L'Ecuyer-CMRG (`set.seed(..., kind = 'L\\'Ecuyer-CMRG')`)",
    "- Study offsets: Study 1 scenarios 1–20, Study 2 scenarios 101–118,",
    "  Study 3 scenarios 201–204, Study 4 scenarios 301–310.",
    "",
    "### Files Created",
    "",
    "| File | Description |",
    "|------|-------------|",
    "| `inst/simulations/sim-pvm.R` | This harness |",
    "| `inst/simulations/dgp/dgp_pvm.R` | DGP functions for all four studies |",
    "| `tests/simulations/sim-pvm-results.rds` | Binary per-replication results |",
    "| `tests/simulations/sim-pvm-summary.csv` | Human-readable summary table |",
    "",
    "---",
    "",
    "## Small-R Pre-Check Results",
    ""
  )

  # Study 1 pre-check
  lines <- c(lines,
    "### Study 1 Pre-Check (R = 50 per scenario, 1,000 total draws)",
    "",
    "| Criterion | Value | Threshold | Pass? |",
    "|-----------|-------|-----------|-------|",
    sprintf("| max_sum_dev_clip    | %s | < 1e-10 | %s |",
            fmt_val(pre_eval1$max_clip_deviation), pass_or_fail(pre_eval1$clip_pass)),
    sprintf("| max_pos_sum_dev_neg | %s | < 1e-10 | %s |",
            fmt_val(pre_eval1$max_neg_deviation), pass_or_fail(pre_eval1$neg_pass)),
    sprintf("| max_warn_rate       | %s | == 0    | %s |",
            fmt_val(pre_eval1$max_warn_rate), pass_or_fail(pre_eval1$warn_pass)),
    sprintf("| max_error_rate      | %s | == 0    | %s |",
            fmt_val(pre_eval1$max_error_rate), pass_or_fail(pre_eval1$err_pass)),
    sprintf("| **Gate**            |       |         | **%s** |",
            pass_or_fail(pre_eval1$overall)),
    ""
  )

  # Study 2 pre-check
  lines <- c(lines,
    "### Study 2 Pre-Check (R = 30 per scenario, 540 total draws)",
    "",
    "| rate_pool | max_sum_dev | Threshold | Pass? |",
    "|-----------|-------------|-----------|-------|"
  )
  for (opt in names(pre_eval2$by_option)) {
    oe <- pre_eval2$by_option[[opt]]
    lines <- c(lines,
      sprintf("| %s | %s | < 1e-10 | %s |",
              opt, fmt_val(oe$max_sum_dev), pass_or_fail(oe$pass_sum)))
  }
  lines <- c(lines,
    sprintf("| **Gate (all options)** |  |  | **%s** |",
            pass_or_fail(pre_eval2$overall)),
    ""
  )

  # Study 3 pre-check
  lines <- c(lines,
    "### Study 3 Pre-Check (R = 20 per scenario, 80 total draws)",
    "",
    "| Criterion | Value | Threshold | Pass? |",
    "|-----------|-------|-----------|-------|",
    sprintf("| max_abs_diff (above-repl) | %s | < 1e-12 | %s |",
            fmt_val(pre_eval3$max_abs_diff), pass_or_fail(pre_eval3$diff_pass)),
    sprintf("| clip_subr_zero            | %s | TRUE    | %s |",
            fmt_val(pre_eval3$clip_subr_zero), pass_or_fail(pre_eval3$clip_subr_zero)),
    sprintf("| neg_subr_negative         | %s | TRUE    | %s |",
            fmt_val(pre_eval3$neg_subr_negative), pass_or_fail(pre_eval3$neg_subr_negative)),
    sprintf("| **Gate**                  |       |         | **%s** |",
            pass_or_fail(pre_eval3$overall)),
    ""
  )

  # Study 4 pre-check
  lines <- c(lines,
    "### Study 4 Pre-Check (R = 25 per scenario, 250 total draws)",
    "",
    "| target_share | fire_rate | Gate criterion | Pass? |",
    "|--------------|-----------|----------------|-------|",
    sprintf("| 0.20 | %s | == 0.0 | %s |",
            fmt_val(pre_eval4$fire_rate_020), pass_or_fail(pre_eval4$pass_020)),
    sprintf("| 0.24 | %s | < 0.05 | %s |",
            fmt_val(pre_eval4$fire_rate_024), pass_or_fail(pre_eval4$pass_024)),
    sprintf("| 0.26 | %s | > 0.90 | %s |",
            fmt_val(pre_eval4$fire_rate_026), pass_or_fail(pre_eval4$pass_026)),
    sprintf("| 0.30 | %s | > 0.95 | %s |",
            fmt_val(pre_eval4$fire_rate_030), pass_or_fail(pre_eval4$pass_030)),
    sprintf("| 0.40 | %s | == 1.0 | %s |",
            fmt_val(pre_eval4$fire_rate_040), pass_or_fail(pre_eval4$pass_040)),
    sprintf("| **Gate (0.20 and 0.40)** |  |  | **%s** |",
            pass_or_fail(pre_eval4$pass_020 && pre_eval4$pass_040)),
    ""
  )

  lines <- c(lines, "---", "")

  # Full run results (only present if mode = FULL)
  if (!is.null(res1)) {
    lines <- c(lines,
      "## Full Run Results",
      "",
      "### Study 1 — Sum-to-1 Invariant (rate_pool = ip_weighted)",
      "",
      "| Criterion | Value | Threshold | Pass? |",
      "|-----------|-------|-----------|-------|",
      sprintf("| max_sum_dev_clip    | %s | < 1e-10 | %s |",
              fmt_val(eval1$max_clip_deviation), pass_or_fail(eval1$clip_pass)),
      sprintf("| max_pos_sum_dev_neg | %s | < 1e-10 | %s |",
              fmt_val(eval1$max_neg_deviation), pass_or_fail(eval1$neg_pass)),
      sprintf("| max_warn_rate       | %s | == 0    | %s |",
              fmt_val(eval1$max_warn_rate), pass_or_fail(eval1$warn_pass)),
      sprintf("| max_error_rate      | %s | == 0    | %s |",
              fmt_val(eval1$max_error_rate), pass_or_fail(eval1$err_pass)),
      sprintf("| **Study 1 overall** |  |  | **%s** |",
              pass_or_fail(eval1$overall)),
      "",
      paste0("Note: Each rate_pool option has been calibrated independently.",
             " Study 1 covers ip_weighted only. Study 2 covers all three options."),
      "",
      "### Study 2 — Pool Denominator Signal (all rate_pool options)",
      "",
      "| rate_pool | max_sum_dev | Threshold | Pass? |",
      "|-----------|-------------|-----------|-------|"
    )
    for (opt in names(eval2$by_option)) {
      oe <- eval2$by_option[[opt]]
      lines <- c(lines,
        sprintf("| %s | %s | < 1e-10 | %s |",
                opt, fmt_val(oe$max_sum_dev), pass_or_fail(oe$pass_sum)))
    }
    lines <- c(lines,
      sprintf("| **Study 2 overall** |  |  | **%s** |",
              pass_or_fail(eval2$overall)),
      "",
      "### Study 3 — Sub-Replacement Sensitivity",
      "",
      "| Criterion | Value | Threshold | Pass? |",
      "|-----------|-------|-----------|-------|",
      sprintf("| max_abs_diff (above-repl, clip vs neg) | %s | < 1e-12 | %s |",
              fmt_val(eval3$max_abs_diff), pass_or_fail(eval3$diff_pass)),
      sprintf("| clip sub-replacement PVM == 0          | %s | TRUE    | %s |",
              fmt_val(eval3$clip_subr_zero), pass_or_fail(eval3$clip_subr_zero)),
      sprintf("| neg sub-replacement PVM < 0            | %s | TRUE    | %s |",
              fmt_val(eval3$neg_subr_negative), pass_or_fail(eval3$neg_subr_negative)),
      sprintf("| **Study 3 overall** |  |  | **%s** |",
              pass_or_fail(eval3$overall)),
      "",
      "### Study 4 — Concentration Warning Threshold",
      "",
      "| target_share | fire_rate | Threshold | Pass? |",
      "|--------------|-----------|-----------|-------|",
      sprintf("| 0.20 | %s | < 0.05  | %s |",
              fmt_val(eval4$fire_rate_020), pass_or_fail(eval4$pass_020)),
      sprintf("| 0.24 | %s | < 0.05  | %s |",
              fmt_val(eval4$fire_rate_024), pass_or_fail(eval4$pass_024)),
      sprintf("| 0.26 | %s | > 0.90  | %s |",
              fmt_val(eval4$fire_rate_026), pass_or_fail(eval4$pass_026)),
      sprintf("| 0.30 | %s | > 0.95  | %s |",
              fmt_val(eval4$fire_rate_030), pass_or_fail(eval4$pass_030)),
      sprintf("| 0.40 | %s | == 1.00 | %s |",
              fmt_val(eval4$fire_rate_040), pass_or_fail(eval4$pass_040)),
      sprintf("| **Study 4 overall** |  |  | **%s** |",
              pass_or_fail(eval4$overall)),
      ""
    )

    # Overall summary
    overall <- eval1$overall && eval2$overall && eval3$overall && eval4$overall
    lines <- c(lines,
      "---",
      "",
      "## Overall Verdict",
      "",
      "| Study | Pass? |",
      "|-------|-------|",
      sprintf("| Study 1 (Sum-to-1, ip_weighted) | %s |", pass_or_fail(eval1$overall)),
      sprintf("| Study 2 (Pool denominator, all options) | %s |", pass_or_fail(eval2$overall)),
      sprintf("| Study 3 (Sub-replacement sensitivity) | %s |", pass_or_fail(eval3$overall)),
      sprintf("| Study 4 (Concentration warning) | %s |", pass_or_fail(eval4$overall)),
      sprintf("| **OVERALL** | **%s** |", pass_or_fail(overall)),
      ""
    )
  } else {
    lines <- c(lines,
      "## Full Run Results",
      "",
      "(Pre-check only mode — full run not executed.)",
      "",
      "---",
      "",
      "## Overall Verdict",
      "",
      "Pre-check mode only. Full verdict pending.",
      ""
    )
  }

  lines <- c(lines,
    "---",
    "",
    "## Simulation Design Notes",
    "",
    paste0("- DGP: `dgp_pvm()` in `inst/simulations/dgp/dgp_pvm.R`, pure function"),
    paste0("- Estimator: `pvm()` called as black-box per sim-spec.md"),
    paste0("- Seed strategy: `master_seed + scenario_index * 1000 + replication_index`"),
    paste0("- Master seed: ", MASTER_SEED),
    paste0("- RNG kind: L'Ecuyer-CMRG for reproducible parallel streams"),
    paste0("- Error handling: failed replications recorded; excluded from metric computation"),
    paste0("- Per-replication seed set at DGP call start (pure function contract)"),
    paste0("- No parallelization — sequential for deterministic reproducibility"),
    paste0("- Per-rate_pool independence: Study 2 thresholds are calibrated for each"),
    paste0("  option independently; a PASS for ip_weighted does NOT certify pool_average"),
    paste0("  or fixed_baseline."),
    paste0("- fixed_baseline constants: ERA=4.20, WHIP=1.30, AVG=0.265 (per sim-spec §2.2)"),
    ""
  )

  writeLines(lines, file.path(run_dir, "simulation.md"))
  invisible(lines)
}

# ---------------------------------------------------------------------------
# 14. Main execution
# ---------------------------------------------------------------------------

main <- function() {
  message("=== pvm() Monte Carlo Simulation ===")
  message(sprintf("Master seed: %d | Mode: %s",
                  MASTER_SEED, if (PRECHECK_ONLY) "PRE-CHECK ONLY" else "FULL"))
  message(sprintf("Run directory: %s", RUN_DIR))
  message(sprintf("Date: %s", format(Sys.time(), "%Y-%m-%d %H:%M UTC")))
  message("")

  # Verify pvm() is available
  if (!existsFunction("pvm")) {
    # Try to find it from the loaded package
    if (!exists("pvm", mode = "function", envir = as.environment("package:rotostats"))) {
      msg <- paste0(
        "HOLD: pvm() function not found after devtools::load_all(). ",
        "The builder has not yet committed R/pvm.R. ",
        "The harness is written and ready; re-run after builder merges."
      )
      message(msg)
      cat(sprintf(
        "\n---\n**Timestamp:** %s UTC\n**From:** simulator\n**Type:** HOLD_REQUEST\n**Subject:** pvm() not available at execution time\n\n%s\n",
        format(Sys.time(), "%Y-%m-%d %H:%M"), msg
      ), file = file.path(RUN_DIR, "mailbox.md"), append = TRUE)

      # Write a simulation.md placeholder with HOLD verdict
      writeLines(c(
        "# Simulation Results: pvm()",
        "",
        paste0("Request ID: pvm-2026-04-23"),
        paste0("Date: ", format(Sys.time(), "%Y-%m-%d %H:%M UTC")),
        "",
        "## Verdict: HOLD",
        "",
        "pvm() function not found. Builder must commit R/pvm.R before the",
        "simulation harness can execute.",
        "",
        "The harness (sim-pvm.R) and DGP (dgp/dgp_pvm.R) are written and ready.",
        "Re-run this script after the builder's implementation is merged.",
        ""
      ), file.path(RUN_DIR, "simulation.md"))
      return(invisible(NULL))
    }
  }

  t_total <- proc.time()["elapsed"]

  # ---- Pre-check gates (mandatory per sim-spec.md) ----

  pre_res1 <- run_precheck_gate(
    study_fn    = run_study_1,
    eval_fn     = evaluate_study_1,
    R_precheck  = PRECHECK_R1,
    study_label = "Study 1",
    run_dir     = RUN_DIR
  )
  pre_eval1 <- evaluate_study_1(pre_res1)

  pre_res2 <- run_precheck_gate(
    study_fn    = run_study_2,
    eval_fn     = evaluate_study_2,
    R_precheck  = PRECHECK_R2,
    study_label = "Study 2",
    run_dir     = RUN_DIR
  )
  pre_eval2 <- evaluate_study_2(pre_res2)

  pre_res3 <- run_precheck_gate(
    study_fn    = run_study_3,
    eval_fn     = evaluate_study_3,
    R_precheck  = PRECHECK_R3,
    study_label = "Study 3",
    run_dir     = RUN_DIR
  )
  pre_eval3 <- evaluate_study_3(pre_res3)

  pre_res4 <- run_precheck_gate(
    study_fn    = run_study_4,
    eval_fn     = evaluate_study_4,
    R_precheck  = PRECHECK_R4,
    study_label = "Study 4",
    run_dir     = RUN_DIR
  )
  pre_eval4 <- evaluate_study_4(pre_res4)

  # ---- Full runs (skipped in PRECHECK_ONLY mode) ----

  res1 <- res2 <- res3 <- res4   <- NULL
  eval1 <- eval2 <- eval3 <- eval4 <- NULL

  if (!PRECHECK_ONLY) {
    res1  <- run_study_1(R = R_STUDY1, label = "FULL")
    eval1 <- evaluate_study_1(res1)

    res2  <- run_study_2(R = R_STUDY2, label = "FULL")
    eval2 <- evaluate_study_2(res2)

    res3  <- run_study_3(R = R_STUDY3, label = "FULL")
    eval3 <- evaluate_study_3(res3)

    res4  <- run_study_4(R = R_STUDY4, label = "FULL")
    eval4 <- evaluate_study_4(res4)
  }

  # ---- Acceptance summary ----

  message("\n=== Acceptance Criteria Summary ===")
  message("Pre-check gates:")
  message(sprintf("  [%s] Study 1 pre-check", if (pre_eval1$overall) "PASS" else "FAIL"))
  message(sprintf("  [%s] Study 2 pre-check", if (pre_eval2$overall) "PASS" else "FAIL"))
  message(sprintf("  [%s] Study 3 pre-check", if (pre_eval3$overall) "PASS" else "FAIL"))
  message(sprintf("  [%s] Study 4 pre-check", if (pre_eval4$overall) "PASS" else "FAIL"))

  if (!PRECHECK_ONLY) {
    message("Full-run criteria:")
    message(sprintf("  [%s] Study 1: max_clip_deviation=%s, max_neg_deviation=%s",
                    if (eval1$overall) "PASS" else "FAIL",
                    fmt_val(eval1$max_clip_deviation),
                    fmt_val(eval1$max_neg_deviation)))
    message(sprintf("  [%s] Study 2: per-option sum-to-1",
                    if (eval2$overall) "PASS" else "FAIL"))
    message(sprintf("  [%s] Study 3: max_abs_diff=%s",
                    if (eval3$overall) "PASS" else "FAIL",
                    fmt_val(eval3$max_abs_diff)))
    message(sprintf("  [%s] Study 4: fire rates 020=%.3f 026=%.3f 040=%.3f",
                    if (eval4$overall) "PASS" else "FAIL",
                    eval4$fire_rate_020, eval4$fire_rate_026, eval4$fire_rate_040))

    overall <- eval1$overall && eval2$overall && eval3$overall && eval4$overall
    message(sprintf("\nOverall: %s", if (overall) "PASS" else "FAIL"))
  }

  # ---- Write outputs ----

  run_date  <- format(Sys.time(), "%Y-%m-%d %H:%M UTC")
  mode_label <- if (PRECHECK_ONLY) "PRE-CHECK ONLY" else "FULL"

  write_simulation_md(
    res1 = res1, res2 = res2, res3 = res3, res4 = res4,
    eval1 = eval1, eval2 = eval2, eval3 = eval3, eval4 = eval4,
    pre_res1 = pre_res1, pre_res2 = pre_res2,
    pre_res3 = pre_res3, pre_res4 = pre_res4,
    pre_eval1 = pre_eval1, pre_eval2 = pre_eval2,
    pre_eval3 = pre_eval3, pre_eval4 = pre_eval4,
    run_dir = RUN_DIR, run_date = run_date, mode_label = mode_label
  )
  message(sprintf("Wrote simulation.md to: %s",
                  file.path(RUN_DIR, "simulation.md")))

  # RDS: save all results
  simdir <- file.path(REPO_ROOT, "tests", "simulations")
  if (!dir.exists(simdir)) dir.create(simdir, recursive = TRUE)

  all_results <- list(
    pre_check = list(
      study_1 = list(results = pre_res1, eval = pre_eval1),
      study_2 = list(results = pre_res2, eval = pre_eval2),
      study_3 = list(results = pre_res3, eval = pre_eval3),
      study_4 = list(results = pre_res4, eval = pre_eval4)
    ),
    full = if (!PRECHECK_ONLY) list(
      study_1 = list(results = res1, eval = eval1),
      study_2 = list(results = res2, eval = eval2),
      study_3 = list(results = res3, eval = eval3),
      study_4 = list(results = res4, eval = eval4)
    ) else NULL,
    metadata = list(
      master_seed   = MASTER_SEED,
      run_date      = run_date,
      mode          = mode_label,
      sim_spec_id   = "pvm-2026-04-23",
      R_study1      = if (PRECHECK_ONLY) PRECHECK_R1 else R_STUDY1,
      R_study2      = if (PRECHECK_ONLY) PRECHECK_R2 else R_STUDY2,
      R_study3      = if (PRECHECK_ONLY) PRECHECK_R3 else R_STUDY3,
      R_study4      = if (PRECHECK_ONLY) PRECHECK_R4 else R_STUDY4,
      baseline_fixed = BASELINE_FIXED
    )
  )

  rds_path <- file.path(simdir, "sim-pvm-results.rds")
  saveRDS(all_results, rds_path)
  message(sprintf("Wrote sim-pvm-results.rds to: %s", rds_path))

  # CSV summary
  if (!PRECHECK_ONLY && !is.null(res1)) {
    csv_df   <- collect_summary_csv(res1, res2, res3, res4,
                                     eval1, eval2, eval3, eval4)
    csv_path <- file.path(simdir, "sim-pvm-summary.csv")
    utils::write.csv(csv_df, csv_path, row.names = FALSE)
    message(sprintf("Wrote sim-pvm-summary.csv to: %s", csv_path))
  }

  total_elapsed <- as.numeric(proc.time()["elapsed"] - t_total)
  message(sprintf("Total elapsed: %.1f seconds", total_elapsed))

  invisible(all_results)
}

# ---------------------------------------------------------------------------
# Helper: existsFunction — check for function existence portably
# ---------------------------------------------------------------------------
existsFunction <- function(name) {
  tryCatch(
    {
      f <- get(name, mode = "function", envir = globalenv(), inherits = TRUE)
      !is.null(f)
    },
    error = function(e) FALSE
  )
}

# Run when executed via Rscript (not when sourced interactively)
if (sys.nframe() == 0L) {
  main()
}
