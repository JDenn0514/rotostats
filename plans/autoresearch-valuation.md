# Autoresearch Plan: Rotisserie Valuation Optimization

> **Goal:** Identify the valuation method and configuration that most accurately converts
> a player's realized stats into dollars. **Primary metric:** per-player earned-$ MAE and
> Spearman rank correlation across Tout Wars 2013–2025 and LABR 2020–2025 expert auction
> records, reported per-format (AL-only / NL-only / mixed) in three views (aggregate /
> consistency / deployment). **Secondary metric:** team-total-vs-standings Spearman ρ
> (the Podhorzer & Bulay protocol) as a cross-check. **Deployment target:** Moonlight
> Graham (AL-only, keeper), scored on earned $ only — keeper-agnostic. The agent iterates
> through a curated grid of configurations, surfaces winners under each view, and commits
> those that improve aggregate MAE without regressing per-format.

---

## Framework Decisions

This plan reflects five structural decisions resolved in the 2026-04-17 design conversation.
Each is elaborated further in the corresponding section below.

1. **Primary metric is player-level** (earned-$ MAE + Spearman), not team-level correlation.
   Team-level correlation is retained as a secondary cross-check. See §Primary Metric.
2. **Evaluation pool is the full projected player pool** (preseason projection ≥ some
   PA/IP threshold — sweep TBD), not rostered players only. Earned $ is scored on actual
   realized stats with no full-season filter; partial-season treatment is covered in
   §Primary Metric.
3. **Data scope is Tout Wars + LABR primary, Moonlight Graham deployment.** NFBC's
   average-only data cannot contribute to the MAE pipeline. See Layer 2 and Layer 3.
4. **Format-aware evaluation** — three views reported every round: aggregate MAE,
   max-format MAE (consistency), per-format MAE. Winner tagging surfaces aggregate,
   consistency, and deployment candidates separately. See §Three-View Winner Tagging.
5. **Search architecture is a curated grid on all axes** (not sequential-greedy). Claude
   proposes curated variants per axis; user approves before the grid runs. See
   §Experiment Protocol.

Specifics marked **TBD** throughout this doc are placeholders for values to be resolved
before the harness runs. They include: per-phase acceptance thresholds (dollars of
improvement required / per-format regression tolerated), grid axis cardinalities, the
library-default policy (consistency vs. deployment vs. aggregate winner), and the
eligibility projection PA/IP sweep values.

---

## Research Design

Validation proceeds in four layers. Layer 1 is a prerequisite gate — do not run real-data
experiments until it passes. Layer 2 drives method selection via the curated grid.
Layer 3 is a post-selection deployment check, not an alternative optimization target.
Layer 4 runs once after the best configuration is committed.

| Layer | Name | Data | Purpose |
|-------|------|------|---------|
| 1 | Synthetic validation | Simulated | Confirm implementation faithfulness before real-data exposure |
| 2 | Multi-league LOYO (primary) | Tout Wars 2013–2025 + LABR 2020–2025 | Drive method selection; per-format MAE across AL-only / NL-only / mixed |
| 3 | Deployment validation | Moonlight Graham 2017–2025 (AL-only, keeper) | Confirm Layer 2 winner performs on deployment target; earned-$ only |
| 4 | Sensitivity analysis | Layer 2 dataset | Identify which parameters matter (OAT perturbation on winner) |

The Layer 2 winner is applied to MG data and scored against MG earned $ during Layer 3.
Material Layer 2 → Layer 3 gaps flag either AL-only distributional quirks beyond the
AL-only Tout Wars / LABR cross-section (worth investigating), or implementation bugs
that surface only in the deployment pipeline (worth fixing). Layer 3 does not re-open
method selection.

### Three-View Winner Tagging (Layer 2)

Every accepted candidate is tagged under three views:

- **Aggregate winner** — lowest mean MAE across the three formats. Answers "best on
  average."
- **Consistency winner** — lowest max MAE (or lowest SD) across formats. Answers "most
  format-invariant / most robust to unknown future distributional shifts."
- **Deployment winner** — lowest MAE on AL-only specifically. Matches the deployment
  target (Moonlight Graham is AL-only).

If one method wins all three, adopt it. If they differ, surface the tradeoff explicitly
and commit a library-default policy (TBD). Likely default: consistency winner (robust,
format-invariant, trustworthy across future seasons), with deployment winner available
as a config-selectable override for AL-only leagues.

---

## Primary Metric: Player-Level Earned-$ MAE

### Metric definition

For each player-season in the evaluation pool:

1. Compute **retrospective earned $** from realized stats, using that year's league
   context (format, budget, roster slots, scored categories). This is the deterministic
   auction-value conversion the method under test is trying to approximate.
2. Compute **predicted $** from the valuation method under test, fed with realized
   stats. (Realized stats, not projections — this isolates method quality from
   projection error. See Critique 3 in `autoresearch-methodology-critiques.md`. A
   projection-based validation stage is proposed as a deployment-gate check after the
   grid completes.)
3. Record per-player error: `err = predicted_$ − earned_$`.

Aggregate error metrics per (method, format, year):

- **MAE** — mean absolute error across all eligible players. Primary.
- **Spearman ρ** — rank correlation between predicted $ and earned $ across the pool.
  Always reported alongside MAE; a method with high MAE but high rank ρ is
  systematically biased (e.g., inflated) and can be fixed by post-hoc rescaling.
- **RMSE** — optional secondary diagnostic.

### Eligibility filter (draftability-based)

A player is eligible for primary scoring if a preseason projection exists with:

- PA ≥ **TBD** (proposed sweep: 100 / 150 / 200 / 250) for hitters
- IP ≥ **TBD** (proposed sweep: 30 / 50 / 80) for pitchers

This operationalizes "draftable on draft day." The filter is based on **projected**
playing time, not realized. Jose Caballero (370 realized PA, 49 SB in 2025) is a valid
evaluation target because he was projected above threshold preseason — regardless of
his final PA count. An injured veteran who played 280 PA is similarly included.

