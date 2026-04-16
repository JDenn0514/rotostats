# Metric Spec: Z-Scores Above Average (`zaa()`)

> **Status:** Draft · 2026-04-14
> **Q1 Conceptual:** Complete · **Q2 Statistical:** Pending code audit · **Q3 Decision:** Pending validation

---

## Purpose

Compute per-player, per-category z-scores within the rostered player pool at each position,
using the within-position distribution as the normalizing factor. The anchor is the position
average: a player at the position mean gets `total_zaa = 0`. Primary use is relative ranking
and scarcity analysis; also the internal building block for `zar()`.

---

## Formal Definition

`zaa(stats = NULL, config = NULL, replacement = NULL, pitcher_pool = "combined", hitter_pool = "positional", category_weight = NULL, weight_method = "none", ...)`

`config` is a `league_config` object (see `plans/implementation/league-config-impl.md`).
`config$categories` defines which columns in `stats` are scored categories and drives
the Step 3 sum and the Step 4 `weight_method` auto-compute. `config$pitcher_slots`
provides the SP/RP split used when `pitcher_pool = "split"`.

**Step 1 — Define the player pool:**

**Attribute extraction:** When `replacement` is provided and carries
`projections` and `config` attributes, those values supersede any explicit
`stats` or `config` arguments. When `replacement = NULL`, both `stats` and
`config` are required.

If `replacement` is provided (a `replacement_level()` object), restrict to the rostered
player pool it defines. Otherwise use all rows in `stats`. When called internally by
`zar()`, `replacement` is always provided — fringe players below the replacement boundary
are excluded from the distribution.

When `replacement = NULL`, `zaa()` emits `cli_inform()` noting that the pool is
unrestricted and the within-position SD may be inflated by marginal players. Users who
want a tighter distribution should supply a `replacement_level()` object.

**`stat_units` guard:** When `replacement` is provided, `zaa()` checks
`attr(replacement, "stat_units")` and aborts with
`rotostats_error_stat_units_mismatch` if the value is `"full_season_normalized"`.
Using normalized inputs causes double-application of IP/AB weighting in Step 2b
and produces z-scores on the wrong scale. This guard is inherited by `zar()` by
delegation — `zar()` does not check the attribute directly.

**Step 2 — Compute within-position z-scores:**

Positional grouping is controlled by `pitcher_pool`:

- `"combined"` (default): all pitchers (SP and RP) form one pool for z-score computation.
  SPs contribute 0 to saves/holds z-scores, which mechanically lowers SP `total_zaa`
  relative to RPs. This is the LPP/FanGraphs approach — partial self-correction, not a
  principled split.
- `"split"`: SP and RP each form separate positional pools. A 30-save closer is compared
  only against other RPs. This is the FVARz/BIGz approach — more principled for leagues
  where SP/RP ranking precision matters.
- `"none"`: all *pitchers* form a single pool with no SP/RP split. Hitter
  pooling is unaffected — it continues to follow `hitter_pool`. Not recommended
  for standard rotisserie formats. For FanGraphs-style combined hitter z-scores,
  use `hitter_pool = "combined"` instead.

**`hitter_pool`** controls how hitter z-scores are pooled:

- `"positional"` (default): z-scores are computed within each position's
  rostered pool. The position boundaries are provided by the `replacement`
  object when supplied; when `replacement = NULL`, `zaa()` uses the positions
  present in `stats$pos_eligibility` (first position only). This is the
  FVARz/BIGz approach.

- `"combined"`: all hitters form a single pool. Position is not used in
  z-score computation. The `replacement` object still defines the rostered
  pool size (Step 1), but within that pool, all hitters are compared against a
  single combined mean and SD per category. This is the FanGraphs auction
  calculator approach.

For hitters, positional grouping follows `replacement_level()` pool definitions (C, 1B, 2B,
3B, SS, OF, CI, MI, UTIL as applicable). Multi-position eligibility is resolved by
`replacement_level()` before `zaa()` runs.

Within each positional group, z-scores are computed differently for counting stats vs.
rate stats.

**Counting stats (HR, R, RBI, SB, K, W, SV, HLD, QS, SVHD — more is better):**

```
z[i, c] = (stat[i, c] - mean_stat[c, pos]) / SD_stat[c, pos]
```

Unweighted (population) mean and SD. Playing time differences already manifest in
full-season projected totals, so no volume adjustment is needed.

**Rate stats (ERA, WHIP, AVG) — two-step volume-weighted approach:**

Step 2a — Raw z-score (unweighted mean and SD):

