# tests/testthat/test-get-projections.R
#
# TDD-first test suite for get_projections().
# Authored from plans/implementation/get-projections-impl.md before the
# function itself exists; the first run must fail.

# ---------------------------------------------------------------------------
# .current_season_year()
# ---------------------------------------------------------------------------

test_that(".current_season_year() returns the calendar year as integer", {
  expect_identical(
    rotostats:::.current_season_year(),
    as.integer(format(Sys.Date(), "%Y"))
  )
  expect_type(rotostats:::.current_season_year(), "integer")
})

# ---------------------------------------------------------------------------
# .validate_source()
# ---------------------------------------------------------------------------

test_that(".validate_source() accepts every documented source", {
  valid <- c("steamer", "zips", "atc", "fangraphsdc", "thebat", "thebatx", "custom")
  for (s in valid) {
    expect_identical(rotostats:::.validate_source(s), s)
  }
})

test_that(".validate_source() rejects unknown sources with the right class", {
  expect_error(
    rotostats:::.validate_source("marcel"),
    class = "rotostats_error_invalid_source"
  )
})

test_that(".validate_source() rejects non-scalar / non-character input", {
  expect_error(
    rotostats:::.validate_source(c("steamer", "zips")),
    class = "rotostats_error_invalid_source"
  )
  expect_error(
    rotostats:::.validate_source(1L),
    class = "rotostats_error_invalid_source"
  )
  expect_error(
    rotostats:::.validate_source(NULL),
    class = "rotostats_error_invalid_source"
  )
})

# ---------------------------------------------------------------------------
# .validate_player_type()
# ---------------------------------------------------------------------------

test_that(".validate_player_type() accepts 'batters', 'pitchers', 'both'", {
  expect_identical(rotostats:::.validate_player_type("batters"), "batters")
  expect_identical(rotostats:::.validate_player_type("pitchers"), "pitchers")
  expect_identical(rotostats:::.validate_player_type("both"), "both")
})

test_that(".validate_player_type() rejects anything else", {
  expect_error(
    rotostats:::.validate_player_type("batter"),
    class = "rotostats_error_invalid_player_type"
  )
  expect_error(
    rotostats:::.validate_player_type(NA_character_),
    class = "rotostats_error_invalid_player_type"
  )
  expect_error(
    rotostats:::.validate_player_type(NULL),
    class = "rotostats_error_invalid_player_type"
  )
})

# ---------------------------------------------------------------------------
# .validate_year()
# ---------------------------------------------------------------------------

test_that(".validate_year(NULL) returns the current season", {
  yr <- rotostats:::.validate_year(NULL)
  expect_identical(yr, rotostats:::.current_season_year())
})

test_that(".validate_year() accepts the current season explicitly", {
  cur <- rotostats:::.current_season_year()
  expect_identical(rotostats:::.validate_year(cur), cur)
  expect_identical(rotostats:::.validate_year(as.numeric(cur)), cur)
})

test_that(".validate_year() aborts on non-current years", {
  cur <- rotostats:::.current_season_year()
  expect_error(
    rotostats:::.validate_year(cur - 1L),
    class = "rotostats_error_unsupported_year"
  )
  expect_error(
    rotostats:::.validate_year(cur + 1L),
    class = "rotostats_error_unsupported_year"
  )
})

test_that(".validate_year() aborts on non-scalar / non-integer input", {
  expect_error(
    rotostats:::.validate_year(c(2026, 2027)),
    class = "rotostats_error_unsupported_year"
  )
  expect_error(
    rotostats:::.validate_year("2026"),
    class = "rotostats_error_unsupported_year"
  )
  expect_error(
    rotostats:::.validate_year(2026.5),
    class = "rotostats_error_unsupported_year"
  )
})

# ---------------------------------------------------------------------------
# .validate_custom_data()
# ---------------------------------------------------------------------------

test_that(".validate_custom_data() returns data unchanged on valid custom input", {
  d <- data.frame(name = "A", HR = 10)
  expect_identical(rotostats:::.validate_custom_data("custom", d), d)

  d2 <- data.frame(playerid = "abc", HR = 10)
  expect_identical(rotostats:::.validate_custom_data("custom", d2), d2)
})

test_that(".validate_custom_data() returns NULL on non-custom source + NULL data", {
  expect_null(rotostats:::.validate_custom_data("steamer", NULL))
})

test_that(".validate_custom_data() aborts when data supplied with non-custom source", {
  d <- data.frame(name = "A")
  expect_error(
    rotostats:::.validate_custom_data("steamer", d),
    class = "rotostats_error_data_ignored"
  )
})

test_that(".validate_custom_data() aborts on custom + NULL", {
  expect_error(
    rotostats:::.validate_custom_data("custom", NULL),
    class = "rotostats_error_missing_custom_data"
  )
})

test_that(".validate_custom_data() aborts on non-data.frame data", {
  expect_error(
    rotostats:::.validate_custom_data("custom", list(name = "A")),
    class = "rotostats_error_invalid_custom_data"
  )
  expect_error(
    rotostats:::.validate_custom_data("custom", matrix(1:4, 2, 2)),
    class = "rotostats_error_invalid_custom_data"
  )
})

test_that(".validate_custom_data() aborts when neither name nor playerid is present", {
  d <- data.frame(HR = 10, RBI = 20)
  expect_error(
    rotostats:::.validate_custom_data("custom", d),
    class = "rotostats_error_invalid_custom_data"
  )
})
