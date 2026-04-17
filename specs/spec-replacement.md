# Metric Spec: Replacement Level (`replacement_level()`)

> **Status:** Draft · 2026-04-16
> **Q1 Conceptual:** Resolved · **Q2 Statistical:** Pending code audit · **Q3 Decision:** Pending validation

---

## Purpose

Compute per-position replacement-level stat lines that serve as the zero-dollar baseline for
PAR (Points Above Replacement) — the direct analog of WAR in rotisserie auction valuation. A
player who projects to exactly replacement level at their position has $0 value; positive PAR
drives auction dollar values.

---

## Formal Definition

`replacement_level()` identifies the **roster boundary player** at each position — the last
player who would realistically be rostered given league size and roster configuration — and
returns their projected stat line as the replacement level for that position.

**Roster boundary:** `n_teams × roster_slots[pos]` players deep in the projection pool,
sorted by a composite ranking (see Sort Key). This is the primary method; no hardcoded
discount constants.

**Boundary method:** Controlled by `boundary_method`:

- `"head_count"` (default): The roster boundary is determined by player count as above.
- `"playing_time"`: The replacement-level player is the one whose cumulative projected PA
  (hitters) or IP (pitchers) crosses the total league deployment threshold
  (`n_teams × roster_slots × mean_PA_per_slot`). Playing time is an input variable rather
  than a derived quantity, so no circularity is introduced. Use for projection vintages with
  many part-time or injured players.

**Boundary band:** Rather than a single boundary player, a symmetric band of ±K players
around the boundary is used. The replacement stat line for each counting stat is the mean of
players in the band; ERA/WHIP are IP-weighted means; AVG is computed as `sum(H) / sum(AB)`
across band players. This smooths cliff effects from individual outlier projections.

Default K = 3 (band of 7 players). Override via `band_width` or `replacement_params$band_width_K`.

**Dynamic K cap:** `K_eff = min(K, floor(n_rostered_pos / 4))`. Prevents the band from
spanning more than 25% of the rostered pool at any position. Relevant for thin AL-only pools
(e.g., 12-team AL SS with only 12 rostered players).

**Cliff detection:** If a statistical discontinuity (cliff) is detected within the band, the
band is truncated at `j−1` below the boundary (where `j` is the position of the cliff within
the lower half of the band). The cliff metric is returned in output for diagnostic purposes.

Cliff detection is only applied when the lower half of the band contains ≥ `cliff_min_n`
players (default 4). For thin pools where fewer players are available, the full band is used
and `cliff_detected = FALSE` is reported. Cliff detection applies only to the lower half of
the band; a talent gap above the boundary means rostered players above it are genuinely
better than the boundary player, which is expected and correct.

The cliff detection method is controlled by `cliff_method`:

- `"mad"` (default): MAD over the full 2K+1 band via `stats::mad()`. Cliff triggers when
  `gap >= cliff_threshold × mad(band_values) × 1.4826`. No dependencies; robust to up to
  50% outliers in the band. `cliff_threshold` default 1.5.
- `"fisher_jenks"`: `classInt::classIntervals(band_values, n=2, style="fisher")`.
  Scale-agnostic; works identically for high-variance (ERA) and low-variance (SV) stats.
  Cliff confirmed when the split falls at or below the boundary player position, verified
  by comparing within-group variance before and after the split. Adds `classInt` dependency.
- `"gap_ratio"`: `cliff_stat = gap_between_adjacent / range(band_values)`. Non-parametric;
  no dependencies. Cliff threshold is `cliff_gap_ratio_threshold` (default 0.375, range
  0.35–0.40; requires calibration). Exposed as `cliff_gap_ratio_threshold` in return
  `params`.

**Positional adjustments (scarcity premiums):** After computing per-position replacement
levels, positional adjustments are computed as:

```
scarcity_premium[pos] = global_replacement_level − replacement_level[pos]
```

Positive values indicate scarce positions (C, SS); negative values indicate deep positions
(OF, 1B). The computation method is controlled by `positional_adjustment_method`:

- `"fvarz"` (default): FVARz replacement anchoring — the replacement player's z-score is
  subtracted from all players at the same position, anchoring replacement level at zero for
  cross-position comparison. Industry standard (fvarbaseball, Harper Wallbanger, Smart
  Fantasy Baseball). No additional dependencies. Produces the catcher inflation described in
  Known Validity Threat #6.
- `"sgp"`: Adjustments computed in SGP units. The scarcity premium for each position is
  interpretable as standings-point units: `scarcity_premium["C"] = +2.3 SGP` means the
  replacement catcher costs 2.3 standings points more than the global-average replacement
  hitter. Requires `sgp_denominators`. Returns `positional_adjustments = NULL` on pass 1
  before denominators are available.
- `"dollar"`: Dollar-space normalization. Each position's contribution above replacement is
  converted to dollars via the budget-proportional formula; cross-position comparisons occur
  in dollar space. Values automatically sum to the auction budget. Does not require
  `sgp_denominators`.
- `"posblend"`: Tuneable blend of within-position and global-pool z-scores:
  `adjusted = pos_weight × (stat - pos_avg) + (1 - pos_weight) × (stat - global_avg)`.
  Requires `pos_weight` (0–1). `pos_weight = 1` is fully positional; `pos_weight = 0` is
  fully global. No principled default; requires empirical calibration against auction prices.

**Z-scores are never averaged across positions under any method.** Global replacement level
is derived within each method's own unit system.

If `sgp_denominators` are supplied but `positional_adjustment_method != "sgp"`, emit
`cli_inform()` when `verbose = TRUE`.

**Global replacement level** is computed separately for hitters and pitchers. The zero-sum
property is enforced as an internal assertion. When `catcher_adjustment_method = "split_pool"`,
catchers are on a separate budget and are excluded from the hitter zero-sum pool; the assertion
runs over non-catcher primary hitter slots only:

```r
zero_sum_positions <- if (catcher_adjustment_method == "split_pool") {
  setdiff(primary_hitter_slots, "C")
} else {
  primary_hitter_slots
}
check <- sum(zero_sum_positions_slots * scarcity_premium[zero_sum_positions])
if (abs(check) > 1e-6) cli::cli_abort("rotostats_error_zero_sum_violation", ...)
```

`primary_hitter_slots` = {C, 1B, 2B, 3B, SS, OF, DH} — UTIL, MI, CI excluded. DH is
included for AL/mixed leagues and excluded for NL-only. Positions with `roster_slots = 0`
contribute nothing. `pitcher_slots` = {SP, RP}.

Hitters and pitchers are computed separately because their distributions are drawn from
different pools and are not on a common scale.

UTIL, MI (middle infield), CI (corner infield), and DH are combo slots — they have no
independent replacement pool and no independent positional adjustment. Players filling any
combo slot receive the scarcity premium of their assigned position from `position_assignments`.
The roster slot they occupy is irrelevant to valuation; every player has exactly one
valuation position.

**SP/RP separation:** Starters and relievers are always computed against separate replacement
levels, even in one-pool pitcher leagues. This avoids sorting circularity (SP and RP have
incomparable rate stats) and stat line incoherence (a blended SP/RP replacement ERA would be
uninterpretable). When `pitcher_slots` is a single integer, the SP/RP split is inferred from
projection data role flags or a 60/40 default with a warning.

If projection data includes an explicit SP/RP role column, it is used directly. If no role
column is present, pitchers are classified by projected IP: IP ≥ `sp_ip_threshold` (default
100) → SP; IP < `sp_ip_threshold` → RP.

All diagnostic output — inference warnings, swingman flags, name match failures, and team
total divergence notices — is controlled by `verbose` (default `FALSE`).

Swingmen — pitchers with projected IP between 80 and 120 — are flagged in `cliff_metric$swingman`
regardless of whether role was explicit or inferred. If a swingman's inclusion shifts the band
mean ERA/WHIP by > 0.10, a `verbose`-gated note is emitted. No behavioral change.

**Rate stat ranking:** The ranking composite uses IP/AB-weighted rate stat contributions.
Method controlled by `boundary_rate_method`:

- `"raw_ip"` (default): Raw IP-weighted rate-stat differences with no league-depth denominator.
  Rankings are league-depth-independent — a pitcher of fixed quality ranks identically in a
  10-team and 15-team league.

  ```
  ERA_contribution  = (repl_ERA  − pitcher_ERA)  × pitcher_IP
  WHIP_contribution = (repl_WHIP − pitcher_WHIP) × pitcher_IP
  AVG_contribution  = (player_AVG − repl_AVG)    × player_AB
  ```

- `"sgp_pool"`: Todd Zola's SGP fixed-baseline-pool approach (Smart Fantasy Baseball). The
  other N−1 rostered pitchers form the baseline pool; a pitcher's ERA contribution is the
  marginal change in the pool's combined ERA/WHIP from adding that pitcher. Requires
  `sgp_denominators`. Partial circularity is managed by the existing iteration loop.

  **Invalid pairing — `"sgp_pool"` with `fixed_baseline` denominators:** When
  `boundary_rate_method = "sgp_pool"` and `sgp_denominators` are supplied,
  `replacement_level()` checks `attr(sgp_denominators, "rate_conversion")`. If the attribute
  value is `"fixed_baseline"`, the function aborts with `cli_abort()`
  (`rotostats_error_rate_method_mismatch`). The `"sgp_pool"` ranking method uses
  pool-blending denominator units, which are incompatible with `"fixed_baseline"`-calibrated
  denominators — those denominators are expressed in counting-equivalent ExER/ExWH/ExH units
  rather than the pool-blended units that `"sgp_pool"` ranking requires. The error message
  must name both the denominator method (`"fixed_baseline"`) and the ranking method
  (`"sgp_pool"`), and suggest either using `rate_conversion = "blended_pool"` in
  `sgp_denominators()` or switching to `boundary_rate_method = "raw_ip"`.

`expected_team_IP` and `expected_team_AB` are **not** used in ranking under either method;
they belong in `sgp()`. `league_history$team_stats` is a validation signal only (see
divergence warning in League History section).

**Rate stat denominators** are determined automatically from a built-in lookup:

```r
RATE_STAT_DENOMINATORS <- c(
  AVG = "AB",  OBP = "PA",   SLG = "AB",   OPS = "PA",
  ERA = "IP",  WHIP = "IP",  "K/9" = "IP", "BB/9" = "IP", "HR/9" = "IP",
  SVHD = "G",  QS = "GS",
  "K%" = "PA", "BB%" = "PA",
  wOBA = "PA", xFIP = "IP",  SIERA = "IP",  FIP = "IP"
)
```

Note: `SVHD` and `QS` are assumed to be counting totals in standard scoring; the `G`/`GS`
denominators apply only when scored per-opportunity. For any rate stat not in this lookup,
`replacement_level()` aborts with a message directing the user to supply the denominator
explicitly via `rate_denominators = c(wOBA = "PA")`. Export `rate_stat_denominators()` (no
arguments) so users can inspect the current lookup.

**Output stat line:** Raw projected totals are returned by default (`normalize_to_season = FALSE`).
Set `normalize_to_season = TRUE` to normalize counting stats to a full-season baseline:
hitters to 600 PA (550 AB when PA unavailable), SP to 200 IP, RP to 70 IP. Use when
projections are partial-season (call-up timing, injury returns). The return value carries
`attr(result, "stat_units")` set to `"raw_projected"` or `"full_season_normalized"`.
Downstream `sgp()` checks this attribute at runtime and aborts with `cli_abort("rotostats_error_stat_units_mismatch")` if the value is `"full_season_normalized"`. This is a known runtime-only guard.

