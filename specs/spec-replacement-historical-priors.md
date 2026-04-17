# Feature Spec: `seed_method = "historical_priors"` in `replacement_level()`

> **Status:** Draft · 2026-04-17
> **Parent spec:** `specs/spec-replacement.md`
> **Scope:** Docs-only (design spec for a future implementation run). No R code, no tests, no simulation-harness changes.

---

## Purpose

When `seed_method = "historical_priors"`, `replacement_level()` bootstraps its pass-1
position assignments by computing per-position replacement-level z-scores directly from
multi-season historical auction data (`league_history$prices`) rather than from the greedy
positional hierarchy used by `seed_method = "hierarchy"`. The historical prior is derived as
the multi-season analog of `replacement_from_prices()`: for each position, the trimmed pool
of $1 players is identified across all retained history years, their end-of-season stat lines
are aggregated, and the resulting per-position stat vector is converted to a z-score within
the `pool_size + K` pool from the parent spec. These z-scores seed pass-1 position
assignments.

The motivation is to reduce first-pass assignment churn and improve the quality of the
initial replacement-level estimate at thin positions (C, SS) where single-season
projection-derived boundaries are noisy. When several years of history exist, the
multi-season trimmed mean is a more stable starting point than a greedy scarcity ordering
whose implied replacement stats are approximate. The number of passes to full convergence
is dominated by multi-position reassignment churn, not by z-score seed quality; even so, a
better seed reduces stat-line volatility during early passes in thin-pool leagues and
shortens the burn-in period for iterative valuations.

On pass 2 and beyond, `replacement_level()` proceeds exactly as under
`seed_method = "hierarchy"` — the historical prior affects only the pass-1 bootstrap seed.

---

## Formal Definition

### Inputs required from `league_history`

`league_history` must be a `league_history` object constructed via `league_history()`. When
`seed_method = "historical_priors"`, the following slots are load-bearing:

**`$prices` (PRIMARY — required)**

The historical prior is derived entirely from `$prices`. Required columns (from
`plans/implementation/league-history-impl.md`):

| Column | Type | Required for this feature | Notes |
|--------|------|--------------------------|-------|
| `year` | integer | yes | Used for n_teams filtering |
| `player_name` | character | yes | Fallback match when `player_id` absent |
| `price` | numeric | yes | Used to identify $1 pool |
| `player_id` | character | no (preferred) | Exact match; name fallback when absent |
| `is_keeper` | logical | no | Exact keeper exclusion; `trim_method` used when absent |
| `pos_eligibility` | character | yes | Position eligibility of the player; used for per-position pool construction. Pipe-delimited: `"C"`, `"1B|3B"`, `"SP|RP"`. Same format as `projections$pos_eligibility`. |
| one column per category in `categories` | numeric | yes | End-of-season actual stats for the auction year. Column names must exactly match `config$categories`. |
| `AB` | numeric | when AVG/OBP/SLG in categories | Required for AB-weighted rate stat aggregation |
| `IP` | numeric | when ERA/WHIP/K9 etc. in categories | Required for IP-weighted rate stat aggregation |

If `$prices` is absent (i.e., `league_history` is non-NULL but `league_history$prices` is
`NULL`), abort with `rotostats_error_missing_league_history` (the existing class; see
Failure Modes). Do not invent a new error class for this case.

**`$team_season` (SECONDARY — optional for this feature)**

`$team_season` is used only for its role already established in the parent spec: the
`IP`/`AB` projection divergence check. It does **not** feed the per-position historical
prior directly.

Inferring per-year n_teams: when `$team_season` is present and `team_id` uniquely
identifies teams, the per-year team count is inferred as the number of distinct `team_id`
values per year. When `$team_season` is absent, `config$n_teams` is assumed constant
across all history years (no n_teams filter is applied, and no warning is emitted).

### Algorithm (numbered steps)

**Step 1 — n_teams filter.**

If `$team_season` is present: for each year in `$prices`, infer the team count from the
distinct `team_id` count in `$team_season` for that year. Filter `$prices` to seasons where
the inferred team count equals `config$n_teams`. If any seasons are dropped, emit
`rotostats_warning_history_n_teams_filtered` (always, not verbose-gated), naming the dropped
seasons and their team counts.

If `$team_season` is absent: skip the n_teams filter; proceed with all years in `$prices`.

**Step 2 — Minimum season count assertion.**

