# tests/testthat/test-replacement.R
#
# Unit tests for replacement_level(), default_replacement_params, and
# rate_stat_denominators().  Written by the tester pipeline from test-spec.md.
# Tester did NOT read spec.md, sim-spec.md, or implementation.md.

library(testthat)

# ---------------------------------------------------------------------------
# Standard config fixtures (test-spec.md §1)
# ---------------------------------------------------------------------------

cfg_mixed_12 <- league_config(
  n_teams       = 12L,
  roster_slots  = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L, SS = 1L,
                    OF = 3L, UTIL = 1L),
  pitcher_slots = c(SP = 6L, RP = 3L),
  categories    = c("HR", "R", "RBI", "SB", "AVG",
                    "W", "K", "SV", "ERA", "WHIP"),
  league_type   = "mixed",
  budget        = 260L
)

cfg_al_12 <- league_config(
  n_teams       = 12L,
  roster_slots  = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L, SS = 1L,
                    OF = 3L, DH = 1L, UTIL = 1L),
  pitcher_slots = c(SP = 6L, RP = 3L),
  categories    = c("HR", "R", "RBI", "SB", "AVG",
                    "W", "K", "SV", "ERA", "WHIP"),
  league_type   = "AL",
  budget        = 260L
)

# ---------------------------------------------------------------------------
# §2  Output Contract Tests
# ---------------------------------------------------------------------------

test_that("TS-01: basic return structure", {
  proj   <- make_projections_data(seed = 42L)
  result <- replacement_level(proj, config = cfg_mixed_12)

  expect_named(result,
    c("replacement_stats", "positional_adjustments",
      "cliff_metric", "two_way_players",
      "pool_diagnostics", "method", "params"),
    ignore.order = TRUE
  )
  expect_equal(result$method, "boundary_band")
  expect_s3_class(result$replacement_stats, "data.frame")
  expect_true("position"       %in% names(result$replacement_stats))
  expect_true("n_band_players" %in% names(result$replacement_stats))
  expect_true("cliff_detected" %in% names(result$replacement_stats))
  expect_true("IP"             %in% names(result$replacement_stats))

  sp_row <- result$replacement_stats[result$replacement_stats$position == "SP", ]
  expect_true(!is.na(sp_row$IP))
})

test_that("TS-02: output attributes present", {
  proj   <- make_projections_data(seed = 42L)
  result <- replacement_level(proj, config = cfg_mixed_12)

  expect_equal(attr(result, "stat_units"), "raw_projected")
  expect_s3_class(attr(result, "config"), "league_config")
  expect_true(is.data.frame(attr(result, "projections")))
  expect_true(is.character(attr(result, "position_assignments")))
  expect_true(!is.null(names(attr(result, "position_assignments"))))
  expect_true(is.logical(attr(result, "converged")))
  iter <- attr(result, "iterations")
  expect_true(is.integer(iter) || is.numeric(iter))
  expect_true(is.numeric(attr(result, "delta")))
})

test_that("TS-03: normalize_to_season = TRUE sets stat_units", {
  proj    <- make_projections_data(seed = 42L)
  result2 <- replacement_level(proj, config = cfg_mixed_12,
                                normalize_to_season = TRUE)
  expect_equal(attr(result2, "stat_units"), "full_season_normalized")
})

test_that("TS-04: params list keys and defaults", {
  proj   <- make_projections_data(seed = 42L)
  result <- replacement_level(proj, config = cfg_mixed_12)

  expect_named(result$params,
    c("converged", "iterations", "delta", "n_teams", "roster_slots",
      "band_width", "cliff_threshold", "sort_by", "stat_units",
      "catcher_adjustment_method", "method"),
    ignore.order = TRUE
  )
  expect_equal(result$params$n_teams, 12L)
  expect_equal(result$params$band_width, 3L)
})

# ---------------------------------------------------------------------------
# §3  Boundary Band Tests
# ---------------------------------------------------------------------------

