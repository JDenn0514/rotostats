# Metric Spec: SGP Conversion (`sgp()`, `sgp_denominators()`)

> **Status:** Draft · 2026-04-16
> **Q1 Conceptual:** Complete · **Q2 Statistical:** Pending code audit · **Q3 Decision:** Pending validation
>
> **Open Q1 questions:** 0

---

## Purpose

Calibrate per-category standings-gain-point denominators from league history and convert
projected player stats into SGP units — the common currency for cross-category talent
comparison in rotisserie leagues.

---

## Formal Definition

### `sgp_denominators(league_history, ...)`

The SGP denominator for a category is the number of units of that stat a team needs to
gain to move up one place in the category standings. Calibrated from team-level season
totals in league history.

**Formula:** Controlled by `denominator_method`:

- `"ols"` **(default):** OLS regression of per-category standings rank against team
  category totals within each year, fitted with `lm(rank ~ total)`, slopes then averaged
  across years (weighted if `weights` is set). The SGP denominator for category c is
  `1 / β̂_c`, where `β̂_c` is the weighted mean of the within-year OLS slopes. The slope
  is Δrank/Δtotal; inverting gives Δtotal/Δrank — the units needed to move one standings
  place. Uses all n data points — outlier teams are one observation among n rather than
  anchoring the calculation. Community-standard improvement over the endpoint formula
  (Bell, Smart Fantasy Baseball, 2014).
- `"gap"` _(legacy):_ Average of all pairwise adjacent gaps between teams sorted by
  category total within each year, then averaged across years. Mathematically equivalent
  to `range / (n_teams − 1)` via telescoping sum — maximally sensitive to the single
  best and worst team. Retained for backward compatibility. Prefer `"ols"`.
- `"trimmed_gap"`: Same as `"gap"` but with 10% of extreme pairs trimmed before
  averaging. Less sensitive to outlier teams than `"gap"` but still range-based.
  Generally inferior to `"ols"` when standings data are available.
- `"sd"`: Standard deviation of team-level category totals, scaled by `E[R_n] /
  (n_teams − 1)`, where `E[R_n]` is the expected range of `n_teams` standard normal
  variables. Computed via numerical integration using base R `integrate()`:

  ```r
  expected_range_normal <- function(n) {
    integrate(function(x) 1 - pnorm(x)^n - (1 - pnorm(x))^n,
              lower = -Inf, upper = Inf)$value
  }
  ```

  Expected values for common league sizes: ~3.08 (n=10), ~3.26 (n=12), ~3.52 (n=15).
  These serve as built-in unit test anchors. Does not require standings data; use as a
  fallback when standings data are unavailable. Assumes team totals are approximately
  normally distributed. The autoresearch plan will also compare an empirically calibrated
  constant (ratio of SD to SLOPE denominator on held-out data) against the
  order-statistics formula.

**Calibration window:** Controlled by `years` parameter (global default) and per-category
overrides in `category_spec`.

- Default window: **all non-excluded seasons** (see Q1-SGP-1, closed).
- **2020 excluded by default** (60-game COVID season). Counting stat denominators are
  directly affected by compressed totals. Rate stats (ERA, WHIP, AVG) are normalized per
  IP/AB and not systematically biased by game count alone, but smaller IP/AB samples
  inflate team-level rate stat variance — which distorts gap and OLS denominator
  estimates. Exclusion is retained for all categories on practical grounds. Override via
  `exclude_years`.
- **IQR filter** (optional, off by default): exclude any season where a team's category
  total is > 1.5 IQR from the league median. Controlled by `outlier_filter`.
- **Per-category override:** `category_spec = cal_spec(SB = cal(years = after(2022)))`
  sets a different window for SB only; all other categories use the global `years` value.
  Year-window helpers: `after(year)`, `before(year)`, `between(y1, y2)`, `last(n)`, `"all"`.

**Year weighting:** Controlled by `weights` parameter (global default) and per-category
overrides in `category_spec`. Accepts a string shorthand, a weight constructor, or any
`function(years_ago) → weight` for custom decay shapes. `decay_lambda` is removed as a
standalone parameter; lambda is now a parameter of `exp_decay()`.

- `"flat"` / `flat()` **(default):** All years weighted equally.
- `"linear"` / `linear_decay()`: Weight = `year_rank / n_years`; most recent year = 1.0.
- `exp_decay(lambda)`: Weight = `lambda ^ years_ago`. _Default λ TBD — candidates are
  λ = 0.9 (gentle decay) and λ = 0.7 (aggressive recency). To be resolved empirically
  (see autoresearch plan §2c)._
- Custom: any `function(years_ago) → weight`, where `years_ago = 0` is the most recent season.
- **Per-category override:** `category_spec = cal_spec(SB = cal(weights = exp_decay(0.7)))`
  applies decay to SB only; all other categories use the global `weights` value.

**2023 SB structural break:** The 2023 shift ban and larger bases approximately doubled
AL-wide SB. Handled via per-category calibration overrides (see Q1-SGP-3, closed).
Recommended default: `SB = cal(years = after(2022), weights = exp_decay(0.7))` inside
`category_spec`.

