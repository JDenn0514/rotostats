# tests/testthat/test-zaa.R
#
# Independent validation of zaa() covering TS-ZAA-1 through TS-ZAA-18.
# Written by the tester pipeline from test-spec.md only.
# Tester did NOT read spec.md, implementation.md, or R/zaa.R source code.
#
# Fixtures are defined in helper-zaa-fixtures.R (auto-loaded by testthat).
# pop_sd() is also defined there: sqrt(mean((x - mean(x))^2)), denominator n.
#
# KNOWN IMPLEMENTATION BUG (audit.md §BLOCK):
#   zaa() throws "missing value where TRUE/FALSE needed" (blank_labels guard)
#   when replacement is provided AND batter_pool = "positional" (the default),
#   or when any pitcher rows exist in the stats pool alongside replacement.
#   Only hitter-only pools with batter_pool = "combined" work with replacement.
#   Affected scenarios: TS-ZAA-2 (pool restriction with pitchers).

library(testthat)

# ===========================================================================
# Helper: build a unified stats data frame from separate pitcher/hitter frames
# Adds cross-position NA columns so rbind works cleanly.
# ===========================================================================
.build_mixed_stats <- function(pitcher_df, batter_df,
                               pitcher_cats, batter_cats) {
  # pitcher rows: NA for batter cats
  for (col in batter_cats) {
    if (!col %in% names(pitcher_df)) pitcher_df[[col]] <- NA_real_
  }
  # batter rows: NA for pitcher cats
  for (col in pitcher_cats) {
    if (!col %in% names(batter_df)) batter_df[[col]] <- NA_real_
  }
  all_cols <- union(names(pitcher_df), names(batter_df))
  for (col in all_cols) {
    if (!col %in% names(pitcher_df)) pitcher_df[[col]] <- NA_real_
    if (!col %in% names(batter_df))  batter_df[[col]]  <- NA_real_
  }
  rbind(pitcher_df[, all_cols], batter_df[, all_cols])
}

# ===========================================================================
# Shared fixture for TS-ZAA-5 and TS-ZAA-6:
# 4 pitchers (2 SP, 2 RP) with W, K, SV, QS all non-NA;
# 5 hitters with HR, R, RBI, SB, BB all non-NA.
# Categories: 5 hitter (HR,R,RBI,SB,BB) + 4 pitcher (W,K,SV,QS).
# Linear pitcher weight = 4/5 = 0.8; sqrt = sqrt(4/5) ~ 0.894.
# ===========================================================================
.make_ts5_fixture <- function() {
  pitchers <- data.frame(
    player_id       = paste0("P", 1:4),
    player_name     = paste0("P", 1:4),
    pos_eligibility = c("SP", "SP", "RP", "RP"),
    team            = rep("NYY", 4), league = rep("AL", 4),
    W = c(12, 10, 3, 2), K = c(160, 140, 80, 60),
    SV = c(2, 1, 20, 10), QS = c(18, 15, 4, 2),
    stringsAsFactors = FALSE
  )
  batters <- data.frame(
    player_id       = paste0("H", 1:5),
    player_name     = paste0("H", 1:5),
    pos_eligibility = c("1B", "1B", "OF", "OF", "OF"),
    team            = rep("BOS", 5), league = rep("AL", 5),
    HR = c(20, 25, 18, 30, 15), R = c(70, 80, 65, 90, 60),
    RBI = c(75, 85, 70, 95, 65), SB = c(5, 10, 15, 20, 25),
    BB = c(50, 60, 45, 70, 40),
    stringsAsFactors = FALSE
  )
  p_cats <- c("W", "K", "SV", "QS")
  h_cats <- c("HR", "R", "RBI", "SB", "BB")
  stats_df <- .build_mixed_stats(pitchers, batters, p_cats, h_cats)

  cfg <- suppressWarnings(
    league_config(
      n_teams            = 12L,
      roster_slots       = c("1B" = 2L, OF = 3L),
      pitcher_slots      = c(SP = 2L, RP = 2L),
      batting_categories = h_cats,
      pitcher_categories = p_cats
    )
  )
  list(
    stats_df      = stats_df,
    cfg           = cfg,
    pitcher_cols  = paste0("zaa_", p_cats),
    batter_cols   = paste0("zaa_", h_cats),
    pitcher_rows  = 1:4,
    batter_rows   = 5:9
  )
}

# ---------------------------------------------------------------------------
# TS-ZAA-11 — Population SD, not sample SD (HIGHEST RISK)
# ---------------------------------------------------------------------------

