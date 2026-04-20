# Metric Spec: Percentage Valuation Method (`pvm()`)

> **Status:** Draft · 2026-04-13 · Amended 2026-04-16
> **Q1 Conceptual:** Complete · **Q2 Statistical:** Pending code audit · **Q3 Decision:** Pending validation
>
> **Open Q1 questions:** 0 — Q1-PVM-1 and Q1-PVM-2 resolved by amendments

---

## Purpose

Compute per-player, per-category proportional shares of above-replacement production so that players can be compared and valued from projections or a single historical season alone, without requiring league standings history.

---

## Surfaces

**Reads (builder, simulator, tester may read):**
- R/replacement.R (pvm takes replacement_level() output; direct read surface — `pvm()` consumes the `projections` / `config` / `stat_units` attributes attached by `replacement_level()`)
- R/dollar_values.R (downstream consumer; context-only read, never sourced directly — `pvm()` emits attributes that `dollar_values()` reads, not the reverse)

**Writes — builder:**
- R/pvm.R

**Writes — simulator:**
- inst/simulations/sim-pvm.R (if a sim harness is added; else "none")
- tests/simulations/sim-pvm-results.rds (if simulation run occurs)
- tests/simulations/sim-pvm-summary.csv (ditto)

**Writes — tester:**
- tests/testthat/test-pvm.R

**Writes — scriber:**
- R/pvm.R roxygen, man/pvm.Rd, NEWS.md, ARCHITECTURE.md

**Frozen surfaces (NO teammate may modify):**
- R/replacement.R
- R/sgp.R
- R/par.R
- R/zaa.R
- R/zar.R
- R/dollar_values.R (downstream consumer)
- R/league-config.R (upstream — `config` is consumed via `attr(replacement, "config")`; `pvm()` does not modify it)
- R/league-history.R (not consumed by `pvm()` directly, but listed here to make it explicit that the `pvm()` run must not modify this file)

---

## Interface

```r
pvm(
  replacement,
  include_raw     = FALSE,
  cat_pct         = "auto",
  rate_pool       = "ip_weighted",
  sub_replacement = "clip",
  baseline        = NULL
)
```

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `replacement` | replacement_level output | Yes | Must carry `projections` and `config` as attributes. Produced by `replacement_level()`. Any other object aborts with `rotostats_error_missing_replacement_attrs`. |
| `include_raw` | logical | No | Default `FALSE`. When `TRUE`, include `contrib_[cat]` columns (raw above-replacement contributions before pool normalization) in the output. |
| `cat_pct` | character or named numeric | No | `"auto"` (default) — derive from config. `"equal"` — flat across all categories. Named numeric vector — explicit weights, must sum to 1.0. |
| `rate_pool` | character | No | `"ip_weighted"` (default) — volume-weight rate stat contributions in raw stat space. `"pool_average"` — Zola canonical extras method with pool-average baseline. `"fixed_baseline"` — counting equivalents using fixed baseline constants from `config`, consistent with `sgp(rate_conversion = "fixed_baseline")`. |
| `sub_replacement` | character | No | `"clip"` (default) — clip sub-replacement contributions to 0; sum-to-1 invariant holds across all rostered players. `"negative"` — allow negative values for sub-replacement players; only positive contributors included in pool denominator (Zola canonical). |
| `baseline` | named numeric | No | Per-category baseline overrides. Names must match scored rate stat categories. Only used when `rate_pool = "fixed_baseline"`. When `NULL` (default), baseline constants are read from `config` automatically. Supports any rate stats present in the league configuration, not just ERA, WHIP, and AVG. |

### Parameter semantics (default vs explicit)

### Parameter: `include_raw`

**Default-path behavior (`missing(x)`):** `include_raw = FALSE`; no `contrib_[cat]` columns are added to the output.

**Explicit-path behavior (user supplied):** Must be a logical scalar (`TRUE` or `FALSE`). Non-logical input, `NA`, or length > 1 aborts with `rotostats_error_invalid_parameter` (reused from the existing registry — no new class). No silent coercion. When `TRUE`, include `contrib_[cat]` columns in the output; when `FALSE`, omit them. TODO(planner): add this case to the Error Handling table at implementation time.

### Parameter: `cat_pct`

**Default-path behavior (`missing(x)`):** `cat_pct = "auto"`; CAT% is derived from `league_config` using `hitter_split / n_hitter_cats` and `(1 - hitter_split) / n_pitcher_cats`. Uses the conventional 67/33 hitter/pitcher split unless overridden in `league_config`.

