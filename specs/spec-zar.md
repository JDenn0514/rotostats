# Metric Spec: Z-Scores Above Replacement (`zar()`)

> **Status:** Draft · 2026-04-16
> **Q1 Conceptual:** Complete · **Q2 Statistical:** Pending code audit · **Q3 Decision:** Pending validation

---

## Purpose

Compute per-player z-scores above the replacement level using the within-position stat
distribution as the normalizing factor. No external league history required. Primary use
case is users without historical SGP denominators who need player rankings or auction
dollar values anchored to the free-agent baseline.

---

## Surfaces

**Reads (builder, simulator, tester may read):**
- R/zaa.R (zar() calls zaa() internally)
- R/replacement.R (zar() takes replacement_level() output)
- R/dollar_values.R — **not a read surface.** Listed elsewhere only as a downstream consumer; `zar()` emits attributes (`units`, `anchor`) that `dollar_values()` reads, but the reverse direction is not taken.
- R/value_plus.R — **not a read surface.** Planned downstream consumer; file does not exist yet and `zar()` does not depend on it.

**Writes — builder:**
- R/zar.R

**Writes — simulator:**
- none

**Writes — tester:**
- tests/testthat/test-zar.R

**Writes — scriber:**
- R/zar.R roxygen, man/zar.Rd, NEWS.md, ARCHITECTURE.md

**Frozen surfaces (NO teammate may modify):**
- R/zaa.R (must be stable; zar runs must not reach into the sibling)
- R/replacement.R
- R/sgp.R
- R/par.R
- R/dollar_values.R — **frozen for the `zar()` scope.** Any modification to the consumer is out of scope; changes must land via the `dollar_values()` feature branch.
- R/value_plus.R — **frozen for the `zar()` scope.** File is planned but not yet present; if it is added during this run by another teammate, it must not be modified here.

---

## Formal Definition

`zar(replacement, pitcher_pool = "combined", hitter_pool = "positional", category_weight = NULL, weight_method = "none", ...)`

`zar()` calls `zaa()` internally. It is not a separate normalization implementation —
it is `zaa()` plus a replacement subtraction step. All normalization logic lives in
`zaa()`; `zar()` owns only the replacement anchor.

**Attribute extraction:** `zar()` extracts `projections` and `config` from
`attr(replacement, "projections")` and `attr(replacement, "config")` at call
time. If either attribute is absent, `zar()` aborts with
`rotostats_error_missing_replacement_attrs`. The `replacement` object must be
produced by `replacement_level()`.

**Step 1 — Compute within-position z-scores:**

Call `zaa(replacement = replacement, pitcher_pool = pitcher_pool, hitter_pool = hitter_pool, category_weight = category_weight, weight_method = weight_method, ...)`.
(Projections and config are extracted from the `replacement` object automatically — no `stats` argument is passed.)

The `replacement`
object restricts the player pool to rostered players only — fringe players below the
replacement boundary are excluded from the within-position mean and SD computation.
All `zaa()` behavior (IP/AB weighting, ERA/WHIP negation, `pitcher_pool` grouping,
`category_weight` application) applies here without modification.

**`stat_units` guard:** Enforced in `zaa()` — see `spec-zaa.md`. Inherited
by `zar()` by delegation.

**Step 2 — Identify the replacement player per position:**

The replacement player at each position is identified from the `replacement` object
returned by `replacement_level()`. Each player in the pool has exactly one valuation
position, resolved upstream by `replacement_level()` via `position_assignments` (default
`multi_pos = "highest_par"`). `zar()` performs no multi-position resolution — it uses
`position_assignments` as a lookup key to determine which position's replacement baseline
to subtract for each player. The replacement stat line returned by `replacement_level()`
is a constructed band average — it is not a real player row and does not appear in the
`zaa()` output. Its per-category z-scores are computed by applying the per-category mean
and SD returned by `zaa()` as output attributes to the band-average stat line directly,
including volume weighting for rate stats (IP-weighted for ERA/WHIP, AB-weighted for AVG)
using the band average's actual IP/AB totals. These replacement z-scores serve as the
category-level baseline for the subtraction in Step 3.

