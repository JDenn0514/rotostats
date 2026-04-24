# get-projections-internal.R — private helpers for get_projections()
#
# No exports. Each function has one job so the exported orchestrator in
# R/get-projections.R stays readable and the HTTP boundary stays isolated.

#' @noRd
.current_season_year <- function() {
  as.integer(format(Sys.Date(), "%Y"))
}

#' @noRd
VALID_PROJECTION_SOURCES <- c(
  "steamer", "zips", "atc", "fangraphsdc",
  "thebat", "thebatx", "custom"
)

#' @noRd
.validate_source <- function(source) {
  if (!is.character(source) || length(source) != 1L || is.na(source) ||
      !(source %in% VALID_PROJECTION_SOURCES)) {
    cli::cli_abort(
      c(
        "{.arg source} must be one of {.val {VALID_PROJECTION_SOURCES}}.",
        i = "Received: {.val {source}}."
      ),
      class = "rotostats_error_invalid_source"
    )
  }
  source
}