Emits `cli_warn()` when any category's effective calibration window spans pre- and
post-2023 with flat weighting, naming the affected category specifically.

**`league_history` is required.** There is no public fallback (see Q1-SGP-8, closed).
The purpose of SGP is calibration to a specific league's history; without that history
the method is not meaningful. Users without league history should use z-scores instead.

**`league_history` schema:** A `league_history` object constructed via `league_history()` — see `plans/implementation/league-history-impl.md` for full schema. `sgp_denominators()` uses the `$team_season` component. Cross-validation of category column names against `config$categories` happens here at call time, not in the constructor.

Returns a named numeric vector: `c(HR = 12.3, R = 18.7, RBI = 19.1, SB = 6.4, AVG = 0.0023, ...)`.

The returned vector also carries `attr(result, "rate_conversion")` set to the value of the `rate_conversion` parameter used during calibration (e.g., `"blended_pool"` or `"fixed_baseline"`). Downstream functions use this attribute to detect invalid method pairings.

---

### `convert_rate_stats(league_history, baseline_era, baseline_whip, baseline_avg, projections, ...)`

Transforms a `league_history` data frame: replaces ERA, WHIP, and AVG columns with
their counting-equivalent forms (ExER, ExWH, ExH) using the Benson / Mosey formulas.
Returns a transformed data frame that can be passed directly to `sgp_denominators()`.

```
ExER  = (baseline_ERA  × team_IP / 9) − team_ER
ExWH  = (baseline_WHIP × team_IP)     − team_WH
ExH   = team_H − (baseline_AVG × team_AB)
```

**Baseline resolution (in priority order):**

1. Explicit arguments (`baseline_era`, `baseline_whip`, `baseline_avg`) — most accurate
2. Derived from `projections` — pool mean rate stat computed from the top `pool_size_p`
   pitchers (or top `pool_size_h` hitters for AVG) by projected playing time, consistent
   with `pool_baseline = "projection_pool"` in `blended_pool`; requires `projections` to
   be supplied
3. Derived from `league_history` mean — least accurate, requires no extra input

Emits `cli_inform()` listing the derived baseline values when auto-derived (options 2
or 3), so users can verify them.

**Returns** a data frame of the same shape as `league_history` with ERA/WHIP/AVG
replaced by ExER/ExWH/ExH. The returned object carries class `sgp_history_transformed`
so that `sgp_denominators()` auto-detects it and skips re-transformation.

This function is called internally by `sgp_denominators()` when
`rate_conversion = "fixed_baseline"` and raw `league_history` is supplied. Users who
want to inspect the intermediate transformed data (e.g., to verify baselines) should
call it explicitly before passing to `sgp_denominators()`.

---

### `sgp(projections, denominators, ...)`

Converts projected stats into SGP units per player.

**Counting stats:**

```
sgp[i, c] = projected_stat[i, c] / denominator[c]
```

**Rate stats (ERA, WHIP, AVG):** Rate stats are not additive across players; a player's
ERA contribution depends on how many innings they pitch relative to the full team pool.
Method controlled by `rate_conversion`:

- `"blended_pool"` **(default):** Player is blended into an assumed average team pool.
  The marginal change in the pool's combined rate stat is divided by the SGP denominator:
  ```
  ERA_SGP[i]  = (avg_ERA  − (pool_ER + player_ER) × 9 / (pool_IP + player_IP)) / era_denom
  WHIP_SGP[i] = (avg_WHIP − (pool_WH + player_WH) / (pool_IP + player_IP))     / whip_denom
  AVG_SGP[i]  = ((pool_H  + player_H) / (pool_AB  + player_AB) − avg_AVG)      / avg_denom
  ```
  Pool constants (`pool_ER`, `pool_IP`, etc.) represent the average team's contribution
  from the remaining rostered pitchers / batters. Controlled by `pool_baseline`:

  - `"projection_pool"` **(default):** Pool derived from the top N projected pitchers
    (or batters for AVG) by projected playing time in the current season. Pool size is
    derived from `league_config`:

    ```
    pool_size_p = config$n_teams × sum(config$pitcher_slots)
    pool_size_h = config$n_teams × sum(config$roster_slots[primary_hitter_slots])
    ```

    Both `sgp()` and `replacement_level()` derive these values from the internal `pool_sizes(config)` helper (see `plans/implementation/league-config-impl.md`) to avoid duplicating the formula.

    where `primary_hitter_slots` = {C, 1B, 2B, 3B, SS, OF, DH} — UTIL, MI, CI
    excluded because combo slots have no independent pool and each player is counted
    once at their valuation position (consistent with `replacement_level()`). Example:
    12 teams × 9 pitcher slots = top 108 pitchers. Pool totals computed once and
    applied to all evaluated players (fixed-constant approximation). Approximation
    error ≈ `player_IP / (pool_IP + player_IP)` — small for relievers (~5%),
    moderate for elite starters (~15%). Smart Fantasy Baseball standard approach.
  - `"per_player"`: Pool totals recomputed for each player by summing over all *other*
    projected pitchers / batters on an average roster. Theoretically correct; eliminates
    the fixed-constant approximation. No published community precedent; higher
    computational cost.
  - `"universal_constants"`: Fixed historical playing-time constants (e.g., 192.5 IP
    per pitcher, 554.5 AB per batter). Requires no projection data at call time; least
    accurate.

  All three `pool_baseline` options are tested empirically in the autoresearch plan
  (§2e). Default is `"projection_pool"` pending empirical results. `avg_ERA` /
  `avg_WHIP` / `avg_AVG` in all cases is the IP-weighted (ERA, WHIP) or
  AB-weighted (AVG) mean across all teams in the most recent non-excluded year of
  `league_history` (after applying `exclude_years`). If a user excludes 2023, for
  example, `avg_ERA` is drawn from 2022. Emits `cli_inform()` naming the year used.

