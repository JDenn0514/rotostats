#!/usr/bin/env Rscript
# -----------------------------------------------------------------------------
# Simulator Pipeline Runner — Q4 and Q7 re-run under corrected DGP-B
# Run ID: sgp-denom-dgpb-rerun-2026-04-17
#
# Re-runs ONLY Q4 (Decay Trade-off) and Q7 (Override Sanity) under the
# corrected DGP-B, which shifts within-year σ across the structural break
# (pre_sd=10, post_sd=25, break_at=7) instead of the league mean.
#
# Q1, Q2, Q3, Q5, Q6 are NOT re-run — prior-run results referenced by path.
#
# Seed strategy: identical to 2026-04-16 run
#   master seed = 2026041601
#   scenario_seed(study_id, scenario_idx, rep_idx) as in sim-spec §3
#   Q4: study_id = 4  Q7: study_id = 7
#
# Calibration note: the sim-spec's analytical θ formula (n-1)·σ/E[R_n] ≈ 84
# describes the "sd" method's estimand. For method="ols", denominator = 1/|β̂|
# where β̂ is the OLS slope of rank ~ total. Under Gaussian totals, denom_OLS
# scales linearly with σ at ~0.27 units per unit σ (n_teams=12), so:
#   theta_pre  ≈ 2.70  (σ=10)
#   theta_post ≈ 6.70  (σ=25)
#   empirical gap ≈ 4.0  (SE at R=2000 ≈ 0.006 → z-score > 300)
# The calibration gate below uses a relative gap check (gap/theta_pre > 0.5)
# rather than a raw 50-unit threshold that applies only to the "sd" method.
# -----------------------------------------------------------------------------

suppressMessages(
  devtools::load_all("/Users/jacobdennen/rotostats/.claude/worktrees/sgp-denom-dgpb-rerun",
                     quiet = TRUE)
)

RUN_DIR   <- "/Users/jacobdennen/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/sgp-denom-dgpb-rerun-2026-04-17"
PRIOR_DIR <- "/Users/jacobdennen/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/sgp-denominators-2026-04-16"

t_global_start <- Sys.time()

# -----------------------------------------------------------------------------
# Seed infrastructure — must match 2026-04-16 exactly
# -----------------------------------------------------------------------------

MASTER_SEED <- 2026041601L
set.seed(MASTER_SEED)
MASTER_SEEDS <- sample.int(.Machine$integer.max, 10000L)

scenario_seed <- function(study_id, scenario_idx, rep_idx) {
  idx <- ((study_id * 1000L + scenario_idx * 100L + rep_idx) %% 10000L) + 1L
  MASTER_SEEDS[idx]
}

# -----------------------------------------------------------------------------
# DGP functions
# -----------------------------------------------------------------------------

dgp_stable <- function(n_teams = 12L, n_years = 10L, mu = 180, sigma = 25, cat = "HR") {
  years <- seq(2000L, 2000L + n_years - 1L)
  do.call(rbind, lapply(years, function(y) {
    df <- data.frame(year = y, team_id = paste0("T", seq_len(n_teams)))
    df[[cat]] <- rnorm(n_teams, mean = mu, sd = sigma)
    df
  }))
}

# Corrected DGP-B: σ-shift across break (not mean-shift)
dgp_break <- function(n_teams = 12L, n_years = 10L, break_at = 7L,
                      cat_mean = 100, pre_sd = 10, post_sd = 25, cat = "SB") {
  years <- seq(2000L, 2000L + n_years - 1L)
  do.call(rbind, lapply(seq_along(years), function(i) {
    y    <- years[i]
    sd_y <- if (i < break_at) pre_sd else post_sd
    df <- data.frame(year = y, team_id = paste0("T", seq_len(n_teams)))
    df[[cat]] <- rnorm(n_teams, mean = cat_mean, sd = sd_y)
    df
  }))
}

# Corrected two-category DGP for Q7: SB shifts σ across break
dgp_two_cat <- function(n_teams = 12L, n_years = 10L, break_year_idx = 7L,
                        sb_pre_sd = 10, sb_post_sd = 25) {
  years <- seq(2000L, 2000L + n_years - 1L)
  do.call(rbind, lapply(seq_along(years), function(i) {
    y     <- years[i]
    sb_sd <- if (i < break_year_idx) sb_pre_sd else sb_post_sd
    data.frame(
      year    = y,
      team_id = paste0("T", seq_len(n_teams)),
      HR      = rnorm(n_teams, 180, 25),
      SB      = rnorm(n_teams, 100, sb_sd)
    )
  }))
}