IP is always included in pitcher `replacement_stats` even if not a scored category (needed
for rate stat weighting downstream).

**Z-score pool:** Z-scores are computed within two unified pools — one for all hitters, one
for all pitchers — each sized to `pool_size + K` players, where:

```
pool_size_p = config$n_teams × sum(config$pitcher_slots)
pool_size_h = config$n_teams × sum(config$roster_slots[primary_hitter_slots])
```

Both `sgp()` and `replacement_level()` derive these values from the internal `pool_sizes(config)` helper (see `plans/implementation/league-config-impl.md`) to avoid duplicating the formula.

`primary_hitter_slots` = {C, 1B, 2B, 3B, SS, OF, DH} — UTIL, MI, CI excluded (combo slots
have no independent pool; each player is counted once at their valuation position). The upper
K players are already within the rostered pool by definition; only the K-player lower
extension beyond the boundary adds new players. Position-specific z-score sub-pools are
explicitly rejected: computing z-scores within a single position produces compressed standard
deviations that overvalue rare skills at thin positions (e.g., SB from a catcher). Positional
scarcity enters through replacement-level subtraction per position, not through pool splitting.

Swingmen are included in the pitcher pool at initial z-score computation time, classified by
`sp_ip_threshold`. If reclassified in a later iteration, their z-score is recomputed in the
new pool. Swingman status is flagged in `cliff_metric$swingman` (informational only).

---

## Why This Measure

PAR requires a zero-dollar baseline — a level of production available for $1 on the auction
market. The roster boundary is the correct conceptual choice: it represents production that
any owner can acquire without sacrificing meaningful value. Players above this line have
positive auction value; players at or below it are freely replaceable.

Per-position replacement levels are required (not a global hitter threshold) because the
roster boundary player varies substantially by position in AL-only leagues. The 10th AL
catcher is a meaningfully weaker player than the 10th AL first baseman. A global threshold
systematically undervalues scarce positions (C, SS) and overvalues deep ones (OF, 1B),
producing mispriced auction targets — a documented failure mode in the previous Python
implementation.

The boundary band (vs. a single boundary player) reduces sensitivity to individual projection
outliers at the roster fringe. The cliff detection protects against bands that span a genuine
talent gap — including a player clearly below a cliff in the "replacement" aggregate would
understate true replacement level.

The optional `replacement_from_prices()` function (trimmed mean of $1 auction prices, top 20%
trimmed to remove $1 keepers bought below market) provides an empirical cross-check on the
boundary-derived replacement level. It is a validation layer, not the primary method.

---

## Assumptions

| Assumption | Testable? | How to Test / Basis |
|---|---|---|
| Roster boundary is the correct conceptual definition of replacement level | Theoretical | Standard sabermetric / rotisserie practice; equivalent to WAR replacement level construction |
| Per-position replacement levels correctly capture positional scarcity | Yes | Compare C/SS scarcity premiums to observed auction price premiums for those positions |
| Boundary band smoothing improves stability vs. single boundary player | Yes | Compare year-over-year variance of band-derived replacement stats vs. single-player-derived; lower variance = better |
| Dynamic K cap (`K_eff = min(K, floor(n_rostered_pos/4))`) prevents band spanning >25% of the pool | Yes | Verify K_eff < K at thin positions (C, SS in AL-only); check that replacement stats remain stable |
| Warm-started coordinate descent converges to a self-consistent fixed point within `max_iter` passes | Partially | Confirmed industry practice (FanGraphs auction calculator, Mastersball PVM); validate convergence rate on Moonlight Graham data |
| 60/40 SP/RP slot split is a reasonable default when role flags are absent | Partially | Compare to empirical SP/RP roster compositions in historical Moonlight Graham seasons |
| Projected IP ≥ 100 correctly classifies SP vs. RP when explicit role flags are absent | Partially | The IP distribution for pitchers is bimodal (starters ~150–180 IP, relievers ~55–70 IP); 100 IP sits reliably in the trough. Validate by comparing inference-based classifications to known role flags. Swingmen (80–120 IP) are flagged regardless. |
| Raw projected totals (not full-season normalized) are the correct output by default | Theoretical | Downstream `sgp()` uses raw projected stats; normalization would double-apply playing time weighting |
| IP-weighted ERA/WHIP quality differences (raw_ip method) correctly rank pitchers independent of league depth | Yes | Verify a fixed-quality pitcher's composite rank is stable across simulated 10-team and 15-team leagues |
| Rate stat denominators are correctly inferred from category names | Theoretical | Lookup is fixed; correctness is definitional for standard stats. Custom stats require explicit override. |
| AB-weighted AVG (`sum(H) / sum(AB)`) correctly aggregates batting average across band | Yes | Trivially correct by construction; verify no floating-point edge cases with very small AB |
| Statistical trim (`iqr`, `mad`, `kde`) correctly identifies $1 players who outperformed replacement level | Partially | When `is_keeper` is available, compare statistically-trimmed pool to the keeper-flag-excluded pool; large divergence indicates mis-calibration |
| Historical team IP/AB mean from `league_history$team_stats` is more accurate than projection-derived sum | Partially | Compare projection-derived sum to historical mean; divergence >15% triggers warning |

---

## Interface

### Inputs

