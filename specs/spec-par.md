# Metric Spec: Points Above Replacement (`par()`)

> **Status:** Draft · 2026-04-16
> **Q1 Conceptual:** Complete · **Q2 Statistical:** Pending code audit · **Q3 Decision:** Pending validation

---

## Purpose

Compute per-player PAR (Points Above Replacement) in standings-point units by converting
projected stats to SGP and subtracting the replacement-level SGP line. No external z-score
normalization required. Primary use case is users with historical SGP denominators who need
player rankings or auction dollar values anchored to the free-agent baseline.

The primary path for SGP-only output (no replacement anchor) is `sgp()` directly.

---

## Formal Definition

`par()` calls `sgp()` internally. It is not a separate SGP implementation — it is `sgp()`
plus a replacement subtraction step. All SGP conversion logic lives in `sgp()`; `par()` owns
only the replacement anchor.

**Attribute extraction:** `par()` extracts `projections` and `config` from
`attr(replacement, "projections")` and `attr(replacement, "config")` at call time. If either
attribute is absent, `par()` aborts with `rotostats_error_missing_replacement_attrs`. The
`replacement` object must be produced by `replacement_level()`.

**Step 1 — Compute SGP:**

Call `sgp(projections, denominators, rate_conversion = rate_conversion, pool_baseline = pool_baseline, league_config = config, baseline_era = baseline[["era"]], baseline_whip = baseline[["whip"]], baseline_avg = baseline[["avg"]])` using the projections and config extracted from the `replacement` object. `baseline` entries are unpacked by name when non-NULL. Returns `sgp_[cat]` columns and `total_sgp` for all players.

All `sgp()` behavior (rate stat conversion, IP/AB weighting, ERA/WHIP negation) applies here
without modification.

**Step 2 — Compute replacement SGP per category:**

Apply the same SGP conversion to the replacement stat line from `replacement_level()`. The
replacement stat line is a constructed band average — it does not appear as a real player
row. For counting stats: `replacement_sgp[c] = replacement_stat[pos, c] / denominator[c]`.
For rate stats: apply the same `rate_conversion` method used in Step 1, using the band
average's actual IP/AB totals. The result is a named numeric vector of replacement-level
SGP by category and position.

**SP/RP replacement baseline:** SP and RP always use separate replacement baselines,
regardless of internal `sgp()` rate stat handling.

**Step 3 — Subtract replacement SGP per player:**

```
par[i, c] = sgp[i, c] - replacement_sgp[position_of_i, c]
total_par[i] = sum(par[i, c] for all scored categories c)
```

Where `position_of_i` is each player's valuation position, resolved upstream by
`replacement_level()` via `position_assignments`. `par()` performs no multi-position
resolution.

By construction, the replacement player at each position has `total_par ≈ 0`.

`total_par` is a direct unweighted sum across all scored categories. It is meaningful within
a fixed league category set but is not comparable across leagues with different category
counts: a 6x6 league's `total_par` values will be systematically larger than the same
players' values in a 5x5 league because an additional category contributes to the sum. Use
`total_par` only to rank players within the same league configuration.

**Replacement band check:** After computing `total_par`, the median `total_par` of the ±K
symmetric band around the roster boundary (K from `replacement$params$band_width`) should
be within `boundary_threshold` (default 1.0) of 0. Emits `cli_warn()` with the observed
median and direction when violated. See Validation Approach for interpretation.

**Re-apply use case:** To experiment with a different replacement level on existing data,
call `par()` with a new `replacement` object. Since `sgp()` is called internally on each
invocation, caching is unnecessary.

**Relationship to `zar()`:**

`par()` and `zar()` answer the same question — talent above the free-agent baseline — using
different normalizing units. `par()` uses SGP denominators calibrated from historical league
standings; `zar()` uses the within-position standard deviation of the player pool. Use
`par()` when league history is available; use `zar()` when it is not.

**Relationship to `sgp()`:**

