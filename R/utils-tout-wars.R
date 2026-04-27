# Internal helpers for the tout_wars_auctions dataset.
# See plans/specs/2026-04-27-auction-csv-normalization-design.md.

# Aliases applied BEFORE tokenization. Map raw input -> canonical output.
.tw_owner_aliases <- c(
  "Wolf and Colton" = "COLTON/WOLF",
  "Van RIPER"       = "VANRIPER",
  "VAN RIPER"       = "VANRIPER",
  "VanRiper"        = "VANRIPER"
)

#' Canonicalize a Tout Wars team-owner string.
#'
#' Trim whitespace, apply aliases, then split on `/`, uppercase tokens,
#' alphabetize, rejoin. Deterministic - `WOLF/COLTON` and `COLTON/WOLF` both
#' collapse to `COLTON/WOLF`.
#'
#' @param x A length-1 character vector.
#' @return Length-1 canonicalized character vector.
#' @keywords internal
#' @noRd
.canonicalize_tw_owner <- function(x) {
  if (is.na(x) || !nzchar(trimws(x))) {
    cli::cli_abort(
      "Owner string is blank or NA.",
      class = "rotostats_error_owner_blank"
    )
  }
  x <- trimws(x)
  if (x %in% names(.tw_owner_aliases)) {
    return(unname(.tw_owner_aliases[x]))
  }
  tokens <- strsplit(x, "/", fixed = TRUE)[[1]]
  tokens <- toupper(trimws(tokens))
  paste(sort(tokens), collapse = "/")
}

.tw_pitcher_slots <- c("SP", "RP", "P")

# Canonical priced slots used to identify roster rows during parsing.
# Reserve ("R") rows have no auction price and are excluded from the dataset
# (see spec non-goal #6).
# INF was introduced in the 2024 AL/NL roster format as a combined-infield
# slot (replaces the historical CI/MI split).
.tw_canonical_slots <- c(
  "C", "1B", "3B", "CI", "2B", "SS", "MI", "INF", "OF", "UT", "SW",
  "P", "SP", "RP"
)

#' Validate parsed `position_slot` values against `.tw_canonical_slots`.
#'
#' Defense-in-depth check that runs after each parser builds its long tibble.
#' Earlier filtering keeps only canonical slots, but this guards against a
#' future code change introducing a non-canonical slot. Aborts when an
#' unknown value is found.
#'
#' @keywords internal
#' @noRd
.validate_tw_position_slots <- function(slots, path) {
  bad <- setdiff(unique(slots), .tw_canonical_slots)
  if (length(bad) > 0) {
    cli::cli_abort(
      c("Unknown position_slot value(s) in {.file {path}}.",
        "i" = "Offending: {.val {bad}}.",
        "i" = "If valid, add to .tw_canonical_slots in R/utils-tout-wars.R."),
      class = "rotostats_error_auction_unknown_slot"
    )
  }
  invisible(slots)
}

#' Derive player_type from position_slot vector.
#' @keywords internal
#' @noRd
.derive_player_type <- function(position_slot) {
  ifelse(position_slot %in% .tw_pitcher_slots, "pitcher", "batter")
}

