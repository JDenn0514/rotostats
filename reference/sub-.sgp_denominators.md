# Single-bracket subscript for sgp_denominators

Delegates to `$denominators`, preserving backward compatibility with
code that treats the return value of
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
as a named numeric vector.

## Usage

``` r
# S3 method for class 'sgp_denominators'
x[i]
```

## Arguments

- x:

  An `sgp_denominators` object.

- i:

  A character name (e.g., `"HR"`) or integer position.

## Value

Named numeric scalar or vector from `x$denominators`.

## See also

[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