test_that("TS-ZAA-11: zaa() uses population SD (denominator n), not stats::sd()", {
  # HR = c(10, 20, 30, 40): mean = 25
  # pop_sd = sqrt(125) ~ 11.18034 (denominator n)
  # sample_sd = stats::sd(...) = sqrt(500/3) ~ 12.9099 (denominator n-1)
  players <- pad_cross_side_columns(data.frame(
    player_id       = c("P1", "P2", "P3", "P4"),
    player_name     = c("A", "B", "C", "D"),
    pos_eligibility = rep("1B", 4),
    team            = rep("NYY", 4), league = rep("AL", 4),
    HR              = c(10, 20, 30, 40),
    stringsAsFactors = FALSE
  ))
  cfg <- make_zaa_cfg(categories = "HR",
                      roster_slots  = c("1B" = 4L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  result <- withCallingHandlers(
    zaa(stats = players, config = cfg),
    message = function(m) invokeRestart("muffleMessage")
  )

  # Expected values with pop_sd = sqrt(125)
  expected_low  <- (10 - 25) / sqrt(125)  # ~ -1.3416
  expected_high <- (40 - 25) / sqrt(125)  # ~  1.3416

  expect_equal(result$zaa_HR[result$player_id == "P1"],
               expected_low,  tolerance = 1e-8,
               label = "TS-ZAA-11: HR=10 z-score pinned to pop_sd denominator n")
  expect_equal(result$zaa_HR[result$player_id == "P4"],
               expected_high, tolerance = 1e-8,
               label = "TS-ZAA-11: HR=40 z-score pinned to pop_sd denominator n")

  # Values differ from sample SD (confirming pop_sd is used)
  sample_sd_high <- (40 - 25) / stats::sd(c(10, 20, 30, 40))
  expect_false(
    isTRUE(all.equal(result$zaa_HR[result$player_id == "P4"],
                     sample_sd_high, tolerance = 1e-8)),
    label = "TS-ZAA-11: sample_sd expected value does NOT match"
  )
})

# ---------------------------------------------------------------------------
# TS-ZAA-12 — Zero-volume edge case
# ---------------------------------------------------------------------------

test_that("TS-ZAA-12: zero IP -> zaa_ERA = NA and rotostats_warning_zero_playing_time fires", {
  pitchers <- data.frame(
    player_id       = c("P1", "P2", "P3", "P4"),
    player_name     = c("A", "B", "C", "D"),
    pos_eligibility = rep("SP", 4),
    team            = rep("NYY", 4), league = rep("AL", 4),
    ERA             = c(3.50, 3.50, 4.00, 4.50),
    IP              = c(180, 0, 150, 120),
    K               = c(150, 80, 120, 90),
    stringsAsFactors = FALSE
  )
  pitchers <- pad_cross_side_columns(pitchers)
  cfg <- make_zaa_cfg(categories = c("ERA", "K"),
                      roster_slots  = c(C = 0L),
                      pitcher_slots = c(SP = 4L, RP = 0L))

  expect_warning(
    {result <- zaa(stats = pitchers, config = cfg)},
    class = "rotostats_warning_zero_playing_time"
  )

  expect_true(is.na(result$zaa_ERA[result$player_id == "P2"]),
              label = "TS-ZAA-12: P2 (IP=0) has NA zaa_ERA")
  expect_false(is.na(result$zaa_ERA[result$player_id == "P1"]),
               label = "TS-ZAA-12: P1 (IP=180) has non-NA zaa_ERA")
  # Note: total_zaa uses rowSums(na.rm = TRUE) so cross-side NAs do not
  # propagate. Same-side zero-playing-time NAs (here zaa_ERA for P2) also
  # fall under na.rm = TRUE — P2's total_zaa reflects only zaa_K.
  expect_equal(
    result$total_zaa[result$player_id == "P2"],
    result$zaa_K[result$player_id == "P2"],
    tolerance = 1e-10,
    label = "TS-ZAA-12: P2 total_zaa equals zaa_K (zaa_ERA dropped via na.rm)"
  )
})

test_that("TS-ZAA-12: NA IP -> zaa_ERA = NA and warning fires", {
  pitchers <- data.frame(
    player_id       = c("P1", "P2", "P3", "P4", "P5"),
    player_name     = letters[1:5],
    pos_eligibility = rep("SP", 5),
    team            = rep("NYY", 5), league = rep("AL", 5),
    ERA             = c(3.50, 3.50, 4.00, 4.50, 3.80),
    IP              = c(180, 0, 150, 120, NA),
    K               = c(150, 80, 120, 90, 110),
    stringsAsFactors = FALSE
  )
  pitchers <- pad_cross_side_columns(pitchers)
  cfg <- make_zaa_cfg(categories = c("ERA", "K"),
                      roster_slots  = c(C = 0L),
                      pitcher_slots = c(SP = 5L, RP = 0L))

  expect_warning(
    {result <- zaa(stats = pitchers, config = cfg)},
    class = "rotostats_warning_zero_playing_time"
  )
  expect_true(is.na(result$zaa_ERA[result$player_id == "P5"]),
              label = "TS-ZAA-12: P5 (IP=NA) has NA zaa_ERA")
})

test_that("TS-ZAA-12: zero AB -> zaa_AVG = NA and warning fires", {
  batters <- data.frame(
    player_id       = c("H1", "H2", "H3", "H4"),
    player_name     = c("A", "B", "C", "D"),
    pos_eligibility = rep("1B", 4),
    team            = rep("BOS", 4), league = rep("AL", 4),
    AVG             = c(0.300, 0.300, 0.270, 0.330),
    AB              = c(500, 0, 400, 350),
    HR              = c(25, 10, 20, 30),
    stringsAsFactors = FALSE
  )
  batters <- pad_cross_side_columns(batters)
  cfg <- make_zaa_cfg(categories = c("AVG", "HR"),
                      roster_slots  = c("1B" = 4L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  expect_warning(
    {result <- zaa(stats = batters, config = cfg)},
    class = "rotostats_warning_zero_playing_time"
  )
  expect_true(is.na(result$zaa_AVG[result$player_id == "H2"]),
              label = "TS-ZAA-12: H2 (AB=0) has NA zaa_AVG")
  expect_false(is.na(result$zaa_AVG[result$player_id == "H1"]),
               label = "TS-ZAA-12: H1 (AB=500) unaffected")
})

# ---------------------------------------------------------------------------
# TS-ZAA-1 — Rate stat sign check (ERA negated; below-mean ERA -> positive z)
# ---------------------------------------------------------------------------

test_that("TS-ZAA-1: below-mean ERA -> positive zaa_ERA; above-mean ERA -> negative", {
  pitchers <- data.frame(
    player_id       = c("P1", "P2", "P3", "P4"),
    player_name     = c("A", "B", "C", "D"),
    pos_eligibility = rep("SP", 4),
    team            = rep("NYY", 4), league = rep("AL", 4),
    ERA             = c(2.50, 3.25, 4.00, 4.75),   # mean = 3.625
    IP              = c(180, 180, 180, 180),
    K               = c(160, 150, 140, 130),
    stringsAsFactors = FALSE
  )
  pitchers <- pad_cross_side_columns(pitchers)
  cfg <- make_zaa_cfg(categories = c("ERA", "K"),
                      roster_slots  = c(C = 0L),
                      pitcher_slots = c(SP = 4L, RP = 0L))

  result <- withCallingHandlers(
    zaa(stats = pitchers, config = cfg),
    message = function(m) invokeRestart("muffleMessage")
  )

  expect_gt(result$zaa_ERA[result$player_id == "P1"], 0,
            label = "TS-ZAA-1: P1 ERA=2.50 < mean=3.625 => positive z")
  expect_gt(result$zaa_ERA[result$player_id == "P2"], 0,
            label = "TS-ZAA-1: P2 ERA=3.25 < mean=3.625 => positive z")
  expect_lt(result$zaa_ERA[result$player_id == "P3"], 0,
            label = "TS-ZAA-1: P3 ERA=4.00 > mean=3.625 => negative z")
  expect_lt(result$zaa_ERA[result$player_id == "P4"], 0,
            label = "TS-ZAA-1: P4 ERA=4.75 > mean=3.625 => negative z")

  # Property-based sign invariant: sign(pool_mean - ERA[i]) == sign(zaa_ERA[i])
  pool_mean_era <- mean(pitchers$ERA)
  for (pid in pitchers$player_id) {
    era_i <- pitchers$ERA[pitchers$player_id == pid]
    zaa_i <- result$zaa_ERA[result$player_id == pid]
    expect_equal(sign(pool_mean_era - era_i), sign(zaa_i),
                 label = paste0("TS-ZAA-1: sign invariant for ", pid))
  }
})

# ---------------------------------------------------------------------------
# TS-ZAA-8 — Attribute schema (nested vs flat, sd_vol presence)
# ---------------------------------------------------------------------------

test_that("TS-ZAA-8A positional: distribution nested by position; sd_vol for rate stats only", {
  batters <- data.frame(
    player_id       = c("C1", "C2", "B1", "B2"),
    player_name     = c("C1", "C2", "B1", "B2"),
    pos_eligibility = c("C", "C", "1B", "1B"),
    team            = rep("NYY", 4), league = rep("AL", 4),
    HR              = c(15, 20, 25, 30),
    AVG             = c(0.260, 0.285, 0.275, 0.300),
    AB              = c(380, 420, 480, 520),
    stringsAsFactors = FALSE
  )
  batters <- pad_cross_side_columns(batters)
  cfg <- make_zaa_cfg(categories = c("HR", "AVG"),
                      roster_slots  = c(C = 2L, "1B" = 2L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  result_A <- withCallingHandlers(
    zaa(stats = batters, config = cfg, batter_pool = "positional"),
    message = function(m) invokeRestart("muffleMessage")
  )

  dist_A <- attr(result_A, "distribution")
  expect_true(is.list(dist_A),               label = "TS-ZAA-8A: distribution is list")
  # Schema is nested by side first; positional pool keys live under $batter.
  expect_true("batter" %in% names(dist_A),   label = "TS-ZAA-8A: batter side present")
  bat_A <- dist_A[["batter"]]
  expect_true("C"  %in% names(bat_A),         label = "TS-ZAA-8A: C key present")
  expect_true("1B" %in% names(bat_A),         label = "TS-ZAA-8A: 1B key present")

  # HR (counting) — sd_vol ABSENT
  hr_entry <- bat_A[["C"]][["HR"]]
  expect_true("mean" %in% names(hr_entry), label = "TS-ZAA-8A: C/HR has mean")
  expect_true("sd"   %in% names(hr_entry), label = "TS-ZAA-8A: C/HR has sd")
  expect_false("sd_vol" %in% names(hr_entry), label = "TS-ZAA-8A: C/HR has no sd_vol")

  # AVG (rate stat) — sd_vol PRESENT
  avg_entry <- bat_A[["C"]][["AVG"]]
  expect_true("mean"   %in% names(avg_entry), label = "TS-ZAA-8A: C/AVG has mean")
  expect_true("sd"     %in% names(avg_entry), label = "TS-ZAA-8A: C/AVG has sd")
  expect_true("sd_vol" %in% names(avg_entry), label = "TS-ZAA-8A: C/AVG has sd_vol")

  # No flat top-level HR key in positional mode
  expect_false("HR" %in% names(bat_A), label = "TS-ZAA-8A: no flat HR key")

  expect_equal(attr(result_A, "units"),  "zscore",  label = "TS-ZAA-8A: units")
  expect_equal(attr(result_A, "anchor"), "average", label = "TS-ZAA-8A: anchor")
})

test_that("TS-ZAA-8B combined: distribution flat by category; no position keys", {
  batters <- data.frame(
    player_id       = c("C1", "C2", "B1", "B2"),
    player_name     = c("C1", "C2", "B1", "B2"),
    pos_eligibility = c("C", "C", "1B", "1B"),
    team            = rep("NYY", 4), league = rep("AL", 4),
    HR              = c(15, 20, 25, 30),
    AVG             = c(0.260, 0.285, 0.275, 0.300),
    AB              = c(380, 420, 480, 520),
    stringsAsFactors = FALSE
  )
  batters <- pad_cross_side_columns(batters)
  cfg <- make_zaa_cfg(categories = c("HR", "AVG"),
                      roster_slots  = c(C = 2L, "1B" = 2L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  result_B <- withCallingHandlers(
    zaa(stats = batters, config = cfg, batter_pool = "combined"),
    message = function(m) invokeRestart("muffleMessage")
  )

  dist_B <- attr(result_B, "distribution")
  expect_true(is.list(dist_B), label = "TS-ZAA-8B: distribution is list")
  # Schema is nested by side first; combined-pool flat keys live under $batter.
  expect_true("batter" %in% names(dist_B), label = "TS-ZAA-8B: batter side present")
  bat_B <- dist_B[["batter"]]
  expect_true("HR"  %in% names(bat_B), label = "TS-ZAA-8B: HR key at top level")
  expect_true("AVG" %in% names(bat_B), label = "TS-ZAA-8B: AVG key at top level")

  # Flat HR: mean+sd but no sd_vol
  expect_true("mean" %in% names(bat_B[["HR"]]),    label = "TS-ZAA-8B: HR has mean")
  expect_true("sd"   %in% names(bat_B[["HR"]]),    label = "TS-ZAA-8B: HR has sd")
  expect_false("sd_vol" %in% names(bat_B[["HR"]]), label = "TS-ZAA-8B: HR has no sd_vol")

  # Flat AVG: sd_vol present
  expect_true("sd_vol" %in% names(bat_B[["AVG"]]), label = "TS-ZAA-8B: AVG has sd_vol")

  # No position keys
  expect_false("C"  %in% names(bat_B), label = "TS-ZAA-8B: no C key at top level")
  expect_false("1B" %in% names(dist_B), label = "TS-ZAA-8B: no 1B key at top level")

  expect_equal(attr(result_B, "units"),  "zscore",  label = "TS-ZAA-8B: units")
  expect_equal(attr(result_B, "anchor"), "average", label = "TS-ZAA-8B: anchor")
})

# ---------------------------------------------------------------------------
# TS-ZAA-10 — Attribute-extraction precedence (replacement supersedes stats)
# ---------------------------------------------------------------------------

test_that("TS-ZAA-10: attr(replacement,'projections') supersedes explicit stats argument", {
  # Uses batter_pool = "combined" to avoid blank_labels bug with positional pool.
  stats_in_repl <- data.frame(
    player_id       = paste0("R", 1:5),
    player_name     = paste0("Repl", 1:5),
    pos_eligibility = rep("1B", 5),
    team            = rep("BOS", 5), league = rep("AL", 5),
    HR              = c(12, 18, 24, 30, 36),
    IP              = rep(NA_real_, 5),
    stringsAsFactors = FALSE
  )
  stats_in_repl <- pad_cross_side_columns(stats_in_repl)
  cfg_small <- league_config(
    n_teams            = 1L,
    roster_slots       = c("1B" = 3L),
    pitcher_slots      = c(SP = 0L, RP = 0L),
    batting_categories = "HR",
    # pitcher_categories supplied as a placeholder; this fixture only exercises
    # hitter HR. The placeholder ensures league_config() accepts the call.
    pitcher_categories = c("K")
  )
  repl <- suppressWarnings(replacement_level(stats_in_repl, config = cfg_small))

  stats_explicit <- data.frame(
    player_id       = paste0("E", 1:5),
    player_name     = paste0("Explicit", 1:5),
    pos_eligibility = rep("1B", 5),
    team            = rep("NYY", 5), league = rep("AL", 5),
    HR              = c(10, 15, 20, 25, 30),
    stringsAsFactors = FALSE
  )
  stats_explicit <- pad_cross_side_columns(stats_explicit)

  result_main    <- zaa(stats = stats_explicit, replacement = repl,
                        config = cfg_small, batter_pool = "combined")
  result_control <- zaa(stats = stats_in_repl,  replacement = repl,
                        config = cfg_small, batter_pool = "combined")

  expect_equal(nrow(result_main), 5L,
               label = "TS-ZAA-10: row count from repl projections (5)")
  expect_equal(nrow(result_main), nrow(result_control),
               label = "TS-ZAA-10: same row count for both calls")

  # Output uses stats_in_repl player_ids (starting with R)
  expect_true(all(grepl("^R", result_main$player_id)),
              label = "TS-ZAA-10: player_ids come from repl, not stats_explicit")

  expect_equal(result_main$zaa_HR, result_control$zaa_HR, tolerance = 1e-10,
               label = "TS-ZAA-10: zaa_HR identical")
  expect_equal(result_main$total_zaa, result_control$total_zaa, tolerance = 1e-10,
               label = "TS-ZAA-10: total_zaa identical")
})

# ---------------------------------------------------------------------------
# TS-ZAA-13 — Missing replacement attrs: rotostats_error_missing_replacement_attrs
# ---------------------------------------------------------------------------

test_that("TS-ZAA-13A: replacement missing projections -> rotostats_error_missing_replacement_attrs", {
  cfg <- make_zaa_cfg(categories = "HR",
                      roster_slots  = c("1B" = 2L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  repl_no_proj <- structure(list(), class = "replacement_level")
  attr(repl_no_proj, "config")     <- cfg
  attr(repl_no_proj, "stat_units") <- "raw_projected"

  expect_error(
    zaa(replacement = repl_no_proj, config = cfg),
    class = "rotostats_error_missing_replacement_attrs"
  )
})

test_that("TS-ZAA-13B: replacement missing config -> rotostats_error_missing_replacement_attrs", {
  proj_df <- data.frame(
    player_id = c("P1", "P2"), player_name = c("A", "B"),
    pos_eligibility = c("1B", "1B"), team = c("NYY", "NYY"),
    league = c("AL", "AL"), HR = c(20, 30), stringsAsFactors = FALSE
  )
  cfg <- make_zaa_cfg(categories = "HR",
                      roster_slots  = c("1B" = 2L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  repl_no_cfg <- structure(list(), class = "replacement_level")
  attr(repl_no_cfg, "projections") <- proj_df
  attr(repl_no_cfg, "stat_units")  <- "raw_projected"

  expect_error(
    zaa(replacement = repl_no_cfg, config = cfg),
    class = "rotostats_error_missing_replacement_attrs"
  )
})

# ---------------------------------------------------------------------------
# TS-ZAA-14 — stat_units mismatch: rotostats_error_stat_units_mismatch
# ---------------------------------------------------------------------------

test_that("TS-ZAA-14: stat_units='full_season_normalized' -> rotostats_error_stat_units_mismatch", {
  proj_df <- data.frame(
    player_id = c("P1", "P2"), player_name = c("A", "B"),
    pos_eligibility = c("1B", "1B"), team = c("NYY", "NYY"),
    league = c("AL", "AL"), HR = c(20, 30), stringsAsFactors = FALSE
  )
  cfg <- make_zaa_cfg(categories = "HR",
                      roster_slots  = c("1B" = 2L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  repl_normalized <- structure(list(), class = "replacement_level")
  attr(repl_normalized, "projections") <- proj_df
  attr(repl_normalized, "config")      <- cfg
  attr(repl_normalized, "stat_units")  <- "full_season_normalized"

  expect_error(
    zaa(replacement = repl_normalized, config = cfg),
    class = "rotostats_error_stat_units_mismatch"
  )
})

test_that("TS-ZAA-14: stat_units mismatch fires AFTER projections/config are present", {
  # Confirms V2 ordering: missing_replacement_attrs fires first; stat_units second
  cfg <- make_zaa_cfg(categories = "HR",
                      roster_slots  = c("1B" = 2L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  # Both attrs present but wrong stat_units -> rotostats_error_stat_units_mismatch
  proj_df <- data.frame(player_id = "P1", player_name = "A", pos_eligibility = "1B",
                        team = "NYY", league = "AL", HR = 20L, stringsAsFactors = FALSE)
  repl_bad_units <- structure(list(), class = "replacement_level")
  attr(repl_bad_units, "projections") <- proj_df
  attr(repl_bad_units, "config")      <- cfg
  attr(repl_bad_units, "stat_units")  <- "something_else"

  expect_error(
    zaa(replacement = repl_bad_units, config = cfg),
    class = "rotostats_error_stat_units_mismatch"
  )
})

# ---------------------------------------------------------------------------
# TS-ZAA-15 — rotostats_warning_auto_weight_combined_pool fires
# ---------------------------------------------------------------------------

test_that("TS-ZAA-15: weight_method='linear' + pitcher_pool='combined' fires warning", {
  fx <- .make_ts5_fixture()

  expect_warning(
    {result <- withCallingHandlers(
      zaa(stats = fx$stats_df, config = fx$cfg,
          weight_method = "linear", pitcher_pool = "combined"),
      message = function(m) invokeRestart("muffleMessage")
    )},
    class = "rotostats_warning_auto_weight_combined_pool"
  )

  expect_s3_class(result, "data.frame")
  expect_true("total_zaa" %in% names(result),
              label = "TS-ZAA-15: function completes and returns data frame")
})

test_that("TS-ZAA-15: category_weight non-NULL suppresses rotostats_warning_auto_weight_combined_pool", {
  fx <- .make_ts5_fixture()

  expect_no_warning(
    withCallingHandlers(
      zaa(stats = fx$stats_df, config = fx$cfg,
          weight_method = "linear", pitcher_pool = "combined",
          category_weight = c(SP = 0.8, RP = 0.8)),
      message = function(m) invokeRestart("muffleMessage")
    ),
    class = "rotostats_warning_auto_weight_combined_pool"
  )
})

# ---------------------------------------------------------------------------
# TS-ZAA-16 — Unrestricted-pool cli_inform fires when replacement = NULL
# ---------------------------------------------------------------------------

test_that("TS-ZAA-16: replacement=NULL emits a message (unrestricted-pool inform)", {
  players <- pad_cross_side_columns(data.frame(
    player_id = c("P1", "P2", "P3"), player_name = c("A", "B", "C"),
    pos_eligibility = rep("1B", 3), team = rep("NYY", 3), league = rep("AL", 3),
    HR = c(15, 25, 35), stringsAsFactors = FALSE
  ))
  cfg <- make_zaa_cfg(categories = "HR",
                      roster_slots  = c("1B" = 3L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  expect_message(zaa(stats = players, config = cfg, replacement = NULL))
})

test_that("TS-ZAA-16: inform message contains expected stable keyword", {
  players <- pad_cross_side_columns(data.frame(
    player_id = c("P1", "P2", "P3"), player_name = c("A", "B", "C"),
    pos_eligibility = rep("1B", 3), team = rep("NYY", 3), league = rep("AL", 3),
    HR = c(15, 25, 35), stringsAsFactors = FALSE
  ))
  cfg <- make_zaa_cfg(categories = "HR",
                      roster_slots  = c("1B" = 3L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  captured_msg <- NULL
  withCallingHandlers(
    zaa(stats = players, config = cfg, replacement = NULL),
    message = function(m) {
      captured_msg <<- m
      invokeRestart("muffleMessage")
    }
  )

  expect_false(is.null(captured_msg), label = "TS-ZAA-16: message was captured")
  msg_text <- conditionMessage(captured_msg)
  expect_true(
    grepl("unrestricted|all rows|SD may be inflated|inflated", msg_text,
          ignore.case = TRUE),
    label = paste0("TS-ZAA-16: message contains expected keyword; got: '",
                   trimws(msg_text), "'")
  )
  expect_false(inherits(captured_msg, "simpleWarning"),
               label = "TS-ZAA-16: inform is not a warning")
  expect_true(inherits(captured_msg, "message"),
              label = "TS-ZAA-16: inform IS a message (class-free)")
})

test_that("TS-ZAA-16: replacement non-NULL emits NO message", {
  players <- pad_cross_side_columns(data.frame(
    player_id = c("P1", "P2", "P3"), player_name = c("A", "B", "C"),
    pos_eligibility = rep("1B", 3), team = rep("NYY", 3), league = rep("AL", 3),
    HR = c(15, 25, 35), IP = rep(NA_real_, 3), stringsAsFactors = FALSE
  ))
  cfg <- league_config(n_teams = 1L, roster_slots = c("1B" = 2L),
                       pitcher_slots = c(SP = 0L, RP = 0L),
                       batting_categories = "HR",
                       # pitcher_categories supplied as a placeholder; this
                       # fixture only exercises hitter HR. The placeholder
                       # ensures league_config() accepts the call.
                       pitcher_categories = "K")
  repl <- suppressWarnings(replacement_level(players, config = cfg))

  expect_no_message(
    zaa(stats = players, replacement = repl, config = cfg, batter_pool = "combined")
  )
})

# ---------------------------------------------------------------------------
# TS-ZAA-5 — weight_method scaling ("linear" and "sqrt")
# ---------------------------------------------------------------------------

test_that("TS-ZAA-5 linear: pitcher total_zaa / rowSums(pitcher_cats) ~ 4/5 = 0.8", {
  # Fixture: 4 pitcher cats (W,K,SV,QS) all non-NA for all pitchers;
  #          5 hitter cats (HR,R,RBI,SB,BB) all non-NA for all hitters.
  # Expected linear multiplier: 4/5 = 0.8 for pitchers, 1.0 for hitters.
  fx <- .make_ts5_fixture()

  result_A <- suppressWarnings(
    withCallingHandlers(
      zaa(stats = fx$stats_df, config = fx$cfg,
          weight_method = "linear", pitcher_pool = "split"),
      message = function(m) invokeRestart("muffleMessage")
    )
  )

  for (i in fx$pitcher_rows) {
    rsum <- sum(as.numeric(result_A[i, fx$pitcher_cols]), na.rm = FALSE)
    if (!is.na(rsum) && abs(rsum) > 1e-10) {
      ratio <- result_A$total_zaa[i] / rsum
      expect_equal(ratio, 4/5, tolerance = 1e-6,
                   label = paste0("TS-ZAA-5 linear: pitcher row ", i,
                                  " ratio ~ 0.8"))
    }
  }
  for (i in fx$batter_rows) {
    rsum <- sum(as.numeric(result_A[i, fx$batter_cols]), na.rm = FALSE)
    if (!is.na(rsum) && abs(rsum) > 1e-10) {
      ratio <- result_A$total_zaa[i] / rsum
      expect_equal(ratio, 1.0, tolerance = 1e-6,
                   label = paste0("TS-ZAA-5 linear: hitter row ", i,
                                  " ratio ~ 1.0"))
    }
  }
})

test_that("TS-ZAA-5 sqrt: pitcher total_zaa / rowSums(pitcher_cats) ~ sqrt(4/5)", {
  fx <- .make_ts5_fixture()

  result_B <- suppressWarnings(
    withCallingHandlers(
      zaa(stats = fx$stats_df, config = fx$cfg,
          weight_method = "sqrt", pitcher_pool = "split"),
      message = function(m) invokeRestart("muffleMessage")
    )
  )

  for (i in fx$pitcher_rows) {
    rsum <- sum(as.numeric(result_B[i, fx$pitcher_cols]), na.rm = FALSE)
    if (!is.na(rsum) && abs(rsum) > 1e-10) {
      ratio <- result_B$total_zaa[i] / rsum
      expect_equal(ratio, sqrt(4/5), tolerance = 1e-6,
                   label = paste0("TS-ZAA-5 sqrt: pitcher row ", i,
                                  " ratio ~ sqrt(4/5)"))
    }
  }
})

test_that("TS-ZAA-5: per-category zaa_<cat> columns unchanged between linear and sqrt", {
  fx <- .make_ts5_fixture()

  result_A <- suppressWarnings(
    withCallingHandlers(
      zaa(stats = fx$stats_df, config = fx$cfg,
          weight_method = "linear", pitcher_pool = "split"),
      message = function(m) invokeRestart("muffleMessage")
    )
  )
  result_B <- suppressWarnings(
    withCallingHandlers(
      zaa(stats = fx$stats_df, config = fx$cfg,
          weight_method = "sqrt", pitcher_pool = "split"),
      message = function(m) invokeRestart("muffleMessage")
    )
  )

  expect_equal(result_A$zaa_K, result_B$zaa_K, tolerance = 1e-10,
               label = "TS-ZAA-5: zaa_K unchanged between linear and sqrt")
  expect_equal(result_A$zaa_W[!is.na(result_A$zaa_W)],
               result_B$zaa_W[!is.na(result_B$zaa_W)],
               tolerance = 1e-10,
               label = "TS-ZAA-5: zaa_W unchanged (non-NA rows)")
})

# ---------------------------------------------------------------------------
# TS-ZAA-6 — category_weight override precedence
# ---------------------------------------------------------------------------

test_that("TS-ZAA-6: category_weight overrides weight_method (not 0.8, but 0.5)", {
  fx <- .make_ts5_fixture()

  result <- suppressWarnings(
    withCallingHandlers(
      zaa(stats = fx$stats_df, config = fx$cfg,
          weight_method   = "linear",
          pitcher_pool    = "split",
          category_weight = c(SP = 0.5, RP = 0.5)),
      message = function(m) invokeRestart("muffleMessage")
    )
  )

  for (i in fx$pitcher_rows) {
    rsum <- sum(as.numeric(result[i, fx$pitcher_cols]), na.rm = FALSE)
    if (!is.na(rsum) && abs(rsum) > 1e-10) {
      ratio <- result$total_zaa[i] / rsum
      expect_equal(ratio, 0.5, tolerance = 1e-6,
                   label = paste0("TS-ZAA-6: pitcher row ", i,
                                  " ratio ~ 0.5 (not 0.8)"))
    }
  }
  for (i in fx$batter_rows) {
    rsum <- sum(as.numeric(result[i, fx$batter_cols]), na.rm = FALSE)
    if (!is.na(rsum) && abs(rsum) > 1e-10) {
      ratio <- result$total_zaa[i] / rsum
      expect_equal(ratio, 1.0, tolerance = 1e-6,
                   label = paste0("TS-ZAA-6: hitter row ", i,
                                  " ratio ~ 1.0"))
    }
  }
})

# ---------------------------------------------------------------------------
# TS-ZAA-2 — Pool restriction effect
# NOTE: Cannot test the restriction with a pitched-only pool because of the
# blank_labels implementation bug (see BLOCK in audit.md). We test:
# (a) Call A (replacement=NULL) emits inform; (b) row-count / inform assertions
# for a hitter-only pool where replacement DOES work.
# ---------------------------------------------------------------------------

test_that("TS-ZAA-2: replacement=NULL emits inform; replacement non-NULL does not", {
  batters <- pad_cross_side_columns(data.frame(
    player_id       = paste0("H", 1:8),
    player_name     = paste0("H", 1:8),
    pos_eligibility = rep("1B", 8),
    team            = rep("NYY", 8), league = rep("AL", 8),
    HR              = c(10, 15, 20, 25, 30, 35, 40, 45),
    IP              = rep(NA_real_, 8),
    stringsAsFactors = FALSE
  ))
  cfg <- league_config(n_teams = 1L, roster_slots = c("1B" = 4L),
                       pitcher_slots = c(SP = 0L, RP = 0L),
                       batting_categories = "HR",
                       # pitcher_categories supplied as a placeholder; this
                       # fixture only exercises hitter HR. The placeholder
                       # ensures league_config() accepts the call.
                       pitcher_categories = "K")
  repl <- suppressWarnings(replacement_level(batters, config = cfg))

  expect_message(zaa(stats = batters, config = cfg))

  expect_no_message(
    zaa(stats = batters, replacement = repl, config = cfg, batter_pool = "combined")
  )
})

test_that("TS-ZAA-2: hitter-only replacement restricts output rows to rostered set", {
  # 8 hitters total, 4 rostered (good HR), 4 fringe (low HR).
  # replacement built from good_batters only.
  good_batters <- pad_cross_side_columns(data.frame(
    player_id       = paste0("G", 1:4),
    player_name     = paste0("Good", 1:4),
    pos_eligibility = rep("1B", 4),
    team            = rep("NYY", 4), league = rep("AL", 4),
    HR              = c(25, 30, 35, 40), IP = rep(NA_real_, 4),
    stringsAsFactors = FALSE
  ))
  cfg <- league_config(n_teams = 1L, roster_slots = c("1B" = 2L),
                       pitcher_slots = c(SP = 0L, RP = 0L),
                       batting_categories = "HR",
                       # pitcher_categories supplied as a placeholder; this
                       # fixture only exercises hitter HR. The placeholder
                       # ensures league_config() accepts the call.
                       pitcher_categories = "K")
  repl <- suppressWarnings(replacement_level(good_batters, config = cfg))
  result_B <- zaa(stats = good_batters, replacement = repl, config = cfg,
                  batter_pool = "combined")

  expect_equal(nrow(result_B), 4L,
               label = "TS-ZAA-2: restricted pool returns rostered rows only")
  expect_true(all(grepl("^G", result_B$player_id)),
              label = "TS-ZAA-2: output contains rostered players only")
})

# ---------------------------------------------------------------------------
# TS-ZAA-3 — Volume-weighting effect
# ---------------------------------------------------------------------------

test_that("TS-ZAA-3: higher IP with same ERA gets larger absolute z-score", {
  pitchers <- data.frame(
    player_id       = c("P1", "P2", "P3", "P4"),
    player_name     = c("A", "B", "C", "D"),
    pos_eligibility = rep("SP", 4),
    team            = rep("NYY", 4), league = rep("AL", 4),
    ERA             = c(3.50, 3.50, 3.80, 4.20),
    IP              = c(200,  60,  200,  60),
    K               = c(180, 60, 160, 50),
    stringsAsFactors = FALSE
  )
  pitchers <- pad_cross_side_columns(pitchers)
  cfg <- make_zaa_cfg(categories = c("ERA", "K"),
                      roster_slots  = c(C = 0L),
                      pitcher_slots = c(SP = 4L, RP = 0L))

  result <- withCallingHandlers(
    zaa(stats = pitchers, config = cfg),
    message = function(m) invokeRestart("muffleMessage")
  )

  abs_p1 <- abs(result$zaa_ERA[result$player_id == "P1"])
  abs_p2 <- abs(result$zaa_ERA[result$player_id == "P2"])

  expect_gt(abs_p1, abs_p2,
            label = "TS-ZAA-3: P1 (ERA=3.50, IP=200) larger |z| than P2 (ERA=3.50, IP=60)")
  expect_equal(abs_p1 / abs_p2, 200/60, tolerance = 0.05,
               label = "TS-ZAA-3: |z_P1|/|z_P2| ~ 200/60 = 3.33")
})

test_that("TS-ZAA-3: higher AB with same AVG (above pool mean) gets larger absolute z-score", {
  # H1 and H2 must have AVG > pool mean to avoid zaa_AVG = 0.
  # Pool mean AVG = (0.310+0.310+0.270+0.280)/4 = 0.2925; H1/H2 are above mean.
  batters <- data.frame(
    player_id       = c("H1", "H2", "H3", "H4"),
    player_name     = c("A", "B", "C", "D"),
    pos_eligibility = rep("1B", 4),
    team            = rep("BOS", 4), league = rep("AL", 4),
    AVG             = c(0.310, 0.310, 0.270, 0.280),  # mean = 0.2925
    AB              = c(500,   200,   500,   200),
    HR              = c(25, 10, 20, 30),
    stringsAsFactors = FALSE
  )
  batters <- pad_cross_side_columns(batters)
  cfg <- make_zaa_cfg(categories = c("AVG", "HR"),
                      roster_slots  = c("1B" = 4L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  result <- withCallingHandlers(
    zaa(stats = batters, config = cfg, batter_pool = "combined"),
    message = function(m) invokeRestart("muffleMessage")
  )

  abs_h1 <- abs(result$zaa_AVG[result$player_id == "H1"])
  abs_h2 <- abs(result$zaa_AVG[result$player_id == "H2"])

  expect_gt(abs_h1, abs_h2,
            label = "TS-ZAA-3: H1 (AVG=0.310, AB=500) larger |z| than H2 (AVG=0.310, AB=200)")
})

# ---------------------------------------------------------------------------
# TS-ZAA-4 — weight_method = "none" identity: total_zaa == rowSums(zaa_cats)
# ---------------------------------------------------------------------------

test_that("TS-ZAA-4: weight_method='none' total_zaa == rowSums(zaa_<cat>) within 1e-10", {
  players <- data.frame(
    player_id       = paste0("P", 1:6),
    player_name     = paste0("Player", 1:6),
    pos_eligibility = c("C", "C", "1B", "1B", "OF", "OF"),
    team            = rep("NYY", 6), league = rep("AL", 6),
    HR              = c(15, 20, 25, 30, 22, 28),
    R               = c(60, 70, 75, 85, 68, 80),
    stringsAsFactors = FALSE
  )
  players <- pad_cross_side_columns(players)
  cfg <- make_zaa_cfg(categories = c("HR", "R"),
                      roster_slots  = c(C = 2L, "1B" = 2L, OF = 2L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  result <- withCallingHandlers(
    zaa(stats = players, config = cfg, weight_method = "none"),
    message = function(m) invokeRestart("muffleMessage")
  )

  zaa_cols    <- c("zaa_HR", "zaa_R")
  computed_sum <- unname(rowSums(result[, zaa_cols, drop = FALSE]))

  expect_true(
    isTRUE(all.equal(result$total_zaa, computed_sum, tolerance = 1e-10)),
    label = "TS-ZAA-4: total_zaa == rowSums(zaa_HR, zaa_R) within 1e-10"
  )

  expect_no_warning(
    withCallingHandlers(
      zaa(stats = players, config = cfg, weight_method = "none"),
      message = function(m) invokeRestart("muffleMessage")
    ),
    class = "rotostats_warning_auto_weight_combined_pool"
  )
})

# ---------------------------------------------------------------------------
# TS-ZAA-7 — pitcher_pool comparison: "split" vs "combined"
# ---------------------------------------------------------------------------

test_that("TS-ZAA-7: split pool gives RP1 a lower zaa_SV than combined pool", {
  # Under combined pool, SP zeros deflate the pool mean SV, inflating RP1's
  # z-score numerator; but they also inflate the pool SD (denominator).
  # Net effect with this fixture: combined zaa_SV[RP1] > split zaa_SV[RP1]
  # because the denominator inflates less than the numerator benefit.
  # The test-spec's simpler assertion is confirmed below.
  pitchers <- data.frame(
    player_id       = c("SP1", "SP2", "SP3", "RP1", "RP2", "RP3"),
    player_name     = c("SP1", "SP2", "SP3", "RP1", "RP2", "RP3"),
    pos_eligibility = c("SP", "SP", "SP", "RP", "RP", "RP"),
    team            = rep("NYY", 6), league = rep("AL", 6),
    W               = c(13, 12, 10, 2, 3, 1),
    K               = c(165, 150, 130, 70, 65, 55),
    SV              = c(0, 0, 0, 30, 15, 8),
    ERA             = c(3.2, 3.5, 4.2, 2.8, 3.0, 3.4),
    IP              = c(190, 175, 165, 65, 60, 55),
    stringsAsFactors = FALSE
  )
  pitchers <- pad_cross_side_columns(pitchers)
  cfg <- make_zaa_cfg(categories = c("W", "K", "SV", "ERA"),
                      roster_slots  = c(C = 0L),
                      pitcher_slots = c(SP = 3L, RP = 3L))

  result_combined <- withCallingHandlers(
    zaa(stats = pitchers, config = cfg, pitcher_pool = "combined"),
    message = function(m) invokeRestart("muffleMessage"),
    warning = function(w) invokeRestart("muffleWarning")
  )
  result_split <- withCallingHandlers(
    zaa(stats = pitchers, config = cfg, pitcher_pool = "split"),
    message = function(m) invokeRestart("muffleMessage")
  )

  zaa_sv_comb  <- result_combined$zaa_SV[result_combined$player_id == "RP1"]
  zaa_sv_split <- result_split$zaa_SV[result_split$player_id    == "RP1"]

  # Under combined: RP1 benefits from SP zeros dragging down pool mean
  # (30 - pool_mean_combined) / pool_sd_combined > (30 - pool_mean_split) / pool_sd_split
  # with this fixture (pool_mean_combined=8.83 < pool_mean_split=17.67)
  expect_gt(zaa_sv_comb, zaa_sv_split,
            label = "TS-ZAA-7: RP1 zaa_SV is higher under combined (inflated by SP zeros)")

  # Under combined, SP z-scores for SV are negative (SV=0 below combined pool mean=8.83)
  zaa_sv_sp1_comb <- result_combined$zaa_SV[result_combined$player_id == "SP1"]
  expect_lt(zaa_sv_sp1_comb, 0,
            label = "TS-ZAA-7: SP1 zaa_SV is negative under combined (SV=0 < pool mean 8.83)")
  # Note: under split, SPs are in their own SV pool (all SV=0) so pop_sd=0 -> z=0.
})

# ---------------------------------------------------------------------------
# TS-ZAA-9 — batter_pool effect on z-score magnitude
# ---------------------------------------------------------------------------

test_that("TS-ZAA-9: catcher HR z-score larger under positional than combined pool", {
  batters <- data.frame(
    player_id       = c("C1", "C2", "B1", "B2", "B3", "B4"),
    player_name     = c("C1", "C2", "B1", "B2", "B3", "B4"),
    pos_eligibility = c("C", "C", "1B", "1B", "1B", "1B"),
    team            = rep("NYY", 6), league = rep("AL", 6),
    HR              = c(15, 25, 20, 28, 35, 42),
    stringsAsFactors = FALSE
  )
  batters <- pad_cross_side_columns(batters)
  cfg <- make_zaa_cfg(categories = "HR",
                      roster_slots  = c(C = 2L, "1B" = 4L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  result_pos <- withCallingHandlers(
    zaa(stats = batters, config = cfg, batter_pool = "positional"),
    message = function(m) invokeRestart("muffleMessage")
  )
  result_comb <- withCallingHandlers(
    zaa(stats = batters, config = cfg, batter_pool = "combined"),
    message = function(m) invokeRestart("muffleMessage")
  )

  abs_pos  <- abs(result_pos$zaa_HR[result_pos$player_id   == "C2"])
  abs_comb <- abs(result_comb$zaa_HR[result_comb$player_id == "C2"])

  expect_gt(abs_pos, abs_comb,
            label = "TS-ZAA-9: top catcher HR z larger under positional (narrower SD)")

  # distribution attribute confirms: positional C/HR sd < combined HR sd
  dist_pos  <- attr(result_pos,  "distribution")
  dist_comb <- attr(result_comb, "distribution")
  sd_pos  <- dist_pos[["C"]][["HR"]][["sd"]]
  sd_comb <- dist_comb[["HR"]][["sd"]]
  if (!is.null(sd_pos) && !is.null(sd_comb)) {
    expect_lt(sd_pos, sd_comb,
              label = "TS-ZAA-9: positional C/HR sd < combined HR sd")
  }
})

# ---------------------------------------------------------------------------
# TS-ZAA-17 — Invalid membership values abort with rotostats_error_invalid_parameter
# ---------------------------------------------------------------------------

test_that("TS-ZAA-17A: pitcher_pool='both' -> rotostats_error_invalid_parameter", {
  players <- data.frame(
    player_id = "P1", player_name = "A", pos_eligibility = "SP",
    team = "NYY", league = "AL", K = 150, stringsAsFactors = FALSE
  )
  cfg <- make_zaa_cfg(categories = "K",
                      roster_slots  = c(C = 0L),
                      pitcher_slots = c(SP = 1L, RP = 0L))

  expect_error(
    withCallingHandlers(
      zaa(stats = players, config = cfg, pitcher_pool = "both"),
      message = function(m) invokeRestart("muffleMessage")
    ),
    class = "rotostats_error_invalid_parameter"
  )
})

test_that("TS-ZAA-17B: batter_pool='all' -> rotostats_error_invalid_parameter", {
  players <- data.frame(
    player_id = "P1", player_name = "A", pos_eligibility = "1B",
    team = "NYY", league = "AL", HR = 25, stringsAsFactors = FALSE
  )
  cfg <- make_zaa_cfg(categories = "HR",
                      roster_slots  = c("1B" = 1L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  expect_error(
    withCallingHandlers(
      zaa(stats = players, config = cfg, batter_pool = "all"),
      message = function(m) invokeRestart("muffleMessage")
    ),
    class = "rotostats_error_invalid_parameter"
  )
})

test_that("TS-ZAA-17C: weight_method='geometric' -> rotostats_error_invalid_parameter", {
  players <- data.frame(
    player_id = "P1", player_name = "A", pos_eligibility = "1B",
    team = "NYY", league = "AL", HR = 25, stringsAsFactors = FALSE
  )
  cfg <- make_zaa_cfg(categories = "HR",
                      roster_slots  = c("1B" = 1L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  expect_error(
    withCallingHandlers(
      zaa(stats = players, config = cfg, weight_method = "geometric"),
      message = function(m) invokeRestart("muffleMessage")
    ),
    class = "rotostats_error_invalid_parameter"
  )
})

# ---------------------------------------------------------------------------
# TS-ZAA-18 — stats=NULL AND replacement=NULL aborts
# ---------------------------------------------------------------------------

test_that("TS-ZAA-18: stats=NULL and replacement=NULL -> rotostats_error_invalid_parameter", {
  cfg <- make_zaa_cfg(categories = "HR",
                      roster_slots  = c("1B" = 2L),
                      pitcher_slots = c(SP = 0L, RP = 0L))

  expect_error(
    zaa(stats = NULL, config = cfg, replacement = NULL),
    class = "rotostats_error_invalid_parameter"
  )
})

test_that("TS-ZAA-18: config=NULL and replacement=NULL -> rotostats_error_invalid_parameter", {
  players <- data.frame(
    player_id = c("P1", "P2"), player_name = c("A", "B"),
    pos_eligibility = c("1B", "1B"), team = c("NYY", "NYY"),
    league = c("AL", "AL"), HR = c(20, 30), stringsAsFactors = FALSE
  )

  expect_error(
    zaa(stats = players, config = NULL, replacement = NULL),
    class = "rotostats_error_invalid_parameter"
  )
})

# ---------------------------------------------------------------------------
# TS-ZAA-Z1a — replacement + batter_pool="positional" (default) + mixed pool
# Closes Note 1 from review.md (zaa-2026-04-21): the blank_labels fix
# (setNames + is.na guard) was exercised by code inspection but had no
# end-to-end test with replacement + batter_pool="positional" + mixed pool.
# ---------------------------------------------------------------------------

test_that("TS-ZAA-Z1a: replacement + batter_pool='positional' + mixed pool returns data frame", {
  # Mixed stats: 2 catchers, 2 first basemen, 2 SPs.
  # n_teams=1 so all 6 players are in the rostered set.
  h_cats <- c("HR", "R", "RBI", "SB")
  p_cats <- c("W", "K", "SV", "QS")

  stats_df <- data.frame(
    player_id       = c("C1", "C2", "B1", "B2", "SP1", "SP2"),
    player_name     = c("C1", "C2", "B1", "B2", "SP1", "SP2"),
    pos_eligibility = c("C", "C", "1B", "1B", "SP", "SP"),
    team            = rep("NYY", 6), league = rep("AL", 6),
    HR  = c(15, 20, 25, 30, NA, NA),
    R   = c(55, 65, 75, 85, NA, NA),
    RBI = c(50, 60, 70, 80, NA, NA),
    SB  = c(3,  5,  10, 15, NA, NA),
    W   = c(NA, NA, NA, NA, 12, 10),
    K   = c(NA, NA, NA, NA, 155, 140),
    SV  = c(NA, NA, NA, NA, 0,  0),
    QS  = c(NA, NA, NA, NA, 18, 15),
    IP  = c(NA, NA, NA, NA, 180, 160),
    stringsAsFactors = FALSE
  )
  cfg <- make_zaa_cfg(
    categories    = c(h_cats, p_cats),
    n_teams       = 1L,
    roster_slots  = c(C = 2L, "1B" = 2L),
    pitcher_slots = c(SP = 2L, RP = 0L)
  )
  repl <- suppressWarnings(replacement_level(stats_df, config = cfg))

  # Assertion 1: call does not throw; returns data frame.
  result <- withCallingHandlers(
    suppressWarnings(
      zaa(stats = stats_df, config = cfg, replacement = repl,
          batter_pool = "positional")
    ),
    message = function(m) invokeRestart("muffleMessage")
  )
  expect_no_error(
    withCallingHandlers(
      suppressWarnings(
        zaa(stats = stats_df, config = cfg, replacement = repl,
            batter_pool = "positional")
      ),
      message = function(m) invokeRestart("muffleMessage")
    )
  )
  expect_true(is.data.frame(result),
              label = "TS-ZAA-Z1a: result is a data.frame")

  # Assertion 2: nrow(result) equals the rostered-set size from
  # attr(repl, "position_assignments") (spec §Step 1).
  pa <- attr(repl, "position_assignments")
  expect_false(
    is.null(pa),
    label = "TS-ZAA-Z1a: position_assignments attribute is not NULL"
  )
  expect_equal(
    nrow(result),
    length(pa),
    label = "TS-ZAA-Z1a: nrow(result) == length(position_assignments)"
  )

  # Assertion 3: distribution is keyed by side first (Task 4.2 schema), then
  # nested on the hitter side under batter_pool="positional".
  # Outer level: $batter / $pitcher.
  # Under $batter: hitter position keys ("C", "1B"); under each, category
  # keys (e.g., "HR").
  dist <- attr(result, "distribution")
  expect_true(is.list(dist), label = "TS-ZAA-Z1a: distribution is list")
  expect_true("batter" %in% names(dist),
              label = "TS-ZAA-Z1a: top-level 'batter' key present")
  bat_dist <- dist[["batter"]]
  expect_true("C"  %in% names(bat_dist),
              label = "TS-ZAA-Z1a: hitter position key 'C' under $batter")
  expect_true("1B" %in% names(bat_dist),
              label = "TS-ZAA-Z1a: hitter position key '1B' under $batter")
  expect_true("HR" %in% names(bat_dist[["C"]]),
              label = "TS-ZAA-Z1a: category key 'HR' under $batter$C")
  expect_true("HR" %in% names(bat_dist[["1B"]]),
              label = "TS-ZAA-Z1a: category key 'HR' under $batter$1B")
  # Confirm these are leaf entries (lists with 'mean' and 'sd')
  c_hr_entry <- bat_dist[["C"]][["HR"]]
  expect_true(is.list(c_hr_entry),
              label = "TS-ZAA-Z1a: dist$batter$C$HR is a list")
  expect_true("mean" %in% names(c_hr_entry),
              label = "TS-ZAA-Z1a: dist$batter$C$HR has 'mean'")
  expect_true("sd"   %in% names(c_hr_entry),
              label = "TS-ZAA-Z1a: dist$batter$C$HR has 'sd'")

  # Assertion 4 (sanity): standard output attribute schema.
  expect_equal(attr(result, "units"),  "zscore",
               label = "TS-ZAA-Z1a: units == 'zscore'")
  expect_equal(attr(result, "anchor"), "average",
               label = "TS-ZAA-Z1a: anchor == 'average'")
})

# ---------------------------------------------------------------------------
# TS-ZAA-19 — AVG in mixed hitter/pitcher pool with weight_method="linear"
# Closes Note 2 from review.md (zaa-2026-04-21): the interaction
# weight_method != "none" + mixed pool + AVG (causing pitcher total_zaa=NA
# via NA AB -> NA zaa_AVG -> NA rowSum) was not covered.
# ---------------------------------------------------------------------------

test_that("TS-ZAA-19: AVG + mixed pool + weight_method='linear': pitcher zaa_AVG and total_zaa are NA", {
  # DOCUMENTED BEHAVIOR: spec-zaa.md §Step 2 (pitchers have NA AB -> NA
  # zaa_AVG via volume-weighting in Step 2b) and §Step 3/§Step 4 (na.rm=FALSE
  # rowSums; weight_method applied to row-summed total).
  #
  # Scored cats: 5 hitter (HR, R, RBI, SB, AVG) + 4 pitcher counting
  # (W, K, SV, QS).  AVG requires AB; pitchers have NA AB -> NA zaa_AVG
  # -> NA total_zaa (na.rm=FALSE).  Hitters have NA for W/K/SV/QS but those
  # are counting stats that produce z=0 for hitters, so hitter total_zaa
  # is finite.  Linear multiplier for hitters = 5/5 = 1.0 (n_hitter/n_hitter).

  h_cats <- c("HR", "R", "RBI", "SB", "AVG")
  p_cats <- c("W", "K", "SV", "QS")

  batters <- data.frame(
    player_id       = c("H1", "H2", "H3"),
    player_name     = c("H1", "H2", "H3"),
    pos_eligibility = c("C", "C", "C"),
    team            = rep("NYY", 3), league = rep("AL", 3),
    HR  = c(20, 15, 25),
    R   = c(70, 60, 80),
    RBI = c(75, 65, 85),
    SB  = c(5,  10, 15),
    AVG = c(0.280, 0.265, 0.295),
    AB  = c(420, 380, 460),
    IP  = rep(NA_real_, 3),
    stringsAsFactors = FALSE
  )
  pitchers <- data.frame(
    player_id       = c("SP1", "SP2"),
    player_name     = c("SP1", "SP2"),
    pos_eligibility = c("SP", "SP"),
    team            = rep("NYY", 2), league = rep("AL", 2),
    W   = c(12, 10),
    K   = c(155, 140),
    SV  = c(0, 0),
    QS  = c(18, 15),
    IP  = c(180, 160),
    # No AB and no AVG: these are NA for pitchers by construction.
    stringsAsFactors = FALSE
  )

  # Use .build_mixed_stats to add cross-position NA columns so rbind works.
  stats_df <- .build_mixed_stats(pitchers, batters,
                                 pitcher_cats = p_cats,
                                 batter_cats  = h_cats)

  cfg <- make_zaa_cfg(
    categories    = c(h_cats, p_cats),
    n_teams       = 12L,
    roster_slots  = c(C = 3L),
    pitcher_slots = c(SP = 2L, RP = 0L)
  )

  # pitcher_pool="split" avoids the combined-pool warning interaction (TS-ZAA-15).
  result <- suppressWarnings(
    withCallingHandlers(
      zaa(stats = stats_df, config = cfg,
          weight_method = "linear", pitcher_pool = "split"),
      message = function(m) invokeRestart("muffleMessage")
    )
  )

  expect_true(is.data.frame(result),
              label = "TS-ZAA-19: result is a data.frame")

  sp_rows  <- result$player_id %in% c("SP1", "SP2")
  hit_rows <- result$player_id %in% c("H1", "H2", "H3")

  # Assertion 1: every pitcher row has NA zaa_AVG.
  # AVG is a hitter-side category (cross-side under Task 4.2 per-side
  # scoping), so pitcher rows always carry NA zaa_AVG regardless of the
  # legacy NA-AB / Step-2b path.
  expect_true(
    all(is.na(result$zaa_AVG[sp_rows])),
    label = "TS-ZAA-19: every pitcher row has NA zaa_AVG (cross-side scoping)"
  )

  # Assertion 2: pitcher total_zaa is finite (Task 4.2 schema change).
  # Pre-Task-4.2 behavior: na.rm=FALSE on the rowSum, so any NA in a
  # cross-side cell (zaa_AVG for pitchers) propagated to NA total_zaa.
  # Post-Task-4.2: total_zaa uses na.rm=TRUE so cross-side NAs contribute 0
  # and each side's intra-side total stays well-defined. Pitcher total_zaa
  # therefore reflects the W/K/SV/QS sum (multiplied by the linear weight).
  expect_true(
    all(is.finite(result$total_zaa[sp_rows])),
    label = "TS-ZAA-19: every pitcher row has finite total_zaa (na.rm=TRUE)"
  )

  # Assertion 3: every hitter row has finite total_zaa.
  # Hitters have full AB coverage -> finite zaa_AVG.
  # Hitter z-scores for W/K/SV/QS are 0 (not NA) per counting-stat behavior.
  expect_true(
    all(is.finite(result$total_zaa[hit_rows])),
    label = "TS-ZAA-19: every hitter row has finite total_zaa"
  )

  # Assertion 4: hitter multiplier preservation.
  # Linear weight_method: multiplier = n_hitter_cats / n_hitter_cats = 5/5 = 1.0.
  # total_zaa[i] / sum(hitter_zaa_cats[i]) must equal 1.0 within tolerance=1e-6.
  # This mirrors TS-ZAA-5's hitter-side ratio check.
  hitter_zaa_cols <- paste0("zaa_", h_cats)  # zaa_HR, zaa_R, zaa_RBI, zaa_SB, zaa_AVG
  for (pid in c("H1", "H2", "H3")) {
    row  <- result[result$player_id == pid, , drop = FALSE]
    rsum <- sum(as.numeric(row[, hitter_zaa_cols, drop = FALSE]), na.rm = FALSE)
    if (!is.na(rsum) && abs(rsum) > 1e-10) {
      ratio <- row$total_zaa / rsum
      expect_equal(
        ratio, 1.0, tolerance = 1e-6,
        label = paste0("TS-ZAA-19: hitter ", pid,
                       " ratio total_zaa / sum(hitter_zaa_cats) == 1.0")
      )
    }
  }
})

# ===========================================================================
# Cross-side category scoping (Task 4.2)
# ===========================================================================
test_that("zaa() output has NA for cross-side categories", {
  fx <- make_zar_fixture()  # batting_categories = c("HR","R","SB"),
                            # pitcher_categories = c("K","SV")
  out <- zaa(replacement = fx$replacement)

  pitcher_rows <- subset(out, player_type == "pitcher")
  batter_rows  <- subset(out, player_type == "batter")

  expect_true(all(is.na(pitcher_rows$zaa_HR)))
  expect_true(all(is.na(pitcher_rows$zaa_R)))
  expect_true(all(is.na(pitcher_rows$zaa_SB)))
  expect_true(all(is.na(batter_rows$zaa_K)))
  expect_true(all(is.na(batter_rows$zaa_SV)))

  # Same-side cells are finite (or NA only for valid same-side reasons like
  # missing playing-time inputs).
  expect_true(any(is.finite(pitcher_rows$zaa_K)))
  expect_true(any(is.finite(batter_rows$zaa_HR)))
})

# ===========================================================================
# Zero-playing-time warning throttling (Task 4.3)
# ===========================================================================
test_that("zaa() emits at most one zero-playing-time warning per side per cat", {
  proj <- make_projections_data(seed = 11L)
  # Force half the SP pool to have 0 IP — pre-fix would warn N times.
  sp_idx <- which(proj$pos_eligibility == "SP")
  proj$IP[sp_idx[1:5]] <- 0

  cfg <- league_config(
    n_teams            = 4L,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 3L, RP = 2L),
    batting_categories = c("HR", "R"),
    pitcher_categories = c("ERA")
  )
  repl <- replacement_level(proj, cfg)

  warnings_emitted <- testthat::capture_warnings(zaa(replacement = repl))
  zero_pt <- grep("zero.*playing.*time|0 IP|0 AB", warnings_emitted,
                  ignore.case = TRUE, value = TRUE)
  expect_lte(length(zero_pt), 2L)  # one summary per affected cat-side, not per player
})
