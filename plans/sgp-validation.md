# SGP Validation Approach

> Created: 2026-04-13
> Related: `specs/spec-sgp.md`, `plans/sgp-issues.md` (M4), `plans/autoresearch-valuation.md`

---

## Overview

Validation for `sgp_denominators()` operates at four layers. Layers 1 and 2 are
development-time. Layers 3 and 4 are user-facing diagnostics that could ship as
`validate_denominators()`. The autoresearch LOYO study (§2b in
`autoresearch-valuation.md`) corresponds to Layer 2 at scale.

The spec's current LOYO target — Spearman ρ ≥ 0.97 between team dollar values and
standings — belongs in `dollar_values()`, not here. Dollar values are downstream of
SGP and incorporate replacement level and dollar allocation, both of which introduce
noise that is not attributable to denominator quality. See `plans/sgp-issues.md` M4
for full diagnosis.

---

## Layer 1 — Synthetic Unit Tests

**Purpose:** Confirm the implementation is faithful to the spec before real data touches it.

**Method:**
1. Generate synthetic league histories from a known data-generating process — e.g.,
   draw team HR totals from N(220, 30²) for a 12-team league over 5 seasons.
2. Compute the analytic "true denominator" from the DGP parameters.
3. Run `sgp_denominators()` on the synthetic data and verify recovery of the planted
   denominator within a tolerance band (e.g., ±5%).
4. Repeat across 1,000 simulated seasons to estimate bias and variance of the
   calibration method.

**Variants to test:**
- OLS vs. gap method: OLS should outperform on data with outlier teams.
- Flat vs. exp_decay weights: under a stationary DGP, flat should recover the true
  denominator; under a trend DGP, exp_decay should outperform.
- Window length 3 vs. 5 vs. all: shorter windows have higher variance; longer windows
  have lower variance but higher bias when there is a trend.

**What it catches:** Implementation bugs, edge cases (all teams tied, single-team
outlier, zero-variance season), rounding errors in counting-equivalent conversions for
rate stats.

---

## Layer 2 — LOYO Predictive Validity (Denominator Isolation)

**Purpose:** Determine which method, window length, and weight scheme produces
denominators that best predict next-year category standings from next-year team stats.
This is the autoresearch LOYO study.

**Method:**
1. Obtain a large multi-league dataset (NFBC, Fantrax public leagues — target: 50+
   leagues × 10+ years = 500+ league-seasons).
2. For each league, for each holdout year N (N = 3 through final year):
   a. Calibrate denominators on years 1–(N−1) using each method variant.
   b. Scale year-N team category totals by each denominator vector.
   c. Compute Spearman ρ between the scaled category totals and actual year-N
      per-category standings finish, for each category.
3. Average per-category ρ across all leagues and holdout years.
4. Rank method variants by mean ρ. Use this to set defaults.

**Method variants to compare:**
- Denominator method: `"gap"`, `"ols"` (OLS via `lm()`), `"trimmed_gap"`
- Window length: 3, 5, all non-excluded
- Weights: `"flat"`, `linear_decay()`, `exp_decay(0.9)`, `exp_decay(0.7)`
- Rate stat method: `"blended_pool"` (fixed, from projections), `"blended_pool"` (per-player),
  `"fixed_baseline"` (baseline from history), `"fixed_baseline"` (baseline from projections)
- SD fallback: `SD × E[R_n] / (n_teams − 1)` (order-statistics) vs. empirical ratio
  calibrated from league data — see `plans/sgp-issues.md` C5

**Primary metric:** Mean per-category Spearman ρ on holdout years, averaged across
leagues. Target threshold: ρ ≥ 0.85 per category.

**Secondary metric:** Year-over-year CV of denominators across the calibration window,
per category. Documents stability independent of predictive accuracy.

**Note on within-year rank correlation:** Do NOT use within-year Spearman ρ between
team category totals and category standings rank as a validation metric. This
correlation is 1.0 by construction — standings rank *is* determined by category totals
in rotisserie scoring. The LOYO design above avoids this by using denominators
calibrated on prior years to predict standings in a held-out year.

