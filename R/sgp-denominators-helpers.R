# Internal helpers for sgp_denominators()
# All functions in this file are non-exported (use @noRd).

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#' @noRd
METADATA_COLS <- c("YEAR", "TEAM_ID", "IP", "AB")

# ---------------------------------------------------------------------------
# Weight constructors
# ---------------------------------------------------------------------------

#' Flat (equal) weight constructor for SGP denominator calibration
#'
#' Returns a weight function that assigns equal weight to all years in the
#' calibration window. Use this when you believe the denominator is stable over
#' time and want to maximise effective sample size.
#'
#' @return A function of class `"flat_weight"` with signature
#'   `function(years_ago)` that always returns `1`. Weights are subsequently
#'   normalized by `sgp_denominators()` so the exact magnitude does not matter.
#'
#' @seealso [exp_decay()], [linear_decay()], [sgp_denominators()]
#' @family weight constructors
#' @export
#' @examples
#' wfn <- flat()
#' wfn(0)  # 1
#' wfn(3)  # 1
#'
#' # Use as the weights argument in sgp_denominators():
#' # sgp_denominators(history, weights = flat())
flat <- function() {
  structure(
    function(years_ago) 1,
    class = c("flat_weight", "function")
  )
}

#' Linear decay weight constructor for SGP denominator calibration
#'
#' Returns a sentinel object signalling that `sgp_denominators()` should apply
#' linearly declining weights proportional to recency rank. Within a window of
#' `n` years the most recent year receives weight `n/n`, one year back receives
#' `(n-1)/n`, etc. Because all weights are normalized by their sum, only the
#' relative ordering matters, not the absolute values.
#'
#' @details
#' `linear_decay()` does not return a callable function — it returns a sentinel
#' of class `"linear_decay_weight"`. The internal `compute_weight()` helper
#' detects this class and applies the rank-proportional formula using the window
#' size available at call time. Do not call the return value directly.
#'
#' @return An object of class `"linear_decay_weight"`. Pass as the `weights`
#'   argument to [sgp_denominators()] or inside [cal()].
#'
#' @seealso [flat()], [exp_decay()], [sgp_denominators()]
#' @family weight constructors
#' @export
#' @examples
#' w <- linear_decay()
#' inherits(w, "linear_decay_weight")  # TRUE
#'
#' # Use as the weights argument:
#' # sgp_denominators(history, weights = linear_decay())
linear_decay <- function() {
  structure(list(), class = "linear_decay_weight")
}

#' Exponential decay weight constructor for SGP denominator calibration
#'
#' Returns a weight function where each additional year back in time reduces the
#' weight by a factor of `lambda`. The most recent year (`years_ago = 0`)
#' receives weight `1`; one year back receives `lambda`; `k` years back
#' `lambda^k`. Use values close to `1` (e.g., `0.9`) for mild decay and lower
#' values (e.g., `0.7`) when recent seasons should dominate strongly.
#'
#' @param lambda Numeric scalar in `(0, 1]`. Decay factor per year. The default
#'   in [sgp_denominators()] is `0.9`.
#'
#' @return A function of class `c("exp_decay_weight", "function")` with
#'   signature `function(years_ago)` returning `lambda^years_ago`.
#'
#' @seealso [flat()], [linear_decay()], [sgp_denominators()]
#' @family weight constructors
#' @export
#' @examples
#' wfn <- exp_decay(0.9)
#' wfn(0)  # 1
#' wfn(1)  # 0.9
#' wfn(2)  # 0.81
#'
#' # Stronger decay — recent years carry much more weight:
#' wfn_strong <- exp_decay(0.7)
#' wfn_strong(3)  # 0.343
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
#' Restricts the calibration window to years strictly greater than `year`.
#' Commonly used to exclude pre-rule-change seasons; e.g., `after(2022)` selects
#' 2023 onward (the post-shift-ban era).
#'
#' @param year Numeric or integer threshold. Years *strictly greater than*
#'   `year` are included (`y > year`).
#'
#' @return An S3 object of class `"sgp_year_window_after"`. Pass as the `years`
#'   argument to [sgp_denominators()] or inside [cal()].
#'
#' @seealso [before()], [between()], [last()], [cal()], [sgp_denominators()]
#' @family year-window helpers
#' @export
#' @examples
#' after(2022)  # selects 2023, 2024, ...
#'
#' # Use inside cal_spec() for a per-category override:
#' cal_spec(SB = cal(years = after(2022)))
after <- function(year) {
  structure(list(year = year), class = "sgp_year_window_after")
}

#' Year-window helper: years strictly before a threshold
#'
#' Restricts the calibration window to years strictly less than `year`.
#'
#' @param year Numeric or integer threshold. Years *strictly less than* `year`
#'   are included (`y < year`).
#'
#' @return An S3 object of class `"sgp_year_window_before"`. Pass as the `years`
#'   argument to [sgp_denominators()] or inside [cal()].
#'
#' @seealso [after()], [between()], [last()], [cal()], [sgp_denominators()]
#' @family year-window helpers
#' @export
#' @examples
#' before(2020)  # selects 2019, 2018, ...
before <- function(year) {
  structure(list(year = year), class = "sgp_year_window_before")
}

