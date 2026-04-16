# Per-category calibration spec constructor

Collects per-category calibration overrides into a single object to pass
as the `category_spec` argument of
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md).
Each named argument must be a
[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md)
object; raw [`list()`](https://rdrr.io/r/base/list.html) entries are
rejected.

## Usage

``` r
cal_spec(...)
```

## Arguments

- ...:

  Named arguments. Each name is an uppercase scoring category (e.g.,
  `SB`, `ERA`) and each value must be a
  [`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md)
  object. Categories not listed here inherit the global `years` and
  `weights` defaults.

## Value

An S3 object of class `"cal_spec"`. Pass as `category_spec` in
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md).

## See also

[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md),
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)

Other calibration spec constructors:
[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md)

## Examples

``` r
# Post-2022 window for SB (2023 rule changes); explicit flat decay for ERA:
cal_spec(
  SB  = cal(years = after(2022)),
  ERA = cal(weights = flat())
)
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
#> $ERA
#> $years
#> NULL
#> 
#> $weights
#> function (years_ago) 
#> 1
#> <bytecode: 0x56411acbb040>
#> <environment: 0x56411b16ad78>
#> attr(,"class")
#> [1] "flat_weight" "function"   
#> 
#> attr(,"class")
#> [1] "cal"
#> 
#> attr(,"class")
#> [1] "cal_spec"
```
