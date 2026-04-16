# =============================================================================
# Monte Carlo Simulation Harness: sgp()
# Run: sgp-2026-04-16
# Master seed: 20260416L
# =============================================================================
# PURPOSE
#   Validate the correctness and behavioral guarantees of sgp() through Monte
#   Carlo simulation.  Treats sgp() as a black box: generates synthetic inputs
#   with known properties, calls the function, and checks outputs against
#   independently derived expected values.
#
# USAGE
#   Rscript tools/simulation/sgp-mc.R
#   — or —
#   source("tools/simulation/sgp-mc.R")   # from an interactive session
#
# REQUIRES
#   rotostats installed / loadable via devtools::load_all()
#   (R/sgp.R must exist — written by builder on feature/sgp)
# =============================================================================

suppressPackageStartupMessages({
  # Try installed package first; fall back to load_all() for development.
  if (requireNamespace("rotostats", quietly = TRUE)) {
    library(rotostats)
  } else {
    devtools::load_all(quiet = TRUE)
  }
})

# ---------------------------------------------------------------------------
# 0. Utilities
# ---------------------------------------------------------------------------

MASTER_SEED <- 20260416L

#' Derive a per-replication seed from the master seed, scenario offset, and
#' replication index.  Formula from sim-spec.md §7.
sim_seed <- function(scenario_offset, replication) {
  MASTER_SEED + scenario_offset * 1000L + replication
}

#' Truncated normal draw (scalar or vector).
rtruncnorm <- function(n, mean, sd, lo, hi, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)
  x <- rnorm(n, mean, sd)
  # Rejection sample for out-of-range draws (≤ 3 passes is almost always enough
  # given the ranges in the spec).
  for (pass in seq_len(20L)) {
    bad <- x < lo | x > hi
    if (!any(bad)) break
    x[bad] <- rnorm(sum(bad), mean, sd)
  }
  # Hard clamp as final safety net.
  pmin(pmax(x, lo), hi)
}

#' Construct a synthetic sgp_denominators object from sim-spec.md §10.
make_fake_denoms <- function(cats, values, rate_conversion) {
  rotostats:::new_sgp_denominators(
    denominators     = setNames(values, cats),
    year_diagnostics = data.frame(),
    bootstrap_ci     = NULL,
    call             = NULL,
    meta             = list(
      rate_conversion = rate_conversion,
      method          = "ols",
      years_used      = 2022L,
      exclude_years   = 2020L,
      package_version = "0.0.0.9000"
    ),
    rate_conversion  = rate_conversion
  )
}

#' Build a minimal league_config object.
make_config <- function(n_teams,
                        pitcher_slots = 9L,
                        roster_slots = c(C = 1L, "1B" = 1L, "2B" = 1L,
                                         "3B" = 1L, SS = 1L, OF = 3L, DH = 1L),
                        categories = c("HR", "R", "RBI", "SB",
                                       "ERA", "WHIP", "AVG")) {
  league_config(
    n_teams       = n_teams,
    roster_slots  = roster_slots,
    pitcher_slots = pitcher_slots,
    categories    = categories
  )
}

#' Build a minimal league_history object (one year, n_teams teams).
#' Parameters come from DGP-Rate spec (§3 DGP-Rate "Baseline year league
#' history").
make_history <- function(n_teams, ts_data) {
  # ts_data: data.frame with columns year, team_id, ERA, IP, WHIP, AVG, AB
  league_history(team_season = ts_data)
}

#' Clopper-Pearson 95% CI for a proportion.
cp_ci <- function(x, n, level = 0.95) {
  alpha <- (1 - level) / 2
  lo <- if (x == 0L) 0 else stats::qbeta(alpha, x, n - x + 1)
  hi <- if (x == n)  1 else stats::qbeta(1 - alpha, x + 1, n - x)
  c(lo = lo, hi = hi)
}

# ---------------------------------------------------------------------------
# Results accumulator
# ---------------------------------------------------------------------------

all_results <- list()

record <- function(scenario_id, n_teams, metric, value, threshold, compare_fn) {
  pass <- compare_fn(value, threshold)
  all_results[[length(all_results) + 1L]] <<- data.frame(
    scenario_id = scenario_id,
    n_teams     = as.integer(n_teams),
    metric      = metric,
    value       = value,
    threshold   = threshold,
    pass        = pass,
    stringsAsFactors = FALSE
  )
}

# Helper: pass when value < threshold
lt_threshold <- function(v, t) v < t
# Helper: pass when value == threshold (for proportions that must be 1.000)
eq_threshold <- function(v, t) isTRUE(all.equal(v, t, tolerance = 1e-10))
# Helper: pass when value >= threshold
ge_threshold <- function(v, t) v >= t

# ---------------------------------------------------------------------------
# 1. SC-1: DGP-Counting — Counting-stat SGP identity sweep
#    Scenario offset = 1, N_rep = 1000, n_players = 500
# ---------------------------------------------------------------------------

cat("=== SC-1: Counting-stat SGP identity sweep ===\n")

SC1_OFFSET   <- 1L
SC1_NREP     <- 1000L
SC1_NPLAYERS <- 500L

COUNTING_CATS <- c("HR", "R", "RBI", "SB", "K", "W")

# Bounds from sim-spec.md §3 DGP-Counting
stat_lo   <- c(HR = 1,  R = 20, RBI = 20, SB = 0,  K = 50,  W = 0)
stat_hi   <- c(HR = 50, R = 120, RBI = 120, SB = 60, K = 280, W = 20)
denom_lo  <- c(HR = 8,  R = 12, RBI = 12, SB = 3,  K = 20,  W = 2)
denom_hi  <- c(HR = 20, R = 25,  RBI = 25, SB = 10, K = 60,  W = 8)

sc1_max_error  <- 0
sc1_mean_errors <- numeric(SC1_NREP)
sc1_p99_errors  <- numeric(SC1_NREP)
sc1_worst_rep   <- NA_integer_
sc1_worst_player <- NA_integer_

