# Linear decay weight constructor for SGP denominator calibration

Returns a sentinel object signalling that
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
should apply linearly declining weights proportional to recency rank.
Within a window of `n` years the most recent year receives weight `n/n`,
one year back receives `(n-1)/n`, etc. Because all weights are
normalized by their sum, only the relative ordering matters, not the
absolute values.

## Usage

``` r
linear_decay()
```

## Value

An object of class `"linear_decay_weight"`. Pass as the `weights`
argument to
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
or inside
[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md).

## Details

`linear_decay()` does not return a callable function — it returns a
sentinel of class `"linear_decay_weight"`. The internal
`compute_weight()` helper detects this class and applies the
rank-proportional formula using the window size available at call time.
Do not call the return value directly.

## See also

[`flat()`](https://jdenn0514.github.io/rotostats/reference/flat.md),
[`exp_decay()`](https://jdenn0514.github.io/rotostats/reference/exp_decay.md),
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)

Other weight constructors:
[`exp_decay()`](https://jdenn0514.github.io/rotostats/reference/exp_decay.md),
[`flat()`](https://jdenn0514.github.io/rotostats/reference/flat.md)

## Examples

``` r
w <- linear_decay()
inherits(w, "linear_decay_weight")  # TRUE
#> [1] TRUE

# Use as the weights argument:
# sgp_denominators(history, weights = linear_decay())
```
