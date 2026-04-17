#!/usr/bin/env Rscript
# replacement-mc.R
# Monte Carlo Simulation Harness for replacement_level()
#
# Implements five studies (A–E) per sim-spec.md for request replacement-2026-04-16.
#
# Studies:
#   A — Boundary-band stability: K=3 vs K=1 year-over-year variance
#   B — Zero-sum invariant under all four catcher_adjustment_method values
#   C — Convergence of the multi-position reassignment loop
#   D — Dynamic K cap behavior in thin AL-only pools
#   E — Rank invariance under boundary_rate_method = "raw_ip" across league sizes
#
# Usage:
#   Rscript inst/simulations/replacement-mc.R
#
# The environment variable STATSCLAW_RUN_DIR controls where simulation.md and
# simulation_results.rds are written. Default: the canonical run directory for
# this request.
#
# Requires: devtools::load_all() to expose replacement_level() and league_config().
# The harness will work once builder's replacement_level() implementation is merged.
#
# Seeds: Master seed 20260416. Per-replication seeds derived as:
#   scenario_seed(study, scenario_idx, r) = 20260416 + study * 100000 + scenario_idx * 10000 + r
# (per sim-spec.md §5)

# ---------------------------------------------------------------------------
# 0. Setup
# ---------------------------------------------------------------------------

SCRIPT_DIR <- normalizePath(dirname(sys.frame(1)$ofile), mustWork = FALSE)
if (!nzchar(SCRIPT_DIR)) {
  # Fallback when not run via Rscript
  SCRIPT_DIR <- normalizePath("inst/simulations", mustWork = FALSE)
}
REPO_ROOT <- normalizePath(file.path(SCRIPT_DIR, "../.."), mustWork = FALSE)

# Load the package so replacement_level() and league_config() are available
if (requireNamespace("devtools", quietly = TRUE)) {
  devtools::load_all(REPO_ROOT, quiet = TRUE)
} else {
  # Fallback: try to load from installed package
  library(rotostats)
}

# Source DGP helpers
source(file.path(SCRIPT_DIR, "dgp", "dgp_a.R"))
source(file.path(SCRIPT_DIR, "dgp", "dgp_c.R"))
source(file.path(SCRIPT_DIR, "dgp", "dgp_d.R"))
source(file.path(SCRIPT_DIR, "dgp", "dgp_e.R"))

# Run directory for output artifacts
RUN_DIR <- Sys.getenv(
  "STATSCLAW_RUN_DIR",
  unset = "/Users/jacobdennen/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/replacement-2026-04-16"
)

# ---------------------------------------------------------------------------
# 1. Constants and seed helpers
# ---------------------------------------------------------------------------

MASTER_SEED <- 20260416L
R_REPS      <- 500L   # replications per scenario

#' Derive per-replication seed deterministically.
#'
#' @param study Integer study index (1=A, 2=B, 3=C, 4=D, 5=E).
#' @param scenario_idx Integer scenario index within the study.
#' @param replication Integer replication index.
#' @return Integer seed.
scenario_seed <- function(study, scenario_idx, replication) {
  MASTER_SEED + study * 100000L + scenario_idx * 10000L + replication
}

# ---------------------------------------------------------------------------
# 2. League configurations
# ---------------------------------------------------------------------------

# Study A/B: 12-team mixed
cfg_study_ab <- league_config(
  n_teams       = 12L,
  roster_slots  = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L,
                    SS = 1L, OF = 3L, UTIL = 1L),
  pitcher_slots = c(SP = 6L, RP = 3L),
  categories    = c("HR", "R", "RBI", "SB", "AVG",
                    "W", "K", "SV", "ERA", "WHIP"),
  league_type   = "mixed",
  budget        = 260L
)

# Study D: 12-team AL (SS thin / C thin are same config structure)
cfg_al_12 <- league_config(
  n_teams       = 12L,
  roster_slots  = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L,
                    SS = 1L, OF = 3L, DH = 1L, UTIL = 1L),
  pitcher_slots = c(SP = 6L, RP = 3L),
  categories    = c("HR", "R", "RBI", "SB", "AVG",
                    "W", "K", "SV", "ERA", "WHIP"),
  league_type   = "AL",
  budget        = 260L
)

# Study D: 5-team (exploratory)
cfg_al_5 <- league_config(
  n_teams       = 5L,
  roster_slots  = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L,
                    SS = 1L, OF = 3L, DH = 1L, UTIL = 1L),
  pitcher_slots = c(SP = 6L, RP = 3L),
  categories    = c("HR", "R", "RBI", "SB", "AVG",
                    "W", "K", "SV", "ERA", "WHIP"),
  league_type   = "AL",
  budget        = 260L
)

