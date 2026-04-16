# Year-window helper: years within an inclusive range

Restricts the calibration window to years satisfying `y1 <= y <= y2`.
Both endpoints are included.

## Usage

``` r
between(y1, y2)
```

## Arguments

- y1:

  Integer. Start of range (inclusive).

- y2:

  Integer. End of range (inclusive).

## Value

An S3 object of class `"sgp_year_window_between"`. Pass as the `years`
argument to
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
or inside
[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md).

## See also

[`after()`](https://jdenn0514.github.io/rotostats/reference/after.md),
[`before()`](https://jdenn0514.github.io/rotostats/reference/before.md),
[`last()`](https://jdenn0514.github.io/rotostats/reference/last.md),
[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md),
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)

Other year-window helpers:
[`after()`](https://jdenn0514.github.io/rotostats/reference/after.md),
[`before()`](https://jdenn0514.github.io/rotostats/reference/before.md),
[`last()`](https://jdenn0514.github.io/rotostats/reference/last.md)

## Examples

``` r
between(2018, 2022)  # selects 2018, 2019, 2020, 2021, 2022
#> $y1
#> [1] 2018
#> 
#> $y2
#> [1] 2022
#> 
#> attr(,"class")
#> [1] "sgp_year_window_between"
```
