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
  expect_equal(nrow(result), 6)  # 3 teams x 2 slots
  expect_setequal(unique(result$team_owner), c("SMITH", "JONES", "COLTON/WOLF"))
  expect_setequal(unique(result$position_slot), c("C", "SP"))
  expect_setequal(unique(result$player_type), c("batter", "pitcher"))
  expect_true(all(!result$is_keeper))
  expect_type(result$price, "integer")
  expect_true(all(result$price > 0))
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