**Explicit-path behavior (user supplied):** Must be either the string `"auto"`, the string `"equal"`, or a named numeric vector. If a named numeric vector: names must cover all scored categories (else abort with `rotostats_error_category_mismatch`) and values must satisfy `|sum(cat_pct) - 1.0| < 1e-10` (else abort with `rotostats_error_cat_pct_sum`). Values that are neither `"auto"`, `"equal"`, nor a named numeric vector (e.g., unnamed numeric, other strings, logical, list) abort with `rotostats_error_invalid_parameter` — reuse the existing class rather than introducing a `cat_pct`-specific variant. TODO(planner): add this case to the Error Handling table at implementation time.

### Parameter: `rate_pool`

**Default-path behavior (`missing(x)`):** `rate_pool = "ip_weighted"`; rate stat contributions are volume-weighted in raw stat space using `PS[j, IP] / mean_rostered_IP` or `PS[j, AB] / mean_rostered_AB`.

**Explicit-path behavior (user supplied):** Must be one of `"ip_weighted"`, `"pool_average"`, or `"fixed_baseline"`. Any other value aborts with `rotostats_error_invalid_parameter` — same reuse rationale as `include_raw` and `cat_pct`. When `"fixed_baseline"` is supplied and a scored rate stat category has no baseline in `config` and no override in `baseline`, abort with the class marked TBD in the Error Handling table. TODO(planner): add the invalid-value case to the Error Handling table at implementation time.

### Parameter: `sub_replacement`

**Default-path behavior (`missing(x)`):** `sub_replacement = "clip"`; sub-replacement contributions are clipped to 0, and the sum-to-1 invariant holds across all rostered players.

**Explicit-path behavior (user supplied):** Must be one of `"clip"` or `"negative"`. Any other value aborts with `rotostats_error_invalid_parameter` — same reuse rationale as the other pvm membership checks. When `"negative"`, sub-replacement players retain negative contributions; only positive contributors enter the pool denominator. TODO(planner): add the invalid-value case to the Error Handling table at implementation time.

### Parameter: `baseline`

**Default-path behavior (`missing(x)`):** `baseline = NULL`; baseline constants are read automatically from `config` when `rate_pool = "fixed_baseline"`. When `rate_pool != "fixed_baseline"`, `baseline` is ignored.

**Explicit-path behavior (user supplied):** Must be a named numeric vector whose names match scored rate stat categories present in the league configuration. Non-numeric, unnamed, or partially named `baseline` (including `NA` / `NaN` / non-finite values) aborts with `rotostats_error_invalid_parameter` — same reuse rationale as the other pvm explicit-path checks. TODO(user): decide error class for `baseline` names that do not correspond to scored rate stat categories (candidates: `rotostats_error_invalid_parameter` or `rotostats_error_category_mismatch` — the latter is more specific but requires broadening its condition in `plans/error-messages.md`). Only consulted when `rate_pool = "fixed_baseline"`; TODO(user): decide whether supplying `baseline` under a non-fixed_baseline `rate_pool` is a silent no-op or an error (current spec body says silent; strict-validation consistency with `include_cat` / `pivot` in `spec-dollar-values.md` would argue for error).

**Outputs:**

Returns a data frame with one row per rostered player:

| Column | Type | Description |
|--------|------|-------------|
| `contrib_[cat]` | numeric | Raw above-replacement contribution per category before pool normalization; volume-adjusted for rate stats. Included only when `include_raw = TRUE`. |
| `pvm_[cat]` | numeric | Proportional share of above-replacement pool for category `c`; 0–1; one column per scored category |
| `total_pvm` | numeric | CAT%-weighted sum of per-category shares; interpretable as fraction of total auction budget |

```r
attr(result, "units")  = "budget_fraction"
attr(result, "anchor") = "replacement"
```

**Required columns in `projections` (extracted from replacement):**

| Column | Used for |
|--------|----------|
| Player ID column (name TBD from config) | Row identity |
| Position column | Pool boundary enforcement |
| One column per scored category | Core formula |
| `IP` | Rate stat volume weighting (ERA, WHIP) when `rate_pool = "ip_weighted"` |
| `AB` | Rate stat volume weighting (AVG) when `rate_pool = "ip_weighted"` |

---

## Formal Definition

`pvm(replacement, ...)`

`projections` and `config` are extracted from `attr(replacement, "projections")` and
`attr(replacement, "config")` at call time. If either attribute is absent, `pvm()` aborts with
`rotostats_error_missing_replacement_attrs`.

This enables the pipe idiom:

```r
replacement_level(projections, config) |> pvm()
```

### Step 1 — Extract inputs from replacement object

```r
projections <- attr(replacement, "projections")
config      <- attr(replacement, "config")
```

Abort with `rotostats_error_missing_replacement_attrs` if either attribute is absent.
Abort with `rotostats_error_stat_units_mismatch` if `attr(replacement, "stat_units") !=
"raw_projected"`.

### Step 2 — Identify the rostered pool

Rostered players are the top `n_teams × roster_slots` players at each position, using the
same pool boundary as `replacement_level()`. This is the identical pool used to compute the
replacement stat line — no separate boundary computation is performed by `pvm()`.

