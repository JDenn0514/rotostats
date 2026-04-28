# Internal helpers for tout_wars_team_season.
# See plans/specs/2026-04-27-tout-wars-team-season-design.md.

# Required columns per side. Used for column validation in the readers.
.tw_ts_batter_required_cols <- c(
  "year", "league", "team", "player_name", "player_id",
  "mlb_team", "position", "salary", "status", "roster_section",
  "eligibility", "ab", "h", "g", "r", "hr", "rbi", "sb", "so",
  "bb", "obp", "slg"
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
      h              = readr::col_integer(),
      g              = readr::col_integer(),
      r              = readr::col_integer(),
      hr             = readr::col_integer(),
      rbi            = readr::col_integer(),
      sb             = readr::col_integer(),
      so             = readr::col_integer(),
      bb             = readr::col_integer(),
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

#' Aggregate batter rows to per-team-season totals.
#'
#' Sums AB, H, BB, SO directly from the per-player stats. Output columns:
#' year, league, team, ab, h_bat, bb_bat, so_bat.
#'
#' @param df Tibble of batter rows (one per player-team-season).
#' @return Tibble grouped by (year, league, team).
#' @keywords internal
#' @noRd
.aggregate_team_batting <- function(df) {
  dplyr::summarise(
    dplyr::group_by(df, .data$year, .data$league, .data$team),
    ab     = sum(.data$ab),
    h_bat  = sum(.data$h),
    bb_bat = sum(.data$bb),
    so_bat = sum(.data$so),
    .groups = "drop"
  )
}

#' Aggregate pitcher rows to per-team-season totals.
#'
#' Sums IP and BB directly. Reconstructs ER via per-player
#' `round(ip * era / 9)` and H via per-player `round(ip * whip) - bb`. All
#' reconstructions match Onroto's two-digit ERA / three-digit WHIP display.
#'
#' @param df Tibble of pitcher rows.
#' @return Tibble grouped by (year, league, team).
#' @keywords internal
#' @noRd
.aggregate_team_pitching <- function(df) {
  df$er_eq_row <- as.integer(round(df$ip * df$era / 9))
  df$h_eq_row  <- as.integer(round(df$ip * df$whip)) - df$bb
  out <- dplyr::summarise(
    dplyr::group_by(df, .data$year, .data$league, .data$team),
    ip       = sum(.data$ip),
    bb_pit   = sum(.data$bb),
    er_eq    = sum(.data$er_eq_row),
    h_pit_eq = sum(.data$h_eq_row),
    .groups  = "drop"
  )
  out
}

# Reconciliation tolerances. AVG/OBP in batting average units, ERA in
# earned-runs-per-9, WHIP in walks-and-hits-per-IP units. See spec for
# justification.
.tw_ts_tolerances <- list(
  avg  = 0.005,
  obp  = 0.005,
  era  = 0.15,
  whip = 0.020
)

#' Compute residuals between roster-reconstructed and standings rate stats.
#'
#' Operates on a joined frame that already carries both the standings rate
#' columns (`AVG`, `OBP`, `ERA`, `WHIP`; uppercase to match the standings
#' schema) and the per-team aggregated counters (`ab`, `h_bat`, `bb_bat`,
#' `ip`, `er_eq`, `h_pit_eq`, `bb_pit`).
#'
#' OBP reconciliation runs in degraded mode (no HBP / SF available from the
#' scraper output): `(H + BB) / (AB + BB)`. Tolerance accounts for the
#' degraded denominator.
#'
#' Returns a tibble with one row per input row, augmented with residual
#' columns and a `flagged` logical (TRUE if any residual exceeds tolerance).
#' NA in a standings rate (e.g., AVG when only OBP was scored that
#' league-year) propagates to NA in that residual and is excluded from the
#' tolerance check.
#'
#' @param joined Tibble. See description.
#' @return Tibble with added columns: avg_resid, obp_resid, era_resid,
#'   whip_resid, flagged.
#' @keywords internal
#' @noRd
.compute_team_residuals <- function(joined) {
  joined_avg  <- joined$h_bat / joined$ab
  joined_obp  <- (joined$h_bat + joined$bb_bat) / (joined$ab + joined$bb_bat)
  joined_era  <- joined$er_eq * 9 / joined$ip
  joined_whip <- (joined$bb_pit + joined$h_pit_eq) / joined$ip

  joined$avg_resid  <- abs(joined_avg  - joined$AVG)
  joined$obp_resid  <- abs(joined_obp  - joined$OBP)
  joined$era_resid  <- abs(joined_era  - joined$ERA)
  joined$whip_resid <- abs(joined_whip - joined$WHIP)

  flag_avg  <- !is.na(joined$avg_resid)  & joined$avg_resid  > .tw_ts_tolerances$avg
  flag_obp  <- !is.na(joined$obp_resid)  & joined$obp_resid  > .tw_ts_tolerances$obp
  flag_era  <- !is.na(joined$era_resid)  & joined$era_resid  > .tw_ts_tolerances$era
  flag_whip <- !is.na(joined$whip_resid) & joined$whip_resid > .tw_ts_tolerances$whip

  joined$flagged <- flag_avg | flag_obp | flag_era | flag_whip
  joined
}

.tw_ts_standings_cat_cols <- c(
  "R", "HR", "RBI", "SB", "OBP", "AVG",
  "W", "SV", "ERA", "WHIP", "SO"
)

.tw_ts_standings_pts_cols <- c(
  "R_pts", "HR_pts", "RBI_pts", "SB_pts", "OBP_pts", "AVG_pts",
  "W_pts", "SV_pts", "ERA_pts", "WHIP_pts", "SO_pts", "total_pts"
)

#' Read a Tout Wars standings CSV.
#'
#' Source schema: `year, league, team, R, R_pts, HR, HR_pts, ..., SO, SO_pts, total_pts`.
#' Categories are kept in their source case (uppercase) so they match the
#' team_season output schema.
#'
#' @param path Path to `{year}-{league}.csv` under standings/.
#' @return Tibble with one row per team-season.
#' @keywords internal
#' @noRd
.read_tw_standings <- function(path) {
  # Counting cats are integers; rate cats and all _pts are doubles.
  col_specs <- list(
    year       = readr::col_integer(),
    league     = readr::col_character(),
    team       = readr::col_character(),
    R          = readr::col_integer(),
    R_pts      = readr::col_double(),
    HR         = readr::col_integer(),
    HR_pts     = readr::col_double(),
    RBI        = readr::col_integer(),
    RBI_pts    = readr::col_double(),
    SB         = readr::col_integer(),
    SB_pts     = readr::col_double(),
    OBP        = readr::col_double(),
    OBP_pts    = readr::col_double(),
    AVG        = readr::col_double(),
    AVG_pts    = readr::col_double(),
    W          = readr::col_integer(),
    W_pts      = readr::col_double(),
    SV         = readr::col_integer(),
    SV_pts     = readr::col_double(),
    ERA        = readr::col_double(),
    ERA_pts    = readr::col_double(),
    WHIP       = readr::col_double(),
    WHIP_pts   = readr::col_double(),
    SO         = readr::col_integer(),
    SO_pts     = readr::col_double(),
    total_pts  = readr::col_double()
  )
  df <- readr::read_csv(
    path,
    col_types = do.call(readr::cols, col_specs),
    progress  = FALSE
  )
  required <- c("year", "league", "team",
                .tw_ts_standings_cat_cols, .tw_ts_standings_pts_cols)
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
  df
}
