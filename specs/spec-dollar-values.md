# Metric Spec: Auction Dollar Values (`dollar_values()`)

> **Status:** Draft · 2026-04-16
> **Q1 Conceptual:** Complete · **Q2 Statistical:** Pending code audit · **Q3 Decision:** Pending validation

---

## Purpose

Convert above-replacement valuations (PAR, ZAR, or PVM) into auction dollar values by
proportionally distributing the available league budget. Supports multi-method comparison
in a single call and optionally adjusts for keeper-league inflation.

---

## Formal Definition

`dollar_values(valuation, config, keepers = NULL, include_cat = FALSE, pivot = FALSE)`

`valuation` is a single PAR/ZAR/PVM output or a list of them. `config` is a
`league_config` object. `keepers` is an optional data frame of retained players and their
salaries.

### Step 1 — Resolve method labels and extract valuation columns

For each element of `valuation`, read `attr(el, "units")` and `attr(el, "anchor")`.
Abort with `rotostats_error_invalid_anchor` if any element has `anchor != "replacement"`.

Map `units` to method label and total column:

| `units` value | Method label | Total column | Per-category columns |
|---|---|---|---|
| `"sgp"` | `sgp` | `total_par` | `par_[cat]` |
| `"zscore"` | `zscore` | `total_zar` | `zar_[cat]` |
| `"budget_fraction"` | `pvm` | `total_pvm` | `pvm_[cat]` |

Any other `units` value aborts with `rotostats_error_invalid_valuation_units`.

**Column naming:**

- **Named list** (`list(sgp = par_df, zscore = zar_df)`): list names are used as method
  labels → `dollars_sgp`, `dollars_zscore`.
- **Single valuation** (not a list): method label inferred from `attr(valuation, "units")`
  → `dollars_sgp`, `dollars_zscore`, or `dollars_pvm`.
- **Unnamed list**: positional labels `A`, `B`, `C`, … → `dollars_A`, `dollars_B`.
  Emits `rotostats_warning_unnamed_valuation_list` directing the user to supply a named
  list for meaningful column names.

### Step 2 — Compute budget allocations

```r
total_budget  <- config$n_teams * config$budget     # total league-wide budget
n_h           <- nrow(hitter_subset_of_valuation)    # all unique rostered hitters
n_p           <- nrow(pitcher_subset_of_valuation)   # all unique rostered pitchers

alloc_h <- total_budget * config$budget_split - n_h * 1
alloc_p <- total_budget * (1 - config$budget_split) - n_p * 1
```

Abort with `rotostats_error_negative_allocatable_budget` if `alloc_h ≤ 0` or
`alloc_p ≤ 0`. This indicates that $1 minimums exhaust the budget for one group —
typically caused by a misconfigured `budget_split` or an implausibly large roster depth.

### Step 3 — Proportional allocation per method

**SGP and z-score methods** (`units = "sgp"` or `"zscore"`):

Players compete for budget within their group (hitters for `alloc_h`, pitchers for
`alloc_p`). Each player receives a share proportional to their clipped above-replacement
value, plus the $1 minimum.

```r
# For each player i:
val[i]  <- max(total_col[i], 0)

# Hitters:
dollars_m[i] <- val[i] / sum(val[hitters]) * alloc_h + 1

# Pitchers:
dollars_m[i] <- val[i] / sum(val[pitchers]) * alloc_p + 1
```

Abort with `rotostats_error_zero_pool` if `sum(val[hitters]) = 0` or
`sum(val[pitchers]) = 0`. This means all rostered players in one group are at or below
replacement — indicates a pool or replacement-level misconfiguration, not a normal input.

**PVM method** (`units = "budget_fraction"`):

`total_pvm[i]` already encodes the hitter/pitcher budget split via the `CAT%` weights
from `pvm()`. Applying a separate group split would double-count it. Allocation is over
the total allocatable budget.

```r
alloc_total <- total_budget - (n_h + n_p) * 1

dollars_pvm[i] <- total_pvm[i] * alloc_total + 1
```