Count the number of distinct years remaining in the filtered `$prices`. If this count is
less than `replacement_params$historical_priors_min_seasons` (default `3L`), abort with
`rotostats_error_insufficient_history`. The error message must name:
- the observed post-filter season count,
- the required minimum (`historical_priors_min_seasons`),
- whether the shortfall was present at entry (i.e., the full `$prices` had fewer than the
  minimum before filtering) or arose from the n_teams filter.

This single error class covers both entry-time and post-filter failures. The message string
distinguishes the two cases.

**Step 3 — Stat-definition consistency check.**

For every category in `config$categories`, assert that a column of the same name is present
in the filtered `$prices` end-of-season stat columns. If any category is absent from
`$prices`, abort with `rotostats_error_stat_definition_drift`. The error message must name
the specific category and the direction of the mismatch:
- `"requested category <X> absent from historical $prices"` — the current scoring system
  uses a stat not present in the history data (e.g., league switched from AVG to OBP
  mid-history and old rows only contain AVG).
- `"historical $prices contains no usable overlap for category <X>"` — a direction where no
  rows in the filtered window provide the needed column.

Do not attempt silent substitution (e.g., substituting AVG for OBP). Abort and require the
user to resolve the schema mismatch.

**Step 4 — Per-position, per-year $1 pool identification.**

For each year `y` and each position `p`:

1. Filter `$prices` to rows where `year == y` and the player's `pos_eligibility` indicates
   eligibility at position `p` (using the same eligibility parsing logic applied to
   `projections$pos_eligibility` throughout the package).
2. Filter to `price == 1` (or `price <= 1` for leagues with $1 minimum bids — use the same
   threshold as the existing $1 calibration path in the parent spec).
3. Apply keeper/outlier exclusion using the same logic as `replacement_from_prices()` and
   the single-season $1 calibration path:
   - When `is_keeper` is present in the filtered rows: exclude `is_keeper == TRUE` rows
     exactly (no statistical trim).
   - When `is_keeper` is absent: apply `trim_method` (from the top-level argument, default
     `"iqr"`) to remove overperforming $1 players.
4. If fewer than `calibration_min_n` players remain for position `p` in year `y`, emit
   `rotostats_warning_calibration_suppressed` (the existing class) for that position-year
   combination and exclude that year from position `p`'s aggregation pool. This is
   consistent with the parent spec's calibration-suppression behavior and the note in Known
   Validity Threats §1 on calibration suppression at thin positions.
5. Compute the mean stat line for the surviving $1 players at position `p` in year `y`:
   - Counting stats: arithmetic mean.
   - AVG: `sum(H) / sum(AB)` across surviving players.
   - ERA: IP-weighted mean: `sum(ER) / sum(IP) * 9` — requires `ER` to be computable, or
     equivalently `sum(ERA_i * IP_i) / sum(IP_i)` when per-player ERA and IP are in `$prices`.
   - WHIP: IP-weighted mean: `sum(WHIP_i * IP_i) / sum(IP_i)`.
   - Other IP-denominated rate stats: IP-weighted mean using the same denominator from
     `RATE_STAT_DENOMINATORS`.
   - PA-denominated rate stats (OBP, SLG, OPS, wOBA, K%, BB%): PA-weighted mean analogous
     to AB-weighted AVG.

The internal helper `compute_positional_adjustments()` is reused for positional adjustment
logic; it is not reused for the per-position stat aggregation itself (which is novel to this
feature). The trim logic from `replacement_from_prices()` — specifically the `is_keeper`
exact exclusion and `trim_method` outlier removal — is reused via the shared internal path
in `R/replacement_internal.R` and must not be duplicated.

**Step 5 — Multi-season aggregation.**

For each position `p`, aggregate the per-year mean stat lines produced in Step 4 into a
single multi-season prior. Use the following aggregation rules:

- Counting stats: simple arithmetic mean across retained years.
- AVG: `sum(H_y) / sum(AB_y)` where `H_y` and `AB_y` are the year-level summed values
  computed in Step 4 (i.e., AB denominators are summed across years before dividing, not
  averaged as ratios).
- ERA: `sum(ERA_y * IP_y) / sum(IP_y)` where `IP_y` is the total IP for position `p`'s $1
  pool in year `y`.
- WHIP: `sum(WHIP_y * IP_y) / sum(IP_y)`.
- Other rate stats: denominator-weighted mean consistent with the weighting rule for their
  denominator type, applying the same `RATE_STAT_DENOMINATORS` lookup as the rest of the
  package.

For any position `p` where fewer than `historical_priors_min_seasons` years survived (after
Step 4 per-year calibration suppression), fall back to the `seed_method = "hierarchy"`
behavior for that position only, and emit `rotostats_warning_calibration_suppressed` for
that position. Do not abort — partial-fallback is correct behavior when, say, SS has
insufficient history but all other positions have ample data.

