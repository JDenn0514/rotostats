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

## Surfaces

**Reads (builder, simulator, tester may read):**
- R/zaa.R (self)
- R/league-config.R (consumes `league_config()` output via `config` arg)
- R/replacement-level.R (consumes `replacement_level()` output and its `projections`, `config`, `stat_units` attributes)
- TODO(user): confirm R/utils.R or other internal helpers
- tests/testthat/test-zaa.R
- inst/ (TODO(user): confirm any fixture data paths under inst/)
- data/ (TODO(user): confirm any package data files consumed at runtime)

**Writes — builder:**
- R/zaa.R

**Writes — simulator:**
- TODO(user): confirm simulator write paths (pure algebraic transform — likely none)

**Writes — tester:**
- tests/testthat/test-zaa.R

**Writes — scriber:**
- R/zaa.R roxygen, man/zaa.Rd, NEWS.md, ARCHITECTURE.md

**Frozen surfaces (NO teammate may modify):**
- R/zar.R (downstream caller — must not be edited by the zaa run)
- R/replacement.R (upstream — consumed via attributes only)
- R/replacement-level.R (upstream — consumed via attributes only)
- R/sgp.R (sibling valuation function)
- R/par.R (sibling valuation function)
- R/pvm.R (sibling valuation function)
- R/dollar-values.R (sibling)
- R/league-config.R (upstream — consumed as config object)
- R/value-plus.R (planned downstream consumer)
- TODO(user): confirm full sibling-file list under R/

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

### Parameter semantics (default vs explicit)

### Parameter: `stats`

**Default-path behavior (`missing(stats)` or `stats = NULL`):** When `replacement` is supplied and carries a `projections` attribute, that attribute supersedes `stats` and no separate validation of `stats` is required. When `replacement = NULL` and `stats` is also `NULL`, `zaa()` must abort — `stats` is required in that path. TODO(user): decide default-path semantics for the no-replacement case (which error class fires on the missing-stats abort).

**Explicit-path behavior (user supplied):** Must be a data frame containing `config$categories` columns and, when ERA/WHIP/AVG are scored, `IP` and `AB` as full-season totals. TODO(user): decide default-path semantics for column-type and column-presence checks (which error class fires — candidates: `rotostats_error_not_data_frame`, `rotostats_error_missing_column`, `rotostats_error_wrong_column_type`).

### Parameter: `config`

**Default-path behavior (`missing(config)` or `config = NULL`):** When `replacement` is supplied and carries a `config` attribute, that attribute supersedes `config` and no separate validation of `config` is required. When `replacement = NULL` and `config` is also `NULL`, `zaa()` must abort — `config` is required in that path. TODO(user): decide default-path semantics for the no-replacement case (which error class fires on the missing-config abort).

**Explicit-path behavior (user supplied):** Must be a `league_config` object exposing `config$categories` (non-empty character vector) and `config$pitcher_slots` (when `pitcher_pool = "split"`). TODO(user): decide default-path semantics for type/shape checks of an explicitly supplied `config`.

### Parameter: `replacement`

**Default-path behavior (`missing(replacement)` or `replacement = NULL`):** Validation of the `stat_units` attribute and `projections`/`config` attribute presence is skipped. `zaa()` emits `cli_inform()` noting the pool is unrestricted and uses all rows in `stats`.

**Explicit-path behavior (user supplied):** Must be a `replacement_level()` object. Missing `projections` or `config` attributes fire `rotostats_error_missing_replacement_attrs`. When `attr(replacement, "stat_units") == "full_season_normalized"`, fires `rotostats_error_stat_units_mismatch`. Only `"raw_projected"` is accepted for the `stat_units` attribute.

### Parameter: `pitcher_pool`

**Default-path behavior (`missing(pitcher_pool)`):** Value defaults to `"combined"`; membership-check validation is skipped because the default is known-valid.

**Explicit-path behavior (user supplied):** Must be one of `"combined"`, `"split"`, `"none"`. TODO(user): decide default-path semantics for invalid-value abort (error class name is not yet registered in `plans/error-messages.md` for `zaa()` — candidates: `rotostats_error_invalid_parameter` or a new `rotostats_error_invalid_pitcher_pool`).

### Parameter: `hitter_pool`

**Default-path behavior (`missing(hitter_pool)`):** Value defaults to `"positional"`; membership-check validation is skipped because the default is known-valid.

**Explicit-path behavior (user supplied):** Must be one of `"positional"`, `"combined"`. TODO(user): decide default-path semantics for invalid-value abort (error class not yet registered for `zaa()` — candidates: `rotostats_error_invalid_parameter` or a new `rotostats_error_invalid_hitter_pool`).