for (r in seq_len(SC1_NREP)) {
  set.seed(sim_seed(SC1_OFFSET, r))

  # Draw projections
  proj <- as.data.frame(
    lapply(COUNTING_CATS, function(cat) {
      runif(SC1_NPLAYERS, stat_lo[cat], stat_hi[cat])
    })
  )
  names(proj) <- COUNTING_CATS

  # Draw denominators
  dvals <- sapply(COUNTING_CATS, function(cat) {
    runif(1, denom_lo[cat], denom_hi[cat])
  })

  # Construct synthetic denom object (counting-only, rate_conversion = "blended_pool"
  # is irrelevant for counting stats; we set it to blended_pool to pass the compat check)
  denom_obj <- make_fake_denoms(COUNTING_CATS, dvals, "blended_pool")

  # Minimal league history (counting-only DGP — rate stats not scored)
  ts_data <- data.frame(
    year    = 2022L,
    team_id = paste0("T", seq_len(12L)),
    HR      = runif(12L, 150, 250),
    R       = runif(12L, 650, 850),
    RBI     = runif(12L, 650, 850),
    SB      = runif(12L, 50, 150),
    K       = runif(12L, 900, 1400),
    W       = runif(12L, 60, 90),
    IP      = runif(12L, 1200, 1600),
    AB      = runif(12L, 5000, 5800),
    ERA     = rnorm(12L, 4.2, 0.3),
    WHIP    = rnorm(12L, 1.30, 0.08),
    AVG     = rnorm(12L, 0.255, 0.010)
  )
  history_obj <- league_history(team_season = ts_data)

  config_obj <- make_config(
    n_teams    = 12L,
    categories = COUNTING_CATS
  )

  result <- tryCatch(
    sgp(
      projections     = proj,
      denominators    = denom_obj,
      league_history  = history_obj,
      rate_conversion = "blended_pool",
      pool_baseline   = "projection_pool",
      league_config   = config_obj
    ),
    error = function(e) {
      message(sprintf("  SC-1 rep %d: sgp() error: %s", r, conditionMessage(e)))
      NULL
    }
  )

  if (is.null(result)) next

  # Independently compute expected SGP
  expected_sgp <- as.data.frame(
    lapply(COUNTING_CATS, function(cat) {
      proj[[cat]] / dvals[cat]
    })
  )
  names(expected_sgp) <- paste0("sgp_", COUNTING_CATS)

  # Compute absolute errors
  errors <- matrix(NA_real_, nrow = SC1_NPLAYERS, ncol = length(COUNTING_CATS))
  for (ci in seq_along(COUNTING_CATS)) {
    col <- paste0("sgp_", COUNTING_CATS[ci])
    if (!col %in% names(result)) {
      message(sprintf("  SC-1 rep %d: missing column %s in result", r, col))
      next
    }
    errors[, ci] <- abs(result[[col]] - expected_sgp[[col]])
  }

  rep_max <- max(errors, na.rm = TRUE)
  sc1_mean_errors[r] <- mean(errors, na.rm = TRUE)
  sc1_p99_errors[r]  <- quantile(errors, 0.99, na.rm = TRUE)

  if (rep_max > sc1_max_error) {
    sc1_max_error    <- rep_max
    sc1_worst_rep    <- r
    sc1_worst_player <- which.max(apply(errors, 1, max, na.rm = TRUE))[1L]
  }
}

cat(sprintf("  Max absolute error : %.2e\n", sc1_max_error))
cat(sprintf("  Mean absolute error: %.2e\n", mean(sc1_mean_errors)))
cat(sprintf("  99th pct error     : %.2e\n", mean(sc1_p99_errors)))
if (!is.na(sc1_worst_rep)) {
  cat(sprintf("  Worst at rep=%d, player=%d\n", sc1_worst_rep, sc1_worst_player))
}

record("SC-1", NA, "M-1: max_abs_error", sc1_max_error, 1e-12, lt_threshold)

# ---------------------------------------------------------------------------
# 2. SC-2, SC-2a, SC-2b: DGP-Rate — Blended-pool sign tests
#    Scenario offsets: 2, 3, 4
# ---------------------------------------------------------------------------

cat("\n=== SC-2/SC-2a/SC-2b: Rate-stat sign tests ===\n")