```r
replacement_level(
  projections,               # data frame of projected player stats
  config,                    # league_config object (see plans/league-config-impl.md)
  sort_by = "zscore",        # "zscore" or "sgp"
  sgp_denominators = NULL,   # named numeric vector from sgp()$denominators; required if sort_by = "sgp"
  boundary_method = "head_count",           # "head_count" | "playing_time"
  seed_method = "hierarchy",               # "hierarchy" | "historical_priors"
  positional_adjustment_method = "fvarz",  # "fvarz" | "sgp" | "dollar" | "posblend"
  pos_weight = NULL,                       # numeric 0–1; required when positional_adjustment_method = "posblend"
  boundary_rate_method = "raw_ip",         # "raw_ip" | "sgp_pool"
  cliff_method = "mad",                    # "mad" | "fisher_jenks" | "gap_ratio"
  cliff_gap_ratio_threshold = 0.375,       # numeric; used when cliff_method = "gap_ratio"
  catcher_adjustment_method = "split_pool", # "split_pool" | "positional_default" | "partial_offset" | "none"
  sp_ip_threshold = 100,     # projected IP cutoff for SP/RP inference when role column is absent
  normalize_to_season = FALSE, # logical: normalize counting stats to full-season baseline
  band_width = NULL,         # integer K (symmetric band half-width); NULL = use replacement_params default
  cliff_threshold = 1.5,     # numeric: threshold for cliff detection (scale depends on cliff_method)
  rate_denominators = NULL,  # named chr vector, e.g. c(wOBA = "PA"); extends built-in lookup
  league_history = NULL,     # optional named list; see League History section
  trim_method = "iqr",       # "iqr" | "mad" | "kde"; used when league_history$prices
                             #   is supplied and is_keeper column is absent
  multi_pos = "highest_par", # "highest_par" | "primary" | "all" | "custom"
  position_assignments = NULL, # named chr vector (player_id → position) from prior
                               #   dollar_values() pass; NULL on first pass
  replacement_params = list(), # named list overriding entries in default_replacement_params
  max_iter = 25L,            # integer: max iteration passes for convergence
  tol = 0.01,                # numeric: convergence tolerance in SGP units (~$0.10–$0.25)
  verbose = FALSE            # logical: if TRUE, emit all diagnostic messages and warnings
)
```

**`projections` required columns:**

| Column | Type | Required | Notes |
|---|---|---|---|
| `player_id` | character | yes | MLBAM ID preferred; used for deduplication |
| `player_name` | character | yes | For display and fallback matching |
| `pos_eligibility` | character | yes | Pipe-delimited: `"C"`, `"1B|3B"`, `"SP|RP"`. First position is primary. |
| `team` | character | yes | MLB team abbreviation |
| `league` | character | yes | `"AL"` or `"NL"` |
| `[stat]` | numeric | yes | One column per scored category; exact names must match `categories` arg |
| `IP` | numeric | pitchers | Required even if not a scored category |
| `AB` | numeric | hitters | Required when AVG, OBP, or SLG in `categories` |
| `role` | character | no | `"SP"` or `"RP"` if source provides it; inferred from IP otherwise |

Validation at function entry using `checkmate`:

```r
checkmate::assert_data_frame(projections, min.rows = 1)
checkmate::assert_names(names(projections),
  must.include = c("player_id", "player_name", "pos_eligibility", "league",
                   stats_required))
checkmate::assert_character(projections$pos_eligibility)
checkmate::assert_subset(projections$league, c("AL", "NL"))
```

### League History (`league_history`)

An optional `league_history` object constructed via `league_history()` — see
`plans/implementation/league-history-impl.md` for schema. Supply when you have historical
data; both components (`$team_season`, `$prices`) are optional. `replacement_level()` uses
`$prices` for the $1 calibration check and `$team_season$IP` / `$AB` for the
projection-derived playing-time validation.

**`$prices` — $1 calibration check:** Players who sold for $1 but outperformed replacement
level (breakouts, injury recoveries, below-market keepers) are excluded before computing
the trimmed mean. All rows are used with equal weight — no window parameter is provided.
The caller is responsible for filtering to the desired years before passing (e.g., exclude
2020, restrict to last 3 seasons).

**Exclusion mechanism:** When `is_keeper` is present in `$prices`, flagged players are removed exactly —
no statistical trim is applied. When `is_keeper` is absent, `trim_method` controls outlier
removal from the $1 pool:

- `"iqr"` (default): remove players above Q3 + 1.5 × IQR of end-of-season values among $1
  players (Tukey fence). Works for all league types.
- `"mad"`: remove players above median + 3 × MAD of end-of-season values. More robust for
  heavily right-skewed distributions.
- `"kde"`: detect the trough between the genuine-$1 cluster and the overperformer cluster
  via kernel density estimation; remove all players above the trough. Errors with an
  informative message if no trough is detectable — use `"iqr"` or `"mad"` instead.
  Future implementation: GMM (Gaussian mixture model) as `trim_method = "gmm"`.

**Trim method selection guidance:**

| Condition | Recommended method |
|---|---|
| `is_keeper` column available | Exact exclusion; `trim_method` ignored |
| `is_keeper` absent, < 3 seasons | `"iqr"` — most robust in small samples |
| `is_keeper` absent, ≥ 3 seasons, high keeper density | `"mad"` — robust to right-skewed $1 pools |
| `is_keeper` absent, ≥ 3 seasons, bimodal structure expected | `"kde"` — detects cluster boundary directly; errors rather than producing a silent bad estimate |

After exclusion, if fewer than `calibration_min_n` players remain, the calibration is
suppressed and `rotostats_warning_calibration_suppressed` is emitted.

When `player_id` is absent from `$prices`, matching falls back to normalized name matching:
1. Decompose Unicode to NFD (`stringi::stri_trans_nfd()`)
2. Strip combining diacritical marks (`stringi::stri_replace_all_regex("\\p{Mn}", "")`)
3. Convert to lowercase (`tolower()`)
4. Remove non-alphanumeric, non-space characters (`str_replace_all("[^a-z0-9 ]", "")`)
5. Collapse multiple spaces (`str_squish()`)

Mismatched player names are reported when `verbose = TRUE`; silent otherwise.

**`$team_season$IP` / `$AB` — playing-time validation:** When `IP` and `AB` columns are
present in `$team_season`, `replacement_level()` warns if the projection-derived sum
diverges from the historical mean by more than `ip_ab_divergence_tol` (default 15%) — a
signal that either the projection vintage is unusual or the historical data is stale.
Historical team totals are **not** used in ranking under either `boundary_rate_method`.