**Step 6 — Z-score conversion.**

Convert the per-position multi-season stat lines from Step 5 into z-scores. Z-scores are
computed within the unified hitter or pitcher pool of `pool_size + K` players, exactly as
defined in the parent spec (§"Z-score pool"). No per-position sub-pool is used.

The mean and standard deviation for z-score standardization come from the current-year
projection pool (not from `$prices`). Historical stat lines are converted to z-scores in the
current projection distribution. This ensures the historical prior is expressed in a scale
that is directly comparable to current-year z-scores, avoiding the stale-mean problem that
would arise from standardizing within the historical distribution.

**Step 7 — Return pass-1 seed.**

Return the per-position z-score vector as the pass-1 seed for position assignments. This
replaces the greedy-hierarchy seed used by `seed_method = "hierarchy"` on pass 1. The
vector is keyed by position name (same keys as `roster_slots`).

On pass 2 and beyond, `replacement_level()` proceeds identically under both seed methods:
`dollar_values()` supplies `position_assignments` and the iteration loop resolves circularity
as described in the parent spec §"Sort Key and Circularity".

---

## Interface

### Public signature — unchanged

`seed_method = "historical_priors"` is already declared in the parent spec's
`replacement_level()` signature. No new top-level arguments are added by this feature.

### New entry in `default_replacement_params`

```r
historical_priors_min_seasons = 3L   # sweep: 2:5
```

Add alongside the existing entries in `default_replacement_params`. This follows the
established pattern of `calibration_min_n`, `sp_ip_threshold`, etc. The default of `3L`
matches the minimum needed for per-position stability at typical thin positions; see
Assumptions.

### Semantics of `league_history` when `seed_method = "historical_priors"`

When `seed_method = "hierarchy"` (the default), `league_history` is optional and its
`$prices` slot feeds only the diagnostic $1 calibration cross-check. When
`seed_method = "historical_priors"`, `$prices` becomes load-bearing:

- `league_history` must be non-NULL; otherwise abort with `rotostats_error_missing_league_history`.
- `league_history$prices` must be non-NULL and satisfy the required column schema described
  above; `league_history$prices` absent (i.e., `NULL`) triggers `rotostats_error_missing_league_history`.
- `$team_season` remains optional; its absence means no n_teams filter is applied.

### Relationship to `trim_method`, `calibration_min_n`, and `replacement_from_prices()`

**`trim_method`:** Under `seed_method = "historical_priors"`, the historical prior fully
supersedes the `trim_method` / $1 calibration path for pass-1 seeding. The two paths are
not blended. `trim_method` continues to govern outlier exclusion within the historical $1
pool itself (Step 4 above) — its role shifts from "single-season seed calibration" to
"multi-season pool cleaning," but the parameter meaning is unchanged.

**`calibration_min_n`:** This parameter governs the single-season $1 calibration
cross-check that runs on the converged replacement level (not on the pass-1 seed). This
diagnostic is independent of `seed_method` and continues to run unchanged.

**`replacement_from_prices()`:** When supplied as `replacement_fn` to `dollar_values()`,
`replacement_from_prices()` is a separately-invoked function that replaces
`replacement_level()` entirely. It is not affected by `seed_method`. The two are
orthogonal: `seed_method` controls the internal bootstrapping of `replacement_level()`'s
pass-1 seed; `replacement_fn` controls which function `dollar_values()` calls. A caller
can use `replacement_level(seed_method = "historical_priors")` as the `replacement_fn`
without any conflict.

---

## Cross-check behavior

The per-season empirical $1 calibration check — the diagnostic that compares the converged
replacement level to the trimmed mean of $1 auction prices for the most recent season —
continues to run on the converged replacement level after the iteration loop completes. This
is unchanged behavior regardless of `seed_method`. The check is a diagnostic, not a
feedback path into pass-1 seeding.

When `seed_method = "historical_priors"`:
- The historical prior REPLACES the `trim_method` / $1 single-season calibration path as
  the source of the pass-1 seed. It does not merely confirm the seed; there is no blending.
- After convergence, the $1 calibration diagnostic runs as normal. A large divergence
  between the converged replacement level and the current-season $1 trimmed mean is
  reported as `rotostats_warning_calibration_suppressed` (if too few $1 players survive) or
  is available for inspection; it does not retroactively alter the converged result.

---

## Failure Modes and Error/Warning Classes

