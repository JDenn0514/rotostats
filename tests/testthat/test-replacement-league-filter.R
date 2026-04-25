# tests/testthat/test-replacement-league-filter.R
#
# Regression tests for league_type pool filtering inside replacement_level().
# Per league_config()'s documented contract, league_type = "AL" / "NL" must
# restrict the player pool to that league; "mixed" keeps both.

base_config <- function(league_type) {
  league_config(
    n_teams            = 2L,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 1L, RP = 1L),
    batting_categories = c("HR", "R", "SB"),
    pitcher_categories = c("K", "SV"),
    league_type        = league_type
  )
}

test_that("league_type = 'AL' drops NL players from the replacement pool", {
  proj <- make_projections_data(seed = 99L)
  expect_true(any(proj$league == "AL"))
  expect_true(any(proj$league == "NL"))

  repl <- replacement_level(proj, base_config("AL"))
  stored <- attr(repl, "projections")

  expect_true(all(stored$LEAGUE == "AL"))
  expect_equal(nrow(stored), sum(proj$league == "AL"))
})

test_that("league_type = 'NL' drops AL players from the replacement pool", {
  proj <- make_projections_data(seed = 99L)

  repl <- replacement_level(proj, base_config("NL"))
  stored <- attr(repl, "projections")

  expect_true(all(stored$LEAGUE == "NL"))
  expect_equal(nrow(stored), sum(proj$league == "NL"))
})

test_that("league_type = 'mixed' keeps both leagues (no filter)", {
  proj <- make_projections_data(seed = 99L)

  repl <- replacement_level(proj, base_config("mixed"))
  stored <- attr(repl, "projections")

  expect_equal(nrow(stored), nrow(proj))
  expect_setequal(unique(stored$LEAGUE), c("AL", "NL"))
})

test_that("zar() output contains no NL players when league_type = 'AL'", {
  proj <- make_projections_data(seed = 99L)
  repl <- replacement_level(proj, base_config("AL"))
  out  <- zar(repl)

  nl_ids <- proj$player_id[proj$league == "NL"]
  expect_true(!any(out$player_id %in% nl_ids))
})

test_that("empty filtered pool aborts with rotostats_error_empty_league_pool", {
  proj <- make_projections_data(seed = 99L)
  proj$league <- "AL"  # remove all NL rows by relabeling

  expect_error(
    replacement_level(proj, base_config("NL")),
    class = "rotostats_error_empty_league_pool"
  )
})