- `"fixed_baseline"` (Zola / Benson / Mosey counting-equivalent approach):
  Converts rate stats to counting-stat equivalents using a fixed baseline, then divides
  by a denominator calibrated in those same counting-equivalent units:
  ```
  ExER[i]  = (baseline_ERA  × player_IP / 9) − player_ER   → ExER[i]  / era_denom
  ExWH[i]  = (baseline_WHIP × player_IP)     − player_WH   → ExWH[i]  / whip_denom
  ExH[i]   = player_H − (baseline_AVG × player_AB)         → ExH[i]   / avg_denom
  ```
  **Baseline:** Mean rate stat of the top `pool_size_p` pitchers (or top `pool_size_h`
  hitters for AVG) by projected playing time — the same population as
  `pool_baseline = "projection_pool"` in `blended_pool`. Not the last-place team rate
  stat. Supplied via
  `baseline_era`, `baseline_whip`, `baseline_avg`, or derived automatically from
  `projections` when supplied. When neither is provided, derived from the league
  history mean (less accurate but requires no projection data).

  **Denominator calibration:** `sgp_denominators()` must receive history with
  ExER/ExWH/ExH columns so that denominators are in counting-equivalent units. Two
  paths (see `convert_rate_stats()` below):

  1. **Automatic:** Pass raw `league_history` to `sgp_denominators()` with
     `rate_conversion = "fixed_baseline"`. Calls `convert_rate_stats()` internally.
  2. **Explicit:** Call `convert_rate_stats(league_history, ...)` directly to produce
     an inspectable transformed object, then pass it to `sgp_denominators()`. The
     function auto-detects ExER/ExWH/ExH columns and skips re-transformation.

  Roster-agnostic; no pool argument required.

- `"team_ip_normalized"`: **Not recommended** — makes rankings league-depth-sensitive.
  Retained for backward-compatibility testing only.

_Default is `"blended_pool"`. Both `"blended_pool"` and `"fixed_baseline"` are tested
empirically in the autoresearch plan (§2e)._

When `sgp_denominators` output is supplied to `replacement_level()` with
`boundary_rate_method = "sgp_pool"`, the `rate_conversion` attribute on the denominators
is checked. If it is `"fixed_baseline"`, `replacement_level()` aborts because the
denominator units (counting-equivalents) are incompatible with pool-blending ranking.
(`boundary_rate_method` is a parameter in `replacement_level()`, not `sgp()`.)

**`total_sgp` computation:** `total_sgp` is the direct sum of SGP across all scored
categories — counting and rate stats alike. Both `"blended_pool"` and `"fixed_baseline"`
produce rate stat SGP in standings-point units, so no separate aggregation step is needed.
`total_sgp` is directly comparable across all players regardless of position. The hitter /
pitcher budget split is a dollar allocation concern handled downstream in `dollar_values()`,
not an SGP comparability concern.

**Negative SGP:** A player with ERA above the replacement level produces negative
`sgp_ERA` under all methods. Negative per-category SGP is valid and meaningful (the
player hurts that category). `total_sgp` may be negative for poor pitchers. These players
will be clipped to $0 in `dollar_values()` but are retained with their full values in
`sgp()` output for diagnostic purposes.

**Edge cases:**
- Player with 0 projected IP or 0 projected AB: returns `sgp_[rate_stat] = NA` with a
  `cli_warn()` if the category is scored. Counted stats return 0.
- Player missing a scored category in projections: returns `NA` for that category column
  with a `cli_warn()`. _Whether to error or warn is TBD._
- Combo stats (OPS, SVHD, QS): use direct projection column when present; fall back to
  component computation with `cli_warn()` when absent (see Q1-SGP-6).

Returns a data frame: one row per player, one `sgp_[cat]` column per scored category,
plus `total_sgp` (sum across all categories, counting and rate).

---

## Why This Measure

SGP denominators are calibrated from actual league outcomes, not projection distributions.
A denominator of 15 HR means 15 HR moved a team one standings place in this specific
league — not a theoretical quantity derived from the player pool. This makes SGP a better
currency for auction valuation than z-scores when league history is available: it measures
how much the standings needle actually moves, not how unusual a player is relative to peers.

The primary alternative is z-scores, which are robust when league history is unavailable
but do not distinguish between a stat that separates standings places and one that does not.
Both methods are supported downstream in `par()` and `dollar_values()`.