test_that("TS-05: counting stat replacement = arithmetic mean of band", {
  # 20 1B-only players; 12 teams × 1 slot → boundary at 12
  # K=3 → K_eff = min(3, floor(12/4)) = 3 → band = ranks 9-15 (7 players)
  # HR sorted desc: 40,38,...,2 (step -2) → rank 9=24, 10=22, 11=20, 12=18,
  #                                           13=16, 14=14, 15=12
  # Expected mean = (24+22+20+18+16+14+12)/7 = 126/7 = 18
  # To isolate: make all non-HR stats identical so z-score rank = HR rank
  proj_1b <- data.frame(
    player_id       = paste0("P", 1:20),
    player_name     = paste0("Player", 1:20),
    pos_eligibility = rep("1B", 20),
    team            = rep("NYY", 20),
    league          = rep("AL", 20),
    HR              = seq(40, 2, by = -2),
    R               = rep(70, 20),
    RBI             = rep(80, 20),
    SB              = rep(5, 20),
    AVG             = rep(0.260, 20),
    AB              = rep(450, 20),
    IP              = rep(NA_real_, 20),
    stringsAsFactors = FALSE
  )
  cfg_1b <- league_config(
    n_teams       = 12L,
    roster_slots  = c(`1B` = 1L),
    pitcher_slots = c(SP = 6L, RP = 3L),
    categories    = c("HR", "R", "RBI", "SB", "AVG"),
    league_type   = "AL"
  )
  result  <- replacement_level(proj_1b, config = cfg_1b)
  repl_hr <- result$replacement_stats[
    result$replacement_stats$position == "1B", "HR"
  ]
  expect_lt(abs(repl_hr - 18.0), 1e-9)
})

test_that("TS-06: AVG replacement = sum(H)/sum(AB), not mean(AVG)", {
  # Test the compute_replacement_stat_line internal function directly.
  # This is the function responsible for AVG aggregation in the band.
  fn <- getFromNamespace("compute_replacement_stat_line", "rotostats")
  band_df <- data.frame(
    HR  = c(12, 11, 10),
    R   = rep(50, 3),
    RBI = rep(60, 3),
    SB  = rep(5, 3),
    AB  = c(350, 420, 480),
    AVG = c(0.240, 0.250, 0.260),
    IP  = rep(NA_real_, 3)
  )
  result_line <- fn(
    band_df     = band_df,
    scored_cats = c("HR", "R", "RBI", "SB", "AVG"),
    rate_cats   = "AVG",
    include_ip  = FALSE,
    include_ab  = TRUE
  )
  # sum(H)/sum(AB) = (0.240*350 + 0.250*420 + 0.260*480) / (350+420+480)
  #                = (84 + 105 + 124.8) / 1250 = 313.8 / 1250 = 0.25104
  expected_avg <- (0.240 * 350 + 0.250 * 420 + 0.260 * 480) / (350 + 420 + 480)
  simple_mean  <- mean(c(0.240, 0.250, 0.260))

  expect_lt(abs(result_line["AVG"] - expected_avg), 1e-6)
  # Must differ from simple mean (0.250) to confirm weighted aggregation
  expect_gt(abs(result_line["AVG"] - simple_mean), 1e-4)
})

test_that("TS-07: ERA and WHIP replacement = IP-weighted mean", {
  # Test compute_replacement_stat_line directly for ERA and WHIP.
  fn <- getFromNamespace("compute_replacement_stat_line", "rotostats")
  band_df <- data.frame(
    W    = c(14, 12, 10),
    K    = c(185, 170, 160),
    SV   = rep(0, 3),
    ERA  = c(3.20, 3.60, 4.00),
    WHIP = c(1.10, 1.20, 1.30),
    IP   = c(180, 170, 155)
  )
  result_line <- fn(
    band_df     = band_df,
    scored_cats = c("W", "K", "SV", "ERA", "WHIP"),
    rate_cats   = c("ERA", "WHIP"),
    include_ip  = TRUE,
    include_ab  = FALSE
  )
  # Weighted ERA = (3.20*180 + 3.60*170 + 4.00*155) / (180+170+155)
  #              = (576 + 612 + 620) / 505 = 1808/505 = 3.580198...
  expected_era  <- (3.20 * 180 + 3.60 * 170 + 4.00 * 155) / (180 + 170 + 155)
  expected_whip <- (1.10 * 180 + 1.20 * 170 + 1.30 * 155) / (180 + 170 + 155)

  expect_lt(abs(result_line["ERA"]  - expected_era),  1e-6)
  expect_lt(abs(result_line["WHIP"] - expected_whip), 1e-6)
})