```
# ERA and WHIP (less is better — negate so positive z = positive standings contribution)
z_raw[i, c]   = -(stat[i, c] - mean_stat[c, pos]) / SD_stat[c, pos]

# AVG (more is better)
z_raw[i, AVG] = (AVG[i] - mean_AVG[pos]) / SD_AVG[pos]
```

Step 2b — Volume-weight by playing time, then re-standardize:

```
# ERA and WHIP: weight by projected IP
z_vol[i, c] = z_raw[i, c] × IP[i]
z[i, c]     = z_vol[i, c] / SD(z_vol[c, pos])

# AVG: weight by projected AB
z_vol[i, AVG] = z_raw[i, AVG] × AB[i]
z[i, AVG]     = z_vol[i, AVG] / SD(z_vol[AVG, pos])
```

`SD(z_vol[c, pos])` is the unweighted population SD of the volume-weighted z-scores
within the positional group. This re-standardization returns the values to a z-score
scale comparable across categories.

A pitcher with more projected IP receives proportionally more ERA/WHIP z-score credit
than a pitcher with identical rate stats but fewer innings, reflecting their actual
contribution to team standings. A 200-IP ace at 3.50 ERA moves team ERA more than a
30-IP reliever at 3.50 ERA. Standard approach in FVARz and BIGz.

**Input format requirement:** `stats` must contain full-season projected totals or
full-season actuals. Per-game, per-PA, or per-IP rates are not valid inputs. Rate stat
volume weighting additionally requires `IP` and `AB` columns as full-season projected
or actual totals — these are used in Step 2b and must be present for ERA, WHIP, and
AVG computation. If rates are passed instead of season totals, z-scores will be
computed on the wrong scale.

**Step 3 — Sum across all scored categories:**

```
total_zaa[i] = sum(z[i, c] for all scored categories c)
```

**Step 4 — Normalize across positions (optional):**

`weight_method` controls how `total_zaa` is adjusted to account for differences in
category count across player groups:

- `"none"` (default): no adjustment. `total_zaa` is the raw sum of per-category z-scores.
- `"linear"`: multiplies `total_zaa` by `n_scored_categories_position /
  n_scored_categories_hitter`. Scales the ceiling — a pitcher group that can accumulate
  in 4 of 5 hitter categories is penalized proportionally. FVARz approach.
- `"sqrt"`: multiplies `total_zaa` by `sqrt(n_scored_categories_position /
  n_scored_categories_hitter)`. Equalizes distributional spread — if per-category z-scores
  are approximately independent, `total_zaa` has variance ≈ n_cats; `"sqrt"` puts all
  positions on a comparable SD scale.

When `weight_method != "none"`, category counts are auto-computed from the scored category
list. Per-category `zaa_[cat]` columns are not scaled — only `total_zaa` is affected.

`category_weight` (named numeric vector mapping position labels to multipliers, e.g.,
`c(SP = 0.8, RP = 0.8)`) overrides `weight_method` when provided. Manual overrides take
precedence over auto-computation and allow arbitrary scaling not expressible through
`weight_method`.

**Warning interaction with `pitcher_pool`:** When `weight_method != "none"` and
`pitcher_pool = "combined"`, `zaa()` emits `cli_warn()` noting that auto-computed weights
treat all pitchers as having `n_pitcher_categories` non-zero categories, but SPs contribute
≈0 to saves/holds and RPs contribute ≈0 to wins. The computed weight will slightly
overstate the normalization factor for both groups. Specify `pitcher_pool = "split"` for
more accurate per-group normalization, or override with a manual `category_weight` vector.

**Output structure:**

Returns a data frame: one row per player, one `zaa_[cat]` column per scored
category, plus `total_zaa`.

```
attr(result, "units")        = "zscore"
attr(result, "anchor")       = "average"
attr(result, "distribution") = named list of per-category distribution parameters
```

**`attr(result, "distribution")` schema:**

When `hitter_pool = "positional"`: a nested list keyed first by position, then
by category:

```
distribution$C$HR    = list(mean = ..., sd = ..., sd_vol = ...)
distribution$SP$ERA  = list(mean = ..., sd = ..., sd_vol = ...)
```

When `hitter_pool = "combined"` or for pitchers under `pitcher_pool = "combined"`:
a flat list keyed by category:

```
distribution$HR  = list(mean = ..., sd = ...)
distribution$ERA = list(mean = ..., sd = ..., sd_vol = ...)
```

`sd_vol` is the population SD of the volume-weighted z-scores (Step 2b
denominator). Present for rate stats only. Used by `zar()` to score the
replacement band-average stat line against the stored distribution without
re-running `zaa()`.

