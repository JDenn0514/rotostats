# Internal helpers for sgp_denominators()
# All functions in this file are non-exported (use @noRd).

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#' @noRd
INVERSE_CATEGORIES <- c("ERA", "WHIP")

#' @noRd
METADATA_COLS <- c("YEAR", "TEAM_ID", "IP", "AB")

# ---------------------------------------------------------------------------
# Weight constructors
# ---------------------------------------------------------------------------

#' Flat (equal) weight constructor for SGP denominator calibration
#'
#' Returns a weight function that assigns equal weight to all years.
#'
#' @return A function with signature `function(years_ago)` that always returns 1.
#' @export
#' @examples
#' wfn <- flat()
#' wfn(0)  # 1
#' wfn(3)  # 1
flat <- function() {
  structure(
    function(years_ago) 1,
    class = c("flat_weight", "function")
  )
}

#' Linear decay weight constructor for SGP denominator calibration
#'
#' Returns a special sentinel object that the SGP denominator weight computation
#' loop handles explicitly. Weights are proportional to recency rank: the most
#' recent year receives the highest weight.
#'
#' @return An object of class `"linear_decay_weight"`. Do not call directly;
#'   it is consumed by `compute_weight()` inside `sgp_denominators()`.
#' @export
#' @examples
#' w <- linear_decay()
#' inherits(w, "linear_decay_weight")  # TRUE
linear_decay <- function() {
  structure(list(), class = "linear_decay_weight")
}

#' Exponential decay weight constructor for SGP denominator calibration
#'
#' Returns a weight function where each additional year back in time reduces the
#' weight by a factor of `lambda`. The most recent year (years_ago = 0) receives
#' weight 1; one year back receives weight `lambda`; two years back `lambda^2`, etc.
#'
#' @param lambda Numeric scalar in (0, 1]. Decay factor. Default in
#'   `sgp_denominators()` is 0.9.
#' @return A function with signature `function(years_ago)` returning `lambda^years_ago`.
#' @export
#' @examples
#' wfn <- exp_decay(0.9)
#' wfn(0)  # 1
#' wfn(1)  # 0.9
#' wfn(2)  # 0.81
exp_decay <- function(lambda) {
  stopifnot(
    is.numeric(lambda),
    length(lambda) == 1L,
    lambda > 0,
    lambda <= 1
  )
  structure(
    function(years_ago) lambda^years_ago,
    class = c("exp_decay_weight", "function")
  )
}

# ---------------------------------------------------------------------------
# Internal: compute a single weight value
# ---------------------------------------------------------------------------

#' @noRd
compute_weight <- function(weight_fn, years_ago, n_years) {
  if (inherits(weight_fn, "linear_decay_weight")) {
    (n_years - years_ago) / n_years
  } else {
    weight_fn(years_ago)
  }
}

# ---------------------------------------------------------------------------
# Year-window helpers
# ---------------------------------------------------------------------------

#' Year-window helper: years strictly after a threshold
#'
#' @param year Numeric or integer threshold. Years *strictly greater than*
#'   `year` are included. For example, `after(2022)` includes 2023 onward.
#' @return An S3 object of class `"sgp_year_window_after"`.
#' @export
#' @examples
#' after(2022)  # selects years >= 2023
after <- function(year) {
  structure(list(year = year), class = "sgp_year_window_after")
}

#' Year-window helper: years strictly before a threshold
#'
#' @param year Numeric or integer threshold. Years *strictly less than* `year`
#'   are included.
#' @return An S3 object of class `"sgp_year_window_before"`.
#' @export
#' @examples
#' before(2020)  # selects years up to 2019
before <- function(year) {
  structure(list(year = year), class = "sgp_year_window_before")
}

#' Year-window helper: years within an inclusive range
#'
#' Both endpoints are included: `y1 <= y <= y2`.
#'
#' @param y1 Integer. Start of range (inclusive).
#' @param y2 Integer. End of range (inclusive).
#' @return An S3 object of class `"sgp_year_window_between"`.
#' @export
#' @examples
#' between(2018, 2022)  # selects 2018, 2019, 2020, 2021, 2022
between <- function(y1, y2) {
  structure(list(y1 = y1, y2 = y2), class = "sgp_year_window_between")
}

#' Year-window helper: the n most recent years
#'
#' @param n Positive integer. Number of most recent years to include.
#' @return An S3 object of class `"sgp_year_window_last"`.
#' @export
#' @examples
#' last(5)  # selects the 5 most recent years
last <- function(n) {
  structure(list(n = n), class = "sgp_year_window_last")
}

# ---------------------------------------------------------------------------
# apply_year_window()
# ---------------------------------------------------------------------------