### Parameter: `category_weight`

**Default-path behavior (`missing(category_weight)` or `category_weight = NULL`):** No manual override is applied; `weight_method` governs normalization. Type/shape validation is skipped.

**Explicit-path behavior (user supplied):** Must be a named numeric vector whose names are position labels (e.g., `SP`, `RP`, hitter positions). Takes precedence over `weight_method`. TODO(user): decide default-path semantics for validation (length, naming, numeric coercion) and which error class fires on violation.

### Parameter: `weight_method`

**Default-path behavior (`missing(weight_method)`):** Value defaults to `"none"`; membership-check validation is skipped because the default is known-valid. No normalization is applied.

**Explicit-path behavior (user supplied):** Must be one of `"none"`, `"linear"`, `"sqrt"`. TODO(user): decide default-path semantics for invalid-value abort (error class not yet registered for `zaa()` — candidates: `rotostats_error_invalid_parameter` or a new `rotostats_error_invalid_weight_method`).

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

**Simulation studies:** N/A — `zaa()` is a pure algebraic transform; no Monte Carlo study is required for validation. Signal pre-check block intentionally omitted.

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

### TS-ZAA-1 — Rate stat sign check

**Preconditions (inputs must satisfy):**
- `stats` contains valid pitcher rows with `ERA` as a scored category.
- Position pool has at least 2 pitchers so that `mean_ERA` is well-defined.
- A test pitcher has `ERA` strictly below the position-average `ERA`.
- `config$categories` includes `ERA`; `IP` column present as full-season totals with `IP > 0`.

**Target guard / behavior under test:**
- `sign(mean_ERA - player_ERA) == sign(zaa_era)` for all pitchers (i.e., negation of rate stats is applied so positive z = positive standings contribution).

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_stat_units_mismatch` — fixture uses `attr(replacement, "stat_units") = "raw_projected"`, so this guard does not fire.
- `rotostats_error_missing_replacement_attrs` — fixture uses a `replacement_level()` object with both `projections` and `config` attributes present.
- TODO(planner): enumerate upstream guards

**Expected outcome:**
- For every pitcher row, `sign(zaa_era) == sign(mean_ERA - player_ERA)`; no error or warning class fires.

### TS-ZAA-2 — Pool restriction effect

**Preconditions (inputs must satisfy):**
- Two parallel calls: (a) `zaa(stats = S, config = C)` with `replacement = NULL`; (b) `zaa(stats = S, config = C, replacement = R)` with a `replacement_level()` object built from the same `S`.
- Fringe / below-replacement players exist in `S` (so the restricted pool is a strict subset).

**Target guard / behavior under test:**
- With a `replacement` restriction, the within-position SD of any scored category is narrower than without, because fringe players widening the tails are excluded.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_stat_units_mismatch` — `replacement` carries `stat_units = "raw_projected"`.
- `rotostats_error_missing_replacement_attrs` — `replacement` is built via `replacement_level()` so attributes are present.
- TODO(planner): enumerate upstream guards

**Expected outcome:**
- `SD(total_zaa_restricted) < SD(total_zaa_unrestricted)` for at least one position pool; equality indicates the pool restriction is not being applied.

### TS-ZAA-3 — Volume-weighting effect (ERA / WHIP by IP, AVG by AB)

**Preconditions (inputs must satisfy):**
- Two pitcher rows with identical projected `ERA` (e.g., 3.50) and different projected `IP` (e.g., 200 vs 60).
- Parallel two-hitter case: identical projected `AVG`, different projected `AB`.
- `IP > 0` and `AB > 0` for all affected rows.
- `config$categories` includes the rate stat under test.

**Target guard / behavior under test:**
- Volume-weighted re-standardization in Step 2b: higher-IP pitcher must produce a larger `abs(zaa_era)`; pre-re-standardization ratio ≈ `IP_A / IP_B` (e.g., 200/60 ≈ 3.33). Post-re-standardization the ratio is preserved. Same logic for `AB` and `zaa_avg`.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_stat_units_mismatch` — `stat_units = "raw_projected"` on `replacement`.
- `rotostats_error_missing_replacement_attrs` — attributes present.
- `rotostats_warning_zero_playing_time` — fixture guarantees `IP > 0` and `AB > 0`, so the zero-IP/AB edge case does not fire.
- TODO(planner): enumerate upstream guards

**Expected outcome:**
- `abs(zaa_era_A) > abs(zaa_era_B)` with the ratio reflecting the IP ratio; analogous for `zaa_avg`.

### TS-ZAA-4 — `weight_method` identity check (`"none"`)

**Preconditions (inputs must satisfy):**
- `weight_method = "none"`; `category_weight = NULL`.
- At least one player with valid per-category `zaa_[cat]` outputs across all scored categories.

**Target guard / behavior under test:**
- `total_zaa[i] == sum(zaa_[cat][i])` exactly (within floating-point tolerance) for every player `i` — no normalization applied.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_stat_units_mismatch` — inapplicable; `replacement` uses `raw_projected` or is absent.
- No `cli_warn()` about weight_method / pitcher_pool interaction: `weight_method = "none"` skips that interaction entirely.
- TODO(planner): enumerate upstream guards

