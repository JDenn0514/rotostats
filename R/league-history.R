# league_history() — historical league data
#
# Holds only historical data (team-season totals and optional auction prices).
# Structural league settings live in league_config(). Window and exclusion
# decisions live as arguments on sgp_denominators() / replacement_level().

# ---------------------------------------------------------------------------
# Main constructor
# ---------------------------------------------------------------------------

#' Historical league data for rotisserie valuation
#'
#' @description
#' Builds a validated S3 list that holds team-season category totals and,
#' optionally, historical auction prices. Passed as `league_history` to
#' [sgp_denominators()] and `replacement_level()`. Construct once and reuse.
#'
#' Holds only historical data. Window and exclusion choices remain as
#' arguments on the consumer (`exclude_years`, `outlier_filter`, `years`).
#' The exception is `prices`: no window parameter is provided, so the caller
#' must pre-filter prices to the desired years (e.g., exclude 2020).
#'
#' @param team_season A data frame in wide format, one row per team-year, with
#'   columns `year`, `team_id`, and one column per scored category. Stat
#'   column names are normalized to uppercase at construction.
#' @param prices Optional data frame of historical auction results with
#'   columns `year`, `player_name`, `price`, and optional `player_id`,
#'   `is_keeper`, `player_type`.
#'
#' @return An S3 object of class `c("league_history", "list")` with
#'   components `$team_season` and `$prices` (NULL if not supplied).
#'
#' @seealso [league_config()], [sgp_denominators()]
#' @export
#' @examples
#' ts <- data.frame(
#'   year    = rep(2022:2023, each = 2),
#'   team_id = rep(c("A", "B"), 2),
#'   HR      = c(180, 210, 190, 220)
#' )
#' h <- league_history(team_season = ts)
#' print(h)
league_history <- function(team_season, prices = NULL) {
  team_season <- validate_team_season(team_season)
  team_season <- normalize_history_columns(team_season)
  check_team_counts(team_season)
  check_na_stat_values(team_season)
  maybe_inform_2020(team_season)

  prices <- validate_prices(prices)

  structure(
    list(
      team_season = team_season,
      prices      = prices
    ),
    class = c("league_history", "list")
  )
}

# ---------------------------------------------------------------------------
# team_season validators
# ---------------------------------------------------------------------------

#' @noRd
validate_team_season <- function(ts) {
  if (!is.data.frame(ts)) {
    cli::cli_abort(
      "{.arg team_season} must be a data frame.",
      class = "rotostats_error_invalid_team_season"
    )
  }

  nm_lower <- tolower(names(ts))
  missing  <- setdiff(c("year", "team_id"), nm_lower)
  if (length(missing) > 0L) {
    cli::cli_abort(
      "{.arg team_season} is missing required column{?s}: {.val {missing}}.",
      class = "rotostats_error_missing_team_season_column"
    )
  }

  year_idx <- match("year", nm_lower)
  year_raw <- ts[[year_idx]]
  year_coerced <- suppressWarnings(as.integer(year_raw))
  if (anyNA(year_coerced) && !anyNA(year_raw)) {
    cli::cli_abort(
      c(
        "{.arg team_season$year} is not coercible to integer.",
        "i" = "Supply year as integer (e.g., {.val 2023L}), not a character label."
      ),
      class = "rotostats_error_invalid_team_season_year"
    )
  }
  ts[[year_idx]] <- year_coerced

  team_idx <- match("team_id", nm_lower)
  team_raw <- ts[[team_idx]]
  if (is.factor(team_raw)) {
    ts[[team_idx]] <- as.character(team_raw)
  } else if (!is.character(team_raw)) {
    cli::cli_abort(
      "{.arg team_season$team_id} must be character (or factor).",
      class = "rotostats_error_invalid_team_season_team_id"
    )
  }

  ts
}

#' @noRd
normalize_history_columns <- function(ts) {
  original <- names(ts)
  upper    <- toupper(original)
  if (!identical(original, upper)) {
    changed <- original != upper
    cli::cli_inform(
      c(
        "Normalizing {sum(changed)} column name{?s} to uppercase.",
        "i" = "{.val {original[changed]}} -> {.val {upper[changed]}}"
      ),
      class = "rotostats_info_history_column_normalized"
    )
    names(ts) <- upper
  }
  ts
}

#' @noRd
check_team_counts <- function(ts) {
  counts   <- table(ts$YEAR)
  if (length(counts) <= 1L) return(invisible(NULL))
  if (length(unique(counts)) > 1L) {
    years <- names(counts)
    pairs <- paste0(years, "=", as.integer(counts), collapse = ", ")
    cli::cli_warn(
      c(
        "Team count varies across years in {.arg team_season}.",
        "i" = "Per-year team counts: {pairs}."
      ),
      class = "rotostats_warning_inconsistent_team_count"
    )
  }
  invisible(NULL)
}

