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
#' @param x An `sgp_denominators` object.
#' @param ... Ignored.
#' @return `x`, invisibly.
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
#' Delegates to `$denominators` for backward compatibility with the old
#' named-numeric-vector API.
#'
#' @param x An `sgp_denominators` object.
#' @param i Index (name or position).
#' @return Named numeric scalar (or vector).
#' @method [ sgp_denominators
#' @export
`[.sgp_denominators` <- function(x, i) x$denominators[i]

#' Double-bracket subscript for sgp_denominators
#'
#' Uses default list semantics so that `x[["denominators"]]`,
#' `x[["year_diagnostics"]]`, etc. work as expected.
#'
#' @param x An `sgp_denominators` object.
#' @param i Index (name or position).
#' @return The list element.
#' @method [[ sgp_denominators
#' @export
`[[.sgp_denominators` <- function(x, i) .subset2(x, i)

#' Coerce sgp_denominators to a named numeric vector
#'
#' Returns the underlying denominator vector. Enables backward-compatible
#' usage such as `as.double(denoms)` or `as.numeric(denoms)`.
#'
#' `as.numeric()` is a base primitive that does not dispatch S3 methods for
#' list objects; `as.double()` does. Registering as `as.double` ensures
#' correct dispatch for both `as.double()` and `as.numeric()` callers (since
#' `as.numeric` internally calls `as.double`).
#'
#' @param x An `sgp_denominators` object.
#' @param ... Ignored.
#' @return Named numeric vector of denominators.
#' @method as.double sgp_denominators
#' @export
as.double.sgp_denominators <- function(x, ...) x$denominators

#' Names of an sgp_denominators object
#'
#' Returns the category names from `$denominators` for backward compatibility
#' with the old named-vector API.
#'
#' @param x An `sgp_denominators` object.
#' @return Character vector of category names.
#' @method names sgp_denominators
#' @export
names.sgp_denominators <- function(x) names(x$denominators)

#' Length of an sgp_denominators object
#'
#' Returns the number of scored categories.
#'
#' @param x An `sgp_denominators` object.
#' @return Integer scalar.
#' @method length sgp_denominators
#' @export
length.sgp_denominators <- function(x) length(x$denominators)