**Rate stat method choice:** `blended_pool` computes marginal contribution — each pitcher
is blended into an average team's existing pool, so their SGP is context-dependent. The
hitter/pitcher budget split must be supplied as an external assumption because marginal
rate-stat SGP and counting-stat SGP do not share a common unit. `fixed_baseline` converts
rate stats to counting-equivalents (ExER, ExWH, ExH) using a fixed baseline scalar. Each
player's SGP is then a standalone property independent of roster context, and because
ExER/ExWH/ExH are in the same units as HR, R, RBI, and SB, all SGP values are directly
addable and the hitter/pitcher budget split emerges from the total SGP ratio rather than
being assumed. Prefer `fixed_baseline` when roster-agnostic values are required (keeper
and trade valuation) or when an emergent budget split is desired. `blended_pool` is the
Smart Fantasy Baseball/FanGraphs standard and the default pending empirical comparison.

---

## Assumptions

| Assumption | Testable? | How to Test / Basis |
|-----------|-----------|---------------------|
| `"ols"` method produces better denominators than `"gap"` and `"sd"` methods | Yes | LOYO CV: compare Spearman ρ across all three methods on Moonlight Graham data |
| Denominators are stable year-over-year within the calibration window | Yes | Compute denominators by year; check CV; flag high-variance categories |
| 2023 marks a structural break for SB | Yes | Compare pre/post-2023 year-by-year SB denominators; F-test for break |
| `years = "all"` maximizes denominator stability for non-SB categories | Yes | LOYO CV post-implementation (autoresearch plan §2b) |
| `exp_decay(0.9)` global weighting improves over flat on stable categories | Yes | LOYO CV post-implementation (autoresearch plan §2c) |
| 2020 is unrepresentative and should be excluded by default | No | Theoretical (60-game season); accepted on practical grounds |
| `"blended_pool"` rate stat method produces better valuations than `"fixed_baseline"` | Yes | LOYO CV comparing both methods (autoresearch plan §2e) |


---

## Interface

### `sgp_denominators()`

```r
sgp_denominators(
  league_history,
  years           = "all",
  weights         = exp_decay(0.9),
  method          = "ols",
  category_spec   = NULL,
  outlier_filter  = FALSE,
  exclude_years   = 2020,
  rate_conversion = "blended_pool",
  roto_pts_col    = "roto_pts"
)
```

| Parameter | Type | Required | Default | Notes |
|-----------|------|----------|---------|-------|
| `league_history` | `league_history` S3 object | Yes | — | Constructed via `league_history()`; `sgp_denominators()` uses the `$team_season` component. Category column names validated against `config$categories` at call time |
| `years` | integer, year-window helper, or `"all"` | No | `"all"` | Global calibration window applied to all categories. Year-window helpers: `after(year)`, `before(year)`, `between(y1, y2)`, `last(n)`, `"all"`. Per-category override via `category_spec` |
| `weights` | character, weight constructor, or `function(years_ago)` | No | `exp_decay(0.9)` | Global weighting applied to all categories. String shorthands: `"flat"`, `"linear"`. Constructors: `flat()`, `linear_decay()`, `exp_decay(lambda)`. Custom: any `function(years_ago)` where `years_ago = 0` is the most recent season. Per-category override via `category_spec` |
| `method` | character | No | `"ols"` | Denominator estimation method. One of `"ols"`, `"gap"`, `"trimmed_gap"`, `"sd"`. Global; no per-category override |
| `category_spec` | `cal_spec` object | No | `NULL` | Per-category overrides for `years` and `weights`. Must be constructed with `cal_spec(SB = cal(...))`. Raw `list()` rejected at construction time |
| `outlier_filter` | logical | No | `FALSE` | When `TRUE`, excludes team-season rows where a category total is > 1.5 IQR from the league median for that category-year |
| `exclude_years` | integer or integer vector | No | `2020` | Years excluded from all calibration windows regardless of `years` setting |
| `inverse_categories` | character vector or `NULL` | No | `NULL` | Categories whose OLS rank is direction-flipped (`n + 1 - rank(total)`) before fitting. Lower totals in these categories receive higher standings positions. Default `NULL` triggers three-layer resolution: (1) this explicit argument when non-NULL (full replacement — config is ignored); (2) `config$inverse_categories` when `config` is passed and non-NULL; (3) `intersect(scoring_categories, inverse_categories())` (package default — preserves ERA/WHIP behavior when scored). Normalized to uppercase internally. When passed explicitly, must be a subset of the effective scored-category set; otherwise aborts with `rotostats_error_invalid_inverse_categories`. Pass `character(0)` to disable all direction flips. |
| `config` | `league_config` S3 object | No | `NULL` | Optional league configuration from [league_config()]. When non-NULL, `config$inverse_categories` is used as Layer-2 fallback when `inverse_categories` is `NULL`. No other fields of `config` are consulted by this function. |
| `rate_conversion` | character | No | `"blended_pool"` | One of `"blended_pool"`, `"fixed_baseline"`. When `"fixed_baseline"`, calls `convert_rate_stats()` internally before calibration unless `league_history` already carries class `sgp_history_transformed`. Stored as `attr(result, "rate_conversion")` on the returned vector |
| `roto_pts_col` | character | No | `"roto_pts"` | Column name in `league_history$team_season` holding total roto points. Used only for the optional standings correlation validation check |

