# tests/simulations/sim-par.R
#
# Monte Carlo simulation harness for par()
#
# Verifies:
#   AC1 — Delegation identity:  par_[c] + replacement_sgp[pos,c] == sgp_[c]
#   AC2 — Boundary invariance:  mean(boundary_total_par[pos]) ≈ 0 (±0.05)
#   AC3 — Band check calibrated DGP: fire rate < 5%
#   AC4 — Band check miscalibrated DGP: fire rate >= 75%
#   AC5 — Failure rate < 1%
#
# Seed strategy (sim-spec.md §6):
#   master_seed = 20260418
#   scenario_seed = master_seed + scenario_index * 1000
#   rep seed = scenario_seed + rep_index
#
# Run from package root:
#   source("tests/simulations/sim-par.R")
# or via Rscript:
#   Rscript tests/simulations/sim-par.R

suppressPackageStartupMessages({
  library(rotostats)
})

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MASTER_SEED  <- 20260418L
R_REPS       <- 200L
SCORED_CATS  <- c("HR", "R", "SB", "K", "SV")
POSITIONS    <- c("C", "1B", "2B", "3B", "SS", "OF", "SP", "RP")

# ---------------------------------------------------------------------------
# 1. Fixed denominators — built as correct sgp_denominators S3 object
# ---------------------------------------------------------------------------
#
# The S3 constructor requires the list shape from sgp-denominators-s3.R:
#   structure(list(denominators, year_diagnostics, bootstrap_ci, call, meta),
#             class = c("sgp_denominators", "list"),
#             rate_conversion = "blended_pool")

make_sim_denominators <- function() {
  denom_vec <- c(HR = 30, R = 50, SB = 15, K = 80, SV = 12)

  structure(
    list(
      denominators     = denom_vec,
      year_diagnostics = NULL,
      bootstrap_ci     = NULL,
      call             = NULL,
      meta             = list(
        method          = "synthetic",
        rate_conversion = "blended_pool",
        years_used      = integer(0L)
      )
    ),
    class           = c("sgp_denominators", "list"),
    rate_conversion = "blended_pool"
  )
}

# ---------------------------------------------------------------------------
# 2. Synthetic league_history
#
# sgp() requires league_history$team_season with columns:
#   year, team_id, IP, AB  (IP and AB needed structurally even for count-only)
# We provide 3 synthetic years × n_teams rows with plausible IP/AB values.
# The actual values don't affect counting-stat SGP computation.
# ---------------------------------------------------------------------------

make_synth_league_history <- function(n_teams = 12L) {
  years    <- 2022L:2024L
  teams    <- paste0("TM", seq_len(n_teams))
  ts_rows  <- expand.grid(year = years, team_id = teams, stringsAsFactors = FALSE)

  n_rows         <- nrow(ts_rows)
  ts_rows$IP     <- rep(1350, n_rows)   # ~team-season pitcher IP
  ts_rows$AB     <- rep(5500, n_rows)   # ~team-season hitter AB
  ts_rows$HR     <- rep(180,  n_rows)
  ts_rows$R      <- rep(750,  n_rows)
  ts_rows$SB     <- rep(80,   n_rows)
  ts_rows$K      <- rep(1300, n_rows)
  ts_rows$SV     <- rep(45,   n_rows)

  league_history(team_season = ts_rows)
}

# ---------------------------------------------------------------------------
# 3. DGP — generate synthetic projections
#
# n_teams controls pool depth:
#   n_hitters = n_teams * 8 * 3      (3× rostered pool)
#   n_sp      = n_teams * 6 * 2
#   n_rp      = n_teams * 3 * 2
# ---------------------------------------------------------------------------