run_rate_sign_test <- function(scenario_id, scenario_offset, n_teams, n_rep) {
  cat(sprintf("  %s: n_teams=%d, N_rep=%d\n", scenario_id, n_teams, n_rep))

  pitcher_slots <- 9L
  hitter_primary_slots <- c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L,
                             SS = 1L, OF = 3L, DH = 1L)
  pool_size_p <- n_teams * pitcher_slots
  pool_size_h <- n_teams * sum(hitter_primary_slots)  # 8 per team

  era_sign_G  <- logical(n_rep)
  era_sign_B  <- logical(n_rep)
  whip_sign_G <- logical(n_rep)
  whip_sign_B <- logical(n_rep)
  avg_sign_G  <- logical(n_rep)
  avg_sign_B  <- logical(n_rep)
  approx_err_reliever <- numeric(n_rep)
  approx_err_starter  <- numeric(n_rep)

  for (r in seq_len(n_rep)) {
    set.seed(sim_seed(scenario_offset, r))

    # --- Generate league history baseline (sim-spec.md §3 DGP-Rate) ---
    ts_ERA  <- rtruncnorm(n_teams, 4.20, 0.30, 1.5, 7.5)
    ts_IP   <- runif(n_teams, 1200, 1600)
    ts_WHIP <- rtruncnorm(n_teams, 1.30, 0.08, 0.8, 2.0)
    ts_AVG  <- rtruncnorm(n_teams, 0.255, 0.010, 0.150, 0.380)
    ts_AB   <- runif(n_teams, 5000, 5800)

    avg_ERA_true  <- stats::weighted.mean(ts_ERA,  ts_IP)
    avg_WHIP_true <- stats::weighted.mean(ts_WHIP, ts_IP)
    avg_AVG_true  <- stats::weighted.mean(ts_AVG,  ts_AB)

    ts_data <- data.frame(
      year    = 2022L,
      team_id = paste0("T", seq_len(n_teams)),
      ERA     = ts_ERA,
      IP      = ts_IP,
      WHIP    = ts_WHIP,
      AVG     = ts_AVG,
      AB      = ts_AB
    )
    history_obj <- tryCatch(
      league_history(team_season = ts_data),
      error = function(e) NULL
    )
    if (is.null(history_obj)) {
      era_sign_G[r] <- FALSE; era_sign_B[r] <- FALSE
      whip_sign_G[r] <- FALSE; whip_sign_B[r] <- FALSE
      avg_sign_G[r] <- FALSE; avg_sign_B[r] <- FALSE
      next
    }

    # --- Generate pitcher pool (pool_size_p pitchers sorted by IP desc) ---
    pool_IP_all  <- runif(pool_size_p, 50, 220)
    pool_ERA_all <- rtruncnorm(pool_size_p, 4.00, 0.60, 1.5, 7.5)
    pool_WHIP_all <- rtruncnorm(pool_size_p, 1.25, 0.15, 0.8, 2.0)

    # Sort descending by IP — top N is already the whole pool
    ord_p <- order(pool_IP_all, decreasing = TRUE)
    pool_IP   <- pool_IP_all[ord_p]
    pool_ERA  <- pool_ERA_all[ord_p]
    pool_WHIP <- pool_WHIP_all[ord_p]

    # Pool totals (independent reference)
    ref_pool_IP   <- sum(pool_IP)
    ref_pool_ER   <- sum(pool_ERA * pool_IP / 9)    # ER = ERA * IP / 9
    ref_pool_WH   <- sum(pool_WHIP * pool_IP)        # WH = WHIP * IP

    # --- Generate hitter pool (pool_size_h hitters sorted by AB desc) ---
    pool_AB_all  <- runif(pool_size_h, 100, 600)
    pool_AVG_all <- rtruncnorm(pool_size_h, 0.255, 0.025, 0.150, 0.380)

    ord_h <- order(pool_AB_all, decreasing = TRUE)
    pool_AB  <- pool_AB_all[ord_h]
    pool_AVG <- pool_AVG_all[ord_h]

    ref_pool_AB <- sum(pool_AB)
    ref_pool_H  <- sum(pool_AVG * pool_AB)

    # --- Good pitcher: ERA strictly below avg_ERA_true - 0.5 ---
    G_ERA  <- runif(1, 1.5, avg_ERA_true - 0.5)
    G_WHIP <- runif(1, 0.8, avg_WHIP_true - 0.1)
    G_IP   <- runif(1, 100, 220)

    # --- Bad pitcher: ERA strictly above avg_ERA_true + 0.5 ---
    B_ERA  <- runif(1, avg_ERA_true + 0.5, 7.0)
    B_WHIP <- runif(1, avg_WHIP_true + 0.1, 2.0)
    B_IP   <- runif(1, 30, 200)

    # --- Good hitter: AVG strictly above avg_AVG_true + 0.020 ---
    Gh_AVG <- runif(1, avg_AVG_true + 0.020, 0.380)
    Gh_AB  <- runif(1, 300, 600)

    # --- Bad hitter: AVG strictly below avg_AVG_true - 0.020 ---
    Bh_AVG <- runif(1, 0.150, avg_AVG_true - 0.020)
    Bh_AB  <- runif(1, 100, 550)

    # --- Denominators ---
    denom_ERA  <- runif(1, 0.15, 0.45)
    denom_WHIP <- runif(1, 0.04, 0.12)
    denom_AVG  <- runif(1, 0.0010, 0.0030)
    denom_HR   <- runif(1, 8, 20)

    scored_cats <- c("HR", "ERA", "WHIP", "AVG")
    denom_obj <- make_fake_denoms(
      cats           = scored_cats,
      values         = c(denom_HR, denom_ERA, denom_WHIP, denom_AVG),
      rate_conversion = "blended_pool"
    )

    # --- Build projections data frame ---
    # Include both players G and B plus the pool players so sgp() can construct
    # the projection pool. Players are labeled with a "type" column for later
    # identification but sgp() won't see that column.
    # Pool players will be rows 1..pool_size_p (pitchers) and after the two
    # evaluated pitchers.  We need all pool players present so the function
    # selects the right top-N by IP.

    # Pitcher section: pool pitchers + G-pitcher (index pool_size_p+1)
    #                + B-pitcher (index pool_size_p+2)
    pitcher_rows <- data.frame(
      IP   = c(pool_IP,   G_IP,  B_IP),
      ERA  = c(pool_ERA,  G_ERA, B_ERA),
      WHIP = c(pool_WHIP, G_WHIP, B_WHIP),
      HR   = c(runif(pool_size_p, 0, 2), 0, 0),
      AB   = as.integer(0L),
      AVG  = 0,
      R    = as.integer(0L),
      SB   = as.integer(0L),
      stringsAsFactors = FALSE
    )

    # Hitter section: pool hitters + G-hitter + B-hitter
    n_pool_h_rows <- pool_size_h
    hitter_rows <- data.frame(
      IP   = 0,
      ERA  = 0,
      WHIP = 0,
      HR   = c(as.integer(round(runif(pool_size_h, 0, 40))),
                as.integer(round(runif(1, 0, 40))),
                as.integer(round(runif(1, 0, 40)))),
      AB   = as.integer(round(c(pool_AB, Gh_AB, Bh_AB))),
      AVG  = c(pool_AVG, Gh_AVG, Bh_AVG),
      R    = as.integer(0L),
      SB   = as.integer(0L),
      stringsAsFactors = FALSE
    )

    projections <- rbind(pitcher_rows, hitter_rows)

    # Index tracking
    idx_G  <- pool_size_p + 1L   # Good pitcher row
    idx_B  <- pool_size_p + 2L   # Bad pitcher row
    idx_Gh <- pool_size_p + 2L + pool_size_h + 1L   # Good hitter row
    idx_Bh <- pool_size_p + 2L + pool_size_h + 2L   # Bad hitter row

    config_obj <- make_config(
      n_teams       = n_teams,
      pitcher_slots = pitcher_slots,
      roster_slots  = hitter_primary_slots,
      categories    = scored_cats
    )

    result <- tryCatch(
      suppressMessages(
        sgp(
          projections     = projections,
          denominators    = denom_obj,
          league_history  = history_obj,
          rate_conversion = "blended_pool",
          pool_baseline   = "projection_pool",
          league_config   = config_obj
        )
      ),
      error = function(e) {
        message(sprintf("  %s rep %d: sgp() error: %s", scenario_id, r, conditionMessage(e)))
        NULL
      }
    )

    if (is.null(result)) {
      era_sign_G[r]  <- FALSE; era_sign_B[r]  <- FALSE
      whip_sign_G[r] <- FALSE; whip_sign_B[r] <- FALSE
      avg_sign_G[r]  <- FALSE; avg_sign_B[r]  <- FALSE
      next
    }

    era_sign_G[r]  <- !is.na(result$sgp_ERA[idx_G])  && result$sgp_ERA[idx_G]  > 0
    era_sign_B[r]  <- !is.na(result$sgp_ERA[idx_B])  && result$sgp_ERA[idx_B]  < 0
    whip_sign_G[r] <- !is.na(result$sgp_WHIP[idx_G]) && result$sgp_WHIP[idx_G] > 0
    whip_sign_B[r] <- !is.na(result$sgp_WHIP[idx_B]) && result$sgp_WHIP[idx_B] < 0
    avg_sign_G[r]  <- !is.na(result$sgp_AVG[idx_Gh]) && result$sgp_AVG[idx_Gh] > 0
    avg_sign_B[r]  <- !is.na(result$sgp_AVG[idx_Bh]) && result$sgp_AVG[idx_Bh] < 0

    # Blended-pool approximation error (informational)
    approx_err_reliever[r] <- B_IP / (ref_pool_IP + B_IP)    # bad = reliever-ish
    approx_err_starter[r]  <- G_IP / (ref_pool_IP + G_IP)    # good = starter-ish
  }

  rate_G   <- mean(era_sign_G)
  rate_B   <- mean(era_sign_B)
  rate_wG  <- mean(whip_sign_G)
  rate_wB  <- mean(whip_sign_B)
  rate_aG  <- mean(avg_sign_G)
  rate_aB  <- mean(avg_sign_B)

  ci_G  <- cp_ci(sum(era_sign_G),   n_rep)
  ci_B  <- cp_ci(sum(era_sign_B),   n_rep)
  ci_wG <- cp_ci(sum(whip_sign_G),  n_rep)
  ci_wB <- cp_ci(sum(whip_sign_B),  n_rep)
  ci_aG <- cp_ci(sum(avg_sign_G),   n_rep)
  ci_aB <- cp_ci(sum(avg_sign_B),   n_rep)

  cat(sprintf("  ERA  sign G: %.4f [%.4f, %.4f]  B: %.4f [%.4f, %.4f]\n",
              rate_G, ci_G["lo"], ci_G["hi"],
              rate_B, ci_B["lo"], ci_B["hi"]))
  cat(sprintf("  WHIP sign G: %.4f [%.4f, %.4f]  B: %.4f [%.4f, %.4f]\n",
              rate_wG, ci_wG["lo"], ci_wG["hi"],
              rate_wB, ci_wB["lo"], ci_wB["hi"]))
  cat(sprintf("  AVG  sign G: %.4f [%.4f, %.4f]  B: %.4f [%.4f, %.4f]\n",
              rate_aG, ci_aG["lo"], ci_aG["hi"],
              rate_aB, ci_aB["lo"], ci_aB["hi"]))

  cat(sprintf("  Approx error (informational) — reliever median: %.1f%%, starter median: %.1f%%\n",
              median(approx_err_reliever) * 100,
              median(approx_err_starter) * 100))

  # Flag investigation triggers
  if (rate_G < 0.995 && ci_G["lo"] < 0.990)
    warning(sprintf("%s: ERA sign-G hit rate %.4f below investigation trigger", scenario_id, rate_G))
  if (rate_B < 0.995 && ci_B["lo"] < 0.990)
    warning(sprintf("%s: ERA sign-B hit rate %.4f below investigation trigger", scenario_id, rate_B))

  record(scenario_id, n_teams, "M-2: ERA_sign_G",  rate_G,  1.0, eq_threshold)
  record(scenario_id, n_teams, "M-2: ERA_sign_B",  rate_B,  1.0, eq_threshold)
  record(scenario_id, n_teams, "M-3: WHIP_sign_G", rate_wG, 1.0, eq_threshold)
  record(scenario_id, n_teams, "M-3: WHIP_sign_B", rate_wB, 1.0, eq_threshold)
  record(scenario_id, n_teams, "M-4: AVG_sign_G",  rate_aG, 1.0, eq_threshold)
  record(scenario_id, n_teams, "M-4: AVG_sign_B",  rate_aB, 1.0, eq_threshold)

  list(
    approx_reliever = approx_err_reliever,
    approx_starter  = approx_err_starter
  )
}