`par()` and `sgp()` are siblings, not alternatives. `sgp()` anchors to zero (no replacement
subtraction — useful for raw production measurement and rate stat diagnostics); `par()` anchors
to the replacement player (useful for auction pricing and draft ranking). `par()` calls `sgp()`
internally — it does not duplicate the conversion logic.

---

## Why This Measure

The replacement player is the marginal rostered player — the worst player a team would
deliberately start. Any player below replacement is freely available on waivers; any player
above replacement contributes positive value worth paying for at auction. Anchoring to
replacement rather than zero places dollar-value-zero at the correct baseline: a player
exactly at replacement should cost $1 at auction, not $0.

`par()` is the SGP path to this baseline. It requires historical SGP denominators calibrated
to your league but rewards that investment with directly interpretable output: a `total_par`
of 5.0 means the player contributes approximately five standings places of value above
replacement. The tradeoff relative to `zar()` is data availability: SGP denominators must be
computed from at least 3–5 seasons of historical standings data. When that history is
unavailable or unreliable, `zar()` is the robust fallback.

---

## Assumptions

| Assumption | Testable? | How to Test / Basis |
|-----------|-----------|---------------------|
| Player pool comes from `replacement_level()` | Yes | Replacement band check: median `total_par` of the ±K band should be within `boundary_threshold` of 0 (see Validation Approach) |
| `par()` delegates all SGP conversion to `sgp()` | Yes | Per-category `par_[cat]` must equal `sgp_[cat]` minus the replacement-level SGP for that category — automatable as a unit test |
| Replacement player is identified by `replacement_level()` | Yes | Replacement boundary player at each position should have `total_par ≈ 0` |
| Every player has exactly one valuation position, resolved by `replacement_level()` before `par()` runs | Yes | Verify that `position_assignments` in the `replacement` object is present and complete; `par()` should abort if `projections` or `config` attribute is missing |
| SP and RP use separate replacement baselines regardless of rate stat handling inside `sgp()` | Yes | Verify that `replacement_sgp[pos, c]` uses the SP replacement line for starters and the RP replacement line for relievers |
| Rate stat conversion is handled entirely by `sgp()` before the replacement subtraction | Yes | `par()` receives pre-converted SGP values from Step 1; rate stat logic lives in `sgp()` |
| SGP denominators are calibrated to this league's historical data | Yes | Denominator validity is a `sgp()` concern; treated as given input here |
| `replacement` carries `stat_units = "raw_projected"` | Yes | Guard enforced in `sgp()`; `par()` inherits by delegation. Violation → `rotostats_error_stat_units_mismatch`. Same pattern as `zar()`. |
| `total_par` is comparable only within a fixed league category set | No | Design choice — identical to SGP's `total_sgp` (see spec-sgp.md Q1-SGP-5). A 6x6 league adds one category to the sum; values are not cross-league comparable. |
| Categories contribute equally and independently to `total_par` | Partially | Compute pairwise category correlations in `sgp()` output; flag high correlations (e.g., HR/RBI) as a diagnostic. Accepted simplification in SGP-based systems. |

---

## Interface

```r
par(
  replacement,
  denominators,
  include_raw        = FALSE,
  boundary_threshold = 1.0,
  rate_conversion    = "blended_pool",
  pool_baseline      = "projection_pool",
  baseline           = NULL
)
```

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `replacement` | replacement_level output | yes | Must carry `projections` and `config` as attributes. Produced by `replacement_level()`. Passing any other object aborts with `rotostats_error_missing_replacement_attrs`. |
| `denominators` | named numeric | yes | SGP denominators by category. Produced by `sgp_denominators()`. Names must cover all scored categories. |
| `include_raw` | logical | no | Default `FALSE`. When `TRUE`, include `sgp_[cat]` and `total_sgp` columns (raw SGP before replacement subtraction) in the output. |
| `boundary_threshold` | numeric | no | Warn when the median `total_par` of the replacement band exceeds this value (default `1.0`, one standings place). |
| `rate_conversion` | character | no | `"blended_pool"` (default) \| `"fixed_baseline"`. Passed to the internal `sgp()` call. Controls how ERA, WHIP, and AVG are converted to standings-point units. |
| `pool_baseline` | character | no | `"projection_pool"` (default). Passed to the internal `sgp()` call. |
| `baseline` | named numeric | no | Per-category baseline overrides for rate stat conversion. Names must match scored rate stat categories (e.g., `c(era = 3.80, whip = 1.15, avg = .265)`). Entries are unpacked by name when passing to `sgp()`. Supports any rate stat present in the league configuration. |

