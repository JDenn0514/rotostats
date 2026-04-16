# Expected range of n standard normal variables

Computes `E[X_(n) - X_(1)]`, the expected range of `n` iid standard
normal variables, via numerical integration of the exact formula:

## Usage

``` r
expected_range_normal(n)
```

## Arguments

- n:

  Integer or numeric scalar, `>= 2`. Number of standard normal variables
  (i.e., number of teams in the league).

## Value

Numeric scalar. The expected range `E[X_(n) - X_(1)]`.

## Details

`integral_{-Inf}^{Inf} [ 1 - Phi(x)^n - (1 - Phi(x))^n ] dx`

This quantity is used by the `"sd"` method of
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
to convert the within-year standard deviation of category totals into a
denominator expressed in standings-gap units.

The integral is evaluated by
[`stats::integrate()`](https://rdrr.io/r/stats/integrate.html) with
default tolerance. Results are stable to better than `1e-3` for all
`n >= 2`.

Verified anchors from Monte Carlo and analytical integration:

|        |        |
|--------|--------|
| n = 10 | 3.0776 |
| n = 12 | 3.2587 |
| n = 15 | 3.4718 |
| n = 20 | 3.7350 |

## See also

[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)

## Examples

``` r
expected_range_normal(10)  # 3.0776
#> [1] 3.077505
expected_range_normal(12)  # 3.2587
#> [1] 3.258455
expected_range_normal(15)  # 3.4718
#> [1] 3.471827
```
