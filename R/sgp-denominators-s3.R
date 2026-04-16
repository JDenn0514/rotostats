# S3 constructor and methods for sgp_denominators objects

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------

#' @noRd
new_sgp_denominators <- function(
  denominators,
  year_diagnostics,
  bootstrap_ci,
  call,
  meta,
  rate_conversion
) {
  structure(
    list(
      denominators     = denominators,
      year_diagnostics = year_diagnostics,
      bootstrap_ci     = bootstrap_ci,
      call             = call,
      meta             = meta
    ),
    class           = c("sgp_denominators", "list"),
    rate_conversion = rate_conversion
  )
}

# ---------------------------------------------------------------------------
# S3 methods
# ---------------------------------------------------------------------------

#' Print method for sgp_denominators objects
#'
#' Displays the estimation method, rate-conversion mode, years used, and the
#' denominator values for each scoring category. When bootstrap CIs are
#' present, the replicate count and CI level are also shown.
#'
#' @param x An `sgp_denominators` object returned by [sgp_denominators()].
#' @param ... Ignored.
#'
#' @return `x`, invisibly.
#'
#' @seealso [sgp_denominators()]
#' @method print sgp_denominators
#' @export
print.sgp_denominators <- function(x, ...) {
  cat("SGP Denominators\n")
  cat(sprintf("  Method:          %s\n", x$meta$method))
  cat(sprintf("  Rate conversion: %s\n", x$meta$rate_conversion))
  cat(sprintf("  Years used:      %s\n", paste(x$meta$years_used, collapse = ", ")))
  cat(sprintf("  Categories (%d):\n", length(x$denominators)))
  print(round(x$denominators, 4))
  if (!is.null(x$bootstrap_ci)) {
    cat(sprintf(
      "  Bootstrap CI:    %d replicates at %.0f%% level\n",
      x$bootstrap_ci$n_bootstrap[1L],
      x$bootstrap_ci$ci_level[1L] * 100
    ))
  }
  invisible(x)
}

#' Single-bracket subscript for sgp_denominators
#'
#' Delegates to `$denominators`, preserving backward compatibility with code
#' that treats the return value of [sgp_denominators()] as a named numeric
#' vector.
#'
#' @param x An `sgp_denominators` object.
#' @param i A character name (e.g., `"HR"`) or integer position.
#'
#' @return Named numeric scalar or vector from `x$denominators`.
#'
#' @seealso [sgp_denominators()]
#' @method [ sgp_denominators
#' @export
`[.sgp_denominators` <- function(x, i) x$denominators[i]

#' Double-bracket subscript for sgp_denominators
#'
#' Uses standard list semantics, giving direct access to named slots:
#' `x[["denominators"]]`, `x[["year_diagnostics"]]`, `x[["bootstrap_ci"]]`,
#' `x[["call"]]`, and `x[["meta"]]`.
#'
#' @param x An `sgp_denominators` object.
#' @param i A character slot name or integer position.
#'
#' @return The list element at position `i`.
#'
#' @seealso [sgp_denominators()]
#' @method [[ sgp_denominators
#' @export
`[[.sgp_denominators` <- function(x, i) .subset2(x, i)

#' Coerce sgp_denominators to a named numeric vector
#'
#' Returns `x$denominators`, the named numeric vector of SGP denominators.
#' Enables backward-compatible usage such as `as.double(denoms)` and
#' `as.numeric(denoms)`.
#'
#' @details
#' **S3 dispatch subtlety.** In base R, `as.numeric` is a primitive that does
#' not dispatch S3 methods for list-based objects — calling
#' `as.numeric(x)` on an S3 list silently falls back to base coercion and
#' returns an empty `numeric(0)`. `as.double` *does* dispatch correctly for
#' list objects. This method is therefore registered as `as.double`, and
#' `as.numeric` works because `as.numeric` internally delegates to `as.double`
#' via R's primitive fallback chain. Future S3 authors building list-based
#' classes in this package should register coercions under `as.double`, not
#' `as.numeric`.
#'
#' @param x An `sgp_denominators` object.
#' @param ... Ignored.
#'
#' @return Named numeric vector of length equal to the number of scored
#'   categories.
#'
#' @seealso [sgp_denominators()]
#' @method as.double sgp_denominators
#' @export
as.double.sgp_denominators <- function(x, ...) x$denominators

#' Names of an sgp_denominators object
#'
#' Returns the category names from `x$denominators`, preserving backward
#' compatibility with code that calls `names()` on the return value of
#' [sgp_denominators()]. To inspect the raw slot names of the underlying list,
#' use `names(unclass(x))`.
#'
#' @param x An `sgp_denominators` object.
#'
#' @return Character vector of uppercase category names, e.g.,
#'   `c("HR", "R", "RBI", "SB", "AVG", "ERA", "WHIP", "K", "W", "SV")`.
#'
#' @seealso [sgp_denominators()]
#' @method names sgp_denominators
#' @export
names.sgp_denominators <- function(x) names(x$denominators)

#' Length of an sgp_denominators object
#'
#' Returns the number of scored categories — equivalent to
#' `length(x$denominators)`. Preserves backward compatibility with code that
#' calls `length()` on the return value of [sgp_denominators()].
#'
#' @param x An `sgp_denominators` object.
#'
#' @return Integer scalar equal to the number of scored categories.
#'
#' @seealso [sgp_denominators()]
#' @method length sgp_denominators
#' @export
length.sgp_denominators <- function(x) length(x$denominators)
