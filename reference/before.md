# Year-window helper: years strictly before a threshold

Restricts the calibration window to years strictly less than `year`.

## Usage

``` r
before(year)
```

## Arguments

- year:

  Numeric or integer threshold. Years *strictly less than* `year` are
  included (`y < year`).

## Value

An S3 object of class `"sgp_year_window_before"`. Pass as the `years`
argument to
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
or inside
[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md).

## See also

[`after()`](https://jdenn0514.github.io/rotostats/reference/after.md),
[`between()`](https://jdenn0514.github.io/rotostats/reference/between.md),
[`last()`](https://jdenn0514.github.io/rotostats/reference/last.md),
[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md),
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)

Other year-window helpers:
[`after()`](https://jdenn0514.github.io/rotostats/reference/after.md),
[`between()`](https://jdenn0514.github.io/rotostats/reference/between.md),
[`last()`](https://jdenn0514.github.io/rotostats/reference/last.md)

## Examples

``` r
before(2020)  # selects 2019, 2018, ...
#> $year
#> [1] 2020
#> 
#> attr(,"class")
#> [1] "sgp_year_window_before"
```