**Returns:** Named numeric vector of SGP denominators, e.g. `c(HR = 12.3, R = 18.7, RBI = 19.1, ...)`. Carries `attr(result, "rate_conversion")` set to the `rate_conversion` value used during calibration.

---

### `convert_rate_stats()`

```r
convert_rate_stats(
  league_history,
  baseline_era  = NULL,
  baseline_whip = NULL,
  baseline_avg  = NULL,
  projections   = NULL,
  league_config = NULL
)
```

| Parameter | Type | Required | Default | Notes |
|-----------|------|----------|---------|-------|
| `league_history` | `league_history` S3 object or data frame | Yes | — | Source of ERA, WHIP, AVG columns to transform |
| `baseline_era` | numeric | No | `NULL` | Explicit ERA baseline scalar. When `NULL`, derived from `projections` pool mean (option 2) or `league_history` mean (option 3) per baseline resolution order |
| `baseline_whip` | numeric | No | `NULL` | Explicit WHIP baseline scalar. Same fallback order |
| `baseline_avg` | numeric | No | `NULL` | Explicit AVG baseline scalar. Same fallback order |
| `projections` | data frame | No | `NULL` | Player-level projected stat lines. When supplied, baselines are derived from the top `pool_size_p` pitchers / `pool_size_h` hitters by projected playing time |
| `league_config` | `league_config` S3 object | No | `NULL` | Required to derive `pool_size_p` / `pool_size_h` when `projections` is supplied and pool sizes are not otherwise available |

**Returns:** Data frame of same shape as `league_history$team_season` with ERA, WHIP, AVG replaced by ExER, ExWH, ExH respectively. Carries class `sgp_history_transformed`; `sgp_denominators()` auto-detects this class and skips re-transformation when the object is passed directly.

---

### `sgp()`

```r
sgp(
  projections,
  denominators,
  rate_conversion    = "blended_pool",
  pool_baseline      = "projection_pool",
  league_config      = NULL,
  baseline_era       = NULL,
  baseline_whip      = NULL,
  baseline_avg       = NULL
)
```

| Parameter | Type | Required | Default | Notes |
|-----------|------|----------|---------|-------|
| `projections` | data frame | Yes | — | Player-level projected stat lines; one row per player. Must include a column for each scored category |
| `denominators` | named numeric vector | Yes | — | Output of `sgp_denominators()`. Must carry `attr(denominators, "rate_conversion")`; used to detect method incompatibilities |
| `rate_conversion` | character | No | `"blended_pool"` | One of `"blended_pool"`, `"fixed_baseline"`, `"team_ip_normalized"` (last not recommended). Should match `attr(denominators, "rate_conversion")` |
| `pool_baseline` | character | No | `"projection_pool"` | One of `"projection_pool"`, `"per_player"`, `"universal_constants"`. Controls how the pool context is constructed for `rate_conversion = "blended_pool"`. Ignored when `rate_conversion = "fixed_baseline"` |
| `league_config` | `league_config` S3 object | Conditional | `NULL` | Required when `pool_baseline = "projection_pool"`. Used by `pool_sizes(config)` to derive `pool_size_p` and `pool_size_h` |
| `baseline_era` | numeric | No | `NULL` | Explicit ERA baseline for `rate_conversion = "fixed_baseline"`. Auto-derived from `projections` pool mean or `denominators` history when `NULL` |
| `baseline_whip` | numeric | No | `NULL` | Explicit WHIP baseline. Same fallback |
| `baseline_avg` | numeric | No | `NULL` | Explicit AVG baseline. Same fallback |

**Outputs:**

Returns a data frame with one row per player:

| Column | Type | Description |
|--------|------|-------------|
| `sgp_[cat]` | numeric | SGP per category; one column per scored category |
| `total_sgp` | numeric | Sum of `sgp_[cat]` across all scored categories |

No output attributes. `attr(denominators, "rate_conversion")` on the input denominators is consumed at call time to detect method incompatibilities; no corresponding attribute is set on the output.

---

## Decision This Informs

- **Primary use:** Produce SGP values that feed `par()` for talent ranking and
  `dollar_values()` for auction pricing
- **Consumer:** `par()`, `dollar_values()`, and directly by users wanting raw SGP
  standings-point output
- **How consumed:** `sgp()` output (per-player SGP) feeds `par()` — `par()` handles replacement anchoring; all SGP conversion including rate stats happens here. `sgp_denominators()` output optionally feeds `replacement_level()` when `sort_by = "sgp"`
- **Sensitivity:** Denominator uncertainty propagates linearly into all downstream SGP,
  PAR, and dollar values — a category with year-over-year CV of 25% produces SGP values
  uncertain to roughly the same degree. A 10% shift in the HR denominator produces a 10%
  shift in HR-derived PAR for every player. Category-dominant players (elite SB, elite K)
  are most sensitive. High-CV categories should be interpreted with lower confidence
  downstream. Use the CV runtime check to identify which categories carry the most
  uncertainty before relying on downstream values.

---

## Dependencies

**Upstream:**
- `league_history`: team-level season totals by category and year. Required; see schema in `sgp_denominators()` above.
- `projections`: player-level projected stat lines
- `league_config`: required when `pool_baseline = "projection_pool"`

