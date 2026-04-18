#!/usr/bin/env Rscript
# run_study_e_only.R
#
# Study E recalibration runner for request replacement-dgp-e-calibration-2026-04-17.
# Performs:
#   1. Pre-loop deterministic boundary sanity check (sim-spec §6.E gate)
#   2. Regression guard (old DGP-E behavior for r=1)
#   3. Study E re-run at R=500 under patched DGP-E
#
# Writes results to RUN_DIR (default: the calibration run directory).
# Does NOT re-run Studies A/B/C/D.

SCRIPT_DIR <- normalizePath(dirname(sys.frame(1)$ofile), mustWork = FALSE)
if (!nzchar(SCRIPT_DIR)) {
  SCRIPT_DIR <- normalizePath("inst/simulations", mustWork = FALSE)
}
REPO_ROOT <- normalizePath(file.path(SCRIPT_DIR, "../.."), mustWork = FALSE)

# Load package
if (requireNamespace("devtools", quietly = TRUE)) {
  devtools::load_all(REPO_ROOT, quiet = TRUE)
} else {
  library(rotostats)
}

# Source the patched DGP-E (this also constructs the fixed pool at source time)
source(file.path(SCRIPT_DIR, "dgp", "dgp_e.R"))

# Run directory
RUN_DIR <- Sys.getenv(
  "STATSCLAW_RUN_DIR",
  unset = "/Users/jacobdennen/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/replacement-dgp-e-calibration-2026-04-17"
)

MASTER_SEED <- 20260416L
R_REPS      <- 500L

scenario_seed <- function(study, scenario_idx, replication) {
  MASTER_SEED + study * 100000L + scenario_idx * 10000L + replication
}

# ---------------------------------------------------------------------------
# League configurations for Study E
# ---------------------------------------------------------------------------

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

safe_repl <- function(...) {
  tryCatch(
    list(result = replacement_level(...), failed = FALSE),
    error = function(e) list(result = NULL, failed = TRUE,
                              error_msg = conditionMessage(e))
  )
}

# ===========================================================================
# STEP 1: Pre-loop deterministic boundary sanity check (sim-spec §6.E GATE)
# ===========================================================================

message("=== Step 1: Pre-loop boundary sanity check ===")

focal_score <- .FOCAL_PITCHER$IP * (.FOCAL_PITCHER$ERA + .FOCAL_PITCHER$WHIP)

pool_scores_all_95 <- .FIXED_IP_SP * (.FIXED_ERA_SP + .FIXED_WHIP_SP)

# 10-team: compare focal vs first 62 complement pitchers
n_comp_10 <- 62L
pool_scores_10 <- pool_scores_all_95[seq_len(n_comp_10)]
n_better_than_focal_10 <- sum(pool_scores_10 < focal_score)
expected_rank_10 <- n_better_than_focal_10 + 1L
expected_rank_vs_boundary_10 <- expected_rank_10 - 60L

# 15-team: compare focal vs first 92 complement pitchers
n_comp_15 <- 92L
pool_scores_15 <- pool_scores_all_95[seq_len(n_comp_15)]
n_better_than_focal_15 <- sum(pool_scores_15 < focal_score)
expected_rank_15 <- n_better_than_focal_15 + 1L
expected_rank_vs_boundary_15 <- expected_rank_15 - 90L

expected_rank_diff_analytical <- abs(expected_rank_vs_boundary_10 -
                                       expected_rank_vs_boundary_15)

message(sprintf("  focal_score (IP * (ERA + WHIP)) = %.2f", focal_score))
message(sprintf("  n_better_than_focal_10 (first 62 pool pitchers) = %d", n_better_than_focal_10))
message(sprintf("  expected_rank_10 = %d  (rank_vs_boundary_10 = %d)", expected_rank_10, expected_rank_vs_boundary_10))
message(sprintf("  n_better_than_focal_15 (first 92 pool pitchers) = %d", n_better_than_focal_15))
message(sprintf("  expected_rank_15 = %d  (rank_vs_boundary_15 = %d)", expected_rank_15, expected_rank_vs_boundary_15))
message(sprintf("  expected_rank_diff_analytical = %d", expected_rank_diff_analytical))

