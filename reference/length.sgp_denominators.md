# Length of an sgp_denominators object

Returns the number of scored categories — equivalent to
`length(x$denominators)`. Preserves backward compatibility with code
that calls [`length()`](https://rdrr.io/r/base/length.html) on the
return value of
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md).

## Usage

``` r
# S3 method for class 'sgp_denominators'
length(x)
```

## Arguments

- x:

  An `sgp_denominators` object.

## Value

Integer scalar equal to the number of scored categories.

## See also

[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