**SP/RP replacement baseline:** SP and RP always use separate replacement baselines,
regardless of the `pitcher_pool` parameter. `pitcher_pool` controls the z-score
normalization pool in `zaa()` (i.e., whether SP and RP share a common mean/SD for
counting stats); it does not affect replacement player identification, which is always
per-role. When `pitcher_pool = "combined"`, counting stat z-scores are normalized against
the combined pitcher distribution but the replacement subtraction still uses the SP
replacement line for starters and the RP replacement line for relievers.

**Step 3 — Subtract replacement-level z-score per category:**

```
zar[i, c] = zaa[i, c] - zaa[replacement_pos, c]
```

Where `zaa[replacement_pos, c]` is the z-score of the replacement band-average stat line
at position `pos` for category `c`, computed by applying the distribution parameters
(per-category mean and SD) from the `zaa()` output attributes to the band-average stat
line. Real-player z-scores appear in the `zaa()` output directly. Both are computed from
the same distribution — derived once from the rostered player pool, never recomputed.

**Step 4 — Sum across all scored categories:**

```
total_zar[i] = sum(zar[i, c] for all scored categories c)
```

By construction, the replacement player at each position has `total_zar ≈ 0`.

`total_zar` is a direct unweighted sum across all scored categories. It is meaningful
within a fixed league category set but is not comparable across leagues with different
category counts: a 6x6 league's `total_zar` values will be systematically larger than
the same players' values in a 5x5 league because an additional category contributes to
the sum. Use `total_zar` only to rank players within the same league configuration.

**Relationship to `par()`:**

`zar()` and `par()` (via `sgp(replacement = ...)`) answer the same question — talent
above the free-agent baseline — using different normalizing units. `par()` uses SGP
denominators calibrated from historical league standings; `zar()` uses the
within-position standard deviation of the player pool. Use `par()` when league history
is available; use `zar()` when it is not.

**Relationship to `zaa()`:**

`zar()` and `zaa()` are siblings, not alternatives. `zaa()` anchors to the position
average (useful for scarcity analysis and relative ranking); `zar()` anchors to the
replacement player (useful for auction pricing and draft ranking). `zar()` calls
`zaa()` internally — it does not duplicate the normalization logic.

---

## Why This Measure

The replacement player is the marginal rostered player — the worst player a team would
deliberately start. Any player below replacement is freely available on waivers; any
player above replacement contributes positive value worth paying for at auction.
Anchoring to replacement rather than the mean places dollar-value-zero at the correct
baseline: a player exactly at replacement should cost $1 at auction, not $0.

`zar()` is the z-score path to this baseline. It uses no external data beyond the player
pool and league configuration — no historical standings required. The tradeoff relative
to `par()` is calibration: SGP denominators reflect how much the standings needle
actually moves in a specific league; z-scores reflect how much spread exists in the
player pool. In a league with unusual category dynamics (saves-heavy, HR-poor), `par()`
will be better calibrated to actual league outcomes. When that history is unavailable
or unreliable, `zar()` is the robust fallback.

---

## Assumptions

| Assumption | Testable? | How to Test / Basis |
|-----------|-----------|---------------------|
| `zar()` delegates all normalization to `zaa()` | Yes | Per-category `zar_[cat]` must equal `zaa_[cat]` minus the replacement player's `zaa_[cat]` — automatable as a unit test |
| Replacement player is identified by `replacement_level()` | Yes | Replacement boundary player at each position should have `total_zar ≈ 0` |
| Every player has exactly one valuation position, resolved by `replacement_level()` before `zar()` runs | Yes | Verify that `position_assignments` in the `replacement` object is present and complete; `zar()` should abort if it is missing |
| SP and RP use separate replacement baselines regardless of `pitcher_pool` | Yes | Verify that `zaa[replacement_pos, c]` uses the SP replacement line for starters and the RP replacement line for relievers — even when `pitcher_pool = "combined"` |
| The distribution is computed once from real rostered players; the replacement band-average z-score is derived by applying stored distribution parameters, not by including a synthetic row | Yes | Verify `zaa()` is called once on real players only; verify the replacement band-average stat line is scored against `zaa()` output attributes rather than passed as an input row |
| `replacement` carries `stat_units = "raw_projected"` | Yes | Guard enforced in `zaa()`; `zar()` inherits by delegation. Violation → `rotostats_error_stat_units_mismatch`. Same pattern as `sgp()`. |
| Pool is restricted to rostered players | Yes | Fringe players below the replacement boundary should not appear in the player distribution |
| `total_zar` is comparable only within a fixed league category set | No | Design choice — identical to SGP's `total_sgp` (see spec-sgp.md Q1-SGP-5). A 6x6 league adds one category to the sum; values are not cross-league comparable. |
| Within-position distribution assumptions inherited from `zaa()` | Deferred | See `spec-zaa.md` — all `zaa()` assumptions apply here |
| Categories contribute equally and independently to `total_zar` | Partially | Compute pairwise category correlations; flag high correlations (e.g., HR/RBI) as a diagnostic. Accepted simplification in z-score systems. |