Within the eligible pool, every player is scored on actual earned $ — **no additional
realized-playing-time filter is applied**.

Players *excluded* by the eligibility filter (no preseason projection, or projection
below threshold) are call-ups and deep reserves that no valuation system could have
priced on draft day. These are aggregated into a separate **information-asymmetry
diagnostic** rather than the primary MAE. Wyatt Langford–style surprise promotions fall
here.

**Dependency:** the eligibility filter requires preseason projection data (source TBD:
Steamer / ZiPS / ATC / blend). This is an unresolved input to the harness.

### Required reporting breakdowns

Every experiment reports the following breakdowns alongside global MAE:

**By sub-pool** — captures the $1-player problem (Critique 1). A method with good
global MAE can still mis-calibrate the $1 pool.

- Top-30 (stars): MAE + Spearman
- Top-31 to top-100 (middle-elite)
- Top-101 to roster capacity (mid-tier)
- $1 pool (players whose realized earned $ is < $2)

**By position** — catches position-specific failures, especially catcher mispricing
from thin-pool distortion.

- C, 1B, 2B, 3B, SS, OF, DH, SP, RP — each with MAE + Spearman

**By era** — diagnostic for whether post-2023 MLB rule changes (shift ban, larger
bases) affected method performance. Tests the assumption that correctly-implemented
methods are era-invariant when internally calibrated within each year's data.

- Pre-2023 (2013–2022)
- Post-2023 (2023–2025)
- **Time-based holdout test** (recommended diagnostic, TBD): fit on 2013–2022, predict
  on 2023–2025; compare to full-LOYO MAE. Material divergence = era-shift signal at
  the method level, triggering investigation rather than automatic weighting changes.

**By format** — the three-view winner tagging from §Research Design.

- AL-only, NL-only, mixed — each with MAE + Spearman

### Secondary metric: team-level Spearman ρ (cross-check)

The Podhorzer & Bulay team-total-vs-standings Spearman ρ protocol is retained as a
secondary cross-check:

1. For each held-out league-year, sum predicted $ per team across rostered players.
2. Correlate `team_total_value` with that team's final standings points.
3. Report Spearman ρ across all held-out league-years.

Literature reference points from Podhorzer & Bulay (Fangraphs, 50-league study):

| System | Correlation |
|--------|-------------|
| SGP (Winning Fantasy Baseball denoms) | 0.9697 |
| Z-scores | 0.9670 |
| Suggested ceiling | ~0.98–0.99 |

**Cross-check divergence flag:** a candidate that wins player-level MAE but loses
team-level Spearman is flagged for investigation — it may be aggressively mis-pricing
stars in ways that cancel in per-player averages but accumulate when summed per team.
The reverse flag also applies.

### Multi-objective acceptance

Candidates are evaluated in tiers:

1. **Player-level MAE (primary gate):** candidate must improve aggregate MAE by ≥ **TBD**
   AND not regress per-format MAE by more than **TBD** (per-phase; see §Experiment
   Protocol for tighter thresholds in later phases).
2. **Team-level Spearman ρ (cross-check gate):** candidate must not regress team-level ρ
   by more than **TBD**.
3. **Sub-pool and per-position diagnostics:** reported for every accepted candidate as
   quality signals, not hard gates.

Candidates that are **Pareto-better** on both player-level MAE and team-level Spearman
are the preferred winner class. Candidates improving one metric at the cost of the
other are surfaced explicitly for human review rather than auto-accepted.

---

## Layer 1 — Synthetic Validation (handled by statsclaw)

Per-function synthetic validation is handled by statsclaw's `simulator` and `tester`
pipelines on each function's feature branch. The `simulator` pipeline designs a DGP,
runs Monte Carlo simulations, and verifies that the function recovers the known truth
within tolerance. The `tester` pipeline independently validates behavior against the
function's `test-spec.md`.

**Gate:** Do not proceed to Layer 2 until every function under test (`sgp_denominators`,
`replacement_level`, `dollar_values`, plus any method-layer functions added after the
spec walkthrough — `par`, `zar`, `zaa`, `pvm`) has a green statsclaw simulator + tester
run merged to `develop`. statsclaw is the single source of truth for per-function
correctness; this plan does not re-spec that validation.

---

## Layer 2 — Multi-League LOYO (Primary)

**Purpose:** Drive method selection. This is the primary evaluation layer — all grid
experiments run here and method rankings are determined by Layer 2 results.

### Data sources

| Dataset | Years | Formats | Role |
|---------|-------|---------|------|
| Tout Wars | 2013–2025 (13 seasons) | AL-only, NL-only, mixed | Primary — drives method selection |
| LABR | 2020–2025 (6 seasons) | AL-only, NL-only, mixed | Secondary — cross-validates Tout Wars winners |

Approximate sample size: **~57 league-years of expert-drafted auction records across
three formats.** Roughly 10× the 6-season single-league footprint of the original plan.

**Data scraping dependency:** Tout Wars and LABR full auction records — plus
per-league-year configuration (teams, budget, roster slots, scored categories) — are
not yet assembled in the repo. Scraping and normalization is a prerequisite task,
tracked as a dependency for Layer 2 activation.

NFBC average auction values are not used in this layer. Individual NFBC drafts are not
available; NFBC can support neither player-level earned-$ scoring (requires per-player
stats, which aren't affected by draft data) nor team-total correlation (requires
per-league roster lists, which NFBC averages do not provide).

### Protocol

**Leave-one-year-out cross-validation** across Tout Wars + LABR seasons, stratified by
format:

- Calibrate any year-spanning parameters (e.g., SGP denominators if applicable) on the
  remaining seasons within the same format.
- Apply to the held-out year; compute per-format MAE against earned $.
- Aggregate per-format MAE across all held-out years for each (format × method ×
  configuration) triple.
- Report three views per §Three-View Winner Tagging (aggregate / consistency /
  deployment).
- Secondary: compute team-total-vs-standings Spearman ρ per league-year; aggregate to a
  league-level mean per the Podhorzer & Bulay protocol.