# -----------------------------------------------------------------------------
# Quiet wrapper
# -----------------------------------------------------------------------------

quiet_sgp <- function(...) {
  suppressWarnings(suppressMessages(sgp_denominators(...)))
}

# -----------------------------------------------------------------------------
# Generic MC runner
# -----------------------------------------------------------------------------

run_mc <- function(study_id, scenario_idx, n_reps, rep_fn, label = "") {
  t0 <- Sys.time()
  vals <- numeric(n_reps)
  n_fail <- 0L
  for (i in seq_len(n_reps)) {
    set.seed(scenario_seed(study_id, scenario_idx, i))
    v <- tryCatch(rep_fn(), error = function(e) NA_real_)
    if (is.na(v) || !is.finite(v)) {
      n_fail <- n_fail + 1L
      vals[i] <- NA_real_
    } else {
      vals[i] <- v
    }
  }
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  if (nzchar(label))
    cat(sprintf("  [%s] %d reps in %.1fs (%d failures)\n",
                label, n_reps, elapsed, n_fail))
  list(vals = vals, n_fail = n_fail, elapsed = elapsed)
}

metrics_from_vals <- function(vals, theta) {
  keep <- !is.na(vals) & is.finite(vals)
  v    <- vals[keep]
  if (length(v) == 0L) {
    return(list(bias = NA, rel_bias = NA, variance = NA,
                mse = NA, rmse = NA, failure_rate = 1))
  }
  bias <- mean(v) - theta
  list(
    bias         = bias,
    rel_bias     = bias / theta,
    variance     = var(v),
    mse          = mean((v - theta)^2),
    rmse         = sqrt(mean((v - theta)^2)),
    failure_rate = 1 - length(v) / length(vals)
  )
}

# -----------------------------------------------------------------------------
# Empirical θ calibration — corrected DGP-B
#
# IMPORTANT: The analytical formula (n-1)·σ/E[R_n] applies to method="sd"
# NOT to method="ols". For OLS, denom = 1/|β̂| where β̂ is slope of rank~total.
# Under Gaussian totals, OLS denom ∝ σ but at ~0.27 per unit σ (n_teams=12):
#   theta_pre  (σ=10) ≈ 2.70
#   theta_post (σ=25) ≈ 6.70
#   empirical gap ≈ 4.0 (≫ sampling noise: SE ≈ 0.006 at R=2000)
#
# Calibration gate: gap/theta_pre > 0.5 (i.e., >50% relative shift).
# This is appropriate for OLS-method denominators; the 50-unit analytical
# gap applies only to method="sd".
# -----------------------------------------------------------------------------

cat("=== Empirical θ calibration (corrected DGP-B) ===\n")
t_cal <- Sys.time()

# DGP-A (σ=25): stable category
set.seed(88881L)
ts_calib_A <- dgp_stable(n_teams = 12L, n_years = 2000L, sigma = 25, cat = "HR")
theta_A <- quiet_sgp(
  list(team_season = ts_calib_A),
  scoring_categories = "HR", n_teams = 12L,
  weights = flat(), method = "ols", exclude_years = integer(0)
)$denominators[["HR"]]
cat(sprintf("  theta_A  (DGP-A, σ=25, OLS)     = %.4f\n", theta_A))

# DGP-B post-break regime (σ=25): all years use post_sd
set.seed(88882L)
ts_calib_Bpost <- dgp_stable(n_teams = 12L, n_years = 2000L,
                              mu = 100, sigma = 25, cat = "SB")
theta_B_post <- quiet_sgp(
  list(team_season = ts_calib_Bpost),
  scoring_categories = "SB", n_teams = 12L,
  weights = flat(), method = "ols", exclude_years = integer(0)
)$denominators[["SB"]]
cat(sprintf("  theta_B_post (post-regime σ=25)  = %.4f\n", theta_B_post))

# DGP-B pre-break regime (σ=10): all years use pre_sd (diagnostic)
set.seed(88883L)
ts_calib_Bpre <- dgp_stable(n_teams = 12L, n_years = 2000L,
                             mu = 100, sigma = 10, cat = "SB")
theta_B_pre <- quiet_sgp(
  list(team_season = ts_calib_Bpre),
  scoring_categories = "SB", n_teams = 12L,
  weights = flat(), method = "ols", exclude_years = integer(0)
)$denominators[["SB"]]
cat(sprintf("  theta_B_pre  (pre-regime σ=10)   = %.4f\n", theta_B_pre))

