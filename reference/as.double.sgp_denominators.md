# Coerce sgp_denominators to a named numeric vector

Returns `x$denominators`, the named numeric vector of SGP denominators.
Enables backward-compatible usage such as `as.double(denoms)` and
`as.numeric(denoms)`.

## Usage

``` r
# S3 method for class 'sgp_denominators'
as.double(x, ...)
```

## Arguments

- x:

  An `sgp_denominators` object.

- ...:

  Ignored.

## Value

Named numeric vector of length equal to the number of scored categories.

## Details

**S3 dispatch subtlety.** In base R, `as.numeric` is a primitive that
does not dispatch S3 methods for list-based objects — calling
`as.numeric(x)` on an S3 list silently falls back to base coercion and
returns an empty `numeric(0)`. `as.double` *does* dispatch correctly for
list objects. This method is therefore registered as `as.double`, and
`as.numeric` works because `as.numeric` internally delegates to
`as.double` via R's primitive fallback chain. Future S3 authors building
list-based classes in this package should register coercions under
`as.double`, not `as.numeric`.

## See also

[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