---

## Interface

```r
zar(
  replacement,
  include_raw     = FALSE,
  pitcher_pool    = "combined",
  hitter_pool     = "positional",
  category_weight = NULL,
  weight_method   = "none",
  ...
)
```

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `replacement` | replacement_level output | yes | Must carry `projections` and `config` as attributes. Produced by `replacement_level()`. Passing any other list aborts with `rotostats_error_missing_replacement_attrs`. |
| `include_raw` | logical | no | Default `FALSE`. When `TRUE`, include `zaa_[cat]` and `total_zaa` columns (within-position z-scores before replacement subtraction) in the output. |
| `pitcher_pool` | character | no | `"combined"` (default) \| `"split"`. Passed to the internal `zaa()` call. Controls whether SP and RP share a z-score distribution for counting stats. Does not affect replacement player identification, which is always per-role. |
| `hitter_pool` | character | no | `"positional"` (default) \| `"combined"`. Passed to the internal `zaa()` call. `"positional"` = FVARz; `"combined"` = FanGraphs aPOS-style. |
| `category_weight` | named numeric | no | Manual per-position multipliers (e.g., `c(SP = 0.8)`). Passed to the internal `zaa()` call. Overrides `weight_method`. |
| `weight_method` | character | no | `"none"` (default) \| `"linear"` \| `"sqrt"`. Passed to the internal `zaa()` call. Use `"linear"` to replicate FVARz's 0.8 SP multiplier in a standard 5-hitting / 4-pitching format. |

**Outputs:**

Returns a data frame with one row per player:

| Column | Type | Description |
|--------|------|-------------|
| `zaa_[cat]` | numeric | Per-category within-position z-score from internal `zaa()` call; one column per scored category. Included only when `include_raw = TRUE`. |
| `total_zaa` | numeric | Sum of `zaa_[cat]` across all scored categories. Included only when `include_raw = TRUE`. |
| `zar_[cat]` | numeric | Per-category z-score above replacement; one column per scored category |
| `total_zar` | numeric | Sum of `zar_[cat]` across all scored categories |

```
attr(result, "units")  = "zscore"
attr(result, "anchor") = "replacement"
```

### Parameter semantics (default vs explicit)

### Parameter: `include_raw`

**Default-path behavior (`missing(x)`):** Value defaults to `FALSE`; logical-type validation is skipped because the default is known-valid. Same rule as `zaa()` applied to parameters with known-valid defaults.

**Explicit-path behavior (user supplied):** Must be a logical scalar. TODO(planner): enumerate the error class fired on type violation — no explicit class is bound in the spec's Error Handling table.

### Parameter: `pitcher_pool`

**Default-path behavior (`missing(x)`):** Value defaults to `"combined"`; membership-check validation is skipped because the default is known-valid. Mirrors the rule enforced inside `zaa()` for the same parameter.

**Explicit-path behavior (user supplied):** Must be one of `"combined"` or `"split"`. Passed to the internal `zaa()` call. TODO(planner): enumerate the error class fired on membership violation — no explicit class is bound in the spec's Error Handling table (delegation to `zaa()` is implied but not named).

### Parameter: `hitter_pool`

**Default-path behavior (`missing(x)`):** Value defaults to `"positional"`; membership-check validation is skipped because the default is known-valid. Mirrors the rule enforced inside `zaa()` for the same parameter.

**Explicit-path behavior (user supplied):** Must be one of `"positional"` or `"combined"`. Passed to the internal `zaa()` call. TODO(planner): enumerate the error class fired on membership violation — no explicit class is bound in the spec's Error Handling table (delegation to `zaa()` is implied but not named).

### Parameter: `category_weight`