### Step 3 — Compute above-replacement contribution per player per category

First compute the signed raw contribution for each player and category:

**Counting stats** (HR, R, RBI, SB, K, W, SV, HLD, SVHD, QS):

```
raw_contrib[i, c] = PS[i, c] - RS[c]
```

**Rate stats — ERA, WHIP** (lower is better, sign flip):

```
raw_contrib[i, c] = RS[c] - PS[i, c]
```

Rate stat contributions are then volume-adjusted before pool summation (see Step 4).

**Rate stats — AVG, OPS** (higher is better, no sign flip):

```
raw_contrib[i, c] = PS[i, c] - RS[c]
```

Then apply sub-replacement handling via the `sub_replacement` parameter:

**`sub_replacement = "clip"` (default):**

Clip all contributions to zero. Sub-replacement players appear in the output with
`pvm_[cat] = 0` and do not affect the pool denominator. The sum-to-1 invariant holds
across all rostered players.

```
contrib[i, c] = max(raw_contrib[i, c], 0)
```

**`sub_replacement = "negative"` (Zola canonical):**

Allow contributions to remain negative. Sub-replacement players receive negative `pvm`
values. Only positive contributors are included in the pool denominator (see Step 4).

```
contrib[i, c] = raw_contrib[i, c]
```

### Step 4 — Compute Pool[c] per category

**Counting stats:**

```
Pool[c] = sum(contrib[j, c]  for all rostered players j)
```

**Rate stats (ERA, WHIP, AVG, OPS) — three options controlled by `rate_pool`:**

In all three options, when `sub_replacement = "negative"`, only positive-contributing players
(`contrib[j, c] > 0`) are included in the pool sum — identical to the counting stat behavior.

**`rate_pool = "ip_weighted"` (default):**

Volume-weight each player's above-replacement contribution before summing, so that a
pitcher who throws 200 IP contributes proportionally more to the pool than one who throws 60 IP:

```
Pool[ERA]  = sum(contrib[j, ERA]  × PS[j, IP] / mean_rostered_IP   for all rostered j)
Pool[WHIP] = sum(contrib[j, WHIP] × PS[j, IP] / mean_rostered_IP   for all rostered j)
Pool[AVG]  = sum(contrib[j, AVG]  × PS[j, AB] / mean_rostered_AB   for all rostered j)
```

Where `mean_rostered_IP` and `mean_rostered_AB` are the mean projected IP and AB across all
rostered pitchers and hitters respectively (computed from the rostered pool in `projections`).

This approach stays in raw stat space — no SGP infrastructure required. It is consistent with
how `zaa()` / `zar()` handle rate stat volume weighting.

**`rate_pool = "pool_average"` (Zola canonical extras method):**

Transform ERA, WHIP, and AVG to counting-equivalent "extras" units using the pool-average
rate stat as the baseline. The baseline is the mean rate stat of all positively-valued
(above-replacement) rostered players in the current projection set:

```
ExH[i]  = PS[i, AB]  × (PS[i, AVG]  – mean_pool_AVG)
ExER[i] = PS[i, IP]  × (mean_pool_ERA  – PS[i, ERA])  / 9
ExWH[i] = PS[i, IP]  × (mean_pool_WHIP – PS[i, WHIP])
```

`Pool[c]` is then the sum of extras across positively-valued players. The pool-average
baseline (`mean_pool_AVG`, `mean_pool_ERA`, `mean_pool_WHIP`) is endogenous — it is
computed from the current projection set and changes with the player pool. No external
baseline constants required. This is the canonical Zola / MastersBall formulation.

**`rate_pool = "fixed_baseline"`:**

Transform ERA, WHIP, and AVG to counting-equivalent units using fixed baseline constants,
consistent with `sgp(rate_conversion = "fixed_baseline")`. Baseline constants are read from
`config` automatically; supply `baseline` (a named numeric vector) to override per-category.
The resulting `Pool[c]` is in counting-equivalent units. Use when consistency with SGP-based
valuations is preferred over self-containment.

### Step 5 — Compute per-player, per-category proportional shares

```
pvm[i, c] = contrib[i, c] / Pool[c]
```

For rate stats with volume weighting, the numerator is also volume-adjusted:

```
pvm[i, ERA] = (contrib[i, ERA] × PS[i, IP] / mean_rostered_IP) / Pool[ERA]
```

If `Pool[c] = 0` (all rostered players are sub-replacement in category `c`), abort with
`rotostats_error_zero_pool`.

When `sub_replacement = "clip"`: all `pvm[i, c]` values are in [0, 1] and
`sum(pvm[j, c]) = 1.0` across all rostered players for each category.