**Downstream:**
- `par()`: consumes `sgp()` output per player
- `dollar_values()`: calls `sgp()` internally when `method = "sgp"`
- `replacement_level()`: optionally consumes `sgp_denominators()` when
  `sort_by = "sgp"` or `boundary_rate_method = "sgp_pool"`

**Sibling functions:**
- `par()`: the replacement-anchored extension of `sgp()`; `sgp()` is the internal
  implementation called by `par()`. Use `sgp()` directly when replacement anchoring is
  not needed (raw production diagnostics, rate stat checks).
- `zaa()`: the z-score path to the same cross-category comparison; use when league
  history for denominator calibration is unavailable.

---

## Error Handling

> Error class names are assigned for conditions where the class is already known. All remaining class names are **TBD** — to be assigned consistently in `plans/error-messages.md` before `R/sgp.R` is implemented.

| Condition | Function | Handler | Error Class |
|-----------|----------|---------|-------------|
| `league_history` missing `year` or `team_id` column | `sgp_denominators()` | `cli_abort()` | TBD |
| Scored category column absent from `league_history` | `sgp_denominators()` | `cli_abort()`, names the missing category | TBD |
| Any element of `inverse_categories` (after uppercase normalization) not present in effective scored-category set | `sgp_denominators()` | `cli_abort()`, names offending elements and valid set | `rotostats_error_invalid_inverse_categories` |
| `category_spec` constructed with raw `list()` instead of `cal_spec()` | `sgp_denominators()` / `cal_spec()` | `cli_abort()` at construction time | TBD |
| `roto_pts` column absent from `league_history` | `sgp_denominators()` | `cli_inform()` — standings validation check skipped | — |
| Column names normalized to uppercase | `sgp_denominators()` | `cli_inform()` (once), names changed columns | — |
| Year used for `avg_ERA` / `avg_WHIP` / `avg_AVG` pool baseline | `sgp()` | `cli_inform()`, names the year used | — |
| Baselines auto-derived from `projections` pool or `league_history` mean | `convert_rate_stats()` | `cli_inform()`, lists derived baseline values | — |
| SVHD column absent — always derived as `SV + HLD` | `sgp()` | `rlang::inform()` with `.frequency = "once"` per session — notes definition and directs users to verify it matches their league's SVHD rules | — |
| Effective calibration window spans pre- and post-2023 with flat weighting | `sgp_denominators()` | `cli_warn()`, names affected category | TBD |
| Category's effective calibration window contains fewer than 3 complete seasons | `sgp_denominators()` | `cli_warn()` per affected category, names the category | TBD |
| `NA` in a scored category column | `sgp_denominators()` | `cli_warn()`, names affected team-year pairs; those rows excluded from calibration | TBD |
| Unrecognized column name in `league_history` | `sgp_denominators()` | `cli_warn()` (once) | TBD |
| Year with different team count than other years | `sgp_denominators()` | `cli_warn()` | TBD |
| OLS within-year R² < 0.80 for a category | `sgp_denominators()` | `cli_warn()`, names category and year | TBD |
| Denominator year-over-year CV > 20% for a category | `sgp_denominators()` | `cli_warn()`, names category | TBD |
| Player has 0 projected IP or 0 projected AB for a scored rate stat | `sgp()` | `sgp_[stat] = NA` + `cli_warn()` | TBD |
| Player missing a scored category in `projections` | `sgp()` | `NA` for that column + `cli_warn()` | TBD |
| QS column absent from `projections` (e.g., ZiPS) | `sgp()` | `cli_warn()` + `NA` for all QS rows | TBD |

---

## Known Validity Threats

### Conceptual (Q1)

---

**Q1-SGP-1: Optimal calibration window length** _(closed — 2026-04-16)_

**Decision:** `years = "all"` — use all non-excluded seasons. Maximizes data for stable
categories (HR, R, RBI). SB contamination from pre-2023 norms is handled by the
per-category `SB = cal(years = after(2022))` override, not by truncating the global window.
Autoresearch LOYO CV will validate post-implementation.

---

**Q1-SGP-2: Year weighting scheme** _(closed — 2026-04-16)_

**Decision:** `weights = exp_decay(0.9)` — gentle exponential recency weighting globally.
Applies modest downweighting to older seasons for all categories; SB uses the more
aggressive `exp_decay(0.7)` override. Autoresearch LOYO CV will validate the λ choice
post-implementation.

---

**Q1-SGP-3: 2023 SB structural break strategy** _(closed — 2026-04-12)_

**Decision:** The three original candidates (truncate, exponential decay, separate
denominators) are unified into a single per-category calibration API rather than being
mutually exclusive switches. Each category controls its own window and weighting
independently. Global top-level arguments (`years`, `weights`, `method`) set defaults for
all categories; `category_spec = cal_spec(...)` provides per-category overrides for any
category that needs different treatment. `category_spec` is purely additive — it never
changes the global defaults for categories not listed.

**API shape:**

