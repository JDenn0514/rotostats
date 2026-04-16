# Metric Spec: Percentage Valuation Method (`pvm()`)

> **Status:** Draft · 2026-04-13 · Amended 2026-04-16
> **Q1 Conceptual:** Complete · **Q2 Statistical:** Pending code audit · **Q3 Decision:** Pending validation
>
> **Open Q1 questions:** 0 — Q1-PVM-1 and Q1-PVM-2 resolved by amendments

---

## Purpose

Compute per-player, per-category proportional shares of above-replacement production so that players can be compared and valued from projections or a single historical season alone, without requiring league standings history.

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

| Condition | Handler | Class |
|-----------|---------|-------|
| `replacement` missing `projections` or `config` attributes | `cli_abort()` | `rotostats_error_missing_replacement_attrs` |
| `attr(replacement, "stat_units") != "raw_projected"` | `cli_abort()` | `rotostats_error_stat_units_mismatch` |
| `Pool[c] = 0` for any category (all rostered players sub-replacement) | `cli_abort()` | `rotostats_error_zero_pool` |
| `cat_pct` named vector does not sum to 1.0 within tolerance | `cli_abort()` | `rotostats_error_cat_pct_sum` |
| `cat_pct` names do not cover all scored categories | `cli_abort()` | `rotostats_error_category_mismatch` |
| Any `pvm[i, c]` exceeds 0.25 | `cli_warn()` (always) | `rotostats_warning_pvm_concentration` |
| `sum(pvm[j, c])` deviates from 1.0 by more than 1e-10 for any category | `cli_warn()` (always) | `rotostats_warning_pvm_sum` |
| `rate_pool = "fixed_baseline"` and a rate stat category has no baseline in `config` and no override in `baseline` | `cli_abort()` | TBD |

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

_Pending — fill in after code audit of relevant source files. Key areas to audit: pool boundary implementation (does the player set passed to `pvm()` match the `n_teams × roster_slots` boundary from `replacement_level()`?), clipping behavior for sub-replacement players, and floating-point precision of the sum-to-1 invariant._

---

### Decision (Q3)

_Pending — fill in after validation harness results. Primary question: do PVM-derived dollar values rank players similarly to SGP-derived dollar values when both are available for comparison? Spearman ρ between PVM dollar values and final standings points is a secondary validation target (expected to be lower than SGP, since PVM lacks league-specific calibration)._

---

## Validation Approach

### Runtime checks

These fire on every call and are automatable as unit tests.

- **Attribute extraction guard:** `pvm()` must abort with `rotostats_error_missing_replacement_attrs`
  when `projections` or `config` attributes are absent from `replacement`.
- **Sum-to-1 invariant:** Behavior depends on `sub_replacement`:
  - `"clip"`: `sum(pvm[j, c])` across all rostered players must equal 1.0 within 1e-10.
    Emit `rotostats_warning_pvm_sum` naming the category and reporting the observed sum if
    violated.
  - `"negative"`: `sum(pvm[j, c])` for positive-contributing players only must equal 1.0
    within 1e-10. Assert the positive-only sum; do not assert the total (which will be less
    than 1.0 by construction).
- **Replacement player at zero:** The replacement boundary player at each position must have
  `pvm_[cat] ≈ 0` for all categories. Assert deviation < 1e-10 before pool normalization
  (numerator is exactly 0 by construction); after normalization, deviation reflects only
  floating-point accumulation.
- **Concentration diagnostic:** Any `pvm[i, c] > 0.25` triggers `rotostats_warning_pvm_concentration`
  naming the player and category. Diagnostic only — no correction applied.
- **cat_pct sum guard:** If `cat_pct` is a named vector, assert `|sum(cat_pct) - 1.0| < 1e-10`
  and that names cover all scored categories. Abort on violation.
- **Pipe-compatibility check:** `replacement_level(projections, config) |> pvm()` must produce
  output structurally identical to `pvm(replacement_level(projections, config))`.

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
