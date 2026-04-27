fixture_path <- function(name) {
  testthat::test_path("fixtures", "tout-wars-auctions", name)
}

test_that(".parse_tw_auction_standard returns long-tidy rows", {
  result <- .parse_tw_auction_standard(
    fixture_path("standard-mini.csv"),
    expected_teams = 3
  )
  expect_named(
    result,
    c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")
  )
  expect_equal(nrow(result), 6)  # 3 teams × 2 priced slots (R rows excluded)
  expect_setequal(unique(result$team_owner), c("SMITH", "JONES", "COLTON/WOLF"))
  expect_setequal(unique(result$position_slot), c("C", "SP"))
  expect_setequal(unique(result$player_type), c("batter", "pitcher"))
  expect_true(all(!result$is_keeper))
  expect_type(result$price, "integer")
  expect_true(all(result$price > 0))
})

test_that(".parse_tw_auction_standard excludes reserve and footer rows", {
  result <- .parse_tw_auction_standard(
    fixture_path("standard-mini.csv"),
    expected_teams = 3
  )
  # Reserve player names from the fixture must not appear in the output.
  expect_false(any(grepl("^Reserve ", result$player_name)))
  # Position_slot column must contain no "R" entries.
  expect_false("R" %in% result$position_slot)
  expect_equal(nrow(result), 6L)
})

test_that(".parse_tw_auction_standard errors on wrong column count", {
  # write a fixture inline with 5 cols instead of 7
  tf <- tempfile(fileext = ".csv")
  writeLines(c(",SMITH,,JONES,", ",Left to Spend,0,Left to Spend,0",
               ",Players Needed,0,Players Needed,0", ",Max Bid,1,Max Bid,1",
               "C,Player A,10,Player B,12"), tf)
  expect_error(
    .parse_tw_auction_standard(tf, expected_teams = 3),
    class = "rotostats_error_auction_col_count"
  )
})

test_that(".parse_tw_auction_standard errors on missing meta rows", {
  tf <- tempfile(fileext = ".csv")
  writeLines(c(",SMITH,,JONES,,WOLF,",
               ",Wrong Label,0,Wrong Label,0,Wrong Label,0",
               ",Players Needed,0,Players Needed,0,Players Needed,0",
               ",Max Bid,1,Max Bid,1,Max Bid,1",
               "C,A,1,B,2,C,3"), tf)
  expect_error(
    .parse_tw_auction_standard(tf, expected_teams = 3),
    class = "rotostats_error_auction_meta_rows"
  )
})

test_that(".parse_tw_auction_standard derives player_type correctly", {
  result <- .parse_tw_auction_standard(
    fixture_path("standard-mini.csv"),
    expected_teams = 3
  )
  expect_equal(result$player_type[result$position_slot == "C"], rep("batter", 3))
  expect_equal(result$player_type[result$position_slot == "SP"], rep("pitcher", 3))
})

test_that(".parse_tw_auction_2012_alnl handles 2012-al layout", {
  result <- .parse_tw_auction_2012_alnl(
    fixture_path("2012-al-mini.csv"),
    expected_teams = 3
  )
  expect_named(
    result,
    c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")
  )
  expect_equal(nrow(result), 6L)
  expect_setequal(unique(result$team_owner), c("SMITH", "JONES", "COLTON/WOLF"))
  expect_setequal(unique(result$position_slot), c("C", "SP"))
  # Row-filter must drop reserves and footer notes.
  expect_false(any(grepl("^Reserve ", result$player_name)))
  expect_false("R" %in% result$position_slot)
})

test_that(".parse_tw_auction_2012_alnl handles 2012-nl layout", {
  result <- .parse_tw_auction_2012_alnl(
    fixture_path("2012-nl-mini.csv"),
    expected_teams = 3
  )
  expect_equal(nrow(result), 6L)
  expect_setequal(unique(result$team_owner), c("ALPHA", "BETA", "GAMMA"))
  expect_setequal(unique(result$player_type), c("batter", "pitcher"))
})

