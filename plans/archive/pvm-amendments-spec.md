# PVM Spec Amendments

> **Date:** 2026-04-16
> **Amends:** `specs/spec-pvm.md`
> **Status:** Proposed — apply before Q2 code audit begins

These amendments bring `pvm()` into alignment with the `par()` / `zar()` design pattern established
after the PVM spec was drafted. They also resolve Q1-PVM-1 and Q1-PVM-2.

---

## Summary

| # | Amendment | Resolves |
|---|-----------|---------|
| 1 | Remove `stats` argument; extract `projections` and `config` from `replacement` attributes | Interface alignment with `par()` / `zar()` |
| 2 | Add step-numbered Formal Definition with `rate_pool` and `sub_replacement` parameters | Q1-PVM-1 |
| 3 | Add `total_pvm` as CAT%-weighted sum via `cat_pct` parameter | Q1-PVM-2 |
| 4 | Add Interface section | Missing section |
| 5 | Add Error Handling section | Missing section |
| 6 | Update output spec with `total_pvm` and output attributes | — |
| 7 | Reformat Validation Approach into Runtime / Manual Diagnostics | Alignment with `par()` / `zar()` |
| 8 | Add Sibling Functions to Dependencies | Missing content |

---

## Amendment 1 — Function Signature

**Current:** `pvm(stats, replacement, ...)`

**Proposed:** `pvm(replacement, ...)`

`pvm()` extracts `projections` and `config` from `attr(replacement, "projections")` and
`attr(replacement, "config")` at call time, identical to the pattern in `zar()`. If either
attribute is absent, `pvm()` aborts with `rotostats_error_missing_replacement_attrs`.

**Rationale:** `replacement_level()` already carries the projections as an attribute. Requiring a
separate `stats` argument forces the caller to manage two objects that must be consistent — the
same data integrity risk that the attribute pattern was designed to eliminate. `par()` and `zar()`
both use this pattern; `pvm()` should match.

This also enables the pipe idiom:

```r
replacement_level(projections, config) |> pvm()
```

---

## Amendment 2 — Formal Definition (step-numbered, rate_pool parameter)

Replace the existing prose-and-formula definition with the following step-numbered structure.

---

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

Where `CAT%[c]` is derived from the `cat_pct` parameter (see Interface). `total_pvm[i]`
is the fraction of the total auction budget this player is worth. To convert to dollars:
`total_pvm[i] × total_budget`.

**Note on cross-method comparison:** `total_pvm` is in budget-fraction units, not standings
points (`total_par`) or standard deviations (`total_zar`). The three totals are not directly
comparable as raw values. Cross-method comparison requires converting all three to dollars
first, or using rank correlation.

---

## Amendment 3 — cat_pct Parameter and Q1-PVM-2 Resolution

**Resolves Q1-PVM-2.**

Add `cat_pct` parameter to control CAT% allocation. Three modes:

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

## Amendment 4 — Interface Section (new)

Add the following Interface section to the spec, replacing the current implicit signature.

```r
pvm(
  replacement,
  cat_pct         = "auto",
  rate_pool       = "ip_weighted",
  sub_replacement = "clip",
  baseline        = NULL
)
```

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `replacement` | replacement_level output | Yes | Must carry `projections` and `config` as attributes. Produced by `replacement_level()`. Any other object aborts with `rotostats_error_missing_replacement_attrs`. |
| `cat_pct` | character or named numeric | No | `"auto"` (default) — derive from config. `"equal"` — flat across all categories. Named numeric vector — explicit weights, must sum to 1.0. |
| `rate_pool` | character | No | `"ip_weighted"` (default) — volume-weight rate stat contributions in raw stat space. `"pool_average"` — Zola canonical extras method with pool-average baseline. `"fixed_baseline"` — counting equivalents using fixed baseline constants from `config`, consistent with `sgp(rate_conversion = "fixed_baseline")`. |
| `sub_replacement` | character | No | `"clip"` (default) — clip sub-replacement contributions to 0; sum-to-1 invariant holds across all rostered players. `"negative"` — allow negative values for sub-replacement players; only positive contributors included in pool denominator (Zola canonical). |
| `baseline` | named numeric | No | Per-category baseline overrides. Names must match scored rate stat categories. Only used when `rate_pool = "fixed_baseline"`. When `NULL` (default), baseline constants are read from `config` automatically. Supports any rate stats present in the league configuration, not just ERA, WHIP, and AVG. |

**Outputs:**

Returns a data frame with one row per rostered player:

| Column | Type | Description |
|--------|------|-------------|
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

## Amendment 5 — Error Handling Section (new)

Add the following Error Handling section.

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

## Amendment 6 — Output Spec Updates

The current spec states `pvm()` does **not** produce a `total_pvm` column. **Reverse this.**

`total_pvm` is produced as the CAT%-weighted sum (Amendment 3) and is the correct aggregate for
this method. The original reasoning ("summing before dollar weighting is misleading") is resolved
by using CAT% weighting: `total_pvm` is already in budget-fraction units, not raw proportion units,
and has a direct interpretation as the player's fraction of the total auction budget.

The `attr(result, "units") = "budget_fraction"` attribute makes the unit explicit and prevents
naive cross-method comparison of raw totals.

---

## Amendment 7 — Validation Approach (reformatted)

Replace the current Validation Approach section with the following split structure, mirroring
`spec-par.md` and `spec-zar.md`.

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

---

## Amendment 8 — Sibling Functions (add to Dependencies)

Add the following Sibling Functions subsection to the Dependencies section.

**Sibling functions:**
- `par()`: same above-replacement quantity in standings-point units; use when historical SGP
  denominators are available.
- `zar()`: same above-replacement quantity in standard deviation units; use when historical
  data is unavailable, same as `pvm()`, but z-scores are calibrated to the within-position
  distribution rather than the total above-replacement pool. Prefer `pvm()` when the
  proportional pool share interpretation is more useful than the distributional interpretation.
- `zaa()`: above-average z-scores without a replacement anchor; use when replacement anchoring
  is not needed.
- `sgp()`: raw standings-point conversion without replacement subtraction; not an alternative
  to `pvm()` but an upstream building block for `par()`.
- `dollar_values()`: primary downstream consumer; multiplies `total_pvm` by `total_budget` to
  produce auction dollar values.

---

## Resolutions

**Q1-PVM-1 (rate stat pool denominator):** Resolved via Amendment 2. Three options via
`rate_pool`: `"ip_weighted"` (default) volume-weights contributions in raw stat space,
consistent with the no-history design goal and `zaa()` / `zar()`; `"pool_average"` implements
the canonical Zola extras method using an endogenous pool-average baseline; `"fixed_baseline"`
aligns with `sgp(rate_conversion = "fixed_baseline")` for users who want cross-method
consistency.

**Q1-PVM-2 (CAT$ equal weighting default):** Resolved via Amendment 3. Default is
`cat_pct = "auto"`, deriving from `league_config`. Equal weighting within the hitter/pitcher
split is the correct structural default for standard 5×5 rotisserie. The `"equal"` and
explicit-vector options cover non-standard formats.

---

## Open Items

- Error class names marked TBD in Amendment 5 must be registered in `plans/error-messages.md`
  before implementation begins.
- The player ID column name referenced in the required-columns table (Amendment 4) needs to be
  confirmed against the `replacement_level()` output spec.
- `rate_pool = "fixed_baseline"`: config values are used automatically; `baseline` (named
  vector) overrides per-category. Error class for missing baseline (TBD in Amendment 5) must
  be registered in `plans/error-messages.md` before implementation.