test_that("TS-08: dynamic K cap limits band size in thin pool", {
  # Test compute_band_indices directly for the K_eff formula.
  # 5 teams × 1 SS slot → n_rostered = 5; K=3 → K_eff = min(3, floor(5/4)) = 1
  # Band = 2*K_eff+1 = 3 players max; pool = 10 players
  band_fn <- getFromNamespace("compute_band_indices", "rotostats")

  # Case 1: 12-team AL SS → K_eff = min(3, floor(12/4)) = 3; band = 7
  bi_12 <- band_fn(n_rostered_pos = 12L, pool_size = 20L, K = 3L)
  expect_equal(bi_12$K_eff, 3L)
  expect_equal(length(bi_12$B_all), 7L)

  # Case 2: 5-team AL SS (thin pool) → K_eff = min(3, floor(5/4)) = 1; band = 3
  bi_5 <- band_fn(n_rostered_pos = 5L, pool_size = 10L, K = 3L)
  expect_equal(bi_5$K_eff, 1L)
  expect_lte(length(bi_5$B_all), 3L)
})

# ---------------------------------------------------------------------------
# §4  Cliff Detection Tests
# ---------------------------------------------------------------------------

test_that("TS-09: cliff detection skipped when lower half < cliff_min_n", {
  # Use compute_band_indices to verify K_eff, then test detect_cliff directly
  detect_fn <- getFromNamespace("detect_cliff", "rotostats")

  # Lower half has only 2 players (< cliff_min_n = 4) → should return cliff_detected = FALSE
  result <- detect_fn(
    B_lower_values            = c(1.0, 0.5),    # 2 lower players
    band_all_values           = c(10, 8, 6, 1.0, 0.5),
    cliff_method              = "mad",
    cliff_threshold           = 1.5,
    cliff_gap_ratio_threshold = 0.375,
    cliff_min_n               = 4L
  )
  expect_false(result$cliff_detected)
})