**Expected outcome:**
- `all.equal(total_zaa, rowSums(zaa_[cat] columns))` returns `TRUE`.

### TS-ZAA-5 — `weight_method` scaling check (`"linear"` and `"sqrt"`)

**Preconditions (inputs must satisfy):**
- 5-hitting / 4-pitching category format via `config$categories`.
- Two fixture calls: (a) `weight_method = "linear"`; (b) `weight_method = "sqrt"`.
- `category_weight = NULL` (no manual override).
- `pitcher_pool` set to avoid the warning interaction — use `"split"` so `rotostats_warning_*` about combined auto-weights does not fire. TODO(planner): confirm the warning class name once registered.

**Target guard / behavior under test:**
- Under `"linear"`: `pitcher total_zaa == 0.8 × rowSum(pitcher zaa_[cat])` (4/5 ratio).
- Under `"sqrt"`: multiplier == `sqrt(4/5) ≈ 0.894`.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_stat_units_mismatch` — `stat_units = "raw_projected"`.
- `rotostats_error_missing_replacement_attrs` — attributes present when `replacement` is supplied.
- The `weight_method` / `pitcher_pool = "combined"` `cli_warn()` interaction — suppressed by using `pitcher_pool = "split"`.
- TODO(planner): enumerate upstream guards

**Expected outcome:**
- `pitcher total_zaa / rowSum(zaa_[cat])` equals `0.8` (linear) or `sqrt(0.8)` (sqrt), within tolerance.

### TS-ZAA-6 — `category_weight` override precedence

**Preconditions (inputs must satisfy):**
- Both `category_weight` (e.g., `c(SP = 0.5, RP = 0.5, C = 1.2, ...)`) AND `weight_method != "none"` are supplied simultaneously.
- `category_weight` names match the position labels produced by the pool definition.

**Target guard / behavior under test:**
- The manual `category_weight` multiplier is applied; the auto-computed `weight_method` multiplier is discarded.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_stat_units_mismatch` — inapplicable here.
- TODO(user): decide which error class fires if `category_weight` is malformed (named numeric check) — the fixture must pass a valid vector so that guard does not fire.
- TODO(planner): enumerate upstream guards

**Expected outcome:**
- `total_zaa[pos == "SP"] == 0.5 × rowSum(zaa_[cat][pos == "SP"])`; the `weight_method` factor does not appear anywhere in the output.

### TS-ZAA-7 — `pitcher_pool` comparison (`"split"` vs `"combined"`)

**Preconditions (inputs must satisfy):**
- Fixture data includes a high-save RP (e.g., 30 SV) alongside multiple SPs with zero SV.
- `config$categories` includes `SV` and `HLD` (or at least `SV`).
- Parallel calls: one with `pitcher_pool = "combined"`, one with `pitcher_pool = "split"`.

**Target guard / behavior under test:**
- Under `"split"`, the RP's `total_zaa` rank among RPs is higher than under `"combined"`, because combined-pool dilution from SP zero-save contributions no longer lowers the RP's saves-category mean relative to its own within-group mean.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_stat_units_mismatch` — inapplicable.
- `rotostats_error_missing_replacement_attrs` — attributes present.
- TODO(planner): enumerate upstream guards

**Expected outcome:**
- `rank(RP_total_zaa_among_RPs, split) <= rank(RP_total_zaa_among_RPs, combined)` (lower rank number = higher placement).

### TS-ZAA-8 — `hitter_pool` attribute structure

**Preconditions (inputs must satisfy):**
- Two parallel calls: `hitter_pool = "combined"` and `hitter_pool = "positional"`.
- `stats` contains hitters across multiple positions (at least 2 distinct positions).

**Target guard / behavior under test:**
- `hitter_pool = "combined"`: `attr(result, "distribution")` is a flat category-keyed list (e.g., `distribution$HR` directly).
- `hitter_pool = "positional"`: `attr(result, "distribution")` is position-keyed then category-keyed (e.g., `distribution$C$HR`).

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_stat_units_mismatch` — inapplicable.
- TODO(planner): enumerate upstream guards

