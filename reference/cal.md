# Per-category calibration override constructor

Creates a calibration override for a single scoring category, specifying
a custom year window and/or custom weight function to use for that
category instead of the global defaults. Pass one or more `cal()`
objects to
[`cal_spec()`](https://jdenn0514.github.io/rotostats/reference/cal_spec.md).

## Usage

``` r
cal(years = NULL, weights = NULL)
```

## Arguments

- years:

  A year-window specification for this category: `"all"`, an integer
  vector, or the result of
  [`after()`](https://jdenn0514.github.io/rotostats/reference/after.md),
  [`before()`](https://jdenn0514.github.io/rotostats/reference/before.md),
  [`between()`](https://jdenn0514.github.io/rotostats/reference/between.md),
  or
  [`last()`](https://jdenn0514.github.io/rotostats/reference/last.md).
  `NULL` (the default) inherits the global `years` argument of
  [`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md).

- weights:

  A weight specification for this category: a constructor result
  ([`flat()`](https://jdenn0514.github.io/rotostats/reference/flat.md),
  [`linear_decay()`](https://jdenn0514.github.io/rotostats/reference/linear_decay.md),
  [`exp_decay()`](https://jdenn0514.github.io/rotostats/reference/exp_decay.md)),
  the shorthand `"flat"` or `"linear"`, or a plain function of signature
  `function(years_ago)`. `NULL` (the default) inherits the global
  `weights` argument.

## Value

An S3 object of class `"cal"`. Use inside
[`cal_spec()`](https://jdenn0514.github.io/rotostats/reference/cal_spec.md).

## See also

[`cal_spec()`](https://jdenn0514.github.io/rotostats/reference/cal_spec.md),
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md),
[`after()`](https://jdenn0514.github.io/rotostats/reference/after.md),
[`flat()`](https://jdenn0514.github.io/rotostats/reference/flat.md),
[`exp_decay()`](https://jdenn0514.github.io/rotostats/reference/exp_decay.md)

Other calibration spec constructors:
[`cal_spec()`](https://jdenn0514.github.io/rotostats/reference/cal_spec.md)

## Examples

``` r
# Override SB to use only post-2022 data with flat weights:
cal(years = after(2022), weights = flat())
#> $years
#> $year
#> [1] 2022
#> 
#> attr(,"class")
#> [1] "sgp_year_window_after"
#> 
#> $weights
#> function (years_ago) 
#> 1
#> <bytecode: 0x56411acbb040>
#> <environment: 0x56411acbada0>
#> attr(,"class")
#> [1] "flat_weight" "function"   
#> 
#> attr(,"class")
#> [1] "cal"

# Override ERA to use exponential decay only (inheriting global year window):
cal(weights = exp_decay(0.8))
#> $years
#> NULL
#> 
#> $weights
#> function (years_ago) 
#> lambda^years_ago
#> <bytecode: 0x56411ad41ab8>
#> <environment: 0x56411ad45610>
#> attr(,"class")
#> [1] "exp_decay_weight" "function"        
#> 
#> attr(,"class")
#> [1] "cal"
```
