# SGP Spec Adversarial Review

> Generated: 2026-04-12
> Source: `specs/spec-sgp.md`
> Reviewer role: statistician + expert rotisserie baseball player

---

## Summary Table

| ID | Severity | Issue |
|----|----------|-------|
| C1 | Critical | Gap method = range/(n−1); outlier sensitivity unacknowledged |
| C2 | Critical | `standings_finish` requirement not removed from formal definition |
| C3 | Critical | Calibration window simultaneously TBD and 5 years |
| C4 | Critical | Sanity check formula `total_sgp ≈ n_teams/2` is numerically wrong |
| C5 | Significant | SD method scaling constant undefined — method unimplementable |
| S1 | Significant | 2020 exclusion not justified for rate stats |
| S2 | Significant | R/RBI structural break flagged in footnote only, not in defaults |
| S3 | Significant | `fixed_baseline` denominator units ambiguous vs. `blended_pool` |
| S4 | Significant | Linearity assumption is wrong; uniformity is the actual assumption |
| S5 | Significant | Pool baseline in `blended_pool` is ambiguous (pre- vs. post-player) |
| M1 | Minor | HLD vs. HD conflates naming convention with definitional variation |
| M2 | Minor | `list()` escape hatch inconsistent with validation-first design |
| M3 | Minor | Sign convention in ERA formula is non-standard |
| M4 | Minor | LOYO target conflates SGP quality with dollar allocation quality |
| M5 | Minor | Denominator uncertainty not acknowledged or propagated |

---

## Critical Issues

### C1. The gap method is mathematically equivalent to range/(n−1) — this is not acknowledged

The spec describes the gap method as "average of all pairwise gaps between adjacent teams in the standings." For n teams sorted by category totals t₁ ≤ t₂ ≤ … ≤ tₙ, the adjacent gaps are g₁ = t₂−t₁, g₂ = t₃−t₂, …, gₙ₋₁ = tₙ−tₙ₋₁. Their average:

```
(g₁ + g₂ + ... + g_{n-1}) / (n-1) = (t_n - t_1) / (n-1) = range / (n-1)
```

This is a telescoping sum. The spec's claim that the gap method "directly answers the question of interest" is misleading — it is just the range normalized by competitive depth. It is therefore *maximally sensitive to outlier teams* (the single worst and single best). A dominant team or a tanking team inflates the denominator, systematically understating every player's value relative to the competitive middle. The SD method, which the spec positions as a fallback, is actually more robust to this. The spec should acknowledge the equivalence, its implication for outlier sensitivity, and revisit whether `trimmed_gap` should be the default instead.

---

### C2. Internal contradiction: `standings_finish` required vs. not required for gap method

The formal definition under `sgp_denominators` states:

> *"Requires `standings_finish` column in `league_history`; aborts with a clear error if absent."*

Q1-SGP-7 (closed) explicitly corrects this:

> *"Correction to prior spec: The previous draft stated that `standings_finish` is required for the gap method. This was incorrect."*

The formal definition has never been updated. Implementers reading only the top of the spec will build in a spurious hard requirement. This is the highest-priority editorial fix.

---

### C3. Calibration window default is simultaneously "TBD" and "5 years"

The formal definition reads: *"Default window: TBD — candidates are most-recent 3, 5, or all available non-excluded seasons."*

Q1-SGP-3 (closed) resolves this: *"Recommended starting default: `years = 5`."* The API example in Q1-SGP-3 shows `years = 5`. The prose definition was never updated to reflect this closed decision. A reader of the formal definition alone would not know the default is 5.

---

### C4. The validation sanity check formula is wrong or unanchored

> *"The median rostered player should have `total_sgp ≈ n_teams / 2`"*

No derivation is provided, and the formula doesn't follow from the denominator definition. Here is what does follow: if denominators calibrate so that 1 SGP = 1 standings place, the *total* SGP across all rostered players in one category ≈ (n_teams − 1) (the range of available standings positions). Summed across C categories, total league-wide SGP ≈ C × (n_teams − 1). The median player's total_sgp = C × (n_teams − 1) / (n_teams × roster_size). For 12 teams, 10 categories, 25-man rosters: 10 × 11 / 300 ≈ 0.37. That is not 6 (= n_teams/2).

The formula `n_teams / 2` appears to conflate total standings points per category with per-player SGP. The sanity check needs a derivation or should be replaced with one that is anchored.

---

### C5. The SD method's scaling constant is undefined

> *"Standard deviation of team-level category totals, scaled by a constant proportional to n_teams."*