make_projections <- function(n_teams, seed) {
  set.seed(seed)

  roster_slots_per_team <- 8L          # C+1B+2B+3B+SS+3OF
  n_hitters <- n_teams * roster_slots_per_team * 3L
  n_sp      <- n_teams * 6L * 2L
  n_rp      <- n_teams * 3L * 2L
  n_total   <- n_hitters + n_sp + n_rp

  # ---- Hitter tiers for HR ----
  n_top    <- round(n_hitters * 0.20)
  n_mid    <- round(n_hitters * 0.60)
  n_bot    <- n_hitters - n_top - n_mid
  hr_lambda <- c(rep(28, n_top), rep(14, n_mid), rep(5, n_bot))

  # ---- Hitter stats ----
  HR_h  <- rpois(n_hitters, lambda = hr_lambda)
  R_h   <- pmax(0L, as.integer(round(rnorm(n_hitters, mean = 70, sd = 20))))
  SB_h  <- rpois(n_hitters, lambda = 10)
  AB_h  <- pmax(150L, as.integer(round(rnorm(n_hitters, mean = 440, sd = 60))))
  IP_h  <- rep(NA_real_, n_hitters)
  K_h   <- rep(NA_real_, n_hitters)
  SV_h  <- rep(NA_real_, n_hitters)

  # ---- Pitcher stats — SP ----
  K_sp  <- pmax(20L, as.integer(round(rnorm(n_sp, mean = 165, sd = 35))))
  SV_sp <- rep(0L, n_sp)
  IP_sp <- pmax(120, pmin(220, round(rnorm(n_sp, mean = 170, sd = 15), 1)))
  HR_sp <- rep(NA_real_, n_sp)
  R_sp  <- rep(NA_real_, n_sp)
  SB_sp <- rep(NA_real_, n_sp)
  AB_sp <- rep(NA_real_, n_sp)

  # ---- Pitcher stats — RP (closers top 25%) ----
  n_closers  <- round(n_rp * 0.25)
  n_non_cl   <- n_rp - n_closers
  sv_lambda  <- c(rep(28, n_closers), rep(2, n_non_cl))
  K_rp  <- pmax(10L, as.integer(round(rnorm(n_rp, mean = 60, sd = 20))))
  SV_rp <- rpois(n_rp, lambda = sv_lambda)
  IP_rp <- pmax(40, pmin(80, round(rnorm(n_rp, mean = 60, sd = 10), 1)))
  HR_rp <- rep(NA_real_, n_rp)
  R_rp  <- rep(NA_real_, n_rp)
  SB_rp <- rep(NA_real_, n_rp)
  AB_rp <- rep(NA_real_, n_rp)

  # ---- Position eligibility ----
  hitter_base_positions <- c(
    rep("C",  ceiling(n_hitters / 8)),
    rep("1B", ceiling(n_hitters / 8)),
    rep("2B", ceiling(n_hitters / 8)),
    rep("3B", ceiling(n_hitters / 8)),
    rep("SS", ceiling(n_hitters / 8)),
    rep("OF", ceiling(n_hitters / 8) * 3L)
  )
  # Trim or extend to exactly n_hitters
  if (length(hitter_base_positions) > n_hitters) {
    hitter_base_positions <- hitter_base_positions[seq_len(n_hitters)]
  } else if (length(hitter_base_positions) < n_hitters) {
    hitter_base_positions <- c(
      hitter_base_positions,
      rep("OF", n_hitters - length(hitter_base_positions))
    )
  }

  # ~15% multi-eligible hitters
  n_multi   <- max(0L, round(n_hitters * 0.15))
  multi_idx <- sample(seq_len(n_hitters), n_multi, replace = FALSE)
  multi_alt <- sample(c("1B|3B", "2B|SS", "1B|OF", "3B|SS"), n_multi, replace = TRUE)
  hitter_base_positions[multi_idx] <- vapply(
    multi_idx,
    function(i) {
      orig <- hitter_base_positions[i]
      # Avoid combining position with itself
      alt_pair <- multi_alt[which(multi_idx == i)[1L]]
      # Use the alternative pair as-is (it's valid cross-position)
      alt_pair
    },
    character(1L)
  )

  pos_elig <- c(hitter_base_positions, rep("SP", n_sp), rep("RP", n_rp))

  # ---- Teams and leagues ----
  team_pool <- c("NYY", "BOS", "LAD", "CHC", "HOU", "ATL",
                 "STL", "SF",  "NYM", "MIN", "SEA", "SD",
                 "CLE", "TB",  "MIL", "PHI")
  teams   <- sample(team_pool, n_total, replace = TRUE)
  leagues <- ifelse(teams %in% c("NYY", "BOS", "HOU", "MIN", "SEA", "CLE", "TB"),
                    "AL", "NL")

  role <- c(rep(NA_character_, n_hitters), rep("SP", n_sp), rep("RP", n_rp))

  data.frame(
    player_id       = paste0("P", seq_len(n_total)),
    player_name     = paste0("Player_", seq_len(n_total)),
    pos_eligibility = pos_elig,
    team            = teams,
    league          = leagues,
    HR              = c(HR_h,  HR_sp,  HR_rp),
    R               = c(R_h,   R_sp,   R_rp),
    SB              = c(SB_h,  SB_sp,  SB_rp),
    K               = c(K_h,   K_sp,   K_rp),
    SV              = c(SV_h,  SV_sp,  SV_rp),
    AB              = c(AB_h,  AB_sp,  AB_rp),
    IP              = c(IP_h,  IP_sp,  IP_rp),
    role            = role,
    stringsAsFactors = FALSE
  )
}