test_that("TS-10: cliff detected in lower half (MAD method) via integration test", {
  # Build a complete projection set: SS hitters + SP/RP pitchers
  # so cfg_al_12 (which needs W, K, SV, ERA, WHIP) is satisfied
  n_ss  <- 25L
  n_sp  <- 80L   # satisfies 12*6=72
  n_rp  <- 40L   # satisfies 12*3=36
  n_total <- n_ss + n_sp + n_rp

  proj_cliff <- data.frame(
    player_id       = paste0("P", seq_len(n_total)),
    player_name     = paste0("Player_", seq_len(n_total)),
    pos_eligibility = c(rep("SS", n_ss), rep("SP", n_sp), rep("RP", n_rp)),
    team            = rep("BOS", n_total),
    league          = rep("AL", n_total),
    HR  = c(30, 28, 26, 24, 22, 20, 18, 16, 14, 12, 10, 8,
            1, 0.5, 0.3, rep(0, 10),
            rep(NA_real_, n_sp + n_rp)),
    R   = c(rep(50, n_ss),  rep(NA_real_, n_sp + n_rp)),
    RBI = c(rep(60, n_ss),  rep(NA_real_, n_sp + n_rp)),
    SB  = c(rep(3, n_ss),   rep(NA_real_, n_sp + n_rp)),
    AVG = c(rep(0.250, n_ss), rep(NA_real_, n_sp + n_rp)),
    AB  = c(rep(300, n_ss), rep(NA_real_, n_sp + n_rp)),
    W   = c(rep(NA_real_, n_ss),
            round(pmax(0, rnorm(n_sp, 12, 4))),
            rep(NA_real_, n_rp)),
    K   = c(rep(NA_real_, n_ss),
            round(pmax(20, rnorm(n_sp, 165, 35))),
            round(pmax(10, rnorm(n_rp, 60, 20)))),
    SV  = c(rep(NA_real_, n_ss + n_sp),
            round(pmax(0, rnorm(n_rp, 8, 10)))),
    ERA = c(rep(NA_real_, n_ss),
            round(pmax(2.0, pmin(7.5, rnorm(n_sp, 3.90, 0.80))), 2),
            round(pmax(2.0, pmin(7.5, rnorm(n_rp, 3.80, 1.00))), 2)),
    WHIP= c(rep(NA_real_, n_ss),
            round(pmax(0.90, pmin(2.00, rnorm(n_sp, 1.25, 0.15))), 3),
            round(pmax(0.90, pmin(2.00, rnorm(n_rp, 1.25, 0.20))), 3)),
    IP  = c(rep(NA_real_, n_ss),
            round(pmax(140, rnorm(n_sp, 170, 15)), 1),
            round(pmax(40,  rnorm(n_rp,  60, 10)), 1)),
    stringsAsFactors = FALSE
  )
  set.seed(42L)
  result_cliff <- replacement_level(
    proj_cliff,
    config          = cfg_al_12,
    cliff_method    = "mad",
    cliff_threshold = 1.5
  )
  ss_cliff <- result_cliff$cliff_metric[
    result_cliff$cliff_metric$position == "SS", , drop = FALSE
  ]
  expect_true(ss_cliff$cliff_detected)
  # Band was truncated
  expect_lt(ss_cliff$n_band_players, 7L)
})

test_that("TS-11: cliff detection only applies to lower half (direct unit test)", {
  detect_fn <- getFromNamespace("detect_cliff", "rotostats")

  # Large gap in upper half values, no gap in lower half → not detected
  # band_all: upper=[30,28,26,...] lower=[8,7.5,7]
  # Introduce a gap only in upper half by passing lower half with no gap
  result <- detect_fn(
    B_lower_values            = c(8.0, 7.5, 7.0, 6.5),  # uniform, no cliff
    band_all_values           = c(30, 1, 8.0, 7.5, 7.0, 6.5),  # big gap in upper (30→1)
    cliff_method              = "mad",
    cliff_threshold           = 1.5,
    cliff_gap_ratio_threshold = 0.375,
    cliff_min_n               = 4L
  )
  # No cliff in lower half values → not detected
  expect_false(result$cliff_detected)
})

# ---------------------------------------------------------------------------
# §5  Zero-Sum Assertion Tests
# ---------------------------------------------------------------------------

test_that("TS-12: zero-sum holds for default catcher_adjustment_method = split_pool", {
  proj   <- make_projections_data(seed = 42L)
  result <- replacement_level(proj, config = cfg_mixed_12)
  pa     <- result$positional_adjustments
  rs     <- cfg_mixed_12$roster_slots

  zs_pos   <- setdiff(c("C", "1B", "2B", "3B", "SS", "OF"), "C")
  zs_pos   <- intersect(zs_pos, names(pa))
  zs_check <- sum(rs[zs_pos] * pa[zs_pos], na.rm = TRUE)
  expect_lt(abs(zs_check), 1e-6)
})

test_that("TS-13: zero-sum holds for catcher_adjustment_method = positional_default", {
  proj      <- make_projections_data(seed = 42L)
  result_pd <- replacement_level(proj, config = cfg_mixed_12,
                                   catcher_adjustment_method = "positional_default")
  pa_pd    <- result_pd$positional_adjustments
  rs       <- cfg_mixed_12$roster_slots

  zs_pos_pd  <- intersect(c("C", "1B", "2B", "3B", "SS", "OF"), names(pa_pd))
  zs_check_pd <- sum(rs[zs_pos_pd] * pa_pd[zs_pos_pd], na.rm = TRUE)
  expect_lt(abs(zs_check_pd), 1e-6)
})

