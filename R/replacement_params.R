# replacement_params.R — exported defaults and rate-stat denominator lookup
#
# Exports:
#   default_replacement_params  (named list)
#   rate_stat_denominators()    (function; returns RATE_STAT_DENOMINATORS)

# ---------------------------------------------------------------------------
# Internal constant
# ---------------------------------------------------------------------------

#' @noRd
RATE_STAT_DENOMINATORS <- c(
  AVG   = "AB",  OBP   = "PA",   SLG   = "AB",   OPS   = "PA",
  ERA   = "IP",  WHIP  = "IP",  "K/9" = "IP",  "BB/9" = "IP",  "HR/9" = "IP",
  SVHD  = "G",   QS    = "GS",
  "K%"  = "PA", "BB%" = "PA",
  wOBA  = "PA",  xFIP  = "IP",  SIERA = "IP",   FIP   = "IP",
  BABIP = "AB"
)

# ---------------------------------------------------------------------------
# Exported list: default_replacement_params
# ---------------------------------------------------------------------------

#' Default parameters for replacement_level()
#'
#' @description
#' Named list of all numeric constants used by `replacement_level()`.
#' Override specific entries via `replacement_params = list(band_width_K = 2L)`.
#'
#' @format A named list with nine elements: `band_width_K` (integer, default
#'   3L, band half-width K), `cliff_threshold` (numeric, default 1.5, MAD
#'   threshold multiplier), `cliff_min_n` (integer, default 4L, minimum lower
#'   band players for cliff detection), `sp_ip_threshold` (numeric, default
#'   100, IP cutoff for SP vs. RP inference), `sp_rp_split_default` (named
#'   numeric, default c(SP=0.60, RP=0.40)), `ip_ab_divergence_tol` (numeric,
#'   default 0.15, fractional IP/AB divergence tolerance),
#'   `calibration_min_n` (integer, default 15L, minimum dollar-one pool
#'   size), `convergence_eps` (numeric, default 0.01, SGP convergence
#'   tolerance), `convergence_max_iter` (integer, default 25L, max passes).
#'
#' @seealso `replacement_level()`, `rate_stat_denominators()`
#'
#' @export
default_replacement_params <- list(
  band_width_K          = 3L,
  cliff_threshold       = 1.5,
  cliff_min_n           = 4L,
  sp_ip_threshold       = 100,
  sp_rp_split_default   = c(SP = 0.60, RP = 0.40),
  ip_ab_divergence_tol  = 0.15,
  calibration_min_n     = 15L,
  convergence_eps       = 0.01,
  convergence_max_iter  = 25L
)

# ---------------------------------------------------------------------------
# Exported function: rate_stat_denominators()
# ---------------------------------------------------------------------------

#' Built-in rate-stat denominator lookup
#'
#' @description
#' Returns the named character vector mapping rate-stat category names to
#' their denominator column (e.g., `ERA -> "IP"`, `AVG -> "AB"`). Supply
#' `rate_denominators` to [replacement_level()] to add or override entries.
#'
#' @details
#' The built-in lookup covers all standard rotisserie rate stats. For any
#' rate stat not in this lookup, [replacement_level()] aborts with
#' `rotostats_error_unknown_rate_stat` and suggests supplying the denominator
#' via `rate_denominators = c(MyStat = "PA")`.
#'
#' @return A named character vector. Names are rate-stat category names;
#'   values are the denominator column name in the `projections` data frame.
#'
#' @seealso [replacement_level()], [default_replacement_params]
#'
#' @examples
#' rate_stat_denominators()
#'
#' @export
rate_stat_denominators <- function() {
  RATE_STAT_DENOMINATORS
}
