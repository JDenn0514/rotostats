# Implementation Reference: `league_history()`

> **Type:** API schema reference — not a conceptual spec
> **Last updated:** 2026-04-14

---

## Purpose

A validated S3 list that holds historical league data — team-season category totals and
optionally auction price history. Passed as the `league_history` argument to
`sgp_denominators()` and `replacement_level()`. Constructed once and reused across calls.

**Boundary:** `league_history` holds only historical data. Structural league settings
(`n_teams`, `roster_slots`, `categories`, `budget`) live in `league_config`. Exclusion
and window decisions (`exclude_years`, `outlier_filter`, `years`) remain as function-level
parameters in `sgp_denominators()` — do not pre-filter `team_season` before passing.
The exception is `prices`: no window parameter is provided for price history, so the
caller is responsible for filtering to the desired years before passing (e.g., exclude
2020, restrict to the last 5 seasons).

---

## Function Signature

```r
league_history(
  team_season,      # data frame: wide, one row per team-year, category totals
  prices = NULL     # data frame: historical auction results (optional)
)
```

---

## Arguments

### `team_season`

Required. A data frame in wide format: one row per team per season. One column per scored
category (season totals), plus required identifier columns. Long-format data should be
converted with `tidyr::pivot_wider()` before passing.

**Required columns:**

| Column | Type | Notes |
|--------|------|-------|
| `year` | `<integer>` | Season year |
| `team_id` | `<character>` | Team identifier, stable across years |
| one per scored category | `<numeric>` | Season totals; names should match `config$categories` |

**Optional columns:**

| Column | Type | Notes |
|--------|------|-------|
| `roto_pts` | `<numeric>` | Team's total roto points for the season. Column name configurable via `roto_pts_col` in `sgp_denominators()`. Used for the standings correlation validation check only — not used in denominator computation. |
| `{category}_pts` | `<numeric>` | Per-category roto points (e.g., `HR_pts`, `SB_pts`). Auto-detected by naming convention in `sgp_denominators()`. When present, used as `standings_pos` in method data frames — handles ties and non-integer scoring correctly. When absent, `standings_pos` is derived from `rank(total, ties.method = "average")` within each year. |
| `IP` | `<numeric>` | Total team innings pitched. Used by `replacement_level()` to validate projection-derived IP totals against historical norms. Required only if you want that validation check — absence silently skips it. |
| `AB` | `<numeric>` | Total team at-bats. Used by `replacement_level()` to validate projection-derived AB totals. Same optional behavior as `IP`. |

Column names are silently normalized to uppercase at construction time. A one-time
`cli_inform()` is emitted if any names were changed.

Cross-validation against `league_config` — e.g., confirming that category column names
match `config$categories` — happens at the function call site (`sgp_denominators()`,
`replacement_level()`), not at construction time. This keeps each constructor's
validation focused on its own structure.

### `prices`

Optional. A data frame of historical auction results, one row per player per auction year.
Used by `replacement_level()` for the trimmed-mean $1 calibration check. If `NULL`, that
check is skipped without warning.

The caller is responsible for filtering to the desired years before passing. All rows are
used with equal weight — no window parameter is provided.

**Required columns:**

| Column | Type | Notes |
|--------|------|-------|
| `year` | `<integer>` | Auction season |
| `player_name` | `<character>` | Used for fallback matching when `player_id` absent |
| `price` | `<numeric>` | Final auction price paid |

**Optional columns:**

| Column | Type | Notes |
|--------|------|-------|
| `player_id` | `<character>` | MLBAM ID preferred; exact match when present, normalized name fallback when absent |
| `is_keeper` | `<logical>` | `TRUE` if player was a keeper retained below market value. When present, flagged players are excluded exactly before the $1 calibration. When absent, `trim_method` in `replacement_level()` controls outlier removal from the $1 pool. |
| `player_type` | `<character>` | `"batter"` or `"pitcher"`. Not used by `league_history()` itself; required by `calibrate_budget_split()`. Case-insensitive normalization applied at construction; `cli_inform()` emitted if any values were changed. |

---

## Return Value

An S3 object of class `c("league_history", "list")` with components `$team_season` and
`$prices` (NULL if not supplied). A `print.league_history()` method summarizes the object:

```
League history
  Team seasons: 12 teams × 7 years (2018–2024)
  Stat columns: HR R RBI SB AVG ERA WHIP K W SV IP AB  (12 cols)
  Prices:       2,847 player-seasons (2018–2024)
  Note:         2020 present — consider exclude_years = 2020 in sgp_denominators()
```

The 2020 note is `cli_inform()` — not a warning. Exclusion is the user's choice at the
call site.

---

## Validation at Construction

| Condition | Response |
|-----------|----------|
| `team_season` not a data frame | `cli_abort()` |
| `year` or `team_id` absent from `team_season` | `cli_abort()` |
| `year` not coercible to integer | `cli_abort()` |
| `team_id` not character | `cli_abort()` |
| Column name normalized to uppercase | `cli_inform()` (once, lists changed names) |
| Year with inconsistent team count across seasons | `cli_warn()`, names the affected years |
| NA in any non-identifier column | `cli_warn()`, names affected team-year pairs |
| `prices` supplied but not a data frame | `cli_abort()` |
| `prices` missing `year`, `player_name`, or `price` | `cli_abort()`, names missing columns |
| `prices$price` contains negative values | `cli_warn()`, names affected rows |
| 2020 present in `team_season$year` | `cli_inform()` — suggests `exclude_years = 2020` |

---

## Downstream Usage

| Function | Components used |
|----------|-----------------|
| `sgp_denominators()` | `$team_season` |
| `replacement_level()` | `$prices` (optional), `$team_season$IP` / `$AB` (optional, validation only) |
| `calibrate_budget_split()` | `$prices` (required; must include `player_type` column) |

---

## Usage Example

```r
history <- league_history(
  team_season = readr::read_csv("moonlight_graham_team_totals.csv"),
  prices      = readr::read_csv("moonlight_graham_auction_prices.csv")
)

# Each function extracts what it needs; unused components are silently ignored
denoms <- sgp_denominators(history, config = lg)
repl   <- replacement_level(projections, config = lg, league_history = history)
```