**`zaa()` is exported** as a standalone user-facing function. It is also the internal
implementation called by `zar()`.

---

## Why This Measure

`zaa()` answers: "how far above the average rostered player at this position is this
player?" A player with `total_zaa = 2.0` is two standard deviations above the position
mean. A player with `total_zaa = 0.0` is exactly average — rostered, contributing, but
not differentiated.

This anchor is useful for relative ranking and scarcity analysis. It is not directly
usable for auction dollar conversion: an average player (`total_zaa = 0`) still has
positive auction value — you would pay to roster them. `zar()` anchors to the replacement
player instead, placing dollar-value-zero at the free-agent baseline.

When historical league data is available, `sgp()` with `replacement` is preferred for
dollar conversion because SGP denominators are calibrated from actual standings movements
in the specific league. `zaa()` uses the within-position distribution of the player pool
as the normalizing factor — appropriate when league history is unavailable or too thin
to be reliable.

---

## Assumptions

| Assumption | Testable? | How to Test / Basis |
|-----------|-----------|---------------------|
| Within-position z-scores are the correct comparison basis | Partially | Scarcity ordering check: best C `total_zaa` should be lower than best 1B `total_zaa` if catcher depth is shallower |
| ERA/WHIP z-scores are volume-weighted by IP (z_raw × IP, re-standardized) | Yes | Compare `zaa_era` for two pitchers with identical ERA but different projected IP — higher IP pitcher must have larger absolute `zaa_era` |
| AVG z-scores are volume-weighted by AB (z_raw × AB, re-standardized) | Yes | Same check: two hitters with identical AVG and different projected AB — higher AB hitter must have larger absolute `zaa_avg` |
| ERA and WHIP z-scores are negated | Yes | Rate stat sign check: pitcher below position-mean ERA must have positive `zaa_era` |
| `stats` input contains full-season totals including `IP` and `AB` columns | Yes | If rates are passed, z-scores are on the wrong scale; check HR values are in the range 5–50, not 0.03–0.25; check IP is in the range 20–220, not 0.1–1.4 |
| Counting stat z-scores use unweighted mean and SD | No | Theoretical: playing time differences already manifest in raw projected totals — valid only when input is full-season volume |
| Pool is rostered players when `replacement` is provided | Yes | Verify that pool restriction narrows the within-position SD relative to the full-stats pool |
| `pitcher_pool = "combined"` default is acceptable | Partial | Compare SP rankings under `"combined"` vs `"split"`; SPs with zero saves should rank lower under `"combined"` |
| `weight_method = "none"` applies no adjustment | Yes | With `"none"`, `total_zaa[i]` must equal the arithmetic sum of all `zaa_[cat]` columns for player i |
| `weight_method = "sqrt"` equalizes distributional spread across positions | Partially | Compare SD of `total_zaa` for hitters vs. pitchers under `"sqrt"` — should converge; independence of per-category z-scores (the theoretical basis) is not guaranteed |
| Manual `category_weight` overrides `weight_method` when provided | Yes | Supply both; verify `total_zaa` reflects the manual multiplier, not the auto-computed one |
| `config$categories` correctly identifies all scored columns in `stats` | Yes | If a scored category is absent from `config$categories`, it is silently excluded from `total_zaa`; cross-validate against `stats` column names at call time |
| Multi-position eligibility is resolved by `replacement_level()` | Deferred | Pool membership for multi-position players is determined upstream; `zaa()` uses whatever pool is passed in |

---

## Interface

```r
zaa(
  stats           = NULL,
  config          = NULL,
  replacement     = NULL,
  pitcher_pool    = "combined",
  hitter_pool     = "positional",
  category_weight = NULL,
  weight_method   = "none",
  ...
)
```

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `stats` | data frame | conditional | Player projections. Required when `replacement = NULL` or lacks `projections` attribute. Superseded by `attr(replacement, "projections")` when present. Same column requirements as `replacement_level()` — must include `IP` and `AB` as full-season totals when ERA, WHIP, or AVG are scored. |
| `config` | league_config | conditional | League configuration object. Required when `replacement = NULL` or lacks `config` attribute. Superseded by `attr(replacement, "config")` when present. |
| `replacement` | replacement_level output | no | When provided, restricts the player pool to rostered players (Step 1) and supplies `stats` and `config` via attributes. When `NULL`, all rows in `stats` are used and `zaa()` emits `cli_inform()` noting the pool is unrestricted. |
| `pitcher_pool` | character | no | `"combined"` (default) \| `"split"` \| `"none"`. Controls pitcher z-score pool grouping. See Step 2. |
| `hitter_pool` | character | no | `"positional"` (default) \| `"combined"`. Controls hitter z-score pool grouping. See Step 2. |
| `category_weight` | named numeric | no | Manual per-position multipliers applied to `total_zaa` (e.g., `c(SP = 0.8, RP = 0.8)`). Overrides `weight_method` when provided. |
| `weight_method` | character | no | `"none"` (default) \| `"linear"` \| `"sqrt"`. Auto-computes category-count normalization for `total_zaa`. Ignored when `category_weight` is supplied. |