#' @noRd
apply_year_window <- function(all_years, window) {
  if (identical(window, "all")) {
    return(all_years)
  }
  if (is.numeric(window) || is.integer(window)) {
    return(intersect(all_years, window))
  }
  if (inherits(window, "sgp_year_window_after")) {
    return(all_years[all_years > window$year])
  }
  if (inherits(window, "sgp_year_window_before")) {
    return(all_years[all_years < window$year])
  }
  if (inherits(window, "sgp_year_window_between")) {
    return(all_years[all_years >= window$y1 & all_years <= window$y2])
  }
  if (inherits(window, "sgp_year_window_last")) {
    return(utils::tail(sort(all_years), window$n))
  }
  cli::cli_abort(
    "Unrecognized year window specification.",
    class = "rotostats_error_invalid_year_window"
  )
}

# ---------------------------------------------------------------------------
# Validation helpers for cal() and cal_spec()
# ---------------------------------------------------------------------------

#' @noRd
is_valid_year_window <- function(x) {
  identical(x, "all") ||
    is.numeric(x) ||
    is.integer(x) ||
    inherits(x, "sgp_year_window_after") ||
    inherits(x, "sgp_year_window_before") ||
    inherits(x, "sgp_year_window_between") ||
    inherits(x, "sgp_year_window_last")
}

#' @noRd
is_valid_weight <- function(x) {
  identical(x, "flat") ||
    identical(x, "linear") ||
    is.function(x) ||
    inherits(x, "linear_decay_weight")
}

# ---------------------------------------------------------------------------
# Cal constructors
# ---------------------------------------------------------------------------

#' Per-category calibration override constructor
#'
#' Creates a calibration override for a single category, specifying a custom
#' year window and/or custom weight function. Pass to [cal_spec()].
#'
#' @param years A year-window specification: `"all"`, an integer vector, or
#'   the result of [after()], [before()], [between()], or [last()]. `NULL`
#'   inherits the global `years` argument of `sgp_denominators()`.
#' @param weights A weight constructor result, `"flat"`, `"linear"`, or a
#'   plain function. `NULL` inherits the global `weights` argument.
#' @return An S3 object of class `"cal"`.
#' @export
#' @examples
#' cal(years = after(2022), weights = flat())
cal <- function(years = NULL, weights = NULL) {
  if (!is.null(years) && !is_valid_year_window(years)) {
    cli::cli_abort(
      "`years` in `cal()` must be {.val \"all\"}, an integer vector, or a year-window helper.",
      class = "rotostats_error_invalid_cal_years"
    )
  }
  if (!is.null(weights) && !is_valid_weight(weights)) {
    cli::cli_abort(
      "`weights` in `cal()` must be a weight constructor result, {.val \"flat\"}, {.val \"linear\"}, or a function.",
      class = "rotostats_error_invalid_cal_weights"
    )
  }
  structure(list(years = years, weights = weights), class = "cal")
}

#' Per-category calibration spec constructor
#'
#' Creates a collection of per-category calibration overrides to pass as the
#' `category_spec` argument of [sgp_denominators()].
#'
#' @param ... Named arguments where each name is a category name (uppercase)
#'   and each value is a [cal()] object.
#' @return An S3 object of class `"cal_spec"`.
#' @export
#' @examples
#' cal_spec(
#'   SB = cal(years = after(2022)),
#'   ERA = cal(weights = flat())
#' )
cal_spec <- function(...) {
  entries <- list(...)
  bad <- names(entries)[!vapply(entries, inherits, logical(1L), "cal")]
  if (length(bad) > 0L) {
    cli::cli_abort(
      "All entries in {.fn cal_spec} must be constructed with {.fn cal}. Raw {.fn list} is not accepted. Bad entries: {.val {bad}}",
      class = "rotostats_error_invalid_category_spec"
    )
  }
  structure(entries, class = "cal_spec")
}

# ---------------------------------------------------------------------------
# expected_range_normal()
# ---------------------------------------------------------------------------

#' Expected range of n standard normal variables
#'
#' Computes the expected range of n iid standard normal variables via
#' numerical integration. Used by the `"sd"` method in [sgp_denominators()].
#'
#' Expected values (numerical integration anchors):
#' - n = 10: ≈ 3.0776
#' - n = 12: ≈ 3.2587
#' - n = 15: ≈ 3.4718
#'
#' @param n Integer >= 2. Number of standard normal variables.
#' @return Numeric scalar. The expected range.
#' @export
#' @examples
#' expected_range_normal(10)  # approx 3.0776
#' expected_range_normal(12)  # approx 3.2587
expected_range_normal <- function(n) {
  stopifnot(
    is.numeric(n) || is.integer(n),
    length(n) == 1L,
    n >= 2
  )
  stats::integrate(
    function(x) 1 - stats::pnorm(x)^n - (1 - stats::pnorm(x))^n,
    lower = -Inf,
    upper = Inf
  )$value
}
