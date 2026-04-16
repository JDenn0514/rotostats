# Double-bracket subscript for sgp_denominators

Uses standard list semantics, giving direct access to named slots:
`x[["denominators"]]`, `x[["year_diagnostics"]]`, `x[["bootstrap_ci"]]`,
`x[["call"]]`, and `x[["meta"]]`.

## Usage

``` r
# S3 method for class 'sgp_denominators'
x[[i]]
```

## Arguments

- x:

  An `sgp_denominators` object.

- i:

  A character slot name or integer position.

## Value

The list element at position `i`.

## See also

[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
