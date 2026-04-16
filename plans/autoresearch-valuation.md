# Autoresearch Plan: Rotisserie Valuation Optimization

> **Goal:** Maximize the correlation between team-level pre-season auction dollar values and
> final rotisserie standings points, using Moonlight Graham historical data as the benchmark.
> The agent should iterate through the search space below, measure results against the
> benchmark, commit winners, and discard losers.

---

## Research Design

Validation proceeds in four layers. Layer 1 is a prerequisite gate — do not run real-data
experiments until it passes. Layers 2 and 3 run the same search space on different datasets.
Layer 4 runs once after the best configuration is found.

| Layer | Name | Data | Purpose |
|-------|------|------|---------|
| 1 | Synthetic validation | Simulated | Confirm implementation faithfulness before real-data exposure |
| 2 | Multi-league LOYO | Public leagues (aspirational) | Establish generally-valid defaults |
| 3 | Moonlight Graham LOYO | Moonlight Graham 2019–2025 | Optimize for this league; compare to Layer 2 |
| 4 | Sensitivity analysis | Moonlight Graham | Identify which parameters actually matter |

Comparing Layer 2 and Layer 3 results tells you whether a winning parameter is a strong
general default or a Moonlight Graham-specific choice:

- **Both layers agree** → document as a confident general default
- **Layers diverge** → document as "tune this" with guidance on when to override

---

## Layer 1 — Synthetic Validation

**Purpose:** Confirm each function is faithful to its spec before any real data touches it.
Run before Phases 1–5. Do not proceed if Layer 1 fails.

**Method:** For each function under test, generate synthetic inputs from a known
data-generating process, compute the expected output analytically, and verify recovery
within tolerance.

### SGP denominators

1. Draw team category totals from a known distribution (e.g., HR ~ N(220, 30²) for a
   12-team league over 5 seasons).
2. Compute the analytic true denominator from the DGP parameters.
3. Run `sgp_denominators()` and verify recovery within ±5%.
4. Repeat across 1,000 simulated seasons to estimate bias and variance.

Variants: OLS vs. gap (OLS should outperform under outlier teams); flat vs. exp_decay
(exp_decay should outperform under a trend DGP); window length 3 vs. 5 vs. all.

Edge cases: all teams tied, single-team outlier, zero-variance season, rounding in
counting-equivalent rate stat conversions.

### Replacement level

1. Generate a synthetic projection pool with known position-group stat distributions.
2. Verify that `replacement_level()` places the boundary at the correct rank for each
   position.
3. Test band averaging, cliff detection, and positional adjustment with known inputs.

### Dollar allocation

1. Generate synthetic PAR values with a known total positive-PAR pool.
2. Verify that `dollar_values()` allocates the budget correctly and that per-player values
   sum to the auction budget within rounding tolerance.

**Gate:** All functions must pass synthetic recovery tests before proceeding to Layer 3.

---

## Layer 2 — Multi-League LOYO (Aspirational)

**Purpose:** Determine which parameter choices are generally valid across leagues vs.
specific to Moonlight Graham. Aspirational — requires public league data not yet assembled.

**Design:** Same LOYO protocol as Layer 3, applied to a large multi-league public dataset.
Target: 50+ leagues × 10+ years.

**Data sources (aspirational):** NFBC, Fantrax public historical leagues.

**Search space:** Same as Layer 3 below. For each candidate configuration, compute mean
Spearman ρ across all held-out league-years.

**Output:** A per-parameter comparison table showing the Layer 2 winner vs. the Layer 3
winner. Parameters where the two layers agree are strong general defaults. Parameters
where they diverge are candidates for league-specific override guidance in the
documentation.

---

## Layer 3 — Moonlight Graham LOYO

This is the primary Moonlight Graham–specific evaluation and the main driver of
default-setting until Layer 2 data is available.

### What we are measuring

For each candidate valuation system:

1. Apply the system to each rostered player's **actual season stats** for year Y
2. Sum each team's player values → `team_total_value`
3. Correlate `team_total_value` with `total_pts` from final standings (Spearman ρ)
4. Repeat for each held-out year; report mean ρ across all held-out years

This follows the Fangraphs methodology (Podhorzer & Bulay) and isolates valuation method
quality from projection accuracy — actual stats are used, not pre-season projections.

### Evaluation protocol

