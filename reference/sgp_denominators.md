# Compute SGP denominators for rotisserie scoring categories

Estimates the SGP (Standings Gain Points) denominator for each scoring
category by fitting OLS (or an alternative method) to historical
team-season standings data. The denominator for category *c* is the
number of additional category units required to move up one place in the
standings, on average, calibrated from your league's history.

`league_history` may be a formal `league_history` S3 object (see
`league_history()`) or any list with a `$team_season` data.frame
containing `year`, `team_id`, and category columns (duck-typing).

## Usage

``` r
sgp_denominators(
  league_history,
  scoring_categories = NULL,
  n_teams = NULL,
  years = "all",
  weights = exp_decay(0.9),
  method = "ols",
  category_spec = NULL,
  outlier_filter = FALSE,
  exclude_years = 2020L,
  rate_conversion = "blended_pool",
  roto_pts_col = "roto_pts",
  n_bootstrap = 0L,
  denom_floor = 1e-09,
  ci_level = 0.95
)
```

## Arguments

- league_history:

  A `league_history` S3 object **or** a plain list with a `$team_season`
  data.frame. The data.frame must contain at minimum `year`, `team_id`,
  and one column per scoring category. Column names are
  case-insensitive; they are normalized to uppercase internally.

- scoring_categories:

  Character vector of category column names, or `NULL` (default) to
  infer from `league_history$team_season`. Explicit specification
  suppresses the inference message and is recommended for production
  use.

- n_teams:

  Positive integer or `NULL` (default). When `NULL`, the number of teams
  is inferred per year from row counts; years with different counts
  produce a `rotostats_warning_uneven_team_counts` warning. When an
  integer is supplied, every year must have exactly that many rows.