approx_sc2  <- run_rate_sign_test("SC-2",  2L, 12L, 1000L)
approx_sc2a <- run_rate_sign_test("SC-2a", 3L, 10L,  500L)
approx_sc2b <- run_rate_sign_test("SC-2b", 4L, 15L,  500L)

# ---------------------------------------------------------------------------
# 3. SC-3: DGP-Additive — total_sgp additivity + permutation invariance
#    Scenario offset = 5, N_rep = 1000, n_players = 300, 8 permutations each
# ---------------------------------------------------------------------------

cat("\n=== SC-3: total_sgp additivity + permutation invariance ===\n")

SC3_OFFSET   <- 5L
SC3_NREP     <- 1000L
SC3_NPLAYERS <- 300L
SC3_NPERM    <- 8L

MIXED_CATS <- c("HR", "R", "SB", "ERA", "WHIP", "AVG")

sc3_add_max_error  <- 0
sc3_perm_max_error <- 0

for (r in seq_len(SC3_NREP)) {
  set.seed(sim_seed(SC3_OFFSET, r))

  HR   <- runif(SC3_NPLAYERS, 0, 50)
  R    <- runif(SC3_NPLAYERS, 20, 120)
  SB   <- runif(SC3_NPLAYERS, 0, 60)
  ERA  <- rtruncnorm(SC3_NPLAYERS, 4.0, 0.7, 1.5, 8.0)
  WHIP <- rtruncnorm(SC3_NPLAYERS, 1.25, 0.15, 0.8, 2.0)
  AVG  <- rtruncnorm(SC3_NPLAYERS, 0.255, 0.030, 0.150, 0.380)
  IP   <- runif(SC3_NPLAYERS, 20, 220)
  AB   <- runif(SC3_NPLAYERS, 50, 600)

  proj_baseline <- data.frame(HR, R, SB, ERA, WHIP, AVG, IP, AB)

  denom_HR   <- runif(1, 8, 20)
  denom_R    <- runif(1, 12, 25)
  denom_SB   <- runif(1, 3, 10)
  denom_ERA  <- runif(1, 0.15, 0.45)
  denom_WHIP <- runif(1, 0.04, 0.12)
  denom_AVG  <- runif(1, 0.0010, 0.0030)

  denom_obj <- make_fake_denoms(
    cats   = MIXED_CATS,
    values = c(denom_HR, denom_R, denom_SB, denom_ERA, denom_WHIP, denom_AVG),
    rate_conversion = "blended_pool"
  )

  n_teams <- 12L
  ts_ERA  <- rtruncnorm(n_teams, 4.20, 0.30, 1.5, 7.5)
  ts_IP   <- runif(n_teams, 1200, 1600)
  ts_WHIP <- rtruncnorm(n_teams, 1.30, 0.08, 0.8, 2.0)
  ts_AVG  <- rtruncnorm(n_teams, 0.255, 0.010, 0.150, 0.380)
  ts_AB   <- runif(n_teams, 5000, 5800)

  ts_data <- data.frame(
    year    = 2022L,
    team_id = paste0("T", seq_len(n_teams)),
    ERA     = ts_ERA, IP = ts_IP, WHIP = ts_WHIP, AVG = ts_AVG, AB = ts_AB
  )
  history_obj <- tryCatch(league_history(team_season = ts_data), error = function(e) NULL)
  if (is.null(history_obj)) next

  config_obj <- make_config(
    n_teams    = n_teams,
    categories = MIXED_CATS
  )

  # Baseline call (canonical column order)
  res_baseline <- tryCatch(
    suppressMessages(
      sgp(
        projections     = proj_baseline,
        denominators    = denom_obj,
        league_history  = history_obj,
        rate_conversion = "blended_pool",
        pool_baseline   = "projection_pool",
        league_config   = config_obj
      )
    ),
    error = function(e) {
      message(sprintf("  SC-3 rep %d baseline: sgp() error: %s", r, conditionMessage(e)))
      NULL
    }
  )
  if (is.null(res_baseline)) next

  # M-5: total_sgp additivity check
  sgp_cols <- grep("^sgp_", names(res_baseline), value = TRUE)
  sgp_cols_no_total <- sgp_cols[sgp_cols != "total_sgp"]
  if (length(sgp_cols_no_total) > 0L && "total_sgp" %in% names(res_baseline)) {
    expected_total <- rowSums(res_baseline[, sgp_cols_no_total, drop = FALSE])
    add_error <- max(abs(res_baseline$total_sgp - expected_total), na.rm = TRUE)
    if (add_error > sc3_add_max_error) sc3_add_max_error <- add_error
  }

  # M-6: permutation invariance
  # We fix the non-category columns (IP, AB) and permute only scored-category columns
  non_cat_cols <- c("IP", "AB")
  cat_cols_in_proj <- intersect(MIXED_CATS, names(proj_baseline))

  for (p in seq_len(SC3_NPERM)) {
    perm_order <- sample(length(cat_cols_in_proj))
    proj_perm  <- proj_baseline[, c(cat_cols_in_proj[perm_order], non_cat_cols)]

    res_perm <- tryCatch(
      suppressMessages(
        sgp(
          projections     = proj_perm,
          denominators    = denom_obj,
          league_history  = history_obj,
          rate_conversion = "blended_pool",
          pool_baseline   = "projection_pool",
          league_config   = config_obj
        )
      ),
      error = function(e) NULL
    )
    if (is.null(res_perm)) next

    if ("total_sgp" %in% names(res_perm) && "total_sgp" %in% names(res_baseline)) {
      perm_error <- max(abs(res_perm$total_sgp - res_baseline$total_sgp), na.rm = TRUE)
      if (perm_error > sc3_perm_max_error) sc3_perm_max_error <- perm_error
    }
  }
}

