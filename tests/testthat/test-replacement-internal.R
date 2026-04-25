test_that(".partition_projections_by_side() uses player_type when present", {
  df <- data.frame(
    player_id   = c("A", "B", "C"),
    player_type = c("batter", "pitcher", "batter"),
    stringsAsFactors = FALSE
  )
  parts <- .partition_projections_by_side(df)
  expect_equal(parts$batter$player_id, c("A", "C"))
  expect_equal(parts$pitcher$player_id, "B")
})

test_that(".partition_projections_by_side() falls back to pos_eligibility regex", {
  df <- data.frame(
    player_id       = c("A", "B", "C"),
    pos_eligibility = c("OF", "SP", "1B|OF"),
    stringsAsFactors = FALSE
  )
  parts <- .partition_projections_by_side(df)
  expect_equal(parts$batter$player_id, c("A", "C"))
  expect_equal(parts$pitcher$player_id, "B")
})

test_that(".partition_projections_by_side() duplicates two-way players", {
  df <- data.frame(
    player_id   = "ohtani",
    player_type = "two_way",
    stringsAsFactors = FALSE
  )
  parts <- .partition_projections_by_side(df)
  expect_equal(parts$batter$player_id, "ohtani")
  expect_equal(parts$pitcher$player_id, "ohtani")
})

test_that(".partition_projections_by_side() aborts when both columns missing", {
  df <- data.frame(player_id = "A", stringsAsFactors = FALSE)
  expect_error(
    .partition_projections_by_side(df),
    class = "rotostats_error_missing_column"
  )
})
