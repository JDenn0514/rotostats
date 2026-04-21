# inverse-categories.R — package-level lower-is-better category lookup
#
# Exports:
#   inverse_categories()    (function; returns INVERSE_CATEGORIES)

# ---------------------------------------------------------------------------
# Internal constant
# ---------------------------------------------------------------------------

#' @noRd
INVERSE_CATEGORIES <- c(
  "ERA", "WHIP", "FIP", "xFIP", "SIERA", "xERA", "BB/9", "HR/9"
)

# ---------------------------------------------------------------------------
# Exported function: inverse_categories()
# ---------------------------------------------------------------------------

#' Built-in inverse-category lookup
#'
#' @description
#' Returns the character vector of scoring categories where a lower value
#' corresponds to better standings performance (lower-is-better categories).
#' Used as the Layer-3 fallback in [sgp_denominators()] when neither a
#' per-call override nor a [league_config()] declaration is present.
#'
#' @details
#' The built-in list covers pitcher ratio stats: ERA, WHIP, FIP, xFIP,
#' SIERA, xERA, BB/9, HR/9. Higher-is-better pitching categories (K/9, K%,
#' K-BB%) are NOT included. Declare a custom set via
#' [league_config()]'s `inverse_categories` argument and pass the config
#' to [sgp_denominators()].
#'
#' @return A character vector of category names (all uppercase). The exact
#'   contents are the package's current starter list; use [league_config()]
#'   to override for a specific league.
#'
#' @seealso [league_config()], [sgp_denominators()]
#'
#' @examples
#' inverse_categories()
#'
#' @export
inverse_categories <- function() INVERSE_CATEGORIES
