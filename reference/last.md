# Year-window helper: the n most recent years

Restricts the calibration window to the `n` most recent years present in
`league_history$team_season`. Useful when only a fixed rolling window is
desired regardless of when the function is called.

## Usage

``` r
last(n)
```

## Arguments

- n:

  Positive integer. Number of most recent years to include.

## Value

An S3 object of class `"sgp_year_window_last"`. Pass as the `years`
argument to
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
or inside
[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md).

## See also

[`after()`](https://jdenn0514.github.io/rotostats/reference/after.md),
[`before()`](https://jdenn0514.github.io/rotostats/reference/before.md),
[`between()`](https://jdenn0514.github.io/rotostats/reference/between.md),
[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md),
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)

Other year-window helpers:
[`after()`](https://jdenn0514.github.io/rotostats/reference/after.md),
[`before()`](https://jdenn0514.github.io/rotostats/reference/before.md),
[`between()`](https://jdenn0514.github.io/rotostats/reference/between.md)

## Examples

``` r
last(5)  # selects the 5 most recent years in the data
#> $n
#> [1] 5
#> 
#> attr(,"class")
#> [1] "sgp_year_window_last"
```