When `sub_replacement = "negative"`: positive-contributing players have `pvm[i, c] > 0`
and their values sum to 1.0; sub-replacement players have `pvm[i, c] < 0`. The total
sum across all rostered players is less than 1.0 by the magnitude of negative shares.

### Step 6 — Compute total_pvm

```
total_pvm[i] = sum(pvm[i, c] × CAT%[c]  for all scored categories c)
```

Where `CAT%[c]` is derived from the `cat_pct` parameter (see cat_pct Parameter below).
`total_pvm[i]` is the fraction of the total auction budget this player is worth. To convert
to dollars: `total_pvm[i] × total_budget`.

**Note on cross-method comparison:** `total_pvm` is in budget-fraction units, not standings
points (`total_par`) or standard deviations (`total_zar`). The three totals are not directly
comparable as raw values. Cross-method comparison requires converting all three to dollars
first, or using rank correlation.

---

## cat_pct Parameter

Controls CAT% allocation used in Step 6.

**`cat_pct = "auto"` (default)**

Derive CAT% from `league_config` using the hitter/pitcher budget split and category counts:

```
CAT%[hitter_cat]  = hitter_split / n_hitter_cats
CAT%[pitcher_cat] = (1 - hitter_split) / n_pitcher_cats
```

Uses the conventional 67% / 33% hitter/pitcher split unless overridden in `league_config`.
This is the correct default for standard 5×5 rotisserie — it follows directly from the
equal-standings-point structure of rotisserie scoring.

**`cat_pct = "equal"`**

Flat equal weighting across all scored categories regardless of hitter/pitcher split:

```
CAT%[c] = 1 / n_scored_categories
```

Use for non-standard formats where the hitter/pitcher distinction is not meaningful, or for
diagnostic comparison against `"auto"`.

**`cat_pct = <named numeric vector>`**

User-supplied explicit weights. Names must cover all scored categories. Values must sum to 1.0
within floating-point tolerance (|sum - 1.0| < 1e-10); abort with `rotostats_error_cat_pct_sum`
if violated.

---

## Error Handling

| Condition | Handler | Class | Trigger fixture |
|-----------|---------|-------|-----------------|
| `replacement` missing `projections` or `config` attributes | `cli_abort()` | `rotostats_error_missing_replacement_attrs` | TS-PVM-1 |
| `attr(replacement, "stat_units") != "raw_projected"` | `cli_abort()` | `rotostats_error_stat_units_mismatch` | TS-PVM-2 |
| `Pool[c] = 0` for any category (all rostered players sub-replacement) | `cli_abort()` | `rotostats_error_zero_pool` | TS-PVM-6 |
| `cat_pct` named vector does not sum to 1.0 within tolerance | `cli_abort()` | `rotostats_error_cat_pct_sum` | TS-PVM-8 |
| `cat_pct` names do not cover all scored categories | `cli_abort()` | `rotostats_error_category_mismatch` | TS-PVM-8 |
| Any `pvm[i, c]` exceeds 0.25 | `cli_warn()` (always) | `rotostats_warning_pvm_concentration` | TS-PVM-7 |
| `sum(pvm[j, c])` deviates from 1.0 by more than 1e-10 for any category | `cli_warn()` (always) | `rotostats_warning_pvm_sum` | TODO(planner): bind to fixture |
| `rate_pool = "fixed_baseline"` and a rate stat category has no baseline in `config` and no override in `baseline` | `cli_abort()` | TBD | TODO(planner): bind to fixture |

_All classes must be registered in `plans/error-messages.md` before implementation._

---

## Why This Measure

SGP denominators require multiple seasons of league-level standings history — typically at least 3 seasons. Many users lack that history, particularly those in new leagues, those who have changed league formats, or those who want to value players from projections alone before a first season.

PVM addresses this gap: it requires only the player pool itself and a replacement-level stat line. No external calibration data is needed. Because the denominator is the pool's own total above-replacement production, PVM self-normalizes to whatever projections or historical stats are supplied.

**Primary alternative: z-scores.** Z-scores measure how unusual a player is relative to the distribution of all pool players (in standard deviation units). PVM measures what fraction of the total above-replacement resource the player controls (in proportion units). Both are valid no-history approaches; PVM has a more direct interpretation for auction valuation because each proportion multiplied by CAT$ immediately yields a dollar value, while z-score-to-dollar conversion requires an additional scaling step.

**SGP is preferred when league history is available.** PVM is the fallback for users without history. The design intent is that `dollar_values()` selects the method based on data availability, but users can also call `pvm()` directly.

---

## Assumptions