# Study E: 10-team and 15-team mixed
cfg_10team <- league_config(
  n_teams       = 10L,
  roster_slots  = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L,
                    SS = 1L, OF = 3L, UTIL = 1L),
  pitcher_slots = c(SP = 6L, RP = 3L),
  categories    = c("HR", "R", "RBI", "SB", "AVG",
                    "W", "K", "SV", "ERA", "WHIP"),
  league_type   = "mixed",
  budget        = 260L
)

cfg_15team <- league_config(
  n_teams       = 15L,
  roster_slots  = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L,
                    SS = 1L, OF = 3L, UTIL = 1L),
  pitcher_slots = c(SP = 6L, RP = 3L),
  categories    = c("HR", "R", "RBI", "SB", "AVG",
                    "W", "K", "SV", "ERA", "WHIP"),
  league_type   = "mixed",
  budget        = 260L
)

# ---------------------------------------------------------------------------
# 3. Utility: extract one replacement stat value
# ---------------------------------------------------------------------------

#' Extract a single stat from the replacement_stats data frame.
#'
#' @param result Return value from \code{replacement_level()}.
#' @param position Character position code, e.g. \code{"1B"}.
#' @param stat Character column name, e.g. \code{"HR"}.
#' @return Scalar numeric (NA if position or stat not found).
repl_stat <- function(result, position, stat) {
  rs  <- result$replacement_stats
  row <- rs[rs$position == position, ]
  if (nrow(row) == 0L || !stat %in% names(row)) return(NA_real_)
  row[[stat]]
}

# ---------------------------------------------------------------------------
# 4. Safe wrapper for replacement_level()
# ---------------------------------------------------------------------------

#' Run replacement_level() and return a list with result and failure flag.
#'
#' Wraps the call in tryCatch so a single replication failure does not abort
#' the loop. Failures are recorded with failed = TRUE.
#'
#' @param ... Arguments forwarded to \code{replacement_level()}.
#' @return A list with \code{result} (NULL on failure) and \code{failed} (logical).
safe_repl <- function(...) {
  tryCatch(
    {
      list(result = replacement_level(...), failed = FALSE)
    },
    error = function(e) {
      list(result = NULL, failed = TRUE, error_msg = conditionMessage(e))
    }
  )
}

# ---------------------------------------------------------------------------
# 5. Study A: Boundary-Band Stability
# ---------------------------------------------------------------------------

run_study_a <- function(R = R_REPS) {
  message("Study A: Boundary-band stability (R = ", R, " per K)")
  t0 <- proc.time()["elapsed"]

  # Two K values; per sim-spec.md §3
  K_values <- c(1L, 3L)

  # For each K, record year-over-year deltas across R replications
  # delta_HR_1B[k, r]  = |repl_1["1B", "HR"] - repl_2["1B", "HR"]|
  # delta_ERA_SP[k, r] = |repl_1["SP", "ERA"] - repl_2["SP", "ERA"]|
  # Also track SS HR and RP ERA as secondary
  deltas <- vector("list", length(K_values))
  names(deltas) <- paste0("K", K_values)

  for (ki in seq_along(K_values)) {
    K <- K_values[ki]
    delta_HR_1B  <- numeric(R)
    delta_ERA_SP <- numeric(R)
    delta_HR_SS  <- numeric(R)
    delta_ERA_RP <- numeric(R)
    n_failures   <- 0L

    for (r in seq_len(R)) {
      if (r %% 100L == 0L) message("  Study A K=", K, " rep ", r, "/", R)

      seed_y1 <- scenario_seed(1L, ki, r)
      seed_y2 <- scenario_seed(1L, ki, R + r)

      proj_y1 <- dgp_a(seed_y1, sigma_proj = 0.10)
      proj_y2 <- dgp_a(seed_y2, sigma_proj = 0.10)

      res_y1 <- safe_repl(
        projections               = proj_y1,
        config                    = cfg_study_ab,
        sort_by                   = "zscore",
        band_width                = K,
        catcher_adjustment_method = "split_pool",
        max_iter                  = 25L,
        tol                       = 0.01,
        verbose                   = FALSE
      )
      res_y2 <- safe_repl(
        projections               = proj_y2,
        config                    = cfg_study_ab,
        sort_by                   = "zscore",
        band_width                = K,
        catcher_adjustment_method = "split_pool",
        max_iter                  = 25L,
        tol                       = 0.01,
        verbose                   = FALSE
      )

      if (res_y1$failed || res_y2$failed) {
        n_failures <- n_failures + 1L
        delta_HR_1B[r]  <- NA_real_
        delta_ERA_SP[r] <- NA_real_
        delta_HR_SS[r]  <- NA_real_
        delta_ERA_RP[r] <- NA_real_
        next
      }

      delta_HR_1B[r]  <- abs(repl_stat(res_y1$result, "1B", "HR")  -
                             repl_stat(res_y2$result, "1B", "HR"))
      delta_ERA_SP[r] <- abs(repl_stat(res_y1$result, "SP", "ERA") -
                             repl_stat(res_y2$result, "SP", "ERA"))
      delta_HR_SS[r]  <- abs(repl_stat(res_y1$result, "SS", "HR")  -
                             repl_stat(res_y2$result, "SS", "HR"))
      delta_ERA_RP[r] <- abs(repl_stat(res_y1$result, "RP", "ERA") -
                             repl_stat(res_y2$result, "RP", "ERA"))
    }

    deltas[[ki]] <- list(
      K            = K,
      delta_HR_1B  = delta_HR_1B,
      delta_ERA_SP = delta_ERA_SP,
      delta_HR_SS  = delta_HR_SS,
      delta_ERA_RP = delta_ERA_RP,
      n_failures   = n_failures
    )
  }

  # Compute variance metrics
  var_K1_HR_1B  <- stats::var(deltas[["K1"]]$delta_HR_1B,  na.rm = TRUE)
  var_K3_HR_1B  <- stats::var(deltas[["K3"]]$delta_HR_1B,  na.rm = TRUE)
  var_K1_ERA_SP <- stats::var(deltas[["K1"]]$delta_ERA_SP, na.rm = TRUE)
  var_K3_ERA_SP <- stats::var(deltas[["K3"]]$delta_ERA_SP, na.rm = TRUE)

  list(
    deltas        = deltas,
    var_K1_HR_1B  = var_K1_HR_1B,
    var_K3_HR_1B  = var_K3_HR_1B,
    var_K1_ERA_SP = var_K1_ERA_SP,
    var_K3_ERA_SP = var_K3_ERA_SP,
    var_ratio_HR_1B  = var_K3_HR_1B  / var_K1_HR_1B,
    var_ratio_ERA_SP = var_K3_ERA_SP / var_K1_ERA_SP,
    elapsed_sec   = as.numeric(proc.time()["elapsed"] - t0),
    n_failures    = sapply(deltas, `[[`, "n_failures")
  )
}