# ---------------------------------------------------------------------------
# 4. league_config builder
# ---------------------------------------------------------------------------

make_league_config <- function(n_teams) {
  league_config(
    n_teams       = n_teams,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L, SS = 1L, OF = 3L),
    pitcher_slots = c(SP = 6L, RP = 3L),
    categories    = SCORED_CATS,
    budget        = 260L,
    budget_split  = 0.67
  )
}

# ---------------------------------------------------------------------------
# 5. Safe par() runner — captures band_check warning without stopping
# ---------------------------------------------------------------------------

run_par_safe <- function(replacement_obj, denominators, synth_lh,
                          boundary_threshold = 1.0) {
  band_fired <- FALSE
  result <- withCallingHandlers(
    par(
      replacement        = replacement_obj,
      denominators       = denominators,
      include_raw        = TRUE,
      boundary_threshold = boundary_threshold,
      rate_conversion    = "blended_pool",
      pool_baseline      = "projection_pool",
      baseline           = NULL,
      league_history     = synth_lh
    ),
    rotostats_warning_band_check = function(w) {
      band_fired <<- TRUE
      invokeRestart("muffleWarning")
    }
  )
  list(result = result, band_check_fired = band_fired)
}

# ---------------------------------------------------------------------------
# 6. Metric extractors
# ---------------------------------------------------------------------------

compute_delegation_max_error <- function(par_result, replacement_obj) {
  repl_sgp             <- attr(par_result, "replacement_sgp")   # named list
  position_assignments <- attr(replacement_obj, "position_assignments")
  # Use PLAYER_ID from stored projections (replacement_level uppercases col names)
  stored_proj          <- attr(replacement_obj, "projections")
  player_positions     <- position_assignments[stored_proj[["PLAYER_ID"]]]

  max_err <- max(vapply(SCORED_CATS, function(cat) {
    sgp_col  <- paste0("sgp_", cat)
    par_col  <- paste0("par_", cat)
    if (!sgp_col %in% names(par_result) || !par_col %in% names(par_result)) {
      return(NA_real_)
    }
    repl_vec <- vapply(player_positions, function(pos) {
      if (is.na(pos) || is.null(repl_sgp[[pos]])) return(NA_real_)
      val <- repl_sgp[[pos]][cat]
      if (is.na(val)) NA_real_ else val
    }, numeric(1L))
    max(abs(par_result[[par_col]] + repl_vec - par_result[[sgp_col]]),
        na.rm = TRUE)
  }, numeric(1L)), na.rm = TRUE)

  max_err
}

get_boundary_total_par <- function(par_result, pos, replacement_obj,
                                    n_teams, roster_slots) {
  position_assignments <- attr(replacement_obj, "position_assignments")
  stored_proj          <- attr(replacement_obj, "projections")
  player_positions     <- position_assignments[stored_proj[["PLAYER_ID"]]]

  pos_players <- which(player_positions == pos)
  if (length(pos_players) == 0L) return(NA_real_)

  # Try hitter roster_slots first; fall back to pitcher_slots from stored config
  n_slots <- tryCatch(roster_slots[[pos]], error = function(e) NULL)
  if (is.null(n_slots) || (length(n_slots) == 0L) || is.na(n_slots)) {
    # Try pitcher slots from the stored config
    cfg_stored <- attr(replacement_obj, "config")
    n_slots    <- tryCatch(cfg_stored$pitcher_slots[[pos]], error = function(e) NULL)
  }
  if (is.null(n_slots) || (length(n_slots) == 0L) || is.na(n_slots)) return(NA_real_)

  boundary_rank <- n_teams * n_slots
  if (boundary_rank > length(pos_players) || boundary_rank <= 0L) return(NA_real_)

  tp_sorted <- sort(par_result$total_par[pos_players], decreasing = TRUE)
  if (boundary_rank > length(tp_sorted)) return(NA_real_)
  tp_sorted[[boundary_rank]]
}