`sum(total_pvm[j]) = 1.0` by construction (from pvm's sum-to-1 invariant), so
`sum(dollars_pvm[j]) = alloc_total + (n_h + n_p) = total_budget`. Budget reconciliation
holds by construction for PVM.

For SGP and z-score, budget reconciliation holds only approximately — floating-point
accumulation may introduce sub-dollar error. Emit `rotostats_warning_budget_reconciliation`
if `|sum(dollars_m) - total_budget| > 1`.

### Step 4 — Per-category dollar attribution (when `include_cat = TRUE`)

For each player `i` and scored category `c`, attribute the player's total dollar value
across categories in proportion to their above-replacement contribution per category.

```r
# SGP:    val_cat[i, c] <- max(par[i, c],  0)
# zscore: val_cat[i, c] <- max(zar[i, c],  0)
# PVM:    val_cat[i, c] <- max(pvm[i, c] * CAT_pct[c], 0)
#         where CAT_pct[c] is extracted from attr(valuation, "cat_pct")

total_weight[i] <- sum_c(val_cat[i, c])

dollars_m_cat[i, c] <- dollars_m[i] * val_cat[i, c] / total_weight[i]
```

When `total_weight[i] = 0` (player at or below replacement in all categories), set
all `dollars_m_cat[i, c] = 0`.

Per-category columns are **attributions**, not independent market prices. They sum to
`dollars_m[i]` by construction. They answer: "of this player's $N, how much comes from
each category?"

Column naming: `dollars_[label]_[cat]` (e.g., `dollars_sgp_HR`, `dollars_zscore_ERA`).

### Step 5 — Keeper inflation adjustment (when `keepers` non-NULL)

Delegate to `adjust_keeper_inflation(dollars, keepers, config)`. The internal helper
adds `dollars_[label]_adj`, `is_keeper`, `keeper_salary`, and `surplus_[label]` columns
to the output. See `adjust_keeper_inflation()` section below.

### Step 6 — Format output

**Wide format** (default, `pivot = FALSE`): one row per player.

**Long format** (`pivot = TRUE`): one row per player × method, with columns `method`,
`dollars`, and — when keepers supplied — `dollars_adj`, `is_keeper`, `keeper_salary`,
`surplus`.

---

## `adjust_keeper_inflation()`

An exported utility called internally by `dollar_values()` when `keepers` is non-NULL.
Can be called directly on already-computed dollar values to apply or re-apply keeper
adjustment without re-running the full pipeline.

```r
adjust_keeper_inflation(dollars, keepers, config)
```

**Steps:**

1. Join `keepers` onto `dollars` by the player identity column. Rows in `dollars` not
   matched in `keepers` receive `is_keeper = FALSE`, `keeper_salary = NA`.
   Rows in `keepers` not matched in `dollars` emit `cli_warn()` naming the unmatched
   players — they are retained players whose projections are absent from the valuation
   pool.

2. Behavior depends on `config$keeper$method`:

   **`"salary_adjust"`** — adjust open-market prices for inflation:
   ```r
   open_market_budget <- total_budget - sum(keepers$salary)
   inflation_mult     <- open_market_budget / sum(dollars_m[!is_keeper])

   dollars_m_adj[i]   <- dollars_m[i] * inflation_mult   # non-keepers
   dollars_m_adj[i]   <- dollars_m[i]                    # keepers (off-market)
   surplus_m[i]       <- dollars_m[i] - keeper_salary[i] # keepers only; NA otherwise
   ```
   Emit `rotostats_warning_negative_inflation` if `inflation_mult < 1.0` — this means
   keeper salaries exceed the open-market value of the retained players, which indicates
   keepers are overpriced relative to model values.

   **`"pool_shrink"`** — pool adjustment was handled upstream when the user excluded kept
   players from the projections before calling `replacement_level()`. No price adjustment
   is applied here. Adds `is_keeper`, `keeper_salary`, and `surplus_m` columns; emits
   `cli_inform()` noting that price adjustment was handled upstream.

   **`"none"`** — adds `is_keeper`, `keeper_salary` columns; no price or surplus
   adjustment. Emits `cli_inform()`.

3. Return the `dollars` data frame with new columns appended.

---

## Why This Measure

The fundamental question in a rotisserie auction is: at what price is this player a
positive expected-value acquisition? Budget-proportional PAR allocation is the industry
standard answer — players receive a share of the available budget equal to their share
of total above-replacement talent.

Multi-method output serves a diagnostic purpose: no single valuation method dominates
empirically across all league configurations. SGP is most accurate when league history
is available and recent; z-scores and PVM are more robust when history is sparse. Large
divergences between methods signal categories where the SGP denominators and player
pool distributions disagree — most commonly SB after the 2023 structural break and SV
in thin-closer leagues. Exposing all methods in one call lets the user identify where
uncertainty is highest and bid conservatively where methods diverge.

**`budget_split` calibration.** The default `budget_split = 0.60` is a reasonable
starting point but should be validated against actual spending history. The sibling
function `calibrate_budget_split(league_history, config)` computes the empirical hitter
fraction from historical prices and returns an updated config. This is the same pattern
as `sgp_denominators()` for denominators — calibrate once from history, then pass the
updated config to all downstream calls. Users without history use the default and accept
the uncertainty.

**Keeper inflation.** In keeper leagues, dollars committed to retained below-market
players inflate the effective cost of every open-market player. `dollar_values()` handles
this via `adjust_keeper_inflation()`. The `"pool_shrink"` method requires upstream action
(filtering kept players before `replacement_level()`); `"salary_adjust"` is handled
entirely inside `dollar_values()`.

---

## Assumptions

| Assumption | Testable? | How to Test / Basis |
|-----------|-----------|---------------------|
| Linear (proportional) dollar-per-PAR allocation | No | Theoretical; auction markets exhibit non-linearity (elite premium). Industry standard accepted on practical grounds. Known to affect absolute magnitudes, not rank order. |
| `budget_split = 0.60` default | Yes | Run `calibrate_budget_split(league_history, config)` and compare to default; use observed split in production |
| $1 minimum for all rostered players | No | League convention; verify against actual league rules |
| PVM `total_pvm` sums to 1.0 | Yes | Inherited from pvm() sum-to-1 invariant; if violated, budget reconciliation fails for PVM method |
| All valuation inputs share the same rostered player pool | Yes | Verify all elements of a multi-method list have identical player rows (same join key, same count); mismatch indicates different `replacement_level()` calls were used |
| Keeper salaries are at or below raw dollar values on average | Partially | Check `inflation_mult ≥ 1.0`; values below 1.0 indicate keepers are overpriced relative to model values, which is possible but unusual |
| `budget_split` encodes the same hitter/pitcher boundary used in `pvm(cat_pct = "auto")` | Yes | Verify `config$budget_split` is the same value used inside pvm(); if pvm was called with `cat_pct = "auto"`, it reads from config — consistent by construction |

---

## Interface

```r
dollar_values(
  valuation,
  config,
  keepers     = NULL,
  include_cat = FALSE,
  pivot       = FALSE
)
```

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `valuation` | par/zar/pvm output, or list | Yes | Single output or named/unnamed list. Named list names become method labels. Unnamed list uses positional labels (A, B, C) with `cli_warn()`. Each element must have `attr(..., "anchor") = "replacement"`. |
| `config` | league_config | Yes | Must include `budget`, `n_teams`, `budget_split`, `categories`. `keeper` field consulted when `keepers` is non-NULL. |
| `keepers` | data.frame | No | One row per retained player. Must include a player identity column matching the column used in the valuation output, and a salary column. Column names controlled by `config$keeper$keeper_col` and `config$keeper$salary_col`. `NULL` = no keeper adjustment. |
| `include_cat` | logical | No | Default `FALSE`. When `TRUE`, include per-category dollar attribution columns (`dollars_[label]_[cat]`). |
| `pivot` | logical | No | Default `FALSE`. When `TRUE`, return long format with a `method` column instead of one `dollars_[label]` column per method. |

**Note:** `budget_split` is a new field being added to `league_config` (this spec
introduces it). Default `0.60`. Use `calibrate_budget_split(league_history, config)` to
derive from observed spending history.

**Outputs:**

Returns a data frame with one row per player (wide, default) or one row per player ×
method (long, `pivot = TRUE`).

| Column | Present when | Description |
|--------|-------------|-------------|
| `dollars_[label]` | Always | Raw dollar value — proportional allocation without keeper adjustment |
| `dollars_[label]_[cat]` | `include_cat = TRUE` | Per-category dollar attribution; sums to `dollars_[label]` |
| `dollars_[label]_adj` | `keepers` non-NULL | Inflation-adjusted dollar value for non-kept players; equals `dollars_[label]` for kept players |
| `is_keeper` | `keepers` non-NULL | Logical; `TRUE` if player appears in `keepers` |
| `keeper_salary` | `keepers` non-NULL | Numeric; keeper contract price; `NA` for non-keepers |
| `surplus_[label]` | `keepers` non-NULL | `dollars_[label] - keeper_salary` for keepers; `NA` for non-keepers |

```r
attr(result, "total_budget") = config$n_teams * config$budget
attr(result, "budget_split") = config$budget_split
attr(result, "methods")      = character vector of method labels used
```

---

## Decision This Informs

- **Primary use:** Set upper-bound bid prices for auction draft; a player acquired below
  `dollars_[label]` (or `dollars_[label]_adj` in keeper leagues) represents positive
  expected value
- **Consumer:** User drafting manually; automated bid-targeting model; league valuation
  reports; keeper surplus analysis
- **How consumed:** Bid at or below `dollars_[label]_adj` for positive expected value.
  Use multi-method output to identify players where methods agree (high confidence) vs.
  diverge (higher uncertainty, warrant conservative bids). Use `surplus_[label]` to rank
  keeper retention decisions.
- **Sensitivity:** A 10% error in replacement level propagates to a ~10% shift in all
  dollar values. Most sensitive for players near the replacement boundary (small PAR/ZAR/PVM).
  Hitter/pitcher split errors shift entire positional pools together. Keeper inflation
  multiplier errors are most consequential in heavily-kept leagues where many high-value
  players are off-market.

---

## Dependencies

**Upstream:**
- `par()` output: `total_par` and `par_[cat]` columns; `attr(result, "units") = "sgp"`
- `zar()` output: `total_zar` and `zar_[cat]` columns; `attr(result, "units") = "zscore"`
- `pvm()` output: `total_pvm` and `pvm_[cat]` columns; `attr(result, "units") = "budget_fraction"`; `attr(result, "cat_pct")` required when `include_cat = TRUE`
- `league_config`: `budget`, `n_teams`, `budget_split` (new field), `categories`, `keeper`
- `keepers` data frame (optional): player identity + salary

**Downstream:**
- User bid decisions and auction draft preparation
- Keeper surplus rankings: `surplus_[label]` drives keep/cut decisions
- League valuation reports

**Sibling functions:**
- `calibrate_budget_split(league_history, config)`: derives `budget_split` from observed
  spending history; returns updated config. Planned utility — same pattern as
  `sgp_denominators()`. Call once before `dollar_values()` when history is available.
- `adjust_keeper_inflation(dollars, keepers, config)`: exported utility called internally
  when `keepers` is non-NULL; can be called independently to re-apply inflation adjustment
  on already-computed dollar values.
- `par()`, `zar()`, `pvm()`: the three upstream valuation methods consumed by this function.

---

## Error Handling

| Condition | Handler | Error Class |
|-----------|---------|-------------|
| Any valuation element has `attr(..., "anchor") != "replacement"` | `cli_abort()` | `rotostats_error_invalid_anchor` |
| Any valuation element has unrecognized `units` value | `cli_abort()` | `rotostats_error_invalid_valuation_units` |
| `config` missing `budget`, `n_teams`, or `budget_split` | `cli_abort()` | `rotostats_error_missing_config_field` |
| `config$budget_split` not in (0, 1) | `cli_abort()` | `rotostats_error_invalid_budget_split` |
| `alloc_h ≤ 0` or `alloc_p ≤ 0` after $1 minimums | `cli_abort()` | `rotostats_error_negative_allocatable_budget` |
| `sum(val[hitters]) = 0` or `sum(val[pitchers]) = 0` for SGP or z-score | `cli_abort()` | `rotostats_error_zero_pool` |
| `keepers` non-NULL but `config$keeper = FALSE` | `cli_abort()` | `rotostats_error_keeper_config_missing` |
| `keepers` missing player identity or salary column | `cli_abort()` | `rotostats_error_missing_keeper_columns` |
| Player in `keepers` not found in `valuation` output | `cli_warn()` (always), names unmatched players | `rotostats_warning_keeper_player_not_found` |
| `inflation_mult < 1.0` (keeper salaries exceed model value) | `cli_warn()` (always) | `rotostats_warning_negative_inflation` |
| Unnamed list supplied | `cli_warn()` (always) | `rotostats_warning_unnamed_valuation_list` |
| `\|sum(dollars_m) - total_budget\| > 1` for SGP or z-score | `cli_warn()` (always) | `rotostats_warning_budget_reconciliation` |

_All classes must be registered in `plans/error-messages.md` before implementation._

---

## Known Validity Threats

### Conceptual (Q1)

**1. Linear allocation is a known approximation.**
Proportional PAR allocation produces correctly ordered rankings but imprecise absolute
dollar levels. Elite players in real auctions command a premium above their proportional
PAR share; replacement-adjacent players sell below proportional value. This does not
affect the sign of expected value, only the magnitude.

**2. `budget_split` default is unvalidated.**
The default `0.60` reflects a reasonable prior, not an empirical estimate for any
specific league. If the league's actual spending history shows a different split,
the default will systematically misprice all pitchers relative to all hitters. Use
`calibrate_budget_split()` when league history is available.

**3. PVM budget reconciliation depends on pvm() sum-to-1 invariant.**
`sum(total_pvm[j]) = 1.0` must hold for the PVM budget to reconcile. Any violation in
`pvm()` (floating-point accumulation, sub-replacement handling edge cases) propagates
directly to `sum(dollars_pvm) ≠ total_budget`. The pvm() `rotostats_warning_pvm_sum`
guard is the upstream defense; `dollar_values()` adds `rotostats_warning_budget_reconciliation`
as a downstream catch.

**4. Multi-method player pool alignment.**
When a named list of valuations is supplied, all elements must represent the same set of
rostered players in the same order. If the user passed different `replacement_level()` objects
to `par()` and `zar()`, the pools may differ — producing misaligned rows and incorrect
dollar values. `dollar_values()` checks that all list elements have the same number of rows
and the same player identity column values, but does not verify that the underlying
replacement objects are identical.

**5. `"pool_shrink"` keeper handling depends on upstream user action.**
When `config$keeper$method = "pool_shrink"`, `adjust_keeper_inflation()` adds surplus
columns but does not adjust prices. The actual inflation effect only materializes if the
user correctly excluded kept players from the projections before calling
`replacement_level()`. If the user calls `dollar_values(keepers = keepers_df, config = config)`
without having shrunk the pool upstream, `pool_shrink` silently produces unadjusted values.
`adjust_keeper_inflation()` emits `cli_inform()` documenting this, but cannot verify that
the upstream pool was correctly filtered.

### Statistical (Q2)

_Pending — fill in after code audit of `R/dollar_values.R` and `R/adjust_keeper_inflation.R`._

Key areas to audit:
- Budget reconciliation for SGP and z-score: verify floating-point accumulation stays within tolerance
- Hitter/pitcher group assignment: verify that pitchers (SP and RP) are correctly separated from hitters in the proportional allocation step
- PVM `cat_pct` extraction: verify `attr(pvm_output, "cat_pct")` is correctly read for per-category attribution

### Decision (Q3)

_Pending — fill in after validation harness results._

---

## Validation Approach

### Runtime checks

- **Budget reconciliation:** `sum(dollars_[label])` across all players must equal
  `total_budget` within $1 tolerance for all methods. For PVM this holds by construction
  (sum-to-1 invariant from pvm()); for SGP and z-score it must be verified at runtime.
  `rotostats_warning_budget_reconciliation` fires on violation.

- **Per-category attribution sum:** When `include_cat = TRUE`, for each player `i`,
  `sum_c(dollars_[label]_[cat][i])` must equal `dollars_[label][i]` within floating-point
  tolerance. Assert this in unit tests with synthetic data.

- **Negative allocatable budget guard:** With a misconfigured `budget_split` (e.g., 0.99)
  and a large roster, `alloc_h` or `alloc_p` becomes negative before the $1 minimums are
  subtracted. Assert that `rotostats_error_negative_allocatable_budget` fires in this
  scenario.

- **Unnamed list warning:** Passing an unnamed list must emit
  `rotostats_warning_unnamed_valuation_list`. Assert in unit tests.

- **Keeper inflation multiplier:** When all keepers have salary = 0, `inflation_mult`
  should equal 1.0 (no inflation). Assert with synthetic data.

### Manual diagnostics

Run once per projection vintage during Q3 validation.

- **Top-player sanity:** The top 5 players by `dollars_[label]` should be recognizable
  elite players in the projection vintage. Any non-elite player in the top 5 warrants
  investigation of pool definition or replacement-level calibration.

- **Method rank correlation:** Spearman ρ between `dollars_sgp` and `dollars_zscore`
  rankings should exceed 0.85 for non-SB categories. Larger divergence for SB is expected
  after the 2023 structural break and should be documented, not treated as a bug.
  Divergence between `dollars_pvm` and `dollars_sgp` greater than 0.15 in Spearman ρ
  indicates a category where the pool distribution and historical standings movements
  disagree materially.

- **Historical price correlation:** When `league_history$prices` is available, Spearman
  ρ between `dollars_[label]` and actual auction prices should exceed 0.70. Lower
  correlation indicates a calibration problem in denominators, replacement level, or
  `budget_split`.

- **Hitter/pitcher split validation:** Compare `sum(dollars_[label])` for hitters vs.
  pitchers against `config$budget_split`. Divergence greater than 5 percentage points
  from the configured split indicates a bug in the group allocation logic.

- **Keeper surplus sanity:** The top 5 players by `surplus_[label]` should be
  recognizable elite players retained well below market value. A marginal player with
  high surplus warrants investigation of the keeper salary data or replacement level.

- **`calibrate_budget_split()` comparison:** Run `dollar_values()` with the default
  `budget_split` and with the calibrated value from `calibrate_budget_split()`. Compare
  rank correlation for pitchers vs. hitters. If Spearman ρ between the two pitcher
  rankings is below 0.95, the default `budget_split` is materially wrong for this league
  and the calibrated value should be used.
