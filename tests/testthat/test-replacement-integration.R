# tests/testthat/test-replacement-integration.R
#
# Integration tests for replacement_level():
#   - sort_by = "sgp" iteration loop
#   - multi-pos assignment
#   - two-call position_assignments protocol
#
# Written by the tester pipeline from test-spec.md (§13).
# Tester did NOT read spec.md, sim-spec.md, or implementation.md.

library(testthat)

# ---------------------------------------------------------------------------
# Shared config fixture
# ---------------------------------------------------------------------------

cfg_mixed_12 <- league_config(
  n_teams            = 12L,
  roster_slots       = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L, SS = 1L,
                         OF = 3L, UTIL = 1L),
  pitcher_slots      = c(SP = 6L, RP = 3L),
  batting_categories = c("HR", "R", "RBI", "SB", "AVG"),
  pitcher_categories = c("W", "K", "SV", "ERA", "WHIP"),
  league_type        = "mixed",
  budget             = 260L
)

# ---------------------------------------------------------------------------
# SGP denominators helper for integration tests
# ---------------------------------------------------------------------------

# Build a minimal sgp_denominators object compatible with replacement_level().
# Uses sgp_denominators() with rate_conversion = "blended_pool" (the only
# implemented option). The team_season data must include IP and AB columns so
# that replacement_level() can forward league_history to sgp() for rate-stat
# baseline computation.
make_test_sgp_denominators <- function(seed = 42L) {
  set.seed(seed)
  n_teams <- 12L
  years   <- 2019L:2023L
  rows <- lapply(years, function(y) {
    data.frame(
      year    = y,
      team_id = paste0("T", seq_len(n_teams)),
      HR      = round(rnorm(n_teams, 200, 25)),
      R       = round(rnorm(n_teams, 700, 50)),
      RBI     = round(rnorm(n_teams, 650, 50)),
      SB      = round(rnorm(n_teams, 90,  18)),
      AVG     = round(rnorm(n_teams, 0.260, 0.008), 4),
      W       = round(rnorm(n_teams, 81,   7)),
      K       = round(rnorm(n_teams, 1350, 100)),
      SV      = round(rnorm(n_teams, 43,   10)),
      ERA     = round(rnorm(n_teams, 3.90, 0.28), 3),
      WHIP    = round(rnorm(n_teams, 1.26, 0.07), 4),
      IP      = round(rnorm(n_teams, 1430, 60)),   # required for blended_pool rate baseline
      AB      = round(rnorm(n_teams, 5600, 150)),  # required for blended_pool rate baseline
      stringsAsFactors = FALSE
    )
  })
  ts <- do.call(rbind, rows)
  list(
    denominators = suppressWarnings(sgp_denominators(
      list(team_season = ts),
      scoring_categories = c("HR", "R", "RBI", "SB", "AVG",
                              "W", "K", "SV", "ERA", "WHIP")
    )),
    history = list(team_season = ts)
  )
}

# ---------------------------------------------------------------------------
# TS-50: sort_by = "sgp" iteration with valid denominators converges
# ---------------------------------------------------------------------------

test_that("TS-50: sort_by=sgp iteration converges with valid denominators", {
  proj       <- make_projections_data(n_batters = 80L, seed = 42L)
  sgp_bundle <- suppressWarnings(make_test_sgp_denominators(seed = 42L))
  # sgp_bundle$denominators has rate_conversion = "blended_pool"; must supply
  # sgp_bundle$history (with IP and AB) as league_history so sgp() can compute
  # rate-stat baselines.
  result_sgp <- suppressWarnings(
    replacement_level(
      proj,
      config           = cfg_mixed_12,
      sort_by          = "sgp",
      sgp_denominators = sgp_bundle$denominators,
      league_history   = sgp_bundle$history
    )
  )
  expect_true(attr(result_sgp, "converged"))
  expect_gte(attr(result_sgp, "iterations"), 1L)
})

# ---------------------------------------------------------------------------
# TS-51: sort_by = "sgp" vs "zscore" produce different replacement stats
# ---------------------------------------------------------------------------

test_that("TS-51: sort_by=sgp produces different replacement stats than zscore", {
  proj       <- make_projections_data(n_batters = 80L, seed = 42L)
  sgp_bundle <- suppressWarnings(make_test_sgp_denominators(seed = 42L))

  result_z   <- replacement_level(proj, config = cfg_mixed_12,
                                    sort_by = "zscore")
  result_sgp <- suppressWarnings(
    replacement_level(proj, config = cfg_mixed_12,
                      sort_by          = "sgp",
                      sgp_denominators = sgp_bundle$denominators,
                      league_history   = sgp_bundle$history)
  )

  z_sp_era   <- result_z$replacement_stats[
    result_z$replacement_stats$position == "SP", "ERA"
  ]
  sgp_sp_era <- result_sgp$replacement_stats[
    result_sgp$replacement_stats$position == "SP", "ERA"
  ]
  # Not identical — methods should diverge
  expect_false(isTRUE(all.equal(z_sp_era, sgp_sp_era, tolerance = 0)))
})

