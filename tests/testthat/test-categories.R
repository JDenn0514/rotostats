test_that("CANONICAL_BATTING_CATEGORIES includes OBP, SLG, OPS and side-suffixed pct stats", {
  expect_true(all(c("OBP", "SLG", "OPS") %in% CANONICAL_BATTING_CATEGORIES))
  expect_true(all(c("K%_BATTER", "BB%_BATTER", "SO%_BATTER") %in%
                    CANONICAL_BATTING_CATEGORIES))
})

test_that("CANONICAL_PITCHER_CATEGORIES includes SO and SO/* family and side-suffixed pct stats", {
  expect_true(all(c("SO", "SO/9", "SO/BB") %in% CANONICAL_PITCHER_CATEGORIES))
  expect_true(all(c("K%_PITCHER", "BB%_PITCHER", "SO%_PITCHER") %in%
                    CANONICAL_PITCHER_CATEGORIES))
})

test_that("CANONICAL_BATTING_CATEGORIES and CANONICAL_PITCHER_CATEGORIES partition the canonical set", {
  expect_true(length(intersect(CANONICAL_BATTING_CATEGORIES,
                               CANONICAL_PITCHER_CATEGORIES)) == 0L)
  expect_setequal(
    union(CANONICAL_BATTING_CATEGORIES, CANONICAL_PITCHER_CATEGORIES),
    CANONICAL_CATEGORIES
  )
})

test_that(".classify_category_side() returns 'batter' for hitter cats", {
  expect_equal(.classify_category_side("HR"), "batter")
  expect_equal(.classify_category_side("AVG"), "batter")
  expect_equal(.classify_category_side("OPS"), "batter")
})

test_that(".classify_category_side() returns 'pitcher' for pitcher cats", {
  expect_equal(.classify_category_side("ERA"), "pitcher")
  expect_equal(.classify_category_side("K/9"), "pitcher")
  expect_equal(.classify_category_side("SV"), "pitcher")
})

test_that(".classify_category_side() returns NA for unknown cats", {
  expect_true(is.na(.classify_category_side("UNKNOWN")))
})

test_that(".classify_category_side() is vectorized", {
  expect_equal(
    .classify_category_side(c("HR", "ERA", "??")),
    c("batter", "pitcher", NA_character_)
  )
})