```r
sgp_denominators(
  league_history,
  years         = "all",         # global default for all categories
  weights       = exp_decay(0.9), # global default; string, weight fn, or custom function
  method        = "ols",    # global default
  category_spec = cal_spec( # per-category overrides; purely additive
    SB = cal(years = after(2022), weights = exp_decay(0.7))
  )
)
```

`cal()` validates field names at construction time. Each `cal()` entry inherits from the
global args for any field not explicitly specified. `cal()` is required — raw `list()` is
not accepted.

**Original candidates as API expressions:**

| Original candidate | API expression |
|--------------------|----------------|
| A. Truncate SB to post-2022 | `SB = cal(years = after(2022))` |
| B. Exponential decay on SB | `SB = cal(weights = exp_decay(0.7))` |
| A + B (truncate and decay) | `SB = cal(years = after(2022), weights = exp_decay(0.7))` |
| C. Pre/post blend | Subsumed — covered by window + weights combination |

**Recommended default:** `years = "all"`, `weights = exp_decay(0.9)` globally, with
`SB = cal(years = after(2022), weights = exp_decay(0.7))` as the named override
reflecting the 2023 structural break.

**Thin history interaction:** The 3-season warning (Q1-SGP-9) fires per-category using
each category's effective year set, not the global window length. A category whose
per-category window contains fewer than 3 complete seasons triggers its own `cli_warn()`
naming that category specifically.

---

**Q1-SGP-4: Rate stat SGP method** _(closed — 2026-04-10)_

**Decision:** Two methods supported — `"blended_pool"` (default) and `"fixed_baseline"`.
Both produce rate stat SGP in standings-point units, directly summable with counting stats.
`"team_ip_normalized"` retained for backward-compatibility testing only.

- `"blended_pool"`: Smart Fantasy Baseball / FanGraphs standard. Player blended into
  average team pool; marginal ERA/WHIP/AVG delta divided by SGP denominator. Requires
  pool context derived from league history.
- `"fixed_baseline"`: Zola / Benson / Mosey counting-equivalent approach. Converts to
  ExER/ExWH/ExH first, then divides by counting-equivalent denominators. Roster-agnostic.

Both methods are tested empirically in the autoresearch plan (§2e). Default is
`"blended_pool"` pending empirical results.

---

**Q1-SGP-5: `total_sgp` aggregation for rate stats** _(closed — 2026-04-10)_

**Decision:** `total_sgp` is the direct sum of SGP across all scored categories. Both
`"blended_pool"` and `"fixed_baseline"` produce rate stat SGP in standings-point units,
so no separate aggregation step is needed and no deferral to `par()` is required.

`total_sgp` is directly comparable across all players — a pitcher with 5.0 `total_sgp`
and a hitter with 5.0 `total_sgp` contribute equally to their team's final standings.
The hitter/pitcher budget split is a dollar allocation concern handled in `dollar_values()`,
not an SGP comparability concern.

---

**Q1-SGP-6: Combo stat handling** _(closed — 2026-04-10)_

**Decision:** Use the direct projection column when available; derive from components only
when absent. Per-stat behavior:

| Stat | Behavior |
|------|----------|
| OPS | Direct column — present in all sources; use as-is |
| SVHD | Always derived as `SV + HLD` — absent from all projection sources. `rlang::inform()` with `.frequency = "once"` on first call per session, noting the definition and directing users to verify it matches their league's SVHD rules |
| QS | Direct column when available (Steamer, ATC); `cli_warn()` + `NA` when absent (ZiPS) |

**Rationale:** Direct projection columns are authoritative — projection systems have already
made their own methodological choices. Re-deriving from components introduces a second
opportunity for error and can produce values that diverge from the source's intent. The
one-time SVHD inform is warranted because SVHD is never a direct column (always derived)
and hold eligibility criteria vary across statistical providers — for example,
Baseball-Reference and MLB.com award holds for early-inning entries while BIS, STATS, and
Elias do not. Users should verify that their projection source and league history use the
same hold definition, as mismatches will distort denominator calibration. Note: `HLD` and
`HD` are alternative column-name abbreviations for the same stat, not different definitions.

**Documentation:** A note in `get_projections()` docs warns that projection systems may
define or calculate stats differently; users should verify against their source's
methodology. Links to per-source FanGraphs documentation are provided in
`plans/get-projections-impl.md`.

---

**Q1-SGP-7: `league_history` schema** _(closed — 2026-04-12)_

**Decision:** Wide format required. Long-format data should be converted with
`tidyr::pivot_wider()` before passing to `sgp_denominators()`.

**Required columns:**

| Column | Type | Description |
|--------|------|-------------|
| `year` | `<integer>` | Season year |
| `team_id` | `<character>` | Team identifier, stable across years |
| one per scored category | `<numeric>` | Season totals; names match the category names used in `sgp()` |

Canonical category names: `HR`, `R`, `RBI`, `SB`, `AVG`, `ERA`, `WHIP`, `K`, `W`,
`SV`, `HLD`, `QS`, `SVHD`, `OPS`.

**Optional columns:**