#' Year-window helper: years within an inclusive range
#'
#' Restricts the calibration window to years satisfying `y1 <= y <= y2`.
#' Both endpoints are included.
#'
#' @param y1 Integer. Start of range (inclusive).
#' @param y2 Integer. End of range (inclusive).
#'
#' @return An S3 object of class `"sgp_year_window_between"`. Pass as the
#'   `years` argument to [sgp_denominators()] or inside [cal()].
#'
#' @seealso [after()], [before()], [last()], [cal()], [sgp_denominators()]
#' @family year-window helpers
#' @export
#' @examples
#' between(2018, 2022)  # selects 2018, 2019, 2020, 2021, 2022
between <- function(y1, y2) {
  structure(list(y1 = y1, y2 = y2), class = "sgp_year_window_between")
}

#' Year-window helper: the n most recent years
#'
#' Restricts the calibration window to the `n` most recent years present in
#' `league_history$team_season`. Useful when only a fixed rolling window is
#' desired regardless of when the function is called.
#'
#' @param n Positive integer. Number of most recent years to include.
#'
#' @return An S3 object of class `"sgp_year_window_last"`. Pass as the `years`
#'   argument to [sgp_denominators()] or inside [cal()].
#'
#' @seealso [after()], [before()], [between()], [cal()], [sgp_denominators()]
#' @family year-window helpers
#' @export
#' @examples
#' last(5)  # selects the 5 most recent years in the data
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
#' Creates a calibration override for a single scoring category, specifying a
#' custom year window and/or custom weight function to use for that category
#' instead of the global defaults. Pass one or more `cal()` objects to
#' [cal_spec()].
#'
#' @param years A year-window specification for this category: `"all"`, an
#'   integer vector, or the result of [after()], [before()], [between()], or
#'   [last()]. `NULL` (the default) inherits the global `years` argument of
#'   [sgp_denominators()].
#' @param weights A weight specification for this category: a constructor result
#'   ([flat()], [linear_decay()], [exp_decay()]), the shorthand `"flat"` or
#'   `"linear"`, or a plain function of signature `function(years_ago)`. `NULL`
#'   (the default) inherits the global `weights` argument.
#'
#' @return An S3 object of class `"cal"`. Use inside [cal_spec()].
#'
#' @seealso [cal_spec()], [sgp_denominators()], [after()], [flat()], [exp_decay()]
#' @family calibration spec constructors
#' @export
#' @examples
#' # Override SB to use only post-2022 data with flat weights:
#' cal(years = after(2022), weights = flat())
#'
#' # Override ERA to use exponential decay only (inheriting global year window):
#' cal(weights = exp_decay(0.8))
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
#' Collects per-category calibration overrides into a single object to pass as
#' the `category_spec` argument of [sgp_denominators()]. Each named argument
#' must be a [cal()] object; raw `list()` entries are rejected.
#'
#' @param ... Named arguments. Each name is an uppercase scoring category
#'   (e.g., `SB`, `ERA`) and each value must be a [cal()] object. Categories
#'   not listed here inherit the global `years` and `weights` defaults.
#'
#' @return An S3 object of class `"cal_spec"`. Pass as `category_spec` in
#'   [sgp_denominators()].
#'
#' @seealso [cal()], [sgp_denominators()]
#' @family calibration spec constructors
#' @export
#' @examples
#' # Post-2022 window for SB (2023 rule changes); explicit flat decay for ERA:
#' cal_spec(
#'   SB  = cal(years = after(2022)),
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
#' Computes `E[X_(n) - X_(1)]`, the expected range of `n` iid standard normal
#' variables, via numerical integration of the exact formula:
#'
#' `integral_{-Inf}^{Inf} [ 1 - Phi(x)^n - (1 - Phi(x))^n ] dx`
#'
#' This quantity is used by the `"sd"` method of [sgp_denominators()] to
#' convert the within-year standard deviation of category totals into a
#' denominator expressed in standings-gap units.
#'
#' @details
#' The integral is evaluated by [stats::integrate()] with default tolerance.
#' Results are stable to better than `1e-3` for all `n >= 2`.
#'
#' Verified anchors from Monte Carlo and analytical integration:
#' \tabular{ll}{
#'   n = 10 \tab 3.0776\cr
#'   n = 12 \tab 3.2587\cr
#'   n = 15 \tab 3.4718\cr
#'   n = 20 \tab 3.7350\cr
#' }
#'
#' @param n Integer or numeric scalar, `>= 2`. Number of standard normal
#'   variables (i.e., number of teams in the league).
#'
#' @return Numeric scalar. The expected range `E[X_(n) - X_(1)]`.
#'
#' @seealso [sgp_denominators()]
#' @export
#' @examples
#' expected_range_normal(10)  # 3.0776
#' expected_range_normal(12)  # 3.2587
#' expected_range_normal(15)  # 3.4718
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