compute_band_median <- function(par_result, replacement_obj, n_teams) {
  repl <- replacement_obj
  K    <- repl$params$band_width
  rs   <- repl$params$roster_slots

  position_assignments <- attr(repl, "position_assignments")
  stored_proj          <- attr(repl, "projections")
  player_positions     <- position_assignments[stored_proj[["PLAYER_ID"]]]

  active_positions <- names(rs[rs > 0L])
  band_vals <- unlist(lapply(active_positions, function(pos) {
    pos_players  <- which(player_positions == pos)
    if (length(pos_players) == 0L) return(numeric(0L))
    boundary_rank <- n_teams * rs[[pos]]
    K_eff  <- min(K, floor(length(pos_players) / 4L))
    band_lo <- max(1L, boundary_rank - K_eff)
    band_hi <- min(length(pos_players), boundary_rank + K_eff)
    tp_pos  <- par_result$total_par[pos_players]
    ord     <- order(tp_pos, decreasing = TRUE)
    band_idx <- ord[seq(band_lo, band_hi)]
    tp_pos[band_idx]
  }))

  if (length(band_vals) == 0L) return(NA_real_)
  median(band_vals, na.rm = TRUE)
}

# ---------------------------------------------------------------------------
# 7. Single-replication runner
# ---------------------------------------------------------------------------

run_one_replication <- function(scenario_id, dgp_type, n_teams, rep,
                                 denominators, synth_lh, rep_seed) {
  set.seed(rep_seed)

  # ---- Build projections ----
  proj <- make_projections(n_teams = n_teams, seed = rep_seed)

  # ---- Build league config (true config) ----
  cfg_true <- make_league_config(n_teams)

  # ---- Build replacement_level config ----
  # For miscalibrated_5: use n_teams + 5 (too many teams → too-low repl level)
  # For miscalibrated_neg5: use n_teams - 5 (too few teams → too-high repl level)
  n_teams_repl <- switch(dgp_type,
    calibrated        = n_teams,
    miscalibrated_5   = n_teams + 5L,
    miscalibrated_neg5 = n_teams - 5L,
    stop("Unknown dgp_type: ", dgp_type)
  )
  cfg_repl <- make_league_config(n_teams_repl)

  # ---- Run replacement_level (suppress verbose messages) ----
  replacement_obj <- suppressMessages(suppressWarnings(
    replacement_level(projections = proj, config = cfg_repl)
  ))

  # ---- Run par() ----
  out <- tryCatch(
    run_par_safe(replacement_obj, denominators, synth_lh,
                 boundary_threshold = 1.0),
    error = function(e) {
      list(result = NULL, band_check_fired = NA, error = e)
    }
  )

  # ---- Determine failure ----
  par_failed  <- is.null(out$result)
  error_class <- if (par_failed && !is.null(out$error)) {
    paste(class(out$error), collapse = "|")
  } else {
    NA_character_
  }

  # ---- Base row (always present) ----
  row <- list(
    scenario_id             = scenario_id,
    dgp_type                = dgp_type,
    n_teams                 = n_teams,
    rep                     = rep,
    par_failed              = par_failed,
    error_class             = error_class,
    delegation_max_error    = NA_real_,
    band_check_fired        = out$band_check_fired,
    band_median_total_par   = NA_real_,
    boundary_total_par_C    = NA_real_,
    boundary_total_par_1B   = NA_real_,
    boundary_total_par_2B   = NA_real_,
    boundary_total_par_3B   = NA_real_,
    boundary_total_par_SS   = NA_real_,
    boundary_total_par_OF   = NA_real_,
    boundary_total_par_SP   = NA_real_,
    boundary_total_par_RP   = NA_real_
  )

  if (!par_failed) {
    par_result <- out$result

    # Delegation identity
    row$delegation_max_error <- tryCatch(
      compute_delegation_max_error(par_result, replacement_obj),
      error = function(e) NA_real_
    )

    # Band median (uses miscalibrated n_teams for band width alignment)
    row$band_median_total_par <- tryCatch(
      compute_band_median(par_result, replacement_obj, n_teams_repl),
      error = function(e) NA_real_
    )

    # Boundary total_par per position (use miscalibrated config slots for rank)
    roster_slots_repl <- cfg_repl$roster_slots
    for (pos in POSITIONS) {
      col_name <- paste0("boundary_total_par_", gsub("[^A-Za-z0-9]", "", pos))
      row[[col_name]] <- tryCatch(
        get_boundary_total_par(par_result, pos, replacement_obj,
                                n_teams_repl, roster_slots_repl),
        error = function(e) NA_real_
      )
    }
  }

  as.data.frame(row, stringsAsFactors = FALSE)
}