**Outputs:**

Returns a data frame with one row per player:

| Column | Type | Description |
|--------|------|-------------|
| `sgp_[cat]` | numeric | Raw SGP per category from Step 1; one column per scored category. Included only when `include_raw = TRUE`. |
| `par_[cat]` | numeric | SGP above replacement per category from Step 3; one column per scored category |
| `total_sgp` | numeric | Sum of `sgp_[cat]` across all scored categories. Included only when `include_raw = TRUE`. |
| `total_par` | numeric | Sum of `par_[cat]` across all scored categories |

```
attr(result, "replacement_sgp") = named numeric vector of replacement-level SGP by category
attr(result, "units")           = "sgp"
attr(result, "anchor")          = "replacement"
```

---

## Error Handling

| Condition | Handler | Class |
|-----------|---------|-------|
| `replacement` missing `projections` or `config` attribute | `cli_abort()` | `rotostats_error_missing_replacement_attrs` |
| `names(denominators)` don't cover all scored categories | `cli_abort()`, names missing categories | TBD |
| Replacement band median `total_par` exceeds `boundary_threshold` | `cli_warn()`, reports observed median and direction | TBD |
| Any error propagated from internal `sgp()` call | Re-raised as-is | (from sgp()) |

Cross-reference `plans/error-messages.md` for class name registry.

---

## Decision This Informs

- **Primary use:** Rank players by talent above the free-agent baseline in standings-point
  units, for leagues where SGP denominators are available. Direct input to `dollar_values()`
  for SGP-based auction pricing.
- **Consumer:** User (draft preparation, trade evaluation, waiver priority);
  `dollar_values()` (budget allocation with SGP denominators); `value_plus()` (planned:
  normalizes `total_par` to a 100-baseline scale for cross-method comparison with `zar()`).
- **How consumed:** Higher `total_par` = more standings-point talent above the free-agent
  baseline. Players with `total_par ≤ 0` are at or below replacement — not worth rostering.
  Pass to `dollar_values()` with `method = "sgp"` for budget allocation.
- **Sensitivity:** Most sensitive near the replacement boundary. Small changes in the
  replacement-level SGP propagate to all players' `par` values. High-variance categories
  (SB, SV) produce the largest sensitivity — a single outlier replacement player in saves
  can shift all closers' `par_sv` values materially.

---

## Dependencies

**Upstream:**
- `replacement_level()`: required. Provides the `replacement` object — replacement stat
  lines by position, `position_assignments`, and `projections` attribute. Must have
  `attr(replacement, "stat_units") == "raw_projected"`.
- `sgp_denominators()`: provides `denominators`. Required.
- `sgp()`: called internally. All `sgp()` upstream requirements apply.

**Downstream:**
- `dollar_values()`: primary consumer of `par_[cat]` and `total_par` for budget allocation.
- User: direct ranking and trade/waiver analysis.
- `value_plus()` (planned): normalizes `total_par` to a 100-baseline scale for cross-method
  comparison with `zar()`.

**Sibling functions:**
- `zar()`: same quantity in standard deviation units; use when historical league data is
  unavailable.
- `sgp()`: the raw SGP step called internally; use directly when replacement anchoring is
  not needed.
- `pvm()`: per-category pool shares as an alternative valuation path.

---

## Known Validity Threats

### Conceptual (Q1)

**1. Replacement boundary sensitivity**