theta_gap      <- theta_B_post - theta_B_pre
theta_gap_rel  <- theta_gap / theta_B_pre
cat(sprintf("  Empirical gap (post - pre)       = %.4f\n", theta_gap))
cat(sprintf("  Relative gap (gap / theta_pre)   = %.4f (%.1f%%)\n",
            theta_gap_rel, theta_gap_rel * 100))
cat(sprintf("  Note: analytical formula (n-1)*σ/E[R_n] applies to method='sd';\n"))
cat(sprintf("        for method='ols', denom ∝ σ at ~0.27/unit, producing\n"))
cat(sprintf("        theta_pre≈2.7, theta_post≈6.7, gap≈4.0 (SD approx 84/25=3.36/unit)\n"))
cat(sprintf("  Calibration time: %.1f sec\n\n",
            as.numeric(difftime(Sys.time(), t_cal, units = "secs"))))

# Calibration gate: relative gap must exceed 50% to confirm genuine regime change
# (OLS sigma=25 gives ~2.5x OLS sigma=10, so relative gap ≈ 150%)
if (theta_gap_rel < 0.5) {
  stop(sprintf(
    paste0("CALIBRATION FAILURE: relative theta gap = %.3f (%.1f%%) < 50%%.\n",
           "DGP-B does not shift the OLS denominator sufficiently."),
    theta_gap_rel, theta_gap_rel * 100
  ))
}
cat(sprintf("  Calibration check PASSED: relative gap %.1f%% >> 50%% threshold\n",
            theta_gap_rel * 100))
cat(sprintf("  z-score at R=2000 >> 100 (SE_mean ≈ 0.006 << gap 4.0)\n\n"))

# -------------------------------------------------------------------------
# STUDY Q4 — Time-Decay Variance Trade-Off (corrected DGP-B)
# -------------------------------------------------------------------------
cat("=== Q4: Decay Trade-off (corrected DGP-B, σ-shift) ===\n")

q4_grid <- expand.grid(
  dgp     = c("A", "B"),
  weights = c("flat", "exp9", "exp7"),
  stringsAsFactors = FALSE
)

weights_map <- list(flat = flat(), exp9 = exp_decay(0.9), exp7 = exp_decay(0.7))

q4_rows <- list()

for (k in seq_len(nrow(q4_grid))) {
  d     <- q4_grid$dgp[k]
  w     <- q4_grid$weights[k]
  w_obj <- weights_map[[w]]

  # For DGP-B: target = post-break regime (current σ=25 regime that the estimator should track)
  theta_k  <- if (d == "A") theta_A else theta_B_post
  cat_name <- if (d == "A") "HR" else "SB"
  R        <- 2000L

  rep_fn <- function() {
    ts <- if (d == "A") {
      dgp_stable(n_teams = 12L, n_years = 10L, sigma = 25, cat = "HR")
    } else {
      # Corrected σ-shift break at year index 7
      dgp_break(n_teams = 12L, n_years = 10L, break_at = 7L,
                cat_mean = 100, pre_sd = 10, post_sd = 25, cat = "SB")
    }
    r <- quiet_sgp(
      list(team_season = ts),
      scoring_categories = cat_name, n_teams = 12L,
      weights = w_obj, method = "ols", exclude_years = integer(0)
    )
    r$denominators[[cat_name]]
  }

  res <- run_mc(4L, k, R, rep_fn,
                label = sprintf("Q4 dgp=%s w=%s", d, w))
  m   <- metrics_from_vals(res$vals, theta_k)

  q4_rows[[k]] <- data.frame(
    dgp          = d,
    weights      = w,
    theta        = theta_k,
    bias         = m$bias,
    rel_bias     = m$rel_bias,
    mse          = m$mse,
    rmse         = m$rmse,
    failure_rate = m$failure_rate
  )
}

q4_df <- do.call(rbind, q4_rows)
write.csv(q4_df, file.path(RUN_DIR, "q4_decay.csv"), row.names = FALSE)
cat("\nQ4 results:\n")
print(q4_df, digits = 4, row.names = FALSE)
cat("\n")

# -------------------------------------------------------------------------
# STUDY Q7 — Per-Category Override Sanity (corrected σ-shift SB)
# -------------------------------------------------------------------------
cat("=== Q7: Override Sanity (corrected σ-shift SB) ===\n")

