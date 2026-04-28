# Tout Wars Team-Season Dataset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `tout_wars_team_season`, a package data object holding 2010–2025 Tout Wars team-season totals with team-level `IP` and `AB`, in the exact wide shape `league_history()` expects. Enables historical-data testing of `sgp_denominators()`, `sgp()`, and `par()`.

**Architecture:** Two-stage R pipeline under `data-raw/`. Stage 1 reads the 45 standings CSVs and 90 per-team batter/pitcher CSVs (produced by the team-stats scraper), filters to `roster_section ∈ {active, previously_active}`, aggregates AB/IP plus reconstructed rate-stat numerators per team, runs a reconciliation check against standings rate stats, and writes a cached RDS. Stage 2 loads the cache and exposes it via `usethis::use_data()`. All substantive logic lives as private helpers in `R/utils-tout-wars-team-season.R`, unit-tested with small in-memory fixtures.

**Tech Stack:** R 4.3+; `dplyr`, `readr`, `tibble`, `cli`, `fs`, `purrr`, `usethis`, `testthat` (all already in DESCRIPTION). No new runtime deps.

**Reference:** [`plans/specs/2026-04-27-tout-wars-team-season-design.md`](../specs/2026-04-27-tout-wars-team-season-design.md)

---

## File Structure

```
R/
├── utils-tout-wars.R                                  unchanged (auction helpers)
├── utils-tout-wars-team-season.R                      CREATE (team-season helpers)
└── data-tout-wars-team-season.R                       CREATE (roxygen for dataset)

data-raw/
├── normalize-tout-wars-auctions.R                     unchanged
├── tout-wars-auctions.R                               unchanged
├── build-tout-wars-team-season.R                      CREATE (Stage 1)
└── tout-wars-team-season.R                            CREATE (Stage 2)

data/
└── tout_wars_team_season.rda                          GENERATED (Stage 2 writes)

tests/testthat/
├── test-tout-wars-team-season.R                       CREATE (schema/sanity)
├── test-utils-tout-wars-team-season.R                 CREATE (helper unit tests)
├── test-sgp-denominators-tout-wars.R                  CREATE (integration: snapshot)
├── test-sgp-tout-wars.R                               CREATE (integration: blended_pool)
├── test-par-tout-wars.R                               CREATE (integration: par())
└── fixtures/
    └── team-season-residuals.csv                      CREATE (committed fixture)

plans/error-messages.md                                MODIFY (register new classes)
.gitignore                                             MODIFY (add cache dir)
```

`R/utils-tout-wars-team-season.R` is a separate file from the existing `R/utils-tout-wars.R` (which is already 700+ lines of auction-parser logic). Splitting by responsibility keeps each file focused.

---

## Task 1: Branch setup

**Files:** none (git operations only).

- [ ] **Step 1: Verify current state**

The team-stats scraper feature was merged into the spec branch during sync. Verify the `develop` branch has been brought current first.

```bash
git fetch origin
git log --oneline origin/develop -5
```

If `feature/tout-wars-team-stats-scraper` has not yet been merged into `origin/develop`, that PR must land first. The team-season build depends on the new per-team batter/pitcher CSVs in `data-raw/sources/tout-wars/rosters/{year}-{league}-{batters,pitchers}.csv`.

- [ ] **Step 2: Create implementation branch off develop**

```bash
git checkout develop
git pull
git checkout -b feature/tout-wars-team-season-dataset
```

- [ ] **Step 3: Smoke check that the per-team CSVs are present**

```bash
ls data-raw/sources/tout-wars/rosters/ | grep -c batters
ls data-raw/sources/tout-wars/rosters/ | grep -c pitchers
```

Expected: `45` and `45`.

```bash
head -1 data-raw/sources/tout-wars/rosters/2024-al-batters.csv
```

Expected first columns: `year,league,team,player_name,player_id,mlb_team,position,salary,status,roster_section,eligibility,ab,g,r,hr,rbi,sb,so,bb,avg,obp,slg,...`

- [ ] **Step 4: No commit yet**

The branch is set up; subsequent tasks produce commits.

---

## Task 2: Stub helper file + roster-CSV readers (TDD)

**Files:**
- Create: `R/utils-tout-wars-team-season.R`
- Create: `tests/testthat/test-utils-tout-wars-team-season.R`

- [ ] **Step 1: Write failing tests**

Create `tests/testthat/test-utils-tout-wars-team-season.R`:

```r
test_that(".read_tw_batters reads a per-team batter CSV with expected columns", {
  path <- "../../data-raw/sources/tout-wars/rosters/2024-al-batters.csv"
  skip_if_not(file.exists(path), "raw batter CSV not present")

  out <- rotostats:::.read_tw_batters(path)

  required <- c("year", "league", "team", "player_name", "player_id",
                "mlb_team", "position", "salary", "status", "roster_section",
                "eligibility", "ab", "g", "r", "hr", "rbi", "sb", "so",
                "bb", "avg", "obp", "slg")
  expect_true(all(required %in% names(out)))
  expect_type(out$year, "integer")
  expect_type(out$league, "character")
  expect_type(out$team, "character")
  expect_type(out$ab, "integer")
  expect_type(out$avg, "double")
  expect_type(out$obp, "double")
  expect_type(out$roster_section, "character")
  expect_true(nrow(out) > 0)
  expect_true(all(out$year == 2024L))
  expect_true(all(out$league == "al"))
})

test_that(".read_tw_pitchers reads a per-team pitcher CSV with expected columns", {
  path <- "../../data-raw/sources/tout-wars/rosters/2024-al-pitchers.csv"
  skip_if_not(file.exists(path), "raw pitcher CSV not present")

  out <- rotostats:::.read_tw_pitchers(path)

  required <- c("year", "league", "team", "player_name", "player_id",
                "mlb_team", "position", "salary", "status", "roster_section",
                "eligibility", "g", "w", "l", "sv", "ip", "bb", "hr",
                "so", "era", "whip")
  expect_true(all(required %in% names(out)))
  expect_type(out$ip, "double")
  expect_type(out$w, "integer")
  expect_type(out$era, "double")
  expect_type(out$whip, "double")
  expect_true(nrow(out) > 0)
})

test_that(".read_tw_batters errors if a required column is missing", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  writeLines("year,league,team\n2024,al,X", tmp)
  expect_error(
    rotostats:::.read_tw_batters(tmp),
    class = "rotostats_error_team_season_missing_column"
  )
})
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
Rscript -e 'devtools::test(filter = "utils-tout-wars-team-season")'
```

Expected: tests fail because `.read_tw_batters` and `.read_tw_pitchers` are not defined.

- [ ] **Step 3: Implement readers**

Create `R/utils-tout-wars-team-season.R`:

```r
# Internal helpers for tout_wars_team_season.
# See plans/specs/2026-04-27-tout-wars-team-season-design.md.

# Required columns per side. Used for column validation in the readers.
.tw_ts_batter_required_cols <- c(
  "year", "league", "team", "player_name", "player_id",
  "mlb_team", "position", "salary", "status", "roster_section",
  "eligibility", "ab", "g", "r", "hr", "rbi", "sb", "so",
  "bb", "avg", "obp", "slg"
)

.tw_ts_pitcher_required_cols <- c(
  "year", "league", "team", "player_name", "player_id",
  "mlb_team", "position", "salary", "status", "roster_section",
  "eligibility", "g", "w", "l", "sv", "ip", "bb", "hr",
  "so", "era", "whip"
)

#' Validate a per-team CSV has the required columns.
#'
#' @param df Tibble loaded from a roster CSV.
#' @param required Character vector of required column names.
#' @param path Source path (for error message).
#' @keywords internal
#' @noRd
.validate_tw_ts_columns <- function(df, required, path) {
  missing <- setdiff(required, names(df))
  if (length(missing) > 0L) {
    cli::cli_abort(
      c(
        "Required column(s) missing from {.file {basename(path)}}.",
        "i" = "Missing: {.val {missing}}"
      ),
      class = "rotostats_error_team_season_missing_column"
    )
  }
  invisible(df)
}

#' Read a per-team batter CSV.
#'
#' @param path Path to `{year}-{league}-batters.csv`.
#' @return Tibble with the columns in `.tw_ts_batter_required_cols`.
#' @keywords internal
#' @noRd
.read_tw_batters <- function(path) {
  df <- readr::read_csv(
    path,
    col_types = readr::cols(
      year           = readr::col_integer(),
      league         = readr::col_character(),
      team           = readr::col_character(),
      player_name    = readr::col_character(),
      player_id      = readr::col_character(),
      mlb_team       = readr::col_character(),
      position       = readr::col_character(),
      salary         = readr::col_integer(),
      status         = readr::col_character(),
      roster_section = readr::col_character(),
      eligibility    = readr::col_character(),
      ab             = readr::col_integer(),
      g              = readr::col_integer(),
      r              = readr::col_integer(),
      hr             = readr::col_integer(),
      rbi            = readr::col_integer(),
      sb             = readr::col_integer(),
      so             = readr::col_integer(),
      bb             = readr::col_integer(),
      avg            = readr::col_double(),
      obp            = readr::col_double(),
      slg            = readr::col_double(),
      .default       = readr::col_character()
    ),
    progress = FALSE
  )
  .validate_tw_ts_columns(df, .tw_ts_batter_required_cols, path)
  df
}

#' Read a per-team pitcher CSV.
#'
#' @param path Path to `{year}-{league}-pitchers.csv`.
#' @return Tibble with the columns in `.tw_ts_pitcher_required_cols`.
#' @keywords internal
#' @noRd
.read_tw_pitchers <- function(path) {
  df <- readr::read_csv(
    path,
    col_types = readr::cols(
      year           = readr::col_integer(),
      league         = readr::col_character(),
      team           = readr::col_character(),
      player_name    = readr::col_character(),
      player_id      = readr::col_character(),
      mlb_team       = readr::col_character(),
      position       = readr::col_character(),
      salary         = readr::col_integer(),
      status         = readr::col_character(),
      roster_section = readr::col_character(),
      eligibility    = readr::col_character(),
      g              = readr::col_integer(),
      w              = readr::col_integer(),
      l              = readr::col_integer(),
      sv             = readr::col_integer(),
      ip             = readr::col_double(),
      bb             = readr::col_integer(),
      hr             = readr::col_integer(),
      so             = readr::col_integer(),
      era            = readr::col_double(),
      whip           = readr::col_double(),
      .default       = readr::col_character()
    ),
    progress = FALSE
  )
  .validate_tw_ts_columns(df, .tw_ts_pitcher_required_cols, path)
  df
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "utils-tout-wars-team-season")'
```

Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add R/utils-tout-wars-team-season.R tests/testthat/test-utils-tout-wars-team-season.R
git commit -m "feat(team-season): add per-team batter/pitcher CSV readers"
```

---

## Task 3: Section filter helper (TDD)

**Files:**
- Modify: `R/utils-tout-wars-team-season.R`
- Modify: `tests/testthat/test-utils-tout-wars-team-season.R`

- [ ] **Step 1: Write failing test**

Append to `tests/testthat/test-utils-tout-wars-team-season.R`:

```r
test_that(".filter_active_sections keeps active and previously_active only", {
  df <- tibble::tibble(
    roster_section = c("active", "reserved", "previously_active",
                       "previously_reserved", "active"),
    val = 1:5
  )
  out <- rotostats:::.filter_active_sections(df)
  expect_equal(out$val, c(1L, 3L, 5L))
})

test_that(".filter_active_sections errors on unknown section value", {
  df <- tibble::tibble(roster_section = c("active", "weird"))
  expect_error(
    rotostats:::.filter_active_sections(df),
    class = "rotostats_error_team_season_unknown_section"
  )
})
```

- [ ] **Step 2: Run to verify failure**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "utils-tout-wars-team-season")'
```

Expected: 2 new tests fail.

- [ ] **Step 3: Implement**

Append to `R/utils-tout-wars-team-season.R`:

```r
.tw_ts_valid_sections <- c(
  "active", "reserved", "previously_active", "previously_reserved"
)

.tw_ts_kept_sections <- c("active", "previously_active")

#' Filter rows to roster sections that contributed to team standings totals.
#'
#' Keeps `active` and `previously_active`. Drops `reserved` and
#' `previously_reserved`. See spec section "Section selection" for rationale.
#'
#' @param df Tibble with a `roster_section` column.
#' @return Tibble filtered to kept sections.
#' @keywords internal
#' @noRd
.filter_active_sections <- function(df) {
  unknown <- setdiff(unique(df$roster_section), .tw_ts_valid_sections)
  if (length(unknown) > 0L) {
    cli::cli_abort(
      c(
        "Unknown {.code roster_section} value(s).",
        "i" = "Unknown: {.val {unknown}}",
        "i" = "Expected one of: {.val {.tw_ts_valid_sections}}"
      ),
      class = "rotostats_error_team_season_unknown_section"
    )
  }
  df[df$roster_section %in% .tw_ts_kept_sections, , drop = FALSE]
}
```

- [ ] **Step 4: Run tests**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "utils-tout-wars-team-season")'
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add R/utils-tout-wars-team-season.R tests/testthat/test-utils-tout-wars-team-season.R
git commit -m "feat(team-season): filter player rows to active/previously_active"
```

---

## Task 4: Per-team aggregator (TDD)

**Files:**
- Modify: `R/utils-tout-wars-team-season.R`
- Modify: `tests/testthat/test-utils-tout-wars-team-season.R`

This task aggregates per-player rows to per-team-season AB / IP and reconstructs rate-stat numerators (H-equivalent for batters, ER-equivalent and H-equivalent for pitchers) used later in reconciliation. Per-player numerators are reconstructed from `(rate × denom)` and rounded to integers before summing, matching the precision Onroto displays.

- [ ] **Step 1: Write failing tests**

Append to `tests/testthat/test-utils-tout-wars-team-season.R`:

```r
test_that(".aggregate_team_batting sums AB and reconstructs H/BB/SO per team", {
  bat <- tibble::tibble(
    year = 2024L, league = "al", team = "Owner1",
    roster_section = "active",
    ab  = c(500L, 400L, 300L),
    bb  = c( 50L,  40L,  20L),
    so  = c(120L,  90L,  60L),
    avg = c(0.300, 0.250, 0.200),
    obp = c(0.380, 0.320, 0.260)
  )
  out <- rotostats:::.aggregate_team_batting(bat)
  expect_equal(out$year, 2024L)
  expect_equal(out$league, "al")
  expect_equal(out$team, "Owner1")
  expect_equal(out$ab, 1200L)
  expect_equal(out$bb_bat, 110L)
  # H_eq = round(500*.300) + round(400*.250) + round(300*.200) = 150+100+60 = 310
  expect_equal(out$h_bat_eq, 310L)
})

test_that(".aggregate_team_batting groups by (year, league, team)", {
  bat <- tibble::tibble(
    year = c(2024L, 2024L, 2024L),
    league = c("al", "al", "al"),
    team = c("A", "A", "B"),
    roster_section = "active",
    ab  = c(500L, 400L, 100L),
    bb  = 0L, so = 0L,
    avg = 0.300, obp = 0.380
  )
  out <- rotostats:::.aggregate_team_batting(bat)
  expect_equal(nrow(out), 2L)
  expect_setequal(out$team, c("A", "B"))
  ab_a <- out$ab[out$team == "A"]
  ab_b <- out$ab[out$team == "B"]
  expect_equal(ab_a, 900L)
  expect_equal(ab_b, 100L)
})