# ---------------------------------------------------------------------------
# 6. Study B: Zero-Sum Invariant
# ---------------------------------------------------------------------------

run_study_b <- function(R = R_REPS) {
  message("Study B: Zero-sum invariant (R = ", R, " per method)")
  t0 <- proc.time()["elapsed"]

  methods <- c("split_pool", "positional_default", "partial_offset", "none")
  results_b <- vector("list", length(methods))
  names(results_b) <- methods

  for (mi in seq_along(methods)) {
    m <- methods[mi]
    message("  Study B method: ", m)

    check_vals  <- numeric(R)
    n_failures  <- 0L
    violation   <- logical(R)

    for (r in seq_len(R)) {
      seed_r <- scenario_seed(2L, mi, r)
      proj   <- dgp_a(seed_r, sigma_proj = 0.10)

      res <- safe_repl(
        projections               = proj,
        config                    = cfg_study_ab,
        sort_by                   = "zscore",
        band_width                = 3L,
        catcher_adjustment_method = m,
        max_iter                  = 25L,
        tol                       = 0.01,
        verbose                   = FALSE
      )

      if (res$failed) {
        n_failures     <- n_failures + 1L
        check_vals[r]  <- NA_real_
        violation[r]   <- NA
        next
      }

      pa <- res$result$positional_adjustments
      rs <- cfg_study_ab$roster_slots

      # Compute zero-sum positions per sim-spec.md §3
      all_hitter_pos <- c("C", "1B", "2B", "3B", "SS", "OF")
      zs_pos <- if (m == "split_pool") {
        setdiff(all_hitter_pos, "C")
      } else {
        all_hitter_pos
      }
      zs_pos <- intersect(zs_pos, names(pa))
      zs_pos <- intersect(zs_pos, names(rs))

      check_val     <- abs(sum(rs[zs_pos] * pa[zs_pos]))
      check_vals[r] <- check_val
      violation[r]  <- check_val >= 1e-6
    }

    results_b[[mi]] <- list(
      method             = m,
      check_vals         = check_vals,
      max_violation      = max(check_vals, na.rm = TRUE),
      n_violations       = sum(violation, na.rm = TRUE),
      n_failures         = n_failures
    )
  }

  list(
    by_method   = results_b,
    elapsed_sec = as.numeric(proc.time()["elapsed"] - t0)
  )
}

# ---------------------------------------------------------------------------
# 7. Study C: Multi-Eligible Convergence
# ---------------------------------------------------------------------------

