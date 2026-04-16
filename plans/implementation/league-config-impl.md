# Implementation Reference: `league_config()`

> **Type:** API schema reference — not a conceptual spec
> **Last updated:** 2026-04-13

---

## Purpose

A validated S3 list that captures the structural settings of a rotisserie league.
Passed as the `config` argument to all downstream functions (`sgp_denominators()`,
`sgp()`, `replacement_level()`, `dollar_values()`, `par()`). Constructed once per
league and reused across calls.

**Boundary:** `league_config` holds only structural league settings — team count,
roster shape, scoring format, budget, and keeper status. Algorithmic choices
(`denominator_method`, `rate_stat_method`, `category_spec`, `weights`) remain as
function-level parameters.

---

## Function Signature

```r
league_config(
  n_teams       = 12L,           # integer: number of teams
  roster_slots,                  # named integer vector: hitter slots by position
  pitcher_slots = 9L,            # integer (one pool) or named integer vector c(SP=6L, RP=3L)
  categories,                    # character vector: scored stat categories
  league_type   = "mixed",       # "mixed" | "AL" | "NL"
  budget        = 260L,          # integer: per-team auction budget in dollars
  budget_split  = 0.60,          # numeric (0, 1): fraction of budget devoted to hitters
  keeper        = FALSE          # logical or list (see Keeper Settings below)
)
```

---

## Arguments

### `n_teams`

Positive integer. Number of teams in the league.

### `roster_slots`

Named integer vector of hitter roster slots by position. Combo slots (UTIL, MI, CI)
should be included — they count toward league depth for pool sizing even though they
have no independent replacement pool. Positions with 0 slots may be omitted.

Example:
```r
c(C=1, "1B"=1, "2B"=1, "3B"=1, SS=1, OF=5, UTIL=1)
```

DH is included for `league_type = "mixed"` or `"AL"` and excluded for `"NL"`. If DH
is supplied with `league_type = "NL"`, `league_config()` emits `cli_warn()` and drops
it.

### `pitcher_slots`

Either:
- **Single integer** (e.g., `9L`): total pitcher slots per team; SP/RP split is inferred
  by downstream functions from projection role flags or the 60/40 default.
- **Named integer vector** (e.g., `c(SP=6L, RP=3L)`): explicit SP/RP split.

When a single integer is supplied and downstream functions need the split, they infer
it and emit `cli_inform()` noting the inferred split. Provide the named vector to
suppress inference.

### `categories`

Character vector of scored category names. Canonical names: `HR`, `R`, `RBI`, `SB`,
`AVG`, `ERA`, `WHIP`, `K`, `W`, `SV`, `HLD`, `QS`, `SVHD`, `OPS`. Names are
normalized to uppercase at construction time; a `cli_inform()` is emitted if any were
changed.

Unrecognized category names are accepted with `cli_warn()` — the package does not
refuse non-standard categories.

### `league_type`

Controls DH eligibility and player pool filtering:
- `"mixed"`: all MLB players eligible; DH slot active if present in `roster_slots`
- `"AL"`: AL players only; DH active
- `"NL"`: NL players only; DH slot dropped with a warning if present

### `budget`

Per-team auction budget in dollars. Integer. Default 260.

### `budget_split`

Fraction of the total league budget devoted to hitters. Numeric in (0, 1). Default 0.60.
Used by `dollar_values()` to split `n_teams × budget` into hitter and pitcher allocation
pools before proportional distribution. Calibrate from observed spending history using
`calibrate_budget_split(league_history, config)`.

### `keeper`

Controls whether and how keeper adjustments are applied upstream of valuation.

- `FALSE` (default): redraft league; no keeper adjustments
- `TRUE`: keeper league with default settings (see below)
- Named list for explicit control:

```r
keeper = list(
  is_keeper    = TRUE,
  method       = "pool_shrink",   # see Keeper Methods below
  keeper_col   = "is_keeper",     # column name in projections flagging kept players
  salary_col   = "keeper_salary"  # column name for keeper contract salary (optional)
)
```

#### Keeper Methods

