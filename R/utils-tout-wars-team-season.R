# Internal helpers for tout_wars_team_season.
# See plans/specs/2026-04-27-tout-wars-team-season-design.md.

# Required columns per side. Used for column validation in the readers.
.tw_ts_batter_required_cols <- c(
  "year", "league", "team", "player_name", "player_id",
  "mlb_team", "position", "salary", "status", "roster_section",
  "eligibility", "ab", "g", "r", "hr", "rbi", "sb", "so",
  "bb", "avg", "obp", "slg"
)

.tw_ts_pitcher_required_cols <- c(
  "year", "league", "team", "player_name", "player_id",
  "mlb_team", "position", "salary", "status", "roster_section",
  "eligibility", "g", "w", "l", "sv", "ip", "bb", "hr",
  "so", "era", "whip"
)

#' Validate a per-team CSV has the required columns.
#'
#' @param df Tibble loaded from a roster CSV.
#' @param required Character vector of required column names.
#' @param path Source path (for error message).
#' @keywords internal
#' @noRd
.validate_tw_ts_columns <- function(df, required, path) {
  missing <- setdiff(required, names(df))
  if (length(missing) > 0L) {
    cli::cli_abort(
      c(
        "Required column(s) missing from {.file {basename(path)}}.",
        "i" = "Missing: {.val {missing}}"
      ),
      class = "rotostats_error_team_season_missing_column"
    )
  }
  invisible(df)
}

#' Read a per-team batter CSV.
#'
#' @param path Path to `{year}-{league}-batters.csv`.
#' @return Tibble with the columns in `.tw_ts_batter_required_cols`.
#' @keywords internal
#' @noRd
.read_tw_batters <- function(path) {
  df <- readr::read_csv(
    path,
    col_types = readr::cols(
      year           = readr::col_integer(),
      league         = readr::col_character(),
      team           = readr::col_character(),
      player_name    = readr::col_character(),
      player_id      = readr::col_character(),
      mlb_team       = readr::col_character(),
      position       = readr::col_character(),
      salary         = readr::col_integer(),
      status         = readr::col_character(),
      roster_section = readr::col_character(),
      eligibility    = readr::col_character(),
      ab             = readr::col_integer(),
      g              = readr::col_integer(),
      r              = readr::col_integer(),
      hr             = readr::col_integer(),
      rbi            = readr::col_integer(),
      sb             = readr::col_integer(),
      so             = readr::col_integer(),
      bb             = readr::col_integer(),
      avg            = readr::col_double(),
      obp            = readr::col_double(),
      slg            = readr::col_double(),
      .default       = readr::col_character()
    ),
    progress = FALSE
  )
  .validate_tw_ts_columns(df, .tw_ts_batter_required_cols, path)
  df
}

#' Read a per-team pitcher CSV.
#'
#' @param path Path to `{year}-{league}-pitchers.csv`.
#' @return Tibble with the columns in `.tw_ts_pitcher_required_cols`.
#' @keywords internal
#' @noRd
.read_tw_pitchers <- function(path) {
  df <- readr::read_csv(
    path,
    col_types = readr::cols(
      year           = readr::col_integer(),
      league         = readr::col_character(),
      team           = readr::col_character(),
      player_name    = readr::col_character(),
      player_id      = readr::col_character(),
      mlb_team       = readr::col_character(),
      position       = readr::col_character(),
      salary         = readr::col_integer(),
      status         = readr::col_character(),
      roster_section = readr::col_character(),
      eligibility    = readr::col_character(),
      g              = readr::col_integer(),
      w              = readr::col_integer(),
      l              = readr::col_integer(),
      sv             = readr::col_integer(),
      ip             = readr::col_double(),
      bb             = readr::col_integer(),
      hr             = readr::col_integer(),
      so             = readr::col_integer(),
      era            = readr::col_double(),
      whip           = readr::col_double(),
      .default       = readr::col_character()
    ),
    progress = FALSE
  )
  .validate_tw_ts_columns(df, .tw_ts_pitcher_required_cols, path)
  df
}

.tw_ts_valid_sections <- c(
  "active", "reserved", "previously_active", "previously_reserved"
)

.tw_ts_kept_sections <- c("active", "previously_active")

#' Filter rows to roster sections that contributed to team standings totals.
#'
#' Keeps `active` and `previously_active`. Drops `reserved` and
#' `previously_reserved`. See spec section "Section selection" for rationale.
#'
#' @param df Tibble with a `roster_section` column.
#' @return Tibble filtered to kept sections.
#' @keywords internal
#' @noRd
.filter_active_sections <- function(df) {
  unknown <- setdiff(unique(df$roster_section), .tw_ts_valid_sections)
  if (length(unknown) > 0L) {
    valid <- .tw_ts_valid_sections
    cli::cli_abort(
      c(
        "Unknown {.code roster_section} value(s).",
        "i" = "Unknown: {.val {unknown}}",
        "i" = "Expected one of: {.val {valid}}"
      ),
      class = "rotostats_error_team_season_unknown_section"
    )
  }
  df[df$roster_section %in% .tw_ts_kept_sections, , drop = FALSE]
}