**Default-path behavior (`missing(x)` or `NULL`):** No manual override is applied; `weight_method` governs normalization. Type/shape validation is skipped because `NULL` disables the override path entirely. Same rule as `zaa()` for this parameter.

**Explicit-path behavior (user supplied):** Must be a named numeric vector (e.g., `c(SP = 0.8)`). Overrides `weight_method`. Passed to the internal `zaa()` call. TODO(planner): enumerate the error class fired on type or naming violation — no explicit class is bound in the spec's Error Handling table (delegation to `zaa()` is implied but not named).

### Parameter: `weight_method`

**Default-path behavior (`missing(x)`):** Value defaults to `"none"`; membership-check validation is skipped because the default is known-valid. No normalization is applied. Mirrors the rule enforced inside `zaa()` for the same parameter.

**Explicit-path behavior (user supplied):** Must be one of `"none"`, `"linear"`, or `"sqrt"`. Passed to the internal `zaa()` call. TODO(planner): enumerate the error class fired on membership violation — no explicit class is bound in the spec's Error Handling table (delegation to `zaa()` is implied but not named).

---

## Decision This Informs

- **Primary use:** Rank players by talent above the free-agent baseline in standard
  deviation units, for leagues where SGP denominators are unavailable. Direct input to
  `dollar_values()` for z-score-based auction pricing.
- **Consumer:** User (draft preparation, trade evaluation, waiver priority);
  `dollar_values()` (budget allocation without SGP denominators); `value_plus()`
  (planned: normalizes to a 100-baseline scale for cross-method comparison with `par()`).
- **How consumed:** Higher `total_zar` = more standard deviation talent above the
  free-agent baseline. Players with `total_zar ≤ 0` are at or below replacement — not
  worth rostering. Pass to `dollar_values()` with `method = "zscore"` for budget
  allocation.
- **Sensitivity:** Most sensitive near the replacement boundary. Small changes in the
  replacement player's `zaa` values propagate to all players' `zar` values. High-variance
  categories (SB, SV) produce the largest sensitivity — a single outlier replacement
  player in saves can shift all closers' `zar_sv` values materially.

---

## Dependencies

**Upstream:**
- `replacement_level()`: required. Identifies the replacement player at each position,
  defines the rostered pool, and resolves multi-position eligibility before `zar()` runs.
- `zaa()`: called internally. All `zaa()` upstream dependencies apply.
- Projections or historical stat data: the same data frame passed to `replacement_level()`
  should be passed here.

**Downstream:**
- `dollar_values()`: primary consumer. `zar()` output feeds directly into z-score-based
  auction dollar calculation.
- `value_plus()` (planned): normalizes `total_zar` to a 100-baseline scale for
  cross-method comparison with `par()`.
- User: direct ranking when SGP denominators are unavailable.

**Sibling functions:**
- `par()` (via `sgp(replacement = ...)`): same quantity in SGP units. Use when historical
  league data is available.
- `zaa()`: the above-average variant. Use when replacement anchoring is not needed.

---

## Error Handling

| Condition | Handler | Error Class | Trigger fixture |
|-----------|---------|-------------|-----------------|
| `replacement` lacks `projections` or `config` attributes | Abort | `rotostats_error_missing_replacement_attrs` | TS-ZAR-1 |
| `replacement` carries `stat_units != "raw_projected"` (inherited from `zaa()`) | Abort | `rotostats_error_stat_units_mismatch` | TODO(planner): bind to fixture |

Error classes are registered in `plans/error-messages.md`.

---

## Known Validity Threats

**Simulation studies:** N/A — `zar()` delegates all numerical work to `zaa()` (itself a pure algebraic transform); no Monte Carlo study is required for validation. Signal pre-check block intentionally omitted.

### Conceptual (Q1)

**1. Replacement boundary sensitivity**

By construction, the replacement player has `total_zar ≈ 0`. The "approximately" depends
on the replacement player being genuinely marginal — at the true roster boundary. If
`replacement_level()` returns a player who is not at that boundary (e.g., due to
`boundary_method` rounding or a thin positional pool), the entire `zar` scale shifts for
that position. All players' values are affected equally, but the magnitude of the shift
is most consequential near the boundary where auction pricing decisions are tightest.

**2. Multi-season historical data: SB structural break**