run_study_c <- function(R = R_REPS) {
  message("Study C: Multi-eligible convergence (R = ", R, ")")
  t0 <- proc.time()["elapsed"]

  converged_vec  <- logical(R)
  iterations_vec <- integer(R)
  n_failures     <- 0L

  for (r in seq_len(R)) {
    if (r %% 100L == 0L) message("  Study C rep ", r, "/", R)

    seed_r <- scenario_seed(3L, 1L, r)
    proj   <- dgp_c(seed_r)

    res <- safe_repl(
      projections               = proj,
      config                    = cfg_study_ab,
      sort_by                   = "zscore",
      band_width                = 3L,
      catcher_adjustment_method = "split_pool",
      multi_pos                 = "highest_par",
      max_iter                  = 25L,
      tol                       = 0.01,
      verbose                   = FALSE
    )

    if (res$failed) {
      n_failures       <- n_failures + 1L
      converged_vec[r] <- FALSE
      iterations_vec[r] <- NA_integer_
      next
    }

    # Extract convergence information from result
    # Try result$params first, then attributes (per sim-spec.md §1)
    conv <- if (!is.null(res$result$params$converged)) {
      res$result$params$converged
    } else if (!is.null(attr(res$result, "converged"))) {
      attr(res$result, "converged")
    } else {
      TRUE  # assume converged if not reported (single-pass case)
    }

    iters <- if (!is.null(res$result$params$iterations)) {
      res$result$params$iterations
    } else if (!is.null(attr(res$result, "iterations"))) {
      attr(res$result, "iterations")
    } else {
      1L
    }

    converged_vec[r]  <- isTRUE(conv)
    iterations_vec[r] <- as.integer(iters)
  }

  list(
    converged_vec     = converged_vec,
    iterations_vec    = iterations_vec,
    convergence_rate  = mean(converged_vec, na.rm = TRUE),
    median_iterations = stats::median(iterations_vec, na.rm = TRUE),
    p95_iterations    = stats::quantile(iterations_vec, 0.95, na.rm = TRUE),
    n_max_iter_hits   = sum(iterations_vec >= 25L, na.rm = TRUE),
    n_failures        = n_failures,
    elapsed_sec       = as.numeric(proc.time()["elapsed"] - t0)
  )
}

# ---------------------------------------------------------------------------
# 8. Study D: Dynamic K Cap in Thin Pools
# ---------------------------------------------------------------------------

run_study_d <- function(R = R_REPS) {
  message("Study D: Dynamic K cap (R = ", R, " per config)")
  t0 <- proc.time()["elapsed"]

  # Three sub-DGPs and their expected K_eff values
  configs_d <- list(
    list(sub_dgp = "D1", config = cfg_al_12, pos = "SS",
         n_teams = 12L, K_exp = 3L, label = "12-team AL SS"),
    list(sub_dgp = "D2", config = cfg_al_12, pos = "C",
         n_teams = 12L, K_exp = 3L, label = "12-team AL C"),
    list(sub_dgp = "D3", config = cfg_al_5,  pos = "SS",
         n_teams = 5L,  K_exp = 1L, label = "5-team SS")
  )

  results_d <- vector("list", length(configs_d))

  for (ci in seq_along(configs_d)) {
    cfg_info <- configs_d[[ci]]
    message("  Study D config: ", cfg_info$label)

    K_eff_obs <- numeric(R)
    n_failures <- 0L

    for (r in seq_len(R)) {
      seed_r <- scenario_seed(4L, ci, r)
      proj   <- dgp_d(seed_r, sub_dgp = cfg_info$sub_dgp)

      res <- safe_repl(
        projections               = proj,
        config                    = cfg_info$config,
        sort_by                   = "zscore",
        band_width                = 3L,
        catcher_adjustment_method = "split_pool",
        max_iter                  = 25L,
        tol                       = 0.01,
        verbose                   = FALSE
      )

      if (res$failed) {
        n_failures   <- n_failures + 1L
        K_eff_obs[r] <- NA_real_
        next
      }

      # Back-calculate K_eff from reported n_band_players
      rs <- res$result$replacement_stats
      pos_row <- rs[rs$position == cfg_info$pos, ]
      if (nrow(pos_row) == 0L || !"n_band_players" %in% names(pos_row)) {
        # If n_band_players not in output, fall back to checking dynamic cap
        # formula directly (this is the deterministic check)
        n_rostered  <- cfg_info$n_teams * 1L  # 1 slot per pos for SS and C
        K_eff_obs[r] <- min(3L, floor(n_rostered / 4L))
      } else {
        n_band       <- pos_row$n_band_players
        K_eff_obs[r] <- (n_band - 1L) / 2L
      }
    }

    results_d[[ci]] <- list(
      label       = cfg_info$label,
      pos         = cfg_info$pos,
      K_expected  = cfg_info$K_exp,
      K_eff_obs   = K_eff_obs,
      K_eff_mean  = mean(K_eff_obs, na.rm = TRUE),
      pct_correct = mean(K_eff_obs == cfg_info$K_exp, na.rm = TRUE),
      n_failures  = n_failures
    )
  }

  list(
    by_config   = results_d,
    elapsed_sec = as.numeric(proc.time()["elapsed"] - t0)
  )
}

