# Names of an sgp_denominators object

Returns the category names from `x$denominators`, preserving backward
compatibility with code that calls
[`names()`](https://rdrr.io/r/base/names.html) on the return value of
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md).
To inspect the raw slot names of the underlying list, use
`names(unclass(x))`.

## Usage

``` r
# S3 method for class 'sgp_denominators'
names(x)
```

## Arguments

- x:

  An `sgp_denominators` object.

## Value

Character vector of uppercase category names, e.g.,
`c("HR", "R", "RBI", "SB", "AVG", "ERA", "WHIP", "K", "W", "SV")`.

## See also

[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