**Leave-one-year-out cross-validation** across the 6 usable seasons:

| Year | Role | Notes |
|------|------|-------|
| 2019 | Calibration / held-out | Full 162-game season |
| 2020 | **Excluded** | 60-game COVID season — unrepresentative |
| 2021 | Calibration / held-out | Full season |
| 2022 | Calibration / held-out | Full season |
| 2023 | Calibration / held-out | Full season |
| 2024 | Calibration / held-out | Full season |
| 2025 | Calibration / held-out | Full season |

For each fold: calibrate SGP denominators on the remaining 5 years, apply to the held-out
year. Replacement level is computed from the held-out year's projection pool (as it would be
in practice). Dollar allocation uses the held-out year's empirical hitter/pitcher spend split.

### Data sources

| File | Purpose |
|------|---------|
| `~/roto-models/data/player_valuations_{year}.csv` | Actual player stats, team assignments, existing SGP values |
| `~/roto-models/data/historical_standings.csv` | Final roto points by team and category |

### Benchmark script

The benchmark outputs a single line to stdout:

```
METRIC correlation=0.971
```

Higher is better. The baseline (existing SGP implementation) should be measured first and
recorded as the floor — any candidate that beats it is a winner; any that falls below it
is discarded.

### Known reference points

From Podhorzer & Bulay (Fangraphs, 50-league study):

| System | Correlation |
|--------|-------------|
| SGP (Winning Fantasy Baseball denoms) | 0.9697 |
| Z-scores | 0.9670 |
| Suggested ceiling | ~0.98–0.99 |

The goal is to exceed 0.97 on Moonlight Graham data and push toward 0.98+.

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

### Phase 0 — Layer 1: Synthetic Validation (prerequisite)

Run before any real-data phases. Do not proceed until all synthetic tests pass.

1. Synthetic `sgp_denominators()` tests: recovery within ±5% across 1,000 simulated seasons
2. Synthetic `replacement_level()` tests: boundary placement, band averaging, cliff detection
3. Synthetic `dollar_values()` tests: budget allocation and sum-to-budget reconciliation
4. **Gate: all pass → proceed to Phase 1**

### Phase 1 — Establish baseline and method comparison (Layer 3)

1. Compute baseline correlation using existing SGP values from `player_valuations_*.csv`
2. Implement z-score method; measure correlation
3. Test hybrid blends at α ∈ {0.25, 0.5, 0.75}
4. **Carry forward the winning top-level method**

### Phase 2 — SGP denominator tuning (Layer 3, if SGP or hybrid wins)

1. Test estimator: pairwise_mean vs. OLS vs. trimmed pairwise mean
2. Test calibration window: 3, 5, all years
3. Test time decay: flat, linear, exponential (λ = 0.9, 0.7)
4. Test rate stat SGP method: blended average-team pool vs. fixed baseline counting equivalent (§2e)
5. For blended pool: test pool_baseline sub-options: projection_pool, per_player, universal_constants (§2e)
6. Test 2023 structural break scope: full window vs. post-2023 SB only vs. post-2023 SB+R+RBI vs. post-2023 all (§2f)
7. **Commit best denominator config**

### Phase 3 — Replacement level tuning (Layer 3)

Run the pool SD diagnostic first (`position_sd_ratio` by position) to determine whether
the catcher inflation is a pool-construction bug (fix before running any experiments) or
a structural scarcity effect (testable via the catcher adjustment options).

1. Test boundary definition: exact, band ±3, band ±5, band = 10% of pool (§3a)
2. Test sort key: z-score, SGP 1-pass, SGP iterative warm-start, historical priors (§3b)
3. Test positional adjustment method: slot-weighted z-score, SGP-unit weighted mean,
   dollar-space, PosFact α ∈ {0.25, 0.5, 0.75, 1.0} (§3c — run SGP-unit first)
4. Test SP/RP threshold: 80, 100, 120 IP (§3d)
5. Test rate stat quality/volume separation: IP-weighted vs. team-IP-normalized (§3g)
6. Test catcher adjustment: none, split pool, 0.75×, historical calibration (§3e)
7. Test cliff detection: disabled; if enabled, test MAD vs. gap-to-range vs. Fisher-Jenks
   scale method, and threshold ∈ {1.0, 1.5, 2.0} (§3f — sweep threshold jointly with method)