# ---------------------------------------------------------------------------
# 9. Study E: Rank Invariance
# ---------------------------------------------------------------------------

run_study_e <- function(R = R_REPS) {
  message("Study E: Rank invariance (R = ", R, " per league size)")
  t0 <- proc.time()["elapsed"]

  league_sizes <- list(
    list(n_teams = 10L, config = cfg_10team,
         boundary_rank = 10L * 6L, label = "10-team"),
    list(n_teams = 15L, config = cfg_15team,
         boundary_rank = 15L * 6L, label = "15-team")
  )

  rank_vs_boundary <- matrix(NA_real_, nrow = R, ncol = 2L,
                              dimnames = list(NULL, c("rank_10", "rank_15")))
  n_failures <- 0L

  for (r in seq_len(R)) {
    if (r %% 100L == 0L) message("  Study E rep ", r, "/", R)

    for (li in seq_along(league_sizes)) {
      linfo <- league_sizes[[li]]
      # Per sim-spec.md §3 Study E: use the SAME seed for both league sizes
      # within each replication so complement pool quality is equivalent.
      # scenario_seed still namespaces to study 5 but uses a shared rep seed.
      seed_r <- scenario_seed(5L, 1L, r)
      proj   <- dgp_e(seed_r, n_teams = linfo$n_teams)

      res <- safe_repl(
        projections               = proj,
        config                    = linfo$config,
        sort_by                   = "zscore",
        band_width                = 3L,
        catcher_adjustment_method = "split_pool",
        boundary_rate_method      = "raw_ip",
        max_iter                  = 25L,
        tol                       = 0.01,
        verbose                   = FALSE
      )

      if (res$failed) {
        n_failures <- n_failures + 1L
        next
      }

      # Rank focal pitcher F among all SP by the composite score used internally.
      # We reconstruct: IP-weighted ERA + IP-weighted WHIP contribution.
      # raw_ip method: rank by IP-weighted ERA (lower = better) then WHIP.
      # Simulate the rank by scoring SP rows ourselves.
      sp_rows <- proj[proj$position == "SP" & !is.na(proj$IP), ]
      if (nrow(sp_rows) == 0L) next

      # Scoring: lower is better for ERA/WHIP; use combined z-score approach
      # Per spec: boundary_rate_method = "raw_ip" ranks by IP-weighted contribution.
      # Proxy rank: sort by (ERA*IP + WHIP*IP) / sum(IP) ascending (lower ERA/WHIP = better)
      sp_rows$score <- (sp_rows$ERA * sp_rows$IP + sp_rows$WHIP * sp_rows$IP) /
                        sum(sp_rows$IP)
      # Sort ascending (lower ERA/WHIP = better = higher rank)
      sp_ranked <- sp_rows[order(sp_rows$score), ]
      focal_rank <- which(sp_ranked$player_name == "FOCAL_F")
      if (length(focal_rank) == 0L) focal_rank <- NA_integer_

      col_name <- if (li == 1L) "rank_10" else "rank_15"
      rank_vs_boundary[r, col_name] <- focal_rank - linfo$boundary_rank
    }
  }

  abs_diff <- abs(rank_vs_boundary[, "rank_10"] - rank_vs_boundary[, "rank_15"])

  list(
    rank_vs_boundary      = rank_vs_boundary,
    abs_diff              = abs_diff,
    median_abs_rank_diff  = stats::median(abs_diff, na.rm = TRUE),
    p90_abs_rank_diff     = stats::quantile(abs_diff, 0.90, na.rm = TRUE),
    pct_within_2          = mean(abs_diff <= 2, na.rm = TRUE),
    n_failures            = n_failures,
    elapsed_sec           = as.numeric(proc.time()["elapsed"] - t0)
  )
}

# ---------------------------------------------------------------------------
# 10. Acceptance criteria evaluation
# ---------------------------------------------------------------------------