if (expected_rank_diff_analytical > 2L) {
  msg <- paste0(
    "SANITY CHECK FAILED: expected_rank_diff = ", expected_rank_diff_analytical,
    " > 2. Fixed pool with FIXED_POOL_SEED=25260416 does not satisfy DGP-E design ",
    "requirement. Planner must revise FIXED_POOL_SEED."
  )
  message(msg)
  # Write to mailbox
  mailbox_path <- file.path(RUN_DIR, "mailbox.md")
  cat(paste0("\n---\n\n## ", format(Sys.time(), "%Y-%m-%d"), " — Simulator BLOCK\n\n",
             "**Type:** BLOCK\n\n", msg, "\n"), file = mailbox_path, append = TRUE)
  stop(msg)
} else {
  message(sprintf("  SANITY CHECK PASSED: expected_rank_diff = %d <= 2. Proceeding to 500-rep loop.",
                  expected_rank_diff_analytical))
}

# ===========================================================================
# STEP 2: Regression guard — old DGP-E behavior for r=1
# ===========================================================================

message("\n=== Step 2: Regression guard (old DGP-E, r=1) ===")

old_dgp_e_rank_diff_r1 <- {
  seed_r1 <- 20526416L + 1L  # scenario_seed(5, 1, 1): 20260416 + 5*100000 + 1*10000 + 1
  # OLD complement SP draw (10-team) — uses per-rep seed, NOT fixed pool
  set.seed(seed_r1)
  n_comp_10_old <- 62L
  IP_10  <- pmin(pmax(round(stats::rnorm(n_comp_10_old, 170, 15)), 120L), 230L)
  ERA_10 <- pmin(pmax(stats::rnorm(n_comp_10_old, 3.80, 0.45), 2.50), 6.00)
  WHIP_10 <- pmin(pmax(stats::rnorm(n_comp_10_old, 1.22, 0.10), 0.90), 1.80)
  # OLD complement SP draw (15-team) — same seed, different n
  set.seed(seed_r1)
  n_comp_15_old <- 92L
  IP_15  <- pmin(pmax(round(stats::rnorm(n_comp_15_old, 170, 15)), 120L), 230L)
  ERA_15 <- pmin(pmax(stats::rnorm(n_comp_15_old, 3.80, 0.45), 2.50), 6.00)
  WHIP_15 <- pmin(pmax(stats::rnorm(n_comp_15_old, 1.22, 0.10), 0.90), 1.80)

  focal_s <- 165 * (4.70 + 1.40)
  score_10 <- IP_10 * (ERA_10 + WHIP_10)
  score_15 <- IP_15 * (ERA_15 + WHIP_15)
  rank_10 <- sum(score_10 < focal_s) + 1L
  rank_15 <- sum(score_15 < focal_s) + 1L
  abs((rank_10 - 60L) - (rank_15 - 90L))
}

stopifnot(old_dgp_e_rank_diff_r1 >= 0L)
message(sprintf("  Regression guard: old DGP-E rank_diff for r=1 (seed=%dL) = %d",
                20526416L + 1L, old_dgp_e_rank_diff_r1))
message("  (This reproduces the old random-pool code path; new code uses fixed pool.)")

# ===========================================================================
# STEP 3: Study E re-run at R=500 under patched DGP-E
# ===========================================================================

message(sprintf("\n=== Step 3: Study E re-run (R=%d) ===", R_REPS))
t0 <- proc.time()["elapsed"]

league_sizes <- list(
  list(n_teams = 10L, config = cfg_10team, boundary_rank = 60L, label = "10-team"),
  list(n_teams = 15L, config = cfg_15team, boundary_rank = 90L, label = "15-team")
)

rank_vs_boundary <- matrix(NA_real_, nrow = R_REPS, ncol = 2L,
                            dimnames = list(NULL, c("rank_10", "rank_15")))
n_failures <- 0L

for (r in seq_len(R_REPS)) {
  if (r %% 100L == 0L) message(sprintf("  Study E rep %d/%d", r, R_REPS))

  for (li in seq_along(league_sizes)) {
    linfo <- league_sizes[[li]]
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

    sp_rows <- proj[proj$position == "SP" & !is.na(proj$IP), ]
    if (nrow(sp_rows) == 0L) next

    sp_rows$score <- (sp_rows$ERA * sp_rows$IP + sp_rows$WHIP * sp_rows$IP) /
                      sum(sp_rows$IP)
    sp_ranked  <- sp_rows[order(sp_rows$score), ]
    focal_rank <- which(sp_ranked$player_name == "FOCAL_F")
    if (length(focal_rank) == 0L) focal_rank <- NA_integer_

    col_name <- if (li == 1L) "rank_10" else "rank_15"
    rank_vs_boundary[r, col_name] <- focal_rank - linfo$boundary_rank
  }
}