| Assumption | Testable? | How to Test / Basis |
|-----------|-----------|---------------------|
| Pool boundary `n_teams × roster_slots` correctly identifies all rostered players | Yes | Verify `sum(pvm[j, c]) = 1.0` for all c after pool normalization |
| Replacement-level player has `pvm[i, c] ≈ 0` for all categories by construction | Yes | Unit test: replacement boundary player's raw pvm before clip should be exactly 0 |
| Rate stat non-additivity requires a separate Pool[c] formula | Yes | Compare IP-weighted pool denominator to naive summation; quantify error for edge cases (single dominant closer, etc.) |
| Projections incorporate realistic playing time; no minimum AB/IP filter needed | Partially | Check pool composition for part-time or injured players with full-season projections; flag if any single player's projected PA < threshold |
| Sign convention (ERA, WHIP flip) produces non-negative values for all above-replacement pitchers | Yes | Unit test: all pitchers with ERA < RS[ERA] should have pvm_ERA > 0 before clipping |
| Sub-replacement players clipped to 0 produce a correct pool sum | Yes | Unit test with synthetic data including sub-replacement players; verify sum-to-1 invariant holds |
| Equal CAT$ weighting is defensible as default for standard 5x5 rotisserie | Partially | By design (each category worth equal standings points); not empirically validated for all league formats |

---

## Decision This Informs

- **Primary use:** Produce per-category proportional pool shares that feed `dollar_values()` when league standings history is unavailable
- **Consumer:** `dollar_values()` (primary), direct user inspection (secondary)
- **How consumed:** `dollar_values()` multiplies `total_pvm` by `total_budget` to produce total dollar values per player. Direct users inspect `pvm` output to compare players within a single category.
- **Sensitivity:** All `pvm` values are jointly determined — adding or removing a single player from the pool shifts every other player's `pvm` in that category. A player who dominates one category (e.g., >20% of the SB pool) suppresses all other players' SB shares. The sum-to-1 constraint means adding a very large-projection player to the pool reduces every other player's share proportionally.

---

## Dependencies

**Upstream:**
- `replacement_level()`: provides `RS[c]` (the replacement stat line per category), defines the pool boundary (`n_teams × roster_slots`), and carries `projections` and `config` as attributes on the returned object
- `projections` and `config` are extracted from `attr(replacement, "projections")` and `attr(replacement, "config")` at call time — no separate `stats` argument is required

**Downstream:**
- `dollar_values()`: multiplies `total_pvm` by `total_budget` to produce auction dollar values; `pvm()` output is the primary input when `method = "pvm"` is selected
- User: direct inspection of per-category pool shares for within-category player comparison without dollar conversion

**Sibling functions:**
- `par()`: same above-replacement quantity in standings-point units; use when historical SGP denominators are available.
- `zar()`: same above-replacement quantity in standard deviation units; use when historical data is unavailable, same as `pvm()`, but z-scores are calibrated to the within-position distribution rather than the total above-replacement pool. Prefer `pvm()` when the proportional pool share interpretation is more useful than the distributional interpretation.
- `zaa()`: above-average z-scores without a replacement anchor; use when replacement anchoring is not needed.
- `sgp()`: raw standings-point conversion without replacement subtraction; not an alternative to `pvm()` but an upstream building block for `par()`.
- `dollar_values()`: primary downstream consumer; multiplies `total_pvm` by `total_budget` to produce auction dollar values.

---

## Known Validity Threats

### Conceptual (Q1)

---

**Q1-PVM-1: Rate stat pool denominator formula** _(resolved — Amendment 2)_

Resolved via three options via `rate_pool`: `"ip_weighted"` (default) volume-weights contributions
in raw stat space, consistent with the no-history design goal and `zaa()` / `zar()`; `"pool_average"`
implements the canonical Zola extras method using an endogenous pool-average baseline; `"fixed_baseline"`
aligns with `sgp(rate_conversion = "fixed_baseline")` for users who want cross-method consistency.

---

**Q1-PVM-2: Default CAT$ equal weighting vs. explicit user choice** _(resolved — Amendment 3)_

Resolved via `cat_pct` parameter. Default is `cat_pct = "auto"`, deriving from `league_config`.
Equal weighting within the hitter/pitcher split is the correct structural default for standard 5×5
rotisserie. The `"equal"` and explicit-vector options cover non-standard formats.

---

### Statistical (Q2)

### Simulation studies — Signal pre-check (mandatory before R ≥ 100)

PVM is a deterministic pool-share transform; sim studies apply when evaluating finite-sample behavior of pool sums vs. the sum-to-1 invariant under floating-point accumulation, or when probing sensitivity to pool composition (adding/removing one player).

For each sim study (when added):

**Estimator used:** <name — e.g., "ip-weighted pool denominator", "pool-average extras">

**Analytical signal prediction:** <closed-form or approximate expression for the estimand under this DGP>. `TODO(planner): derive analytical prediction`

**Small-R pre-check (R ≤ 50):**
- Gate: <quantitative PASS condition that must hold at R=50 before proceeding to R=500>
- If gate fails: BLOCK. Route to planner — DGP or estimator assumption is wrong.

