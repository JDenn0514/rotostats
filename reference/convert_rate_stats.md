# Convert rate statistics to counting-stat equivalents (stub)

This function is not yet implemented. When complete it will convert rate
statistics (ERA, WHIP, AVG) to counting-stat equivalents using a fixed
baseline approach, enabling the `rate_conversion = "fixed_baseline"`
path in
[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md).

Until then, calling this function — directly or via
`sgp_denominators(rate_conversion = "fixed_baseline")` — always aborts
with class `rotostats_error_not_implemented`. Use the default
`rate_conversion = "blended_pool"` instead.

## Usage

``` r
convert_rate_stats(
  league_history,
  baseline_era = NULL,
  baseline_whip = NULL,
  baseline_avg = NULL,
  projections = NULL,
  league_config = NULL
)
```

## Arguments

- league_history:

  A `league_history` S3 object or duck-typed list with a `$team_season`
  data.frame. Not used (stub).

- baseline_era:

  Numeric. Fixed baseline ERA. Not used (stub).

- baseline_whip:

  Numeric. Fixed baseline WHIP. Not used (stub).

- baseline_avg:

  Numeric. Fixed baseline AVG. Not used (stub).

- projections:

  Data frame of player projections. Not used (stub).

- league_config:

  League configuration object. Not used (stub).

## Value

Does not return; always aborts with `rotostats_error_not_implemented`.

## See also

[`sgp_denominators()`](https://jdenn0514.github.io/rotostats/reference/sgp_denominators.md)
