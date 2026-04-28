test_that("par() runs on tout_wars_team_season + Steamer fixture", {
  fixture_path <- test_path("fixtures/projections-steamer-both.rds")
  skip_if_not(file.exists(fixture_path), "steamer fixture not present")
  projections <- readRDS(fixture_path)

  ts <- dplyr::filter(tout_wars_team_season, league == "mixed")
  history <- league_history(team_season = ts)

  # n_teams = 1 because the 50-row fixture cannot support n_teams = 15
  # (e.g. only 3 catchers in the pool, but 15 teams × 1 C slot = 15 needed).
  config <- league_config(
    n_teams            = 1L,
    roster_slots       = c(C = 1, "1B" = 1, "2B" = 1, "3B" = 1, SS = 1,
                           OF = 3, UTIL = 1),
    pitcher_slots      = c(SP = 5L, RP = 3L),
    batting_categories = c("R", "HR", "RBI", "SB", "OBP"),
    pitcher_categories = c("W", "SV", "SO", "ERA", "WHIP")
  )
  denoms <- sgp_denominators(
    history,
    scoring_categories = c("R", "HR", "RBI", "SB", "OBP",
                           "W", "SV", "SO", "ERA", "WHIP"),
    exclude_years      = 2020L
  )

  repl <- replacement_level(projections = projections, config = config)
  out <- par(
    replacement     = repl,
    denominators    = denoms,
    league_history  = history
  )

  expect_true("total_par" %in% names(out))
  expect_equal(nrow(out), nrow(projections))
  expect_true(any(is.finite(out$total_par)))

  # With a 50-row fixture and ~17 roster slots, most players are below
  # replacement by construction, so median PAR is negative.  Instead assert
  # that at least some players have positive PAR (the "above replacement"
  # contributors that drive auction value).
  expect_true(any(out$total_par > 0, na.rm = TRUE))
})