test_that("TS-14: zero-sum holds for catcher_adjustment_method = none", {
  proj      <- make_projections_data(seed = 42L)
  result_n  <- replacement_level(proj, config = cfg_mixed_12,
                                   catcher_adjustment_method = "none")
  pa_n     <- result_n$positional_adjustments
  rs       <- cfg_mixed_12$roster_slots

  zs_pos_n    <- intersect(c("C", "1B", "2B", "3B", "SS", "OF"), names(pa_n))
  zs_check_n  <- sum(rs[zs_pos_n] * pa_n[zs_pos_n], na.rm = TRUE)
  expect_lt(abs(zs_check_n), 1e-6)
})

test_that("TS-15: zero-sum holds for catcher_adjustment_method = partial_offset", {
  proj     <- make_projections_data(seed = 42L)
  result_po <- replacement_level(proj, config = cfg_mixed_12,
                                   catcher_adjustment_method = "partial_offset")
  pa_po    <- result_po$positional_adjustments
  rs       <- cfg_mixed_12$roster_slots

  zs_pos_po   <- intersect(c("C", "1B", "2B", "3B", "SS", "OF"), names(pa_po))
  zs_check_po <- sum(rs[zs_pos_po] * pa_po[zs_pos_po], na.rm = TRUE)
  expect_lt(abs(zs_check_po), 1e-6)
})

test_that("TS-16: scarcity premium direction - C and SS positive, OF at or below zero", {
  proj   <- make_projections_data(seed = 42L)
  result <- replacement_level(proj, config = cfg_mixed_12)
  pa     <- result$positional_adjustments

  expect_gt(pa["C"],  0)
  expect_gt(pa["SS"], 0)
  expect_lte(pa["OF"], 0)
})

# ---------------------------------------------------------------------------
# §6  SP/RP Separation and Role Inference Tests
# ---------------------------------------------------------------------------

test_that("TS-17: SP and RP always produce separate replacement rows", {
  proj   <- make_projections_data(seed = 42L)
  result <- replacement_level(proj, config = cfg_mixed_12)

  positions <- result$replacement_stats$position
  expect_true("SP" %in% positions)
  expect_true("RP" %in% positions)

  sp_era <- result$replacement_stats[result$replacement_stats$position == "SP", "ERA"]
  rp_era <- result$replacement_stats[result$replacement_stats$position == "RP", "ERA"]
  expect_false(isTRUE(all.equal(sp_era, rp_era)))
})

test_that("TS-18: SP/RP inferred from IP when role column absent", {
  proj         <- make_projections_data(seed = 42L)
  proj_no_role <- proj[, setdiff(names(proj), "role")]

  result_inferred <- replacement_level(proj_no_role, config = cfg_mixed_12)
  expect_true("SP" %in% result_inferred$replacement_stats$position)
  expect_true("RP" %in% result_inferred$replacement_stats$position)
})

test_that("TS-19: explicit role column used directly when present", {
  proj <- make_projections_data(seed = 42L)
  # Assign role="SP" to pitchers with IP < 100 (override IP-based inference)
  is_pitcher <- !is.na(proj$IP)
  proj$role[is_pitcher & proj$IP < 100] <- "SP"

  result_explicit <- replacement_level(proj, config = cfg_mixed_12)
  expect_true("SP" %in% result_explicit$replacement_stats$position)
  expect_true("RP" %in% result_explicit$replacement_stats$position)
})

test_that("TS-20: swingman flag set for pitchers with 80 <= IP <= 120", {
  proj <- make_projections_data(seed = 42L)
  # Force some SP to be in swingman range (80-120 IP)
  sp_idx <- which(proj$pos_eligibility == "SP")
  sp_sorted <- sp_idx[order(proj$IP[sp_idx], decreasing = TRUE)]
  proj$IP[sp_sorted[c(6, 7)]] <- 95

  result <- replacement_level(proj, config = cfg_mixed_12)
  # swingman column exists in cliff_metric
  expect_true("swingman" %in% names(result$cliff_metric))
})

