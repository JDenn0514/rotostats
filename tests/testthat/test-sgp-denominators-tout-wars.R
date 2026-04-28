test_that("sgp_denominators runs on tout_wars_team_season (mixed, OBP)", {
  ts <- dplyr::filter(tout_wars_team_season, league == "mixed")
  history <- league_history(team_season = ts)

  denoms <- sgp_denominators(
    history,
    scoring_categories = c("R", "HR", "RBI", "SB", "OBP",
                           "W", "SV", "SO", "ERA", "WHIP"),
    exclude_years      = 2020L
  )

  # Snapshot the denominator vector so future regressions show up as a diff.
  expect_snapshot_value(round(as.numeric(denoms), 4), style = "json2")
})

test_that("sgp_denominators runs on tout_wars_team_season (al, AVG)", {
  ts <- dplyr::filter(tout_wars_team_season, league == "al")
  history <- league_history(team_season = ts)

  denoms <- sgp_denominators(
    history,
    scoring_categories = c("R", "HR", "RBI", "SB", "AVG",
                           "W", "SV", "SO", "ERA", "WHIP"),
    exclude_years      = 2020L
  )

  expect_snapshot_value(round(as.numeric(denoms), 4), style = "json2")
})

test_that("sgp_denominators denominator values are positive and finite", {
  ts <- dplyr::filter(tout_wars_team_season, league == "mixed")
  history <- league_history(team_season = ts)

  denoms <- sgp_denominators(
    history,
    scoring_categories = c("R", "HR", "RBI", "SB", "OBP",
                           "W", "SV", "SO", "ERA", "WHIP"),
    exclude_years      = 2020L
  )

  vals <- as.numeric(denoms)
  expect_true(all(is.finite(vals)))
  expect_true(all(vals > 0))
})