**Expected outcome:**
- Names structure matches the documented `attr(result, "distribution")` schema exactly; `sd_vol` present for rate stats only.

### TS-ZAA-9 — `hitter_pool` effect on z-score magnitude

**Preconditions (inputs must satisfy):**
- Two synthetic hitter rows with identical `HR` total, one eligible at `C`, one at `1B`.
- Parallel calls with `hitter_pool = "combined"` and `hitter_pool = "positional"`.
- Catcher pool SD is narrower than combined-pool SD (a property of the synthetic data).

**Target guard / behavior under test:**
- Under `hitter_pool = "combined"`, the catcher's `zaa_hr` magnitude is smaller than under `hitter_pool = "positional"` because the combined SD is wider.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_stat_units_mismatch` — inapplicable.
- TODO(planner): enumerate upstream guards

**Expected outcome:**
- `abs(zaa_hr[C, combined]) < abs(zaa_hr[C, positional])`.

### TS-ZAA-10 — Attribute extraction precedence

**Preconditions (inputs must satisfy):**
- `zaa(stats = different_df, replacement = repl)` where `repl` carries a `projections` attribute that differs from `different_df` (different rows, different values).
- `repl` also carries a valid `config` attribute.

**Target guard / behavior under test:**
- `attr(replacement, "projections")` supersedes the explicit `stats` argument; output rows reflect `repl`'s projections.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_stat_units_mismatch` — `stat_units = "raw_projected"` on `repl`.
- `rotostats_error_missing_replacement_attrs` — both `projections` and `config` attributes are present on `repl`.
- TODO(planner): enumerate upstream guards

**Expected outcome:**
- Output row set and per-player values match a control call `zaa(stats = attr(repl, "projections"), config = attr(repl, "config"), replacement = repl)` exactly.

### Manual diagnostics

- **Directional sanity:** Top-10 players by `total_zaa` at each position should be
  recognizable contributors in the projection vintage. A non-rostered player appearing
  in the top 10 indicates a pool definition error. (Requires human judgment against the
  projection vintage — not automatable.)

---

## Error Handling

Classes below are drawn from references in the spec body (e.g., §Formal Definition,
§Parameter semantics). The canonical registry is `plans/error-messages.md` — this
table only binds each class to the fixture that exercises it.

| Class | Condition | Trigger fixture |
|-------|-----------|-----------------|
| `rotostats_error_stat_units_mismatch` | `attr(replacement, "stat_units") != "raw_projected"` (e.g., `"full_season_normalized"`) | TODO(planner): bind to fixture |
| `rotostats_error_missing_replacement_attrs` | `replacement` provided but missing `projections` or `config` attribute | TODO(planner): bind to fixture |
| `rotostats_error_not_data_frame` (candidate — explicit-path `stats`) | `stats` supplied but is not a data frame | TODO(planner): bind to fixture |
| `rotostats_error_missing_column` (candidate — explicit-path `stats`) | `stats` missing a scored-category column, `IP`, or `AB` when a rate stat is scored | TODO(planner): bind to fixture |
| `rotostats_error_wrong_column_type` (candidate — explicit-path `stats`) | A scored category column in `stats` is not numeric | TODO(planner): bind to fixture |
| `rotostats_error_invalid_parameter` (candidate — `pitcher_pool`, `hitter_pool`, `weight_method`) | Explicit value not in the allowed membership set | TODO(planner): bind to fixture |
| `cli_inform()` — unrestricted pool notice (no registered class) | `replacement = NULL`; pool is unrestricted | TODO(planner): bind to fixture |
| `cli_warn()` — `weight_method` × `pitcher_pool = "combined"` interaction (no registered class) | `weight_method != "none"` AND `pitcher_pool = "combined"` | TODO(planner): bind to fixture |

Notes:
- `rotostats_error_stat_units_mismatch` and `rotostats_error_missing_replacement_attrs` are the only classes registered in `plans/error-messages.md` as thrown by `zaa()`. The remaining rows are candidates surfaced by the Parameter-semantics audit (Fix 1) and have not yet been registered; binding them here is deferred to the planner.
- `cli_inform()` and `cli_warn()` sites have no registered warning class yet; registration in `plans/error-messages.md` is a prerequisite before a fixture binding can be meaningful.