| Method | Description |
|--------|-------------|
| `"pool_shrink"` (default) | Remove kept players from the draftable pool before computing replacement level and dollar values. Budget is not adjusted — remaining dollars chase the remaining pool. |
| `"salary_adjust"` | Kept players stay in the pool. Their keeper salary is subtracted from league-wide available budget before dollar value computation. Requires `salary_col`. |
| `"none"` | Keeper flags are recorded but no adjustment is made. Useful for diagnostic comparison. |

When `keeper = TRUE`, defaults to `method = "pool_shrink"`, `keeper_col = "is_keeper"`,
`salary_col = NULL`.

---

## Return Value

An S3 object of class `c("league_config", "list")`. Fields are the resolved, validated
values of all arguments. A `print.league_config()` method summarizes the config:

```
League configuration
  Teams:      12 | Budget: $260 | Type: mixed
  Hitters:    C=1, 1B=1, 2B=1, 3B=1, SS=1, OF=5, UTIL=1 (11 slots)
  Pitchers:   SP=6, RP=3 (9 slots)
  Categories: R HR RBI SB AVG | W K SV ERA WHIP  (5x5)
  Keeper:     no
```

---

## Validation at Construction

| Condition | Response |
|-----------|----------|
| `n_teams` not a positive integer | `cli_abort()` |
| `roster_slots` not a named integer vector | `cli_abort()` |
| `pitcher_slots` contains names other than `SP` / `RP` | `cli_abort()` |
| `budget` not a positive integer | `cli_abort()` |
| `budget_split` not in (0, 1) | `cli_abort()` |
| `league_type` not one of `"mixed"`, `"AL"`, `"NL"` | `cli_abort()` |
| DH in `roster_slots` with `league_type = "NL"` | `cli_warn()`, DH dropped |
| Category name normalized to uppercase | `cli_inform()` (once, lists changed names) |
| Unrecognized category name | `cli_warn()` (once per name) |
| `keeper` is a list missing required fields | `cli_abort()`, names missing fields |
| `keeper` method `"salary_adjust"` with no `salary_col` | `cli_abort()` |

---

## Downstream Usage

All functions that accept `config` extract what they need:

| Function | Fields used |
|----------|-------------|
| `sgp_denominators()` | `n_teams`, `categories` |
| `sgp()` | `n_teams`, `pitcher_slots`, `roster_slots`, `categories` |
| `replacement_level()` | `n_teams`, `roster_slots`, `pitcher_slots`, `categories`, `league_type`, `keeper` |
| `dollar_values()` | `n_teams`, `budget`, `budget_split`, `categories`, `keeper` |
| `par()` | `categories` |

`category_spec` (per-category calibration overrides for SGP) is a separate argument to
`sgp_denominators()` — it is not part of `league_config`.

---

## Internal Helper: `pool_sizes(config)`

A non-exported helper used by both `sgp()` and `replacement_level()` to derive the number of rostered players in each pool from a `league_config` object. Centralises the formula so changes propagate to both call sites automatically.

```r
pool_sizes <- function(config) {
  primary_hitter_slots <- c("C", "1B", "2B", "3B", "SS", "OF", "DH")
  list(
    pitchers = config$n_teams * sum(config$pitcher_slots),
    hitters  = config$n_teams * sum(config$roster_slots[
                 intersect(names(config$roster_slots), primary_hitter_slots)])
  )
}
```

`primary_hitter_slots` excludes UTIL, MI, and CI (combo slots have no independent replacement pool; each player is counted once at their valuation position). DH is included for mixed and AL leagues; excluded for NL (DH is dropped from `roster_slots` at `league_config()` construction time for NL leagues).

---

## Usage Example

```r
lg <- league_config(
  n_teams       = 12L,
  roster_slots  = c(C=1, "1B"=1, "2B"=1, "3B"=1, SS=1, OF=5, UTIL=1),
  pitcher_slots = c(SP=6L, RP=3L),
  categories    = c("R", "HR", "RBI", "SB", "AVG", "W", "K", "SV", "ERA", "WHIP"),
  league_type   = "mixed",
  budget        = 260L
)

denoms  <- sgp_denominators(league_history, config = lg)
repl    <- replacement_level(projections, config = lg)
par_out <- par(repl, denominators = denoms)
dollars <- dollar_values(par_out, config = lg)
```