---

## Decision This Informs

- **Primary use:** Relative player ranking within position — "who is most elite at this
  position?" Standalone export for users who want above-average z-scores without a
  replacement anchor.
- **Consumer:** User (direct ranking for scarcity analysis); `zar()` (internal dependency);
  `value_plus()` (planned: normalizes output to a 100-baseline scale).
- **How consumed:** Higher `total_zaa` = more standard deviations above position average.
  Not directly used for dollar conversion — use `zar()` output for that.
- **Sensitivity:** Most sensitive to pool definition. Including fringe players widens the
  SD and compresses elite players' z-scores. When `replacement` is not provided, all rows
  in `stats` are used — users should be aware this may inflate the SD if marginal players
  are present.

---

## Dependencies

**Upstream:**
- `league_config()`: required. Provides `config$categories` (scored category list),
  `config$pitcher_slots` (SP/RP split for `pitcher_pool = "split"`). See
  `plans/implementation/league-config-impl.md`.
- `replacement_level()`: optional but recommended. Defines the rostered player pool and
  position boundaries for within-position distribution computation. Multi-position
  eligibility is resolved here before `zaa()` runs.
- Projections or historical stat data: the stat distribution for z-score computation.
  Must include `IP` and `AB` columns as full-season totals for rate stat volume weighting.

**Downstream:**
- `zar()`: calls `zaa()` internally; inherits `config`, `pitcher_pool`, `category_weight`, and `weight_method`.
- User: direct ranking and scarcity analysis without a replacement anchor.
- `value_plus()` (planned): normalizes `zaa` output to a 100-baseline scale.

---

## Known Validity Threats

### Conceptual (Q1)

**1. Category count affects `total_zaa` scale — addressed by `weight_method`, with caveats**

`total_zaa` is the sum of per-category z-scores. A league with 5 hitting categories and
4 pitcher categories produces pitcher totals on a different scale than hitter totals under
the default `weight_method = "none"`. `weight_method = "linear"` or `"sqrt"` corrects
this by auto-computing the category ratio from the scored category list.

Two residual caveats:

- **`pitcher_pool = "combined"` interaction:** Auto-computed weights treat SP and RP as
  each having `n_pitcher_categories` non-zero categories. In practice, SPs contribute ≈0
  to saves/holds and RPs contribute ≈0 to wins — the effective non-zero count for each
  group is lower than the full scored pitcher category count. `zaa()` emits `cli_warn()`
  when `weight_method != "none"` and `pitcher_pool = "combined"`. Using
  `pitcher_pool = "split"` produces cleaner per-group normalization; manual
  `category_weight` is always available as a precise override.
- **Independence assumption for `"sqrt"`:** The `"sqrt"` method equalizes distributional
  spread under the assumption that per-category z-scores are approximately independent,
  giving `Var(total_zaa) ≈ n_cats`. In practice, categories are correlated (HR and RBI
  co-move; ERA and WHIP co-move). The SD equalization is approximate, not exact.

**2. League depth sensitivity**

The standard deviation of a stat within the rostered pool depends on league size and
roster slot counts. A 10-team league has a different within-position SD than a 15-team
league, even on identical player pools. `total_zaa` values are not directly comparable
across league configurations. `attr(result, "units") = "zscore"` does not encode league
size or depth.

**3. `pitcher_pool = "combined"` conflates SP and RP distributions**

Under the default setting, SPs contribute 0 to saves and holds z-scores. The SP total
is mechanically lower, which is partially self-correcting, but the z-score distribution
for shared categories (ERA, WHIP, K) is contaminated by pooling two categorically
different pitcher roles. For leagues where SP/RP ranking precision matters,
`pitcher_pool = "split"` is more principled.

Under the volume-weighted re-z approach, the combined pool ERA/WHIP mean is unweighted
(equally influenced by each pitcher, not by IP volume). SP-anchoring of the benchmark
is not a concern. However, the combined pool mean ERA may still differ structurally from
the SP-only or RP-only mean if the two groups have systematically different ERA
distributions — which they typically do. The remaining distortion is that SP and RP
ERA z-scores are both computed against the same combined mean, not their own group's
mean. Under `"split"`, each group's ERA mean and SD are derived from its own pool,
producing cleaner within-group comparisons.