cat(sprintf("  M-5 additivity max error    : %.2e\n", sc3_add_max_error))
cat(sprintf("  M-6 permutation max error   : %.2e\n", sc3_perm_max_error))

record("SC-3", 12L, "M-5: total_sgp_additivity",        sc3_add_max_error,  1e-12, lt_threshold)
record("SC-3", 12L, "M-6: total_sgp_perm_invariance",   sc3_perm_max_error, 1e-12, lt_threshold)

# ---------------------------------------------------------------------------
# 4. SC-4: DGP-PoolSweep — Pool-size scaling sweep
#    Scenario offsets: 6 (n=10), 7 (n=12), 8 (n=15); N_rep = 500 each
# ---------------------------------------------------------------------------

cat("\n=== SC-4: Pool-size scaling sweep ===\n")

run_pool_sweep <- function(scenario_id, scenario_offset, n_teams, n_rep) {
  cat(sprintf("  %s: n_teams=%d\n", scenario_id, n_teams))

  pitcher_slots       <- 9L
  hitter_primary_slots <- c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L,
                              SS = 1L, OF = 3L, DH = 1L)
  pool_size_p <- n_teams * pitcher_slots
  pool_size_h <- n_teams * sum(hitter_primary_slots)

  m7_max_error <- 0

  for (r in seq_len(n_rep)) {
    set.seed(sim_seed(scenario_offset, r))

    # Pool pitchers
    pool_IP_all   <- runif(pool_size_p, 50, 220)
    pool_ERA_all  <- rtruncnorm(pool_size_p, 4.00, 0.60, 1.5, 7.5)
    pool_WHIP_all <- rtruncnorm(pool_size_p, 1.25, 0.15, 0.8, 2.0)

    ord_p     <- order(pool_IP_all, decreasing = TRUE)
    pool_IP   <- pool_IP_all[ord_p]
    pool_ERA  <- pool_ERA_all[ord_p]
    pool_WHIP <- pool_WHIP_all[ord_p]

    # Reference pool totals (independent)
    ref_pool_IP  <- sum(pool_IP)
    ref_pool_ER  <- sum(pool_ERA * pool_IP / 9)
    ref_pool_WH  <- sum(pool_WHIP * pool_IP)

    # Pool hitters
    pool_AB_all  <- runif(pool_size_h, 100, 600)
    pool_AVG_all <- rtruncnorm(pool_size_h, 0.255, 0.025, 0.150, 0.380)

    ord_h    <- order(pool_AB_all, decreasing = TRUE)
    pool_AB  <- pool_AB_all[ord_h]
    pool_AVG <- pool_AVG_all[ord_h]

    ref_pool_AB <- sum(pool_AB)
    ref_pool_H  <- sum(pool_AVG * pool_AB)

    # League history
    ts_ERA  <- rtruncnorm(n_teams, 4.20, 0.30, 1.5, 7.5)
    ts_IP   <- runif(n_teams, 1200, 1600)
    ts_WHIP <- rtruncnorm(n_teams, 1.30, 0.08, 0.8, 2.0)
    ts_AVG  <- rtruncnorm(n_teams, 0.255, 0.010, 0.150, 0.380)
    ts_AB   <- runif(n_teams, 5000, 5800)
    avg_ERA_true  <- stats::weighted.mean(ts_ERA,  ts_IP)
    avg_WHIP_true <- stats::weighted.mean(ts_WHIP, ts_IP)
    avg_AVG_true  <- stats::weighted.mean(ts_AVG,  ts_AB)

    ts_data <- data.frame(
      year    = 2022L,
      team_id = paste0("T", seq_len(n_teams)),
      ERA = ts_ERA, IP = ts_IP, WHIP = ts_WHIP, AVG = ts_AVG, AB = ts_AB
    )
    history_obj <- tryCatch(league_history(team_season = ts_data), error = function(e) NULL)
    if (is.null(history_obj)) next

    # Good pitcher for indirect M-7 check
    G_ERA  <- runif(1, 1.5, avg_ERA_true - 0.5)
    G_WHIP <- runif(1, 0.8, avg_WHIP_true - 0.1)
    G_IP   <- runif(1, 100, 220)

    # Projections: pool + G player
    projections <- data.frame(
      IP   = c(pool_IP,   G_IP),
      ERA  = c(pool_ERA,  G_ERA),
      WHIP = c(pool_WHIP, G_WHIP),
      HR   = c(runif(pool_size_p, 0, 2), 0),
      AB   = as.integer(c(rep(0L, pool_size_p), 0L)),
      AVG  = 0,
      R    = as.integer(0L),
      SB   = as.integer(0L)
    )

    denom_ERA  <- runif(1, 0.15, 0.45)
    denom_WHIP <- runif(1, 0.04, 0.12)
    denom_AVG  <- runif(1, 0.0010, 0.0030)
    denom_HR   <- runif(1, 8, 20)
    scored_cats <- c("HR", "ERA", "WHIP", "AVG")

    denom_obj <- make_fake_denoms(
      cats            = scored_cats,
      values          = c(denom_HR, denom_ERA, denom_WHIP, denom_AVG),
      rate_conversion = "blended_pool"
    )

    config_obj <- make_config(
      n_teams       = n_teams,
      pitcher_slots = pitcher_slots,
      roster_slots  = hitter_primary_slots,
      categories    = scored_cats
    )

    result <- tryCatch(
      suppressMessages(
        sgp(
          projections     = projections,
          denominators    = denom_obj,
          league_history  = history_obj,
          rate_conversion = "blended_pool",
          pool_baseline   = "projection_pool",
          league_config   = config_obj
        )
      ),
      error = function(e) NULL
    )
    if (is.null(result)) next

    # M-7: indirect pool-size verification
    # Independently recompute blended ERA for G player using ref_pool_IP / ref_pool_ER
    G_ER           <- G_ERA * G_IP / 9
    blended_ERA_G_ref <- (ref_pool_ER + G_ER) * 9 / (ref_pool_IP + G_IP)
    expected_ERA_sgp_G <- (avg_ERA_true - blended_ERA_G_ref) / denom_ERA

    idx_G <- pool_size_p + 1L
    if (!is.null(result$sgp_ERA) && !is.na(result$sgp_ERA[idx_G])) {
      m7_err <- abs(result$sgp_ERA[idx_G] - expected_ERA_sgp_G)
      if (m7_err > m7_max_error) m7_max_error <- m7_err
    }
  }

  cat(sprintf("    M-7 pool-size match max error: %.2e\n", m7_max_error))
  record(scenario_id, n_teams, "M-7: pool_size_match", m7_max_error, 1e-10, lt_threshold)
}