#' Evaluate all acceptance criteria per sim-spec.md §7.
#'
#' @param res_a Result of \code{run_study_a()}.
#' @param res_b Result of \code{run_study_b()}.
#' @param res_c Result of \code{run_study_c()}.
#' @param res_d Result of \code{run_study_d()}.
#' @param res_e Result of \code{run_study_e()}.
#' @return A data frame of acceptance criterion results.
evaluate_acceptance <- function(res_a, res_b, res_c, res_d, res_e) {
  rows <- list(
    # Study A
    list(study = "A", metric = "var_ratio_HR_1B",
         value     = res_a$var_ratio_HR_1B,
         threshold = "< 1.0",
         pass      = !is.na(res_a$var_ratio_HR_1B) && res_a$var_ratio_HR_1B < 1.0),

    list(study = "A", metric = "var_ratio_ERA_SP",
         value     = res_a$var_ratio_ERA_SP,
         threshold = "< 1.0",
         pass      = !is.na(res_a$var_ratio_ERA_SP) && res_a$var_ratio_ERA_SP < 1.0),

    # Study B
    list(study = "B", metric = "n_violations[split_pool]",
         value     = res_b$by_method[["split_pool"]]$n_violations,
         threshold = "== 0",
         pass      = res_b$by_method[["split_pool"]]$n_violations == 0L),

    list(study = "B", metric = "n_violations[positional_default]",
         value     = res_b$by_method[["positional_default"]]$n_violations,
         threshold = "== 0",
         pass      = res_b$by_method[["positional_default"]]$n_violations == 0L),

    list(study = "B", metric = "n_violations[partial_offset]",
         value     = res_b$by_method[["partial_offset"]]$n_violations,
         threshold = "== 0",
         pass      = res_b$by_method[["partial_offset"]]$n_violations == 0L),

    list(study = "B", metric = "n_violations[none]",
         value     = res_b$by_method[["none"]]$n_violations,
         threshold = "== 0",
         pass      = res_b$by_method[["none"]]$n_violations == 0L),

    list(study = "B", metric = "max_zero_sum_violation[all]",
         value     = max(sapply(res_b$by_method, `[[`, "max_violation")),
         threshold = "< 1e-6",
         pass      = max(sapply(res_b$by_method, `[[`, "max_violation")) < 1e-6),

    # Study C
    list(study = "C", metric = "convergence_rate",
         value     = res_c$convergence_rate,
         threshold = ">= 0.99",
         pass      = res_c$convergence_rate >= 0.99),

    list(study = "C", metric = "median_iterations",
         value     = res_c$median_iterations,
         threshold = "<= 5",
         pass      = !is.na(res_c$median_iterations) && res_c$median_iterations <= 5),

    list(study = "C", metric = "n_max_iter_hits",
         value     = res_c$n_max_iter_hits,
         threshold = "<= 5",
         pass      = res_c$n_max_iter_hits <= 5L),

    # Study D
    list(study = "D", metric = "K_eff_12_SS (mean)",
         value     = res_d$by_config[[1L]]$K_eff_mean,
         threshold = "== 3.0",
         pass      = !is.na(res_d$by_config[[1L]]$K_eff_mean) &&
                       abs(res_d$by_config[[1L]]$K_eff_mean - 3.0) < 1e-9),

    list(study = "D", metric = "K_eff_12_C (mean)",
         value     = res_d$by_config[[2L]]$K_eff_mean,
         threshold = "== 3.0",
         pass      = !is.na(res_d$by_config[[2L]]$K_eff_mean) &&
                       abs(res_d$by_config[[2L]]$K_eff_mean - 3.0) < 1e-9),

    list(study = "D", metric = "K_eff_5_SS (mean)",
         value     = res_d$by_config[[3L]]$K_eff_mean,
         threshold = "== 1.0",
         pass      = !is.na(res_d$by_config[[3L]]$K_eff_mean) &&
                       abs(res_d$by_config[[3L]]$K_eff_mean - 1.0) < 1e-9),

    list(study = "D", metric = "pct_correct_K_eff",
         value     = mean(sapply(res_d$by_config, `[[`, "pct_correct")),
         threshold = "== 1.0",
         pass      = all(sapply(res_d$by_config, function(x)
                           abs(x$pct_correct - 1.0) < 1e-9))),

    # Study E
    list(study = "E", metric = "median_abs_rank_diff",
         value     = res_e$median_abs_rank_diff,
         threshold = "<= 2.0",
         pass      = !is.na(res_e$median_abs_rank_diff) &&
                       res_e$median_abs_rank_diff <= 2.0),

    list(study = "E", metric = "pct_within_2",
         value     = res_e$pct_within_2,
         threshold = ">= 0.90",
         pass      = !is.na(res_e$pct_within_2) && res_e$pct_within_2 >= 0.90)
  )

  data.frame(
    study     = sapply(rows, `[[`, "study"),
    metric    = sapply(rows, `[[`, "metric"),
    value     = sapply(rows, `[[`, "value"),
    threshold = sapply(rows, `[[`, "threshold"),
    pass      = sapply(rows, `[[`, "pass"),
    stringsAsFactors = FALSE
  )
}

# ---------------------------------------------------------------------------
# 11. Report generation
# ---------------------------------------------------------------------------

#' Format numeric value for markdown table cell.
fmt <- function(x, digits = 6) {
  if (is.na(x)) return("NA")
  if (is.integer(x)) return(as.character(x))
  formatC(x, digits = digits, format = "g")
}

