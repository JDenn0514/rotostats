# Critical Review: `specs/spec-replacement.md`

Synthesized from two independent reviews. Issues are grouped by type and ordered by priority.

---

## I. Critical Conceptual Flaws

### 1. Z-score ranking and positional boundary detection are circularly dependent

The spec rejects position-specific z-score pools, arguing that positional scarcity enters only through per-position replacement-level subtraction. This creates a logical circularity: the ranking that determines who sits at the boundary must be position-aware if you're computing per-position boundaries. When you rank players from a unified pool, you're comparing a 12th-best C (scoring -2σ) directly against a 12th-best 1B (scoring -0.5σ) without accounting for the fact that 1B is simply deeper. On the first pass, before PAR estimates exist, z-score ranking determines assignments — but those assignments are needed to compute the position-specific replacement levels that make z-score ranking position-aware. The "iteration resolves this" argument doesn't fix the bootstrap problem; it defers it.

### 2. Global weighted z-score averaging mixes incompatible units

The formula `global_hitter_repl = Σ(primary_hitter_slots[pos] × repl_zscore[pos]) / Σ(primary_hitter_slots)` takes a roster-slot-weighted mean of per-position replacement-level z-scores. This is statistically incoherent. A replacement C's z-score and a replacement 1B's z-score come from different quantiles of the same distribution — they are not drawn from a common scale in the way averaging assumes. Replacement C might be at -2.1σ, replacement 1B at -0.8σ, purely because 1B is deep. Averaging these z-scores produces a number with no clear interpretation. If the downstream goal is positional adjustment, that adjustment should be done in dollar or SGP units, not z-scores.

### 3. Rate stat weighting via `expected_team_IP/AB` conflates two distinct concepts

The formula `ERA_contribution = (repl_ERA − pitcher_ERA) × pitcher_IP / expected_team_IP` normalizes each pitcher's contribution to team-level production, which makes replacement level league-depth-sensitive in an undesirable way. A borderline swingman with 100 IP will rank higher in a league with shallow pitching depth (small `expected_team_IP`) than in a deep-pitching league, all else equal. Ranking should reflect absolute pitcher quality; league-specific normalization belongs in `sgp()`, not in boundary detection.

### 4. Catcher calibration failure is patched, not fixed

The spec acknowledges that replacement-level z-scores for catchers "may still be inflated despite the unified pool" and that `priceguide` applies a 0.75× catcher discount as "an empirical correction." If the replacement-level algorithm produces prices 30% too high for an entire position, the root cause hasn't been identified — only the symptom suppressed. The spec should either diagnose why catcher z-scores are inflated (likely driven by a handful of elite catching defenders skewing the pool) or introduce a principled positional adjustment rather than an unexplained multiplier applied downstream.

---

## II. Statistically Unsound or Under-Specified Methodology

### 5. σ estimation for cliff detection is under-specified

The cliff detection rule triggers on a drop of ≥1.5σ between adjacent players, but the spec never says what σ is computed over. The entire position pool? The band itself? A reference population? With a band of only 7 players, sample standard deviation is highly variable — and you're estimating it from the very tail of the distribution where you're trying to detect discontinuities. Using the band's own SD to detect outliers in the band is a weak statistical procedure. The method should be specified, not implied.

### 6. Z-score pool composition is ambiguous

The pool is "sized to `n_teams × total_slots_for_type + band_width`," but it's unclear whether `band_width` here means the full band (2K+1) or just the lower half (K). A 5% difference in pool size shifts all z-scores. Swingmen (pitchers with unknown role) are especially problematic: are they included in the pitcher pool before role inference? If a swingman is classified as SP in one iteration and RP in another, do its z-scores change between iterations? No answer is provided.

### 7. Multi-position convergence criterion is fully deferred

The spec delegates convergence of the multi-position assignment loop entirely to `dollar_values()`, with the note that "2–3 passes are typical." This is not a specification — it's a guess. There is no maximum iteration count, no explicit convergence criterion (e.g., Δ replacement stat < ε), and no fallback if the loop doesn't converge. Two different `dollar_values()` implementations could converge differently and produce different final replacement levels.

### 8. Raw projected totals assumption requires documentation of downstream dependencies

The justification for not normalizing to a full-season baseline is that "`sgp()` uses raw projected stats and normalization would double-apply playing time weighting." This is a load-bearing assumption about `sgp()`'s implementation that is not documented. If `sgp()` is later changed, this rationale breaks silently. Partial-season projections (injured players, call-up timing) are also not addressed.

---

## III. Unjustified Constants and Thresholds

Every numeric constant in the spec is presented without empirical justification.