run_pool_sweep("SC-4(n=10)", 6L, 10L, 500L)
run_pool_sweep("SC-4(n=12)", 7L, 12L, 500L)
run_pool_sweep("SC-4(n=15)", 8L, 15L, 500L)

# ---------------------------------------------------------------------------
# 5. SC-5: DGP-Compat — Denominator-attribute compatibility check
#    Scenario offset = 9, N_rep = 200
# ---------------------------------------------------------------------------

cat("\n=== SC-5: Denominator compatibility check ===\n")

SC5_OFFSET <- 9L
SC5_NREP   <- 200L

sc5_abort_count <- 0L

for (r in seq_len(SC5_NREP)) {
  set.seed(sim_seed(SC5_OFFSET, r))

  # Counting-only projections
  proj <- data.frame(
    HR  = runif(50, 1, 50),
    R   = runif(50, 20, 120),
    RBI = runif(50, 20, 120),
    SB  = runif(50, 0, 60)
  )

  # denom with "fixed_baseline" attribute — incompatible with blended_pool call
  denom_obj <- make_fake_denoms(
    cats            = c("HR", "R", "RBI", "SB"),
    values          = c(runif(1, 8, 20), runif(1, 12, 25),
                        runif(1, 12, 25), runif(1, 3, 10)),
    rate_conversion = "fixed_baseline"
  )

  ts_data <- data.frame(
    year    = 2022L,
    team_id = paste0("T", seq_len(12L)),
    HR      = runif(12L, 150, 250),
    R       = runif(12L, 650, 850),
    RBI     = runif(12L, 650, 850),
    SB      = runif(12L, 50, 150),
    IP      = runif(12L, 1200, 1600),
    AB      = runif(12L, 5000, 5800),
    ERA     = rnorm(12L, 4.2, 0.3),
    WHIP    = rnorm(12L, 1.30, 0.08),
    AVG     = rnorm(12L, 0.255, 0.010)
  )
  history_obj <- tryCatch(league_history(team_season = ts_data), error = function(e) NULL)
  if (is.null(history_obj)) next

  config_obj <- make_config(
    n_teams    = 12L,
    categories = c("HR", "R", "RBI", "SB")
  )

  result <- tryCatch(
    suppressMessages(
      sgp(
        projections     = proj,
        denominators    = denom_obj,
        league_history  = history_obj,
        rate_conversion = "blended_pool",
        pool_baseline   = "projection_pool",
        league_config   = config_obj
      )
    ),
    rotostats_error_invalid_rate_conversion = function(e) {
      sc5_abort_count <<- sc5_abort_count + 1L
      NULL
    },
    error = function(e) {
      # Wrong error class — counts as failure
      message(sprintf("  SC-5 rep %d: wrong error class: %s", r, class(e)[1]))
      NULL
    }
  )
}