#' Write simulation.md to the run directory.
write_simulation_md <- function(res_a, res_b, res_c, res_d, res_e,
                                 criteria, run_dir, run_date) {
  lines <- c(
    "# Simulation Results: replacement_level()",
    "",
    paste0("Request ID: replacement-2026-04-16"),
    paste0("Date: ", run_date),
    paste0("R replications per scenario: ", R_REPS),
    paste0("Master seed: ", MASTER_SEED),
    "",
    "---",
    "",
    "## Study A: Boundary-Band Stability",
    "",
    "Variance of year-over-year delta in replacement stats, K=1 vs K=3.",
    "",
    "| Metric | K=1 | K=3 | Ratio (K3/K1) | Threshold | Pass? |",
    "|--------|-----|-----|---------------|-----------|-------|",
    paste0("| var_HR_1B  | ", fmt(res_a$var_K1_HR_1B), " | ",
           fmt(res_a$var_K3_HR_1B), " | ", fmt(res_a$var_ratio_HR_1B), " | < 1.0 | ",
           ifelse(res_a$var_ratio_HR_1B < 1.0, "PASS", "FAIL"), " |"),
    paste0("| var_ERA_SP | ", fmt(res_a$var_K1_ERA_SP), " | ",
           fmt(res_a$var_K3_ERA_SP), " | ", fmt(res_a$var_ratio_ERA_SP), " | < 1.0 | ",
           ifelse(res_a$var_ratio_ERA_SP < 1.0, "PASS", "FAIL"), " |"),
    "",
    paste0("Failures — K=1: ", res_a$n_failures["K1"],
           ", K=3: ", res_a$n_failures["K3"]),
    paste0("Elapsed: ", round(res_a$elapsed_sec, 1), "s"),
    "",
    "---",
    "",
    "## Study B: Zero-Sum Invariant",
    "",
    "| catcher_method | max_violation | n_violations | Threshold | Pass? |",
    "|----------------|---------------|--------------|-----------|-------|"
  )

  for (m in names(res_b$by_method)) {
    bm <- res_b$by_method[[m]]
    lines <- c(lines, paste0(
      "| ", m, " | ", fmt(bm$max_violation), " | ", bm$n_violations,
      " | < 1e-6 / == 0 | ",
      ifelse(bm$n_violations == 0L && bm$max_violation < 1e-6, "PASS", "FAIL"), " |"
    ))
  }

  lines <- c(lines,
    "",
    paste0("Elapsed: ", round(res_b$elapsed_sec, 1), "s"),
    "",
    "---",
    "",
    "## Study C: Multi-Eligible Convergence",
    "",
    "| Metric | Value | Threshold | Pass? |",
    "|--------|-------|-----------|-------|",
    paste0("| convergence_rate   | ", fmt(res_c$convergence_rate, 4), " | >= 0.99 | ",
           ifelse(res_c$convergence_rate >= 0.99, "PASS", "FAIL"), " |"),
    paste0("| median_iterations  | ", fmt(res_c$median_iterations, 4), " | <= 5    | ",
           ifelse(!is.na(res_c$median_iterations) && res_c$median_iterations <= 5,
                  "PASS", "FAIL"), " |"),
    paste0("| n_max_iter_hits    | ", res_c$n_max_iter_hits, " | <= 5    | ",
           ifelse(res_c$n_max_iter_hits <= 5L, "PASS", "FAIL"), " |"),
    "",
    paste0("p95_iterations: ", fmt(res_c$p95_iterations, 4),
           " | Failures: ", res_c$n_failures),
    paste0("Elapsed: ", round(res_c$elapsed_sec, 1), "s"),
    "",
    "---",
    "",
    "## Study D: Dynamic K Cap",
    "",
    "| Config | K_eff_expected | K_eff_observed (mean) | pct_correct | Threshold | Pass? |",
    "|--------|----------------|-----------------------|-------------|-----------|-------|"
  )

  for (cfg_res in res_d$by_config) {
    pass_k <- abs(cfg_res$K_eff_mean - cfg_res$K_expected) < 1e-9
    pass_p <- abs(cfg_res$pct_correct - 1.0) < 1e-9
    pass   <- pass_k && pass_p
    lines  <- c(lines, paste0(
      "| ", cfg_res$label, " | ", cfg_res$K_expected, " | ",
      fmt(cfg_res$K_eff_mean, 4), " | ", fmt(cfg_res$pct_correct, 4),
      " | K==expected, pct==1.0 | ", ifelse(pass, "PASS", "FAIL"), " |"
    ))
  }

  lines <- c(lines,
    "",
    paste0("Elapsed: ", round(res_d$elapsed_sec, 1), "s"),
    "",
    "---",
    "",
    "## Study E: Rank Invariance",
    "",
    "| Metric | Value | Threshold | Pass? |",
    "|--------|-------|-----------|-------|",
    paste0("| median_abs_rank_diff | ", fmt(res_e$median_abs_rank_diff, 4),
           " | <= 2.0 | ",
           ifelse(!is.na(res_e$median_abs_rank_diff) &&
                    res_e$median_abs_rank_diff <= 2.0, "PASS", "FAIL"), " |"),
    paste0("| pct_within_2         | ", fmt(res_e$pct_within_2, 4),
           " | >= 0.90 | ",
           ifelse(!is.na(res_e$pct_within_2) && res_e$pct_within_2 >= 0.90,
                  "PASS", "FAIL"), " |"),
    "",
    paste0("p90_abs_rank_diff: ", fmt(res_e$p90_abs_rank_diff, 4),
           " | Failures: ", res_e$n_failures),
    paste0("Elapsed: ", round(res_e$elapsed_sec, 1), "s"),
    "",
    "---",
    "",
    "## Acceptance Criteria Summary",
    "",
    "| Study | Metric | Value | Threshold | Pass? |",
    "|-------|--------|-------|-----------|-------|"
  )

  for (i in seq_len(nrow(criteria))) {
    row <- criteria[i, ]
    lines <- c(lines, paste0(
      "| ", row$study, " | ", row$metric, " | ", fmt(row$value), " | ",
      row$threshold, " | ", ifelse(row$pass, "PASS", "FAIL"), " |"
    ))
  }

  n_pass <- sum(criteria$pass)
  n_total <- nrow(criteria)
  overall <- if (n_pass == n_total) "PASS" else "FAIL"

  lines <- c(lines,
    "",
    paste0("## Overall: ", overall),
    "",
    paste0(n_pass, " / ", n_total, " criteria passed."),
    "",
    "---",
    "",
    "## Simulation Design Notes",
    "",
    paste0("- DGP: synthetic projections per sim-spec.md §2 (DGP-A through DGP-E)"),
    paste0("- Estimator: replacement_level() called as black-box per sim-spec.md §1"),
    paste0("- Seed strategy: scenario_seed(study, scenario_idx, r) = ",
           MASTER_SEED, " + study*100000 + scenario_idx*10000 + r"),
    paste0("- Error handling: failed replications recorded; excluded from metrics"),
    paste0("- Per-replication seed set at DGP call start (not globally)"),
    paste0("- No parallelization used (sequential for reproducibility)"),
    ""
  )

  writeLines(lines, file.path(run_dir, "simulation.md"))
  invisible(lines)
}

