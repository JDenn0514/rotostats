# Error and Warning Classes

All `cli_abort()` and `cli_warn()` calls must use a class from this table.

## Errors

| Class | Thrown by | Condition | Recovery guidance |
|-------|-----------|-----------|-------------------|
| `rotostats_error_not_data_frame` | TBD | `data` is not a data.frame | Pass a data.frame |
| `rotostats_error_missing_replacement_attrs` | `par()`, `zar()`, `pvm()`, `zaa()` | `replacement` object missing `projections` or `config` attribute | Use the `replacement_level()` constructor |
| `rotostats_error_stat_units_mismatch` | `zaa()`, `pvm()` | `attr(replacement, "stat_units")` is not `"raw_projected"` | Ensure replacement level is built from raw projections |
| `rotostats_error_category_mismatch` | `par()` | `names(replacement_sgp)` don't match `sgp_[cat]` columns in `sgp_output` | Align `scoring_categories` across `sgp()` and `par()` calls |
| `rotostats_error_zero_pool` | `pvm()`, `dollar_values()` | `Pool[c] = 0` for any category (all rostered players sub-replacement), or `sum(val[group]) = 0` in dollar allocation | Widen the player pool or lower the replacement level |
| `rotostats_error_cat_pct_sum` | `pvm()` | `cat_pct` named vector does not sum to 1.0 within tolerance | Rescale `cat_pct` so values sum to 1.0 |
| `rotostats_error_invalid_anchor` | `dollar_values()` | Valuation element has `attr(..., "anchor") != "replacement"` | Use `replacement_level()` to produce the anchor |
| `rotostats_error_invalid_valuation_units` | `dollar_values()` | Valuation element has unrecognized `units` attribute value | Use a supported units value (see `?dollar_values`) |
| `rotostats_error_missing_config_field` | `dollar_values()` | `config` missing `budget`, `n_teams`, or `budget_split` | Supply all required fields via `league_config()` |
| `rotostats_error_invalid_budget_split` | `dollar_values()` | `config$budget_split` not in (0, 1) | Pass a value strictly between 0 and 1 |
| `rotostats_error_negative_allocatable_budget` | `dollar_values()` | $1 minimums exhaust hitter or pitcher budget after applying `budget_split` | Increase budget or adjust `budget_split` |
| `rotostats_error_keeper_config_missing` | `dollar_values()` | `keepers` non-NULL but `config$keeper = FALSE` | Set `config$keeper = TRUE` when passing keepers |
| `rotostats_error_missing_keeper_columns` | `dollar_values()`, `adjust_keeper_inflation()` | `keepers` data frame missing player identity or salary column | Include required columns in `keepers` |
| `rotostats_error_missing_prices` | `calibrate_budget_split()` | `league_history$prices` is NULL | Supply historical prices in `league_history` |
| `rotostats_error_missing_player_type` | `calibrate_budget_split()` | `prices` missing `player_type` column | Add a `player_type` column to the prices data frame |
| `rotostats_error_missing_team_season` | `sgp_denominators()` | `league_history$team_season` is NULL or not a data.frame | Pass a list or `league_history` object whose `$team_season` slot is a non-NULL data.frame |
| `rotostats_error_missing_required_column` | `sgp_denominators()` | `year` or `team_id` column absent from `team_season` | Add the missing column(s) to `league_history$team_season` |
| `rotostats_error_invalid_rate_conversion` | `sgp_denominators()` | `rate_conversion` is not `"blended_pool"` or `"fixed_baseline"` | Pass one of the two supported values |
| `rotostats_error_invalid_method` | `sgp_denominators()` | `method` is not one of `"ols"`, `"gap"`, `"trimmed_gap"`, `"sd"` | Pass one of the four supported method strings |
| `rotostats_error_invalid_category_spec` | `sgp_denominators()`, `cal_spec()` | `category_spec` is not a `"cal_spec"` object; or a raw `list()` was used inside `cal_spec()` | Construct with `cal_spec(CAT = cal(...))` |
| `rotostats_error_n_teams_mismatch` | `sgp_denominators()` | Explicit `n_teams` does not match a year's row count in `team_season` | Either omit `n_teams` (infer per year) or ensure every year has exactly `n_teams` rows |
| `rotostats_error_missing_category_column` | `sgp_denominators()` | A named element of `scoring_categories` is absent from `team_season` | Add the missing column to `league_history$team_season` or correct the category name |
| `rotostats_error_not_implemented` | `convert_rate_stats()` | Function is called (stub only in this release) | Use `rate_conversion = "blended_pool"` (the default) |
| `rotostats_error_invalid_year_window` | `apply_year_window()` (internal) | Unrecognized year-window specification passed as `years` | Use `"all"`, an integer vector, or a helper: `after()`, `before()`, `between()`, `last()` |
| `rotostats_error_invalid_weights` | `sgp_denominators()` | `weights` argument is not a valid weight specification | Pass a constructor result (`flat()`, `linear_decay()`, `exp_decay()`), or the shorthand `"flat"` or `"linear"` |
| `rotostats_error_invalid_cal_years` | `cal()` | `years` field in `cal()` is not a valid year window | See `after()`, `before()`, `between()`, `last()` |
| `rotostats_error_invalid_cal_weights` | `cal()` | `weights` field in `cal()` is not a valid weight specification | See `flat()`, `linear_decay()`, `exp_decay()` |
| `rotostats_error_invalid_cal_field` | `cal()` | Unrecognized field name passed to `cal()` | Only `years` and `weights` are accepted |
| `rotostats_error_invalid_parameter` | `sgp_denominators()` | `n_bootstrap` or another parameter fails type or range validation | Pass a non-negative integer scalar for `n_bootstrap`; see `?sgp_denominators` for constraints |