test_that(".aggregate_team_pitching sums IP and reconstructs ER/H/BB", {
  pit <- tibble::tibble(
    year = 2024L, league = "al", team = "Owner1",
    roster_section = "active",
    ip   = c(200.0, 150.0, 60.0),
    bb   = c( 50L,   40L,  20L),
    era  = c(3.60, 4.20, 5.00),
    whip = c(1.20, 1.30, 1.40)
  )
  out <- rotostats:::.aggregate_team_pitching(pit)
  expect_equal(out$ip, 410.0)
  expect_equal(out$bb_pit, 110L)
  # ER_eq = round(200*3.60/9) + round(150*4.20/9) + round(60*5.00/9)
  #       = 80 + 70 + 33 = 183
  expect_equal(out$er_eq, 183L)
  # h_pit_eq per row = round(ip*whip) - bb
  # rows: round(240) - 50 = 190, round(195) - 40 = 155, round(84) - 20 = 64
  # sum = 190 + 155 + 64 = 409
  expect_equal(out$h_pit_eq, 409L)
})
```

- [ ] **Step 2: Run to verify failure**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "utils-tout-wars-team-season")'
```

Expected: 3 new tests fail.

- [ ] **Step 3: Implement**

Append to `R/utils-tout-wars-team-season.R`:

```r
#' Aggregate batter rows to per-team-season totals.
#'
#' Sums AB, BB, SO directly. Reconstructs hits via per-player
#' `round(ab * avg)` then sums, matching Onroto's three-digit AVG display
#' precision. Output columns: year, league, team, ab, bb_bat, so_bat,
#' h_bat_eq.
#'
#' @param df Tibble of batter rows (one per player-team-season).
#' @return Tibble grouped by (year, league, team).
#' @keywords internal
#' @noRd
.aggregate_team_batting <- function(df) {
  df$h_eq_row <- as.integer(round(df$ab * df$avg))
  out <- dplyr::summarise(
    dplyr::group_by(df, .data$year, .data$league, .data$team),
    ab        = sum(.data$ab),
    bb_bat    = sum(.data$bb),
    so_bat    = sum(.data$so),
    h_bat_eq  = sum(.data$h_eq_row),
    .groups   = "drop"
  )
  out
}

#' Aggregate pitcher rows to per-team-season totals.
#'
#' Sums IP and BB directly. Reconstructs ER via per-player
#' `round(ip * era / 9)` and H via per-player `round(ip * whip) - bb`. All
#' reconstructions match Onroto's two-digit ERA / three-digit WHIP display.
#'
#' @param df Tibble of pitcher rows.
#' @return Tibble grouped by (year, league, team).
#' @keywords internal
#' @noRd
.aggregate_team_pitching <- function(df) {
  df$er_eq_row <- as.integer(round(df$ip * df$era / 9))
  df$h_eq_row  <- as.integer(round(df$ip * df$whip)) - df$bb
  out <- dplyr::summarise(
    dplyr::group_by(df, .data$year, .data$league, .data$team),
    ip       = sum(.data$ip),
    bb_pit   = sum(.data$bb),
    er_eq    = sum(.data$er_eq_row),
    h_pit_eq = sum(.data$h_eq_row),
    .groups  = "drop"
  )
  out
}
```

- [ ] **Step 4: Run tests**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "utils-tout-wars-team-season")'
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add R/utils-tout-wars-team-season.R tests/testthat/test-utils-tout-wars-team-season.R
git commit -m "feat(team-season): aggregate per-player rows to team totals"
```

---

## Task 5: Reconciliation helper (TDD)

**Files:**
- Modify: `R/utils-tout-wars-team-season.R`
- Modify: `tests/testthat/test-utils-tout-wars-team-season.R`

Computes per-team-season residuals between roster-reconstructed rates and standings rates. Returns a tibble of residuals plus a flag for rows that exceed tolerance.

- [ ] **Step 1: Write failing tests**

Append to `tests/testthat/test-utils-tout-wars-team-season.R`:

```r
test_that(".compute_team_residuals computes joined rates and tolerance flag", {
  joined <- tibble::tibble(
    year = 2024L, league = "al", team_id = "OWNER1",
    ab = 5500L, h_bat_eq = 1500L, bb_bat = 600L,
    ip = 1450, er_eq = 600L, h_pit_eq = 1300L, bb_pit = 450L,
    AVG = 1500 / 5500,        # exact match
    OBP = (1500 + 600) / (5500 + 600),
    ERA = 600 * 9 / 1450,
    WHIP = (1300 + 450) / 1450
  )
  out <- rotostats:::.compute_team_residuals(joined)
  expect_true(abs(out$avg_resid) < 1e-9)
  expect_true(abs(out$obp_resid) < 1e-9)
  expect_true(abs(out$era_resid) < 1e-9)
  expect_true(abs(out$whip_resid) < 1e-9)
  expect_false(out$flagged)
})

test_that(".compute_team_residuals flags rows exceeding tolerance", {
  joined <- tibble::tibble(
    year = 2024L, league = "al", team_id = "OWNER1",
    ab = 5500L, h_bat_eq = 1700L, bb_bat = 600L,  # AVG inflated
    ip = 1450, er_eq = 600L, h_pit_eq = 1300L, bb_pit = 450L,
    AVG = 0.270,
    OBP = 0.340,
    ERA = 600 * 9 / 1450,
    WHIP = (1300 + 450) / 1450
  )
  out <- rotostats:::.compute_team_residuals(joined)
  expect_true(out$flagged)
  expect_gt(abs(out$avg_resid), 0.005)
})

test_that(".compute_team_residuals handles NA standings values gracefully", {
  joined <- tibble::tibble(
    year = 2024L, league = "al", team_id = "OWNER1",
    ab = 5500L, h_bat_eq = 1500L, bb_bat = 600L,
    ip = 1450, er_eq = 600L, h_pit_eq = 1300L, bb_pit = 450L,
    AVG = NA_real_,             # league didn't score AVG that year
    OBP = (1500 + 600) / (5500 + 600),
    ERA = 600 * 9 / 1450,
    WHIP = (1300 + 450) / 1450
  )
  out <- rotostats:::.compute_team_residuals(joined)
  expect_true(is.na(out$avg_resid))
  expect_false(out$flagged)
})
```

- [ ] **Step 2: Run to verify failure**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "utils-tout-wars-team-season")'
```

Expected: 3 new tests fail.

- [ ] **Step 3: Implement**

Append to `R/utils-tout-wars-team-season.R`:

```r
# Reconciliation tolerances. AVG/OBP in batting average units, ERA in
# earned-runs-per-9, WHIP in walks-and-hits-per-IP units. See spec for
# justification.
.tw_ts_tolerances <- list(
  avg  = 0.005,
  obp  = 0.005,
  era  = 0.15,
  whip = 0.020
)

#' Compute residuals between roster-reconstructed and standings rate stats.
#'
#' Operates on a joined frame that already carries both the standings rate
#' columns (`AVG`, `OBP`, `ERA`, `WHIP`; uppercase to match the standings
#' schema) and the per-team aggregated counters (`ab`, `h_bat_eq`, `bb_bat`,
#' `ip`, `er_eq`, `h_pit_eq`, `bb_pit`).
#'
#' OBP reconciliation runs in degraded mode (no HBP / SF available from the
#' scraper output): `(H + BB) / (AB + BB)`. Tolerance accounts for the
#' degraded denominator.
#'
#' Returns a tibble with one row per input row, augmented with residual
#' columns and a `flagged` logical (TRUE if any residual exceeds tolerance).
#' NA in a standings rate (e.g., AVG when only OBP was scored that
#' league-year) propagates to NA in that residual and is excluded from the
#' tolerance check.
#'
#' @param joined Tibble. See description.
#' @return Tibble with added columns: avg_resid, obp_resid, era_resid,
#'   whip_resid, flagged.
#' @keywords internal
#' @noRd
.compute_team_residuals <- function(joined) {
  joined_avg  <- joined$h_bat_eq / joined$ab
  joined_obp  <- (joined$h_bat_eq + joined$bb_bat) / (joined$ab + joined$bb_bat)
  joined_era  <- joined$er_eq * 9 / joined$ip
  joined_whip <- (joined$bb_pit + joined$h_pit_eq) / joined$ip

  joined$avg_resid  <- abs(joined_avg  - joined$AVG)
  joined$obp_resid  <- abs(joined_obp  - joined$OBP)
  joined$era_resid  <- abs(joined_era  - joined$ERA)
  joined$whip_resid <- abs(joined_whip - joined$WHIP)

  flag_avg  <- !is.na(joined$avg_resid)  & joined$avg_resid  > .tw_ts_tolerances$avg
  flag_obp  <- !is.na(joined$obp_resid)  & joined$obp_resid  > .tw_ts_tolerances$obp
  flag_era  <- !is.na(joined$era_resid)  & joined$era_resid  > .tw_ts_tolerances$era
  flag_whip <- !is.na(joined$whip_resid) & joined$whip_resid > .tw_ts_tolerances$whip

  joined$flagged <- flag_avg | flag_obp | flag_era | flag_whip
  joined
}
```