| Class | Trigger condition | Always / verbose-gated |
|-------|-------------------|------------------------|
| `rotostats_error_missing_league_history` | `seed_method = "historical_priors"` and `league_history` is `NULL`; or `league_history` is non-NULL but `league_history$prices` is `NULL` or absent | `cli_abort()` (always) |
| `rotostats_error_insufficient_history` | Post-filter distinct year count in `$prices` < `replacement_params$historical_priors_min_seasons`; covers both "too few seasons at entry" and "too few after n_teams filter" | `cli_abort()` (always) |
| `rotostats_warning_history_n_teams_filtered` | One or more seasons dropped because their inferred n_teams != `config$n_teams`; lists dropped seasons and their team counts | `cli_warn()` (always — not verbose-gated) |
| `rotostats_error_stat_definition_drift` | A category in `config$categories` is absent from historical `$prices` end-of-season stat columns; or the reverse — historical has a stat but current categories use a different (non-derivable) stat | `cli_abort()` (always) |
| `rotostats_warning_calibration_suppressed` | Fewer than `calibration_min_n` players remain for a position-year in Step 4, or fewer than `historical_priors_min_seasons` years survive for a position after per-year suppression (partial fallback case) | `cli_warn()` (always — existing class) |

All new classes (`rotostats_error_insufficient_history`, `rotostats_warning_history_n_teams_filtered`,
`rotostats_error_stat_definition_drift`) must be registered in `plans/error-messages.md`.

The `rotostats_error_missing_league_history` row in `plans/error-messages.md` must be
extended to cover the historical-priors path (currently it only documents the case where
`league_history` is `NULL`; it must also cover the case where `league_history$prices` is
absent).

---

## Assumptions

| Assumption | Testable? | How to Test / Basis |
|---|---|---|
| Multi-season trimmed $1 pool produces a more stable per-position seed than within-season hierarchy under sparse-data conditions | Yes | Compare pass-1 assignment churn and replacement-stat line variance under both seed methods on held-out years in Moonlight Graham data; lower churn + variance = better |
| Seasons with matching `n_teams` are the correct pool to aggregate | Theoretical | Boundary depth is `n_teams * roster_slots[pos]`; a 12-team season and a 15-team season produce boundary players of materially different quality. Explicit restriction is transparent and matches the caller-filters-the-window convention established in the parent spec for `$prices` |
| 3-season default (`historical_priors_min_seasons = 3L`) is sufficient for per-position stability | Partially testable | Leave-one-out CV (hold out each year, re-derive prior from remaining years, compare to single-season hierarchy seed on the held-out year); validate once multi-season history is available |
| Standardizing historical stat lines in the current-year projection distribution (not the historical distribution) produces a seed that is correctly scaled relative to current players | Partially testable | Compare replacement z-scores derived from historical mean stats (standardized in current-year pool) to the boundary player's current-year z-score; they should be in the same neighborhood at the same position |
| Reusing `compute_positional_adjustments()` and the trim-logic path from `replacement_from_prices()` ensures per-position historical prior is constructed consistently with the single-season path | Yes | Test that on identical single-season data, `seed_method = "historical_priors"` with a one-year `$prices` produces pass-1 z-scores that match a `replacement_from_prices()`-style computation within floating-point tolerance (see Follow-up Work Items §test-spec, item g) |

---

## Known Validity Threats

**1. High-keeper-density seasons produce uninformative $1 pools at thin positions.**
Even with `is_keeper` flags or `trim_method` outlier removal, a keeper-heavy league may
leave fewer than `calibration_min_n` genuine $1 players at a given position in a given year
(particularly C and SS in AL-only leagues). The per-year suppression in Step 4 excludes
those year-position pairs from aggregation. If suppression affects many years at a position,
the multi-season prior for that position degrades toward the partial-fallback behavior
defined in Step 5 — and may ultimately fall back to `seed_method = "hierarchy"` at that
position. This is the correct behavior but users should monitor it via
`rotostats_warning_calibration_suppressed`. See the parent spec's §Known Validity Threats #5
and the note on calibration suppression.

**2. Stat-definition drift across seasons is not smoothed over — it aborts.**
A league that switched from AVG to OBP mid-history, or that changed its categoriy set
between eras, will trigger `rotostats_error_stat_definition_drift` for any category absent
from the filtered `$prices`. Silent stat substitution (using historical AVG as a proxy for
OBP) would produce meaningless priors with no warning. Aborting forces the user to either
extend their history data schema retroactively, restrict `$prices` to years with consistent
category definitions, or use `seed_method = "hierarchy"`. This is intentional.