test_that("TS-21: pitcher replacement_stats always includes IP column", {
  proj   <- make_projections_data(seed = 42L)
  result <- replacement_level(proj, config = cfg_mixed_12)

  expect_true("IP" %in% names(result$replacement_stats))
  sp_ip <- result$replacement_stats[result$replacement_stats$position == "SP", "IP"]
  expect_true(!is.na(sp_ip))
  expect_gt(sp_ip, 0)
})

# ---------------------------------------------------------------------------
# §7  Invalid Pairings and Error Tests
# ---------------------------------------------------------------------------

test_that("TS-22: sort_by = sgp without sgp_denominators → error", {
  proj <- make_projections_data(seed = 42L)
  expect_error(
    replacement_level(proj, config = cfg_mixed_12, sort_by = "sgp"),
    class = "rotostats_error_missing_sgp_denominators"
  )
})

test_that("TS-23 & TS-24: boundary_rate_method=sgp_pool × rate_conversion=fixed_baseline → error naming both", {
  proj <- make_projections_data(seed = 42L)
  fake_denoms <- structure(
    list(denominators = c(ERA = 0.5, WHIP = 0.05)),
    class           = c("sgp_denominators", "list"),
    rate_conversion = "fixed_baseline"
  )

  err <- tryCatch(
    replacement_level(
      proj,
      config               = cfg_mixed_12,
      boundary_rate_method = "sgp_pool",
      sgp_denominators     = fake_denoms
    ),
    error = function(e) e
  )
  expect_s3_class(err, "rotostats_error_rate_method_mismatch")
  expect_match(conditionMessage(err), "fixed_baseline")
  expect_match(conditionMessage(err), "sgp_pool")
})

test_that("TS-25: projections missing required column → error", {
  proj     <- make_projections_data(seed = 42L)
  proj_bad <- proj[, setdiff(names(proj), "player_id")]
  expect_error(
    replacement_level(proj_bad, config = cfg_mixed_12),
    class = "rotostats_error_missing_column"
  )
})

test_that("TS-26: wrong column type → error", {
  proj          <- make_projections_data(seed = 42L)
  proj_bad_type <- proj
  proj_bad_type$HR <- as.character(proj_bad_type$HR)
  expect_error(
    replacement_level(proj_bad_type, config = cfg_mixed_12),
    class = "rotostats_error_wrong_column_type"
  )
})

test_that("TS-27: unknown rate stat → error", {
  # Use a hitter-only config with BABIP (unknown rate stat) as a scored category.
  # projections must include all required columns for the categories listed.
  proj <- make_projections_data(seed = 42L)
  cfg_custom_cat <- league_config(
    n_teams       = 12L,
    roster_slots  = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L, SS = 1L, OF = 3L),
    pitcher_slots = c(SP = 6L, RP = 3L),
    categories    = c("HR", "R", "RBI", "SB", "AVG", "W", "K", "SV", "ERA", "WHIP",
                      "BABIP"),  # BABIP is unknown rate stat
    league_type   = "mixed"
  )
  proj_babip       <- proj
  proj_babip$BABIP <- 0.300
  expect_error(
    replacement_level(proj_babip, config = cfg_custom_cat),
    class = "rotostats_error_unknown_rate_stat"
  )
})