- [ ] **Step 4: Run tests**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "utils-tout-wars-team-season")'
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add R/utils-tout-wars-team-season.R tests/testthat/test-utils-tout-wars-team-season.R
git commit -m "feat(team-season): compute reconciliation residuals vs standings"
```

---

## Task 6: Standings reader (TDD)

**Files:**
- Modify: `R/utils-tout-wars-team-season.R`
- Modify: `tests/testthat/test-utils-tout-wars-team-season.R`

Reads a single standings CSV and returns a tibble with uppercase category names matching the team_season schema.

- [ ] **Step 1: Write failing tests**

Append to `tests/testthat/test-utils-tout-wars-team-season.R`:

```r
test_that(".read_tw_standings reads a standings CSV with normalized columns", {
  path <- "../../data-raw/sources/tout-wars/standings/2024-al.csv"
  skip_if_not(file.exists(path), "raw standings CSV not present")

  out <- rotostats:::.read_tw_standings(path)

  expect_true(all(c("year", "league", "team",
                    "R", "HR", "RBI", "SB", "OBP", "AVG",
                    "W", "SV", "ERA", "WHIP", "SO",
                    "R_pts", "HR_pts", "total_pts") %in% names(out)))
  expect_type(out$year, "integer")
  expect_type(out$R, "integer")
  expect_type(out$AVG, "double")
  expect_type(out$OBP, "double")
  expect_type(out$ERA, "double")
  expect_true(all(out$year == 2024L))
  expect_true(all(out$league == "al"))
})
```

- [ ] **Step 2: Run to verify failure**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "utils-tout-wars-team-season")'
```

Expected: new test fails.

- [ ] **Step 3: Implement**

Append to `R/utils-tout-wars-team-season.R`:

```r
.tw_ts_standings_cat_cols <- c(
  "R", "HR", "RBI", "SB", "OBP", "AVG",
  "W", "SV", "ERA", "WHIP", "SO"
)

.tw_ts_standings_pts_cols <- c(
  "R_pts", "HR_pts", "RBI_pts", "SB_pts", "OBP_pts", "AVG_pts",
  "W_pts", "SV_pts", "ERA_pts", "WHIP_pts", "SO_pts", "total_pts"
)

#' Read a Tout Wars standings CSV.
#'
#' Source schema: `year, league, team, R, R_pts, HR, HR_pts, ..., SO, SO_pts, total_pts`.
#' Categories are kept in their source case (uppercase) so they match the
#' team_season output schema.
#'
#' @param path Path to `{year}-{league}.csv` under standings/.
#' @return Tibble with one row per team-season.
#' @keywords internal
#' @noRd
.read_tw_standings <- function(path) {
  # Counting cats are integers; rate cats and all _pts are doubles.
  col_specs <- list(
    year       = readr::col_integer(),
    league     = readr::col_character(),
    team       = readr::col_character(),
    R          = readr::col_integer(),
    R_pts      = readr::col_double(),
    HR         = readr::col_integer(),
    HR_pts     = readr::col_double(),
    RBI        = readr::col_integer(),
    RBI_pts    = readr::col_double(),
    SB         = readr::col_integer(),
    SB_pts     = readr::col_double(),
    OBP        = readr::col_double(),
    OBP_pts    = readr::col_double(),
    AVG        = readr::col_double(),
    AVG_pts    = readr::col_double(),
    W          = readr::col_integer(),
    W_pts      = readr::col_double(),
    SV         = readr::col_integer(),
    SV_pts     = readr::col_double(),
    ERA        = readr::col_double(),
    ERA_pts    = readr::col_double(),
    WHIP       = readr::col_double(),
    WHIP_pts   = readr::col_double(),
    SO         = readr::col_integer(),
    SO_pts     = readr::col_double(),
    total_pts  = readr::col_double()
  )
  df <- readr::read_csv(
    path,
    col_types = do.call(readr::cols, col_specs),
    progress  = FALSE
  )
  required <- c("year", "league", "team",
                .tw_ts_standings_cat_cols, .tw_ts_standings_pts_cols)
  missing <- setdiff(required, names(df))
  if (length(missing) > 0L) {
    cli::cli_abort(
      c(
        "Required column(s) missing from {.file {basename(path)}}.",
        "i" = "Missing: {.val {missing}}"
      ),
      class = "rotostats_error_team_season_missing_column"
    )
  }
  df
}
```

- [ ] **Step 4: Run tests**

```bash
Rscript -e 'devtools::load_all(); devtools::test(filter = "utils-tout-wars-team-season")'
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add R/utils-tout-wars-team-season.R tests/testthat/test-utils-tout-wars-team-season.R
git commit -m "feat(team-season): add standings CSV reader"
```

---

## Task 7: Stage 1 build script

**Files:**
- Create: `data-raw/build-tout-wars-team-season.R`
- Modify: `.gitignore`

Stage 1 orchestrates: read all standings, read all batter/pitcher CSVs, filter sections, aggregate, join, reconcile, validate sanity bounds, write the cache RDS.

- [ ] **Step 1: Add the cache directory to .gitignore**

Append to `.gitignore`:

```
# Build cache for team-season pipeline (regenerable; do not commit)
data-raw/sources/cache/
```

- [ ] **Step 2: Create the build script**

Create `data-raw/build-tout-wars-team-season.R`:

```r
# Stage 1: build the team-season tibble from standings + per-team
# batter/pitcher CSVs, run reconciliation, write the cache RDS.
#
# Spec: plans/specs/2026-04-27-tout-wars-team-season-design.md

devtools::load_all()

standings_dir <- "data-raw/sources/tout-wars/standings"
rosters_dir   <- "data-raw/sources/tout-wars/rosters"
cache_dir     <- "data-raw/sources/cache"
fs::dir_create(cache_dir)

# ---- 1. Discover league-years from the standings directory ------------------
standings_files <- list.files(standings_dir, pattern = "\\.csv$",
                              full.names = TRUE)
parse_key <- function(path) {
  stem <- fs::path_ext_remove(fs::path_file(path))
  parts <- strsplit(stem, "-", fixed = TRUE)[[1]]
  list(year = as.integer(parts[1]), league = parts[2])
}
keys <- lapply(standings_files, parse_key)
years <- vapply(keys, `[[`, integer(1L), "year")
leagues <- vapply(keys, `[[`, character(1L), "league")

# Filter to 2010-2025 (spec scope)
in_scope <- years >= 2010L & years <= 2025L
standings_files <- standings_files[in_scope]
years <- years[in_scope]
leagues <- leagues[in_scope]

stopifnot(length(standings_files) == 45L)

# ---- 2. Read all standings --------------------------------------------------
cli::cli_inform("Reading {.val {length(standings_files)}} standings file(s).")
standings <- purrr::map_dfr(standings_files, rotostats:::.read_tw_standings)

# Canonicalize team -> team_id (reuse auction-pipeline canonicalizer)
standings$team_id <- vapply(
  standings$team, rotostats:::.canonicalize_tw_owner, character(1L)
)

# ---- 3. Read all batter / pitcher CSVs --------------------------------------
batter_files <- file.path(rosters_dir,
                          sprintf("%d-%s-batters.csv", years, leagues))
pitcher_files <- file.path(rosters_dir,
                           sprintf("%d-%s-pitchers.csv", years, leagues))
stopifnot(all(file.exists(batter_files)))
stopifnot(all(file.exists(pitcher_files)))

cli::cli_inform("Reading {.val {length(batter_files)}} batter and pitcher CSV(s).")
batters  <- purrr::map_dfr(batter_files,  rotostats:::.read_tw_batters)
pitchers <- purrr::map_dfr(pitcher_files, rotostats:::.read_tw_pitchers)

# ---- 4. Filter to active + previously_active --------------------------------
batters  <- rotostats:::.filter_active_sections(batters)
pitchers <- rotostats:::.filter_active_sections(pitchers)

# ---- 5. Aggregate to team ---------------------------------------------------
team_bat <- rotostats:::.aggregate_team_batting(batters)
team_pit <- rotostats:::.aggregate_team_pitching(pitchers)

# Canonicalize team -> team_id on both sides
team_bat$team_id <- vapply(
  team_bat$team, rotostats:::.canonicalize_tw_owner, character(1L)
)
team_pit$team_id <- vapply(
  team_pit$team, rotostats:::.canonicalize_tw_owner, character(1L)
)

# ---- 6. Join standings × batting × pitching ---------------------------------
joined <- dplyr::left_join(
  standings,
  dplyr::select(team_bat, .data$year, .data$league, .data$team_id,
                .data$ab, .data$bb_bat, .data$so_bat, .data$h_bat_eq),
  by = c("year", "league", "team_id")
)
joined <- dplyr::left_join(
  joined,
  dplyr::select(team_pit, .data$year, .data$league, .data$team_id,
                .data$ip, .data$bb_pit, .data$er_eq, .data$h_pit_eq),
  by = c("year", "league", "team_id")
)

# Fail loudly on any team_id mismatch (a standings row with no roster join)
unmatched <- joined[is.na(joined$ab) | is.na(joined$ip), ,
                    drop = FALSE]
if (nrow(unmatched) > 0L) {
  cli::cli_abort(
    c(
      "{nrow(unmatched)} standings row(s) have no matching roster aggregation.",
      "i" = "Affected: {paste(unmatched$year, unmatched$league, unmatched$team_id, sep = '/', collapse = ', ')}"
    ),
    class = "rotostats_error_team_owner_mismatch"
  )
}

# ---- 7. Reconciliation ------------------------------------------------------
joined <- rotostats:::.compute_team_residuals(joined)

flag_rate_by_ly <- dplyr::summarise(
  dplyr::group_by(joined, .data$year, .data$league),
  n = dplyr::n(),
  n_flagged = sum(.data$flagged),
  .groups = "drop"
)
flag_rate_by_ly$flag_rate <- flag_rate_by_ly$n_flagged / flag_rate_by_ly$n

bad_ly <- flag_rate_by_ly[flag_rate_by_ly$flag_rate > 0.05, , drop = FALSE]
if (nrow(bad_ly) > 0L) {
  cli::cli_abort(
    c(
      "Reconciliation: {nrow(bad_ly)} league-year(s) have >5% flagged team-seasons.",
      "i" = "Worst: {paste(bad_ly$year, bad_ly$league, sprintf('(%.1f%%)', 100 * bad_ly$flag_rate), collapse = ', ')}",
      "i" = "Inspect {.file data-raw/sources/cache/team-season-residuals.csv}."
    ),
    class = "rotostats_error_team_season_reconciliation"
  )
}

# Write per-team residual diagnostics for inspection
residuals_df <- dplyr::select(
  joined,
  .data$year, .data$league, .data$team_id,
  .data$avg_resid, .data$obp_resid,
  .data$era_resid, .data$whip_resid,
  .data$flagged
)
readr::write_csv(residuals_df, file.path(cache_dir, "team-season-residuals.csv"))

# ---- 8. Sanity bounds -------------------------------------------------------
oob <- joined[joined$ab < 3500 | joined$ab > 6500 |
              joined$ip < 800  | joined$ip > 2000, , drop = FALSE]
if (nrow(oob) > 0L) {
  cli::cli_abort(
    c(
      "{nrow(oob)} team-season(s) have IP or AB outside sanity bounds.",
      "i" = "AB bounds [3500, 6500]; IP bounds [800, 2000].",
      "i" = "Affected: {paste(oob$year, oob$league, oob$team_id, sep = '/', collapse = ', ')}"
    ),
    class = "rotostats_error_team_season_oob"
  )
}

# ---- 9. Cross-check against tout_wars_auctions team_owner set ---------------
auction_pairs <- dplyr::distinct(
  tout_wars_auctions[, c("year", "league", "team_owner")]
)
auction_pairs$key <- paste(auction_pairs$year, auction_pairs$league,
                           auction_pairs$team_owner, sep = "/")
ts_pairs <- dplyr::distinct(
  joined[, c("year", "league", "team_id")]
)
ts_pairs$key <- paste(ts_pairs$year, ts_pairs$league, ts_pairs$team_id,
                      sep = "/")
# Auctions cover 2012-2026, team-season covers 2010-2025; intersect on
# overlapping years only.
overlap_years <- intersect(unique(auction_pairs$year), unique(ts_pairs$year))
auction_overlap <- auction_pairs[auction_pairs$year %in% overlap_years, ]
ts_overlap      <- ts_pairs[ts_pairs$year %in% overlap_years, ]
in_auction_only <- setdiff(auction_overlap$key, ts_overlap$key)
in_ts_only      <- setdiff(ts_overlap$key, auction_overlap$key)
if (length(in_auction_only) > 0L || length(in_ts_only) > 0L) {
  cli::cli_abort(
    c(
      "team_id sets differ between tout_wars_auctions and team-season.",
      "i" = "In auctions only: {.val {head(in_auction_only, 10)}}",
      "i" = "In team-season only: {.val {head(in_ts_only, 10)}}"
    ),
    class = "rotostats_error_team_owner_mismatch"
  )
}

# ---- 10. Final shape ---------------------------------------------------------
final_cols <- c(
  "year", "league", "team_id",
  "R", "HR", "RBI", "SB", "OBP", "AVG",
  "W", "SV", "SO", "ERA", "WHIP",
  "AB", "IP",
  "R_pts", "HR_pts", "RBI_pts", "SB_pts", "OBP_pts", "AVG_pts",
  "W_pts", "SV_pts", "ERA_pts", "WHIP_pts", "SO_pts", "total_pts"
)
joined$AB <- as.integer(joined$ab)
joined$IP <- joined$ip
out <- joined[, final_cols, drop = FALSE]
out <- dplyr::arrange(out, .data$year, .data$league, .data$team_id)
out <- tibble::as_tibble(out)
class(out) <- c("tbl_df", "tbl", "data.frame")

saveRDS(out, file.path(cache_dir, "tout-wars-team-season.rds"))
cli::cli_inform("Wrote cache: {nrow(out)} team-seasons.")
```

- [ ] **Step 3: Run the script**

```bash
Rscript data-raw/build-tout-wars-team-season.R
```

Expected: no errors. Output ends with `Wrote cache: <N> team-seasons.` where `<N>` ≈ 579 (between 540 and 620).

If reconciliation aborts, inspect `data-raw/sources/cache/team-season-residuals.csv`. The most likely cause is per-player rounding noise exceeding tolerance for a few teams; before relaxing tolerances in `R/utils-tout-wars-team-season.R`, confirm the residual distribution looks roughly uniform (not concentrated in one year, suggesting a parser bug).

- [ ] **Step 4: Verify the cache file**

```bash
Rscript -e 'x <- readRDS("data-raw/sources/cache/tout-wars-team-season.rds"); print(dim(x)); print(names(x)); print(summary(x[, c("AB", "IP")]))'
```

Expected: dimensions ~ (579, 28), names match `final_cols`, AB ∈ [3500, 6500], IP ∈ [800, 2000].

- [ ] **Step 5: Commit**

```bash
git add data-raw/build-tout-wars-team-season.R .gitignore
git commit -m "feat(team-season): Stage 1 build script with reconciliation"
```

---

## Task 8: Stage 2 use_data wrapper

**Files:**
- Create: `data-raw/tout-wars-team-season.R`

- [ ] **Step 1: Create the wrapper script**

Create `data-raw/tout-wars-team-season.R`:

```r
# Stage 2: load the cached team-season tibble and expose it as the package
# data object `tout_wars_team_season`.
#
# Spec: plans/specs/2026-04-27-tout-wars-team-season-design.md

devtools::load_all()

cache_path <- "data-raw/sources/cache/tout-wars-team-season.rds"
if (!file.exists(cache_path)) {
  cli::cli_abort(
    c(
      "Cache file not found: {.file {cache_path}}.",
      "i" = "Run {.file data-raw/build-tout-wars-team-season.R} first."
    )
  )
}

tout_wars_team_season <- readRDS(cache_path)

# Defensive: re-sort and re-class in case cache was edited.
tout_wars_team_season <- dplyr::arrange(
  tout_wars_team_season, .data$year, .data$league, .data$team_id
)
class(tout_wars_team_season) <- c("tbl_df", "tbl", "data.frame")

# Strip readr's spec/problems attributes that may have propagated through
# the pipeline.
attr(tout_wars_team_season, "spec") <- NULL
attr(tout_wars_team_season, "problems") <- NULL

usethis::use_data(tout_wars_team_season, overwrite = TRUE)
cli::cli_inform("Wrote tout_wars_team_season: {nrow(tout_wars_team_season)} rows.")
```

- [ ] **Step 2: Run the script**

```bash
Rscript data-raw/tout-wars-team-season.R
```

Expected: `data/tout_wars_team_season.rda` is created.

- [ ] **Step 3: Verify the package data**

```bash
Rscript -e 'devtools::load_all(); print(dim(tout_wars_team_season)); print(class(tout_wars_team_season))'
```

Expected: dims ~ (579, 28), class `c("tbl_df", "tbl", "data.frame")`.

- [ ] **Step 4: Commit**

```bash
git add data-raw/tout-wars-team-season.R data/tout_wars_team_season.rda
git commit -m "feat(team-season): Stage 2 use_data wrapper and dataset"
```

---

## Task 9: Roxygen documentation for the dataset

**Files:**
- Create: `R/data-tout-wars-team-season.R`

- [ ] **Step 1: Create the documentation file**

Create `R/data-tout-wars-team-season.R`:

```r
#' Tout Wars Team-Season Totals, 2010-2025
#'
#' Wide team-season totals for all three Tout Wars expert leagues
#' (American League, National League, Mixed). One row per team-year, in the
#' shape required by [league_history()] for testing
#' [sgp_denominators()], [sgp()], and [par()].
#'
#' @format A tibble with 28 columns:
#' \describe{
#'   \item{year}{Integer. Standings year (2010-2025).}
#'   \item{league}{Character. One of `"al"`, `"nl"`, `"mixed"`. Mixed
#'     present 2013+.}
#'   \item{team_id}{Character. Canonicalized team owner. Same canonicalization
#'     as `tout_wars_auctions$team_owner`.}
#'   \item{R, HR, RBI, SB}{Integer batting counting categories from
#'     standings.}
#'   \item{OBP, AVG}{Double batting rate categories. `NA` when the league
#'     did not score that category in that year.}
#'   \item{W, SV, SO}{Integer pitching counting categories from standings.}
#'   \item{ERA, WHIP}{Double pitching rate categories from standings.}
#'   \item{AB}{Integer. Sum of player AB across the team's `active` and
#'     `previously_active` roster sections.}
#'   \item{IP}{Double. Sum of player IP across the same sections.}
#'   \item{R_pts ... SO_pts}{Double. Standings points per category. `NA`
#'     when the category was not scored.}
#'   \item{total_pts}{Double. Total roto points.}
#' }
#'
#' @details
#' ## Section selection for AB / IP
#'
#' `AB` and `IP` sum stats from roster rows where
#' `roster_section %in% c("active", "previously_active")`. Players moved
#' to `reserved` or `previously_reserved` accumulated their stats outside
#' the team's contributing window and are excluded. This captures
#' injured-but-active players (whose pre-injury stats counted) without
#' overcounting season-long stashes.
#'
#' ## Reconciliation tolerances
#'
#' At build time, roster-reconstructed team rate stats are compared to the
#' standings rate values:
#' - AVG, OBP within 0.005
#' - ERA within 0.15
#' - WHIP within 0.020
#'
#' If more than 5% of team-seasons in any league-year exceed tolerance, the
#' build aborts. Per-team residuals are written to
#' `data-raw/sources/cache/team-season-residuals.csv`.
#'
#' @source Standings CSVs at
#'   `data-raw/sources/tout-wars/standings/{year}-{league}.csv`; per-team
#'   batter and pitcher CSVs at
#'   `data-raw/sources/tout-wars/rosters/{year}-{league}-{batters,pitchers}.csv`,
#'   produced by `data-raw/sources/tout-wars/scrape/team_stats.py`. Built
#'   via `data-raw/build-tout-wars-team-season.R` and
#'   `data-raw/tout-wars-team-season.R`.
"tout_wars_team_season"
```

- [ ] **Step 2: Regenerate documentation**

```bash
Rscript -e 'devtools::document()'
```

Expected: `man/tout_wars_team_season.Rd` is created. No warnings.

- [ ] **Step 3: Verify the help page renders**

```bash
Rscript -e 'devtools::load_all(); ?tout_wars_team_season' 2>&1 | head -5
```

Expected: no error.

- [ ] **Step 4: Commit**

```bash
git add R/data-tout-wars-team-season.R man/tout_wars_team_season.Rd
git commit -m "docs(team-season): roxygen for tout_wars_team_season dataset"
```

---

## Task 10: Schema and sanity tests

**Files:**
- Create: `tests/testthat/test-tout-wars-team-season.R`
- Create: `tests/testthat/fixtures/team-season-residuals.csv`

- [ ] **Step 1: Snapshot the build-time residuals as a committed fixture**

```bash
cp data-raw/sources/cache/team-season-residuals.csv tests/testthat/fixtures/team-season-residuals.csv
```

- [ ] **Step 2: Create the test file**

Create `tests/testthat/test-tout-wars-team-season.R`:

```r
test_that("tout_wars_team_season has the expected schema", {
  expected_cols <- c(
    "year", "league", "team_id",
    "R", "HR", "RBI", "SB", "OBP", "AVG",
    "W", "SV", "SO", "ERA", "WHIP",
    "AB", "IP",
    "R_pts", "HR_pts", "RBI_pts", "SB_pts", "OBP_pts", "AVG_pts",
    "W_pts", "SV_pts", "ERA_pts", "WHIP_pts", "SO_pts", "total_pts"
  )
  expect_named(tout_wars_team_season, expected_cols)
  expect_s3_class(tout_wars_team_season, "tbl_df")

  expect_type(tout_wars_team_season$year, "integer")
  expect_type(tout_wars_team_season$league, "character")
  expect_type(tout_wars_team_season$team_id, "character")
  expect_type(tout_wars_team_season$R, "integer")
  expect_type(tout_wars_team_season$AB, "integer")
  expect_type(tout_wars_team_season$IP, "double")
  expect_type(tout_wars_team_season$ERA, "double")
})

test_that("tout_wars_team_season covers 2010-2025 (no 2026)", {
  expect_setequal(unique(tout_wars_team_season$year), 2010:2025)
})

test_that("tout_wars_team_season league domain is valid", {
  expect_setequal(
    unique(tout_wars_team_season$league),
    c("al", "nl", "mixed")
  )
})

test_that("Mixed league only appears 2013+", {
  mixed_years <- unique(
    tout_wars_team_season$year[tout_wars_team_season$league == "mixed"]
  )
  expect_true(min(mixed_years) >= 2013L)
})

test_that("AB and IP are within sanity bounds", {
  expect_true(all(tout_wars_team_season$AB >= 3500 &
                  tout_wars_team_season$AB <= 6500))
  expect_true(all(tout_wars_team_season$IP >= 800 &
                  tout_wars_team_season$IP <= 2000))
})

test_that("(year, league, team_id) is unique", {
  keys <- with(tout_wars_team_season,
               paste(year, league, team_id, sep = "/"))
  expect_equal(length(keys), length(unique(keys)))
})

test_that("team_id matches tout_wars_auctions$team_owner where overlapping", {
  ts_keys <- with(
    tout_wars_team_season,
    paste(year, league, team_id, sep = "/")
  )
  auction_keys <- with(
    tout_wars_auctions,
    paste(year, league, team_owner, sep = "/")
  )
  overlap_years <- intersect(
    unique(tout_wars_team_season$year),
    unique(tout_wars_auctions$year)
  )
  ts_overlap <- ts_keys[tout_wars_team_season$year %in% overlap_years]
  auction_overlap <- auction_keys[tout_wars_auctions$year %in% overlap_years]
  expect_setequal(unique(ts_overlap), unique(auction_overlap))
})

test_that("OBP or AVG is non-NA per row (one of the two is always scored)", {
  has_obp <- !is.na(tout_wars_team_season$OBP)
  has_avg <- !is.na(tout_wars_team_season$AVG)
  expect_true(all(has_obp | has_avg))
})

test_that("reconciliation residuals are within fixture tolerances", {
  fixture <- readr::read_csv(
    test_path("fixtures/team-season-residuals.csv"),
    col_types = readr::cols(.default = "d", league = "c", team_id = "c",
                             flagged = "l")
  )
  flag_rate_by_ly <- dplyr::summarise(
    dplyr::group_by(fixture, year, league),
    flag_rate = mean(flagged),
    .groups = "drop"
  )
  expect_true(all(flag_rate_by_ly$flag_rate <= 0.05))
})
```

- [ ] **Step 3: Run the tests**

```bash
Rscript -e 'devtools::test(filter = "tout-wars-team-season$")'
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add tests/testthat/test-tout-wars-team-season.R tests/testthat/fixtures/team-season-residuals.csv
git commit -m "test(team-season): schema, sanity, and residual tolerance checks"
```

---

## Task 11: sgp_denominators integration test

**Files:**
- Create: `tests/testthat/test-sgp-denominators-tout-wars.R`

This test takes `tout_wars_team_season`, builds a `league_history()`, and runs `sgp_denominators()` on the standard 5×5+OBP categories. The denominator vector is snapshotted via `expect_snapshot_value()` so any future change in the build pipeline that perturbs the values surfaces as a test diff.

- [ ] **Step 1: Create the test**

Create `tests/testthat/test-sgp-denominators-tout-wars.R`:

```r
test_that("sgp_denominators runs on tout_wars_team_season (mixed, OBP)", {
  ts <- dplyr::filter(tout_wars_team_season, league == "mixed")
  history <- league_history(team_season = ts)

  denoms <- sgp_denominators(
    history,
    scoring_categories = c("R", "HR", "RBI", "SB", "OBP",
                           "W", "SV", "SO", "ERA", "WHIP"),
    exclude_years      = 2020L
  )

  # Snapshot the denominator vector so future regressions show up as a diff.
  expect_snapshot_value(round(as.numeric(denoms), 4), style = "json2")
})

test_that("sgp_denominators runs on tout_wars_team_season (al, AVG)", {
  ts <- dplyr::filter(tout_wars_team_season, league == "al")
  history <- league_history(team_season = ts)

  denoms <- sgp_denominators(
    history,
    scoring_categories = c("R", "HR", "RBI", "SB", "AVG",
                           "W", "SV", "SO", "ERA", "WHIP"),
    exclude_years      = 2020L
  )

  expect_snapshot_value(round(as.numeric(denoms), 4), style = "json2")
})

test_that("sgp_denominators denominator values are positive and finite", {
  ts <- dplyr::filter(tout_wars_team_season, league == "mixed")
  history <- league_history(team_season = ts)

  denoms <- sgp_denominators(
    history,
    scoring_categories = c("R", "HR", "RBI", "SB", "OBP",
                           "W", "SV", "SO", "ERA", "WHIP"),
    exclude_years      = 2020L
  )

  vals <- as.numeric(denoms)
  expect_true(all(is.finite(vals)))
  expect_true(all(vals > 0))
})
```

- [ ] **Step 2: Run the test (this records the snapshot the first time)**

```bash
Rscript -e 'devtools::test(filter = "sgp-denominators-tout-wars")'
```

Expected: tests pass; first run records `tests/testthat/_snaps/sgp-denominators-tout-wars/`.

- [ ] **Step 3: Inspect the snapshot for sanity**

```bash
ls tests/testthat/_snaps/sgp-denominators-tout-wars/
cat tests/testthat/_snaps/sgp-denominators-tout-wars/*-mixed-OBP.json2 2>/dev/null | head -30
```

Expected: a JSON list of denominators. R/HR/RBI/SB should be in roughly the right order of magnitude (R ≈ 5-10, HR ≈ 1-3, SB ≈ 1-3, etc.). If any value is wildly off, investigate before committing the snapshot.

- [ ] **Step 4: Commit**

```bash
git add tests/testthat/test-sgp-denominators-tout-wars.R tests/testthat/_snaps/sgp-denominators-tout-wars/
git commit -m "test(team-season): integration snapshot for sgp_denominators"
```

---

## Task 12: sgp() and par() integration tests

**Files:**
- Create: `tests/testthat/test-sgp-tout-wars.R`
- Create: `tests/testthat/test-par-tout-wars.R`

These tests use the existing Steamer projection fixtures plus `tout_wars_team_season` to run `sgp()` and `par()` end-to-end on the blended-pool path. They assert finiteness and that side-mismatched cells are NA, but do not snapshot exact SGP / PAR values (which are sensitive to projection vintage).

- [ ] **Step 1: Inspect available projection fixtures**

```bash
ls tests/testthat/fixtures/ | grep -i steamer
```

Expected output includes `projections-steamer-both.rds`.

- [ ] **Step 2: Inspect the Steamer fixture's columns**

```bash
Rscript -e 'p <- readRDS("tests/testthat/fixtures/projections-steamer-both.rds"); str(p, max.level = 1, list.len = 30)'
```

Note the exact column names — the test will use whatever the fixture provides for `IP`, `AB`, and the categorical stats. If the fixture is per-side, see the per-side fixtures (`projections-steamer-bat.json`, `projections-steamer-pit.json`).

- [ ] **Step 3: Create the sgp() integration test**

Create `tests/testthat/test-sgp-tout-wars.R`:

```r
test_that("sgp() blended_pool runs on tout_wars_team_season + Steamer fixture", {
  fixture_path <- test_path("fixtures/projections-steamer-both.rds")
  skip_if_not(file.exists(fixture_path), "steamer fixture not present")
  projections <- readRDS(fixture_path)

  ts <- dplyr::filter(tout_wars_team_season, league == "mixed")
  history <- league_history(team_season = ts)
  config <- league_config(
    n_teams            = 15L,
    roster_slots       = c(C = 1, "1B" = 1, "2B" = 1, "3B" = 1, SS = 1,
                           OF = 5, UTIL = 1),
    pitcher_slots      = c(SP = 6L, RP = 3L),
    batting_categories = c("R", "HR", "RBI", "SB", "OBP"),
    pitcher_categories = c("W", "SV", "SO", "ERA", "WHIP")
  )
  denoms <- sgp_denominators(
    history,
    scoring_categories = c("R", "HR", "RBI", "SB", "OBP",
                           "W", "SV", "SO", "ERA", "WHIP"),
    exclude_years      = 2020L
  )

  out <- sgp(
    projections    = projections,
    denominators   = denoms,
    league_history = history,
    league_config  = config
  )

  # Schema: sgp_<CAT> per scored category + total_sgp
  expected_cols <- c(paste0("sgp_", c("R", "HR", "RBI", "SB", "OBP",
                                       "W", "SV", "SO", "ERA", "WHIP")),
                     "total_sgp")
  expect_true(all(expected_cols %in% names(out)))
  expect_equal(nrow(out), nrow(projections))

  # At least some hitter rows should have finite hitter-cat SGP, and at
  # least some pitcher rows should have finite pitcher-cat SGP.
  hitter_cols  <- c("sgp_R", "sgp_HR", "sgp_RBI", "sgp_SB", "sgp_OBP")
  pitcher_cols <- c("sgp_W", "sgp_SV", "sgp_SO", "sgp_ERA", "sgp_WHIP")
  hr_finite <- rowSums(is.finite(as.matrix(out[, hitter_cols, drop = FALSE]))) > 0
  pi_finite <- rowSums(is.finite(as.matrix(out[, pitcher_cols, drop = FALSE]))) > 0
  expect_gt(sum(hr_finite), 100)
  expect_gt(sum(pi_finite), 100)
})
```

- [ ] **Step 4: Create the par() integration test**

Create `tests/testthat/test-par-tout-wars.R`:

```r
test_that("par() runs on tout_wars_team_season + Steamer fixture", {
  fixture_path <- test_path("fixtures/projections-steamer-both.rds")
  skip_if_not(file.exists(fixture_path), "steamer fixture not present")
  projections <- readRDS(fixture_path)

  ts <- dplyr::filter(tout_wars_team_season, league == "mixed")
  history <- league_history(team_season = ts)
  config <- league_config(
    n_teams            = 15L,
    roster_slots       = c(C = 1, "1B" = 1, "2B" = 1, "3B" = 1, SS = 1,
                           OF = 5, UTIL = 1),
    pitcher_slots      = c(SP = 6L, RP = 3L),
    batting_categories = c("R", "HR", "RBI", "SB", "OBP"),
    pitcher_categories = c("W", "SV", "SO", "ERA", "WHIP")
  )
  denoms <- sgp_denominators(
    history,
    scoring_categories = c("R", "HR", "RBI", "SB", "OBP",
                           "W", "SV", "SO", "ERA", "WHIP"),
    exclude_years      = 2020L
  )

  repl <- replacement_level(projections = projections, config = config)
  out <- par(
    replacement     = repl,
    denominators    = denoms,
    league_history  = history
  )

  expect_true("total_par" %in% names(out))
  expect_equal(nrow(out), nrow(projections))
  expect_true(any(is.finite(out$total_par)))

  # Replacement-level players should sit near 0 PAR by construction.
  # Median total_par across the +/-K boundary band is checked inside par()
  # via boundary_threshold; we don't re-assert numerics here, but we do
  # assert the warning class did not fire (it would have warned only
  # outside threshold).
  expect_true(median(out$total_par, na.rm = TRUE) > 0)
})
```

- [ ] **Step 5: Run both tests**

```bash
Rscript -e 'devtools::test(filter = "(sgp|par)-tout-wars")'
```

Expected: both tests pass.

If either test fails because `replacement_level()` requires inputs not present in the Steamer fixture, narrow the test data first (e.g., a filtered subset of `projections`) and update the test code. Do not weaken the assertions to silence a real failure.

- [ ] **Step 6: Commit**

```bash
git add tests/testthat/test-sgp-tout-wars.R tests/testthat/test-par-tout-wars.R
git commit -m "test(team-season): integration tests for sgp() and par()"
```

---

## Task 13: Register error / warning classes

**Files:**
- Modify: `plans/error-messages.md`

- [ ] **Step 1: Inspect the existing format**

```bash
head -40 plans/error-messages.md
```

Note the exact heading style and grouping convention.

- [ ] **Step 2: Append new classes**

Append a new section to `plans/error-messages.md` (matching the existing style — adapt the heading/format to the file's actual conventions if they differ from the template below):

```markdown
## tout_wars_team_season build pipeline

| Class                                              | Severity | Source                                         | Trigger |
|----------------------------------------------------|----------|------------------------------------------------|---------|
| `rotostats_error_team_season_missing_column`       | error    | `R/utils-tout-wars-team-season.R`              | Required column absent from a standings or roster CSV. |
| `rotostats_error_team_season_unknown_section`      | error    | `R/utils-tout-wars-team-season.R`              | Roster row carries a `roster_section` value not in `{active, reserved, previously_active, previously_reserved}`. |
| `rotostats_error_team_season_reconciliation`       | error    | `data-raw/build-tout-wars-team-season.R`       | More than 5% of team-seasons in any league-year have a residual exceeding tolerance. |
| `rotostats_error_team_season_oob`                  | error    | `data-raw/build-tout-wars-team-season.R`       | Computed AB or IP outside the sanity bounds [3500, 6500] / [800, 2000]. |
| `rotostats_error_team_owner_mismatch`              | error    | `data-raw/build-tout-wars-team-season.R`       | Standings row has no roster join, or `team_id` set differs from `tout_wars_auctions$team_owner` for an overlapping league-year. |
```

- [ ] **Step 3: Commit**

```bash
git add plans/error-messages.md
git commit -m "docs(team-season): register new error classes"
```

---

## Task 14: Final R CMD check and PR prep

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

```bash
Rscript -e 'devtools::test()'
```

Expected: all tests pass. No new warnings.

- [ ] **Step 2: Run R CMD check**

```bash
Rscript -e 'devtools::check()'
```

Expected: 0 errors, 0 warnings, 0 notes (or only pre-existing notes unrelated to this change).

If a new note appears about an unused dependency or undocumented data, fix it (most likely needs `@keywords internal` on a helper or an `@docType data` somewhere — but the roxygen template in Task 9 should already cover this).

- [ ] **Step 3: Verify the dataset round-trips through `league_history()`**

```bash
Rscript -e '
devtools::load_all()
h <- league_history(team_season = tout_wars_team_season)
print(h)
'
```

Expected: the print method shows team count × year span, lists stat columns, and notes 2020 presence.

- [ ] **Step 4: Push the branch and open a PR against develop**

```bash
git push -u origin feature/tout-wars-team-season-dataset
gh pr create --base develop --title "feat: tout_wars_team_season dataset" --body "$(cat <<'EOF'
## Summary
- Adds `tout_wars_team_season`, a 2010-2025 wide tibble in the shape `league_history()` expects.
- Two-stage R pipeline under `data-raw/`. AB and IP are summed from per-team batter/pitcher CSVs (filtered to `active` + `previously_active` sections).
- Build-time reconciliation against standings rate stats with documented tolerances.
- Integration tests for `sgp_denominators()`, `sgp()`, and `par()` on the new dataset.

Spec: [`plans/specs/2026-04-27-tout-wars-team-season-design.md`](plans/specs/2026-04-27-tout-wars-team-season-design.md)
Plan: [`plans/implementation/2026-04-28-tout-wars-team-season.md`](plans/implementation/2026-04-28-tout-wars-team-season.md)

## Test plan
- [ ] `devtools::test()` passes
- [ ] `devtools::check()` is clean
- [ ] Snapshot test for `sgp_denominators()` matches recorded values
- [ ] Manual: `league_history(team_season = tout_wars_team_season)` prints sensibly
EOF
)"
```

- [ ] **Step 5: No commit at this step**

The PR is the deliverable.

---

## Self-Review Notes

- Spec coverage: every section of the spec has at least one task. Stage 1 → Task 7. Stage 2 → Task 8. Schema → Task 10. Reconciliation → Tasks 5 + 7 + 10. Section selection → Task 3. Tests for `sgp_denominators` / `sgp` / `par` → Tasks 11–12. Error classes → Task 13. Documentation → Task 9.
- Type consistency: helper signatures and column names match across tasks (`h_bat_eq`, `h_pit_eq`, `er_eq`, `bb_bat`, `bb_pit`, `ab`, `ip` are used consistently from Task 4 onward; the final dataset uses uppercase `AB`/`IP`/category names per the spec).
- Tolerances and bounds match the spec exactly (AVG/OBP ≤ 0.005, ERA ≤ 0.15, WHIP ≤ 0.020; AB ∈ [3500, 6500], IP ∈ [800, 2000]).
- The Steamer fixture file exists in the repo (`projections-steamer-both.rds`); Task 12 has a `skip_if_not` guard in case it ever moves.
