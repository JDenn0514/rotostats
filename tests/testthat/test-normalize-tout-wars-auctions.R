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

# ── Task 4-7 augmentation tests ──────────────────────────────────────────────

# Build a well-formed standard-layout fixture for N teams.
# Each row has 2 + 2*n_teams fields (trailing empty col), matching the real
# CSV format used by Tout Wars.  After the parser trims the all-NA trailing
# column the result is 1 + 2*n_teams = expected_cols.
#
# extra_col: if not NULL, a length-6 character vector.  Each element is
# appended after the trailing comma of the corresponding row (replacing the
# empty field with a non-empty value).  Use "" to keep a row's extra field
# empty, NA to keep it empty as well.
.std_lines <- function(n_teams,
                       meta_labels = c("Left to Spend", "Players Needed", "Max Bid"),
                       slot1 = "C", slot2 = "SP",
                       p1 = "10", p2 = "20",
                       extra_col = NULL) {
  # owner row: empty + (owner, empty) * n_teams + trailing empty
  # e.g., ",O1,,O2,,O3,,"  for n_teams = 3  (2 + 2*3 = 8 fields)
  owner_parts <- paste(
    vapply(seq_len(n_teams), function(k) paste0("O", k, ",,"), character(1)),
    collapse = ""
  )
  owner_row <- paste0(",", owner_parts)  # already ends with ",,"

  meta_row_line <- function(label) {
    parts <- paste(
      vapply(seq_len(n_teams), function(k) paste0(label, ",0"), character(1)),
      collapse = ","
    )
    paste0(",", parts, ",")   # leading empty + label/value pairs + trailing empty
  }

  data_row_line <- function(slot, prefix, price) {
    parts <- paste(
      vapply(seq_len(n_teams), function(k) paste0(prefix, k, ",", price), character(1)),
      collapse = ","
    )
    paste0(slot, ",", parts, ",")  # slot + name/price pairs + trailing empty
  }

  lines <- c(
    owner_row,
    meta_row_line(meta_labels[1]),
    meta_row_line(meta_labels[2]),
    meta_row_line(meta_labels[3]),
    data_row_line(slot1, "PA", p1),
    data_row_line(slot2, "PB", p2)
  )

  # Replace the trailing empty field of each row with the given extra_col value.
  # This effectively inserts a (2 + 2*n_teams)-th column.
  if (!is.null(extra_col)) {
    stopifnot(length(extra_col) == length(lines))
    fill <- ifelse(is.na(extra_col), "", extra_col)
    lines <- paste0(lines, fill)
  }

  lines
}

# Build a no-meta-row standard fixture (owner + 2 data rows).
# Same row-format rules: 2 + 2*n_teams fields per row.
.std_lines_no_meta <- function(n_teams, slot1 = "C", slot2 = "SP",
                                p1 = "10", p2 = "20") {
  owner_parts <- paste(
    vapply(seq_len(n_teams), function(k) paste0("O", k, ",,"), character(1)),
    collapse = ""
  )
  owner_row <- paste0(",", owner_parts)

  data_row_line <- function(slot, prefix, price) {
    parts <- paste(
      vapply(seq_len(n_teams), function(k) paste0(prefix, k, ",", price), character(1)),
      collapse = ","
    )
    paste0(slot, ",", parts, ",")
  }

  c(owner_row,
    data_row_line(slot1, "PA", p1),
    data_row_line(slot2, "PB", p2))
}

# Test 1: has_meta_rows = FALSE
test_that(".parse_tw_auction_standard parses no-meta-row files with has_meta_rows = FALSE", {
  tf <- tempfile(fileext = ".csv")
  writeLines(.std_lines_no_meta(12L), tf)

  result <- .parse_tw_auction_standard(tf, expected_teams = 12L, has_meta_rows = FALSE)
  # 12 teams * 2 priced rows = 24
  expect_equal(nrow(result), 24L)
  expect_type(result$price, "integer")

  # Calling with has_meta_rows = TRUE on the same file should abort because
  # rows 2-4 are data rows, not meta-label rows.
  expect_error(
    .parse_tw_auction_standard(tf, expected_teams = 12L, has_meta_rows = TRUE),
    class = "rotostats_error_auction_meta_rows"
  )
})

# Test 2: "O" → "OF" slot rewrite
test_that(".parse_tw_auction_standard rewrites slot 'O' to 'OF'", {
  tf <- tempfile(fileext = ".csv")
  writeLines(.std_lines(3L, slot1 = "O", slot2 = "SP"), tf)

  result <- .parse_tw_auction_standard(tf, expected_teams = 3L)
  expect_true(all(result$position_slot != "O"))
  expect_true("OF" %in% result$position_slot)
})

# Test 3: trailing duplicate-slot column, all canonical — should be silently dropped
test_that(".parse_tw_auction_standard drops trailing duplicate-slot col when all canonical", {
  # extra_col replaces the trailing empty field: data rows get canonical slot values
  extra <- c("", "", "", "", "C", "SP")
  tf <- tempfile(fileext = ".csv")
  writeLines(.std_lines(3L, extra_col = extra), tf)

  result <- .parse_tw_auction_standard(tf, expected_teams = 3L)
  expect_equal(nrow(result), 6L)
})

