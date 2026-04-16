# Flat (equal) weight constructor for SGP denominator calibration

Returns a weight function that assigns equal weight to all years in the
calibration window. Use this when you believe the denominator is stable
over time and want to maximise effective sample size.

## Usage

``` r
flat()
```

## Value

A function of class `"flat_weight"` with signature `function(years_ago)`
that always returns `1`. Weights are subsequently normalized by
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
so the exact magnitude does not matter.

## See also

[`exp_decay()`](https://jdenn0514.github.io/rotostats/reference/exp_decay.md),
[`linear_decay()`](https://jdenn0514.github.io/rotostats/reference/linear_decay.md),
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)

Other weight constructors:
[`exp_decay()`](https://jdenn0514.github.io/rotostats/reference/exp_decay.md),
[`linear_decay()`](https://jdenn0514.github.io/rotostats/reference/linear_decay.md)

## Examples

``` r
wfn <- flat()
wfn(0)  # 1
#> [1] 1
wfn(3)  # 1
#> [1] 1

# Use as the weights argument in sgp_denominators():
# sgp_denominators(history, weights = flat())
```