| Constant | Location | Problem |
|---|---|---|
| **K = 3** (band half-width) | Default value | No validation showing K=3 minimizes year-over-year variance vs. K=1, K=2, or K=4. Simultaneously claimed as the default and marked TBD in the function signature. |
| **1.5σ** (cliff threshold) | Cliff detection | Borrowed from IQR outlier notation (1.5 × IQR) but applied to a different context. Not calibrated against real projection distributions. High-variance stats (ERA) and low-variance stats will trigger at very different player gaps. |
| **≥4 players** (cliff detection disabled) | Minimum-N guard | Why not 3 or 5? No sample-size justification given. |
| **100 IP** (SP/RP split) | Role inference | Claimed to "sit reliably in the trough" of the bimodal distribution, but no citation or empirical data is provided. Stability across projection vintages and vendors is not addressed. |
| **67/33 SP/RP split** | Fallback when `pitcher_slots` is a scalar | Not the composition of any common league format (most use ~50/50 or 60/40). No basis given. |
| **15%** (team IP/AB divergence warning) | Historical calibration | Round number, no justification. A 14.9% divergence passes silently; 15.1% warns. |
| **≥15 players** ($1 calibration minimum) | $1 pool trimming | No statistical basis given. ~30 is a common minimum for mean estimation; 15 is conservatively low or conservatively high depending on the goal. |

The spec's Known Validity Threats section explicitly acknowledges K=3 is untested for thin AL-only pools (where it spans 58% of the entire positive pool for some positions) — yet recommends monitoring rather than specifying a data-driven default.

---

## IV. Specification Completeness Problems (Blocking)

### 9. Data input format entirely unspecified

Required column names, column types, multi-position eligibility encoding, and league type detection (AL-only vs. mixed vs. NL-only) are all deferred. The DH inclusion logic in the global replacement formula explicitly depends on league type, yet there is no `league_type` parameter in the function signature. The spec appears to assume the code will infer league type from whether `roster_slots["DH"] > 0`, but this inference is never written down.

### 10. Output format unspecified

Exact output column names for `replacement_stats`, position label conventions, and stat name consistency with the `projections` input are all deferred. This directly blocks the design of `sgp()` and `dollar_values()`, which consume this output.

### 11. Two-way player output contract is ambiguous

The spec says "Combined PAR = sum of hitting PAR + pitching PAR" and delegates slot deduplication to `dollar_values()`. But the output format for two-way players is not defined. Does `replacement_stats` contain one row per player, or one row per player-per-sport? If a two-way player is top-50 as a hitter and top-100 as a pitcher, which pool does their boundary slot count against? This is a load-bearing contract.

### 12. Error handling strategy is not specified

The spec describes many failure modes — cliff detection disabled, $1 calibration suppressed, KDE trough not found, role inference ambiguous — but does not say which should `stop()`, which should `warning()`, and which should silently proceed. Different implementers will make different choices.

### 13. Rate stat denominator lookup is incomplete for real leagues

The lookup covers standard categories but OBP, SVHD, and QS handling is incomplete. The escape hatch (`rate_stat_denominators`) is mentioned but the error message for an unknown category is not specified. This is a common silent-failure vector.

---

## V. Smaller Issues Worth Addressing

- **Band symmetry is unjustified**: Why ±K? An asymmetric band (more players below the boundary than above) might better capture the shape of the talent distribution cliff.
- **Cliff detection is lower-half only** without explanation. If there's a genuine cliff above the boundary, it would be ignored.
- **Swingman flagging is ambiguous**: The spec says swingmen are "flagged in the output" but does not say whether this is an informational column or triggers changed behavior.
- **Positional adjustment sign convention is confusing**: The formula `global − replacement[pos]` is called an "adjustment" but reads more like a difference. The claim that positive values indicate scarce positions (C, SS) requires careful verification — if catchers are genuinely scarce, their replacement level should be *lower* than the global mean, making `global − replacement_C` positive only if that is true in the data.
- **Zero-sum property is asserted but not enforced**: The spec calls non-zero weighted sum of adjustments "a bug," but defines no error or assertion to catch it.
- **Name normalization order-of-operations is not specified**: Accent stripping, punctuation removal, and casing are described in prose but the order is not given. Two implementers normalizing names differently will fail to match the same player.
- **Trim method selection guidance is absent**: Three methods (IQR, MAD, KDE) are offered with no guidance on when to choose each.

---

## Priority Summary

| Priority | Issues |
|---|---|
| **Must resolve before implementation** | #1 (z-score circularity), #2 (z-score averaging incoherence), #3 (rate stat weighting design), #9 (input format), #10 (output format), #11 (two-way player contract), league type detection (part of #9) |
| **Must resolve before code review** | #5 (σ estimation method), #7 (convergence criterion), all of §III (unjustified constants), #12 (error handling strategy) |
| **Should resolve before stable release** | #4 (catcher calibration root cause), #8 (partial-season handling), #13 (rate stat denominator coverage), swingman flagging semantics |
| **Nice to have** | Band symmetry justification, cliff detection scope, sign convention clarification, name normalization order-of-ops |
