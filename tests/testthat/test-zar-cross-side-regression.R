# tests/testthat/test-zar-cross-side-regression.R
# Regression: pitcher rows must receive NA for hitter z-scores (HR, R, SB, ...)
# and vice versa. Before this fix, FanGraphs pitcher `hr` (HR allowed) and `r`
# (R allowed) collided with hitter `hr` / `r` after the union combine, so
# pitchers received a non-NA hitter z-score.

test_that("pitcher rows get NA for hitter categories in zar() output", {
  skip_if_not_installed("withr")

  proj <- make_projections_data(seed = 7L)

  cfg <- league_config(
    n_teams            = 12L,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 3L, RP = 3L),
    batting_categories = c("HR", "R", "SB"),
    pitcher_categories = c("K", "SV", "ERA"),
    league_type        = "mixed"
  )

  repl <- replacement_level(proj, cfg)
  out  <- zar(repl)

  pitchers <- subset(out, player_type == "pitcher")
  hitters  <- subset(out, player_type == "batter")

  # Hitter cats in pitcher rows: NA, not 0, not non-zero.
  expect_true(all(is.na(pitchers$zar_hr)))
  expect_true(all(is.na(pitchers$zar_r)))
  expect_true(all(is.na(pitchers$zar_sb)))

  # Pitcher cats in hitter rows: NA, not 0.
  expect_true(all(is.na(hitters$zar_k)))
  expect_true(all(is.na(hitters$zar_sv)))
  expect_true(all(is.na(hitters$zar_era)))

  # total_zar is the rowSum(na.rm = TRUE) — neither side gets credit for the
  # other side's cells but each side's intra-side total is well-defined.
  expect_true(all(is.finite(pitchers$total_zar)))
  expect_true(all(is.finite(hitters$total_zar)))
})