**Estimator-threshold compatibility:** Thresholds calibrated for the three `rate_pool` options must be verified per-option. A threshold derived for `rate_pool = "ip_weighted"` is NOT valid for `rate_pool = "pool_average"` (endogenous baseline) or `rate_pool = "fixed_baseline"` (external constants). `TODO(planner): calibrate per rate_pool option`.

_Pending — fill in after code audit of relevant source files. Key areas to audit: pool boundary implementation (does the player set passed to `pvm()` match the `n_teams × roster_slots` boundary from `replacement_level()`?), clipping behavior for sub-replacement players, and floating-point precision of the sum-to-1 invariant._

---

### Decision (Q3)

_Pending — fill in after validation harness results. Primary question: do PVM-derived dollar values rank players similarly to SGP-derived dollar values when both are available for comparison? Spearman ρ between PVM dollar values and final standings points is a secondary validation target (expected to be lower than SGP, since PVM lacks league-specific calibration)._

---

## Validation Approach

### Runtime checks

These fire on every call and are automatable as unit tests.

### TS-PVM-1 — Attribute extraction guard fires when replacement lacks attributes

**Preconditions (inputs must satisfy):**
- `replacement` argument is an object whose `projections` attribute OR `config` attribute is `NULL` / absent.
- All other parameters are omitted so defaults apply.

**Target guard / behavior under test:**
- `pvm()` aborts with `rotostats_error_missing_replacement_attrs` during Step 1 attribute extraction.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_stat_units_mismatch` — cannot fire before the attribute-presence check, which runs first.
- `rotostats_error_zero_pool` — unreachable because execution aborts before Step 4.
- `rotostats_error_cat_pct_sum` — `cat_pct` defaults to `"auto"`; no named numeric supplied.
- `rotostats_error_category_mismatch` — unreachable; execution aborts before cat_pct is consulted.
- `rotostats_error_multi_pos_all_unsupported` — TODO(planner): enumerate upstream guards (spec does not currently state where/if `pvm()` checks `params$multi_pos`).
- `rotostats_warning_pvm_concentration` — unreachable; execution aborts before pvm values exist.
- `rotostats_warning_pvm_sum` — unreachable; execution aborts before pvm values exist.

**Expected outcome:**
- Abort with class string `"rotostats_error_missing_replacement_attrs"`.

### TS-PVM-2 — Stat-units mismatch guard fires when stat_units attribute is wrong

**Preconditions (inputs must satisfy):**
- `replacement` has valid `projections` and `config` attributes.
- `attr(replacement, "stat_units")` is present but not equal to `"raw_projected"`.
- All other parameters omitted so defaults apply.

**Target guard / behavior under test:**
- `pvm()` aborts with `rotostats_error_stat_units_mismatch` during Step 1.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_missing_replacement_attrs` — fixture supplies both required attributes.
- `rotostats_error_zero_pool` — unreachable; execution aborts before Step 4.
- `rotostats_error_cat_pct_sum` — `cat_pct` defaults to `"auto"`.
- `rotostats_error_category_mismatch` — unreachable; execution aborts before cat_pct resolution.
- `rotostats_error_multi_pos_all_unsupported` — TODO(planner): enumerate upstream guards.
- `rotostats_warning_pvm_concentration` — unreachable; aborts before pvm values computed.
- `rotostats_warning_pvm_sum` — unreachable; aborts before pvm values computed.

**Expected outcome:**
- Abort with class string `"rotostats_error_stat_units_mismatch"`.

### TS-PVM-3 — Sum-to-1 invariant under `sub_replacement = "clip"`

**Preconditions (inputs must satisfy):**
- Valid `replacement` object (projections, config, `stat_units = "raw_projected"` all present).
- Projection set contains a mix of above- and below-replacement players in every scored category; at least one strictly positive contributor per category.
- `sub_replacement = "clip"` (either by default or explicit).
- `cat_pct` defaults to `"auto"`; `rate_pool` defaults to `"ip_weighted"`; `baseline = NULL`.
- No single player's `pvm[i, c]` exceeds 0.25 (otherwise the concentration warning would also fire — not this fixture's target).