| Column | Type | Description |
|--------|------|-------------|
| `roto_pts` | `<numeric>` | Team's total roto points for the season. Name configurable via `roto_pts_col` argument. Used for standings correlation validation check only — not used in denominator computation. |
| `{category}_pts` | `<numeric>` | Per-category roto points (e.g., `HR_pts`, `SB_pts`). Auto-detected by naming convention. When present, used as `standings_pos` in method data frames — handles ties and non-integer scoring correctly. When absent, `standings_pos` is derived from `rank(total, ties.method = "average")` within each year. |

**Column naming:** Names are silently normalized to uppercase before processing. A
one-time `cli_inform()` is emitted if any column names were changed.

**Validation behavior:**

| Condition | Response |
|-----------|----------|
| Missing `year` or `team_id` | `cli_abort()` |
| Scored category column absent | `cli_abort()`, names the missing category |
| `roto_pts` absent | `cli_inform()` — standings validation check skipped |
| Unrecognized column name | `cli_warn()` once |
| Year with different team count than others | `cli_warn()` |
| `NA` in a category column | `cli_warn()`, names affected team-year pairs; those rows excluded from calibration |

**Correction to prior spec:** The previous draft stated that `standings_finish` is required
for the gap method. This was incorrect. The gap method derives per-category team order
from the category totals directly — it requires only the category total columns. Overall
standings data (`roto_pts`) is optional and used solely for the validation sanity check.

---

**Q1-SGP-8: Public fallback denominator source** _(closed — 2026-04-12, won't implement)_

**Decision:** No public fallback. SGP's defining feature is calibration to a specific
league's history — a generic public denominator undermines that. Users without league
history should use z-scores, which are robust and require no calibration data.

---

**Q1-SGP-9: Thin history warning threshold** _(closed — 2026-04-10)_

**Decision:** Warn when the calibration window contains fewer than **3 complete seasons**
of league history. The unit is seasons, not team-season rows — the spec's prior
`n_teams × 3` framing was a unit error.

**Basis:** Tanner Bell (Smart Fantasy Baseball, 2016) explicitly identified 3 seasons of a
single private league as producing "a lot of noise and statistical variation." The statistics
literature threshold for reliable mean estimation (n ≥ 20–25 observations) is reached at
~2–3 seasons for a 12-team league (11 adjacent gaps/season). Three seasons is the community
floor; the warning message should encourage users to supply more history when available and
note that public denominators (e.g., NFBC) are an alternative when history is thin.

**Note:** The 2023 structural break (shift ban + larger bases) raises the question of whether
pre-2023 seasons are meaningfully comparable for SB calibration. This is confirmed empirically
by the ~40% SB increase in 2023 and is the basis for the per-category override above. R and
RBI show no comparable break. See autoresearch plan §2e for LOYO validation.

### Statistical (Q2)
_Pending — fill in after code audit of `R/sgp.R`. Known issue from autoresearch plan:
OLS regression denominator estimator is biased upward (flagged as F3); confirm gap
method implementation is not using OLS under the hood._

**Audit target — `replacement_level()` internal `sgp()` call:** When `sort_by = "sgp"`,
`replacement_level()` calls `sgp()` internally to rank players. Confirm that this call
does **not** pass a `replacement` argument. Replacement level should be identified from
raw total SGP (projected stats / denominators), not from PAR — using `replacement` here
would be both circular (the replacement band doesn't exist yet) and wrong (it would rank
players by value-above-replacement rather than absolute quality, shifting which players
fall at the boundary).

### Decision (Q3)
_Pending — fill in after LOYO validation (autoresearch plan §2). Primary target:
Spearman ρ ≥ 0.97 between team dollar values and final standings points on held-out years._

---

## Validation Approach

### Runtime Checks

These fire automatically on every call. Failing checks emit `cli_warn()` but do not abort.

**`sgp_denominators()` runtime checks:**

- **Denominator stability:** Year-over-year CV of denominators should be ≤ 10% for
  counting stats (HR, R, RBI). CV > 20% in any category triggers a `cli_warn()` naming
  the category. High CV in SB post-2022 is expected; high CV in HR is not.
- **OLS regression R²:** When `method = "ols"`, the within-year R² of `lm(rank ~ total)`
  should exceed 0.80. R² < 0.80 triggers a `cli_warn()` naming the category and year.
  Do _not_ use within-year Spearman ρ between category totals and standings rank as a
  validation metric — this correlation is 1.0 by construction in rotisserie scoring.

### Manual Diagnostics

Run after calibration to inspect denominator quality. Not auto-fired.

- **Expected range anchors:** The `"sd"` method's `expected_range_normal()` function has
  known expected values for common league sizes (n=10: ~3.08, n=12: ~3.26, n=15: ~3.52).
  These serve as unit test anchors to verify the numerical integration is correct.
- **Year-by-year denominator trace:** Compute denominators year-by-year within the
  calibration window and plot vs. year. Flag any category showing a visible step change —
  evidence of a structural break like the 2023 SB shift. Categories with monotone trends
  (no reversal) may be better served by recency weighting.
- **LOYO predictive validity:** Leave-one-year-out cross-validation on Moonlight Graham
  data. Primary target: Spearman ρ ≥ 0.97 between team dollar values and final standings
  points on held-out years. Full methodology, bootstrap diagnostics, and sensitivity
  analysis are in `plans/sgp-validation.md`. Full-system validation belongs in the
  `dollar_values()` spec.