**4. Rate stat sign convention must be consistent across all consumers**

ERA and WHIP z-scores are negated. Any consumer reading `zaa_era` or `zaa_whip` must
know positive = good. Column naming does not encode sign direction. Sorting functions
that treat all `zaa_[cat]` columns as "more is better" will produce incorrect
ERA/WHIP rankings.

### Statistical (Q2)

_Pending — fill in after code audit of `R/zaa.R`_

Known issues to verify in audit:

- **IP = 0 / AB = 0 edge case:** In Step 2b, `z_vol = z_raw × IP`. A pitcher with 0
  projected IP produces `z_vol = 0` regardless of ERA, giving `zaa_era = 0`. This is
  likely wrong. Confirm whether the implementation returns `NA` with `cli_warn()` for
  players with 0 projected IP (ERA/WHIP) or 0 projected AB (AVG) — consistent with
  SGP's behavior for the same edge case.
- **Population vs. sample SD in re-standardization:** Step 2b divides by
  `SD(z_vol[c, pos])`. Confirm this is the unweighted **population** SD (denominator
  `n`), not the Bessel-corrected sample SD (denominator `n − 1`), consistent with the
  counting stat computation.

### Decision (Q3)

_Pending — fill in after validation harness results_

---

## Validation Approach

- **Rate stat sign check:** A pitcher projected with ERA below the position-average ERA
  must produce positive `zaa_era`. Assert `sign(mean_ERA - player_ERA) == sign(zaa_era)`
  for all pitchers. Automatable as a unit test.
- **Pool restriction effect:** Compare `total_zaa` SD with and without a
  `replacement_level()` pool restriction. When restricted, the SD should be narrower.
  If SD is identical, the pool restriction is not being applied.
- **Volume-weighting effect:** Two pitchers with identical projected ERA but different
  projected IP must produce different `zaa_era` — the higher-IP pitcher must have the
  larger absolute value. Construct a synthetic test case (e.g., Pitcher A: ERA 3.50,
  IP 200; Pitcher B: ERA 3.50, IP 60) and assert `abs(zaa_era_A) / abs(zaa_era_B) ≈
  200/60 ≈ 3.33` before re-standardization. After re-standardization the ratio is
  preserved. Same check applies to `zaa_avg` with AB. Automatable as a unit test.
- **Directional sanity:** Top-10 players by `total_zaa` at each position should be
  recognizable contributors in the projection vintage. A non-rostered player appearing
  in the top 10 indicates a pool definition error.
- **`weight_method` identity check:** With `weight_method = "none"` and no manual
  `category_weight`, `total_zaa[i]` must equal the arithmetic sum of all `zaa_[cat]`
  columns for player i. Automatable as a unit test.
- **`weight_method` scaling check:** With `weight_method = "linear"` in a 5-hitting /
  4-pitching format, pitcher `total_zaa` must equal 0.8 × the arithmetic sum of their
  `zaa_[cat]` columns. With `weight_method = "sqrt"`, the multiplier must be
  `sqrt(4/5) ≈ 0.894`. Both are automatable as unit tests.
- **`category_weight` override check:** When both `category_weight` and
  `weight_method != "none"` are supplied, `total_zaa` must reflect the manual
  `category_weight` multiplier, not the auto-computed one. Automatable as a unit test.
- **`pitcher_pool` comparison:** Under `"split"`, a 30-save closer should rank higher
  among RPs than under `"combined"`, where their z-score is diluted by SP volume in
  shared categories.
- **`hitter_pool` attribute structure check:** When `hitter_pool = "combined"`,
  `attr(result, "distribution")` must be a flat category-keyed list. When
  `hitter_pool = "positional"`, it must be a position-keyed nested list.
  Automatable as a unit test on the attribute structure.
- **`hitter_pool` effect on z-scores:** Under `hitter_pool = "combined"`, a
  catcher with elite HR production will have a lower `zaa_hr` than under
  `hitter_pool = "positional"` (the combined SD is wider, so the same HR total
  is worth fewer standard deviations). Verify directionally with a synthetic
  two-player test: same HR total, one at C, one at 1B. The combined-pool C
  z-score must be smaller in magnitude than the positional-pool C z-score.
- **Attribute extraction precedence:** When both explicit `stats` and
  `attr(replacement, "projections")` are supplied, the replacement attribute
  wins. Automatable: call `zaa(stats = different_df, replacement = repl)` and
  assert output reflects `repl`'s projections, not `different_df`.