# Test 4: trailing duplicate-slot column with ONE non-canonical cell — still dropped (tolerance)
test_that(".parse_tw_auction_standard drops trailing dup-slot col with one typo cell", {
  # SP row has "f" instead of "SP" — one non-canonical out of two data rows
  extra <- c("", "", "", "", "C", "f")
  tf <- tempfile(fileext = ".csv")
  writeLines(.std_lines(3L, extra_col = extra), tf)

  result <- .parse_tw_auction_standard(tf, expected_teams = 3L)
  expect_equal(nrow(result), 6L)
})

# Test 5: trailing duplicate-slot column with TWO non-canonical cells — NOT dropped → error
test_that(".parse_tw_auction_standard errors when trailing slot col has two non-canonical cells", {
  extra <- c("", "", "", "", "f", "g")
  tf <- tempfile(fileext = ".csv")
  writeLines(.std_lines(3L, extra_col = extra), tf)

  expect_error(
    .parse_tw_auction_standard(tf, expected_teams = 3L),
    class = "rotostats_error_auction_col_count"
  )
})

# Test 6: stray-comment columns (≤1 non-NA cell each) are silently trimmed
test_that(".parse_tw_auction_standard trims stray comment columns with <=1 non-NA cell", {
  # First extra column has one non-NA cell (a comment on the C row).
  # Second extra column is entirely empty (all trailing commas).
  extra1 <- c("", "", "", "", "All set Dave...", "")
  base <- .std_lines(3L, extra_col = extra1)
  # Append a second trailing empty col to every line.
  lines <- paste0(base, ",")
  tf <- tempfile(fileext = ".csv")
  writeLines(lines, tf)

  result <- .parse_tw_auction_standard(tf, expected_teams = 3L)
  expect_equal(nrow(result), 6L)
})

# Test 7: alternate meta-row labels ("$ To Spend" / "# Needed" / "Max Bid")
test_that(".parse_tw_auction_standard accepts shorthand meta labels", {
  tf <- tempfile(fileext = ".csv")
  writeLines(
    .std_lines(3L, meta_labels = c("$ To Spend", "# Needed", "Max Bid")),
    tf
  )

  result <- .parse_tw_auction_standard(tf, expected_teams = 3L)
  expect_equal(nrow(result), 6L)
})

# Test 8: "$"-prefix prices are stripped and coerced to integer
test_that(".parse_tw_auction_standard strips leading '$' from prices", {
  tf <- tempfile(fileext = ".csv")
  writeLines(.std_lines(3L, p1 = "$10", p2 = "$20"), tf)

  result <- .parse_tw_auction_standard(tf, expected_teams = 3L)
  expect_type(result$price, "integer")
  expect_true(all(result$price[result$position_slot == "C"] == 10L))
  expect_true(all(result$price[result$position_slot == "SP"] == 20L))
})

# Test 9: dropped-empty-price picks emit an informational message and reduce row count
test_that(".parse_tw_auction_standard drops and announces picks with empty price", {
  # 3-team standard fixture where team 2 on the C row has an empty price cell.
  # Constructed manually so the empty price cell is explicit.  All rows have
  # the same number of fields (2 + 2*3 = 8) matching the real fixture format.
  tf <- tempfile(fileext = ".csv")
  writeLines(c(
    ",O1,,O2,,O3,,",             # owner row (8 fields)
    ",Left to Spend,0,Left to Spend,0,Left to Spend,0,",  # meta rows (8 fields)
    ",Players Needed,0,Players Needed,0,Players Needed,0,",
    ",Max Bid,1,Max Bid,1,Max Bid,1,",
    "C,PA1,10,PA2,,PA3,12,",     # PA2 has empty price
    "SP,PB1,20,PB2,21,PB3,22,"
  ), tf)

  expect_message(
    result <- .parse_tw_auction_standard(tf, expected_teams = 3L),
    regexp = "Dropping"
  )
  # 3 * 2 = 6 expected, but 1 dropped → 5
  expect_equal(nrow(result), 5L)
})

# Test 10: .parse_tw_auction_2021_al parses the bespoke 2021-al layout
test_that(".parse_tw_auction_2021_al parses 2021-al layout correctly", {
  path <- fixture_path("2021-al-12.csv")

  result <- .parse_tw_auction_2021_al(path, expected_teams = 12L)

  expect_named(
    result,
    c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")
  )
  # 12 teams * 2 priced rows (C and OF) = 24
  expect_equal(nrow(result), 24L)
  expect_type(result$price, "integer")
  # "O" in col 2 must have been rewritten to "OF"
  expect_true("OF" %in% result$position_slot)
  expect_false("O" %in% result$position_slot)
  expect_setequal(unique(result$position_slot), c("C", "OF"))
  expect_true(all(result$player_type == "batter"))
  expect_true(all(!result$is_keeper))
})