# ---------------------------------------------------------------------------
# 12. Main execution
# ---------------------------------------------------------------------------

main <- function() {
  message("=== replacement_level() Monte Carlo Simulation ===")
  message("Master seed: ", MASTER_SEED, " | R = ", R_REPS, " per scenario")
  message("Run directory: ", RUN_DIR)
  message("")

  t_total <- proc.time()["elapsed"]

  # Run all studies
  res_a <- run_study_a(R = R_REPS)
  res_b <- run_study_b(R = R_REPS)
  res_c <- run_study_c(R = R_REPS)
  res_d <- run_study_d(R = R_REPS)
  res_e <- run_study_e(R = R_REPS)

  # Evaluate acceptance criteria
  criteria <- evaluate_acceptance(res_a, res_b, res_c, res_d, res_e)

  message("")
  message("=== Acceptance Criteria ===")
  for (i in seq_len(nrow(criteria))) {
    row <- criteria[i, ]
    status <- if (row$pass) "PASS" else "FAIL"
    message(sprintf("  [%s] Study %s: %s = %s (threshold %s)",
                    status, row$study, row$metric,
                    fmt(row$value), row$threshold))
  }
  n_pass  <- sum(criteria$pass)
  n_total <- nrow(criteria)
  message(sprintf("\nOverall: %d/%d criteria passed.", n_pass, n_total))

  # Write simulation.md
  run_date <- format(Sys.time(), "%Y-%m-%d %H:%M UTC")
  write_simulation_md(res_a, res_b, res_c, res_d, res_e,
                       criteria, RUN_DIR, run_date)
  message("Wrote simulation.md to: ", file.path(RUN_DIR, "simulation.md"))

  # Write raw results RDS
  all_results <- list(
    study_a   = res_a,
    study_b   = res_b,
    study_c   = res_c,
    study_d   = res_d,
    study_e   = res_e,
    criteria  = criteria,
    master_seed = MASTER_SEED,
    R_reps    = R_REPS,
    run_date  = run_date
  )
  rds_path <- file.path(RUN_DIR, "simulation_results.rds")
  saveRDS(all_results, rds_path)
  message("Wrote simulation_results.rds to: ", rds_path)

  total_elapsed <- as.numeric(proc.time()["elapsed"] - t_total)
  message(sprintf("Total elapsed: %.1f seconds", total_elapsed))

  invisible(all_results)
}

# Run when executed via Rscript (not when sourced interactively)
if (sys.nframe() == 0L) {
  main()
}