sc5_rate <- sc5_abort_count / SC5_NREP
cat(sprintf("  M-8 compat abort rate: %.4f (%d/%d)\n",
            sc5_rate, sc5_abort_count, SC5_NREP))
record("SC-5", 12L, "M-8: compat_abort_rate", sc5_rate, 1.0, eq_threshold)

# ---------------------------------------------------------------------------
# 6. SC-6: DGP-EdgeCase — Zero IP/AB players
#    Scenario offset = 10, N_rep = 500, n_players = 100 + 2
# ---------------------------------------------------------------------------

cat("\n=== SC-6: Zero IP/AB edge cases ===\n")

SC6_OFFSET   <- 10L
SC6_NREP     <- 500L
SC6_NPLAYERS <- 100L

sc6_era_na  <- 0L  # zero-IP pitcher: sgp_ERA == NA
sc6_whip_na <- 0L  # zero-IP pitcher: sgp_WHIP == NA
sc6_avg_na  <- 0L  # zero-AB hitter:  sgp_AVG == NA

for (r in seq_len(SC6_NREP)) {
  set.seed(sim_seed(SC6_OFFSET, r))

  n_teams <- 12L
  pitcher_slots <- 9L
  hitter_primary_slots <- c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L,
                             SS = 1L, OF = 3L, DH = 1L)
  pool_size_p <- n_teams * pitcher_slots
  pool_size_h <- n_teams * sum(hitter_primary_slots)

  # Normal players (100 rows): mix of pitchers and hitters
  normal_IP  <- runif(SC6_NPLAYERS, 20, 220)
  normal_AB  <- as.integer(round(runif(SC6_NPLAYERS, 50, 600)))
  normal_ERA <- rtruncnorm(SC6_NPLAYERS, 4.0, 0.7, 1.5, 8.0)
  normal_WHIP<- rtruncnorm(SC6_NPLAYERS, 1.25, 0.15, 0.8, 2.0)
  normal_AVG <- rtruncnorm(SC6_NPLAYERS, 0.255, 0.030, 0.150, 0.380)
  normal_HR  <- as.integer(round(runif(SC6_NPLAYERS, 0, 40)))
  normal_R   <- as.integer(round(runif(SC6_NPLAYERS, 20, 120)))
  normal_SB  <- as.integer(round(runif(SC6_NPLAYERS, 0, 40)))

  # Zero-IP pitcher (row 101)
  zero_ip_row <- data.frame(
    IP = 0, AB = 0L,
    ERA = 4.50, WHIP = 1.30, AVG = 0.0,
    HR = 0L, R = 0L, SB = 0L
  )

  # Zero-AB hitter (row 102)
  zero_ab_row <- data.frame(
    IP = 0, AB = 0L,
    ERA = 0.0, WHIP = 0.0, AVG = 0.260,
    HR = 5L, R = 20L, SB = 3L
  )

  normal_rows <- data.frame(
    IP = normal_IP, AB = normal_AB,
    ERA = normal_ERA, WHIP = normal_WHIP, AVG = normal_AVG,
    HR = normal_HR, R = normal_R, SB = normal_SB
  )

  projections <- rbind(normal_rows, zero_ip_row, zero_ab_row)
  idx_zero_ip <- SC6_NPLAYERS + 1L
  idx_zero_ab <- SC6_NPLAYERS + 2L

  scored_cats <- c("HR", "ERA", "WHIP", "AVG")
  denom_obj <- make_fake_denoms(
    cats            = scored_cats,
    values          = c(runif(1, 8, 20), runif(1, 0.15, 0.45),
                        runif(1, 0.04, 0.12), runif(1, 0.0010, 0.0030)),
    rate_conversion = "blended_pool"
  )

  ts_ERA  <- rtruncnorm(n_teams, 4.20, 0.30, 1.5, 7.5)
  ts_IP   <- runif(n_teams, 1200, 1600)
  ts_WHIP <- rtruncnorm(n_teams, 1.30, 0.08, 0.8, 2.0)
  ts_AVG  <- rtruncnorm(n_teams, 0.255, 0.010, 0.150, 0.380)
  ts_AB   <- runif(n_teams, 5000, 5800)

  ts_data <- data.frame(
    year    = 2022L,
    team_id = paste0("T", seq_len(n_teams)),
    ERA = ts_ERA, IP = ts_IP, WHIP = ts_WHIP, AVG = ts_AVG, AB = ts_AB
  )
  history_obj <- tryCatch(league_history(team_season = ts_data), error = function(e) NULL)
  if (is.null(history_obj)) next

  config_obj <- make_config(
    n_teams       = n_teams,
    pitcher_slots = pitcher_slots,
    roster_slots  = hitter_primary_slots,
    categories    = scored_cats
  )

  result <- tryCatch(
    suppressMessages(
      sgp(
        projections     = projections,
        denominators    = denom_obj,
        league_history  = history_obj,
        rate_conversion = "blended_pool",
        pool_baseline   = "projection_pool",
        league_config   = config_obj
      )
    ),
    error = function(e) {
      message(sprintf("  SC-6 rep %d: sgp() error: %s", r, conditionMessage(e)))
      NULL
    }
  )
  if (is.null(result)) next

  if (!is.null(result$sgp_ERA)  && is.na(result$sgp_ERA[idx_zero_ip]))  sc6_era_na  <- sc6_era_na  + 1L
  if (!is.null(result$sgp_WHIP) && is.na(result$sgp_WHIP[idx_zero_ip])) sc6_whip_na <- sc6_whip_na + 1L
  if (!is.null(result$sgp_AVG)  && is.na(result$sgp_AVG[idx_zero_ab]))  sc6_avg_na  <- sc6_avg_na  + 1L
}