**Year weighting:** Equal weight across all seasons for the loss function. Era-stratified
MAE (pre-2023 vs. post-2023) is reported as a diagnostic. Time-based holdout test
(fit 2013–2022, predict 2023–2025) recommended as an era-shift detection probe (TBD
whether included in default reporting).

**Format handling:** Per-format MAE is always reported. A winning method must satisfy
per-phase acceptance rules across all three formats (see §Experiment Protocol). Library
default-policy (which view's winner ships as the package default) is TBD — likely
consistency winner with config-selectable deployment override.

### Search space

See §Search Space (below) for the curated-grid dimensions. The agent executes a full
Cartesian over curated variants per axis, not sequential-greedy phase-by-phase tuning.
Grid cardinality per axis is TBD but approximately: ~5 methods × ~20 replacement
variants × ~10 denom configs × ~3 allocation × ~4 weighting ≈ 12K combinations.

---

## Layer 3 — Deployment Validation (Moonlight Graham)

**Purpose:** Confirm the Layer 2 winner performs on the deployment target (Moonlight
Graham, AL-only, keeper). This is a post-selection validation check, not an alternative
method-selection driver.

### What we measure

For the Layer 2 winner only (not every candidate):

1. Apply the winning valuation method and configuration to each Moonlight Graham
   player-season.
2. Compute player-level earned-$ MAE against MG earned $.
3. Compute team-total-vs-standings Spearman ρ as secondary cross-check.
4. Report MG-specific sub-pool (top-30 / top-100 / mid / $1) and per-position
   breakdowns per §Primary Metric.

### Keeper handling

MG is a keeper league, but keepers are out of scope for this validation:

- **Earned-$ MAE is keeper-agnostic** — a player's earned value from realized stats is
  the same whether they were a keeper or an auction pick. MG is valid for earned-$
  validation.
- **MG auction prices are keeper-contaminated** (a $5 keeper with $25 value isn't a
  market signal). Do *not* use MG auction prices as market ground truth at any point.
- **Keeper-aware bid adjustments** belong in a separate function (provisionally
  `bid_ceiling()`) that takes base valuations plus roster state and budget as inputs.
  That function is not part of this evaluation and is deferred to a later spec.

### Evaluation protocol

**Leave-one-year-out cross-validation** across usable MG seasons (2017–2025 excluding
2020 COVID season):

| Year | Role | Notes |
|------|------|-------|
| 2017 | Calibration / held-out | |
| 2018 | Calibration / held-out | |
| 2019 | Calibration / held-out | Full 162-game season |
| 2020 | **Excluded** | 60-game COVID season — unrepresentative |
| 2021 | Calibration / held-out | Full season |
| 2022 | Calibration / held-out | Full season |
| 2023 | Calibration / held-out | Full season |
| 2024 | Calibration / held-out | Full season |
| 2025 | Calibration / held-out | Full season |

Any year-spanning calibration (e.g., SGP denominators) uses MG data only for this layer
— the Layer 2 winner's *structure* is preserved, but calibration inputs come from MG.

### Data sources

| File | Purpose |
|------|---------|
| `~/roto-models/data/player_valuations_{year}.csv` | Actual player stats and team assignments |
| `~/roto-models/data/historical_standings.csv` | Final roto points by team and category |

### Gap investigation

**Large Layer 2 → Layer 3 gaps are diagnostic signals, not re-optimization targets.**
Investigate causes before any remediation:

- AL-only distributional quirks in MG beyond the AL-only Tout Wars / LABR cross-section
  (team count, budget allocation, scored categories — note whether MG's format specifics
  differ from Tout Wars AL-only).
- Implementation bugs that surface only in the MG deployment data pipeline.
- Pool construction differences (MG's keeper-adjusted active pool vs. open Tout Wars
  pool).

Layer 3 does not re-open method selection. If a Layer 2 winner fails Layer 3, the
response is to (a) debug the data/implementation gap, or (b) expose MG-style leagues
as a config override using Layer 2's deployment-view winner — not to re-run the grid
on MG data.

---

## Layer 4 — Sensitivity Analysis

**Purpose:** After Phases 1–5 identify the best-performing configuration, determine which
parameters drove the improvement and which were insensitive. Runs once, at the end.

**Method:**
1. Take the best configuration from Phase 5.
2. Perturb each parameter by ±1 step in its sweep range (OAT — one at a time).
3. Recompute SGP and rank all players under the perturbed configuration.
4. Report the percentage of player rankings that shift by > 5 positions under each
   perturbation.

**Output:**
- **High rank-shift:** Document as "tune this"; include per-category override guidance
  where applicable.
- **Flat:** Document as "default is fine — unlikely to matter for most leagues."

This informs which parameters need active calibration guidance in user-facing documentation
vs. which can be left at their defaults with confidence.

---

## Search Space

The design choices below are organized by subsystem. The agent should work through them
roughly in priority order — higher-impact decisions first, fine-tuning last. The same
search space applies to both Layer 2 and Layer 3.

---

### 1. Valuation Method (highest leverage)

The top-level choice: how player stats are converted to dollar values.

| Choice | Description |
|--------|-------------|
| **SGP** (baseline) | Stats-per-game-point; empirically calibrated to this specific league's standings history |
| **Z-score** | Player's z-score relative to replacement pool across all scored categories |
| **Hybrid α** | `α × normalized_SGP + (1-α) × z_score` per player, where α ∈ {0.25, 0.5, 0.75} |

**What to explore:**
- Establish SGP baseline correlation first
- Run z-score as a direct comparison
- If neither dominates, test hybrid blends at α = 0.25, 0.5, 0.75
- Carry the winner (or best blend) into subsequent subsystem exploration

---

### 2. SGP Denominator Estimation

SGP denominators are the "points gained per one unit of a stat." The Fangraphs study found
these are the single most impactful variable in SGP-based systems — wrong denominators moved
a system from 1st to 7th place.

#### 2a. Estimator method

| Choice | Description | Known issue |
|--------|-------------|-------------|
| **Pairwise mean** (spec default) | Average of all pairwise differences between adjacent teams in standings | Correct per spec; robust to non-linear effects |
| **OLS regression** | Regress category stat on category points to get slope | Biased upward per code audit (F3) — test to quantify how much |
| **Trimmed pairwise mean** | Pairwise mean with 10% of extreme pairs trimmed | May improve stability in seasons with outlier teams |

#### 2b. Calibration window

| Choice | Description |
|--------|-------------|
| **3 years** | Most recent 3 seasons only |
| **5 years** | Most recent 5 seasons |
| **All available** | All non-excluded seasons (up to 6 years in LOYO) |

**Hypothesis:** Recent seasons may be more informative (SB norms changed dramatically post-2023);
but small windows add variance. Test all three.

#### 2c. Time decay weighting

| Choice | Description |
|--------|-------------|
| **Flat** (baseline) | All years weighted equally |
| **Linear decay** | Weight = (year_rank / n_years), most recent = 1.0 |
| **Exponential decay λ=0.9** | Weight = 0.9^(years_ago) |
| **Exponential decay λ=0.7** | More aggressive — recent years dominate |

**Motivation:** SB denominator likely shifted structurally after 2023 rule changes. Heavier
recent weighting may capture this without discarding older ERA/WHIP signal.

#### 2d. Outlier season handling

| Choice | Description |
|--------|-------------|
| **Exclude 2020** (baseline) | COVID season already excluded |
| **IQR filter** | Exclude any season where a team's category total is > 1.5 IQR from median |

#### 2e. Rate stat SGP method

Two approaches exist for converting ERA, WHIP, and AVG into standings-point units before
summing into total_sgp:

| Choice | Description |
|--------|-------------|
| **Blended average-team pool** (Smart Fantasy Baseball / FanGraphs) | Player is blended into an assumed average team: `ERA_SGP = ((pool_ER + player_ER) × 9 / (pool_IP + player_IP) − avg_ERA) / −era_denom`. Pool constants derived from league history. More accurate; requires pool context. |
| **Fixed baseline counting equivalent** (Zola / Benson / Mosey) | Convert to counting-stat equivalent first: `ExER = (baseline_ERA × player_IP / 9) − player_ER`, then divide by an ExER-per-point denominator. Roster-agnostic; denominator must be calibrated in counting-equivalent units. |

For the blended pool method, also test the three `pool_baseline` sub-options:

| `pool_baseline` | Description |
|-----------------|-------------|
| `"projection_pool"` (default) | Pool derived from top-N projected pitchers/batters by playing time |
| `"per_player"` | Pool recomputed for each player by summing over all other projected players on an average roster |
| `"universal_constants"` | Fixed historical playing-time constants; requires no projection data |

**Experiment:** Test both top-level methods against LOYO correlation on Moonlight Graham
data. Hypothesis: blended pool is more accurate for typical rosters; fixed baseline may be
more robust in years with unusual team compositions. For blended pool, compare all three
`pool_baseline` options.

---

#### 2f. 2023 structural break — scope of effect

The 2023 shift ban and larger bases changed the run environment materially. The question is
not only whether pre-2023 SB denominators are contaminated, but whether R and RBI are also
affected enough that pre-2023 seasons should be downweighted or excluded.

| Choice | Description |
|--------|-------------|
| **Full window** (baseline) | All non-excluded seasons weighted equally; 2023 break absorbed by noise |
| **Post-2023 only for SB** | Truncate SB window to 2023+; use full window for R, RBI, HR, ERA, WHIP |
| **Post-2023 only for SB + R + RBI** | Broader truncation covering all categories plausibly affected by the rule changes |
| **Post-2023 only (all categories)** | Treat 2023 as a clean break for the entire run environment |

**Experiment protocol:** For each choice, compute LOYO correlation on all available years.
Also report year-over-year denominator change (2022→2023 vs. other adjacent years) for each
category — a large 2022→2023 jump relative to historical year-over-year variance is evidence
the break is real and material for that category.

**Hypothesis:** SB is the most affected. R and RBI may show a moderate break. HR, ERA, and
WHIP are less likely to be structurally changed. Empirical testing should confirm or reject
this ordering before any default truncation policy is set.

---

### 3. Replacement Level (high leverage, many open questions)

Replacement level is the zero-dollar baseline: a player at replacement level contributes $0
to auction value. Every dollar of positive value is production *above* this line. Getting
the baseline wrong misprices every player in the pool.

See `specs/spec-replacement.md` for the full conceptual spec and open questions.

#### 3a. Boundary definition

| Choice | Description |
|--------|-------------|
| **Exact boundary** | Single player at rank `n_teams × roster_slots[pos]` |
| **Band ±3** | Mean stat line of 7 players centered on boundary (±3 either side) |
| **Band ±5** | Mean stat line of 11 players centered on boundary |
| **Band = 10% of pool** | Band width scales with position pool depth |

**Motivation:** Single boundary player is sensitive to one outlier projection. A band
smooths this. However, wide bands on thin positions (C: ~10 AL catchers total) may
absorb talent well above/below the true replacement line.

#### 3b. Player ranking (sort key for boundary identification)

| Choice | Description | Trade-off |
|--------|-------------|-----------|
| **Z-score** (default) | Rank by composite z-score before computing replacement | No circular dependency; fast |
| **SGP (1 pass)** | Rank by SGP using prior-year denominators | Slightly more accurate; requires prior-year SGP |
| **SGP (iterative, warm-start)** | Seed pass 1 with within-position rank order only; subsequent passes use `dollar_values()` assignments; stop when assignment is stable and max stat change < ε | Most accurate; eliminates the circularity in the first-pass z-score approach (see `replacement_solutions.md` Issue 1) |
| **Historical priors** | Seed replacement levels from pooled historical actuals (2021–2024); iterate to refine with current projections | More stable year-to-year; lags structural changes |

**Note on "SGP (iterative, warm-start)":** The existing "3 passes" framing is replaced here by a principled convergence criterion. Convergence = assignment stable + max stat change < 0.01 SGP; hard cap at 25 passes.

#### 3c. Positional adjustment method

How the cross-position adjustment (scarcity premium) is computed. The formula is:

```
scarcity_premium[pos] = global_replacement − replacement[pos]
```

The critical question is *what units* this is computed in and what "global_replacement" means.
See `replacement_solutions.md` Issue 2 — averaging per-position z-scores is statistically
incoherent; the research consensus is that this should be done in SGP or dollar units.

| Choice | Description |
|--------|-------------|
| **Slot-weighted z-score mean** (current spec) | `Σ(slots[pos] × repl_zscore[pos]) / Σ(slots)` — statistically incoherent (see Issue 2) but testable as a baseline |
| **SGP-unit weighted mean** | Compute each position's replacement stat line in SGP units, take slot-weighted mean; adjustments are in standings-points currency | 
| **Dollar-space normalization** | Convert each position's FVARz to dollars via `(FVARz / total_positive_FVARz) × budget`; cross-position comparison happens in dollar space |
| **PosFact blending** | `α × (stat − pos_avg) + (1−α) × (stat − global_avg)` where α ∈ {0.25, 0.5, 0.75, 1.0}; α=1 is fully positional, α=0 is fully global (Razzball approach) |
| **Median** | Median across position replacement z-scores; robust to thin-pool distortion at C/SS |

**Recommended default to test first:** SGP-unit weighted mean, since it produces interpretable
adjustments and avoids distributional incompatibility. PosFact α sweep is a secondary experiment.

#### 3d. SP/RP separation

| Choice | Description |
|--------|-------------|
| **67/33 SP/RP default** | 7 SP slots, 2 RP slots (with 9 pitcher slots) |
| **IP threshold 80** | Pitchers with projected IP ≥ 80 classified as SP |
| **IP threshold 100** | Standard threshold |
| **IP threshold 120** | Conservative — only true starters classified as SP |

**Hypothesis:** The correct threshold interacts with replacement level directly. A high
threshold undersupplies SP (inflating SP value); a low threshold oversupplies it.

#### 3e. Catcher adjustment

AL-only leagues have ~10 viable catchers. The shallow pool inflates catcher z-scores and
often produces modeled prices that exceed what the market actually pays.

| Choice | Description |
|--------|-------------|
| **None** (baseline) | No catcher-specific adjustment |
| **0.75× discount** | Multiply catcher PAR by 0.75 (Priceguide convention) — patches the symptom without diagnosing the cause |
| **Historical price calibration** | Fit a scaling factor from observed auction prices for catchers across historical seasons |
| **Positional adjustment only** | Let the positional adjustment absorb scarcity naturally; no explicit discount |
| **Split pool** | Separate catchers into their own pool with independent z-scores and a budget allocation proportional to catcher roster slots; no cross-pool contamination (RotoWire Z-Files recommendation; see `replacement_solutions.md` Issue 4 Solution A) |

**Run diagnostic first:** Before testing these options, compute `position_sd_ratio` (each
position's within-pool SD / global SD) across scored categories. A catcher SD ratio well
below 1.0 indicates pool-compression as the root cause (fix the pool construction); a ratio
near 1.0 points to genuine scarcity premium (test split pool or calibrated discount).

#### 3f. Cliff detection

When computing band-based replacement, a talent cliff between adjacent band members may mean
the band spans a genuine talent gap. Cliff detection truncates the band at the cliff.

Two orthogonal choices: whether to enable cliff detection, and if enabled, how to estimate
the scale (σ or equivalent) used in the threshold test.

**Detection enabled/disabled and threshold:**

| Choice | Description |
|--------|-------------|
| **Disabled** (baseline) | Use full band regardless of within-band variance |
| **Enabled, threshold = 1.5** | Truncate band if adjacent-player drop exceeds threshold × scale |
| **Enabled, threshold = 1.0** | More sensitive — catches shallower cliffs |

**Scale estimation method (only applies when enabled):**

| Choice | Description |
|--------|-------------|
| **MAD over full 2K+1 band** | `mad(band_values) * 1.4826`; 50% breakdown point; base R `stats::mad()`; robust to the very outlier you're trying to detect (recommended; see `replacement_solutions.md` Issue 5) |
| **Global position pool SD** | SD of all N players in the full position pool; larger sample, more stable, but less sensitive to within-band structure |
| **Gap-to-range ratio** | `gap / range(band_values)`; scale-free, no distributional assumptions; threshold recalibration required (~0.35–0.40) |
| **Fisher-Jenks 2-class split** | Optimal 1D k-means split of band values; no σ estimation needed; always finds a split (`classInt` package) |

**Note:** The existing spec's σ source is undefined — the scale estimation method is a real
design choice that will affect which cliffs are detected. The threshold value (1.5 vs. 1.0)
interacts with the scale method and should be swept jointly.

#### 3g. Rate stat quality/volume separation

How ERA and WHIP are weighted when ranking pitchers for boundary detection. The current
spec normalizes by `expected_team_IP`, which makes a pitcher's ranking sensitive to league
pitching depth — a methodological flaw (see `replacement_solutions.md` Issue 3).

| Choice | Description |
|--------|-------------|
| **IP-normalized by team total** (current spec) | `(repl_ERA − pitcher_ERA) × pitcher_IP / expected_team_IP` — ranking is league-depth-sensitive; borderline swingmen rank differently in 10-team vs. 15-team leagues |
| **Raw IP-weighted quality** (recommended) | `(repl_ERA − pitcher_ERA) × pitcher_IP` — quality is absolute; volume scaling happens only in `sgp()` downstream. Mirrors FanGraphs WAR's explicit quality/volume separation |
| **SGP fixed-baseline-pool** | ERA SGP via `((baseline_ER + pitcher_ER) × 9 / (baseline_IP + pitcher_IP) − lg_avg_ERA) / ERA_denom`; baseline is the other 107 rostered pitchers held constant across rankings (Todd Zola / Smart Fantasy Baseball approach) |

**Note:** `expected_team_IP` should be retained in the interface solely for the divergence
warning check (projection-vs-historical calibration), not as a ranking input.

#### 3h. Replacement parameter sweep (constants calibration)

All numeric constants in the replacement algorithm are currently asserted without empirical
basis. These should be swept via OAT sensitivity analysis using the LOYO framework.

| Parameter | Current default | Sweep range | Notes |
|-----------|----------------|-------------|-------|
| Band half-width K | 3 | 1, 2, 3, 4, 5 | Dynamic cap: `min(K, floor(n_rostered_pos / 4))` prevents band > 25% of pool in thin positions |
| Cliff threshold | 1.5 | 0.5, 1.0, 1.5, 2.0, 2.5 | Interacts with scale estimation method (3f) |
| Cliff min-N (disabled below) | 4 | 3, 4, 5 | |
| SP/RP IP threshold | 100 | 80, 90, 100, 110, 120 | Validate with bimodal mixture model on projection data |
| Default SP/RP split | 67/33 | 50/50, 60/40, 67/33 | Infer from historical roster actuals when possible |
| Calibration min-N ($1 pool) | 15 | 10, 15, 20, 25 | Standard minimum for mean estimation is ~20–25 |

**Sweep protocol:** OAT — hold all others at current default, vary one at a time; record
Spearman ρ and $1-pool bias (mean projected value for players who actually sold for $1).
Low-sensitivity constants (ρ flat across sweep) can keep their defaults; high-sensitivity
constants need empirical calibration.

---

### 4. Dollar Allocation

After PAR is computed for every player, PAR is converted to dollars. The total positive-PAR
pool is scaled to fit the known auction budget.

#### 4a. Hitter/pitcher spending split

| Choice | Description |
|--------|-------------|
| **Empirical** (recommended) | Derived from historical Moonlight Graham auction logs; recalculated each year |
| **Fixed 67/33** | 67% to hitters, 33% to pitchers — common industry default |
| **Fixed 70/30** | Slightly hitter-heavy split |

**Note:** `auction_log_2026.csv` and prior auction data exist in the data directory. Empirical
splits are computable for each season. This is likely low-variance — test empirical vs.
fixed to confirm.

#### 4b. Minimum pre-allocation

Standard practice: reserve $1 per rostered player before computing `dollars_per_par`.

| Choice | Description |
|--------|-------------|
| **$1 × n_rostered** (standard) | Reserve minimum salary before allocating remaining budget |
| **$0.50 × n_rostered** | Smaller reserve — more dollars flow to PAR pool |

---

### 5. Category Weighting (lower leverage, test last)

Standard roto valuation weights all categories equally. The question is whether differential
weighting improves correlation with standings.

| Choice | Description | Hypothesis |
|--------|-------------|------------|
| **Equal weights** (baseline) | 1.0 × each category | Standard; probably hard to beat |
| **Stability weights** | Weight ∝ year-over-year stability of team category totals; penalize volatile categories (SB) | More stable categories better predict final standings |
| **Spread weights** | Weight ∝ cross-team standard deviation in category; emphasize categories where teams differ most | High-spread categories separate teams; low-spread categories are noise |
| **Learned weights** | Fit category weights to maximize LOYO correlation on training years | Risk of overfitting with only 6 seasons |

**Caution:** Learned weights with 6 seasons and 10 categories are likely overfit. Run this
last and evaluate carefully against the held-out years.

---

## Experiment Protocol

The protocol runs in five phases: synthetic validation gate, variant curation, curated
grid on Layer 2, deployment validation + sensitivity analysis, and optional autoresearch
extension. The phase numbering reflects execution order; phases are not sequential
tuning rounds in the old sense. Method selection and parameter tuning happen jointly
inside the Phase 2 grid.

### Phase 0 — Per-function Validation (prerequisite, handled by statsclaw)

Run before any real-data phases. Per-function simulator + tester validation is owned by
statsclaw on each function's feature branch (see §Layer 1). One additional harness-level
check belongs to this plan, not to any single function:

1. **Harness earned-$ recovery:** given a synthetic player pool with a known stat-to-dollar
   mapping, verify that the autoresearch harness's earned-$ computation recovers the true
   values within rounding tolerance.
2. **Gate: statsclaw simulator + tester green on `develop` for every function under test,
   AND harness earned-$ recovery passes → proceed to Phase 1.**

### Phase 1 — Variant Curation (prerequisite to grid)

Claude proposes curated variants spanning the design space of the §Search Space
subsections; user reviews and approves before the grid runs. Target cardinalities
(TBD-approximate):

- **Replacement-level variants (~20):** proposals drawn from §3 — boundary × sort key ×
  positional adjustment × SP/RP threshold × catcher handling × cliff detection × rate-stat
  quality/volume. Informed by `specs/spec-replacement.md` and `replacement_solutions.md`.
- **Denominator configurations (~10):** drawn from §2 — estimator × window × decay ×
  rate-stat method × 2023-break scope.
- **Allocation configurations (~3):** drawn from §4.
- **Weighting configurations (~4):** drawn from §5.
- **Methods (~5):** SGP, z-score, hybrid α ∈ {0.25, 0.5, 0.75}, plus any of PVM / ZAA /
  ZAR / PAR that the spec walkthrough classifies as distinct top-level methods. Final
  method axis TBD pending spec classification.

**Grid cardinality:** ~5 methods × ~20 replacement × ~10 denom × ~3 allocation × ~4
weighting ≈ 12K combinations. Exact cardinality TBD.

### Phase 2 — Curated Grid on Layer 2

Execute full Cartesian over curated variants per axis against the Layer 2 dataset
(Tout Wars + LABR), per the Layer 2 Protocol.

Per combination, the harness computes and logs:

- Player-level MAE per format (AL-only / NL-only / mixed); aggregate mean and max across formats.
- Spearman rank ρ per format; aggregate mean and max.
- Sub-pool MAE (top-30 / top-100 / mid / $1).
- Per-position MAE.
- Era-stratified MAE (pre-2023 vs. post-2023).
- Secondary: team-total-vs-standings Spearman ρ per league-year.

Results logged to `autoresearch.jsonl` or equivalent harness output.

**Tiered acceptance rule (thresholds TBD, phase-depth dependent):**

| Gate | Condition |
|------|-----------|
| Primary | Aggregate player-level MAE improves by ≥ **$TBD** vs. incumbent |
| Per-format guardrail | No single-format MAE regresses by more than **$TBD** (looser for initial method exploration, tighter for within-method parameter tuning) |
| Cross-check | Team-level Spearman ρ does not regress by more than **TBD** |
| Pareto flag | Candidates improving one view but regressing another are surfaced for human review rather than auto-accepted |

Winners tagged per §Three-View Winner Tagging (aggregate, consistency, deployment).

### Phase 3 — Deployment Validation (Layer 3)

Apply the Layer 2 winner(s) to Moonlight Graham data per §Layer 3. Report gap metrics
and investigate any material divergence. Layer 3 does not re-open method selection.

### Phase 4 — Layer 4 Sensitivity Analysis

Run once, after the winner commits:

1. Perturb each parameter by ±1 step in its sweep range (OAT).
2. Recompute valuations and rank all players under each perturbation.
3. Record percentage of player rankings that shift by > 5 positions.
4. Classify parameters as high-sensitivity ("tune this") or flat ("default is fine").
5. Feed results into user-facing documentation guidance.

### Phase 5 — Autoresearch Extension (optional)

Once the curated grid establishes a Pareto frontier, an autoresearch agent may extend
beyond it. Agent proposals include new methods, refinements to existing methods'
internals, or replacement-level variants outside the curated set. Accepted proposals
follow the same tiered acceptance rule as Phase 2. Not gated to the same timeline as
Phases 0–4.

---

## Files the Agent May Modify

| File | What to modify |
|------|---------------|
| `R/sgp.R` | SGP denominator estimator, calibration window, time decay |
| `R/replacement.R` | Boundary definition, sort key, band width, catcher adjustment |
| `R/par.R` | PAR arithmetic (once specced); hitter/pitcher split hooks |
| `R/zar.R` | Z-score above replacement (once specced); pooling, standardization window |
| `R/zaa.R` | Z-above-average (once specced); baseline choice |
| `R/pvm.R` | Percent-value method (once specced); tier anchors |
| `R/dollar_values.R` | Budget allocation, minimum allocation, iteration logic, hybrid-α blend |
| `autoresearch.sh` | Benchmark runner — should not need modification |
| `autoresearch.jsonl` | Experiment log — written by the agent automatically |

The exact set of method-layer files (`par.R`, `zar.R`, `zaa.R`, `pvm.R`) is **pending
the spec walkthrough** (see Open Questions). Some of these may be collapsed into
`dollar_values.R` or a single `methods.R` depending on spec outcomes.

**Do not modify:**
- `plans/autoresearch-valuation.md` (this file)
- `data/` files (read-only ground truth)
- `tests/` (existing tests must continue to pass)

---

## Stopping Rules

The primary optimization target is **player-level earned-$ MAE** (lower is better); the
secondary cross-check is **team-total vs. standings Spearman ρ** (higher is better). The
curated grid in Phase 2 evaluates all ~12K configurations exhaustively — there is no
early-stop during Phase 2 enumeration. Stopping rules apply to the *winner selection*
and to any post-grid autoresearch extension (Phase 5).

**Multi-objective acceptance (Phase 2 winner selection):**

- **Accept** a candidate as a new best only if it improves primary MAE by **≥ TBD-ε_mae**
  without regressing secondary Spearman ρ by more than **TBD-δ_rho**
- **Tie-break** equal-MAE candidates by (a) higher Spearman ρ, then (b) lower worst-format
  MAE (deployment robustness), then (c) simpler configuration (fewer non-default axis
  settings)
- **Three-view winners** are selected separately using:
  - Aggregate: lowest mean MAE across leagues × years
  - Consistency: lowest worst-case (max) MAE across any single league-year
  - Deployment: lowest MAE on Moonlight Graham (Layer 3) specifically

**Phase-level stops:**

- **Phase 2 (grid)** — runs to completion; no early-stop. Report all three view winners.
- **Phase 3 (MG deployment)** — runs only the top-K candidates from Phase 2 (K TBD,
  candidate values 5 / 10 / 20); no early-stop within that set.
- **Phase 4 (sensitivity)** — one-at-a-time perturbation on the selected consistency
  winner; runs to completion across the perturbation list.
- **Phase 5 (autoresearch, optional)** — stops when 10 consecutive agent-proposed
  variants fail the multi-objective acceptance rule, OR when TBD-max-experiments is
  reached, whichever comes first.

**Numerical thresholds** (TBD-ε_mae, TBD-δ_rho, TBD-K, TBD-max-experiments) will be
resolved empirically after a pilot run on a single LOYO fold — the scale of natural
MAE variance across the grid determines a meaningful improvement threshold. Until then,
they are recorded as TBDs rather than guessed.

---

## Open Questions Deferred to Validation (not part of this search)

These questions cannot be resolved by MAE optimization alone — they require separate
validation, upstream data work, or explicit scope decisions.

### Scope & methodology

- **Keeper handling is out of scope.** The valuation functions under test produce
  keeper-agnostic earned-$ and bid-ceiling baselines. Keeper discounts (strategic bid
  adjustments based on league keeper rules, inflation, and roster construction) are
  deferred to a separate future `bid_ceiling()` or `keeper_adjustment()` function.
  Moonlight Graham Layer 3 evaluation uses MG's **keeper-agnostic earned-$** only; MG's
  auction prices are contaminated by keeper economics and are not used as ground truth.
- **Projection source (for eligibility filter) is TBD.** The draftability filter
  requires a preseason projection (PA ≥ 100/150/200/250, IP ≥ 30/50/80). The specific
  projection source (Steamer, ZiPS, THE BAT, composite) is unresolved; sweep is
  expected across the candidate thresholds but projection-source choice itself is a
  separate data-sourcing question.
- **Method axis membership pending spec walkthrough.** Which of SGP / Z-score / PVM /
  PAR / ZAR / ZAA / hybrid-α are *methods* (top-level search axis values) vs.
  *components* (parameterizations within another method) vs. *variants* (same method
  under a different name) is pending the walkthrough of `specs/spec-sgp.md`,
  `specs/spec-replacement.md`, `specs/spec-par.md`, `specs/spec-zar.md`,
  `specs/spec-zaa.md`, `specs/spec-pvm.md`, `specs/spec-dollar-values.md`. The method
  axis listed in §Search Space is a working assumption until that walkthrough
  completes.
- **Library-default policy is TBD.** The three-view winner tagging produces an
  aggregate winner, a consistency winner, and a deployment winner. Which of these (or
  which combination) becomes the shipped library default, and whether non-winner
  configurations are exposed as named presets, is a post-experiment decision.

### Data dependencies

- **Tout Wars and LABR data scraping not yet done.** Layer 2 (primary evaluation)
  depends on scraping Tout Wars 2013–2025 and LABR 2020–2025 auction and final-stat
  tables. No experiments can run until that data is ingested and validated. Roster
  snapshot date must be verified (opening-day rosters preferred; see
  `plans/autoresearch-methodology-critiques.md` Critique 4).
- **Moonlight Graham 2017–2025 is AL-only.** Layer 3 deployment validation is AL-only
  until NL-only MG data or a second keeper league is added. Any NL-only behavior is
  untested in Layer 3.

### Numerical thresholds (TBD until pilot run)

- **TBD-ε_mae** — minimum MAE improvement to accept a new winner (Phase 2)
- **TBD-δ_rho** — maximum allowed Spearman ρ regression when accepting an MAE-better
  candidate
- **TBD-K** — number of Phase 2 candidates promoted to Phase 3 deployment validation
- **TBD-max-experiments** — cap on Phase 5 autoresearch extension
- **$1 pool calibration window** — trimmed-mean band for $1-player diagnostic
  (addresses Critique 1); set after the first pilot grid reports actual $1-pool MAE
  distribution

All TBDs are resolved empirically after a single LOYO-fold pilot run; rather than
guess thresholds now, the plan is to observe the natural scale of MAE and ρ variance
across the grid and pick thresholds that separate meaningful differences from noise.

### Post-implementation validation checks (not autoresearch experiments)

- Positional adjustment sign direction (C/SS positive, OF/1B negative) — unit-tested
  after implementation. `scarcity_premium["C"] > 0` and `scarcity_premium["OF"] <= 0`
  for a standard AL-only league fixture.
- Budget reconciliation: total positive-PAR pool within ~$5 of actual auction budget —
  diagnostic at end of each phase.
- Two-way player value formula: `hitter_PAR + pitcher_PAR − 1` (Pitcher List
  formulation) is not testable via Layer 2/3 since neither data source has two-way
  players; validate against Ottoneu leagues if extending scope.
- Pool SD diagnostic (`position_sd_ratio` by position/category) — run once on
  historical data to identify catcher inflation drivers before committing to a catcher
  adjustment method; prerequisite diagnostic, not an experiment.
- SP/RP threshold empirical validation — fit a bimodal mixture model
  (`mixtools::normalmixEM`) to actual pitcher IP distributions from 5 years of
  Steamer/ZiPS projections; use the empirical trough as the default rather than the
  round-number 100.

---

## Interpreting Results

The primary metric is **player-level earned-$ MAE** — how close the system's value gets
to each player's realized end-of-season auction value, averaged across the eligible
pool. The secondary metric is **team-total vs. standings Spearman ρ** — a coarser
signal that a system's total-value sums order teams correctly, which is necessary but
not sufficient for individual-player accuracy.

**Low MAE** means individual player dollar values are accurate. **High ρ** means the
system correctly orders teams by quality. A system can achieve high ρ while producing
poor individual values (e.g., systematically misprices $1 players but gets totals
right) — this is precisely the Critique 1 failure mode. Reporting both, with MAE as
primary, guards against that.

### Diagnostic breakdowns for every Phase 2/3 winner

- **Sub-pool MAE**: top-30, top-100, mid-tier, $1-pool separately. The $1-pool
  diagnostic explicitly addresses Critique 1 — a well-calibrated system projects ~$1
  for players who actually earned $1.
- **Per-position MAE**: C, 1B, 2B, 3B, SS, OF, DH, SP, RP.
- **Per-format MAE**: AL-only, NL-only, mixed — always reported regardless of which
  view tagged the winner.
- **Era-stratified MAE**: pre-2023 vs. post-2023. MLB rule changes (shift ban, larger
  bases) may shift category volatility; stratification detects over-fit to one regime.
- **Budget reconciliation**: total positive-PAR pool vs. actual auction budget.

### Three-view winner comparison

Three winners are tagged independently per Phase 2:

- **Aggregate winner** — lowest mean MAE across leagues × years.
- **Consistency winner** — lowest worst-case MAE across any single league-year.
- **Deployment winner** — lowest MAE on Moonlight Graham (Layer 3).

**When they agree**, the shared configuration is a confident general default. **When
they diverge**, the divergence is itself the finding: the aggregate winner may be
over-fit to the dominant data source (Tout Wars), the consistency winner may be
robust-but-average, and the deployment winner may encode MG-specific behavior
(AL-only, shallow catcher pool, keeper-league roster construction). Divergences are
documented as configurable variants with guidance on when to select each, not
collapsed into a single "best" choice. Library-default policy (which view ships as the
default) is TBD.

### Scope caveats

- Results measure **inherent methodology quality given actual-stats inputs**
  (Critique 3). Pre-season projection error is not part of this benchmark — a separate
  validation using pre-season projections correlated with the same ground truth is
  required to estimate real-world auction performance.
- Raw system outputs are compared; strategic overlays (reliever discount,
  category-volatility-adjusted bids, keeper discounts) are out of scope and deferred
  to downstream `bid_ceiling()` / strategy functions (Critique 2).
- Moonlight Graham roster snapshot date must be verified (opening-day preferred;
  Critique 4). Season-end snapshots degrade ρ signal uniformly across candidates but
  do not bias relative rankings — they do cap the achievable ρ ceiling.