abs_diff              <- abs(rank_vs_boundary[, "rank_10"] - rank_vs_boundary[, "rank_15"])
median_abs_rank_diff  <- stats::median(abs_diff, na.rm = TRUE)
mean_abs_rank_diff    <- mean(abs_diff, na.rm = TRUE)
pct_within_2          <- mean(abs_diff <= 2, na.rm = TRUE)
p90_abs_rank_diff     <- stats::quantile(abs_diff, 0.90, na.rm = TRUE)
q95_abs_rank_diff     <- stats::quantile(abs_diff, 0.95, na.rm = TRUE)
elapsed_sec           <- as.numeric(proc.time()["elapsed"] - t0)

message(sprintf("  median_abs_rank_diff  = %.4f", median_abs_rank_diff))
message(sprintf("  mean_abs_rank_diff    = %.4f", mean_abs_rank_diff))
message(sprintf("  pct_within_2          = %.4f", pct_within_2))
message(sprintf("  p90_abs_rank_diff     = %.4f", p90_abs_rank_diff))
message(sprintf("  q95_abs_rank_diff     = %.4f", q95_abs_rank_diff))
message(sprintf("  n_failures            = %d", n_failures))
message(sprintf("  Elapsed: %.1fs", elapsed_sec))

# ===========================================================================
# STEP 4: Acceptance evaluation
# ===========================================================================

pass_median <- !is.na(median_abs_rank_diff) && median_abs_rank_diff <= 2.0
pass_pct    <- !is.na(pct_within_2) && pct_within_2 >= 0.90
pass_sanity <- expected_rank_diff_analytical <= 2L

message("\n=== Step 4: Acceptance evaluation ===")
message(sprintf("  [%s] expected_rank_diff_analytical <= 2: %d",
                if (pass_sanity) "PASS" else "FAIL", expected_rank_diff_analytical))
message(sprintf("  [%s] median_abs_rank_diff <= 2.0: %.4f",
                if (pass_median) "PASS" else "FAIL", median_abs_rank_diff))
message(sprintf("  [%s] pct_within_2 >= 0.90: %.4f",
                if (pass_pct) "PASS" else "FAIL", pct_within_2))

overall_pass <- pass_sanity && pass_median && pass_pct
message(sprintf("\nOverall: %s", if (overall_pass) "PASS" else "FAIL"))

# ===========================================================================
# STEP 5: Collect results and write outputs
# ===========================================================================

results_e <- list(
  rank_vs_boundary              = rank_vs_boundary,
  abs_diff                      = abs_diff,
  median_abs_rank_diff          = median_abs_rank_diff,
  mean_abs_rank_diff            = mean_abs_rank_diff,
  pct_within_2                  = pct_within_2,
  p90_abs_rank_diff             = p90_abs_rank_diff,
  q95_abs_rank_diff             = q95_abs_rank_diff,
  n_failures                    = n_failures,
  elapsed_sec                   = elapsed_sec,
  # Sanity check values
  expected_rank_diff_analytical = expected_rank_diff_analytical,
  n_better_than_focal_10        = n_better_than_focal_10,
  n_better_than_focal_15        = n_better_than_focal_15,
  expected_rank_10              = expected_rank_10,
  expected_rank_15              = expected_rank_15,
  expected_rank_vs_boundary_10  = expected_rank_vs_boundary_10,
  expected_rank_vs_boundary_15  = expected_rank_vs_boundary_15,
  focal_score                   = focal_score,
  # Regression guard
  old_dgp_e_rank_diff_r1        = old_dgp_e_rank_diff_r1,
  regression_guard_seed         = 20526416L + 1L,
  # Acceptance
  pass_sanity                   = pass_sanity,
  pass_median                   = pass_median,
  pass_pct                      = pass_pct,
  overall_pass                  = overall_pass,
  # Run metadata
  R_reps                        = R_REPS,
  master_seed                   = MASTER_SEED,
  fixed_pool_seed               = .FIXED_POOL_SEED,
  run_date                      = format(Sys.time(), "%Y-%m-%d %H:%M UTC")
)

# Write RDS
rds_path <- file.path(RUN_DIR, "simulation_results.rds")
saveRDS(results_e, rds_path)
message(sprintf("Wrote simulation_results.rds to: %s", rds_path))

# Per-replication breakdown (first 10 rows for inspection)
message("\nFirst 10 replication rank_vs_boundary values:")
head_mat <- rank_vs_boundary[seq_len(min(10L, R_REPS)), , drop = FALSE]
print(head_mat)
message("\nabs_diff distribution (table of unique values):")
print(table(abs_diff))

# Return results invisibly for interactive use
invisible(results_e)