**Target guard / behavior under test:**
- `sum(pvm[j, c]) == 1.0` within 1e-10 for every scored category `c`; no `rotostats_warning_pvm_sum` fires.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_missing_replacement_attrs` — attributes are present.
- `rotostats_error_stat_units_mismatch` — stat_units is `"raw_projected"`.
- `rotostats_error_zero_pool` — each category has positive contributors.
- `rotostats_error_cat_pct_sum` — cat_pct is `"auto"`, not a named vector.
- `rotostats_error_category_mismatch` — cat_pct is `"auto"`; no user names to mismatch.
- `rotostats_error_multi_pos_all_unsupported` — TODO(planner): enumerate upstream guards.
- `rotostats_warning_pvm_concentration` — fixture explicitly bounds `pvm[i, c] <= 0.25`.
- `rotostats_warning_pvm_sum` — asserted NOT to fire; this fixture exists to verify invariant holds.

**Expected outcome:**
- For every category `c`: `abs(sum(pvm[, c]) - 1.0) < 1e-10`; no warning emitted.

### TS-PVM-4 — Positive-only sum-to-1 under `sub_replacement = "negative"`

**Preconditions (inputs must satisfy):**
- Valid `replacement` object.
- Projection set contains both above- and below-replacement players in each scored category.
- `sub_replacement = "negative"` supplied explicitly.
- Remaining parameters at defaults; no single positive player's `pvm[i, c]` exceeds 0.25.

**Target guard / behavior under test:**
- Sum of `pvm[j, c]` restricted to positive-contributing players equals 1.0 within 1e-10 for each category; sub-replacement players have `pvm[i, c] < 0`; total sum across all rostered players is less than 1.0 by the magnitude of negative shares.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_missing_replacement_attrs` — attributes present.
- `rotostats_error_stat_units_mismatch` — stat_units is `"raw_projected"`.
- `rotostats_error_zero_pool` — at least one positive contributor per category.
- `rotostats_error_cat_pct_sum` — cat_pct at default.
- `rotostats_error_category_mismatch` — cat_pct at default.
- `rotostats_error_multi_pos_all_unsupported` — TODO(planner): enumerate upstream guards.
- `rotostats_warning_pvm_concentration` — fixture bounds positive pvm values ≤ 0.25.
- `rotostats_warning_pvm_sum` — asserted NOT to fire on the positive-only sum.

**Expected outcome:**
- `abs(sum(pvm[pvm[, c] > 0, c]) - 1.0) < 1e-10` for every category; no warning emitted.

### TS-PVM-5 — Replacement boundary player has pvm ≈ 0

**Preconditions (inputs must satisfy):**
- Valid `replacement` object.
- Projection set where the replacement boundary player (lowest-ranked rostered at each position) has `PS[boundary, c] == RS[c]` exactly for every scored category.
- Parameters at defaults.

**Target guard / behavior under test:**
- The boundary player's `contrib[boundary, c]` is exactly 0 before pool normalization; after normalization, `abs(pvm[boundary, c]) < 1e-10`.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_missing_replacement_attrs` — attributes present.
- `rotostats_error_stat_units_mismatch` — stat_units is `"raw_projected"`.
- `rotostats_error_zero_pool` — pool still has strictly positive contributors (boundary player contributes 0, not all players).
- `rotostats_error_cat_pct_sum` — cat_pct default.
- `rotostats_error_category_mismatch` — cat_pct default.
- `rotostats_error_multi_pos_all_unsupported` — TODO(planner): enumerate upstream guards.
- `rotostats_warning_pvm_concentration` — boundary pvm ≈ 0; irrelevant.
- `rotostats_warning_pvm_sum` — fixture sized so invariant holds.

**Expected outcome:**
- `abs(pvm[boundary_player, c]) < 1e-10` for every scored category `c`.

### TS-PVM-6 — Zero-pool abort when all rostered players are sub-replacement

**Preconditions (inputs must satisfy):**
- Valid `replacement` object.
- Projection set constructed so that in at least one scored category `c*`, every rostered player has `PS[i, c*] <= RS[c*]` (after sign flip for ERA/WHIP).
- `sub_replacement = "clip"` (default) so `Pool[c*] = 0`.
- Other parameters at defaults.

**Target guard / behavior under test:**
- `pvm()` aborts with `rotostats_error_zero_pool` during Step 5 (or during Step 4 pool computation), naming the affected category.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_missing_replacement_attrs` — attributes present.
- `rotostats_error_stat_units_mismatch` — stat_units is `"raw_projected"`.
- `rotostats_error_cat_pct_sum` — cat_pct default.
- `rotostats_error_category_mismatch` — cat_pct default.
- `rotostats_error_multi_pos_all_unsupported` — TODO(planner): enumerate upstream guards.
- `rotostats_warning_pvm_concentration` — unreachable; abort precedes pvm computation for the zero-pool category.
- `rotostats_warning_pvm_sum` — unreachable; abort precedes invariant check.

**Expected outcome:**
- Abort with class string `"rotostats_error_zero_pool"`.

### TS-PVM-7 — Concentration warning when a single player exceeds 25% share

**Preconditions (inputs must satisfy):**
- Valid `replacement` object.
- Projection set where exactly one player's projected value in category `c*` dominates (e.g., a single elite closer with projected SV far above all peers), so `pvm[i*, c*] > 0.25` after normalization.
- No category has all-sub-replacement players; sum-to-1 invariant still holds.
- Parameters at defaults.

**Target guard / behavior under test:**
- `rotostats_warning_pvm_concentration` fires for player `i*` and category `c*`; `pvm()` returns a valid data frame (warning, not abort).

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_missing_replacement_attrs` — attributes present.
- `rotostats_error_stat_units_mismatch` — stat_units correct.
- `rotostats_error_zero_pool` — pool non-zero by construction.
- `rotostats_error_cat_pct_sum` — cat_pct default.
- `rotostats_error_category_mismatch` — cat_pct default.
- `rotostats_error_multi_pos_all_unsupported` — TODO(planner): enumerate upstream guards.
- `rotostats_warning_pvm_sum` — fixture sized so invariant holds within tolerance.

