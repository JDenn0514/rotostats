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