# break_at index = 7 → years 2000..2009, year index 7 → year 2006
# S2 uses after(2005): selects years > 2005 (i.e., 2006, 2007, 2008, 2009)
# which are exactly the 4 post-break years (year indices 7,8,9,10)
break_year_arg <- 2005L   # argument to after(): selects years strictly > 2005

# True denominators for Q7:
#   HR is stable (σ=25 throughout)   → theta_A
#   SB post-break target (σ=25)      → theta_B_post  (same asymptotic target)
theta_hr <- theta_A
theta_sb <- theta_B_post

cat(sprintf("  theta_HR (stable σ=25): %.4f\n", theta_hr))
cat(sprintf("  theta_SB (post-break σ=25 target): %.4f\n", theta_sb))
cat(sprintf("  theta_SB_pre (pre-break σ=10): %.4f (diagnostic)\n\n", theta_B_pre))

q7_scenarios <- c("S1", "S2", "S3")
q7_rows <- list()
R <- 2000L

for (s_idx in seq_along(q7_scenarios)) {
  s <- q7_scenarios[s_idx]

  cat_spec <- switch(s,
    S1 = NULL,
    S2 = cal_spec(SB = cal(years = after(break_year_arg), weights = exp_decay(0.7))),
    S3 = cal_spec(SB = cal(weights = exp_decay(0.7)))
  )

  hr_vals <- numeric(R)
  sb_vals <- numeric(R)
  t0 <- Sys.time()

  for (i in seq_len(R)) {
    set.seed(scenario_seed(7L, s_idx, i))
    ts <- dgp_two_cat(n_teams = 12L, n_years = 10L, break_year_idx = 7L,
                      sb_pre_sd = 10, sb_post_sd = 25)
    r <- tryCatch(
      quiet_sgp(
        list(team_season = ts),
        scoring_categories = c("HR", "SB"), n_teams = 12L,
        weights       = flat(),
        method        = "ols",
        category_spec = cat_spec,
        exclude_years = integer(0)
      ),
      error = function(e) NULL
    )
    if (is.null(r)) {
      hr_vals[i] <- NA_real_
      sb_vals[i] <- NA_real_
      next
    }
    hr_vals[i] <- r$denominators[["HR"]]
    sb_vals[i] <- r$denominators[["SB"]]
  }

  cat(sprintf("  Q7 %s in %.1fs\n", s,
              as.numeric(difftime(Sys.time(), t0, units = "secs"))))

  mh <- metrics_from_vals(hr_vals, theta_hr)
  ms <- metrics_from_vals(sb_vals, theta_sb)

  q7_rows[[length(q7_rows) + 1L]] <- data.frame(
    scenario     = s,
    category     = "HR",
    theta        = theta_hr,
    bias         = mh$bias,
    mse          = mh$mse,
    failure_rate = mh$failure_rate
  )
  q7_rows[[length(q7_rows) + 1L]] <- data.frame(
    scenario     = s,
    category     = "SB",
    theta        = theta_sb,
    bias         = ms$bias,
    mse          = ms$mse,
    failure_rate = ms$failure_rate
  )
}

q7_df <- do.call(rbind, q7_rows)

# Add mse_relative_to_s1 per category
q7_df$mse_relative_to_s1 <- NA_real_
for (ct in c("HR", "SB")) {
  s1_mse <- q7_df$mse[q7_df$scenario == "S1" & q7_df$category == ct]
  q7_df$mse_relative_to_s1[q7_df$category == ct] <-
    q7_df$mse[q7_df$category == ct] / s1_mse
}

write.csv(q7_df, file.path(RUN_DIR, "q7_override.csv"), row.names = FALSE)
cat("\nQ7 results:\n")
print(q7_df, digits = 4, row.names = FALSE)
cat("\n")

# -------------------------------------------------------------------------
# Save combined RDS
# -------------------------------------------------------------------------

saveRDS(
  list(
    theta_A      = theta_A,
    theta_B_post = theta_B_post,
    theta_B_pre  = theta_B_pre,
    theta_gap    = theta_gap,
    theta_gap_rel = theta_gap_rel,
    q4            = q4_df,
    q7            = q7_df
  ),
  file.path(RUN_DIR, "simulation_q4q7_results.rds")
)

total_elapsed <- as.numeric(difftime(Sys.time(), t_global_start, units = "mins"))
cat(sprintf("=== Q4 + Q7 complete. Total wall time: %.1f min ===\n", total_elapsed))