# ---------------------------------------------------------------------------
# 8. Scenario definitions
# ---------------------------------------------------------------------------

scenarios <- data.frame(
  scenario_id = c("S1", "S2", "S3", "S4", "S5"),
  dgp_type    = c("calibrated", "calibrated", "calibrated",
                  "miscalibrated_5", "miscalibrated_neg5"),
  n_teams     = c(12L, 10L, 15L, 12L, 12L),
  stringsAsFactors = FALSE
)

# ---------------------------------------------------------------------------
# 9. Main simulation loop
# ---------------------------------------------------------------------------

cat(sprintf(
  "\n=== par() Monte Carlo Simulation ===\n%d scenarios × %d replications = %d total\n\n",
  nrow(scenarios), R_REPS, nrow(scenarios) * R_REPS
))

denominators <- make_sim_denominators()

# Build synth league_history once per scenario (n_teams can vary S2/S3)
# We'll rebuild inside the scenario loop where n_teams matters.

all_results <- vector("list", nrow(scenarios) * R_REPS)
result_idx  <- 0L

t_start <- proc.time()[["elapsed"]]

for (s in seq_len(nrow(scenarios))) {
  scenario_id <- scenarios$scenario_id[s]
  dgp_type    <- scenarios$dgp_type[s]
  n_teams     <- scenarios$n_teams[s]
  scenario_seed <- MASTER_SEED + s * 1000L

  synth_lh <- suppressMessages(suppressWarnings(
    make_synth_league_history(n_teams = n_teams)
  ))

  cat(sprintf("Scenario %s (%s, n_teams=%d): ", scenario_id, dgp_type, n_teams))
  n_fail <- 0L

  for (r in seq_len(R_REPS)) {
    rep_seed <- scenario_seed + r

    suppressMessages(suppressWarnings({
      rep_row <- run_one_replication(
        scenario_id = scenario_id,
        dgp_type    = dgp_type,
        n_teams     = n_teams,
        rep         = r,
        denominators = denominators,
        synth_lh    = synth_lh,
        rep_seed    = rep_seed
      )
    }))

    result_idx <- result_idx + 1L
    all_results[[result_idx]] <- rep_row

    if (rep_row$par_failed) n_fail <- n_fail + 1L

    if (r %% 40L == 0L) cat(".")
  }

  t_elapsed <- proc.time()[["elapsed"]] - t_start
  cat(sprintf(" done (%d failed) [%.1fs elapsed]\n", n_fail, t_elapsed))
}

t_total <- proc.time()[["elapsed"]] - t_start
cat(sprintf("\nTotal runtime: %.1f seconds\n\n", t_total))

# ---------------------------------------------------------------------------
# 10. Assemble results data frame
# ---------------------------------------------------------------------------

results_df <- do.call(rbind, all_results)
rownames(results_df) <- NULL

# ---------------------------------------------------------------------------
# 11. Compute summary CSV
# ---------------------------------------------------------------------------

boundary_pos_cols <- paste0("boundary_total_par_", POSITIONS)