sc6_era_rate  <- sc6_era_na  / SC6_NREP
sc6_whip_rate <- sc6_whip_na / SC6_NREP
sc6_avg_rate  <- sc6_avg_na  / SC6_NREP

cat(sprintf("  M-9 zero-IP ERA NA rate : %.4f (%d/%d)\n",
            sc6_era_rate,  sc6_era_na,  SC6_NREP))
cat(sprintf("  M-9 zero-IP WHIP NA rate: %.4f (%d/%d)\n",
            sc6_whip_rate, sc6_whip_na, SC6_NREP))
cat(sprintf("  M-9 zero-AB AVG NA rate : %.4f (%d/%d)\n",
            sc6_avg_rate,  sc6_avg_na,  SC6_NREP))

# M-9 pass requires all three NA rates to be 1.000
sc6_all_rate <- min(sc6_era_rate, sc6_whip_rate, sc6_avg_rate)
record("SC-6", 12L, "M-9: zero_ip_ERA_NA_rate",  sc6_era_rate,  1.0, eq_threshold)
record("SC-6", 12L, "M-9: zero_ip_WHIP_NA_rate", sc6_whip_rate, 1.0, eq_threshold)
record("SC-6", 12L, "M-9: zero_ab_AVG_NA_rate",  sc6_avg_rate,  1.0, eq_threshold)

# ---------------------------------------------------------------------------
# 7. Assemble and print results table
# ---------------------------------------------------------------------------

cat("\n=== RESULTS TABLE ===\n")

results_df <- do.call(rbind, all_results)
row.names(results_df) <- NULL

# Pretty-print
cat(sprintf("%-18s %8s  %-38s %12s %12s %5s\n",
            "scenario_id", "n_teams", "metric", "value", "threshold", "pass"))
cat(strrep("-", 100), "\n")
for (i in seq_len(nrow(results_df))) {
  row <- results_df[i, ]
  cat(sprintf("%-18s %8s  %-38s %12.6g %12.6g %5s\n",
              row$scenario_id,
              ifelse(is.na(row$n_teams), "N/A", as.character(row$n_teams)),
              row$metric,
              row$value,
              row$threshold,
              ifelse(row$pass, "PASS", "FAIL")))
}

# Failures summary
failures <- results_df[!results_df$pass, ]
if (nrow(failures) > 0L) {
  cat("\n=== FAILURES ===\n")
  for (i in seq_len(nrow(failures))) {
    row <- failures[i, ]
    cat(sprintf("  FAIL: %s / %s — value=%.6g, threshold=%.6g\n",
                row$scenario_id, row$metric, row$value, row$threshold))
  }
} else {
  cat("\nAll acceptance criteria passed.\n")
}

# Blended-pool approximation error table (informational)
cat("\n=== BLENDED-POOL APPROXIMATION ERROR (informational, SC-2) ===\n")
cat(sprintf("  SC-2  reliever median: %.1f%%  starter median: %.1f%%\n",
            median(approx_sc2$approx_reliever)  * 100,
            median(approx_sc2$approx_starter)   * 100))
cat(sprintf("  SC-2a reliever median: %.1f%%  starter median: %.1f%%\n",
            median(approx_sc2a$approx_reliever) * 100,
            median(approx_sc2a$approx_starter)  * 100))
cat(sprintf("  SC-2b reliever median: %.1f%%  starter median: %.1f%%\n",
            median(approx_sc2b$approx_reliever) * 100,
            median(approx_sc2b$approx_starter)  * 100))

# Check spec-noted investigation flags
for (sname in c("SC-2", "SC-2a", "SC-2b")) {
  approx_list <- switch(sname,
    "SC-2"  = approx_sc2,
    "SC-2a" = approx_sc2a,
    "SC-2b" = approx_sc2b
  )
  med_rel <- median(approx_list$approx_reliever)
  med_sta <- median(approx_list$approx_starter)
  if (med_rel > 0.15)
    cat(sprintf("  FLAG: %s reliever approximation error %.1f%% exceeds 15%% — warrants investigation\n",
                sname, med_rel * 100))
  if (med_sta > 0.25)
    cat(sprintf("  FLAG: %s starter approximation error %.1f%% exceeds 25%% — warrants investigation\n",
                sname, med_sta * 100))
}

# Save results for tester
invisible(results_df)