**Expected outcome:**
- Warning class `"rotostats_warning_pvm_concentration"` emitted naming player `i*` and category `c*`; returned data frame includes the expected `pvm_[cat]` columns.

### TS-PVM-8 — cat_pct named-vector sum and membership guards

**Preconditions (inputs must satisfy):**
- Valid `replacement` object.
- `cat_pct` supplied as a named numeric vector.
- Two sub-fixtures: (a) values sum to 0.95 (not 1.0 within tolerance); (b) values sum to 1.0 but names omit a scored category.
- Other parameters at defaults.

**Target guard / behavior under test:**
- (a) aborts with `rotostats_error_cat_pct_sum`. (b) aborts with `rotostats_error_category_mismatch`.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_missing_replacement_attrs` — attributes present.
- `rotostats_error_stat_units_mismatch` — stat_units correct.
- `rotostats_error_zero_pool` — unreachable; cat_pct validation occurs before pool computation (TODO(planner): confirm ordering in implementation).
- `rotostats_error_multi_pos_all_unsupported` — TODO(planner): enumerate upstream guards.
- `rotostats_warning_pvm_concentration` — unreachable; aborts before pvm output.
- `rotostats_warning_pvm_sum` — unreachable; aborts before invariant check.
- In sub-fixture (a), `rotostats_error_category_mismatch` MUST NOT fire first — names may match but sum fails; TODO(planner): confirm sum check ordering relative to name check.
- In sub-fixture (b), `rotostats_error_cat_pct_sum` MUST NOT fire first — sum is 1.0; name check is the target.

**Expected outcome:**
- Sub-fixture (a): abort with class string `"rotostats_error_cat_pct_sum"`.
- Sub-fixture (b): abort with class string `"rotostats_error_category_mismatch"`.

### TS-PVM-9 — Pipe-compatibility: piped and nested calls produce identical output

**Preconditions (inputs must satisfy):**
- Valid `projections` and `config` inputs that produce a well-formed `replacement_level()` output.
- Call path A: `replacement_level(projections, config) |> pvm()`.
- Call path B: `pvm(replacement_level(projections, config))`.
- Parameters at defaults in both paths.

**Target guard / behavior under test:**
- Outputs from A and B are structurally identical: same columns, same row order, element-wise equal within 1e-12, and identical `units` / `anchor` attributes.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_missing_replacement_attrs` — attributes present.
- `rotostats_error_stat_units_mismatch` — stat_units correct.
- `rotostats_error_zero_pool` — fixture has positive pools.
- `rotostats_error_cat_pct_sum` — cat_pct default.
- `rotostats_error_category_mismatch` — cat_pct default.
- `rotostats_error_multi_pos_all_unsupported` — TODO(planner): enumerate upstream guards.
- `rotostats_warning_pvm_concentration` — fixture sized so no player exceeds 25%.
- `rotostats_warning_pvm_sum` — fixture sized so invariant holds.

**Expected outcome:**
- `identical(A[order(A$player_id), ], B[order(B$player_id), ])` is `TRUE`; `attr(A, "units") == attr(B, "units") == "budget_fraction"`; `attr(A, "anchor") == attr(B, "anchor") == "replacement"`.

### Manual diagnostics

Run once per projection vintage during Q3 validation.

- **Elite player sanity check:** The top player by `pvm_[cat]` in each category should be a
  recognizable elite producer in that category (e.g., HR pool leader among projection HR leaders).
  A non-elite player leading a deep category is a signal of a pool boundary or projection error.
- **Cross-method rank correlation:** When `par()` or `zar()` output is also available, Spearman ρ
  between `total_pvm` rankings and `total_par` / `total_zar` rankings should exceed 0.90.
  Deviations above 0.15 should trigger investigation; identify which categories are driving
  the divergence. Divergence at SV and SB is expected and is not a failure signal.
- **cat_pct = "auto" vs "equal" comparison:** Run both and compare `total_pvm` rankings. In a
  standard 5×5 league these should produce near-identical rankings. Material divergence
  indicates the hitter/pitcher split in `league_config` differs from the 67/33 convention —
  inspect config before use.