# ---------------------------------------------------------------------------
# TS-52: position_assignments from pass 1 fed into pass 2
# ---------------------------------------------------------------------------

test_that("TS-52: position_assignments on second call updates pool membership", {
  proj    <- make_projections_data(n_batters = 80L, 
                                   seed = 42L)
  result1 <- replacement_level(proj, config = cfg_mixed_12,
                                multi_pos = "highest_par")
  pa1 <- attr(result1, "position_assignments")

  result2 <- replacement_level(proj, config = cfg_mixed_12,
                                multi_pos = "highest_par",
                                position_assignments = pa1)
  expect_named(result2, names(result1), ignore.order = TRUE)
  expect_s3_class(result2$replacement_stats, "data.frame")
})

# ---------------------------------------------------------------------------
# TS-53: multi_pos = "primary" ignores position_assignments
# ---------------------------------------------------------------------------

test_that("TS-53: multi_pos=primary ignores position_assignments", {
  proj    <- make_projections_data(n_batters = 80L, 
                                   seed = 42L)
  result1 <- replacement_level(proj, config = cfg_mixed_12,
                                multi_pos = "highest_par")
  pa1     <- attr(result1, "position_assignments")

  result_prim  <- replacement_level(proj, config = cfg_mixed_12,
                                     multi_pos = "primary",
                                     position_assignments = pa1)
  result_prim2 <- replacement_level(proj, config = cfg_mixed_12,
                                     multi_pos = "primary",
                                     position_assignments = NULL)

  expect_equal(result_prim$replacement_stats, result_prim2$replacement_stats)
})

# ---------------------------------------------------------------------------
# replacement_level() accepts the get_projections() pitcher wire format
#
# Regression guard for the integration gap where FanGraphs pitcher rows
# (no position field -> pos_eligibility = "P") were silently dropped from
# every SP/RP pool. The fixture here mirrors the shape of
# get_projections("steamer") after normalization: lowercase column names,
# pitcher rows with pos_eligibility = "P", batter rows with standard batter
# eligibility tokens.
# ---------------------------------------------------------------------------

test_that("replacement_level() classifies pitchers when pos_eligibility = 'P'", {
  set.seed(42L)
  # OF needs n_teams * 5 = 50 eligible; weight the position mix so OF is the
  # majority (mirrors real projection sets where OF dominates batter rows).
  hit_positions <- c(
    rep("C",  20L),
    rep("1B", 15L),
    rep("2B", 15L),
    rep("SS", 15L),
    rep("3B", 15L),
    rep("OF", 60L)
  )
  n_hit <- length(hit_positions)
  # Need >= n_teams * SP_slots (10 * 7 = 70) SP-eligible and
  # n_teams * RP_slots (10 * 4 = 40) RP-eligible per the 60/40 default split
  # of pitcher_slots = 11L.
  n_sp <- 80L
  n_rp <- 50L
  n_pit <- n_sp + n_rp

  batters <- data.frame(
    player_id       = paste0("h", seq_len(n_hit)),
    player_name     = paste0("Batter ", seq_len(n_hit)),
    team            = "NYY",
    league          = "AL",
    pos_eligibility = hit_positions,
    player_type     = "batter",
    AB              = rnorm(n_hit, mean = 500, sd = 40),
    HR              = rnorm(n_hit, mean = 20,  sd = 6),
    R               = rnorm(n_hit, mean = 70,  sd = 10),
    RBI             = rnorm(n_hit, mean = 70,  sd = 10),
    SB              = rnorm(n_hit, mean = 8,   sd = 4),
    AVG             = rnorm(n_hit, mean = 0.260, sd = 0.020),
    IP              = NA_real_,
    W               = NA_real_,
    ERA             = NA_real_,
    WHIP            = NA_real_,
    SV              = NA_real_,
    K               = NA_real_,
    stringsAsFactors = FALSE
  )

  ip_vals <- c(
    runif(n_sp, min = 150, max = 200),
    runif(n_rp, min = 40, max = 80)
  )
  pitchers <- data.frame(
    player_id       = paste0("p", seq_len(n_pit)),
    player_name     = paste0("Pitcher ", seq_len(n_pit)),
    team            = "NYY",
    league          = "AL",
    pos_eligibility = rep("P", n_pit),
    player_type     = "pitcher",
    AB              = NA_real_,
    HR              = NA_real_,
    R               = NA_real_,
    RBI             = NA_real_,
    SB              = NA_real_,
    AVG             = NA_real_,
    IP              = ip_vals,
    W               = rnorm(n_pit, mean = 8,    sd = 3),
    ERA             = rnorm(n_pit, mean = 4.0,  sd = 0.6),
    WHIP            = rnorm(n_pit, mean = 1.30, sd = 0.12),
    SV              = c(rep(0, n_pit - 10L), rnorm(10L, mean = 15, sd = 8)),
    K               = ip_vals * rnorm(n_pit, mean = 1.0, sd = 0.1),
    stringsAsFactors = FALSE
  )

  proj <- rbind(batters, pitchers)

  config <- league_config(
    n_teams            = 10L,
    roster_slots       = c(C = 2L, `1B` = 1L, `2B` = 1L, SS = 1L, `3B` = 1L,
                           OF = 5L, UT = 2L, CI = 1L, MI = 1L),
    pitcher_slots      = 11L,
    batting_categories = c("AVG", "HR", "R", "RBI", "SB"),
    pitcher_categories = c("W", "ERA", "WHIP", "SV", "K"),
    league_type        = "AL",
    budget_split       = 0.5
  )

  repl <- replacement_level(proj, config = config)

  sp_row <- repl$replacement_stats[repl$replacement_stats$position == "SP", ,
                                    drop = FALSE]
  rp_row <- repl$replacement_stats[repl$replacement_stats$position == "RP", ,
                                    drop = FALSE]
  expect_gt(sp_row$n_band_players, 0L)
  expect_gt(rp_row$n_band_players, 0L)

  expect_false(is.na(sp_row$W))
  expect_false(is.na(sp_row$ERA))
  expect_false(is.na(sp_row$WHIP))
  expect_false(is.na(sp_row$K))
  expect_false(is.na(rp_row$W))
  expect_false(is.na(rp_row$ERA))

  of_row <- repl$replacement_stats[repl$replacement_stats$position == "OF", ,
                                    drop = FALSE]
  expect_false(is.na(of_row$HR))
  expect_false(is.na(of_row$R))
})

