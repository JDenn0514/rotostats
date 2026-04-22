# rate-stat-formulas.R — registry + accessor for blended-pool rate-stat formulas
#
# Exports:
#   rate_stat_formulas()   (function; returns RATE_STAT_FORMULAS)
#
# Internal:
#   RATE_STAT_FORMULAS         (named list of formula descriptors)
#   .validate_rate_stat_formulas() (override validator)
#   .sgp_col_name()            (SGP column-name sanitizer)

# ---------------------------------------------------------------------------
# Internal constant
# ---------------------------------------------------------------------------

#' @noRd
RATE_STAT_FORMULAS <- list(
  ERA = list(
    denominator_col = "IP",
    scale = 9,
    numerator_fn = function(rate, denom) rate * denom / 9,
    direction = "inverse",
    pool_type = "pitcher"
  ),
  WHIP = list(
    denominator_col = "IP",
    scale = 1,
    numerator_fn = function(rate, denom) rate * denom,
    direction = "inverse",
    pool_type = "pitcher"
  ),
  AVG = list(
    denominator_col = "AB",
    scale = 1,
    numerator_fn = function(rate, denom) rate * denom,
    direction = "standard",
    pool_type = "hitter"
  ),
  FIP = list(
    denominator_col = "IP",
    scale = 1,
    numerator_fn = function(rate, denom) rate * denom,
    direction = "inverse",
    pool_type = "pitcher"
  ),
  XFIP = list(
    denominator_col = "IP",
    scale = 1,
    numerator_fn = function(rate, denom) rate * denom,
    direction = "inverse",
    pool_type = "pitcher"
  ),
  SIERA = list(
    denominator_col = "IP",
    scale = 1,
    numerator_fn = function(rate, denom) rate * denom,
    direction = "inverse",
    pool_type = "pitcher"
  ),
  XERA = list(
    denominator_col = "IP",
    scale = 1,
    numerator_fn = function(rate, denom) rate * denom,
    direction = "inverse",
    pool_type = "pitcher"
  ),
  "K/9" = list(
    denominator_col = "IP",
    scale = 9,
    numerator_fn = function(rate, denom) rate * denom / 9,
    direction = "standard",
    pool_type = "pitcher"
  ),
  "BB/9" = list(
    denominator_col = "IP",
    scale = 9,
    numerator_fn = function(rate, denom) rate * denom / 9,
    direction = "inverse",
    pool_type = "pitcher"
  ),
  "HR/9" = list(
    denominator_col = "IP",
    scale = 9,
    numerator_fn = function(rate, denom) rate * denom / 9,
    direction = "inverse",
    pool_type = "pitcher"
  )
)

# ---------------------------------------------------------------------------
# Exported function: rate_stat_formulas()
# ---------------------------------------------------------------------------