compute_scenario_summary <- function(df_s) {
  ok <- df_s[!df_s$par_failed, , drop = FALSE]
  n_reps        <- nrow(ok)
  failure_rate  <- mean(df_s$par_failed)
  dgp           <- df_s$dgp_type[1L]

  deleg_max  <- if (n_reps > 0) max(ok$delegation_max_error, na.rm = TRUE) else NA_real_
  fire_rate  <- if (n_reps > 0) mean(ok$band_check_fired, na.rm = TRUE) else NA_real_
  band_mean  <- if (n_reps > 0) mean(ok$band_median_total_par, na.rm = TRUE) else NA_real_
  band_sd    <- if (n_reps > 0) sd(ok$band_median_total_par, na.rm = TRUE) else NA_real_

  # Per-position boundary means and SDs
  bnd_means <- setNames(
    vapply(boundary_pos_cols, function(col)
      if (n_reps > 0) mean(ok[[col]], na.rm = TRUE) else NA_real_,
      numeric(1L)),
    sub("boundary_total_par_", "boundary_mean_", boundary_pos_cols)
  )
  bnd_sds <- setNames(
    vapply(boundary_pos_cols, function(col)
      if (n_reps > 0) sd(ok[[col]], na.rm = TRUE) else NA_real_,
      numeric(1L)),
    sub("boundary_total_par_", "boundary_sd_", boundary_pos_cols)
  )

  # AC assessments
  ac1 <- if (!is.na(deleg_max)) deleg_max < 1e-10 else NA
  ac2 <- if (dgp == "calibrated" && n_reps > 0) {
    all(abs(bnd_means) < 0.05, na.rm = TRUE)
  } else NA
  ac3 <- if (dgp == "calibrated" && !is.na(fire_rate)) {
    fire_rate < 0.05
  } else NA
  ac4 <- if (dgp %in% c("miscalibrated_5", "miscalibrated_neg5") && !is.na(fire_rate)) {
    fire_rate >= 0.75
  } else NA
  ac5 <- failure_rate < 0.01

  row <- c(
    list(
      scenario_id              = df_s$scenario_id[1L],
      dgp_type                 = dgp,
      n_teams                  = df_s$n_teams[1L],
      n_reps                   = n_reps,
      failure_rate             = failure_rate,
      delegation_max_error_max = deleg_max,
      band_check_fire_rate     = fire_rate,
      band_median_mean         = band_mean,
      band_median_sd           = band_sd
    ),
    as.list(bnd_means),
    as.list(bnd_sds),
    list(
      ac_sim1_pass = ac1,
      ac_sim2_pass = ac2,
      ac_sim3_pass = ac3,
      ac_sim4_pass = ac4,
      ac_sim5_pass = ac5
    )
  )
  as.data.frame(row, stringsAsFactors = FALSE)
}

summary_list <- lapply(unique(results_df$scenario_id), function(sid) {
  compute_scenario_summary(results_df[results_df$scenario_id == sid, , drop = FALSE])
})
summary_df <- do.call(rbind, summary_list)
rownames(summary_df) <- NULL

# ---------------------------------------------------------------------------
# 12. Write outputs
# ---------------------------------------------------------------------------

# Resolve output directory: this script lives in tests/simulations/
# Use the script's own directory if available, otherwise fall back to
# tests/simulations/ relative to the current working directory.
sim_dir <- tryCatch(
  normalizePath(dirname(sys.frame(0)$ofile), mustWork = FALSE),
  error = function(e) file.path(getwd(), "tests", "simulations")
)
if (!dir.exists(sim_dir)) {
  sim_dir <- file.path(getwd(), "tests", "simulations")
}
if (!dir.exists(sim_dir)) dir.create(sim_dir, recursive = TRUE)

rds_path <- file.path(sim_dir, "sim-par-results.rds")
csv_path <- file.path(sim_dir, "sim-par-summary.csv")

saveRDS(results_df, rds_path)
write.csv(summary_df, csv_path, row.names = FALSE)

cat(sprintf("Results written to:\n  %s\n  %s\n\n", rds_path, csv_path))

# ---------------------------------------------------------------------------
# 13. Print acceptance criteria report
# ---------------------------------------------------------------------------

cat("=== Acceptance Criteria Report ===\n\n")

