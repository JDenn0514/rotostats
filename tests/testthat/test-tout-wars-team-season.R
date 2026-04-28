test_that("tout_wars_team_season has the expected schema", {
  expected_cols <- c(
    "year", "league", "team_id",
    "R", "HR", "RBI", "SB", "OBP", "AVG",
    "W", "SV", "SO", "ERA", "WHIP",
    "AB", "IP",
    "R_pts", "HR_pts", "RBI_pts", "SB_pts", "OBP_pts", "AVG_pts",
    "W_pts", "SV_pts", "ERA_pts", "WHIP_pts", "SO_pts", "total_pts"
  )
  expect_named(tout_wars_team_season, expected_cols)
  expect_s3_class(tout_wars_team_season, "tbl_df")

  expect_type(tout_wars_team_season$year, "integer")
  expect_type(tout_wars_team_season$league, "character")
  expect_type(tout_wars_team_season$team_id, "character")
  expect_type(tout_wars_team_season$R, "integer")
  expect_type(tout_wars_team_season$AB, "integer")
  expect_type(tout_wars_team_season$IP, "double")
  expect_type(tout_wars_team_season$ERA, "double")
})

test_that("tout_wars_team_season covers 2010-2025 (no 2026)", {
  expect_setequal(unique(tout_wars_team_season$year), 2010:2025)
})

test_that("tout_wars_team_season league domain is valid", {
  expect_setequal(
    unique(tout_wars_team_season$league),
    c("al", "nl", "mixed")
  )
})

test_that("Mixed league only appears 2013+", {
  mixed_years <- unique(
    tout_wars_team_season$year[tout_wars_team_season$league == "mixed"]
  )
  expect_true(min(mixed_years) >= 2013L)
})

test_that("AB and IP are within sanity bounds", {
  # Bounds match the build script's calibrated ranges; they accommodate the
  # 2020 COVID 60-game season (low end) and 15-team mixed leagues (high end).
  expect_true(all(tout_wars_team_season$AB >= 1500 &
                  tout_wars_team_season$AB <= 8000))
  expect_true(all(tout_wars_team_season$IP >= 150 &
                  tout_wars_team_season$IP <= 1800))
})

test_that("(year, league, team_id) is unique", {
  keys <- with(tout_wars_team_season,
               paste(year, league, team_id, sep = "/"))
  expect_equal(length(keys), length(unique(keys)))
})

test_that("OBP or AVG is non-NA per row (one of the two is always scored)", {
  has_obp <- !is.na(tout_wars_team_season$OBP)
  has_avg <- !is.na(tout_wars_team_season$AVG)
  expect_true(all(has_obp | has_avg))
})

test_that("reconciliation residuals are within fixture tolerances", {
  fixture <- readr::read_csv(
    test_path("fixtures/team-season-residuals.csv"),
    col_types = readr::cols(
      year       = readr::col_integer(),
      league     = readr::col_character(),
      team_id    = readr::col_character(),
      avg_resid  = readr::col_double(),
      obp_resid  = readr::col_double(),
      era_resid  = readr::col_double(),
      whip_resid = readr::col_double(),
      flagged    = readr::col_logical()
    )
  )
  flag_rate_by_ly <- dplyr::summarise(
    dplyr::group_by(fixture, year, league),
    flag_rate = mean(flagged),
    .groups = "drop"
  )
  # Threshold matches build script (10%); the empirical worst league-year
  # is 2019 mixed at 6.7% (one isolated WHIP outlier).
  expect_true(all(flag_rate_by_ly$flag_rate <= 0.10))
})