#' Built-in blended-pool rate-stat formula registry
#'
#' @description
#' Returns the named list of blended-pool formula descriptors consumed by
#' [sgp()] for linear rate stats. Each entry describes how to turn a player's
#' per-IP (or per-AB) rate into a poolable numerator, how to blend the player
#' into the team pool, and which direction (higher-is-better vs lower-is-
#' better) the resulting SGP takes.
#'
#' @details
#' Each entry is a list with five fields:
#'
#' \describe{
#'   \item{`denominator_col`}{Character scalar. Name of the playing-time
#'     column in `projections` used both as numerator weight and as pool
#'     denominator (e.g., `"IP"` for pitcher rate stats, `"AB"` for AVG).}
#'   \item{`scale`}{Numeric scalar. Multiplicative factor applied when
#'     recomposing the blended rate from the summed numerator and summed
#'     denominator. For ERA and the per-9 stats the scale is `9`; for WHIP,
#'     AVG, FIP, xFIP, SIERA, and xERA the scale is `1`.}
#'   \item{`numerator_fn`}{Function `function(rate, denom) -> numeric`.
#'     Turns a player's rate and playing-time values into the poolable
#'     numerator (e.g., `ER = ERA * IP / 9`).}
#'   \item{`direction`}{Character scalar. Either `"inverse"` (lower is
#'     better — ERA, WHIP, FIP, xFIP, SIERA, xERA, BB/9, HR/9) or
#'     `"standard"` (higher is better — AVG, K/9). Controls the subtraction
#'     order in the blended-pool SGP formula.}
#'   \item{`pool_type`}{Character scalar. Either `"pitcher"` (pool sized from
#'     `pool_sizes(config)$pitchers` and selected by descending IP) or
#'     `"hitter"` (pool sized from `pool_sizes(config)$hitters` and selected
#'     by descending AB or the entry's `denominator_col`).}
#' }
#'
#' Pass a list of the same shape as `rate_stat_formulas` to [sgp()] to
#' **fully replace** the default registry (for instance to add a custom
#' linear rate stat). The replacement semantics are intentionally symmetric
#' with [sgp_denominators()]'s `inverse_categories` argument: a user override
#' defines the entire effective set, not an augmentation of the package
#' default. Pass `NULL` (the default) to use the package registry.
#'
#' @return A named list. Names are uppercase rate-stat category names (with
#'   `K/9`, `BB/9`, `HR/9` kept in their canonical slashed form); values are
#'   five-field lists as documented in Details.
#'
#' @seealso [sgp()], [rate_stat_denominators()]
#'
#' @examples
#' rate_stat_formulas()[["ERA"]]
#'
#' @export
rate_stat_formulas <- function() {
  RATE_STAT_FORMULAS
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Validate a user-supplied rate_stat_formulas override. Aborts with
# rotostats_error_invalid_rate_stat_formula if any entry is malformed.
# Returns the override with names uppercased (preserving slashes).
#' @noRd
.validate_rate_stat_formulas <- function(rsf) {
  if (!is.list(rsf) || is.null(names(rsf)) || any(!nzchar(names(rsf)))) {
    cli::cli_abort(
      "{.arg rate_stat_formulas} must be a named list.",
      class = "rotostats_error_invalid_rate_stat_formula"
    )
  }

  required_fields <- c(
    "denominator_col",
    "scale",
    "numerator_fn",
    "direction",
    "pool_type"
  )

  for (cat in names(rsf)) {
    entry <- rsf[[cat]]
    if (!is.list(entry)) {
      cli::cli_abort(
        "Entry {.val {cat}} in {.arg rate_stat_formulas} must be a list, not {.cls {class(entry)[1L]}}.",
        class = "rotostats_error_invalid_rate_stat_formula"
      )
    }
    missing_fields <- setdiff(required_fields, names(entry))
    if (length(missing_fields) > 0L) {
      cli::cli_abort(
        "Entry {.val {cat}} in {.arg rate_stat_formulas} is missing required field(s): {.val {missing_fields}}.",
        class = "rotostats_error_invalid_rate_stat_formula"
      )
    }
    if (
      !is.character(entry$denominator_col) ||
        length(entry$denominator_col) != 1L ||
        !nzchar(entry$denominator_col)
    ) {
      cli::cli_abort(
        "Entry {.val {cat}}: {.field denominator_col} must be a non-empty character scalar.",
        class = "rotostats_error_invalid_rate_stat_formula"
      )
    }
    if (
      !is.numeric(entry$scale) ||
        length(entry$scale) != 1L ||
        !is.finite(entry$scale)
    ) {
      cli::cli_abort(
        "Entry {.val {cat}}: {.field scale} must be a finite numeric scalar.",
        class = "rotostats_error_invalid_rate_stat_formula"
      )
    }
    if (!is.function(entry$numerator_fn)) {
      cli::cli_abort(
        "Entry {.val {cat}}: {.field numerator_fn} must be a function.",
        class = "rotostats_error_invalid_rate_stat_formula"
      )
    }
    if (
      !identical(entry$direction, "inverse") &&
        !identical(entry$direction, "standard")
    ) {
      cli::cli_abort(
        "Entry {.val {cat}}: {.field direction} must be {.val inverse} or {.val standard}, not {.val {entry$direction}}.",
        class = "rotostats_error_invalid_rate_stat_formula"
      )
    }
    if (
      !identical(entry$pool_type, "pitcher") &&
        !identical(entry$pool_type, "hitter")
    ) {
      cli::cli_abort(
        "Entry {.val {cat}}: {.field pool_type} must be {.val pitcher} or {.val hitter}, not {.val {entry$pool_type}}.",
        class = "rotostats_error_invalid_rate_stat_formula"
      )
    }
  }

  names(rsf) <- toupper(names(rsf))
  rsf
}

# Turn a category name into its SGP column name. Slash-containing names
# (K/9, BB/9, HR/9) become sgp_k_per_9 etc.; non-slash names preserve case
# (sgp_HR, sgp_ERA) for backward compatibility.
#' @noRd
.sgp_col_name <- function(cats) {
  has_slash <- grepl("/", cats, fixed = TRUE)
  out <- cats
  out[has_slash] <- tolower(gsub("/", "_per_", out[has_slash], fixed = TRUE))
  paste0("sgp_", out)
}