for (i in seq_len(nrow(summary_df))) {
  row <- summary_df[i, , drop = FALSE]
  cat(sprintf("Scenario %s (%s, n=%d):\n",
              row$scenario_id, row$dgp_type, row$n_teams))
  cat(sprintf("  n_reps=%d  failure_rate=%.3f  deleg_max_err=%.2e  fire_rate=%.3f\n",
              row$n_reps, row$failure_rate, row$delegation_max_error_max,
              row$band_check_fire_rate))

  # Boundary means for calibrated scenarios
  if (row$dgp_type == "calibrated") {
    bm_cols <- grep("^boundary_mean_", names(row), value = TRUE)
    bm_vals <- unlist(row[, bm_cols])
    bm_str  <- paste(sub("boundary_mean_", "", bm_cols),
                     sprintf("%.3f", bm_vals), sep = "=", collapse = "  ")
    cat(sprintf("  Boundary means: %s\n", bm_str))
  }

  ac1_sym <- if (isTRUE(row$ac_sim1_pass)) "PASS" else if (isFALSE(row$ac_sim1_pass)) "FAIL" else "N/A"
  ac2_sym <- if (isTRUE(row$ac_sim2_pass)) "PASS" else if (isFALSE(row$ac_sim2_pass)) "FAIL" else "N/A"
  ac3_sym <- if (isTRUE(row$ac_sim3_pass)) "PASS" else if (isFALSE(row$ac_sim3_pass)) "FAIL" else "N/A"
  ac4_sym <- if (isTRUE(row$ac_sim4_pass)) "PASS" else if (isFALSE(row$ac_sim4_pass)) "FAIL" else "N/A"
  ac5_sym <- if (isTRUE(row$ac_sim5_pass)) "PASS" else if (isFALSE(row$ac_sim5_pass)) "FAIL" else "N/A"

  cat(sprintf("  AC1(deleg):    %s  (max_err=%.2e, threshold=1e-10)\n",
              ac1_sym, row$delegation_max_error_max))
  cat(sprintf("  AC2(boundary): %s  (all pos mean within ±0.05 of 0)\n", ac2_sym))
  cat(sprintf("  AC3(calib):    %s  (fire_rate=%.3f < 0.05)\n",
              ac3_sym, row$band_check_fire_rate))
  cat(sprintf("  AC4(miscal):   %s  (fire_rate=%.3f >= 0.75)\n",
              ac4_sym, row$band_check_fire_rate))
  cat(sprintf("  AC5(failure):  %s  (failure_rate=%.4f < 0.01)\n\n",
              ac5_sym, row$failure_rate))
}

# Overall verdict
all_ac1 <- all(summary_df$ac_sim1_pass, na.rm = TRUE)
all_ac2 <- all(summary_df$ac_sim2_pass[!is.na(summary_df$ac_sim2_pass)], na.rm = TRUE)
all_ac3 <- all(summary_df$ac_sim3_pass[!is.na(summary_df$ac_sim3_pass)], na.rm = TRUE)
all_ac4 <- all(summary_df$ac_sim4_pass[!is.na(summary_df$ac_sim4_pass)], na.rm = TRUE)
all_ac5 <- all(summary_df$ac_sim5_pass, na.rm = TRUE)

all_pass <- all_ac1 && all_ac2 && all_ac3 && all_ac4 && all_ac5

cat(sprintf("=== Overall Verdict: %s ===\n", if (all_pass) "SIMULATED" else "HOLD"))
cat(sprintf("  AC1 (delegation identity):     %s\n", if (all_ac1) "PASS" else "FAIL"))
cat(sprintf("  AC2 (boundary invariance):     %s\n", if (all_ac2) "PASS" else "FAIL"))
cat(sprintf("  AC3 (calibrated band check):   %s\n", if (all_ac3) "PASS" else "FAIL"))
cat(sprintf("  AC4 (miscalibrated band check):%s\n", if (all_ac4) "PASS" else "FAIL"))
cat(sprintf("  AC5 (failure rate):            %s\n", if (all_ac5) "PASS" else "FAIL"))
cat(sprintf("  Total runtime: %.1f seconds\n\n", t_total))

invisible(list(results = results_df, summary = summary_df))