### `replacement_params`

All numeric constants are accessible and overridable via a `replacement_params` named list.
Export `default_replacement_params` for inspection.

```r
default_replacement_params <- list(
  band_width_K          = 3L,         # sweep: 1:5
  cliff_threshold       = 1.5,        # sweep: seq(0.5, 3.0, 0.25)
  cliff_min_n           = 4L,         # sweep: 3:6
  sp_ip_threshold       = 100,        # sweep: c(80, 90, 100, 110, 120)
  sp_rp_split_default   = c(SP = 0.60, RP = 0.40),
  ip_ab_divergence_tol  = 0.15,       # sweep: c(0.10, 0.15, 0.20)
  calibration_min_n     = 15L,        # sweep: c(10, 15, 20, 25, 30)
  convergence_eps       = 0.01,       # sweep: c(0.001, 0.01, 0.05)
  convergence_max_iter  = 25L
)
```

Override specific entries: `replacement_params = list(band_width_K = 2L)`. The `band_width`
and `cliff_threshold` top-level parameters are convenience aliases for the corresponding
`replacement_params` entries; if both are supplied, the top-level parameter wins.

### Outputs

```r
list(
  replacement_stats      = <data frame: position × stat>,
  positional_adjustments = <named numeric vector or NULL>,
  cliff_metric           = <data frame: position, cliff_detected, cliff_location,
                            cliff_magnitude, swingman, n_band_players>,
  two_way_players        = <character vector: player_ids with PAR > $0 in both roles>,
  pool_diagnostics       = <list: position_sd_ratio per category>,
  method                 = "boundary_band",
  params                 = list(converged, iterations, delta, n_teams, roster_slots,
                                band_width, cliff_threshold, sort_by, stat_units, ...)
)
```

**`replacement_stats` data frame** (one row per position):

| Column | Type | Notes |
|---|---|---|
| `position` | character | Exact keys from `roster_slots` names |
| `[stat]` | numeric | One column per category; same names as `projections` input |
| `IP` | numeric | Always present for pitcher positions |
| `AB` | numeric | Always present for hitter positions when AVG/OBP in `categories` |
| `n_band_players` | integer | Number of players averaged into this replacement line |
| `cliff_detected` | logical | Whether cliff detection truncated the band |

Stat column names exactly match input `projections` column names. `position` values are a
subset of `names(roster_slots)`. `replacement_stats` is always position-indexed — two-way
players do not appear as rows.

The return value carries `attr(result, "stat_units")` set to `"raw_projected"` or
`"full_season_normalized"`.

Downstream `sgp()` checks this attribute at runtime and aborts with `cli_abort("rotostats_error_stat_units_mismatch")` if the value is `"full_season_normalized"`. This is a known runtime-only guard.

**Output attributes:**

```
attr(result, "stat_units")           = "raw_projected" | "full_season_normalized"
attr(result, "config")               = the league_config object passed at call time
attr(result, "projections")          = the projections data frame passed at call time
attr(result, "position_assignments") = named character vector (player_id → position)
```

`config` and `projections` allow downstream functions (`zar()`, `zaa()`) to
extract both without requiring users to supply them again. Functions that
iterate with the replacement object should strip `attr(replacement, "projections")`
before the loop and re-attach after convergence to avoid per-iteration copying.

The return value carries `attr(result, "converged")`, `attr(result, "iterations")`, and
`attr(result, "delta")` following `lme4`/`optim()` conventions.

`positional_adjustments` is `NULL` on pass 1 when `positional_adjustment_method = "sgp"`
(denominators not yet available). Under all other methods it is a named numeric vector of
`scarcity_premium` values indexed by position name.

`pool_diagnostics$position_sd_ratio`: ratio of each position's within-pool SD to the global
SD for each scored category. A ratio significantly below 1.0 on counting stats indicates
pool compression (a construction issue); a ratio near 1.0 with inflated prices indicates a
genuine scarcity premium. Used to distinguish the two for catcher calibration.

---

## Multi-Position and Two-Way Player Handling

**Multi-position eligibility** (`multi_pos`):

- `"highest_par"` (default): A multi-eligible player is assigned to the position where their
  PAR is highest (equivalently, where positional scarcity is greatest). This is the correct
  default for auction valuation.
- `"primary"`: Assign to the position listed first in `pos_eligibility`. `position_assignments`
  is ignored.
- `"all"`: Compute separate replacement-level comparisons for every eligible position.
  `replacement_stats` output shape changes to player × position × stat.
- `"custom"`: Caller supplies an explicit position assignment vector via `position_assignments`.

**Pass-1 bootstrap (seed):** On pass 1 (`position_assignments = NULL`), the seed is determined
by `seed_method`:

- `"hierarchy"` (default): Players are ranked within their primary position group only (first
  position in `pos_eligibility`), using the greedy scarcity ordering C > SS > 2B > 3B > 1B >
  OF. Industry-standard seed (fvarbaseball, Harper Wallbanger).
- `"historical_priors"`: Per-position replacement-level z-scores calibrated from
  `league_history` data seed the first pass. Requires `league_history`; aborts with
  `rotostats_error_missing_league_history` otherwise.

On subsequent passes (pass 2+), `dollar_values()` supplies current assignments via
`position_assignments`.

**Replacement level computation uses the same position assignments as player valuation.**
When `multi_pos = "highest_par"`, the replacement-level player at position P is the Nth-best
player assigned to P under current PAR estimates. Each player appears in exactly one
position's pool. This ensures replacement levels are self-consistent with valuations: a 2B/SS
player assigned to SS counts toward SS pool depth, correctly reducing apparent SS scarcity.

**Convergence criterion** (managed internally by `replacement_level()`):

1. **Primary:** Zero players change their assigned position between passes N and N+1
   (`all(new_assignment == old_assignment)`)
