# get-projections-internal.R — private helpers for get_projections()
#
# No exports. Each function has one job so the exported orchestrator in
# R/get-projections.R stays readable and the HTTP boundary stays isolated.

#' @noRd
.current_season_year <- function() {
  as.integer(format(Sys.Date(), "%Y"))
}