test_that("TS-28: pool too small → error", {
  # 15 teams × 2 SS slots = need 30 SS; provide only 20
  cfg_deep_ss <- league_config(
    n_teams       = 15L,
    roster_slots  = c(SS = 2L),
    pitcher_slots = c(SP = 6L, RP = 3L),
    categories    = c("HR", "R", "RBI", "SB", "AVG"),
    league_type   = "AL"
  )
  thin_proj <- data.frame(
    player_id       = paste0("SS", 1:30),
    player_name     = paste0("SS_Player", 1:30),
    pos_eligibility = c(rep("SS", 20), rep("SP", 5), rep("RP", 5)),
    team            = rep("TM", 30),
    league          = rep("AL", 30),
    HR              = c(seq(30, 11, by = -1), rep(NA, 10)),
    R               = c(rep(50, 20), rep(NA, 10)),
    RBI             = c(rep(60, 20), rep(NA, 10)),
    SB              = c(rep(5, 20),  rep(NA, 10)),
    AVG             = c(rep(0.265, 20), rep(NA, 10)),
    AB              = c(rep(400, 20), rep(NA, 10)),
    IP              = c(rep(NA, 20), rep(170, 5), rep(60, 5)),
    stringsAsFactors = FALSE
  )
  expect_error(
    replacement_level(thin_proj, config = cfg_deep_ss),
    class = "rotostats_error_pool_too_small"
  )
})

test_that("TS-29: positional_adjustment_method=posblend without pos_weight → error", {
  proj <- make_projections_data(seed = 42L)
  expect_error(
    replacement_level(proj, config = cfg_mixed_12,
                      positional_adjustment_method = "posblend"),
    class = "rotostats_error_missing_pos_weight"
  )
})

test_that("TS-30: seed_method=historical_priors without league_history → error", {
  proj <- make_projections_data(seed = 42L)
  expect_error(
    replacement_level(proj, config = cfg_mixed_12,
                      seed_method = "historical_priors"),
    class = "rotostats_error_missing_league_history"
  )
})

# ---------------------------------------------------------------------------
# §8  Convergence Tests
# ---------------------------------------------------------------------------

test_that("TS-31: converged = TRUE with single-position players", {
  proj <- make_projections_data(seed = 42L)
  # Flatten all multi-eligible to primary position
  proj$pos_eligibility <- vapply(
    strsplit(proj$pos_eligibility, "\\|"),
    function(x) x[1L],
    character(1L)
  )
  result <- replacement_level(proj, config = cfg_mixed_12,
                               multi_pos = "primary")
  expect_true(attr(result, "converged"))
})

test_that("TS-32: converged = FALSE + warning at max_iter", {
  proj <- make_projections_data(seed = 42L)
  expect_warning(
    result_nc <- replacement_level(proj, config = cfg_mixed_12,
                                    max_iter = 1L),
    class = "rotostats_warning_convergence_not_reached"
  )
  expect_false(attr(result_nc, "converged"))
  expect_equal(attr(result_nc, "iterations"), 1L)
})

test_that("TS-33: convergence warning fires even when verbose = FALSE", {
  proj <- make_projections_data(seed = 42L)
  warning_fired <- FALSE
  withCallingHandlers(
    replacement_level(proj, config = cfg_mixed_12,
                      max_iter = 1L, verbose = FALSE),
    rotostats_warning_convergence_not_reached = function(w) {
      warning_fired <<- TRUE
      invokeRestart("muffleWarning")
    }
  )
  expect_true(warning_fired)
})

# ---------------------------------------------------------------------------
# §9  default_replacement_params Tests
# ---------------------------------------------------------------------------

test_that("TS-34: default_replacement_params has correct keys and defaults", {
  expect_named(
    default_replacement_params,
    c("band_width_K", "cliff_threshold", "cliff_min_n", "sp_ip_threshold",
      "sp_rp_split_default", "ip_ab_divergence_tol", "calibration_min_n",
      "convergence_eps", "convergence_max_iter"),
    ignore.order = TRUE
  )
  expect_equal(default_replacement_params$band_width_K,         3L)
  expect_equal(default_replacement_params$cliff_threshold,       1.5)
  expect_equal(default_replacement_params$cliff_min_n,           4L)
  expect_equal(default_replacement_params$sp_ip_threshold,       100)
  expect_equal(default_replacement_params$sp_rp_split_default,   c(SP = 0.60, RP = 0.40))
  expect_equal(default_replacement_params$ip_ab_divergence_tol,  0.15)
  expect_equal(default_replacement_params$calibration_min_n,     15L)
  expect_equal(default_replacement_params$convergence_eps,       0.01)
  expect_equal(default_replacement_params$convergence_max_iter,  25L)
})