2. **Secondary:** `max(abs(new_repl_stats - old_repl_stats)) < tol` (default `tol = 0.01`
   in SGP units ≈ $0.10–$0.25)

Both conditions must hold simultaneously. Hard cap: `max_iter` passes (default 25). If the
cap is reached, emit `rotostats_warning_convergence_not_reached` and return best-so-far with
`converged = FALSE`. Non-convergence is a warning, not an error, following `lme4` convention.

Position assignment circularity (when `multi_pos = "highest_par"`) and SGP circularity
converge in the same iteration loop — no separate loop is needed.

**Note on pass count and seed quality:** The number of passes to convergence is dominated by
multi-position reassignment churn, not by z-score seed quality at thin positions. A catcher or
shortstop with no multi-position eligibility is assigned on pass 1 and never moves; their
replacement level stabilizes immediately. The 2–3 pass typical count reflects how long it
takes 2B/SS and CI/MI multi-eligible players to settle into their highest-PAR positions. Poor
seed quality at thin positions (C, SS) delays convergence of the replacement *stat line* but
does not delay convergence of *assignments* — the two criteria are distinct. In practice, thin
positions converge in 1–2 passes because there are few multi-eligible players competing for
those slots.

**Two-way players:**

Hitting and pitching roles are always computed separately. Two-way PAR is:

```
two_way_PAR = hitter_PAR + pitcher_PAR - 1
```

The deduction of 1 (≈ $1 minimum salary) accounts for the single roster slot occupied
(Pitcher List formulation). The two-way player is charged against the pool where they produce
higher PAR as the "primary" role; the secondary role's value is treated as incremental. Slot
deduplication is the responsibility of `dollar_values()` — this contract must be explicit in
the `dollar_values()` spec. Additionally, when `catcher_adjustment_method = "split_pool"`,
`dollar_values()` must treat the catcher budget as a separate allocation
(`n_C_slots / n_total_primary_hitter_slots × hitter_budget`) rather than drawing from the
shared hitter pool. `dollar_values()` detects this via `params$catcher_adjustment_method`.

`two_way_players` in the return list: character vector of `player_id` values with PAR > $0 in
both roles. Informational; consumed by `dollar_values()`.

---

## Sort Key and Circularity

The sort key determines player ranking, which determines who sits at the boundary.

**`sort_by = "zscore"` (default):** Players ranked by composite z-score across projected
stats. Self-contained — no upstream dependency on `sgp()`. This is the default and enables
`replacement_level()` to run without `sgp_denominators`.

**`sort_by = "sgp"` (optional):** Players ranked by total SGP. Requires `sgp_denominators`
(named numeric vector from `sgp_denominators()`). The ranking depends on per-player SGP,
which depends in turn on the current replacement stat line — directly via `multi_pos`
reassignment churn under `multi_pos = "highest_par"`, and via the marginal pool baseline
when `boundary_rate_method = "sgp_pool"`. This is the circular dependency the loop resolves.

**Circularity resolution:** Iteration is managed internally by `replacement_level()`. The
caller computes `sgp_denominators` once from `league_history` and passes them in; the loop
itself runs inside the function:

1. **Pass 1:** Rank players by composite z-score, identify boundary, compute initial
   replacement stats and position assignments.
2. **Pass N (N ≥ 2):** Call `sgp(projections, denominators)` internally to derive per-player
   `total_sgp`; re-rank by `total_sgp`; identify the new boundary; recompute replacement
   stats; re-evaluate multi-position assignments (when `multi_pos = "highest_par"`).
3. Repeat pass N until the convergence criteria above are met or `max_iter` is reached
   (2–3 passes typical).

`sgp_denominators` are calibrated once outside the loop and do not change between iterations
— what updates each pass is per-player SGP totals (via re-ranking) and position assignments.
Position assignment circularity and SGP-ranking circularity converge in the same loop; no
separate loop is needed.

`replacement_level()` is deterministic for fixed inputs and returns a converged result.
Downstream callers (`par()`, `zar()`, `dollar_values()`) consume the converged output and do
not orchestrate the loop.

---

## Error Handling

| Condition | Handler | Class |
|---|---|---|
| Missing required column in `projections` | `cli_abort()` | `rotostats_error_missing_column` |
| Wrong column type (e.g., `avg` is character) | `cli_abort()` | `rotostats_error_wrong_column_type` |
| Unknown rate stat not in lookup | `cli_abort()` | `rotostats_error_unknown_rate_stat` |
| `sort_by = "sgp"` but `sgp_denominators` is NULL | `cli_abort()` | `rotostats_error_missing_sgp_denominators` |
| `n_teams × roster_slots[pos]` exceeds projection pool | `cli_abort()` | `rotostats_error_pool_too_small` |
| `trim_method = "kde"` and no trough detectable | `cli_abort()` | `rotostats_error_kde_no_trough` |
| `seed_method = "historical_priors"` but `league_history` is NULL | `cli_abort()` | `rotostats_error_missing_league_history` |
| `positional_adjustment_method = "posblend"` but `pos_weight` is NULL | `cli_abort()` | `rotostats_error_missing_pos_weight` |
| Convergence not reached within `max_iter` | `cli_warn()` (always) | `rotostats_warning_convergence_not_reached` |
| Calibration pool < `calibration_min_n` after trimming | `cli_warn()` (always) | `rotostats_warning_calibration_suppressed` |
| Team IP/AB diverges > `ip_ab_divergence_tol` from historical | `cli_warn()` (if `verbose`) | `rotostats_warning_team_total_divergence` |
| Name match failure in `league_history$prices` | `cli_warn()` (if `verbose`) | `rotostats_warning_name_match_failure` |
| Swingman in boundary band | No signal; `swingman = TRUE` in `cliff_metric` | — |
| Zero-sum violation in positional adjustments | `cli_abort()` (internal assertion) | `rotostats_error_zero_sum_violation` |
| `sgp_denominators` supplied but `positional_adjustment_method != "sgp"` | `cli_inform()` (if `verbose`) | — |