test_that(".parse_tw_auction_2012_mixed handles empty row 1 and sparse slots", {
  result <- .parse_tw_auction_2012_mixed(
    fixture_path("2012-mixed-mini.csv"),
    expected_teams = 3
  )
  # 3 teams * 3 priced data rows = 9. Reserve row, "checked" notes row, and
  # the trailing empty row must all be excluded.
  expect_equal(nrow(result), 9L)
  expect_setequal(unique(result$team_owner), c("SMITH", "JONES", "COLTON/WOLF"))
  expect_setequal(unique(result$position_slot), c("C", "SP"))
  expect_false(any(result$player_name %in% c("Reserve A", "Reserve B", "Reserve C")))
  expect_false(any(result$player_name == "checked"))

  # Sparse-slot row (row 6 of fixture: A1/A2/A3) should backward-inherit `C`.
  smith_rows <- dplyr::filter(result, .data$team_owner == "SMITH")
  expect_equal(sum(smith_rows$position_slot == "C"), 2L)
  expect_equal(sum(smith_rows$position_slot == "SP"), 1L)
})

test_that("standard parser handles 2015-nl quoted-multiline fields natively", {
  # The raw 2015-nl.csv has literal newlines inside quoted owner names
  # (e.g., "GARDNER\n", "HERTZ\n") and inside several player names. readr's
  # CSV parser handles RFC-4180 multiline-quoted fields natively, and the
  # standard parser already trims surrounding whitespace. This test pins
  # the round-trip so a future readr regression cannot reintroduce the
  # embedded-newline pathology silently.
  path <- testthat::test_path(
    "..", "..", "data-raw", "sources", "tout-wars", "auctions", "2015-nl.csv"
  )
  testthat::skip_if_not(file.exists(path), "2015-nl.csv not present in source tree")

  result <- expect_no_warning(
    .parse_tw_auction_standard(path, expected_teams = 12)
  )

  expect_equal(nrow(result), 276L)
  expect_setequal(
    unique(result$team_owner),
    c("CARTY", "COCKCROFT", "GARDNER", "GIANELLA", "GUILFOYLE", "HERTZ",
      "KREUTZER", "MCCAFFREY", "MELNICK", "WALTON", "WILDERMAN", "ZOLA")
  )
  expect_false(any(grepl("\n", result$team_owner)))
  expect_false(any(grepl("\n", result$player_name)))
})

test_that(".normalize_tw_auction dispatches to the standard parser by default", {
  result <- .normalize_tw_auction(
    fixture_path("standard-al-12.csv"),
    year = 2018, league = "al"
  )
  expect_equal(nrow(result), 24)
})

test_that(".normalize_tw_auction routes 2012-al to the bespoke parser", {
  result <- .normalize_tw_auction(
    fixture_path("2012-al-12.csv"),
    year = 2012, league = "al"
  )
  expect_equal(nrow(result), 24)
})

test_that(".normalize_tw_auction errors on unknown league", {
  expect_error(
    .normalize_tw_auction(fixture_path("standard-mini.csv"), year = 2018, league = "xyz"),
    class = "rotostats_error_auction_unknown_league"
  )
})

test_that(".normalize_tw_auction consults .tw_team_count_overrides for 2012-nl=13", {
  result <- .normalize_tw_auction(
    fixture_path("2012-nl-13.csv"),
    year = 2012, league = "nl"
  )
  # 13 teams * 2 priced rows = 26 picks
  expect_equal(nrow(result), 26L)
})

test_that(".normalize_tw_auction routes 2012-mixed to the bespoke parser", {
  result <- .normalize_tw_auction(
    fixture_path("2012-mixed-15.csv"),
    year = 2012, league = "mixed"
  )
  # 15 teams * 3 priced rows (sparse backward-filled to C, C, SP) = 45 picks
  expect_equal(nrow(result), 45L)
  # Confirm position_slot has only canonical values (parser-specific backward-fill)
  expect_setequal(unique(result$position_slot), c("C", "SP"))
})
