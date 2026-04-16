# Error and Warning Classes

All `cli_abort()` and `cli_warn()` calls must use a class from this table.

## Errors

| Class | Thrown by | Condition |
|-------|-----------|-----------|
| `rotostats_error_not_data_frame` | TBD | `data` is not a data.frame |
| `rotostats_error_missing_replacement_attrs` | `par()`, `zar()`, `pvm()`, `zaa()` | `replacement` object missing `projections` or `config` attribute |
| `rotostats_error_stat_units_mismatch` | `zaa()`, `pvm()` | `attr(replacement, "stat_units")` is not `"raw_projected"` |
| `rotostats_error_category_mismatch` | `par()` | `names(replacement_sgp)` don't match `sgp_[cat]` columns in `sgp_output` |
| `rotostats_error_zero_pool` | `pvm()`, `dollar_values()` | `Pool[c] = 0` for any category (all rostered players sub-replacement), or `sum(val[group]) = 0` in dollar allocation |
| `rotostats_error_cat_pct_sum` | `pvm()` | `cat_pct` named vector does not sum to 1.0 within tolerance |
| `rotostats_error_missing_replacement_attrs` | `par()`, `zar()`, `pvm()`, `zaa()` | (see above) |
| `rotostats_error_invalid_anchor` | `dollar_values()` | Valuation element has `attr(..., "anchor") != "replacement"` |
| `rotostats_error_invalid_valuation_units` | `dollar_values()` | Valuation element has unrecognized `units` attribute value |
| `rotostats_error_missing_config_field` | `dollar_values()` | `config` missing `budget`, `n_teams`, or `budget_split` |
| `rotostats_error_invalid_budget_split` | `dollar_values()` | `config$budget_split` not in (0, 1) |
| `rotostats_error_negative_allocatable_budget` | `dollar_values()` | $1 minimums exhaust hitter or pitcher budget after applying `budget_split` |
| `rotostats_error_keeper_config_missing` | `dollar_values()` | `keepers` non-NULL but `config$keeper = FALSE` |
| `rotostats_error_missing_keeper_columns` | `dollar_values()`, `adjust_keeper_inflation()` | `keepers` data frame missing player identity or salary column |
| `rotostats_error_missing_prices` | `calibrate_budget_split()` | `league_history$prices` is NULL |
| `rotostats_error_missing_player_type` | `calibrate_budget_split()` | `prices` missing `player_type` column |

## Warnings

| Class | Thrown by | Condition |
|-------|-----------|-----------|
| `rotostats_warning_example` | TBD | Example warning condition |
| `rotostats_warning_pvm_concentration` | `pvm()` | Any `pvm[i, c] > 0.25` |
| `rotostats_warning_pvm_sum` | `pvm()` | `sum(pvm[j, c])` deviates from 1.0 by more than 1e-10 for any category |
| `rotostats_warning_keeper_player_not_found` | `dollar_values()`, `adjust_keeper_inflation()` | Player in `keepers` not found in valuation output |
| `rotostats_warning_negative_inflation` | `adjust_keeper_inflation()` | `inflation_mult < 1.0` — keeper salaries exceed open-market model value |
| `rotostats_warning_unnamed_valuation_list` | `dollar_values()` | Unnamed list supplied; positional labels (A, B, C) used |
| `rotostats_warning_budget_reconciliation` | `dollar_values()` | `\|sum(dollars_m) - total_budget\| > 1` for SGP or z-score method |