By construction, the replacement player has `total_par ≈ 0`. The "approximately" depends on
the replacement player being genuinely marginal — at the true roster boundary. If
`replacement_level()` returns a player who is not at that boundary (e.g., due to
`boundary_method` rounding or a thin positional pool), the entire `par` scale shifts for
that position. All players' values are affected equally, but the magnitude of the shift is
most consequential near the boundary where auction pricing decisions are tightest.

**2. Denominator calibration period**

SGP denominators must be computed from historical league standings data. Using fewer than
3–5 seasons increases denominator variance, particularly for low-frequency categories (SV,
SB). A single outlier season (a saves-heavy year, a stolen-base resurgence) can bias the
denominator and distort all players' `par_sv` or `par_sb` values. Validate denominators
against multi-season averages before relying on them for auction pricing.

**3. Multi-season historical data: SB structural break**

The 2023 shift ban and larger bases approximately doubled AL-wide SB. Pooling seasons across
this structural break distorts the SB denominator — it will reflect a mixture of pre- and
post-2023 norms, depressing the value of stolen bases relative to the current environment.
For projection-based inputs, use post-2023 denominators only.

**4. Positional scarcity inheritance**

`par()` inherits positional adjustments from `replacement_level()`. If `replacement_level()`
uses a global (non-positional) replacement line, PAR will systematically undervalue scarce
positions (C, SS) and overvalue deep ones (OF, 1B). This is a `replacement_level()` design
choice that propagates directly into PAR.

### Statistical (Q2)

_Pending — fill in after code audit of `R/par.R`_

### Decision (Q3)

_Pending — fill in after validation harness results_

---

## Validation Approach

**Runtime checks** (automatable unit tests; fire on every call or in the test harness):

- **Replacement band check:** The median `total_par` of the ±K symmetric band around the
  roster boundary (K from `replacement$params$band_width`) should be within
  `boundary_threshold` of 0. `par()` emits `cli_warn()` with the observed median and
  direction when this is violated. Default `boundary_threshold = 1.0` (one standings place).
  Do not adjust `boundary_threshold` to silence the warning — the fix lives upstream in
  `replacement_level()`.
  - Median above `+boundary_threshold`: replacement level is too conservative (all PAR
    values are inflated). Check that `n_teams` and roster slot counts in `league_config`
    match your league; consider increasing roster depth in `replacement_level()`.
  - Median below `-boundary_threshold`: replacement level is too aggressive (values are
    deflated). Check `n_teams` and roster slot counts in `league_config`.
- **Attribute extraction error:** `par()` must abort with
  `rotostats_error_missing_replacement_attrs` when passed a plain list lacking the
  `projections` attribute.
- **Consistency with `sgp()`:** For every player and category, `par_[cat]` must equal
  `sgp_[cat]` minus the replacement-level SGP for that category.
- **Rate stat sign check:** Inherited from `sgp()`. Assert
  `sign(mean_ERA - player_ERA) == sign(par_era)` for all pitchers.
- **Pipe-compatibility check:** `replacement_level(projections, config) |> par(denominators)`
  must produce output structurally identical to
  `par(replacement_level(projections, config), denominators)`.

**Manual diagnostics** (require a real projection vintage and human judgment):

- **Directional sanity:** The top-10 players by `total_par` should be recognizable elite
  players in the projection vintage. Inspect any non-elite player in the top 10 as a
  potential valuation error.
- **Positional scarcity compression:** At scarce positions (C, SS), the spread in
  `total_par` across rostered players should be narrower than at deep positions (OF, 1B),
  reflecting fewer differentiated slots. A wide, flat distribution at a scarce position
  suggests the replacement level is set too low.
- **Rank correlation with `zar()`:** When both methods are available (user has SGP
  denominators), Spearman ρ between `total_par` and `total_zar` rankings should exceed
  0.85 for non-SB categories. Divergence for SB (structural break) and SV (sparse,
  high-variance) is expected — flag and document rather than suppress.
