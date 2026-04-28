test_that(".read_tw_batters reads a per-team batter CSV with expected columns", {
  path <- "../../data-raw/sources/tout-wars/rosters/2024-al-batters.csv"
  skip_if_not(file.exists(path), "raw batter CSV not present")

  out <- rotostats:::.read_tw_batters(path)

  required <- c("year", "league", "team", "player_name", "player_id",
                "mlb_team", "position", "salary", "status", "roster_section",
                "eligibility", "ab", "g", "r", "hr", "rbi", "sb", "so",
                "bb", "avg", "obp", "slg")
  expect_true(all(required %in% names(out)))
  expect_type(out$year, "integer")
  expect_type(out$league, "character")
  expect_type(out$team, "character")
  expect_type(out$ab, "integer")
  expect_type(out$avg, "double")
  expect_type(out$obp, "double")
  expect_type(out$roster_section, "character")
  expect_true(nrow(out) > 0)
  expect_true(all(out$year == 2024L))
  expect_true(all(out$league == "al"))
})

test_that(".read_tw_pitchers reads a per-team pitcher CSV with expected columns", {
  path <- "../../data-raw/sources/tout-wars/rosters/2024-al-pitchers.csv"
  skip_if_not(file.exists(path), "raw pitcher CSV not present")

  out <- rotostats:::.read_tw_pitchers(path)

  required <- c("year", "league", "team", "player_name", "player_id",
                "mlb_team", "position", "salary", "status", "roster_section",
                "eligibility", "g", "w", "l", "sv", "ip", "bb", "hr",
                "so", "era", "whip")
  expect_true(all(required %in% names(out)))
  expect_type(out$ip, "double")
  expect_type(out$w, "integer")
  expect_type(out$era, "double")
  expect_type(out$whip, "double")
  expect_true(nrow(out) > 0)
})

test_that(".read_tw_batters errors if a required column is missing", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  writeLines("year,league,team\n2024,al,X", tmp)
  expect_error(
    rotostats:::.read_tw_batters(tmp),
    class = "rotostats_error_team_season_missing_column"
  )
})

test_that(".filter_active_sections keeps active and previously_active only", {
  df <- tibble::tibble(
    roster_section = c("active", "reserved", "previously_active",
                       "previously_reserved", "active"),
    val = 1:5
  )
  out <- rotostats:::.filter_active_sections(df)
  expect_equal(out$val, c(1L, 3L, 5L))
})

test_that(".filter_active_sections errors on unknown section value", {
  df <- tibble::tibble(roster_section = c("active", "weird"))
  expect_error(
    rotostats:::.filter_active_sections(df),
    class = "rotostats_error_team_season_unknown_section"
  )
})