#' @noRd
check_na_stat_values <- function(ts) {
  id_cols    <- c("YEAR", "TEAM_ID")
  stat_cols  <- setdiff(names(ts), id_cols)
  if (length(stat_cols) == 0L) return(invisible(NULL))
  na_mask <- vapply(ts[stat_cols], anyNA, logical(1L))
  if (!any(na_mask)) return(invisible(NULL))
  bad_cols <- stat_cols[na_mask]
  rows     <- which(
    Reduce(`|`, lapply(ts[bad_cols], is.na))
  )
  pairs <- paste(
    sprintf("%s/%s", ts$YEAR[rows], ts$TEAM_ID[rows]),
    collapse = ", "
  )
  cli::cli_warn(
    c(
      "NA values in stat column{?s} {.val {bad_cols}}.",
      "i" = "Affected team-year{?s}: {pairs}."
    ),
    class = "rotostats_warning_na_stat_value"
  )
  invisible(NULL)
}

#' @noRd
maybe_inform_2020 <- function(ts) {
  if (!(2020L %in% ts$YEAR)) return(invisible(NULL))
  cli::cli_inform(
    c(
      "{.val 2020} present in {.arg team_season$year}.",
      "i" = "Consider {.code exclude_years = 2020L} in {.fn sgp_denominators}."
    ),
    class = "rotostats_info_2020_present"
  )
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# prices validators
# ---------------------------------------------------------------------------

#' @noRd
validate_prices <- function(prices) {
  if (is.null(prices)) return(NULL)

  if (!is.data.frame(prices)) {
    cli::cli_abort(
      "{.arg prices} must be a data frame or {.code NULL}.",
      class = "rotostats_error_invalid_prices"
    )
  }

  required <- c("year", "player_name", "price")
  missing  <- setdiff(required, names(prices))
  if (length(missing) > 0L) {
    cli::cli_abort(
      "{.arg prices} is missing required column{?s}: {.val {missing}}.",
      class = "rotostats_error_missing_prices_column"
    )
  }

  if (any(is.finite(prices$price) & prices$price < 0)) {
    bad   <- which(is.finite(prices$price) & prices$price < 0)
    n_bad <- length(bad)
    cli::cli_warn(
      c(
        "Negative {.field price} in {.arg prices}: {n_bad} row{?s}.",
        "i" = "Row indices: {.val {bad}}."
      ),
      class = "rotostats_warning_negative_price"
    )
  }

  if ("player_type" %in% names(prices)) {
    raw   <- prices$player_type
    lower <- tolower(raw)
    if (!identical(raw, lower)) {
      cli::cli_inform(
        c(
          "Normalizing {.field player_type} values to lowercase.",
          "i" = "Accepted values: {.val batter}, {.val pitcher}."
        ),
        class = "rotostats_info_player_type_normalized"
      )
    }
    prices$player_type <- lower
  }

  prices
}

# ---------------------------------------------------------------------------
# Print method
# ---------------------------------------------------------------------------

#' Print method for league_history objects
#'
#' @param x A `league_history` object from [league_history()].
#' @param ... Ignored.
#'
#' @return `x`, invisibly.
#'
#' @method print league_history
#' @export
print.league_history <- function(x, ...) {
  cat("League history\n")
  ts        <- x$team_season
  years     <- sort(unique(ts$YEAR))
  n_teams   <- length(unique(ts$TEAM_ID))
  year_span <- if (length(years) > 1L) {
    sprintf("%d-%d", min(years), max(years))
  } else {
    as.character(years)
  }
  cat(sprintf("  Team seasons: %d teams x %d year(s) (%s)\n",
              n_teams, length(years), year_span))
  stat_cols <- setdiff(names(ts), c("YEAR", "TEAM_ID"))
  cat(sprintf("  Stat columns: %s  (%d cols)\n",
              paste(stat_cols, collapse = " "),
              length(stat_cols)))
  if (!is.null(x$prices)) {
    pr_years <- sort(unique(x$prices$year))
    pr_span  <- if (length(pr_years) > 1L) {
      sprintf("%d-%d", min(pr_years), max(pr_years))
    } else {
      as.character(pr_years)
    }
    cat(sprintf("  Prices:       %s player-seasons (%s)\n",
                format(nrow(x$prices), big.mark = ","), pr_span))
  }
  if (2020L %in% years) {
    cat("  Note:         2020 present - consider exclude_years = 2020L\n")
  }
  invisible(x)
}