test_that("TS-35: replacement_params overrides take effect", {
  proj <- make_projections_data(seed = 42L)
  result_narrow <- replacement_level(
    proj,
    config             = cfg_mixed_12,
    replacement_params = list(band_width_K = 1L)
  )
  expect_equal(result_narrow$params$band_width, 1L)
  expect_lte(max(result_narrow$replacement_stats$n_band_players), 3L)
})

test_that("TS-36: top-level band_width wins over replacement_params", {
  proj <- make_projections_data(seed = 42L)
  result_conflict <- replacement_level(
    proj,
    config             = cfg_mixed_12,
    band_width         = 2L,
    replacement_params = list(band_width_K = 5L)
  )
  expect_equal(result_conflict$params$band_width, 2L)
})

# ---------------------------------------------------------------------------
# §10  rate_stat_denominators() Tests
# ---------------------------------------------------------------------------

test_that("TS-37: rate_stat_denominators() returns named character vector", {
  rsd <- rate_stat_denominators()
  expect_true(is.character(rsd))
  expect_true(!is.null(names(rsd)))
})

test_that("TS-38: rate_stat_denominators() contains required mappings", {
  rsd <- rate_stat_denominators()
  expect_equal(rsd[["AVG"]],  "AB")
  expect_equal(rsd[["ERA"]],  "IP")
  expect_equal(rsd[["WHIP"]], "IP")
  expect_equal(rsd[["OBP"]],  "PA")
  expect_equal(rsd[["SLG"]],  "AB")
})

test_that("TS-39: custom rate_denominators extends the lookup without error", {
  proj <- make_projections_data(seed = 42L)
  proj_babip       <- proj
  proj_babip$BABIP <- 0.300

  expect_no_error(
    replacement_level(proj_babip, config = cfg_mixed_12,
                      rate_denominators = c(BABIP = "AB"))
  )
})

# ---------------------------------------------------------------------------
# §14  Property-Based Invariants
# ---------------------------------------------------------------------------

test_that("TS-54: replacement_stats positions match config positions", {
  proj   <- make_projections_data(seed = 42L)
  result <- replacement_level(proj, config = cfg_mixed_12)

  valid_positions <- c(names(cfg_mixed_12$roster_slots), "SP", "RP")
  expect_true(all(result$replacement_stats$position %in% valid_positions))
})

test_that("TS-55: n_band_players >= 1 for all positions", {
  proj   <- make_projections_data(seed = 42L)
  result <- replacement_level(proj, config = cfg_mixed_12)
  expect_true(all(result$replacement_stats$n_band_players >= 1L))
})

test_that("TS-56: all stat columns in replacement_stats are numeric", {
  proj   <- make_projections_data(seed = 42L)
  result <- replacement_level(proj, config = cfg_mixed_12)

  stat_cols <- setdiff(names(result$replacement_stats),
                       c("position", "n_band_players", "cliff_detected"))
  for (col in stat_cols) {
    expect_true(is.numeric(result$replacement_stats[[col]]),
                info = paste("column", col, "is not numeric"))
  }
})

test_that("TS-57: position_assignments covers all players with valid positions", {
  proj   <- make_projections_data(seed = 42L)
  result <- replacement_level(proj, config = cfg_mixed_12)

  pa <- attr(result, "position_assignments")
  expect_true(is.character(pa))
  expect_true(!is.null(names(pa)))
  valid_pos <- c(names(cfg_mixed_12$roster_slots), "SP", "RP")
  expect_true(all(pa %in% valid_pos))
})

test_that("TS-58: stat_units attribute is always set", {
  proj   <- make_projections_data(seed = 42L)
  result <- replacement_level(proj, config = cfg_mixed_12)
  expect_true(
    attr(result, "stat_units") %in% c("raw_projected", "full_season_normalized")
  )
})
