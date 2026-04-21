# rotostats (development version)

## New arguments

* `sgp_denominators()` gains an `inverse_categories` argument (default
  `c("ERA", "WHIP")`) to declare which scoring categories use a
  direction-flipped rank before OLS fitting. Leagues scoring OAVG, BB9, or
  other lower-is-better categories can now pass these names directly instead
  of modifying package source. When omitted, the default set is silently
  intersected with the league's actual scored categories, so batting-only
  leagues and partial-rate-stat leagues work without modification. When
  supplied explicitly, every element must appear in the effective scored-category
  set (otherwise aborts with `rotostats_error_invalid_inverse_categories`).
  Existing callers are unaffected.

* `inverse_categories` infrastructure: new `inverse_categories()` accessor
  (package-level lower-is-better category list); `league_config()` gains an
  optional `inverse_categories` field (validated, uppercased, stored;
  `NULL` = inherit from package default); `sgp_denominators()` default changes
  from `c("ERA", "WHIP")` to `NULL` with three-layer resolution (user arg >
  `config$inverse_categories` > `intersect(scoring_categories,
  inverse_categories())`); legacy ERA/WHIP behavior preserved unchanged when
  those categories are scored.

## New functions

* `par()` — Computes per-player Points Above Replacement (PAR) in SGP units.
  Takes a `replacement_level()` output and `sgp_denominators()` output, calls
  `sgp()` internally to convert projected statistics, and subtracts the
  position-specific replacement-level SGP from each player's individual SGP.
  SP and RP use separate replacement baselines derived from their respective rows
  in `replacement$replacement_stats`. Returns a data frame with one `par_<CAT>`
  column per scored category plus `total_par`; when `include_raw = TRUE`,
  prepends the raw `sgp_<CAT>` and `total_sgp` columns before subtraction.
  Emits `rotostats_warning_band_check` when the median `total_par` of the +/-K
  replacement band around the roster boundary exceeds `boundary_threshold`
  (default 1.0 SGP unit), indicating a mis-calibrated replacement level.
  Note: the band check cannot detect `n_teams` miscalibration because the PAR
  anchor and the boundary identification both use the same `n_teams` value from
  the `replacement_level()` call.

* `replacement_level()` — Per-position replacement-level stat-line estimator
  that serves as the zero-dollar PAR baseline for rotisserie auction valuation;
  implements boundary-band averaging with dynamic K cap, cliff detection, SP/RP
  role inference, and a multi-position iteration loop.

* `replacement_from_prices()` — Derives replacement-level stat lines from
  historical \$1 auction prices (trimmed mean method) rather than projections;
  shares the same output schema as `replacement_level()`.

* `default_replacement_params` — Exported named list of all nine numeric
  constants used by `replacement_level()` (band half-width, cliff thresholds,
  SP/RP IP cutoff, convergence tolerances, etc.); individual entries are
  overridden via `replacement_params = list(band_width_K = 2L)`.

* `rate_stat_denominators()` — Returns the built-in named character vector
  mapping rate-stat category names to their denominator columns (e.g.,
  `ERA -> "IP"`, `AVG -> "AB"`); used internally by `replacement_level()` for
  weighted averaging and unknown-rate-stat validation.

* `sgp()` — Converts projected per-player statistics into SGP units using
  pre-calibrated denominators from `sgp_denominators()`. Implements the
  blended-pool rate-stat method with a projection-pool baseline; pool sizes
  are derived automatically from `league_config`. Returns a data frame with
  one `sgp_<CAT>` column per scored category plus `total_sgp`.

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

## New arguments

* `sgp_denominators()` gains an `inverse_categories` argument (default
  `c("ERA", "WHIP")`) to declare which scoring categories use a
  direction-flipped rank before OLS fitting. Leagues scoring OAVG, BB9, or
  other lower-is-better categories can now pass these names directly instead
  of modifying package source. When omitted, the default set is silently
  intersected with the league's actual scored categories, so batting-only
  leagues and partial-rate-stat leagues work without modification. When
  supplied explicitly, every element must appear in the effective scored-category
  set (otherwise aborts with `rotostats_error_invalid_inverse_categories`).
  Existing callers are unaffected.

## Improvements

* `replacement_level()`: The multi-position convergence loop now detects
  higher-order assignment cycles (periods 3–5) using a rolling state-hash
  buffer of depth `replacement_params$cycle_history_window` (default 5).
  Previously only 2-cycles were detected. This eliminates the
  `rotostats_warning_convergence_not_reached` false-alarm that occurred in
  ~3% of highly multi-eligible pools.

* `replacement_level()` and `replacement_from_prices()` now emit
  `rotostats_warning_name_match_failure` (when `verbose = TRUE`) to
  diagnose player-name mismatches between data sources. These warnings are
  purely diagnostic — calibration output is unchanged.

## Breaking changes

* `sgp()` now validates `pool_baseline` at the top of the function.
  Passing `pool_baseline = "per_player"` or
  `pool_baseline = "universal_constants"` now aborts immediately with
  `rotostats_error_invalid_pool_baseline` rather than propagating to a
  different downstream error. Only `pool_baseline = "projection_pool"`
  (the default) is accepted.

* `sgp()` now emits `rotostats_warning_zero_playing_time` (instead of
  `rotostats_warning_missing_category_column`) when a player has 0 or `NA`
  projected IP or AB for a scored rate stat. Callers using
  `withCallingHandlers(rotostats_warning_missing_category_column = ...)` to
  intercept zero-playing-time rows must update to
  `withCallingHandlers(rotostats_warning_zero_playing_time = ...)`.
  The condition triggering `rotostats_warning_missing_category_column` is
  unchanged: it fires only when a scored category column is entirely absent
  from `projections`.

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