No formula is given for this constant. The SD method is referenced as a cross-check and as the fallback when `standings_finish` is unavailable, but without a defined constant it is unimplementable from the spec alone. The standard fantasy baseball convention (e.g., Tanner Bell's approach) scales SD by `n_teams / Z` where Z depends on normal quantile assumptions — but this is not stated. The spec should either define the constant or cite the derivation.

---

## Significant Issues

### S1. 2020 exclusion applied to rate stats without basis

The spec excludes 2020 by default on the grounds that it was a "60-game COVID season; unrepresentative totals." This argument applies cleanly to counting stats (HR, R, RBI, SB — obviously compressed). But ERA, WHIP, and AVG are rate stats: they are normalized by IP and AB respectively and are not inherently affected by sample size in the same direction. A pitcher's ERA in 60 games is not systematically different from his ERA in 162 games due to game count alone. The spec should either justify excluding 2020 for rate stats (e.g., higher variance, sample-size uncertainty in denominator calibration) or carve out an exception for rate categories.

---

### S2. SB structural break logic not extended to R and RBI

The spec makes a strong case that the 2023 shift ban + larger bases approximately doubled SB and recommends `SB = cal(years = after(2022), weights = exp_decay(0.7))`. But Q1-SGP-9 itself notes: *"the 2023 structural break…raises the question of whether pre-2023 seasons are meaningfully comparable…particularly for R and RBI as well as SB."*

This flagged concern appears only in a footnote in the Q&A section and is not surfaced in the formal definition, assumptions table, or `category_spec` recommended defaults. If R and RBI were also materially affected (runs per game increased roughly 4–5% post-shift ban), the spec's recommended default is incomplete. At minimum, the Assumptions table should list "2023 R and RBI structural break" as a testable claim.

---

### S3. `fixed_baseline` requires differently-calibrated denominators — spec doesn't explain how

The spec states: *"Denominators must be calibrated in counting-equivalent units (extra ER prevented per standings point, etc.), not raw ERA units."* But `sgp_denominators()` returns a single named vector (e.g., `era = 0.15`). It's not clear whether this is a raw-ERA denominator or a counting-equivalent denominator, or whether the function returns different values depending on which method the user later passes to `sgp()`. If the same denominator vector is consumed by both `"blended_pool"` and `"fixed_baseline"`, the units are wrong for one of them. The spec needs to clarify whether denominators are method-specific or whether `sgp()` handles the unit conversion internally.

---

### S4. Assumption "linear relationship between category totals and standings points" is the wrong assumption

The Assumptions table lists: *"Linear relationship between category totals and standings points — testable by checking residuals of standings rank ~ category total regression per year."*

The relationship between category totals and standings points in a rotisserie league is, by construction, *monotone but not necessarily linear* — you rank teams and assign integer points. What the gap method actually assumes is that adjacent gaps are roughly uniform — i.e., team category totals are approximately uniformly distributed. Testing regression residuals would detect non-monotonicity but not the uniformity assumption that actually matters for gap-method validity. The assumption should be restated: "Adjacent gaps in team category totals are approximately uniform across standings positions — testable by plotting team totals against standings rank and checking for clustering or heavy tails."

---

### S5. Pool baseline in `blended_pool` is underspecified

The formula uses `avg_ERA` described as "the pool's combined rate stat." It's not specified whether `avg_ERA` is:

- **(a)** The pre-player pool ERA, recomputed for each player being evaluated (correct but computationally heavy), or
- **(b)** A fixed league-average ERA applied uniformly to all players (approximation)

If (b), then a player is included in the pool baseline their own calculation is measured against, which creates a circular dependency and slightly biases low-IP pitchers' SGP upward (their small IP contribution to pool ERA is being subtracted from itself). The spec should state which interpretation is intended and acknowledge the approximation error if (b) is chosen.

---

## Minor Issues

### M1. HLD vs. HD are not different definitions

> *"its definition varies across leagues (SV + HD vs. SV + HLD)"*

`HD` and `HLD` are both column-name abbreviations for "holds" — the difference is naming convention, not baseball definition. The actual definitional variation in leagues is usually whether holds require meeting a save situation vs. any multi-inning relief appearance, or whether blown saves offset holds. The spec conflates column-naming convention with definitional variation.

---

### M2. `list()` escape hatch is philosophically inconsistent

> *"Bare `list()` is accepted in place of `cal()` as an escape hatch, without construction-time validation."*

The spec is otherwise emphatic about early validation and clear error messages (`cli_abort()` for missing columns, etc.). Silently accepting unvalidated input through an escape hatch is inconsistent with that design. If the escape hatch is retained, it should emit a `cli_warn()` at use time noting that it bypasses validation.

---

### M3. Sign convention in blended_pool formula is non-standard

The formula writes:

```
ERA_SGP[i] = (...blended_ERA... − avg_ERA) / −era_denom
```

Negating the denominator rather than rearranging the numerator is an unusual convention. The mathematically equivalent and less surprising form is:

```
ERA_SGP[i] = (avg_ERA − blended_ERA) / era_denom
```

The current form will produce correct results but will confuse anyone auditing the code against the spec.

---

### M4. LOYO validation target confounds SGP quality with dollar allocation quality

> *"Primary target: Spearman ρ ≥ 0.97 between team dollar values and final standings points on held-out years."*

Dollar values are downstream of SGP — they incorporate replacement level, the dollar allocation split between hitters and pitchers, and the dollar conversion formula. A failing LOYO result could reflect a poor SGP denominator *or* a poor replacement level *or* a poor dollar conversion formula. A cleaner primary validation target for SGP specifically would be: Spearman ρ between team-level category SGP totals and actual category standings finish in the held-out year, by category. Dollar value correlation belongs in the `dollar_values()` spec, not here.

---

### M5. Denominator uncertainty is not addressed

The spec defines point estimates for denominators but denominators are estimates with variance. A category with high year-over-year variance in its denominator produces uncertain SGP values downstream. The spec mentions checking CV of denominators as a validation step but never propagates that uncertainty into SGP outputs or flags it as a limitation. At minimum, the spec should acknowledge that denominator uncertainty scales linearly into all PAR and dollar values downstream.