---

## Layer 3 — Denominator Stability Diagnostics

**Purpose:** Surface per-category calibration quality to the user at runtime, without
requiring held-out years.

**Methods (all computable from `league_history` alone):**

### 3a. Year-over-year CV

Compute denominators separately for each year in the calibration window. Report CV
(SD / mean) per category.

- **Threshold:** CV ≤ 10% is typical for stable categories (HR, R, RBI) per Tanner
  Bell's 2016 analysis. CV > 20% should trigger a `cli_warn()` naming the category.
- **Interpretation:** High CV in SB post-2022 is expected and explained by the
  structural break. High CV in HR unexpectedly warrants investigation.

### 3b. Within-year OLS regression R²

When `method = "ols"`, the `lm()` call produces R² as a free diagnostic. R² < 0.80
in a given year indicates the linear standings-rank ~ category-total relationship is a
poor fit; the denominator estimate for that year is unreliable.

- Emit a `cli_warn()` when R² < 0.80 in any year, naming the category and year.
- Log all per-year R² values in the returned object's metadata.

### 3c. Bootstrap confidence intervals

Resample team-year rows with replacement (1,000 replications). Recompute denominators
on each resample. Report 90% CI per category.

- Wide CIs (e.g., ±30% of point estimate) indicate high sensitivity to individual
  team-seasons — usually a thin history or outlier season problem.
- Makes the thin-history warning (< 3 seasons) quantitative: "SV CI spans [3.1, 8.7];
  consider supplying more history."
- Controlled by `bootstrap = TRUE` (off by default; opt-in due to compute cost).

---

## Layer 4 — Sensitivity Analysis

**Purpose:** Identify which categories and player types are most sensitive to
denominator precision.

**Method:**
1. After calibrating denominators, perturb each denominator by ±1 SD of its
   year-over-year distribution (derived from the Layer 3a CV calculation).
2. Recompute SGP and rank all players under the perturbed denominators.
3. Report: percentage of player rankings that shift by > 5 positions under ±1 SD
   perturbation, per category.

**Interpretation:** Categories with high rank-shift percentages are where denominator
accuracy matters most. These are candidates for per-category calibration overrides
(`category_spec`). Inform the user: "SB denominator instability affects 23% of player
rankings by > 5 positions; consider `SB = cal(years = after(2022))`."

**Implementation note:** Layer 4 requires `sgp()` output (player-level SGP), so it
cannot be run inside `sgp_denominators()` alone. It belongs in a joint
`validate_denominators(denominators, projections)` function or as a post-hoc step.

---

## `validate_denominators()` — Proposed User-Facing Function

Combines Layers 3 and 4 into a single diagnostic call:

```r
validate_denominators(
  denominators,             # output of sgp_denominators()
  league_history,           # the same history used for calibration
  projections = NULL,       # optional; required for Layer 4 sensitivity analysis
  bootstrap   = FALSE,      # Layer 3c; off by default
  n_boot      = 1000        # bootstrap replications
)
```

**Returns** a list with:
- `stability`: per-category CV and bootstrap CI (if `bootstrap = TRUE`)
- `fit`: per-year, per-category OLS R² (if `method = "ols"`)
- `sensitivity`: rank-shift percentages per category (if `projections` supplied)
- A `summary()` method that emits a formatted table via `cli`

**Phase:** Phase 2 feature — after the core `sgp_denominators()` + `sgp()` pipeline
ships. Not a prerequisite for Phase 1.

---

## Where the Spearman ρ ≥ 0.97 Target Belongs

The full-system target — Spearman ρ ≥ 0.97 between team dollar values and final
standings points — is valid but belongs in `dollar_values()` validation, not here.
Move it there verbatim. The Layer 2 LOYO study (ρ ≥ 0.85 per category) is the
denominator-specific analog.