#' Parse a standard-layout Tout Wars auction CSV.
#'
#' @param path Path to the raw CSV.
#' @param expected_teams Integer team count (12 for AL/NL, 15 for Mixed).
#' @return Tibble with columns team_owner, position_slot, player_type,
#'   player_name, price, is_keeper.
#' @keywords internal
#' @noRd
.parse_tw_auction_standard <- function(path, expected_teams, has_meta_rows = TRUE) {
  raw <- readr::read_csv(
    path,
    col_types = readr::cols(.default = "c"),
    col_names = FALSE,
    progress = FALSE
  )

  # When meta rows are absent (2021 files), the header is row 1 only and
  # roster rows start at row 2. Otherwise: row 1 + meta rows 2-4 + roster.
  header_rows <- if (has_meta_rows) 1:4 else 1L
  min_rows <- length(header_rows)
  if (nrow(raw) < min_rows) {
    cli::cli_abort(
      "Too few rows in {.file {path}}; expected header + roster.",
      class = "rotostats_error_auction_meta_rows"
    )
  }

  # Some 2021/2022 files abbreviate "OF" as "O" in the slot column. Rewrite
  # before canonical-slot filtering so those rows are recognised as outfield.
  slot_col <- toupper(trimws(as.character(raw[[1]])))
  slot_col[!is.na(slot_col) & slot_col == "O"] <- "OF"
  raw[[1]] <- slot_col

  # Filter rows: keep header (and meta rows when present) unconditionally.
  # For the rest, keep only rows whose col 1 (trimmed, uppercased) is a
  # canonical priced slot. This drops footer/summary rows AND reserve (R) rows.
  is_priced_roster <- !is.na(slot_col) & nzchar(slot_col) & slot_col %in% .tw_canonical_slots
  is_priced_roster[seq_len(min_rows)] <- FALSE  # Don't double-count header rows.
  keep_rows <- c(header_rows, which(is_priced_roster))
  raw <- raw[keep_rows, , drop = FALSE]

  # Trim trailing all-NA columns (now safe — footer/reserve rows excluded).
  is_trailing_na <- vapply(raw, function(col) all(is.na(col)), logical(1))
  last_keep <- max(which(!is_trailing_na))
  raw <- raw[, seq_len(last_keep), drop = FALSE]

  expected_cols <- 1L + 2L * expected_teams

  # Some files (e.g., 2014/2015/2016/2017/2024/2026 mixed) carry a trailing
  # duplicate slot column that mirrors col 1 on the priced-roster rows. If we
  # are off by exactly one column AND the trailing column on data rows is
  # mostly canonical slots (i.e., it's clearly a duplicate slot column, with
  # tolerance for a single typo cell), drop it.
  # The single-cell tolerance is justified by 2017-mixed.csv row 19, where the
  # trailing duplicate slot cell reads "f" instead of "P" (lowercase typo on the
  # pitcher row). All other files have fully canonical trailing columns.
  if (ncol(raw) == expected_cols + 1L && nrow(raw) > min_rows) {
    coln_data <- toupper(trimws(as.character(raw[-seq_len(min_rows), ncol(raw), drop = TRUE])))
    coln_slot_match <- coln_data %in% .tw_canonical_slots
    if (length(coln_slot_match) > 0 &&
        sum(coln_slot_match) >= length(coln_slot_match) - 1L) {
      raw <- raw[, -ncol(raw), drop = FALSE]
    }
  }

  # Some files (e.g., 2024-nl) have stray comment cells in columns past the
  # expected layout (a single non-NA cell in an otherwise all-NA column).
  # If we're over the expected width AND every column past `expected_cols`
  # has at most one non-NA cell, drop them.
  if (ncol(raw) > expected_cols) {
    extra_cols <- (expected_cols + 1L):ncol(raw)
    nonna_per_extra <- vapply(extra_cols, function(j) {
      v <- as.character(raw[[j]])
      sum(!is.na(v) & nzchar(trimws(v)))
    }, integer(1))
    if (all(nonna_per_extra <= 1L)) {
      raw <- raw[, seq_len(expected_cols), drop = FALSE]
    }
  }

  if (ncol(raw) != expected_cols) {
    cli::cli_abort(
      c("Wrong column count in {.file {path}}.",
        "i" = "Expected {expected_cols} columns ({expected_teams} teams), got {ncol(raw)}."),
      class = "rotostats_error_auction_col_count"
    )
  }

  # Validate meta rows (rows 2-4): col 2 of each must match a recognized
  # label set. Two variants seen in the wild:
  #   - canonical: "Left to Spend" / "Players Needed" / "Max Bid"
  #   - shorthand: "$ To Spend"   / "# Needed"        / "Max Bid"
  #   (used in 2023-mixed and 2024-mixed)
  if (has_meta_rows) {
    meta_actual <- vapply(2:4, function(i) as.character(raw[i, 2, drop = TRUE]), character(1))
    meta_canonical <- c("Left to Spend", "Players Needed", "Max Bid")
    meta_shorthand <- c("$ To Spend",    "# Needed",        "Max Bid")
    if (!identical(meta_actual, meta_canonical) &&
        !identical(meta_actual, meta_shorthand)) {
      cli::cli_abort(
        c("Meta rows 2-4 do not match expected labels in {.file {path}}.",
          "i" = "Expected {.val {meta_canonical}} or {.val {meta_shorthand}}, got {.val {meta_actual}}."),
        class = "rotostats_error_auction_meta_rows"
      )
    }
  }

  # Extract owners from row 1, even cols (2, 4, 6, ...).
  owner_cols <- seq(2L, by = 2L, length.out = expected_teams)
  owners_raw <- as.character(raw[1, owner_cols, drop = TRUE])
  owners <- vapply(owners_raw, .canonicalize_tw_owner, character(1))

  # Data rows: rows after the header block.
  data_rows <- raw[-seq_len(min_rows), , drop = FALSE]

  # For each team k (1..expected_teams): cols 2k = name, 2k+1 = price.
  per_team <- lapply(seq_len(expected_teams), function(k) {
    name_col <- 2L * k
    price_col <- 2L * k + 1L
    tibble::tibble(
      team_owner    = owners[k],
      position_slot = as.character(data_rows[[1]]),
      player_name   = as.character(data_rows[[name_col]]),
      price_chr     = as.character(data_rows[[price_col]])
    )
  })
  long <- dplyr::bind_rows(per_team)

  # Drop empty rows.
  long <- dplyr::filter(long, !is.na(.data$player_name) & nzchar(trimws(.data$player_name)))
  long$player_name <- trimws(long$player_name)

  # Drop picks with a player name but a missing price cell. These are source
  # data-entry omissions (e.g., 2017-mixed has 2 such cells). They are not a
  # layout deviation; we don't fabricate a price, but we also shouldn't abort
  # the whole file. Emit an informational notice naming the dropped picks.
  empty_price <- is.na(long$price_chr) | !nzchar(trimws(long$price_chr))
  if (any(empty_price)) {
    dropped <- long$player_name[empty_price]
    cli::cli_inform(c(
      "Dropping {sum(empty_price)} pick(s) with missing price in {.file {path}}.",
      "i" = "Affected player(s): {.val {dropped}}."
    ))
    long <- long[!empty_price, , drop = FALSE]
  }

  # Strip leading "$" on prices (2025-mixed formats prices as "$9").
  long$price_chr <- sub("^\\$", "", trimws(long$price_chr))

  # Coerce price to non-negative integer.
  price_int <- suppressWarnings(as.integer(long$price_chr))
  if (any(is.na(price_int)) || any(price_int < 0)) {
    bad <- long$price_chr[is.na(price_int) | (price_int < 0)]
    cli::cli_abort(
      c("Non-integer or negative prices in {.file {path}}.",
        "i" = "Offending values: {.val {bad}}."),
      class = "rotostats_error_auction_price"
    )
  }
  long$price <- price_int
  long$price_chr <- NULL

  long$position_slot <- trimws(long$position_slot)
  .validate_tw_position_slots(long$position_slot, path)
  long$player_type <- .derive_player_type(long$position_slot)
  long$is_keeper <- FALSE

  long <- dplyr::arrange(
    long,
    .data$team_owner, .data$position_slot, dplyr::desc(.data$price)
  )

  long[, c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")]
}

#' Parse a 2012 Mixed Tout Wars auction CSV.
#'
#' Layout deviation from standard:
#' - Row 1 is entirely empty.
#' - Owner row is row 2; owners in odd columns (3, 5, ..., 2k+1, ..., 31).
#' - Meta rows are rows 3-5 (not 2-4).
#' - Data rows start at row 6.
#' - Position slot in col 2; sparse - the label appears on the LAST row of each
#'   slot group, so preceding rows must backward-fill from below.
#' - For team k: name at col 2k+1, price at col 2k+2. Total cols 2 + 2 * teams.
#'
#' Trailing junk rows (notes, "checked" labels, blank rows after the last
#' priced row) are dropped before backward-fill so they cannot poison the
#' inheritance chain. Reserve rows (slot `R`) survive backward-fill but are
#' dropped by the canonical-slot post-filter (see spec non-goal #6).
#'
#' @keywords internal
#' @noRd
.parse_tw_auction_2012_mixed <- function(path, expected_teams) {
  raw <- readr::read_csv(
    path,
    col_types = readr::cols(.default = "c"),
    col_names = FALSE,
    progress = FALSE
  )

  if (nrow(raw) < 5L) {
    cli::cli_abort(
      "Too few rows in {.file {path}}; expected empty row + owner row + 3 meta rows + roster.",
      class = "rotostats_error_auction_meta_rows"
    )
  }

  # Drop trailing rows after the last row whose col 2 (slot) is non-empty.
  # The 2012-mixed file has notes rows (col 2 empty, scattered text in name
  # cols) and blank rows after the last priced/reserve roster row. These
  # would defeat backward-fill (no label below to inherit from), so we cut
  # them off first. This works because the slot label always appears on the
  # LAST row of each group, including the last group overall.
  slot_col_raw <- as.character(raw[[2]])
  nonempty_slot <- !is.na(slot_col_raw) & nzchar(trimws(slot_col_raw))
  if (!any(nonempty_slot[-(1:5)])) {
    cli::cli_abort(
      "No slot labels found in col 2 of {.file {path}}.",
      class = "rotostats_error_auction_slot_orphan"
    )
  }
  last_data_row <- max(which(nonempty_slot))
  raw <- raw[seq_len(last_data_row), , drop = FALSE]

  is_trailing_na <- vapply(raw, function(col) all(is.na(col)), logical(1))
  last_keep <- max(which(!is_trailing_na))
  raw <- raw[, seq_len(last_keep), drop = FALSE]

  # In the 2012-mixed layout col 1 is an empty placeholder and col 2 holds
  # the slot - both above and beyond the per-team (name, price) pairs.
  expected_cols <- 2L + 2L * expected_teams
  if (ncol(raw) != expected_cols) {
    cli::cli_abort(
      c("Wrong column count in {.file {path}}.",
        "i" = "Expected {expected_cols} columns ({expected_teams} teams in 2012-mixed layout), got {ncol(raw)}."),
      class = "rotostats_error_auction_col_count"
    )
  }

  # Validate row 1 is empty.
  row1_nonempty <- sum(!is.na(raw[1, ]) & nzchar(trimws(as.character(raw[1, ]))))
  if (row1_nonempty > 0) {
    cli::cli_abort(
      "2012-mixed parser expects row 1 empty in {.file {path}}, found {row1_nonempty} non-empty cells.",
      class = "rotostats_error_auction_row1_nonempty"
    )
  }

  # Validate meta rows: col 3 of rows 3-5 must match the meta labels.
  meta_labels <- c("Left to Spend", "Players Needed", "Max Bid")
  meta_actual <- vapply(3:5, function(i) as.character(raw[i, 3, drop = TRUE]), character(1))
  if (!identical(meta_actual, meta_labels)) {
    cli::cli_abort(
      c("Meta rows 3-5 do not match expected labels in {.file {path}}.",
        "i" = "Expected {.val {meta_labels}}, got {.val {meta_actual}}."),
      class = "rotostats_error_auction_meta_rows"
    )
  }

  # Owners are in row 2, odd columns 3, 5, ..., 2*expected_teams + 1.
  owner_cols <- seq(3L, by = 2L, length.out = expected_teams)
  owners_raw <- as.character(raw[2, owner_cols, drop = TRUE])
  owners <- vapply(owners_raw, .canonicalize_tw_owner, character(1))

  data_rows <- raw[-(1:5), , drop = FALSE]

  # Backward-fill position slot column (col 2). Trailing junk has already been
  # trimmed, so the last data row is guaranteed to have a non-empty slot.
  slot_raw <- as.character(data_rows[[2]])
  slot_filled <- slot_raw
  n <- length(slot_filled)
  if (n == 0L || is.na(slot_filled[n]) || !nzchar(trimws(slot_filled[n]))) {
    cli::cli_abort(
      "Last data row in {.file {path}} has empty position slot \u2014 cannot backward-fill.",
      class = "rotostats_error_auction_slot_orphan"
    )
  }
  for (i in rev(seq_len(n - 1L))) {
    if (is.na(slot_filled[i]) || !nzchar(trimws(slot_filled[i]))) {
      slot_filled[i] <- slot_filled[i + 1L]
    }
  }
  slot_filled <- trimws(slot_filled)

  # Drop reserve rows (and any other non-canonical slot) before price coercion;
  # reserve rows have empty price cells that would otherwise trip the integer
  # check.
  is_canonical <- slot_filled %in% .tw_canonical_slots
  data_rows <- data_rows[is_canonical, , drop = FALSE]
  slot_filled <- slot_filled[is_canonical]

  per_team <- lapply(seq_len(expected_teams), function(k) {
    name_col <- 2L * k + 1L
    price_col <- 2L * k + 2L
    tibble::tibble(
      team_owner    = owners[k],
      position_slot = slot_filled,
      player_name   = as.character(data_rows[[name_col]]),
      price_chr     = as.character(data_rows[[price_col]])
    )
  })
  long <- dplyr::bind_rows(per_team)

  long <- dplyr::filter(long, !is.na(.data$player_name) & nzchar(trimws(.data$player_name)))
  long$player_name <- trimws(long$player_name)

  price_int <- suppressWarnings(as.integer(long$price_chr))
  if (any(is.na(price_int)) || any(price_int < 0)) {
    bad <- long$price_chr[is.na(price_int) | (price_int < 0)]
    cli::cli_abort(
      c("Non-integer or negative prices in {.file {path}}.",
        "i" = "Offending values: {.val {bad}}."),
      class = "rotostats_error_auction_price"
    )
  }
  long$price <- price_int
  long$price_chr <- NULL

  .validate_tw_position_slots(long$position_slot, path)
  long$player_type <- .derive_player_type(long$position_slot)
  long$is_keeper <- FALSE

  long <- dplyr::arrange(
    long,
    .data$team_owner, .data$position_slot, dplyr::desc(.data$price)
  )

  long[, c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")]
}

#' Parse a 2012 AL or NL Tout Wars auction CSV.
#'
#' Layout deviation from standard:
#' - Owner row 1: owners in odd columns (1, 3, 5, ..., 23).
#' - Position slot in column 2 (not column 1).
#' - For team k: name at col 2k+1, price at col 2k+2.
#'
#' @keywords internal
#' @noRd
.parse_tw_auction_2012_alnl <- function(path, expected_teams) {
  raw <- readr::read_csv(
    path,
    col_types = readr::cols(.default = "c"),
    col_names = FALSE,
    progress = FALSE
  )

  if (nrow(raw) < 4L) {
    cli::cli_abort(
      "Too few rows in {.file {path}}; expected header + 3 meta rows + roster.",
      class = "rotostats_error_auction_meta_rows"
    )
  }

  # Filter rows: keep header (row 1) + meta rows (2-4) + priced-roster rows
  # only. Slot label lives in col 2 in the 2012-al/nl layout (not col 1).
  # Drops footer/notes rows AND reserve (R) rows.
  slot_col <- toupper(trimws(as.character(raw[[2]])))
  is_priced_roster <- !is.na(slot_col) & nzchar(slot_col) & slot_col %in% .tw_canonical_slots
  is_priced_roster[seq_len(4)] <- FALSE
  keep_rows <- c(seq_len(4), which(is_priced_roster))
  raw <- raw[keep_rows, , drop = FALSE]

  is_trailing_na <- vapply(raw, function(col) all(is.na(col)), logical(1))
  last_keep <- max(which(!is_trailing_na))
  raw <- raw[, seq_len(last_keep), drop = FALSE]

  # In the 2012-al/nl layout, owner is in col 1 and slot is in col 2 — both
  # are dedicated columns above and beyond the per-team (name, price) pairs.
  expected_cols <- 2L + 2L * expected_teams
  if (ncol(raw) != expected_cols) {
    cli::cli_abort(
      c("Wrong column count in {.file {path}}.",
        "i" = "Expected {expected_cols} columns ({expected_teams} teams in 2012 layout), got {ncol(raw)}."),
      class = "rotostats_error_auction_col_count"
    )
  }

  # Validate meta rows: col 3 of rows 2-4 must match the meta labels.
  meta_labels <- c("Left to Spend", "Players Needed", "Max Bid")
  meta_actual <- vapply(2:4, function(i) as.character(raw[i, 3, drop = TRUE]), character(1))
  if (!identical(meta_actual, meta_labels)) {
    cli::cli_abort(
      c("Meta rows 2-4 do not match expected labels in {.file {path}}.",
        "i" = "Expected {.val {meta_labels}}, got {.val {meta_actual}}."),
      class = "rotostats_error_auction_meta_rows"
    )
  }

  # Owners are in row 1, odd columns: 1, 3, 5, ..., 2*expected_teams - 1.
  owner_cols <- seq(1L, by = 2L, length.out = expected_teams)
  owners_raw <- as.character(raw[1, owner_cols, drop = TRUE])
  owners <- vapply(owners_raw, .canonicalize_tw_owner, character(1))

  # Data rows: row 5 onward (already filtered to priced-roster rows).
  # Position slot in col 2.
  data_rows <- raw[-(1:4), , drop = FALSE]

  per_team <- lapply(seq_len(expected_teams), function(k) {
    name_col <- 2L * k + 1L
    price_col <- 2L * k + 2L
    tibble::tibble(
      team_owner    = owners[k],
      position_slot = as.character(data_rows[[2]]),
      player_name   = as.character(data_rows[[name_col]]),
      price_chr     = as.character(data_rows[[price_col]])
    )
  })
  long <- dplyr::bind_rows(per_team)

  long <- dplyr::filter(long, !is.na(.data$player_name) & nzchar(trimws(.data$player_name)))
  long$player_name <- trimws(long$player_name)

  price_int <- suppressWarnings(as.integer(long$price_chr))
  if (any(is.na(price_int)) || any(price_int < 0)) {
    bad <- long$price_chr[is.na(price_int) | (price_int < 0)]
    cli::cli_abort(
      c("Non-integer or negative prices in {.file {path}}.",
        "i" = "Offending values: {.val {bad}}."),
      class = "rotostats_error_auction_price"
    )
  }
  long$price <- price_int
  long$price_chr <- NULL

  long$position_slot <- trimws(long$position_slot)
  .validate_tw_position_slots(long$position_slot, path)
  long$player_type <- .derive_player_type(long$position_slot)
  long$is_keeper <- FALSE

  long <- dplyr::arrange(
    long,
    .data$team_owner, .data$position_slot, dplyr::desc(.data$price)
  )

  long[, c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")]
}

#' Parse a 2021-al Tout Wars auction CSV.
#'
#' Layout:
#' - 2 leading structural columns: col 1 sparse "team owner ID" (mostly empty),
#'   col 2 = position slot.
#' - 12 × (player_name, price) pairs at cols 3..26.
#' - Owner row is row 1; owners at odd cols 3, 5, ..., 25.
#' - No meta rows (rows 2+ are immediately roster data).
#' - "O" abbreviation for "OF" appears in some slot cells (e.g., 4 outfield
#'   rows). Normalized to "OF" before canonical-slot filtering.
#'
#' @keywords internal
#' @noRd
.parse_tw_auction_2021_al <- function(path, expected_teams) {
  raw <- readr::read_csv(
    path,
    col_types = readr::cols(.default = "c"),
    col_names = FALSE,
    progress = FALSE
  )

  if (nrow(raw) < 1L) {
    cli::cli_abort(
      "Too few rows in {.file {path}}; expected owner row + roster.",
      class = "rotostats_error_auction_meta_rows"
    )
  }

  # Normalize "O" -> "OF" in col 2 before canonical-slot filtering.
  slot_raw <- toupper(trimws(as.character(raw[[2]])))
  slot_raw[!is.na(slot_raw) & slot_raw == "O"] <- "OF"
  raw[[2]] <- slot_raw

  # Filter rows: keep header row 1 + priced-roster rows from rows 2+.
  is_priced_roster <- !is.na(slot_raw) & nzchar(slot_raw) & slot_raw %in% .tw_canonical_slots
  is_priced_roster[1L] <- FALSE
  keep_rows <- c(1L, which(is_priced_roster))
  raw <- raw[keep_rows, , drop = FALSE]

  is_trailing_na <- vapply(raw, function(col) all(is.na(col)), logical(1))
  last_keep <- max(which(!is_trailing_na))
  raw <- raw[, seq_len(last_keep), drop = FALSE]

  expected_cols <- 2L + 2L * expected_teams
  if (ncol(raw) != expected_cols) {
    cli::cli_abort(
      c("Wrong column count in {.file {path}}.",
        "i" = "Expected {expected_cols} columns ({expected_teams} teams in 2021-al layout), got {ncol(raw)}."),
      class = "rotostats_error_auction_col_count"
    )
  }

  # Owners are in row 1, odd columns 3, 5, ..., 2*expected_teams + 1.
  owner_cols <- seq(3L, by = 2L, length.out = expected_teams)
  owners_raw <- as.character(raw[1, owner_cols, drop = TRUE])
  owners <- vapply(owners_raw, .canonicalize_tw_owner, character(1))

  data_rows <- raw[-1L, , drop = FALSE]

  per_team <- lapply(seq_len(expected_teams), function(k) {
    name_col <- 2L * k + 1L
    price_col <- 2L * k + 2L
    tibble::tibble(
      team_owner    = owners[k],
      position_slot = as.character(data_rows[[2]]),
      player_name   = as.character(data_rows[[name_col]]),
      price_chr     = as.character(data_rows[[price_col]])
    )
  })
  long <- dplyr::bind_rows(per_team)

  long <- dplyr::filter(long, !is.na(.data$player_name) & nzchar(trimws(.data$player_name)))
  long$player_name <- trimws(long$player_name)

  empty_price <- is.na(long$price_chr) | !nzchar(trimws(long$price_chr))
  if (any(empty_price)) {
    dropped <- long$player_name[empty_price]
    cli::cli_inform(c(
      "Dropping {sum(empty_price)} pick(s) with missing price in {.file {path}}.",
      "i" = "Affected player(s): {.val {dropped}}."
    ))
    long <- long[!empty_price, , drop = FALSE]
  }

  price_int <- suppressWarnings(as.integer(long$price_chr))
  if (any(is.na(price_int)) || any(price_int < 0)) {
    bad <- long$price_chr[is.na(price_int) | (price_int < 0)]
    cli::cli_abort(
      c("Non-integer or negative prices in {.file {path}}.",
        "i" = "Offending values: {.val {bad}}."),
      class = "rotostats_error_auction_price"
    )
  }
  long$price <- price_int
  long$price_chr <- NULL

  long$position_slot <- trimws(long$position_slot)
  .validate_tw_position_slots(long$position_slot, path)
  long$player_type <- .derive_player_type(long$position_slot)
  long$is_keeper <- FALSE

  long <- dplyr::arrange(
    long,
    .data$team_owner, .data$position_slot, dplyr::desc(.data$price)
  )

  long[, c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")]
}

# Maps (year, league) -> override parser function. Default is
# .parse_tw_auction_standard. Defined AFTER the parser functions so R can
# resolve the function objects at source time.
# 2015-nl was originally listed here, but readr handles its quoted-multiline
# fields natively (Task 5 verifies); so it is intentionally absent and routes
# to the standard parser by default.
.tw_auction_overrides <- list(
  "2012-al"    = .parse_tw_auction_2012_alnl,
  "2012-nl"    = .parse_tw_auction_2012_alnl,
  "2012-mixed" = .parse_tw_auction_2012_mixed,
  # 2021-nl, 2021-mixed and all three 2022 files use the standard layout but
  # omit the meta rows 2-4 (the file jumps directly from owners to roster
  # data).
  "2021-nl"    = function(path, expected_teams) {
    .parse_tw_auction_standard(path, expected_teams, has_meta_rows = FALSE)
  },
  "2021-mixed" = function(path, expected_teams) {
    .parse_tw_auction_standard(path, expected_teams, has_meta_rows = FALSE)
  },
  "2022-al"    = function(path, expected_teams) {
    .parse_tw_auction_standard(path, expected_teams, has_meta_rows = FALSE)
  },
  "2022-nl"    = function(path, expected_teams) {
    .parse_tw_auction_standard(path, expected_teams, has_meta_rows = FALSE)
  },
  "2022-mixed" = function(path, expected_teams) {
    .parse_tw_auction_standard(path, expected_teams, has_meta_rows = FALSE)
  },
  # 2021-al uses the 2012-alnl-style layout (slot in col 2, owners on odd
  # cols starting from col 3) but also omits meta rows.
  "2021-al"    = function(path, expected_teams) {
    .parse_tw_auction_2021_al(path, expected_teams)
  }
)

# Golden per-file row counts. Populated empirically after Stage 1's first
# clean run. Used by Stage 1 (in-script assertion) and Stage 2 (combined
# row-count assertion). Update when raw files change.
.tw_auction_row_counts <- c(
  "2012-al"    = 276L,
  "2012-mixed" = 345L,
  "2012-nl"    = 299L,
  "2013-al"    = 276L,
  "2013-mixed" = 345L,
  "2013-nl"    = 276L,
  "2014-al"    = 276L,
  "2014-mixed" = 345L,
  "2014-nl"    = 276L,
  "2015-al"    = 276L,
  "2015-mixed" = 345L,
  "2015-nl"    = 276L,
  "2016-al"    = 276L,
  "2016-mixed" = 345L,
  "2016-nl"    = 276L,
  "2017-al"    = 276L,
  "2017-mixed" = 343L,
  "2017-nl"    = 276L,
  "2018-al"    = 276L,
  "2018-mixed" = 345L,
  "2018-nl"    = 275L,
  "2019-al"    = 275L,
  "2019-mixed" = 345L,
  "2019-nl"    = 276L,
  "2020-al"    = 276L,
  "2020-mixed" = 345L,
  "2020-nl"    = 276L,
  "2021-al"    = 276L,
  "2021-mixed" = 345L,
  "2021-nl"    = 276L,
  "2022-al"    = 276L,
  "2022-mixed" = 345L,
  "2022-nl"    = 276L,
  "2023-al"    = 276L,
  "2023-mixed" = 345L,
  "2023-nl"    = 276L,
  "2024-al"    = 276L,
  "2024-mixed" = 345L,
  "2024-nl"    = 276L,
  "2025-al"    = 276L,
  "2025-mixed" = 345L,
  "2025-nl"    = 276L,
  "2026-al"    = 276L,
  "2026-mixed" = 345L,
  "2026-nl"    = 276L
)

# Default team count by league.
.tw_team_counts <- c(al = 12L, nl = 12L, mixed = 15L)

# Per-(year, league) team-count overrides for files that deviate from the
# default. 2012 NL ran with 13 teams instead of the usual 12.
.tw_team_count_overrides <- list("2012-nl" = 13L)

#' Normalize a single Tout Wars auction CSV via dispatch on (year, league).
#'
#' @param path Path to raw CSV.
#' @param year Integer.
#' @param league One of "al", "nl", "mixed".
#' @return Long-tidy tibble (Stage 1 schema).
#' @keywords internal
#' @noRd
.normalize_tw_auction <- function(path, year, league) {
  if (!league %in% names(.tw_team_counts)) {
    cli::cli_abort(
      "Unknown league {.val {league}} (expected one of {.val {names(.tw_team_counts)}}).",
      class = "rotostats_error_auction_unknown_league"
    )
  }
  key <- paste0(year, "-", league)
  expected_teams <- .tw_team_count_overrides[[key]]
  if (is.null(expected_teams)) expected_teams <- .tw_team_counts[[league]]
  parser <- .tw_auction_overrides[[key]]
  if (is.null(parser)) parser <- .parse_tw_auction_standard
  parser(path, expected_teams = expected_teams)
}