The 2023 shift ban and larger bases approximately doubled AL-wide SB. Pooling seasons
across this structural break distorts the SB within-position distribution — the mean and
SD will reflect a mixture of pre- and post-2023 norms, compressing pre-2023 SB totals
toward zero. For projection-based inputs this threat does not apply; projection systems
incorporate current-era SB norms and do not average across structural breaks.

**3. Validity threats inherited from `zaa()`**

Category count scale (`category_weight` auto-compute not yet implemented), league depth
sensitivity, `pitcher_pool = "combined"` conflation, and rate stat sign convention — all
documented in `spec-zaa.md` §Known Validity Threats — apply here as well.

**4. Positional scarcity mechanism**

`zar()` encodes positional scarcity through two interacting mechanisms: (1) per-position
replacement baselines — each position's boundary player is determined independently by
`replacement_level()`, so a catcher must clear a different bar than a first baseman —
and (2) the natural variation in within-position SD across positions. Positions with
compressed talent distributions (C, SS in AL-only leagues) produce smaller SDs, which
compresses `total_zar` for all players at that position relative to deep positions (OF,
1B). Being the best catcher in a shallow pool typically yields lower `total_zar` than
being the best first baseman in a deep pool because the talent spread is smaller — this
is the correct behavior under FVARz-style replacement anchoring, not a defect.

**Known limitation:** Pure FVARz-style replacement anchoring systematically undervalues
catchers relative to observed auction market prices. This is a documented property of the
methodology, addressed by `catcher_adjustment_method` in `replacement_level()` — see
`spec-replacement.md`.

If `replacement_level()` uses a global (non-positional) replacement line, both mechanisms
collapse: all positions share a single baseline and SD context, systematically undervaluing
scarce positions (C, SS) and overvaluing deep ones (OF, 1B).

### Statistical (Q2)

_Pending — fill in after code audit of `R/zar.R`_

### Decision (Q3)

_Pending — fill in after validation harness results_

---

## Validation Approach

### Runtime checks

These fire on every call or run automatically in the test harness. Each is automatable
as a unit test with fixture data.

### TS-ZAR-1 — Attribute extraction error

**Preconditions (inputs must satisfy):**
- `replacement` is a plain list (not produced by `replacement_level()`).
- `replacement` lacks at least one of `attr(., "projections")` or `attr(., "config")`.

**Target guard / behavior under test:**
- `zar()` aborts with `rotostats_error_missing_replacement_attrs` when the required attributes are absent.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_stat_units_mismatch` — must NOT fire first; this guard is enforced inside `zaa()` and is downstream of attribute extraction in `zar()`.
- `rotostats_error_multi_pos_all_unsupported` — must NOT fire first; the fixture's plain list does not carry `params$multi_pos == "all"`.
- TODO(planner): enumerate upstream guards — spec does not fully order the internal check sequence in `zar()`.

**Expected outcome:**
- Abort with condition class `"rotostats_error_missing_replacement_attrs"`.

### TS-ZAR-2 — Replacement boundary check

**Preconditions (inputs must satisfy):**
- `replacement` is a valid `replacement_level()` output with `projections`, `config`, and `stat_units = "raw_projected"` attributes intact.
- `position_assignments` is present and complete (every player has exactly one valuation position).
- `params$multi_pos` is not `"all"`.

**Target guard / behavior under test:**
- For the replacement-level player at each position, `total_zar ≈ 0` (deviations < 0.5 SD). Failure signals that the replacement line was not applied correctly (Steps 1 and 2 used different `replacement_level()` objects).

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_missing_replacement_attrs` — must NOT fire first; fixture carries valid attributes.
- `rotostats_error_stat_units_mismatch` — must NOT fire first; fixture carries `stat_units = "raw_projected"`.
- `rotostats_error_multi_pos_all_unsupported` — must NOT fire first; fixture is produced with single-assignment `multi_pos`.
- TODO(planner): enumerate upstream guards — spec does not enumerate every `zaa()` guard reached by this path.

**Expected outcome:**
- For each replacement-level player, `abs(total_zar) < 0.5`.

### TS-ZAR-3 — Consistency with `zaa()`

**Preconditions (inputs must satisfy):**
- `replacement` is a valid `replacement_level()` output.
- The same `replacement` object is used to derive both the `zaa()` output and the replacement player's z-scores.