- years:

  Global calibration window. One of:

  - `"all"` (default) — all years present in `league_history`.

  - An integer vector of specific years.

  - A year-window helper:
    [`after()`](https://jdenn0514.github.io/rotostats/reference/after.md),
    [`before()`](https://jdenn0514.github.io/rotostats/reference/before.md),
    [`between()`](https://jdenn0514.github.io/rotostats/reference/between.md),
    [`last()`](https://jdenn0514.github.io/rotostats/reference/last.md).
    Per-category overrides via `category_spec` take precedence. Years in
    `exclude_years` are removed after the window is applied.

- weights:

  Global year-weighting scheme. One of:

  - A weight constructor:
    [`flat()`](https://jdenn0514.github.io/rotostats/reference/flat.md),
    [`linear_decay()`](https://jdenn0514.github.io/rotostats/reference/linear_decay.md),
    or
    [`exp_decay()`](https://jdenn0514.github.io/rotostats/reference/exp_decay.md)
    (default: `exp_decay(0.9)`).

  - `"flat"` or `"linear"` as character shorthands. Per-category
    overrides via `category_spec` take precedence.

- method:

  Character. Denominator estimation method. One of:

  - `"ols"` (default) — OLS slope from
    `standings_position ~ category_total`.

  - `"gap"` — mean adjacent gap between sorted team totals.

  - `"trimmed_gap"` — 10%-trimmed mean adjacent gap.

  - `"sd"` — `sd(totals) * (n - 1) / E[R_n]`, where `E[R_n]` is the
    expected range of `n` standard normals (see
    [`expected_range_normal()`](https://jdenn0514.github.io/rotostats/reference/expected_range_normal.md)).

- category_spec:

  A
  [`cal_spec()`](https://jdenn0514.github.io/rotostats/reference/cal_spec.md)
  object providing per-category overrides for `years` and/or `weights`,
  or `NULL` (default). Build with
  `cal_spec(CAT = cal(years = ..., weights = ...))`.

- outlier_filter:

  Logical. When `TRUE`, team-season rows whose category value falls more
  than 1.5 × IQR outside the league median for that category-year are
  excluded before fitting. Default: `FALSE`.

- exclude_years:

  Integer vector of years excluded from all calibration windows.
  Default: `2020L` (COVID-shortened season).

- rate_conversion:

  Character. One of `"blended_pool"` (default) or `"fixed_baseline"`.
  The `"fixed_baseline"` path requires `league_history` to already be of
  class `"sgp_history_transformed"`; otherwise it calls the
  not-yet-implemented
  [`convert_rate_stats()`](https://jdenn0514.github.io/rotostats/reference/convert_rate_stats.md)
  stub and aborts with `rotostats_error_not_implemented`.

- roto_pts_col:

  Character. Column name for total roto points in `team_season`. Used
  only for optional standings validation; not part of denominator
  computation. Default: `"roto_pts"`.

- n_bootstrap:

  Non-negative integer. Number of year-level bootstrap replicates for CI
  estimation. `0L` (default) disables bootstrapping. When positive,
  year-level percentile bootstrap CIs are returned in `$bootstrap_ci`.
  See the Caveats section for coverage properties.

- denom_floor:

  Positive numeric. Near-zero slope guard threshold. If
  `abs(weighted_slope) < denom_floor`, the denominator is set to `Inf`
  and a `rotostats_warning_near_zero_slope` warning is emitted. Default:
  `1e-9`.

- ci_level:

  Numeric in `(0, 1)`. Bootstrap CI nominal coverage level. Used only
  when `n_bootstrap > 0`. Default: `0.95`.

## Value

An S3 object of class `c("sgp_denominators", "list")` with the following
slots:

- `$denominators`:

  Named numeric vector, one entry per scored category. Names are
  uppercase category names.

- `$year_diagnostics`:

  data.frame with one row per (year × category) combination. Columns:
  `year`, `category`, `n_teams`, `slope` (OLS only; `NA` for other
  methods), `r_squared` (OLS only), `weight` (normalized, sums to 1
  within category), `standings_pos_source` (factor: `"category_pts"` or
  `"rank"`).

- `$bootstrap_ci`:

  data.frame or `NULL`. When non-NULL: columns `category`, `ci_lower`,
  `ci_upper`, `ci_level`, `n_bootstrap`.

- `$call`:

  The matched call, captured at function entry.

- `$meta`:

  Named list: `rate_conversion`, `method`, `years_used` (integer vector
  of all years that entered any category's calibration),
  `exclude_years`, `package_version`.

Additionally, `attr(result, "rate_conversion")` is set to the
`rate_conversion` value for backward compatibility with downstream code.

## Details

### Estimation methods

**`"ols"`**: Fits `standings_position ~ category_total` via OLS for each
category-year. Standings position is the direction-aware rank (1 = last
place, `n` = first place). For inverse categories (ERA, WHIP) the rank
is flipped — `n + 1 - rank(total)` — so that lower totals receive higher
rank numbers and the OLS slope is negative. The denominator is
`1 / |weighted_mean_slope|`.

**`"gap"`**: Mean of adjacent gaps between sorted totals,
`mean(diff(sort(totals)))`, equivalent to `range / (n - 1)`. No rank
fitting required; sign convention does not apply.

**`"trimmed_gap"`**: Same as `"gap"` but with 10% trimming from each end
of the gap vector to reduce sensitivity to outliers.

**`"sd"`**: `sd(totals) * (n - 1) / E[R_n]`, where `E[R_n]` is the
expected range of `n` standard normal variables (see
[`expected_range_normal()`](https://jdenn0514.github.io/rotostats/reference/expected_range_normal.md)).
This method targets a different estimand than OLS — its output is
approximately 12x larger for typical 12-team leagues. Do not mix OLS and
SD denominators across categories.

### Backward compatibility

Code written against the old named-numeric-vector API continues to work
without modification:

    denoms <- sgp_denominators(history, ...)
    attr(denoms, "rate_conversion")  # character
    as.numeric(denoms)               # named numeric vector
    denoms["HR"]                     # numeric scalar
    names(denoms)                    # character vector of category names
    length(denoms)                   # integer

### Dependency notes

The `league_history()` constructor is not yet implemented. A plain list
with a `$team_season` data.frame is accepted as a duck-type fallback.

[`convert_rate_stats()`](https://jdenn0514.github.io/rotostats/reference/convert_rate_stats.md)
is a stub only. The `rate_conversion = "fixed_baseline"` path aborts
with `rotostats_error_not_implemented`.

## Caveats

**Jensen's-inequality undercoverage of bootstrap CIs at small
`n_years`.** The OLS denominator is `d = 1 / |beta|`. Because the
inverse is a convex function, Jensen's inequality implies
`E[1/|beta|] > 1/E[|beta|]`, producing a small upward bias in the
denominator estimate. At `n_years = 6` this bias is approximately 1% of
the true denominator (statistically confirmed by the sgp-denominators
Monte Carlo study).

The **percentile bootstrap CI** is centered on the biased estimate
rather than on the true denominator, so the lower CI bound
systematically lies above the truth too often, yielding empirical
coverage of approximately **84-85%** at nominal 95% when `n_years <= 6`.
At `n_years >= 10` coverage is materially better. This is not an
implementation defect — it is a known property of the percentile
bootstrap under upward-biased estimators.

**Practical guidance:**

- For `n_years <= 6`, treat percentile bootstrap CIs as approximate (~10
  percentage-point undercoverage). The point estimates remain unbiased
  in relative terms (bias \< 2% of denominator value).

- If tighter coverage is required, BCa (bias-corrected and accelerated)
  bootstrap corrects for this bias and is a planned enhancement.

- For `n_years >= 10`, percentile CIs are adequate for most
  applications.

## See also

[`cal()`](https://jdenn0514.github.io/rotostats/reference/cal.md),
[`cal_spec()`](https://jdenn0514.github.io/rotostats/reference/cal_spec.md),
[`flat()`](https://jdenn0514.github.io/rotostats/reference/flat.md),
[`exp_decay()`](https://jdenn0514.github.io/rotostats/reference/exp_decay.md),
[`linear_decay()`](https://jdenn0514.github.io/rotostats/reference/linear_decay.md),
[`after()`](https://jdenn0514.github.io/rotostats/reference/after.md),
[`before()`](https://jdenn0514.github.io/rotostats/reference/before.md),
[`between()`](https://jdenn0514.github.io/rotostats/reference/between.md),
[`last()`](https://jdenn0514.github.io/rotostats/reference/last.md),
[`expected_range_normal()`](https://jdenn0514.github.io/rotostats/reference/expected_range_normal.md),
[`convert_rate_stats()`](https://jdenn0514.github.io/rotostats/reference/convert_rate_stats.md)

## Examples

``` r
# Minimal example with a duck-typed league history:
history <- list(
  team_season = data.frame(
    year    = c(2022L, 2022L, 2022L, 2023L, 2023L, 2023L),
    team_id = rep(c("A", "B", "C"), 2),
    HR      = c(150, 180, 210, 155, 185, 215),
    stringsAsFactors = FALSE
  )
)
denoms <- sgp_denominators(
  history,
  scoring_categories = "HR",
  exclude_years      = integer(0)
)
#> Normalizing column names to uppercase: year -> YEAR, team_id -> TEAM_ID.
#> `roto_pts_col` ("ROTO_PTS") not found in `team_season`. Standings validation
#> skipped.
#> Warning: Category "HR" has only 2 season(s) in its calibration window (< 3).
#> Warning: essentially perfect fit: summary may be unreliable
#> Warning: essentially perfect fit: summary may be unreliable
denoms["HR"]     # numeric scalar denominator
#> HR 
#> 30 
names(denoms)    # "HR"
#> [1] "HR"
as.numeric(denoms)   # named numeric vector
#> HR 
#> 30 

# Per-category override: restrict SB to post-2022, keep global window for HR:
if (FALSE) { # \dontrun{
denoms2 <- sgp_denominators(
  history,
  scoring_categories = c("HR", "SB"),
  category_spec = cal_spec(
    SB = cal(years = after(2022))
  )
)
} # }

# Bootstrap CIs (year-level percentile, 500 replicates):
if (FALSE) { # \dontrun{
denoms_ci <- sgp_denominators(
  history,
  scoring_categories = "HR",
  exclude_years      = integer(0),
  n_bootstrap        = 500L
)
denoms_ci$bootstrap_ci
} # }
```
