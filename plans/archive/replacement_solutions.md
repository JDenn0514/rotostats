# Solutions: `replacement_level()` Specification Issues

Synthesized from first-principles analysis and research across fantasy baseball methodology
literature, sports analytics, statistical methods, and R package design best practices.

Solutions within each issue are ordered best-to-worst. An **Overview & Recommendation**
section follows each issue.

---

## I. Critical Conceptual Flaws

---

### Issue 1: Z-score ranking and positional boundary detection are circularly dependent

---

#### Solution A — Warm-started coordinate descent (iterative convergence to fixed point)

**Why it fixes the issue:** Replaces the undefined "z-score ranking on first pass" with a
deterministic seed: on pass 1, each player is ranked only within their primary position
pool (first position listed in `pos_eligibility`). This breaks the bootstrap circularity
without abandoning the iterative architecture. Subsequent passes use
`position_assignments` from `dollar_values()` and converge to a fixed point where
assignments and replacement levels are mutually consistent.

The theoretical basis is coordinate descent: alternating between (A) updating the
assignment given current replacement levels and (B) updating replacement levels given
current assignments converges to a stationary point when the objective is bounded below
and continuous — both conditions hold for SGP-based valuation.

**Pros:**
- Eliminates the circularity on pass 1 without discarding the iterative machinery
- Converges to a self-consistent fixed point where rankings and boundaries agree
- Confirmed industry practice: FanGraphs auction calculator, Mastersball PVM both use
  iterative convergence initialized by a positional hierarchy seed
- Convergence is typically 3–5 passes for well-behaved projections
- Pass-1 behavior is deterministic and reproducible

**Cons:**
- Which fixed point you converge to depends on the seed; multi-eligible players assigned
  to their primary position on pass 1 may start in a suboptimal pool
- Requires a formally defined convergence criterion (see Issue 7) or the circularity
  just reappears as an unbounded loop
- "Primary position" must be explicitly defined in the spec

**Implementation (R):** In the `is.null(position_assignments)` branch, replace global
`order()` with `split()`-then-`order()` within each primary position group:

```r
if (is.null(position_assignments)) {
  # Pass 1: rank within primary position only
  players$primary_pos <- vapply(
    strsplit(players$pos_eligibility, "\\|"), `[[`, character(1), 1
  )
  repl_pos <- split(seq_len(nrow(players)), players$primary_pos)
  repl_pos <- lapply(repl_pos, function(idx) {
    idx[order(players$composite_score[idx], decreasing = TRUE)]
  })
} else {
  # Pass 2+: use supplied assignments
  ...
}
```

---

#### Solution B — Fixed historical replacement-level priors (FanGraphs WAR approach)

**Why it fixes the issue:** Eliminates the circularity on pass 1 by not computing
replacement levels from the current projection pool at all. Instead, use 3–5 years of
historical league data to calibrate stable per-position replacement-level z-scores.
These priors seed pass 1. Iteration refines them for the current year's projections.
This mirrors FanGraphs' WAR methodology: positional adjustments are fixed historical
constants (+12.5 runs/162g for C, −12.5 for 1B, etc.) calibrated from long-run data,
not derived fresh each season.

**Pros:**
- Eliminates pass-1 circularity without requiring within-position ranking logic
- Historical priors are more stable than projection-derived seeds; reduces year-to-year
  volatility in replacement-level estimates
- The historical data is already available via `league_history`

**Cons:**
- Adds an out-of-band calibration dependency; replacement levels lag structural changes
  (a new position becoming scarcer won't register until the historical pool updates)
- Requires a separate calibration pipeline before the first run of `replacement_level()`
- The autoresearch framework would need extending to produce and maintain these priors

---

#### Solution C — Greedy positional hierarchy (one-pass, no iteration)

**Why it fixes the issue:** Sidesteps the circularity by using a fixed, asserted scarcity
ordering (C > SS > 2B > 3B > 1B > OF > Util) to assign multi-eligible players. After
one-pass assignment, replacement levels are computed per position with no need for
ranking to feed back into assignment. The hierarchy is an axiom, not a derived output,
so there is nothing circular.

Used by fvarbaseball and Harper Wallbanger's valuation system.

**Pros:**
- Zero implementation complexity; single-pass, deterministic
- Produces stable, reproducible output
- Good fallback seed for Solution A's first pass

**Cons:**
- The hierarchy is asserted, not derived from the data; gets the ordering wrong when
  the actual scarcity landscape differs from the conventional order
- Does not converge to a self-consistent solution — assignment and replacement levels
  are not mutually consistent, just computed in one direction
- Acceptable as a seed but not as a final answer

---

#### Solution D — Playing-time boundary (PA/IP threshold, not head count)

**Why it fixes the issue:** Substitutes projected playing time for head count as the
boundary criterion. The replacement-level player is the one whose cumulative projected
PA (or IP for pitchers) crosses the total league deployment threshold
(`n_teams × roster_slots × mean_PA_per_slot`). Playing time is an input variable, not
derived from the ranking, so no circularity is introduced.

**Pros:**
- No circularity: PA/IP projections are inputs, not derived from replacement levels
- Handles part-time players more naturally — a 200-PA player is weighted differently
  than a 600-PA player at the same head-count rank
- More stable in projection years with many injured/platoon players

**Cons:**
- Requires reliable PA/IP projections, which themselves carry uncertainty
- Still requires assigning each player to a primary position (the hierarchy problem
  reappears one level up)
- More complex to implement than a head-count cutoff

---

#### Solution E — Flat pool (single cutoff across all non-C hitters)

**Why it fixes the issue:** Eliminates the circularity by eliminating per-position
boundaries entirely. In a 15-team × 14-hitter-slot league, the 211th hitter overall is
replacement level. No position-specific assignment is required.

**Pros:**
- Zero circularity; trivial to implement
- Acceptable as a fast initializer for Solution A

**Cons:**
- Systematically undervalues scarce positions (SS, 2B, C) by setting their replacement
  level at the OF/1B depth
- Requires a separate catcher patch regardless
- Not a valid production algorithm; only useful as a benchmark or seed

---

#### Overview & Recommendation

**Best → Worst:** A > B > C > D > E

**Recommendation: Solution A**, initialized with the Solution C hierarchy as the
pass-1 seed. The greedy hierarchy is the industry-standard seed; coordinate descent
from that seed converges to a self-consistent fixed point. Solution B (historical
priors) is worth implementing as an alternative seed once sufficient historical data is
accumulated from Moonlight Graham. Expose `max_iter` and `tol` as parameters per
Issue 7's fix.

Also add two user-facing parameters:

- `boundary_method = c("head_count", "playing_time")` (default `"head_count"`): `"head_count"` implements the roster boundary approach described throughout this spec. `"playing_time"` implements Solution D — the replacement-level player is the one whose cumulative projected PA (hitters) or IP (pitchers) crosses the total league deployment threshold (`n_teams × roster_slots × mean_PA_per_slot`). Playing time is an input variable rather than a derived quantity, so no circularity is introduced. Best for projection vintages with many part-time or injured players.

- `seed_method = c("hierarchy", "historical_priors")` (default `"hierarchy"`): Controls the pass-1 seed within coordinate descent. `"hierarchy"` uses the greedy positional ordering (Solution C). `"historical_priors"` uses per-position replacement-level z-scores calibrated from `league_history` data; requires `league_history` to be supplied and will `cli_abort()` otherwise.

---

### Issue 2: Global weighted z-score averaging mixes incompatible units

---

#### Solution A — Compute positional adjustments in SGP units (recommended)

**Why it fixes the issue:** SGP denominators convert per-category counting and rate stats
into a common standings-points scale. Once each position's replacement stat line is
expressed in SGP units, the weighted average across positions is coherent: it represents
the average replacement-level contribution to standings points across positions, weighted
by how many roster slots each position occupies. No distributional assumptions about
z-scores are required.

Confirmed by FanGraphs auction calculator (aPOS is computed in dollar/PAR units, not
z-score units) and the SGP methodology literature (Todd Zola, Smart Fantasy Baseball).

**Pros:**
- Positional adjustments become interpretable: `scarcity_premium["C"] = +2.3 SGP`
  means the replacement catcher costs you 2.3 standings points more than a
  global-average replacement hitter
- Zero-sum property holds exactly by construction when slot weights sum correctly
- Aligns with how `dollar_values()` already operates

**Cons:**
- Requires SGP denominators as input; positional adjustments cannot be computed on
  pass 1 if `sgp_denominators` is NULL
- Return `positional_adjustments = NULL` on pass 1 and document this explicitly

---

#### Solution B — Dollar-space normalization (convert FVARz to dollars, compare there)

**Why it fixes the issue:** Rather than averaging z-scores globally, convert each
position's FVARz above replacement to dollars via the budget-proportional formula:
`$ = (player_FVARz / total_FVARz_positive_pool) × discretionary_budget + $1_minimum`.
Dollar values are the universal currency; cross-position comparisons happen in dollar
space, not z-score space.

**Pros:**
- Values automatically sum to the auction budget (strong calibration constraint)
- Standard final step in all z-score-based systems; well-understood
- Does not require SGP denominators

**Cons:**
- Absorbs the distributional incompatibility into the conversion factor rather than
  eliminating it; if one position's pool is shallow, that position exerts
  disproportionate influence on the conversion factor
- Less interpretable than SGP-unit adjustments

---

#### Solution C — FVARz replacement anchoring (industry standard, but incomplete)

**Why it fixes the issue partially:** The standard FVARz approach: compute z-scores
within each position's pool, subtract the replacement player's z-score from all players
at that position (`FVARz_i = zSUM_i - zSUM_replacement`). After this offset, all
positions share a replacement-level anchor of zero, enabling cross-position comparison.

Widely used: fvarbaseball, Harper Wallbanger, Smart Fantasy Baseball all use this.

**Pros:**
- Industry-standard; well-understood; direct cross-position comparison after offset
- Self-adjusting: when catchers improve as a class, the offset shrinks automatically
- No SGP denominators required

**Cons:**
- Papers over the incompatible-units problem rather than solving it: one FVARz unit at
  C does not equal one FVARz unit at OF in terms of auction dollars, because the thin
  catcher pool inflates the spread between adjacent players
- This is exactly the step that produces the systematic catcher overvaluation (Issue 4)

---

#### Solution D — Razzball PosFact blending (tuneable dial)

**Why it fixes the issue:** Introduce a `pos_weight` parameter (0–1) that blends
within-position z-scores with global-pool z-scores:
`adjusted = pos_weight × (stat - pos_avg) + (1 - pos_weight) × (stat - global_avg)`.
At `pos_weight = 1`, fully positional. At `pos_weight = 0`, fully global. The parameter
is calibrated empirically against actual auction prices.

**Pros:**
- Explicitly acknowledges the incompatibility and treats it as a tuneable dial
- A `pos_weight ≈ 0.5` reduces the overstatement of scarce-position premiums
- Directly addresses the problem rather than ignoring it

**Cons:**
- `pos_weight` is an additional free parameter requiring empirical calibration
- The blended value is not interpretable in a single unit

---

#### Overview & Recommendation

**All four solutions represent methodological positions held by real practitioners; none is obviously wrong.** Expose as `positional_adjustment_method` parameter with the following options:

- `"fvarz"` (default): Solution C — FVARz replacement anchoring. Industry standard (fvarbaseball, Harper Wallbanger, Smart Fantasy Baseball). The replacement player's z-score is subtracted from all players at the same position, anchoring replacement level at zero for cross-position comparison. No additional dependencies. Produces the known catcher inflation described in Issue 4.

- `"sgp"`: Solution A — positional adjustments computed in SGP units. Theoretically cleanest; the scarcity premium for each position is interpretable as standings-point units (`scarcity_premium["C"] = +2.3 SGP` means the replacement catcher costs you 2.3 standings points more than global average replacement). Requires `sgp_denominators`. On pass 1 (before denominators exist), return `positional_adjustments = NULL` and document this explicitly.

- `"dollar"`: Solution B — dollar-space normalization. Each position's FVARz above replacement is converted to dollars via the budget-proportional formula; cross-position comparisons happen in dollar space. Values automatically sum to the auction budget (strong calibration constraint). Does not require `sgp_denominators`.

- `"posblend"`: Solution D — tuneable blend of within-position and global-pool z-scores. Requires `pos_weight` sub-parameter (0–1); `pos_weight = 1` is fully positional, `pos_weight = 0` is fully global. No principled default for `pos_weight`; requires empirical calibration against auction price data.

**Regardless of method:** Do not average z-scores across positions under any circumstances — the global weighted z-score formula in the current spec must be removed entirely.

**Verbose notification:** If `sgp_denominators` are supplied but `positional_adjustment_method != "sgp"`, emit `cli_inform()` when `verbose = TRUE`: *"sgp_denominators were supplied but positional_adjustment_method = '{method}', not 'sgp'. SGP-unit adjustments will not be computed. Set positional_adjustment_method = 'sgp' to use them."*

---

### Issue 3: Rate stat weighting via `expected_team_IP/AB` conflates two distinct concepts

---

#### Solution A — Remove `expected_team_IP` from `replacement()`; use raw IP-weighted quality

**Why it fixes the issue:** The `expected_team_IP` denominator answers "what share of
team innings does this pitcher represent?" — a dollar allocation question. Ranking
should answer "is pitcher A better than pitcher B?" Raw IP-weighted rate-stat differences
answer that without reference to league depth:

```
ERA_ranking_weight = (repl_ERA - pitcher_ERA) × pitcher_IP
WHIP_ranking_weight = (repl_WHIP - pitcher_WHIP) × pitcher_IP
```

FanGraphs WAR uses exactly this separation: `(lgFIP - FIP)` is the quality component;
IP is the volume scaler applied only when converting to total WAR. The two are computed
independently and multiplied — never combined as a ratio to a league total.

**Pros:**
- Rankings become league-depth-independent: a borderline swingman ranks identically in
  a 10-team and 15-team league, as it should
- Removes `expected_team_IP` from `replacement()`'s interface; the parameter moves to
  `sgp()` where it belongs
- Simpler formula; one fewer parameter to document and validate
- Retains `league_history$team_stats` solely for the divergence warning check

**Cons:**
- Raw IP-weighted ERA differences are not on the same scale as counting stat
  contributions — requires z-score or SGP normalization across categories to form a
  composite rank. This is already required by the spec's `sort_by` parameter; no new
  complexity is introduced.

---

#### Solution B — SGP fixed-baseline-pool approach (Todd Zola / Smart Fantasy Baseball)

**Why it fixes the issue:** The SGP rate-stat formula anchors the baseline pool to a
fixed empirical set (108 rostered pitchers' combined ER and IP), not to a
league-size-sensitive `expected_team_IP`. A pitcher's ERA SGP contribution is:

```
ERA_SGP = ((baseline_ER + pitcher_ER) × 9 / (baseline_IP + pitcher_IP) - lg_avg_ERA) /
          ERA_SGP_denom
```

The `baseline_ER` and `baseline_IP` are the other 107 rostered pitchers. This pool is
held constant across rankings, so the denominator does not shift with league depth.

**Pros:**
- Directly in SGP units; no separate z-score normalization step needed
- The baseline pool captures the actual competitive context (how your pitchers interact
  with the rest of your roster's ERA/WHIP)
- Empirically calibrated; production-validated

**Cons:**
- Requires knowing which 107 pitchers make up the baseline pool, which itself requires
  an assignment — partial circularity reappears
- More complex than raw IP-weighting; requires `sgp_denominators` and baseline pool

---

#### Solution C — Use ERA- or FIP- (normalized rate stats decoupled from league environment)

**Why it fixes the issue:** `ERA- = (pitcher_ERA / lgERA) × 100` is inherently decoupled
from how many innings any pitcher throws. Quality ranking is purely relative to the
league ERA, not to total league IP.

**Pros:**
- Clean separation of quality from volume
- FanGraphs publishes ERA- for easy reference

**Cons:**
- For rotisserie ERA/WHIP categories, you ultimately need to convert back to expected
  ERA/WHIP contribution for SGP; ERA- is a quality proxy, not the final metric
- Adds a conceptual translation step

---

#### Overview & Recommendation

**Solutions A and B are both defensible.** Expose as `rate_stat_ranking_method` parameter:

- `"raw_ip"` (default): Solution A — raw IP-weighted rate-stat differences with no league-depth denominator. Rankings are league-depth-independent: a pitcher of fixed quality ranks identically in a 10-team and 15-team league. Formula: `rating_weight = (repl_rate - player_rate) × player_IP`. Conceptually cleanest; removes `expected_team_IP` from `replacement()`'s interface entirely.

- `"sgp_pool"`: Solution B — Todd Zola's SGP fixed-baseline-pool approach (Smart Fantasy Baseball). The other N−1 rostered pitchers form the baseline pool; a pitcher's ERA contribution is computed as the marginal change in the pool's combined ERA/WHIP from adding that pitcher. Requires `sgp_denominators`. Partial circularity (the pool composition depends on rankings that depend on the pool) is managed by the existing iteration loop. Production-validated by Zola's system.

**Regardless of method:** Remove `expected_team_IP` from `replacement()`'s interface. Retain it in `sgp()` where it belongs. `league_history$team_stats` is a validation signal only (divergence warning), not a ranking input, under either method.

---

### Issue 4: Catcher calibration failure is patched, not fixed

---

#### Solution A — Catcher/non-catcher split pool (structurally principled)

**Why it fixes the issue:** Rather than treating catchers as one position among many in a
unified hitter pool, divide hitters into two pools: catchers and non-catcher hitters.
Compute z-scores and dollar allocations within each pool. Each pool receives a budget
allocation proportional to its roster slot count. Because catchers are compared only to
catchers, their thin-pool distribution does not contaminate the non-catcher distribution,
and vice versa.

Endorsed by the RotoWire Z-Files column: "It's only necessary to account for catchers —
in almost all formats, you're fine breaking the hitting pool into catcher and
non-catcher."

**Pros:**
- Eliminates cross-pool contamination structurally; no empirical discount needed
- Within-pool replacement anchoring handles scarcity automatically
- Self-adjusting: if catchers improve as a class, the catcher-pool replacement level
  rises accordingly

**Cons:**
- Budget allocation across pools (what fraction goes to catchers?) is a free parameter
  requiring justification; infer it from `roster_slots` counts
- Does not prevent overvaluation within the catcher pool itself if the top 2–3 catchers
  are much better than the rest
- Breaks direct cross-pool dollar comparisons (a $15 catcher vs. $15 OF are no longer
  directly comparable without knowing pool budget splits)

---

#### Solution B — Diagnose root cause before applying any correction

**Why it fixes the issue:** The 0.75× discount suppresses a symptom without identifying
the cause. Add a diagnostic output: `pool_diagnostics$position_sd_ratio` — the ratio of
each position's within-pool SD to the global SD for each scored category. If the catcher
SD ratio is significantly below 1.0 on counting stats, the pool is compressed (a
construction bug — fix the pool). If the SD ratio is near 1.0 but prices are still
inflated, the inflation is a genuine scarcity premium (market effect — handle in
`dollar_values()` as a parametric adjustment).

**Pros:**
- Forces an actual diagnosis before a correction is applied
- If Option A of the diagnostic reveals a pool-construction bug, fixing it improves all
  positions, not just catchers

**Cons:**
- Requires implementing the diagnostic before the spec can be finalized
- If both effects are present (pool compression + real scarcity premium), decomposing
  them requires more data

---

#### Solution C — Parametric `catcher_adjustment_method` exposing the choice

**Why it fixes the issue:** Rather than hardcoding a correction, expose the choice as a
function parameter with documented tradeoffs:
`catcher_adjustment_method = c("split_pool", "full_offset", "partial_offset", "none")`.

- `"split_pool"` implements Solution A
- `"full_offset"` applies the standard FVARz replacement anchoring (industry default but
  produces inflation)
- `"partial_offset"` applies a fraction of the offset (empirical; not principled)
- `"none"` implements the Podhorzer/FanGraphs contrarian view that positional scarcity
  premium is a market artifact, not real value

**Pros:**
- No permanent commitment to one approach while the debate is unresolved
- Documents the tradeoffs explicitly
- Research (RotoGraphs/Podhorzer) supports the `"none"` option for sophisticated users
  who buy catchers at a discount to market

**Cons:**
- Pushes a methodological decision onto the user
- Requires maintaining and testing four code paths

---

#### Solution D — Full FVARz replacement offset (industry standard, but the source of the problem)

**Why it is listed:** It is the standard approach (FVARz, FanGraphs auction calculator).
The replacement catcher's `zSUM` is subtracted from all catchers, forcing the replacement
catcher to zero. Elite catchers then receive inflated values proportional to their
distance above the replacement.

**Pros:** Industry standard; self-adjusting; no hardcoded constants.

**Cons:** This is exactly what inflates catcher prices by 30% in thin-pool years. Applying
it correctly and consistently without a diagnostic (Solution B) or structural fix
(Solution A) just reproduces the issue the spec acknowledges.

---

#### Solution E — No adjustment (Podhorzer / contrarian)

**Why it is listed:** The theoretical argument is that since every team must start one (or
two) catchers, positional scarcity creates no transferable standings advantage. Analysts
who consistently pay below the market-implied catcher premium tend to perform better.

**Pros:** Theoretically coherent; validated by some empirical evidence.

**Cons:** A valuation tool that undervalues catchers relative to market will produce prices
that don't match auction behavior, confusing users who expect market-realistic output.

---

#### Overview & Recommendation

**Best → Worst:** A > B > C > D > E

**Recommendation:** Implement Solution B (diagnostics) immediately to determine the root
cause. If pool-construction compression is found, fix it (likely resolving the issue
without further correction). If the residual inflation is structural, implement Solution A
(split pool) as the default and wrap it in Solution C's parameterization. Remove the
0.75× hardcoded discount from `priceguide` entirely.

---

## II. Statistically Unsound or Under-Specified Methodology

---

### Issue 5: σ estimation for cliff detection is under-specified

---

#### Solution A — MAD over the full 2K+1 band (simple, robust, available in base R)

**Why it fixes the issue:** MAD (Median Absolute Deviation) = `median(|xᵢ - median(x)|)`,
scaled by 1.4826 for consistency with σ under normality. It has a 50% breakdown point,
meaning up to half the band can be extreme values without destabilizing the estimate —
exactly the right property when you're trying to detect whether one of those values is
an outlier. Available as `stats::mad()` with no dependencies.

The cliff rule becomes: `gap ≥ cliff_threshold × mad(band_values) × 1.4826`, where
the band is the full 2K+1 players and the SD estimate is explicit.

**Pros:**
- Eliminates the σ-source ambiguity completely; MAD over 2K+1 is fully specified
- Base R, zero dependencies
- Well-known; easy to document; familiar to statisticians
- More reliable than SD at n=7 (SD has ~70% relative standard error at n=3)

**Cons:**
- MAD has 37% Gaussian efficiency (less efficient than SD when data is truly clean)
- At n=7 (full band), the MAD estimate still has meaningful variance; bootstrapping it
  in the calibration study is advisable

---

#### Solution B — Fisher-Jenks 2-class split (scale-free; no σ estimation needed)

**Why it fixes the issue:** Fisher-Jenks partitions an ordered sequence into k=2 classes
by minimizing within-class variance (optimal 1D k-means). Applied to the 2K+1 band
values, `classInt::classIntervals(band_values, n=2, style="fisher")` returns the optimal
split. If the split falls at the expected boundary position, a cliff is confirmed.
No σ estimation required.

**Pros:**
- Completely sidesteps the σ estimation problem
- Scale-agnostic: works identically for ERA (high variance) and SV (low variance)
  without recalibration
- Available in `classInt` on CRAN

**Cons:**
- Always finds a split (no null hypothesis); requires a second step to assess whether the
  split is meaningful (compare within-group variance before/after, or compare to a
  permutation null)
- Less interpretable than a σ-based threshold to package users

---

#### Solution C — Gap-to-range ratio (non-parametric, from first principles)

**Why it fixes the issue:** Replace the σ-based statistic with
`cliff_stat = gap_between_adjacent / range(band_values)`. The threshold becomes
approximately 0.35–0.40 (calibrated). This has an intuitive interpretation ("is this
gap large relative to the spread of the entire band?") and requires no distributional
assumptions.

**Pros:**
- Non-parametric; no distributional assumptions
- Intuitive interpretation
- No dependencies

**Cons:**
- The threshold (0.35–0.40) requires calibration and has no prior-art basis
- Sensitive to the maximum and minimum of the band (range-based statistics have 0%
  breakdown point)

---

#### Solution D — Sn/Qn estimators via `robustbase` (better small-sample properties)

**Why it fixes the issue:** Sn = `c × median_i(median_j(|xᵢ - xⱼ|))`. Like MAD, it has
50% breakdown point, but unlike MAD it is approximately unbiased at n=10 (< 1% bias)
and has 58% Gaussian efficiency. Available in `robustbase::Sn()`.

**Pros:**
- Better small-sample bias properties than MAD
- Also 50% breakdown point

**Cons:**
- Adds a `robustbase` dependency
- More obscure than MAD; harder to explain in documentation

---

#### Solution E — PELT changepoint detection via `changepoint` package

**Why it fixes the issue:** `changepoint::cpt.mean(band_values, method="PELT", penalty="MBIC")`
detects whether a statistically supported mean-shift exists in the ordered band. The MBIC
penalty adapts to sample size, preventing false positives in small samples. If exactly
one changepoint is detected below the boundary player, declare a cliff.

**Pros:**
- Rigorous; penalty adapts to n; no threshold calibration needed
- Nonparametric variant available (`changepoint.np`)

**Cons:**
- Adds a dependency; PELT with MBIC is conservative and may miss genuine small cliffs;
  overkill for a 7-player window

---

#### Overview & Recommendation

**Best → Worst:** A > B > C > D > E

Expose as `cliff_method` parameter. All three practical options are viable for user selection:

- `"mad"` (default): Solution A — MAD over the full 2K+1 band via `stats::mad()`. No dependencies. Robust to up to 50% outliers in the band. The σ specification is fully explicit: `mad(band_values) * 1.4826`. Cliff triggers when `gap >= cliff_threshold × mad(band_values) * 1.4826`.

- `"fisher_jenks"`: Solution B — `classInt::classIntervals(band_values, n=2, style="fisher")`. Scale-agnostic; works identically for high-variance stats (ERA) and low-variance stats (SV) without recalibration. Adds `classInt` dependency. Always finds a split; cliff is confirmed when the split falls at or below the boundary player position. Second-step significance check: compare within-group variance before and after the split.

- `"gap_ratio"`: Solution C — `cliff_stat = gap_between_adjacent / range(band_values)`. Non-parametric, no dependencies. Intuitive interpretation ("is this gap large relative to the full band spread?"). Default threshold approximately 0.35–0.40; requires calibration and should be exposed as `cliff_gap_ratio_threshold` in `replacement_params`.

Solutions D (Sn/Qn via `robustbase`) and E (PELT changepoint via `changepoint`) are not user-facing options — too heavyweight for a 7-player window and better suited to the calibration study.

---

### Issue 6: Z-score pool composition is ambiguous

**Single Recommended Fix — No meaningful alternatives exist.**

**Fix:**

1. **Pool size:** `pool_size = n_teams × total_slots_for_type + K` (not `+ 2K + 1`). The
   upper K players are already within the rostered pool by definition. Only the K-player
   lower extension beyond the boundary adds new players.

2. **Swingman inclusion:** Swingmen are included in the pitcher pool, classified at
   initial z-score computation time by projected IP using `sp_ip_threshold`. If a
   swingman is reclassified in a later iteration, their z-score is recomputed in the new
   classification's pool. Tie z-score computation to classification explicitly.

3. **Swingmen in the band:** Flag `swingman = TRUE` in the `cliff_metric` output column.
   Informational only — no behavioral change.

**Why:** A 5% pool size ambiguity is enough to shift borderline players' z-scores
meaningfully (3.6% difference between K and 2K+1 extra players in a 10-team × 11-pitcher
league). Specifying `+K` unambiguously eliminates this. Tying swingman z-scores to
classification makes iteration deterministic and reproducible.

---

### Issue 7: Multi-position convergence criterion is fully deferred

---

#### Solution A — Assignment stability + absolute stat change + hard cap (standard convergence criteria)

**Why it fixes the issue:** Provides two concrete stopping conditions and a safety fallback:

1. **Primary:** Assignment stability — zero players change their assigned position between
   passes N and N+1 (`all(new_assignment == old_assignment)`)
2. **Secondary:** Absolute stat change — `max(abs(new_repl_stats - old_repl_stats)) < tol`
   (default `tol = 0.01` in SGP units ≈ $0.10–$0.25 in dollar terms)
3. **Hard cap:** `max_iter = 25`; if not converged, emit `rotostats_warning_convergence_not_reached`
   and return best-so-far with `converged = FALSE`

Stop when BOTH the primary and secondary conditions are met, or when the hard cap is
reached. Following the `lme4` convention, non-convergence is a warning, not an error.

Standard approach: `optim()` uses `reltol`, `maxit`; `nls()` uses `tol`, `maxiter`;
`lme4` warns on non-convergence but returns the object. `mize` package codifies five
orthogonal criteria (iteration count, absolute change, relative change, gradient norm,
step size).

**Pros:**
- Direct analog to base R optimization conventions; familiar pattern
- Both criteria are necessary: assignment can be stable while stats still shift
  (swingman reclassification); stats can be stable while assignment oscillates (degenerate
  near-ties)
- Hard cap prevents infinite loops from corner-case assignment oscillation
- Storing `converged`, `iterations`, `delta` in return attributes makes diagnostics available

**Cons:**
- `tol = 0.01` SGP units needs empirical validation via the calibration sweep (Issue III)
- Assignment stability can oscillate when two players are essentially identical; both
  criteria combined handle this, but the combination adds code complexity

**Implementation:**

```r
for (i in seq_len(max_iter)) {
  repl_new  <- update_replacement(projections, roster_slots, assign_prev)
  assign_new <- assign_players(projections, repl_new)

  delta      <- max(abs(repl_new$stats - repl_old$stats))
  stable     <- identical(assign_new, assign_prev)

  if (stable && delta < tol) { converged <- TRUE; break }

  repl_old   <- repl_new
  assign_prev <- assign_new
}
if (!converged) rlang::warn("rotostats_warning_convergence_not_reached", ...)
structure(repl_new, converged = converged, iterations = i, delta = delta)
```

---

#### Solution B — Hungarian algorithm / `clue::solve_LSAP` for the inner assignment step

**Why it partially fixes the issue:** The inner assignment sub-problem (given current
replacement levels, assign players to positions optimally) can be solved non-iteratively
in O(n³) time using the Linear Sum Assignment Problem algorithm. `clue::solve_LSAP(cost_matrix, maximum = TRUE)` where `cost_matrix[i,j]` = value of assigning player i to
slot j. This makes the inner step globally optimal and eliminates assignment-oscillation
as a convergence failure mode.

Note: the outer loop (Issues 1 and 7) is still required because replacement levels
themselves depend on the assignment. Only the inner assignment step becomes non-iterative.

**Pros:**
- Globally optimal assignment at each pass; no oscillation between equivalent assignments
- Reduces the convergence problem to a single criterion: stat-change magnitude
- O(n³) is fast for n ≤ 500 (all realistic fantasy roster sizes)

**Cons:**
- Requires constructing an n × m cost matrix with eligibility constraints (bookkeeping)
- Adds `clue` dependency
- Does not eliminate the outer convergence loop

---

#### Solution C — Integer linear programming via `lpSolve` or `ompr`

**Why it partially fixes the issue:** `lpSolve::lp.assign()` or `ompr` + GLPK solver
formulates the multi-position assignment as an ILP, handles non-square problems and
eligibility constraints as zero-coefficient decision variables, and solves to global
optimality in one call.

**Pros:** Most general formulation; handles side-constraints; `ompr` syntax is readable.

**Cons:** Heaviest dependency (solver + `ROI.plugin.glpk`); overkill when `clue::solve_LSAP`
suffices; outer convergence loop still required.

---

#### Overview & Recommendation

**Best → Worst:** A > B > C

**Recommendation: Solution A** as the convergence specification, with Solution B
(`clue::solve_LSAP`) as an implementation optimization for the inner assignment step
(reduces oscillation failure mode). The convergence criterion must be specified in the
`replacement_level()` spec even though the loop lives in `dollar_values()`. Add a
`converged` attribute to the return object following `lme4` / `optim()` conventions.

---

### Issue 8: Playing time normalization is a user choice

**Change from single recommended fix to parameterized design.**

Add `normalize_to_season = FALSE` as a user-facing parameter:

- `normalize_to_season = FALSE` (default): Return raw projected totals as supplied in `projections`. Required when `sgp()` compares raw projected stats to SGP denominators calibrated on raw actual season stats — normalizing would double-apply playing time weighting. Appropriate for full-season projections (Steamer, ZiPS, ATC, THE BAT X).

- `normalize_to_season = TRUE`: Normalize counting stats to a full-season baseline before computing replacement level. Hitters normalized to 600 PA (or 550 AB when PA is unavailable); SP normalized to 200 IP; RP normalized to 70 IP. Use when projections are partial-season (call-up timing, injury returns) and the caller wants replacement level expressed in full-season terms.

**Interface Contract (regardless of setting):**

Add `attr(result, "stat_units") <- if (normalize_to_season) "full_season_normalized" else "raw_projected"` to the return value so `sgp()` can assert the contract at runtime:

```r
stopifnot(attr(replacement_stats, "stat_units") == "raw_projected")
```

**Load-bearing consequence:** `normalize_to_season = TRUE` combined with `sort_by = "sgp"` requires that `sgp_denominators` were themselves computed on normalized stats. This is a cross-function contract that must be documented in both the `replacement()` and `sgp()` specs. If the normalization baselines change (e.g., 600 PA → 650 PA), both specs must be updated simultaneously.

---

## III. Unjustified Constants and Thresholds

All numeric constants are addressed as a group with a single coherent approach.

---

#### Solution A — `replacement_params` object + OAT sensitivity sweep + leave-one-season-out CV

**Why it fixes the issue:** The root problem is not that the constants are wrong — it is
that they are presented as fixed defaults without a derivation or calibration record.
The fix has three parts:

**Part 1: Move all constants to a `replacement_params` list with documented ranges.**

```r
default_replacement_params <- list(
  band_width_K          = 3L,         # sweep: 1:5
  cliff_threshold       = 1.5,        # sweep: seq(0.5, 3.0, 0.25)
  cliff_min_n           = 4L,         # sweep: 3:6
  sp_ip_threshold       = 100,        # sweep: c(80, 90, 100, 110, 120)
  sp_rp_split_default   = c(SP=0.60, RP=0.40),
  ip_ab_divergence_tol  = 0.15,       # sweep: c(0.10, 0.15, 0.20)
  calibration_min_n     = 15L,        # sweep: c(10, 15, 20, 25, 30)
  convergence_eps       = 0.01,       # sweep: c(0.001, 0.01, 0.05)
  convergence_max_iter  = 25L
)
```

Callers override specific entries: `replacement_params = list(band_width_K = 2L)`.
Export `default_replacement_params` so users can inspect it.

**Part 2: Calibrate against Moonlight Graham historical data using leave-one-season-out CV.**

1. Collect NFBC average auction prices for 2021–2024 (or Moonlight Graham auction results)
2. For each candidate constant value, sweep OAT while holding others at defaults
3. Record Spearman ρ between projected dollar values and actual prices; RMSE; $1-pool bias
4. Leave one season out, calibrate on 3, test on 1; report mean ρ across all folds
5. Fill the "Derivation" column in the constants table with the sweep result

**Part 3: Specific empirically-motivated corrections.**

| Constant | Action |
|---|---|
| K = 3 in thin pools | Add dynamic cap: `K_eff = min(K, floor(n_rostered_pos / 4))` to prevent band spanning >25% of the rostered pool |
| 100 IP SP/RP split | Fit `mixtools::normalmixEM(projected_IP)` to 5 years of Steamer/ZiPS projections; use the empirical trough as the default |
| 67/33 SP/RP split | Infer from `historical_rosters.csv` actual SP/RP slot composition; this is a Moonlight Graham format parameter |
| 15-player calibration min | Raise to 20 unless the calibration sweep shows meaningful degradation between 15 and 20 |
| 1.5σ cliff threshold | Re-derive after fixing σ estimation (Issue 5); the 1.5 is borrowed from IQR outlier context where it doesn't apply |

**Pros:**
- All constants become auditable, updatable, and defensible
- The autoresearch framework already has the CV infrastructure; extending it to replacement-level
  parameters adds modest work
- Exposes which constants are sensitive (must be calibrated carefully) vs. insensitive (any
  reasonable value works)
- Fixes 67/33 SP/RP split for Moonlight Graham specifically

**Cons:**
- Calibration on Moonlight Graham data produces defaults specific to a 10-team AL-only format;
  the package must document this
- The dynamic K cap introduces conditional behavior that must be documented in the spec

---

#### Solution B — OAT sensitivity sweep + NFBC price validation only (pragmatic subset)

**Why:** If the full calibration pipeline (Solution A) is not immediately feasible, run an
OAT sweep across K, cliff threshold, and SP/RP split against any available price data.
Local sensitivity analysis requires only an outer `for` loop over a parameter grid —
trivial to implement. Even without leave-one-season-out CV, knowing which constants are
high-sensitivity vs. flat-sensitivity guides where to focus calibration effort.

**Pros:** Much faster to implement than Solution A; identifies the most impactful constants.

**Cons:** No out-of-sample validation; risk of overfitting to whatever price data is available.

---

#### Overview & Recommendation

**Best → Worst:** A > B

**Recommendation: Solution A.** The calibration work is necessary for the package to be
defensible. The autoresearch plan already describes a `~320-config` sweep; a
replacement-level parameter sweep can be incorporated with modest additions. Implement
the `replacement_params` object now (no calibration data needed); fill the empirical
defaults as the calibration data becomes available.

---

## IV. Specification Completeness Problems

---

### Issue 9: Data input format entirely unspecified

**Single Recommended Fix — Define the schema explicitly.**

**Required `projections` columns:**

| Column | Type | Notes |
|---|---|---|
| `player_id` | character | MLBAM ID preferred; used for deduplication |
| `player_name` | character | For display and fallback matching |
| `pos_eligibility` | character | Pipe-delimited: `"C"`, `"1B|3B"`, `"SP|RP"`. First is primary. |
| `team` | character | MLB team abbreviation |
| `league` | character | `"AL"` or `"NL"` |
| `[stat]` | numeric | One column per scored category; exact names must match `categories` arg |
| `IP` | numeric | Required for pitchers even if not a scored category |
| `AB` | numeric | Required for hitters when AVG/OBP/SLG in categories |
| `role` | character | Optional: `"SP"` or `"RP"` if source provides it; otherwise inferred from IP |

Add `league_type = c("mixed", "AL", "NL")` as an explicit function parameter. Do not
infer from `roster_slots["DH"] > 0`.

**Validation at function entry using `checkmate`:**

```r
checkmate::assert_data_frame(projections, min.rows = 1)
checkmate::assert_names(names(projections),
  must.include = c("player_id", "player_name", "pos_eligibility", "league",
                   stats_required))
checkmate::assert_character(projections$pos_eligibility)
checkmate::assert_subset(projections$league, c("AL", "NL"))
```

`checkmate` is the preferred approach: C-implemented (near-zero overhead), no DSL to
learn, errors include argument name automatically. Use `pointblank` only if graduated
warn/stop thresholds are needed per validation rule (see Issue 12).

---

### Issue 10: Output format unspecified

**Single Recommended Fix — Define the output schema explicitly.**

**`replacement_stats` data frame (one row per position):**

| Column | Type | Notes |
|---|---|---|
| `position` | character | Exact keys from `roster_slots` names |
| `[stat]` | numeric | One column per category; same names as `projections` input |
| `IP` | numeric | Always present for pitcher positions |
| `AB` | numeric | Always present for hitter positions when AVG/OBP in categories |
| `n_band_players` | integer | Number of players averaged into this replacement line |
| `cliff_detected` | logical | Whether cliff detection truncated the band |

Stat column names must exactly match the input `projections` column names.
`position` values must be a subset of `names(roster_slots)`.

Output `intersect(names(projections), c(categories, "IP", "AB"))` to guarantee exact
name matching without manual enumeration.

The return value is a list:

```r
list(
  replacement_stats    = <data.frame above>,
  positional_adjustments = <named numeric or NULL on pass 1>,
  cliff_metric         = <data.frame: position, cliff_detected, swingman, n_band_players, ...>,
  two_way_players      = <character vector of player_ids with both roles>,
  params               = <list: converged, iterations, delta, ...>,
  pool_diagnostics     = <list: position_sd_ratio per category>
)
```

---

### Issue 11: Two-way player output contract is ambiguous

**Single Recommended Fix — `replacement_stats` is position-indexed, never player-indexed.**

`replacement_stats` always contains one row per position (9 rows for standard AL
10-cat: C, 1B, 2B, 3B, SS, OF, DH, SP, RP). Two-way players do not appear as rows.

**The math for two-way player valuation (Pitcher List formulation, most directly implementable):**

```
two_way_PAR = hitter_PAR + pitcher_PAR - 1
```

The deduction of 1 (≈ $1 minimum salary) accounts for the single roster slot a two-way
player occupies. This avoids double-counting while capturing value from both roles.

The boundary slot deduplication convention: a two-way player is charged against the pool
where they produce higher PAR as the "primary" role. The secondary role's value is
treated as incremental. This convention must be specified in the `dollar_values()` spec,
which must be written concurrently.

The `two_way_players` element of the return list is a character vector of player IDs
with PAR > $0 in both roles — informational, consumed by `dollar_values()`.

Do not implement the Yahoo approach (two separate player rows). That double-counts the
roster slot.

---

### Issue 12: Error handling strategy is not specified

**Single Recommended Fix — Specify a decision matrix using `rlang` conditions.**

Governing principle (from Hadley Wickham's *Advanced R* and `vctrs` policy): abort on
conditions that make output structurally invalid; warn on conditions that degrade quality
but produce valid estimates; inform for actions taken on the user's behalf.

| Condition | Handler | Class |
|---|---|---|
| Missing required column in `projections` | `cli_abort()` | `rotostats_error_missing_column` |
| Wrong column type (e.g., `avg` is character) | `cli_abort()` | `rotostats_error_wrong_column_type` |
| Unknown rate stat not in lookup | `cli_abort()` | `rotostats_error_unknown_rate_stat` |
| `sort_by = "sgp"` but `sgp_denominators` is NULL | `cli_abort()` | `rotostats_error_missing_sgp_denominators` |
| `n_teams × roster_slots[pos]` exceeds projection pool | `cli_abort()` | `rotostats_error_pool_too_small` |
| KDE trough not detectable (from `trim_method = "kde"` only) | `cli_abort()` | `rotostats_error_kde_no_trough` |
| Convergence not reached within `max_iter` | `cli_warn()` (always) | `rotostats_warning_convergence_not_reached` |
| Calibration pool < `calibration_min_n` after trimming | `cli_warn()` (always) | `rotostats_warning_calibration_suppressed` |
| Team IP/AB diverges > `ip_ab_divergence_tol` from historical | `cli_warn()` (if `verbose`) | `rotostats_warning_team_total_divergence` |
| Name match failure in `league_history$prices` | `cli_warn()` (if `verbose`) | `rotostats_warning_name_match_failure` |
| Swingman in boundary band | No signal; `swingman = TRUE` in `cliff_metric` | — |
| Zero-sum violation in positional adjustments | `cli_abort()` (internal assertion) | `rotostats_error_zero_sum_violation` |

`verbose`-gating: conditions that degrade the primary output warn always. Informational
or operational conditions (team total divergence, name failures) are gated.

All classes must be added to `plans/error-messages.md` as the canonical registry.

Use `rlang::caller_env()` so errors point to the user's calling frame, not internals.
Following `lme4` convention: non-convergence is a warning, not an error; return the
best-so-far result with `converged = FALSE` in `params`.

---

### Issue 13: Rate stat denominator lookup is incomplete for real leagues

**Single Recommended Fix — Expand the lookup and specify the error message.**

**Expanded built-in lookup:**

```r
RATE_STAT_DENOMINATORS <- c(
  AVG = "AB",  OBP = "PA",   SLG = "AB",   OPS = "PA",
  ERA = "IP",  WHIP = "IP",  "K/9" = "IP", "BB/9" = "IP", "HR/9" = "IP",
  # Common alternative categories:
  SVHD = "G",   QS = "GS",
  "K%" = "PA",  "BB%" = "PA",
  wOBA = "PA",  xFIP = "IP",  SIERA = "IP",  FIP = "IP"
)
```

Note on `SVHD` and `QS`: when scored as counting totals (not rates), they need no
denominator. When scored per-opportunity (`SVHD%`, `QS%`), use `G` and `GS`
respectively. The spec must document which interpretation is assumed.

**Extensibility:** Start with Pattern A (argument-based):

```r
replacement_level(projections, roster_slots,
  rate_denominators = c(SIERA = "IP"))
# Merged with defaults internally via modifyList()
```

Promote to Pattern C (environment registry + `register_rate_denominator()`) when a
third-party-extension use case is confirmed. Export `rate_stat_denominators()` (no
arguments) so users can inspect the current lookup.

**Required error message for unknown stat:**

```
Error: Category "SIERA" is not in the built-in rate stat denominator lookup and no
`rate_denominators` override was supplied.

Hint: If SIERA is a rate stat in your league, supply:
  rate_denominators = c(SIERA = "IP")
If SIERA is a counting stat, remove it from `categories`.
```

---

## V. Smaller Issues

---

**Band symmetry:** Keep ±K symmetric. The boundary player is the center by construction;
a symmetric band smooths noise symmetrically. An asymmetric band would require an
additional free parameter (upper half-width, lower half-width) and would only be
superior if `cliff_metric` data shows consistently asymmetric truncation. Document this
rationale explicitly in the spec.

**Cliff detection lower-half only:** Document why. A talent cliff above the boundary
means rostered players above it are genuinely better than the boundary player, which is
expected and correct. Detecting cliffs above the boundary would exclude players who
properly belong in the rostered pool.

**Swingman flagging:** `swingman` is an informational-only logical column in `cliff_metric`.
If a swingman's inclusion shifts the band mean ERA/WHIP by > 0.10 (material), emit a
`verbose`-gated note. No behavioral change.

**Positional adjustment sign convention:** Rename the formula argument to
`scarcity_premium[pos] = global_replacement_level - replacement_level[pos]`. Add a unit
test: `expect_gt(scarcity_premium["C"], 0)` and `expect_lte(scarcity_premium["OF"], 0)`
for a standard AL-only league fixture. This makes the sign convention a runnable check.

**Zero-sum property:** Enforce with an internal assertion:

```r
check <- sum(primary_hitter_slots * positional_adjustment[hitter_positions])
if (abs(check) > 1e-6) cli::cli_abort("rotostats_error_zero_sum_violation", ...)
```

**Name normalization order-of-operations:** Specify the explicit order in the spec:
1. Decompose Unicode to NFD
2. Strip combining diacritical marks (Unicode category Mn)
3. Convert to lowercase
4. Remove non-alphanumeric, non-space characters
5. Collapse multiple spaces
6. Trim whitespace

In R: `stringi::stri_trans_nfd()` → `stringi::stri_replace_all_regex("\\p{Mn}", "")`
→ `tolower()` → `str_replace_all("[^a-z0-9 ]", "")` → `str_squish()`.

**Trim method selection guidance:** Add a decision table to the spec:

| Condition | Recommended method |
|---|---|
| `is_keeper` column available | Exact exclusion; `trim_method` ignored |
| `is_keeper` absent, < 3 seasons | `"iqr"` — most robust in small samples |
| `is_keeper` absent, ≥ 3 seasons, high keeper density | `"mad"` — robust to right-skewed $1 pools |
| `is_keeper` absent, ≥ 3 seasons, bimodal structure expected | `"kde"` — detects cluster boundary directly; errors rather than silent bad estimate |

---

## VI. Separate Function: `replacement_from_prices()`

**Decision:** Implement as a standalone function, not as a `method` argument to `replacement()`.

**Rationale:** The input contract is fundamentally different. `replacement()` requires `projections` as its primary input; `replacement_from_prices()` requires historical auction `prices`. Making `projections` optional when `method = "prices"` produces a messy interface where required arguments depend on other argument values — a pattern R handles poorly and that produces confusing error messages. The algorithmic difference (boundary detection + band averaging vs. statistical trimming of a $1 auction pool) is large enough that a shared function body would be harder to read and test than two focused functions.

Both functions return the same output schema (Issue 10) and are interchangeable as the `replacement_fn` argument to `dollar_values()`.

**Interface:**

```r
replacement_from_prices(
  prices,                    # data frame: league_history$prices schema (see Issue 10 fix)
  n_teams,
  roster_slots,
  categories,
  trim_method   = "iqr",     # "iqr" | "mad" | "kde"
  calibration_min_n = 15L,   # from replacement_params
  verbose       = FALSE
)
```

`projections` is not an input. `sort_by`, `band_width`, `cliff_threshold`, `cliff_method`, `sp_ip_threshold`, `boundary_method`, `seed_method`, `normalize_to_season`, and all iteration parameters do not apply and must not appear in the signature.

**Algorithm:**

1. Filter `prices` to `price == 1` (or `price <= 1` for leagues with $1 minimum bids)
2. Exclude `is_keeper == TRUE` rows exactly when present; apply `trim_method` when `is_keeper` absent
3. If fewer than `calibration_min_n` remain after exclusion: `cli_warn("rotostats_warning_calibration_suppressed", ...)` and return `NULL`
4. Per position (inferred from player eligibility flags in the `prices` data): compute the mean end-of-season stat line of $1 players at that position
5. Compute positional adjustments using the same weighted-average logic as `replacement()` via shared internal helper
6. Return the same list schema as `replacement()` with `method = "prices"` in `params`

**Shared internal helpers** (live in `R/replacement_internal.R`):

- `format_replacement_output()` — constructs the return list and attaches `stat_units` attribute
- `compute_positional_adjustments()` — shared weighted-average positional adjustment logic
- `assert_replacement_output_contract()` — validates output schema before return

**Integration with `dollar_values()`:**

```r
dollar_values(
  projections,
  replacement_fn = replacement,             # default
  # or:
  replacement_fn = replacement_from_prices,
  ...
)
```

`dollar_values()` calls `replacement_fn(...)` at each iteration step. When `replacement_fn = replacement_from_prices`, historical prices do not change between passes — `dollar_values()` should detect `params$method == "prices"` and skip the inner replacement-update step, calling `replacement_fn` once and reusing the result across passes.

**Limitation:** Results are only as good as the historical price data. In leagues with high keeper density or fewer than 3 seasons of history, the $1 pool may be too thin to produce reliable estimates (suppressed per `calibration_min_n`). Most useful as a validation layer on `replacement()` output or as the primary method in leagues with 5+ seasons of auction history and low keeper density.

---

## Priority Summary

| Priority | Issues & Key Actions |
|---|---|
| **Before implementation** | #1 (warm-started coordinate descent; `boundary_method` + `seed_method` parameters); #2 (parameterize `positional_adjustment_method`; remove z-score averaging formula); #3 (parameterize `rate_stat_ranking_method`; remove `expected_team_IP` from `replacement()` interface); #8 (`normalize_to_season` parameter; `stat_units` attribute); #9 (define input schema + `checkmate` validation); #10 (define output schema); #11 (position-indexed output, two-way PAR formula); #12 (error decision matrix); §VI (`replacement_from_prices()` separate function; shared internal helpers in `R/replacement_internal.R`) |
| **Before code review** | #5 (parameterize `cliff_method`: `"mad"` default, `"fisher_jenks"`, `"gap_ratio"`); #7 (convergence criterion: assignment stability + stat change + max_iter); Section III (`replacement_params` object; dynamic K cap; 100 IP bimodal validation); #13 (expanded rate stat lookup + error message) |
| **Before stable release** | #4 (run pool diagnostic; implement `catcher_adjustment_method`; remove 0.75× hardcode from `priceguide`); #6 (pool size = n_teams × slots + K; swingman z-score recompute rule); V (sign convention test; zero-sum assertion; name normalization order; trim method table) |