8. Constant sweep (§3h): K ∈ {1–5}, calibration min-N, SP/RP split default
9. **Commit best replacement config**

### Phase 4 — Dollar allocation (Layer 3)

1. Test hitter/pitcher split: empirical vs. fixed 67/33, 70/30
2. Test minimum pre-allocation: $1 vs. $0.50
3. **Commit if any improvement**

### Phase 5 — Category weighting (Layer 3, optional, run last)

1. Equal vs. stability weights vs. spread weights
2. Learned weights (check for overfit — requires held-out correlation to stay above baseline)

### Phase 6 — Layer 4: Sensitivity Analysis

Run once, after Phase 5 completes and the best configuration is committed.

1. Perturb each parameter by ±1 step in its sweep range (OAT)
2. Recompute SGP and rank all players under each perturbation
3. Record percentage of player rankings that shift by > 5 positions
4. **Classify parameters as high-sensitivity ("tune this") or flat ("default is fine")**
5. Feed results directly into user-facing documentation guidance

### Layer 2 (Aspirational) — Run Phases 1–5 on multi-league data

When public league data is available, re-run Phases 1–5 using the Layer 2 dataset. Compare
winners against Layer 3 results. Update documentation to reflect which parameters are
consistent across leagues vs. which are Moonlight Graham-specific.

---

## Files the Agent May Modify

| File | What to modify |
|------|---------------|
| `R/sgp.R` | SGP denominator estimator, calibration window, time decay |
| `R/replacement.R` | Boundary definition, sort key, band width, catcher adjustment |
| `R/dollar_values.R` | Hitter/pitcher split, minimum allocation, iteration logic |
| `autoresearch.sh` | Benchmark runner — should not need modification |
| `autoresearch.jsonl` | Experiment log — written by the agent automatically |

**Do not modify:**
- `plans/autoresearch-valuation.md` (this file)
- `data/` files (read-only ground truth)
- `tests/` (existing tests must continue to pass)

---

## Stopping Rules

- **Accept** any candidate that beats the current best by ≥ 0.002 correlation points
- **Reject** any candidate that falls below the current best (revert to last committed winner)
- **Stop Phase** when 3 consecutive experiments produce no improvement ≥ 0.002
- **Stop overall** when correlation reaches 0.980 or when the full search space is exhausted

---

## Open Questions Deferred to Validation (not part of this search)

These questions cannot be resolved by correlation optimization alone — they require
separate validation:

- Positional adjustment sign direction (C/SS positive, OF/1B negative) — verify after
  implementation, not during autoresearch. Unit test: `scarcity_premium["C"] > 0` and
  `scarcity_premium["OF"] <= 0` for a standard AL-only league fixture.
- Budget reconciliation: total positive-PAR pool should be within ~$5 of actual auction
  budget — check as a diagnostic at the end of each phase
- $1 player trimmed-mean calibration window — deferred until implementation is live
- Two-way player value formula: `hitter_PAR + pitcher_PAR − 1` (Pitcher List formulation)
  is not testable via correlation alone since Moonlight Graham has no two-way players;
  validate against Ottoneu leagues if extending beyond the current format
- Pool SD diagnostic (`position_sd_ratio` by position/category) — run once on historical
  data to determine catcher inflation root cause before choosing a catcher adjustment
  method; this is a prerequisite diagnostic, not an autoresearch experiment
- 100 IP SP/RP threshold empirical validation — fit a bimodal mixture model
  (`mixtools::normalmixEM`) to actual pitcher IP distributions from 5 years of Steamer/ZiPS
  projections; use the empirical trough as the default rather than the round-number 100

---

## Interpreting Results

A high correlation means the system correctly **orders teams by quality**. It does not mean
individual player dollar values are accurate. After finding the best-correlating system,
a separate calibration step will check:

- Do total team dollar values match the actual auction budget within ~$5?
- Are catcher prices within observed market range?
- Does the system correctly identify the top-3 teams in held-out years?

**Comparing Layer 2 and Layer 3 results:** Parameters where the two layers agree are
documented as confident general defaults. Parameters where they diverge indicate
Moonlight Graham-specific behavior — these should be documented as configurable with
guidance explaining the league characteristics that drive the difference (e.g., shallow
catcher pool, unusual SB environment, heavy auction spend on pitching).