All classes must be added to `plans/error-messages.md` as the canonical registry. Use
`rlang::caller_env()` so errors point to the user's calling frame, not internals.

---

## `replacement_from_prices()`

Implemented as a standalone function with a fundamentally different primary input. Returns the
same output schema as `replacement_level()` and is interchangeable as the `replacement_fn`
argument to `dollar_values()`.

**Rationale for separate function:** `replacement_level()` requires `projections` as its
primary input; `replacement_from_prices()` requires historical auction `prices`. Making
`projections` optional when `method = "prices"` produces a messy interface where required
arguments depend on other argument values. The algorithmic difference (boundary detection +
band averaging vs. statistical trimming of a $1 auction pool) is large enough that a shared
function body would be harder to read and test than two focused functions.

```r
replacement_from_prices(
  prices,                    # data frame: league_history$prices schema
  n_teams,
  roster_slots,
  categories,
  trim_method   = "iqr",     # "iqr" | "mad" | "kde"
  calibration_min_n = 15L,
  verbose       = FALSE
)
```

`projections` is not an input. `sort_by`, `band_width`, `cliff_threshold`, `cliff_method`,
`sp_ip_threshold`, `boundary_method`, `seed_method`, `normalize_to_season`, and all iteration
parameters do not apply and must not appear in the signature.

**Algorithm:**
1. Filter `prices` to `price == 1` (or `price <= 1` for leagues with $1 minimum bids)
2. Exclude `is_keeper == TRUE` rows exactly when present; apply `trim_method` when absent
3. If fewer than `calibration_min_n` remain: emit `rotostats_warning_calibration_suppressed`
   and return `NULL`
4. Per position (inferred from player eligibility flags in the `prices` data): compute the
   mean end-of-season stat line of $1 players at that position
5. Compute positional adjustments via shared internal helper `compute_positional_adjustments()`
6. Return same list schema as `replacement_level()` with `method = "prices"` in `params`

**Shared internal helpers** (in `R/replacement_internal.R`):

- `format_replacement_output()` — constructs return list and attaches `stat_units` attribute
- `compute_positional_adjustments()` — shared positional adjustment logic
- `assert_replacement_output_contract()` — validates output schema before return

**Integration with `dollar_values()`:**

```r
dollar_values(
  projections,
  replacement_fn = replacement_level,        # default
  # or:
  replacement_fn = replacement_from_prices,
  ...
)
```

When `replacement_fn = replacement_from_prices`, historical prices do not change between
passes. `dollar_values()` detects `params$method == "prices"` and calls `replacement_fn`
once, reusing the result across passes.

**Limitations:** Most useful as a validation layer on `replacement_level()` output or as the
primary method in leagues with 5+ seasons of low-keeper-density auction history. Suppressed
per `calibration_min_n` when the genuine-$1 pool is too thin.

---

## Dependencies

**Upstream:**
- `projections`: a data frame of third-party projected player stats (ATC, THE BAT X, or
  similar) filtered to the appropriate player pool. `replacement_level()` does not fetch or
  filter projections itself.
- `sgp()$denominators`: required only when `sort_by = "sgp"` or
  `boundary_rate_method = "sgp_pool"`.

**Downstream:**
- `sgp()`: consumes `replacement_stats` to compute per-player SGP above replacement.
- `dollar_values()`: consumes `replacement_stats` and `positional_adjustments` from the
  converged result; does not manage iteration.

---

## Decision This Informs

- **Primary use:** Define the per-position replacement baseline — the zero-dollar anchor
  for all auction valuation. Required upstream of every function that produces a
  replacement-anchored output (`par()`, `zar()`, `dollar_values()`).
- **Consumer:**
  - `par()` and `zar()`: subtract `replacement_stats` (band-average stat line) per
    position to produce above-replacement values.
  - `zaa()`: uses the replacement object to restrict the player pool to rostered players
    before computing within-position z-scores.
  - `dollar_values()`: consumes `position_assignments` and `replacement_stats` from the
    converged `replacement_level()` result.
- **How consumed:**
  - `replacement_stats`: one row per position, one column per category — subtracted
    directly in `par()` Step 3 and `zar()` Step 3.
  - `position_assignments`: maps each player to their valuation position; used by `par()`
    and `zar()` to route each player to the correct positional baseline.
  - `positional_adjustments`: scarcity premiums by position; consumed by `dollar_values()`
    for budget allocation across positions.
  - `attr(result, "projections")` and `attr(result, "config")`: carried forward so
    `zar()` and `zaa()` callers do not need to re-supply them.
- **Sensitivity:** Most sensitive to roster configuration. A wrong `n_teams` or
  `roster_slots` shifts the entire replacement baseline; the `boundary_threshold` guard
  in `par()` detects the symptom. Thin positional pools (C, SS in AL-only) are most
  sensitive to `band_width` — the dynamic K cap limits but does not eliminate instability
  in small-sample positions.

---

## Known Validity Threats

### Conceptual (Q1)

**1. Band width is disproportionately wide for thin AL-only pools.**
With K = 3, a 12-team AL SS pool (12 rostered players) has a band of 7 — 58% of the entire
positive pool. The dynamic K cap (`K_eff = min(K, floor(n_rostered_pos / 4))`) limits this
to at most 25% of the pool. Cliff detection is additionally skipped when the lower half has
fewer than `cliff_min_n` players, ensuring the band mean is not corrupted by a genuine talent
gap it cannot detect. Monitor year-over-year variance of SS/C replacement stats; if they are
unstable, reducing K via `band_width` is the corrective lever.

**2. Cliff detection disabled for thin lower bands.**
When the lower half of the band has fewer than `cliff_min_n` players, cliff detection is
skipped and the full band is used. This is the correct tradeoff — a genuine talent cliff at a
thin position is effectively undetectable without more data. The residual risk is that the
band mean includes a player clearly below a real talent gap, modestly understating replacement
level. Validate by checking that replacement stat lines at C and SS are directionally
consistent with observed $1 auction prices when `league_history$prices` is available.

