test_that("sgp() blended_pool runs on tout_wars_team_season + Steamer fixture", {
  fixture_path <- test_path("fixtures/projections-steamer-both.rds")
  skip_if_not(file.exists(fixture_path), "steamer fixture not present")
  projections <- readRDS(fixture_path)

  ts <- dplyr::filter(tout_wars_team_season, league == "mixed")
  history <- league_history(team_season = ts)
  config <- league_config(
    n_teams            = 15L,
    roster_slots       = c(C = 1, "1B" = 1, "2B" = 1, "3B" = 1, SS = 1,
                           OF = 5, UTIL = 1),
    pitcher_slots      = c(SP = 6L, RP = 3L),
    batting_categories = c("R", "HR", "RBI", "SB", "OBP"),
    pitcher_categories = c("W", "SV", "SO", "ERA", "WHIP")
  )
  denoms <- sgp_denominators(
    history,
    scoring_categories = c("R", "HR", "RBI", "SB", "OBP",
                           "W", "SV", "SO", "ERA", "WHIP"),
    exclude_years      = 2020L
  )

  out <- sgp(
    projections    = projections,
    denominators   = denoms,
    league_history = history,
    league_config  = config
  )

  # Schema: sgp_<CAT> per scored category + total_sgp
  expected_cols <- c(paste0("sgp_", c("R", "HR", "RBI", "SB", "OBP",
                                       "W", "SV", "SO", "ERA", "WHIP")),
                     "total_sgp")
  expect_true(all(expected_cols %in% names(out)))
  expect_equal(nrow(out), nrow(projections))

  # At least some hitter rows should have finite hitter-cat SGP, and at
  # least some pitcher rows should have finite pitcher-cat SGP. The fixture
  # has 25 batters + 25 pitchers; allow a generous margin (>= 10 each side).
  hitter_cols  <- c("sgp_R", "sgp_HR", "sgp_RBI", "sgp_SB", "sgp_OBP")
  pitcher_cols <- c("sgp_W", "sgp_SV", "sgp_SO", "sgp_ERA", "sgp_WHIP")
  hr_finite <- rowSums(is.finite(as.matrix(out[, hitter_cols, drop = FALSE]))) > 0
  pi_finite <- rowSums(is.finite(as.matrix(out[, pitcher_cols, drop = FALSE]))) > 0
  expect_gte(sum(hr_finite), 10)
  expect_gte(sum(pi_finite), 10)
})