test_that("replacement_level() + zar() pipeline produces finite pitcher zar", {
  set.seed(7L)
  hit_positions <- c(
    rep("C",  20L),
    rep("1B", 15L),
    rep("2B", 15L),
    rep("SS", 15L),
    rep("3B", 15L),
    rep("OF", 60L)
  )
  n_hit <- length(hit_positions)
  n_sp <- 80L
  n_rp <- 50L
  n_pit <- n_sp + n_rp
  batters <- data.frame(
    player_id       = paste0("h", seq_len(n_hit)),
    player_name     = paste0("H", seq_len(n_hit)),
    team            = "NYY",
    league          = "AL",
    pos_eligibility = hit_positions,
    player_type     = "batter",
    AB              = rnorm(n_hit, 500, 40),
    HR              = rnorm(n_hit, 20, 6),
    R               = rnorm(n_hit, 70, 10),
    RBI             = rnorm(n_hit, 70, 10),
    SB              = rnorm(n_hit, 8, 4),
    AVG             = rnorm(n_hit, 0.260, 0.020),
    IP              = NA_real_, W = NA_real_, ERA = NA_real_,
    WHIP = NA_real_, SV = NA_real_, K = NA_real_,
    stringsAsFactors = FALSE
  )
  ip_vals <- c(runif(n_sp, 150, 200), runif(n_rp, 40, 80))
  pitchers <- data.frame(
    player_id       = paste0("p", seq_len(n_pit)),
    player_name     = paste0("P", seq_len(n_pit)),
    team            = "NYY",
    league          = "AL",
    pos_eligibility = rep("P", n_pit),
    player_type     = "pitcher",
    AB              = NA_real_, HR = NA_real_, R = NA_real_,
    RBI = NA_real_, SB = NA_real_, AVG = NA_real_,
    IP              = ip_vals,
    W               = rnorm(n_pit, 8, 3),
    ERA             = rnorm(n_pit, 4.0, 0.6),
    WHIP            = rnorm(n_pit, 1.30, 0.12),
    SV              = c(rep(0, n_pit - 10L), rnorm(10L, 15, 8)),
    K               = ip_vals * rnorm(n_pit, 1.0, 0.1),
    stringsAsFactors = FALSE
  )
  proj <- rbind(batters, pitchers)
  config <- league_config(
    n_teams            = 10L,
    roster_slots       = c(C = 2L, `1B` = 1L, `2B` = 1L, SS = 1L, `3B` = 1L,
                           OF = 5L, UT = 2L, CI = 1L, MI = 1L),
    pitcher_slots      = 11L,
    batting_categories = c("AVG", "HR", "R", "RBI", "SB"),
    pitcher_categories = c("W", "ERA", "WHIP", "SV", "K"),
    league_type        = "AL",
    budget_split       = 0.5
  )

  result <- zar(replacement_level(proj, config = config))

  pit_ids <- paste0("p", seq_len(n_pit))
  pit_rows <- result[result$player_id %in% pit_ids, , drop = FALSE]
  expect_gt(nrow(pit_rows), 0L)
  expect_true(any(is.finite(pit_rows$zar_W)))
  expect_true(any(is.finite(pit_rows$zar_ERA)))
})
