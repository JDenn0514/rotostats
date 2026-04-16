# Exponential decay weight constructor for SGP denominator calibration

Returns a weight function where each additional year back in time
reduces the weight by a factor of `lambda`. The most recent year
(`years_ago = 0`) receives weight `1`; one year back receives `lambda`;
`k` years back `lambda^k`. Use values close to `1` (e.g., `0.9`) for
mild decay and lower values (e.g., `0.7`) when recent seasons should
dominate strongly.

## Usage

``` r
exp_decay(lambda)
```

## Arguments

- lambda:

  Numeric scalar in `(0, 1]`. Decay factor per year. The default in
  [`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
  is `0.9`.

## Value

A function of class `c("exp_decay_weight", "function")` with signature
`function(years_ago)` returning `lambda^years_ago`.

## See also

[`flat()`](https://jdenn0514.github.io/rotostats/reference/flat.md),
[`linear_decay()`](https://jdenn0514.github.io/rotostats/reference/linear_decay.md),
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)

Other weight constructors:
[`flat()`](https://jdenn0514.github.io/rotostats/reference/flat.md),
[`linear_decay()`](https://jdenn0514.github.io/rotostats/reference/linear_decay.md)

## Examples

``` r
wfn <- exp_decay(0.9)
wfn(0)  # 1
#> [1] 1
wfn(1)  # 0.9
#> [1] 0.9
wfn(2)  # 0.81
#> [1] 0.81

# Stronger decay — recent years carry much more weight:
wfn_strong <- exp_decay(0.7)
wfn_strong(3)  # 0.343
#> [1] 0.343
```