**3. Expansion or contraction mid-history shrinks the usable window.**
A league that expanded from 12 to 15 teams mid-history will have its pre-expansion seasons
dropped by the n_teams filter in Step 1. This is the correct behavior (boundary depth is
n_teams-specific), but users with short post-expansion histories may find they fall below
`historical_priors_min_seasons`. The `rotostats_error_insufficient_history` message names
the n_teams mismatch explicitly to guide recovery. Recovery options: supply `$team_season`
so the filter can act accurately; or lower `historical_priors_min_seasons` via
`replacement_params`; or use `seed_method = "hierarchy"`.

**4. The historical prior only improves the seed — it cannot rescue a pathologically mis-specified `config`.**
If `n_teams` or `roster_slots` are wrong, the converged replacement level will be
mis-calibrated regardless of seed quality. The historical prior addresses seed churn, not
boundary definition. The parent spec's `rotostats_error_pool_too_small` and the $1
calibration diagnostic remain the primary runtime guards against mis-specified config.

**5. `$prices` end-of-season stats reflect actual outcomes, not projections.**
The historical prior is computed from actual end-of-season stats of $1 players, not from
their projected stats at auction time. This is correct for the purpose of identifying what
true $1-level production looks like at each position. However, it means the historical
prior is partly a function of which players happened to be purchased for $1, including
players who were injured early and contributed little. The `trim_method` and
`calibration_min_n` guards mitigate the impact of these cases.

---

## Follow-up Work Items (for the implementation run)

A future statsclaw implementation run will consume this spec. The Planner agent for that
run must address all of the following:

**New internal helper(s):**
- `compute_historical_prior_seed()` (or similar name) in `R/replacement_internal.R`.
  Responsible for Steps 1–7 above: n_teams filtering, season count assertion, stat-definition
  check, per-position per-year pool construction, multi-season aggregation, and z-score
  conversion. Signature should accept `prices`, `config`, `replacement_params`, `trim_method`,
  `team_season` (optional), and `projections` (for current-year z-score standardization).

**Plumbing:**
- In `replacement_level()`: route to `compute_historical_prior_seed()` when `seed_method =
  "historical_priors"` and `position_assignments` is NULL (pass 1 only). Replace the greedy
  hierarchy seed with the returned z-score vector. Pass 2+ proceeds unchanged.
- Add `historical_priors_min_seasons = 3L` to `default_replacement_params` in
  `R/replacement_params.R`.
- Extend the `rotostats_error_missing_league_history` emit site to cover the
  `league_history$prices` absent case (currently it only checks `league_history` is NULL).

**Test-spec items (minimum required):**

| ID | Description |
|----|-------------|
| TS-HP-1 | Happy path: sufficient history (≥ 3 matching seasons), correct column schema, no stat drift — `compute_historical_prior_seed()` returns a named numeric vector of z-scores with one entry per position in `roster_slots` |
| TS-HP-2 | `rotostats_error_insufficient_history` fires when total distinct years in `$prices` < `historical_priors_min_seasons` before any filtering |
| TS-HP-3 | `rotostats_warning_history_n_teams_filtered` fires and lists correct dropped seasons; downstream proceeds with reduced window; no abort when post-filter count ≥ min |
| TS-HP-4 | `rotostats_warning_history_n_teams_filtered` fires AND `rotostats_error_insufficient_history` is subsequently raised when the n_teams filter reduces the window below `historical_priors_min_seasons` |
| TS-HP-5 | `rotostats_error_stat_definition_drift` fires when a current category (e.g., OBP) is absent from `$prices`; message names the category and direction |
| TS-HP-6 | `rotostats_error_missing_league_history` fires (reusing the existing class) when `seed_method = "historical_priors"` and `league_history$prices` is NULL or `league_history` is NULL |
| TS-HP-7 | Equivalence: on identical single-season data (one year in `$prices`, matching `config$n_teams`, no n_teams filter), `seed_method = "historical_priors"` pass-1 z-scores match a `replacement_from_prices()`-style computation for the same position and stat set, within floating-point tolerance (1e-9 or tighter) |

**Sim-spec items:**
- DGP variant for multi-season historical data: generate synthetic `$prices` with known
  per-position $1 distributions across 3–7 seasons; verify `compute_historical_prior_seed()`
  recovers the known per-position means within Monte Carlo SE bounds.
- Convergence comparison: in a thin-position AL-only league (12 teams, SS pool = 12 rostered),
  compare pass counts and replacement-stat-line variance across `seed_method = "historical_priors"`
  vs `seed_method = "hierarchy"` across R = 500 simulated projection vintages; confirm that
  historical priors reduce variance of early-pass replacement stat lines at C and SS.
