# rotostats (development version)

## New functions

* `sgp_denominators()` — Calibrates the SGP (Standings Gain Points) denominator
  for each rotisserie scoring category from historical team-season standings.
  Supports four estimation methods (`"ols"`, `"gap"`, `"trimmed_gap"`, `"sd"`),
  per-category calibration overrides via `cal_spec()`, and optional year-level
  bootstrap CIs. Returns an S3 object of class `"sgp_denominators"` that is
  fully backward-compatible with code that treated the return value as a named
  numeric vector.

* `convert_rate_stats()` — Stub; always aborts. Use
  `rate_conversion = "blended_pool"` (the default) for now.

* Weight constructors: `flat()`, `linear_decay()`, `exp_decay()`.

* Year-window helpers: `after()`, `before()`, `between()`, `last()`.

* Calibration spec constructors: `cal()`, `cal_spec()`.

* `expected_range_normal()` — Computes E[range] of *n* i.i.d. standard
  normals via numerical integration; used internally by `method = "sd"`.

## Implementation notes for maintainers

See `plans/sgp-denominators-architecture.md` for a full discussion of the
three non-obvious design decisions summarised below.

**Direction-aware rank-flip for inverse categories.**
`sgp_denominators()` uses a rank-1=worst / rank-n=best convention throughout.
For normal categories (HR, R, RBI, …) `rank(total)` already gives this —
higher totals get higher rank numbers and the OLS slope is positive.
For inverse categories (ERA, WHIP) a lower value is better, so `rank(ERA)`
would assign the best team rank 1 — the wrong end. The implementation applies
`n + 1 - rank(total)` before OLS fitting, making the best ERA team rank *n*
and producing a negative slope. The sign-check warning
`rotostats_warning_unexpected_slope_sign` fires if observed slope sign
disagrees with this convention, signalling corrupted or mislabelled data.
The flip lives in `R/sgp-denominators.R` at the `standings_pos` computation
block, and is mirrored in the bootstrap resampling path.

**`as.double` / `as.numeric` dispatch on list S3 objects.**
`as.numeric` is a base primitive that swallows S3 dispatch for list-based
objects — `as.numeric(x)` on an S3 list falls back to base coercion silently.
`as.double` dispatches correctly. The method is therefore registered as
`as.double.sgp_denominators`; `as.numeric` works because R's primitive
fallback delegates to `as.double`. All future list-based S3 classes in this
package should follow the same pattern: register coercions under `as.double`,
not `as.numeric`. See `R/sgp-denominators-s3.R` and
`?as.double.sgp_denominators`.

**OLS vs. SD estimand distinction.**
The `"ols"` and `"sd"` methods do not share an estimand. For a 12-team league
with σ = 25, the OLS denominator converges to ≈ 6.7 while the SD denominator
converges to ≈ 82 — a factor of 12. The SD formula
`σ × (n-1) / E[R_n]` targets the within-year expected gap in *counting units*,
whereas OLS targets `1 / |β̂|` which is determined by the covariance of rank
with total. Do not mix OLS denominators for some categories with SD
denominators for others in the same league valuation.
