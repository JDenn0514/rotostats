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
  n_teams       = 12L,
  roster_slots  = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L, SS = 1L,
                    OF = 3L, UTIL = 1L),
  pitcher_slots = c(SP = 6L, RP = 3L),
  categories    = c("HR", "R", "RBI", "SB", "AVG",
                    "W", "K", "SV", "ERA", "WHIP"),
  league_type   = "mixed",
  budget        = 260L
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
  proj       <- make_projections_data(n_hitters = 80L, seed = 42L)
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
  proj       <- make_projections_data(n_hitters = 80L, seed = 42L)
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
  proj    <- make_projections_data(n_hitters = 80L, 
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
  proj    <- make_projections_data(n_hitters = 80L, 
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
