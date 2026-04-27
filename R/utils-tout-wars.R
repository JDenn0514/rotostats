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
.parse_tw_auction_standard <- function(path, expected_teams) {
  raw <- readr::read_csv(
    path,
    col_types = readr::cols(.default = "c"),
    col_names = FALSE,
    progress = FALSE
  )

  # Trim trailing all-NA columns.
  is_trailing_na <- vapply(raw, function(col) all(is.na(col)), logical(1))
  last_keep <- max(which(!is_trailing_na))
  raw <- raw[, seq_len(last_keep), drop = FALSE]

  expected_cols <- 1L + 2L * expected_teams
  if (ncol(raw) != expected_cols) {
    cli::cli_abort(
      c("Wrong column count in {.file {path}}.",
        "i" = "Expected {expected_cols} columns ({expected_teams} teams), got {ncol(raw)}."),
      class = "rotostats_error_auction_col_count"
    )
  }

  # Validate meta rows (rows 2-4): col 2 of each must start with the labels.
  meta_labels <- c("Left to Spend", "Players Needed", "Max Bid")
  meta_actual <- vapply(2:4, function(i) as.character(raw[i, 2, drop = TRUE]), character(1))
  if (!identical(meta_actual, meta_labels)) {
    cli::cli_abort(
      c("Meta rows 2-4 do not match expected labels in {.file {path}}.",
        "i" = "Expected {.val {meta_labels}}, got {.val {meta_actual}}."),
      class = "rotostats_error_auction_meta_rows"
    )
  }

  # Extract owners from row 1, even cols (2, 4, 6, ...).
  owner_cols <- seq(2L, by = 2L, length.out = expected_teams)
  owners_raw <- as.character(raw[1, owner_cols, drop = TRUE])
  owners <- vapply(owners_raw, .canonicalize_tw_owner, character(1))

  # Data rows: row 5 onward.
  data_rows <- raw[-(1:4), , drop = FALSE]

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
  long$player_type <- .derive_player_type(long$position_slot)
  long$is_keeper <- FALSE

  long <- dplyr::arrange(
    long,
    .data$team_owner, .data$position_slot, dplyr::desc(.data$price)
  )

  long[, c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")]
}