## Warnings

| Class | Thrown by | Condition | Recovery guidance |
|-------|-----------|-----------|-------------------|
| `rotostats_warning_example` | TBD | Example warning condition | — |
| `rotostats_warning_pvm_concentration` | `pvm()` | Any `pvm[i, c] > 0.25` | Review category concentration; consider rebalancing |
| `rotostats_warning_pvm_sum` | `pvm()` | `sum(pvm[j, c])` deviates from 1.0 by more than 1e-10 for any category | Check PVM inputs for floating-point accumulation errors |
| `rotostats_warning_keeper_player_not_found` | `dollar_values()`, `adjust_keeper_inflation()` | Player in `keepers` not found in valuation output | Verify player IDs match between `keepers` and projections |
| `rotostats_warning_negative_inflation` | `adjust_keeper_inflation()` | `inflation_mult < 1.0` — keeper salaries exceed open-market model value | Review keeper contracts; negative inflation is unusual but valid |
| `rotostats_warning_unnamed_valuation_list` | `dollar_values()` | Unnamed list supplied; positional labels (A, B, C) used | Name the elements of the valuation list |
| `rotostats_warning_budget_reconciliation` | `dollar_values()` | `\|sum(dollars_m) - total_budget\| > 1` for SGP or z-score method | Check for floating-point accumulation or rounding |
| `rotostats_warning_na_category_value` | `sgp_denominators()` | NA or NaN in a scored category column; names affected team-year pairs | Investigate and impute or remove the affected rows before calling `sgp_denominators()` |
| `rotostats_warning_unrecognized_column` | `sgp_denominators()` | Unrecognized column in `team_season` (emitted once per call) | Pass `scoring_categories` explicitly or remove extra columns from `team_season` |
| `rotostats_warning_uneven_team_counts` | `sgp_denominators()` | Different team counts across years when `n_teams` is NULL | Supply `n_teams` explicitly to enforce a consistent count, or filter `team_season` to matching years |
| `rotostats_warning_thin_calibration_window` | `sgp_denominators()` | Fewer than 3 seasons in a category's effective calibration window | Widen the `years` window or the per-category `cal(years = ...)` override |
| `rotostats_warning_structural_break_flat_weights` | `sgp_denominators()` | Calibration window spans pre- and post-2023 seasons with flat weighting; names the category | Use `category_spec = cal_spec(SB = cal(years = after(2022)))` or switch to `exp_decay()` |
| `rotostats_warning_zero_variance_category` | `sgp_denominators()` | Zero variance in a category-year under OLS; slope set to NA | Remove or investigate the constant-value year; consider excluding it via `exclude_years` |
| `rotostats_warning_low_r_squared` | `sgp_denominators()` | OLS R² < 0.80; names category and year | Inspect data quality for the flagged category-year; consider `method = "gap"` for noisy categories |
| `rotostats_warning_near_zero_slope` | `sgp_denominators()` | `abs(slope) < denom_floor`; denominator set to Inf | Check data quality; increase `denom_floor` if the category genuinely has low discrimination |
| `rotostats_warning_unexpected_slope_sign` | `sgp_denominators()` | Positive OLS slope for an inverse category (ERA, WHIP), or negative slope for a normal category, after the direction-aware rank transformation | Verify that inverse categories are correctly declared and that `league_history` data is not corrupted |
| `rotostats_warning_no_valid_years` | `sgp_denominators()` | No valid years remain for a category after exclusions; denominator set to NA | Widen `years` window or reduce `exclude_years` |
| `rotostats_warning_high_denominator_cv` | `sgp_denominators()` | Year-over-year denominator CV > 20%; names category and CV value | Consider a shorter or more recent calibration window to reduce instability |