**3. SP/RP separation with inferred role flags introduces a circular dependency within `replacement_level()`.**
Classifying a pitcher as SP vs. RP based on projected IP requires a threshold. That threshold
implicitly assumes a replacement-level IP, which is itself an output of `replacement_level()`.
For most projections this is benign (clear SP/RP bimodal separation), but swingmen may be
affected. Swingmen are flagged in `cliff_metric$swingman` for review regardless.

**4. Two-way player PAR double-counts roster slot consumption.**
Mitigated by `two_way_PAR = hitter_PAR + pitcher_PAR - 1`, charging the deducted slot against
the higher-PAR role's pool. The specific deduplication contract must be explicit in the
`dollar_values()` spec. The Python implementation's C1 finding (two-way double-counting) was
a failure of this exact case.

**5. `league_history$prices` calibration may be uninformative in high-keeper-density seasons.**
Even with `is_keeper` flags or statistical trimming, a keeper-heavy league may leave fewer
than `calibration_min_n` genuine-$1 players — triggering the suppression guard. When `kde`
is used and the $1 pool lacks clear bimodal structure, it errors rather than producing a
meaningless estimate. In either case the boundary-derived replacement level is used without
an empirical cross-check for that season.

**6. Catcher replacement-level estimates may be inflated in AL-only leagues.**
`pool_diagnostics$position_sd_ratio` provides a diagnostic to distinguish root causes: a
ratio significantly below 1.0 on counting stats indicates pool compression (a construction
bug — fix the pool); a ratio near 1.0 with inflated prices indicates a genuine scarcity
premium. `catcher_adjustment_method` exposes the correction approach.

**`catcher_adjustment_method` overrides the catcher row of `positional_adjustments` — it is
not applied on top of the positional adjustment. `"positional_default"` means "apply
`positional_adjustment_method` to catchers unchanged." All other values replace
`scarcity_premium["C"]` with a position-specific calculation before the zero-sum assertion
runs.**

- `"split_pool"` (default): Catchers are compared only against catchers in a structurally
  separate pool with budget allocation proportional to roster slot count (`n_C_slots /
  n_total_primary_hitter_slots × hitter_budget`). Eliminates cross-pool contamination
  without requiring an empirical discount. C is excluded from the zero-sum assertion (see
  above).
- `"positional_default"`: Apply `positional_adjustment_method` to catchers unchanged; no
  catcher-specific override. Under `"fvarz"`, this produces the known ~30% catcher
  inflation in thin-pool years.
- `"partial_offset"`: Empirical fraction of the offset. Not principled; for research use.
- `"none"`: No positional adjustment (Podhorzer/FanGraphs contrarian view).

The 0.75× hardcoded discount in `priceguide` should be removed once `pool_diagnostics` is
implemented and the root cause is confirmed.

### Statistical (Q2)
_Pending — fill in after code audit of `R/replacement.R`_

### Decision (Q3)
_Pending — fill in after validation harness results_

---

## Validation Approach

### Runtime checks

These fire automatically on every call or run as unit tests with fixture data.

- **Zero-sum assertion:** `sum(primary_hitter_slots × scarcity_premium[hitter_positions])`
  must equal 0. Enforced as an internal assertion; any deviation is a computation bug, not
  a calibration issue.
- **Scarcity premium direction:** C and SS scarcity premiums must be positive; OF and 1B
  must be at or below zero. Automatable as unit tests:

  ```r
  expect_gt(scarcity_premium["C"], 0)
  expect_lte(scarcity_premium["OF"], 0)
  ```

- **`stat_units` attribute:** `attr(result, "stat_units")` must be `"raw_projected"` (or
  `"full_season_normalized"` when `normalize_to_season = TRUE`). Automatable.
- **`position_assignments` completeness:** Every player in the rostered pool must appear
  in `position_assignments`. Automatable: assert no player is missing a valuation position.

### Manual diagnostics

Run after implementation with a real projection vintage.

- **$1 calibration check:** When `league_history$prices` is supplied, replacement stat
  lines at each position should be close to the trimmed mean of the empirical $1 auction
  pool. Large divergence (more than one standings place in `total_par`) suggests the
  boundary is mis-specified. Not automatable — requires historical price data.
- **Year-held-out stability:** Replacement stat lines estimated on one projection vintage
  should be similar in relative magnitude across positions to those on another vintage.
  Large year-over-year swings at a single position (not explained by a real talent-pool
  shift) indicate boundary instability.
- **Budget reconciliation:** If `dollar_values()` produces a total positive-PAR auction
  pool that deviates from the known auction budget by more than ~$5, the replacement
  baseline is likely mis-set (too high or too low). Requires a full downstream run.

The formal validation protocol will be specified in Q3 after the implementation exists.

**Parameter calibration:** All constants in `default_replacement_params` should be calibrated
via leave-one-season-out CV against Moonlight Graham and/or NFBC auction prices (2021–2024).
For each candidate value, sweep OAT while holding others at defaults. Record Spearman ρ
between projected dollar values and actual prices, RMSE, and $1-pool bias. Specific targets:

- `band_width_K = 3`: validate year-over-year variance reduction vs. K=1 (single boundary player)
- `sp_ip_threshold = 100`: validate against empirical bimodal trough from 5 years of
  Steamer/ZiPS IP projections via `mixtools::normalmixEM()`
- `sp_rp_split_default = c(SP=0.60, RP=0.40)`: re-derive from `historical_rosters.csv` actual
  SP/RP slot compositions in Moonlight Graham
- `cliff_threshold = 1.5`: re-derive after fixing cliff detection σ estimation (now uses MAD)
- `calibration_min_n = 15`: raise to 20 unless calibration sweep shows meaningful degradation
