# Implementation Reference: `calibrate_budget_split()`

> **Type:** API schema reference — not a conceptual spec
> **Last updated:** 2026-04-16

---

## Purpose

Compute the empirical hitter/pitcher budget split from historical auction price data and
return an updated `league_config` with `budget_split` set from observed spending. Call
once before `dollar_values()` when league price history is available; use the returned
config in all downstream calls.

**Pattern:** Same as `sgp_denominators()` — calibrate from history, then pass the
updated config forward. The default `config$budget_split = 0.60` is a reasonable prior;
this function replaces it with a league-specific estimate.

---

## Function Signature

```r
calibrate_budget_split(
  league_history,             # league_history object with non-NULL prices component
  config,                     # league_config object to update
  exclude_keepers = FALSE,    # logical: exclude is_keeper = TRUE rows before computing
  verbose         = TRUE      # logical: emit cli_inform() reporting the computed split
)
```

---

## Arguments

### `league_history`

A `league_history` object (produced by `league_history()`). The `$prices` component
must be non-NULL — abort with `rotostats_error_missing_prices` if it is NULL.

`prices` must contain a `player_type` column (`"batter"` or `"pitcher"`) in addition to
the columns required by `league_history()`. This column is not required at
`league_history()` construction time but is required here. If absent, abort with
`rotostats_error_missing_player_type`.

**Year filtering:** The caller is responsible for restricting `prices` to the desired
seasons before constructing `league_history`. All rows in `prices` are used with equal
weight — there is no `years` or `exclude_years` parameter on this function.

### `config`

A `league_config` object. `config$budget_split` will be replaced with the computed
value. All other fields are unchanged.

### `exclude_keepers`

Default `FALSE`. When `TRUE`, rows with `is_keeper = TRUE` in `prices` are excluded
before computing the split. Use when keeper prices are systematically below market value
and would distort the open-market hitter/pitcher ratio. Has no effect when `prices`
lacks an `is_keeper` column (no rows are excluded, no warning is emitted).

### `verbose`

Default `TRUE`. When `TRUE`, emits `cli_inform()` reporting the computed split, the
number of seasons and player-auction records used, and the previous default value being
replaced:

```
calibrate_budget_split: 0.623 (hitters) / 0.377 (pitchers)
  Computed from 2,341 player-auctions across 7 seasons (2018–2024)
  Replaces default budget_split = 0.60
```

---

## Computation

```r
# Subset to batter / pitcher rows
hitter_rows  <- prices[prices$player_type == "batter",  ]
pitcher_rows <- prices[prices$player_type == "pitcher", ]

# Pooled split: total dollars to hitters / total dollars in auction
budget_split <- sum(hitter_rows$price) / sum(prices$price)
```

**Pooled rather than year-averaged.** Summing across all years weights each dollar
equally — seasons with higher total spending have proportionally more influence.
Year-averaging would weight each season equally regardless of how many players were
auctioned. Pooled is the correct default when budgets are consistent across years.

If `prices$price` contains negative values (invalid), those rows are excluded and
`cli_warn()` is emitted naming the count of excluded rows (inherits from
`league_history()` construction-time check, but applied again here as a guard).

---

## Return Value

An updated `league_config` object with `config$budget_split` replaced. All other fields
are unchanged. The returned object is a valid `league_config` — it passes all
`league_config()` validation checks.

No `print` method changes — `print.league_config()` already displays `budget_split`.

---

## Validation and Error Handling

| Condition | Response |
|-----------|----------|
| `league_history$prices` is NULL | `cli_abort()` — `rotostats_error_missing_prices` |
| `prices` missing `player_type` column | `cli_abort()` — `rotostats_error_missing_player_type` |
| `prices$player_type` contains values other than `"batter"` / `"pitcher"` | `cli_warn()`, names unexpected values; those rows excluded from computation |
| `sum(prices$price) = 0` after filtering | `cli_abort()` — total prices sum to zero; cannot compute ratio |
| Computed `budget_split` outside (0.40, 0.80) | `cli_warn()` — unusual result; reports computed value and suggests verifying `player_type` classification; does not abort |
| `exclude_keepers = TRUE` but `prices` has no `is_keeper` column | No warning — silently proceeds using all rows |

---

## Downstream Usage

| Function | How `budget_split` is used |
|----------|---------------------------|
| `dollar_values()` | Splits total budget into `alloc_h` (hitters) and `alloc_p` (pitchers) before proportional allocation |
| `pvm()` with `cat_pct = "auto"` | Derives per-category budget fractions: `CAT%[hitter_cat] = budget_split / n_hitter_cats` |

Both functions read `config$budget_split` — pass the returned config to both.

---

## Notes on `player_type` in `prices`

`player_type` is not required by `league_history()` at construction time, but it is
required here. Users who add it to their `prices` CSV before calling `league_history()`
will have it available automatically:

```
year, player_name, price, player_type
2024, Aaron Judge, 52, batter
2024, Gerrit Cole, 31, pitcher
```

Alternatively, join against a roster file or projection source after construction:

```r
prices_typed <- prices |>
  dplyr::left_join(roster_file[c("player_name", "player_type")], by = "player_name")
history <- league_history(team_season, prices = prices_typed)
```

The `player_type` values must match `"batter"` and `"pitcher"` exactly (case-insensitive
normalization is applied at construction; a `cli_inform()` is emitted if any were
changed).

---

## Usage Example

```r
history <- league_history(
  team_season = readr::read_csv("team_totals.csv"),
  prices      = readr::read_csv("auction_prices.csv")  # must have player_type column
)

config <- league_config(
  n_teams      = 12L,
  roster_slots = c(C=1, "1B"=1, "2B"=1, "3B"=1, SS=1, OF=5, UTIL=1),
  pitcher_slots = c(SP=6L, RP=3L),
  categories   = c("R", "HR", "RBI", "SB", "AVG", "W", "K", "SV", "ERA", "WHIP"),
  budget       = 260L
)

# Replace default budget_split = 0.60 with league-specific estimate
config <- calibrate_budget_split(history, config)

# config$budget_split now reflects observed spending — pass to all downstream calls
repl    <- replacement_level(projections, config = config)
dollars <- dollar_values(
  list(sgp = par(repl, denominators), zscore = zar(repl), pvm = pvm(repl)),
  config = config
)
```
