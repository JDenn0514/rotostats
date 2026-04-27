test_that("tout_wars_auctions has the expected schema", {
  expect_named(
    tout_wars_auctions,
    c("year", "league", "team_owner", "position_slot",
      "player_type", "player_name", "price", "is_keeper")
  )
  expect_type(tout_wars_auctions$year, "integer")
  expect_type(tout_wars_auctions$league, "character")
  expect_type(tout_wars_auctions$team_owner, "character")
  expect_type(tout_wars_auctions$position_slot, "character")
  expect_type(tout_wars_auctions$player_type, "character")
  expect_type(tout_wars_auctions$player_name, "character")
  expect_type(tout_wars_auctions$price, "integer")
  expect_type(tout_wars_auctions$is_keeper, "logical")
})

test_that("tout_wars_auctions domain values are valid", {
  expect_setequal(unique(tout_wars_auctions$league), c("al", "nl", "mixed"))
  expect_setequal(unique(tout_wars_auctions$player_type), c("batter", "pitcher"))
  expect_true(all(!tout_wars_auctions$is_keeper))
})

test_that("tout_wars_auctions has no NA values", {
  for (col in names(tout_wars_auctions)) {
    expect_false(any(is.na(tout_wars_auctions[[col]])), info = paste("column:", col))
  }
})

test_that("tout_wars_auctions has expected row count by year-league", {
  observed <- dplyr::count(tout_wars_auctions, year, league, name = "n")
  expected <- tibble::tibble(
    key = names(rotostats:::.tw_auction_row_counts),
    n   = unname(rotostats:::.tw_auction_row_counts)
  )
  expected$year   <- as.integer(sub("-.*", "", expected$key))
  expected$league <- sub("^[^-]+-", "", expected$key)
  expected$key    <- NULL
  joined <- dplyr::left_join(observed, expected, by = c("year", "league"),
                             suffix = c("_obs", "_exp"))
  expect_equal(joined$n_obs, joined$n_exp)
})

test_that("per-(year, league) total price is in sanity bounds", {
  totals <- dplyr::summarise(
    dplyr::group_by(tout_wars_auctions, year, league),
    total = sum(price), .groups = "drop"
  )
  expect_true(all(totals$total >= 2000 & totals$total <= 5000))
})

test_that("price values are non-negative integers", {
  expect_true(all(tout_wars_auctions$price >= 0))
  expect_type(tout_wars_auctions$price, "integer")
})