**Target guard / behavior under test:**
- For every player `i` and category `c`, `zar[i, c] == zaa[i, c] - zaa[replacement_pos, c]`.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_missing_replacement_attrs` — must NOT fire first; fixture carries valid attributes.
- `rotostats_error_stat_units_mismatch` — must NOT fire first; fixture carries `stat_units = "raw_projected"`.
- `rotostats_error_multi_pos_all_unsupported` — must NOT fire first; fixture is produced with single-assignment `multi_pos`.
- TODO(planner): enumerate upstream guards — spec does not enumerate every `zaa()` guard reached by this path.

**Expected outcome:**
- Per-cell equality: `zar_[cat] == zaa_[cat] - zaa_[cat](replacement_pos)` within floating-point tolerance for all rows and all scored categories.

### TS-ZAR-4 — Rate stat sign check

**Preconditions (inputs must satisfy):**
- `replacement` is a valid `replacement_level()` output.
- ERA is in the scored category set and is flagged as an inverse (rate) stat.
- Fixture includes pitchers with both above- and below-mean ERA values.

**Target guard / behavior under test:**
- `sign(mean_ERA - player_ERA) == sign(zar_era)` for all pitchers (inherited from `zaa()` rate-stat sign convention).

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_missing_replacement_attrs` — must NOT fire first; fixture carries valid attributes.
- `rotostats_error_stat_units_mismatch` — must NOT fire first; fixture carries `stat_units = "raw_projected"`.
- `rotostats_error_multi_pos_all_unsupported` — must NOT fire first; fixture uses single-assignment `multi_pos`.
- TODO(planner): enumerate upstream guards — spec does not enumerate every `zaa()` guard reached by this path.

**Expected outcome:**
- For every pitcher with non-missing ERA: `sign(mean_ERA - player_ERA) == sign(zar_era)`.

### TS-ZAR-5 — Pipe-compatibility check

**Preconditions (inputs must satisfy):**
- `projections` and `config` are valid inputs to `replacement_level()`.
- The same `projections` and `config` are used in both the piped and nested call forms.

**Target guard / behavior under test:**
- `replacement_level(projections, config) |> zar()` produces output structurally identical to `zar(replacement_level(projections, config))`.

**Guards that MUST NOT fire first (non-target):**
- `rotostats_error_missing_replacement_attrs` — must NOT fire first; both call forms pass a valid `replacement_level()` output.
- `rotostats_error_stat_units_mismatch` — must NOT fire first; both call forms carry `stat_units = "raw_projected"`.
- `rotostats_error_multi_pos_all_unsupported` — must NOT fire first; `replacement_level()` default assignment is single-position.
- TODO(planner): enumerate upstream guards — spec does not enumerate every `zaa()` guard reached by this path.

**Expected outcome:**
- Structural equality of the two output data frames (same column names, same column types, same row count, same per-cell values within floating-point tolerance); attributes `units` and `anchor` equal across forms.

### Manual diagnostics

These require a real projection vintage and human judgment. Run once per vintage during Q3
validation.

- **Rank correlation with `par()`:** When both methods are available (user has SGP
  denominators), Spearman ρ between `total_zar` and `total_par` rankings should exceed
  0.85 for non-SB categories. Divergence for SB (structural break) and SV (sparse,
  high-variance) is expected — flag and document rather than suppress.
- **Directional sanity:** Top-10 players by `total_zar` should be recognizable elite
  players in the projection vintage. A non-elite player in the top 10 is a signal of
  a pool definition error or a miscoded rate stat sign.
- **Positional consistency (heuristic):** In a typical AL-only projection vintage, the
  best catcher's `total_zar` will tend to be lower than the best first baseman's
  `total_zar` because catcher talent pools are shallower and more compressed. This is
  not mathematically guaranteed — a historically dominant catcher can exceed the best
  first baseman in a strong vintage. Substantially equal `total_zar` values across all
  positions, or scarce positions (C, SS) consistently reading higher than deep ones (OF),
  are worth investigating and may indicate a global rather than per-position replacement
  line.
- **Method equivalence check:** `total_zar` under `hitter_pool = "combined"`
  should rank hitters similarly to the FanGraphs auction calculator output for
  non-SB, non-SV categories. Spearman ρ > 0.90 among hitters is a reasonable
  threshold. Divergence at catcher (scarcity encoding differs between methods)
  is expected and is not a failure signal.
