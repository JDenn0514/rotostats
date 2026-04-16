# Year-window helper: years strictly after a threshold

Restricts the calibration window to years strictly greater than `year`.
Commonly used to exclude pre-rule-change seasons; e.g., `after(2022)`
selects 2023 onward (the post-shift-ban era).

## Usage

``` r
after(year)
```

## Arguments

- year:

  Numeric or integer threshold. Years *strictly greater than* `year` are
  included (`y > year`).

## Value

An S3 object of class `"sgp_year_window_after"`. Pass as the `years`
argument to
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
or inside
[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md).

## See also

[`before()`](https://jdenn0514.github.io/rotostats/reference/before.md),
[`between()`](https://jdenn0514.github.io/rotostats/reference/between.md),
[`last()`](https://jdenn0514.github.io/rotostats/reference/last.md),
[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md),
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)

Other year-window helpers:
[`before()`](https://jdenn0514.github.io/rotostats/reference/before.md),
[`between()`](https://jdenn0514.github.io/rotostats/reference/between.md),
[`last()`](https://jdenn0514.github.io/rotostats/reference/last.md)

## Examples

``` r
after(2022)  # selects 2023, 2024, ...
#> $year
#> [1] 2022
#> 
#> attr(,"class")
#> [1] "sgp_year_window_after"

# Use inside cal_spec() for a per-category override:
cal_spec(SB = cal(years = after(2022)))
#> $SB
#> $years
#> $year
#> [1] 2022
#> 
#> attr(,"class")
#> [1] "sgp_year_window_after"
#> 
#> $weights
#> NULL
#> 
#> attr(,"class")
#> [1] "cal"
#> 
#> attr(,"class")
#> [1] "cal_spec"
```
