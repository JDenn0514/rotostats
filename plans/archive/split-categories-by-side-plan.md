# Split Categories by Side Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate cross-side z-score contamination and verbose `0 IP / 0 AB` warnings in `zar()` / `zaa()` by carrying hitter and pitcher scored-category sets separately end-to-end.

**Architecture:** Replace the singular `config$categories` field with two distinct fields: `config$batting_categories` and `config$pitcher_categories`. Every entry point (`zaa()`, `zar()`, `par()`, `pvm()`, `replacement_level()`, `sgp()`) computes per-side z-scores against the same-side projection pool only. Cells outside a player's side are `NA` (not `0`). The downstream `total_zar` / `total_par` already use `na.rm = TRUE` so cross-side `NA` semantics flow through correctly. This is a breaking, pre-1.0 change with no migration shim — the field name itself changes so callers fail loud rather than silently default.

**Tech Stack:** R 4.x, testthat (3rd-edition style), roxygen2, devtools, cli + rlang condition system, S3.

---

## Pre-conditions

- Working directory is a clean checkout of `develop`.
- All existing tests pass (`devtools::test()`).
- The user's CLAUDE.md rule applies: feature branch from `develop`, conventional commits, target `develop` in PR, run `devtools::document()` before any commit that touches roxygen, run `devtools::check()` before opening the PR.
- statsclaw `BrainMode = "isolated"` — skip any `/contribute` prompt.

---

## File Structure

**Files created:**
- `R/categories.R` — package-level canonical category lists and side-classification helpers.

**Files modified:**
- `R/league-config.R` — replace `categories` arg with `batting_categories` + `pitcher_categories`; new validators; updated print method.
- `R/zaa.R` — split main computation into per-side passes; cross-side cells are `NA`; throttle the verbose zero-playing-time warning.
- `R/zar.R` — consume `batting_categories` ∪ `pitcher_categories`; `total_zar` already NA-safe.
- `R/par.R` — consume the union of side-specific `sgp_denominators` lists; `total_par` already NA-safe.
- `R/pvm.R` — drop dependency on the local `PVM_PITCHER_CATEGORIES` constant; use the new shared classifier; iterate scored cats per side.
- `R/replacement.R` — partition the projection pool by side before per-side replacement boundary computation; preserve two-way duplication (Ohtani).
- `R/replacement_internal.R` — pass the active side into `compute_pool_zscores()`, `compute_replacement_stat_line()`, `compute_par_at_pos()`.
- `R/sgp.R` — iterate the union of `batting_categories` + `pitcher_categories`; rate-stat side comes from `pool_type` already.
- `R/sgp-denominators.R` — accept either a single `scoring_categories` argument (current behavior) or two side-keyed lists when `config` is supplied.
- `R/get-projections-internal.R` — add `.classify_custom_player_type()` for `source = "custom"` data lacking `player_type`.
- `NEWS.md` — document the breaking change.
- `plans/error-messages.md` — register new error / warning classes.

**Test files modified (mechanical signature change + side-aware assertions):**
- `tests/testthat/helper-zaa-fixtures.R`
- `tests/testthat/helper-zar-fixtures.R`
- `tests/testthat/helper-par-fixtures.R`
- `tests/testthat/helper-pvm-fixtures.R`
- `tests/testthat/helper-test-data.R` (verify, no signature change)
- `tests/testthat/test-league-config.R`
- `tests/testthat/test-zaa.R`
- `tests/testthat/test-zar.R`
- `tests/testthat/test-par.R`
- `tests/testthat/test-par-sim.R`
- `tests/testthat/test-pvm.R`
- `tests/testthat/test-replacement.R`
- `tests/testthat/test-replacement-integration.R`
- `tests/testthat/test-replacement-from-prices.R`
- `tests/testthat/test-sgp.R`
- `tests/testthat/test-sgp-integration.R`
- `tests/testthat/test-sgp-denominators.R`
- `tests/testthat/test-inverse-categories.R`

---

## Phase 0 — Pre-flight

### Task 0.1: Cut feature branch

**Files:** none (branch operation)

- [ ] **Step 1: Verify clean state**

```bash
git status
```
Expected: working tree clean on `develop`.

- [ ] **Step 2: Cut branch**

```bash
git checkout develop
git pull --ff-only origin develop
git checkout -b fix/zar-split-categories-by-side
```
Expected: now on the new branch, no diff vs `develop`.

### Task 0.2: Lock in the regression case as a failing test

**Files:**
- Create: `tests/testthat/test-zar-cross-side-regression.R`

This test demonstrates the original bug (a pitcher receiving non-zero `zar_hr` / `zar_r` because pitcher `hr` / `r` columns from FanGraphs collide with hitter columns after the union combine). It must FAIL on `develop` and PASS once the plan is complete.

- [ ] **Step 1: Write the failing regression test**

```r
# tests/testthat/test-zar-cross-side-regression.R
# Regression: pitcher rows must receive NA for hitter z-scores (HR, R, SB, ...)
# and vice versa. Before this fix, FanGraphs pitcher `hr` (HR allowed) and `r`
# (R allowed) collided with hitter `hr` / `r` after the union combine, so
# pitchers received a non-NA hitter z-score.

test_that("pitcher rows get NA for hitter categories in zar() output", {
  skip_if_not_installed("withr")

  proj <- make_projections_data(seed = 7L)

  cfg <- league_config(
    n_teams            = 12L,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 3L, RP = 3L),
    batting_categories = c("HR", "R", "SB"),
    pitcher_categories = c("K", "SV", "ERA"),
    league_type        = "mixed"
  )

  repl <- replacement_level(proj, cfg)
  out  <- zar(repl)

  pitchers <- subset(out, player_type == "pitcher")
  hitters  <- subset(out, player_type == "batter")

  # Hitter cats in pitcher rows: NA, not 0, not non-zero.
  expect_true(all(is.na(pitchers$zar_hr)))
  expect_true(all(is.na(pitchers$zar_r)))
  expect_true(all(is.na(pitchers$zar_sb)))

  # Pitcher cats in hitter rows: NA, not 0.
  expect_true(all(is.na(hitters$zar_k)))
  expect_true(all(is.na(hitters$zar_sv)))
  expect_true(all(is.na(hitters$zar_era)))

  # total_zar is the rowSum(na.rm = TRUE) — neither side gets credit for the
  # other side's cells but each side's intra-side total is well-defined.
  expect_true(all(is.finite(pitchers$total_zar)))
  expect_true(all(is.finite(hitters$total_zar)))
})
```

- [ ] **Step 2: Run the new test, expecting FAIL**

```bash
Rscript -e 'devtools::test(filter = "zar-cross-side-regression")'
```
Expected: FAIL — pitcher rows currently have nonzero `zar_hr` / `zar_r` because the API column collision pollutes downstream z-scores.

- [ ] **Step 3: Commit the failing test (xfail style — keep it red until plan completes)**

Mark the test as `expect_failure(...)` wrapping each block, OR commit it directly as a red TODO. Simpler: just commit it red with a `skip("re-enabled at end of plan")` and remove the skip in Task 10.1.

```r
# Top of test_that block, before any expect_*:
skip("Re-enabled in Task 10.1 once split-by-side architecture lands.")
```

```bash
git add tests/testthat/test-zar-cross-side-regression.R
git commit -m "test(zar): add cross-side contamination regression (skipped until fix)"
```

---

## Phase 1 — Shared category infrastructure

### Task 1.1: Create `R/categories.R`

**Files:**
- Create: `R/categories.R`
- Test: `tests/testthat/test-categories.R`

This file is the single source of truth for which categories belong to which side. Lifts the existing `PVM_PITCHER_CATEGORIES` from `R/pvm.R` and adds a parallel `PVM_BATTING_CATEGORIES` (currently implicit — anything not in the pitcher list is treated as a batter category). Adds a side-classifier helper used everywhere downstream.

- [ ] **Step 1: Write the failing test**

```r
# tests/testthat/test-categories.R
test_that("CANONICAL_BATTING_CATEGORIES and CANONICAL_PITCHER_CATEGORIES partition the canonical set", {
  expect_true(length(intersect(CANONICAL_BATTING_CATEGORIES,
                               CANONICAL_PITCHER_CATEGORIES)) == 0L)
  expect_setequal(
    union(CANONICAL_BATTING_CATEGORIES, CANONICAL_PITCHER_CATEGORIES),
    CANONICAL_CATEGORIES
  )
})

test_that(".classify_category_side() returns 'batter' for hitter cats", {
  expect_equal(.classify_category_side("HR"), "batter")
  expect_equal(.classify_category_side("AVG"), "batter")
  expect_equal(.classify_category_side("OPS"), "batter")
})

test_that(".classify_category_side() returns 'pitcher' for pitcher cats", {
  expect_equal(.classify_category_side("ERA"), "pitcher")
  expect_equal(.classify_category_side("K/9"), "pitcher")
  expect_equal(.classify_category_side("SV"), "pitcher")
})

test_that(".classify_category_side() returns NA for unknown cats", {
  expect_true(is.na(.classify_category_side("UNKNOWN")))
})

test_that(".classify_category_side() is vectorized", {
  expect_equal(
    .classify_category_side(c("HR", "ERA", "??")),
    c("batter", "pitcher", NA_character_)
  )
})
```

- [ ] **Step 2: Run the test, expecting FAIL**

```bash
Rscript -e 'devtools::test(filter = "categories")'
```
Expected: FAIL — file does not yet exist.

- [ ] **Step 3: Implement `R/categories.R`**

```r
# R/categories.R — Canonical category lists, partitioned by side.
#
# Single source of truth for which scored category belongs to hitters vs
# pitchers. Used by league_config validators, zaa()/zar()/par()/pvm() to
# scope per-side z-score computations, and by .classify_custom_player_type()
# in get-projections-internal.R when the user supplies a custom data frame
# without a player_type column.

#' @noRd
CANONICAL_BATTING_CATEGORIES <- c(
  "HR", "R", "RBI", "SB", "AVG", "OPS"
)

#' @noRd
CANONICAL_PITCHER_CATEGORIES <- c(
  "W", "K", "SV", "HLD", "QS", "SVHD",
  "ERA", "WHIP", "FIP", "XFIP", "SIERA", "XERA",
  "K/9", "BB/9", "HR/9"
)

#' @noRd
.classify_category_side <- function(cat) {
  cat_u <- toupper(cat)
  out <- rep(NA_character_, length(cat_u))
  out[cat_u %in% CANONICAL_BATTING_CATEGORIES] <- "batter"
  out[cat_u %in% CANONICAL_PITCHER_CATEGORIES] <- "pitcher"
  out
}
```

- [ ] **Step 4: Update `R/league-config.R`'s `CANONICAL_CATEGORIES` to be derived**

The old constant `CANONICAL_CATEGORIES` (a single combined list at lines 12-27 of `R/league-config.R`) stays — but is now derived as the union, computed at package load.

In `R/league-config.R`, replace lines 11-27:

```r
#' @noRd
CANONICAL_CATEGORIES <- c(
  CANONICAL_BATTING_CATEGORIES,
  CANONICAL_PITCHER_CATEGORIES
)
```

- [ ] **Step 5: Run the test, expecting PASS**

```bash
Rscript -e 'devtools::test(filter = "categories")'
```
Expected: PASS, all 5 tests.

- [ ] **Step 6: Commit**

```bash
git add R/categories.R R/league-config.R tests/testthat/test-categories.R
git commit -m "$(cat <<'EOF'
feat(categories): add CANONICAL_BATTING/PITCHER lists and side classifier

Single source of truth for which scored category belongs to hitters vs
pitchers. CANONICAL_CATEGORIES becomes a derived union. Used downstream
to scope per-side z-score computation in zaa()/zar()/par()/pvm() and to
classify custom projections lacking a player_type column.
EOF
)"
```

### Task 1.2: Lift `PVM_PITCHER_CATEGORIES` out of `R/pvm.R`

**Files:**
- Modify: `R/pvm.R` (remove the local constant)
- Modify: `R/categories.R` (add a documented re-export note)

`PVM_PITCHER_CATEGORIES` in `R/pvm.R:12-16` is `c("W", "K", "SV", "HLD", "SVHD", "QS", "ERA", "WHIP", "FIP", "XFIP", "SIERA", "XERA", "K/9", "BB/9", "HR/9")` — exactly equal to `CANONICAL_PITCHER_CATEGORIES` from Task 1.1.

- [ ] **Step 1: Delete `PVM_PITCHER_CATEGORIES` definition from `R/pvm.R`**

Locate at `R/pvm.R:12-16`. Delete those lines including the `#' @noRd` tag.

- [ ] **Step 2: Replace all references in `R/pvm.R`**

Inside `R/pvm.R`, replace `PVM_PITCHER_CATEGORIES` with `CANONICAL_PITCHER_CATEGORIES` (currently at lines ~470-471 and ~596 — search for the constant name to find all sites).

```bash
Rscript -e 'cat(system("grep -n PVM_PITCHER_CATEGORIES R/pvm.R", intern = TRUE), sep = "\n")'
```

For each hit, swap the identifier.

- [ ] **Step 3: Run pvm tests**

```bash
Rscript -e 'devtools::test(filter = "pvm")'
```
Expected: PASS — names match identically, no behavior change.

- [ ] **Step 4: Commit**

```bash
git add R/pvm.R
git commit -m "refactor(pvm): use shared CANONICAL_PITCHER_CATEGORIES from categories.R"
```

---

## Phase 2 — `league_config()` API

The constructor's `categories` argument splits into `batting_categories` + `pitcher_categories`. Both required. No default. No migration shim — pre-1.0.

### Task 2.1: Add validators

**Files:**
- Modify: `R/league-config.R`

- [ ] **Step 1: Write failing tests**

Add to `tests/testthat/test-league-config.R` a new context:

```r
test_that("league_config() requires batting_categories and pitcher_categories", {
  expect_error(
    league_config(
      n_teams       = 12L,
      roster_slots  = c(C = 1L),
      pitcher_slots = 9L
    ),
    class = "rotostats_error_invalid_categories"
  )
})

test_that("league_config() rejects empty character vectors for either side", {
  expect_error(
    league_config(
      n_teams            = 12L,
      roster_slots       = c(C = 1L),
      pitcher_slots      = 9L,
      batting_categories = character(0),
      pitcher_categories = c("W", "K")
    ),
    class = "rotostats_error_invalid_categories"
  )
  expect_error(
    league_config(
      n_teams            = 12L,
      roster_slots       = c(C = 1L),
      pitcher_slots      = 9L,
      batting_categories = c("HR", "R"),
      pitcher_categories = character(0)
    ),
    class = "rotostats_error_invalid_categories"
  )
})

test_that("league_config() warns when a batting cat is in the canonical pitcher list", {
  expect_warning(
    league_config(
      n_teams            = 12L,
      roster_slots       = c(C = 1L),
      pitcher_slots      = 9L,
      batting_categories = c("HR", "ERA"),  # ERA misplaced
      pitcher_categories = c("W", "K")
    ),
    class = "rotostats_warning_category_side_mismatch"
  )
})

test_that("league_config() warns when a pitcher cat is in the canonical batting list", {
  expect_warning(
    league_config(
      n_teams            = 12L,
      roster_slots       = c(C = 1L),
      pitcher_slots      = 9L,
      batting_categories = c("HR", "R"),
      pitcher_categories = c("W", "K", "AVG")  # AVG misplaced
    ),
    class = "rotostats_warning_category_side_mismatch"
  )
})

test_that("league_config() stores both fields normalized to uppercase", {
  cfg <- league_config(
    n_teams            = 12L,
    roster_slots       = c(C = 1L),
    pitcher_slots      = 9L,
    batting_categories = c("hr", "r"),
    pitcher_categories = c("w", "k")
  )
  expect_equal(cfg$batting_categories, c("HR", "R"))
  expect_equal(cfg$pitcher_categories, c("W", "K"))
})

test_that("config$categories convenience field returns the union", {
  cfg <- league_config(
    n_teams            = 12L,
    roster_slots       = c(C = 1L),
    pitcher_slots      = 9L,
    batting_categories = c("HR", "R"),
    pitcher_categories = c("W", "K")
  )
  expect_setequal(cfg$categories, c("HR", "R", "W", "K"))
})
```

- [ ] **Step 2: Run, expecting FAIL**

```bash
Rscript -e 'devtools::test(filter = "league-config")'
```
Expected: FAIL — argument names don't exist yet.

- [ ] **Step 3: Implement `validate_side_categories()` in `R/league-config.R`**

Replace the existing `validate_categories()` function (lines 278-308) with:

```r
#' @noRd
validate_side_categories <- function(
  cats,
  arg_name,
  canonical_for_side,
  canonical_for_other_side
) {
  if (!is.character(cats) || length(cats) == 0L || any(is.na(cats))) {
    cli::cli_abort(
      c(
        "{.arg {arg_name}} must be a non-empty character vector.",
        i = "Received: {.val {cats}}."
      ),
      class = "rotostats_error_invalid_categories"
    )
  }
  cats_upper <- toupper(cats)

  # Side-mismatch warning: a category present here that the canonical lists
  # assign to the other side. Doesn't block — leagues can score odd combos —
  # but loudly surfaces typos like batting_categories = c("HR", "ERA").
  misplaced <- intersect(cats_upper, canonical_for_other_side)
  if (length(misplaced)) {
    cli::cli_warn(
      c(
        "{.val {misplaced}} {?is/are} normally scored on the other side; \\
         appearing in {.arg {arg_name}}.",
        i = "If this is intentional, ignore this warning."
      ),
      class = "rotostats_warning_category_side_mismatch"
    )
  }

  # Unknown-category warning: not in either canonical list.
  unknown <- setdiff(
    cats_upper,
    union(canonical_for_side, canonical_for_other_side)
  )
  if (length(unknown)) {
    cli::cli_warn(
      c(
        "Unrecognized {.arg {arg_name}}: {.val {unknown}}.",
        i = "Accepted but unvalidated against canonical lists."
      ),
      class = "rotostats_warning_unknown_category"
    )
  }

  cats_upper
}

#' @noRd
validate_batting_categories <- function(cats) {
  validate_side_categories(
    cats,
    arg_name                 = "batting_categories",
    canonical_for_side       = CANONICAL_BATTING_CATEGORIES,
    canonical_for_other_side = CANONICAL_PITCHER_CATEGORIES
  )
}

#' @noRd
validate_pitcher_categories <- function(cats) {
  validate_side_categories(
    cats,
    arg_name                 = "pitcher_categories",
    canonical_for_side       = CANONICAL_PITCHER_CATEGORIES,
    canonical_for_other_side = CANONICAL_BATTING_CATEGORIES
  )
}
```

- [ ] **Step 4: Run, expecting PASS for the three validator-only tests** (constructor change comes next)

The `expect_error(..., class = "rotostats_error_invalid_categories")` test still fails because the constructor signature hasn't changed. That's wired up in Task 2.2.

- [ ] **Step 5: Commit**

```bash
git add R/league-config.R tests/testthat/test-league-config.R
git commit -m "feat(league-config): add side-aware category validators"
```

### Task 2.2: Switch the constructor signature

**Files:**
- Modify: `R/league-config.R` (constructor body and roxygen doc)

- [ ] **Step 1: Replace constructor signature and body**

Replace `R/league-config.R:105-144` with:

```r
league_config <- function(
  n_teams = 12L,
  roster_slots,
  pitcher_slots = 9L,
  batting_categories,
  pitcher_categories,
  inverse_categories = NULL,
  league_type = "mixed",
  budget = 260L,
  budget_split = 0.60,
  keeper = FALSE
) {
  n_teams       <- validate_n_teams(n_teams)
  league_type   <- validate_league_type(league_type)
  roster_slots  <- validate_roster_slots(roster_slots)
  pitcher_slots <- validate_pitcher_slots(pitcher_slots)
  budget        <- validate_budget(budget)
  budget_split  <- validate_budget_split(budget_split)

  batting_categories <- validate_batting_categories(batting_categories)
  pitcher_categories <- validate_pitcher_categories(pitcher_categories)

  # Convenience union — canonical order is batting first, then pitcher.
  categories <- c(batting_categories, pitcher_categories)

  inverse_categories <- validate_inverse_categories(
    inverse_categories,
    categories
  )
  roster_slots <- drop_dh_for_nl(roster_slots, league_type)
  keeper       <- resolve_keeper(keeper)

  structure(
    list(
      n_teams            = n_teams,
      roster_slots       = roster_slots,
      pitcher_slots      = pitcher_slots,
      batting_categories = batting_categories,
      pitcher_categories = pitcher_categories,
      categories         = categories,
      inverse_categories = inverse_categories,
      league_type        = league_type,
      budget             = budget,
      budget_split       = budget_split,
      keeper             = keeper
    ),
    class = c("league_config", "list")
  )
}
```

- [ ] **Step 2: Update the roxygen doc block** (lines 45-104)

Replace the `@param categories` block with:

```r
#' @param batting_categories Character vector of scored batting categories.
#'   Normalized to uppercase. Required. Validates against
#'   `CANONICAL_BATTING_CATEGORIES`; categories belonging to the canonical
#'   pitcher list emit `rotostats_warning_category_side_mismatch`.
#' @param pitcher_categories Character vector of scored pitcher categories.
#'   Normalized to uppercase. Required. Validates against
#'   `CANONICAL_PITCHER_CATEGORIES`; categories belonging to the canonical
#'   batting list emit `rotostats_warning_category_side_mismatch`.
```

Update the example block:

```r
#' @examples
#' lg <- league_config(
#'   n_teams            = 12L,
#'   roster_slots       = c(C = 1, "1B" = 1, "2B" = 1, "3B" = 1,
#'                          SS = 1, OF = 5, UTIL = 1),
#'   pitcher_slots      = c(SP = 6L, RP = 3L),
#'   batting_categories = c("R", "HR", "RBI", "SB", "AVG"),
#'   pitcher_categories = c("W", "K", "SV", "ERA", "WHIP")
#' )
#' print(lg)
```

- [ ] **Step 3: Run all league-config tests, expecting PASS**

```bash
Rscript -e 'devtools::document(); devtools::test(filter = "league-config")'
```

- [ ] **Step 4: Commit**

```bash
git add R/league-config.R man/league_config.Rd
git commit -m "$(cat <<'EOF'
feat(league-config)!: split categories into batting/pitcher

BREAKING: replace `categories` arg with `batting_categories` +
`pitcher_categories`. config$categories is preserved as a derived union
for callers that legitimately want both sides at once. No migration
shim — pre-1.0, fail loud.
EOF
)"
```

### Task 2.3: Update `print.league_config`

**Files:**
- Modify: `R/league-config.R:450-491`

- [ ] **Step 1: Write the failing test**

Add to `tests/testthat/test-league-config.R`:

```r
test_that("print.league_config() shows batting and pitcher cats on separate lines", {
  cfg <- league_config(
    n_teams            = 12L,
    roster_slots       = c(C = 1L),
    pitcher_slots      = 9L,
    batting_categories = c("HR", "R", "AVG"),
    pitcher_categories = c("W", "K", "ERA")
  )
  txt <- capture.output(print(cfg))
  expect_true(any(grepl("Batting:.*HR.*R.*AVG", txt)))
  expect_true(any(grepl("Pitching:.*W.*K.*ERA", txt)))
})
```

- [ ] **Step 2: Run, expecting FAIL**

```bash
Rscript -e 'devtools::test(filter = "league-config")'
```

- [ ] **Step 3: Replace the print method's category section**

In `R/league-config.R:473-477`, replace:

```r
  cat(sprintf(
    "  Categories: %s  (%d)\n",
    paste(x$categories, collapse = " "),
    length(x$categories)
  ))
```

with:

```r
  cat(sprintf(
    "  Batting:    %s  (%d)\n",
    paste(x$batting_categories, collapse = " "),
    length(x$batting_categories)
  ))
  cat(sprintf(
    "  Pitching:   %s  (%d)\n",
    paste(x$pitcher_categories, collapse = " "),
    length(x$pitcher_categories)
  ))
```

- [ ] **Step 4: Run, expecting PASS**

```bash
Rscript -e 'devtools::test(filter = "league-config")'
```

- [ ] **Step 5: Commit**

```bash
git add R/league-config.R tests/testthat/test-league-config.R
git commit -m "feat(league-config): split print output into batting and pitching lines"
```

---

## Phase 3 — Test fixtures (mechanical migration)

Every helper that constructs a `league_config()` must be migrated to the new arg form. Each fixture is small and self-contained; the migration is mechanical and shows up across the test suite as red until done.

### Task 3.1: Migrate `helper-zaa-fixtures.R`

**Files:**
- Modify: `tests/testthat/helper-zaa-fixtures.R`

- [ ] **Step 1: Read the file**

```bash
Rscript -e 'cat(readLines("tests/testthat/helper-zaa-fixtures.R"), sep = "\n")'
```

- [ ] **Step 2: Apply the rewrite**

In every call to `league_config(...)` in this file, replace the single `categories = c(...)` argument with two separate args. Use `.classify_category_side()` mentally to bucket cats:

For example, replace:

```r
  config <- league_config(
    n_teams       = n_teams,
    roster_slots  = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots = c(SP = 1L, RP = 1L),
    categories    = c("HR", "R", "SB", "K", "SV"),
    league_type   = "mixed"
  )
```

with:

```r
  config <- league_config(
    n_teams            = n_teams,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 1L, RP = 1L),
    batting_categories = c("HR", "R", "SB"),
    pitcher_categories = c("K", "SV"),
    league_type        = "mixed"
  )
```

- [ ] **Step 3: Run zaa tests to surface any other usages**

```bash
Rscript -e 'devtools::test(filter = "zaa")'
```

Tests will still fail because `zaa()` itself hasn't been updated. That's expected — we're migrating fixture call sites only.

- [ ] **Step 4: Commit**

```bash
git add tests/testthat/helper-zaa-fixtures.R
git commit -m "test(fixtures): migrate zaa fixtures to batting/pitcher_categories"
```

### Task 3.2: Migrate `helper-zar-fixtures.R`

**Files:**
- Modify: `tests/testthat/helper-zar-fixtures.R`

Four `league_config()` call sites in this file (lines 24, 59, 93, 136 in the current source). Each migrated the same way: split `categories` by side using `.classify_category_side()` mentally.

- [ ] **Step 1: Apply migration**

In `make_zar_fixture()`:
```r
    batting_categories = c("HR", "R", "SB"),
    pitcher_categories = c("K", "SV"),
```

In `make_zar_rate_fixture()`:
```r
    batting_categories = c("HR", "R"),
    pitcher_categories = c("ERA"),
```

In `make_zar_sv_fixture()`:
```r
    batting_categories = c("HR", "R", "SB"),
    pitcher_categories = c("K", "SV"),
```

In `make_zar_boundary_fixture()`:
```r
    batting_categories = c("HR", "R", "SB"),
    pitcher_categories = c("K", "SV"),
```

- [ ] **Step 2: Commit**

```bash
git add tests/testthat/helper-zar-fixtures.R
git commit -m "test(fixtures): migrate zar fixtures to batting/pitcher_categories"
```

### Task 3.3: Migrate `helper-par-fixtures.R`

**Files:**
- Modify: `tests/testthat/helper-par-fixtures.R`

- [ ] **Step 1: Read it**

```bash
Rscript -e 'cat(readLines("tests/testthat/helper-par-fixtures.R"), sep = "\n")'
```

- [ ] **Step 2: For every `league_config(... categories = ...)` call, split by side**

Use the same mental partition. If a fixture only scores hitter cats, set `pitcher_categories = c("K")` (any one canonical pitcher cat) so the constructor accepts it; the tests that only assert hitter behavior will not look at pitcher output. (Conversely for pitcher-only fixtures.)

Document this in a comment at the top of any fixture where the unused-side default is supplied:

```r
# pitcher_categories supplied as a placeholder; this fixture only exercises
# hitter PAR. The placeholder ensures league_config() accepts the call.
```

- [ ] **Step 3: Commit**

```bash
git add tests/testthat/helper-par-fixtures.R
git commit -m "test(fixtures): migrate par fixtures to batting/pitcher_categories"
```

### Task 3.4: Migrate `helper-pvm-fixtures.R`

**Files:**
- Modify: `tests/testthat/helper-pvm-fixtures.R`

Same mechanical migration as Task 3.3.

- [ ] **Step 1: Apply migration**

For each call site, partition `categories` into the two side-specific args.

- [ ] **Step 2: Commit**

```bash
git add tests/testthat/helper-pvm-fixtures.R
git commit -m "test(fixtures): migrate pvm fixtures to batting/pitcher_categories"
```

### Task 3.5: Verify `helper-test-data.R` needs no change

**Files:**
- Read only: `tests/testthat/helper-test-data.R`

`make_projections_data()` doesn't touch `league_config`. It already produces hitter rows with NA pitcher stats and vice versa, which is the shape the new architecture relies on. No migration needed.

- [ ] **Step 1: Verify no changes needed**

```bash
Rscript -e 'cat(grep("league_config", readLines("tests/testthat/helper-test-data.R"), value = TRUE), sep = "\n")'
```
Expected: empty output. No league_config call sites.

- [ ] **Step 2: No commit (no changes)**

### Task 3.6: Migrate test files (mechanical)

**Files (one commit each is fine, or a single bulk commit at end of phase):**
- `tests/testthat/test-league-config.R` (already touched in Task 2 — skip if covered there)
- `tests/testthat/test-zaa.R`
- `tests/testthat/test-zar.R`
- `tests/testthat/test-par.R`
- `tests/testthat/test-par-sim.R`
- `tests/testthat/test-pvm.R`
- `tests/testthat/test-replacement.R`
- `tests/testthat/test-replacement-integration.R`
- `tests/testthat/test-replacement-from-prices.R`
- `tests/testthat/test-sgp.R`
- `tests/testthat/test-sgp-integration.R`
- `tests/testthat/test-sgp-denominators.R`
- `tests/testthat/test-inverse-categories.R`

For each test file: find every direct `league_config(... categories = ...)` call and split it into `batting_categories = ...` + `pitcher_categories = ...`. Tests that exercise hitter-only (or pitcher-only) behavior need a placeholder for the unused side; comment that it is a placeholder.

- [ ] **Step 1: Find all call sites across test files**

```bash
Rscript -e 'system("grep -rn -- \"league_config(\" tests/testthat/ | grep -v helper-")'
```

- [ ] **Step 2: Migrate each call site**

For each, partition `categories` into the two new args. Remove the now-misnamed singular arg.

- [ ] **Step 3: Run the full test suite to surface remaining red**

```bash
Rscript -e 'devtools::test()'
```

Many tests will still fail because `zaa()` / `zar()` / `replacement_level()` haven't been migrated yet — that's expected. We just want the failures to be inside the consumers, not in the constructor calls.

- [ ] **Step 4: Commit**

```bash
git add tests/testthat/
git commit -m "$(cat <<'EOF'
test: migrate all league_config() callers to split categories

Mechanical update of every test file that constructs a league_config().
Tests still fail in consumers (zaa, zar, replacement_level) because
those haven't been migrated yet — phases 4-6 land those changes.
EOF
)"
```

---

## Phase 4 — `zaa()` core split

`zaa()` is the bug epicenter. Today it iterates every `cat in categories` over every player pool, regardless of side. The rewrite computes hitter z-scores against the hitter pool only and pitcher z-scores against the pitcher pool only.

### Task 4.1: Side-partition helper for the projection pool

**Files:**
- Modify: `R/replacement_internal.R` (or `R/zaa.R` — choose `replacement_internal.R` since the helper is shared)
- Test: `tests/testthat/test-replacement-internal.R` (create if absent)

The helper splits a projections data frame into `list(batter = <df>, pitcher = <df>)`. Honors `player_type` if present (canonical case from `get_projections()`); falls back to `pos_eligibility` regex matching `PITCHER_ELIG_REGEX`.

- [ ] **Step 1: Write the failing test**

```r
test_that(".partition_projections_by_side() uses player_type when present", {
  df <- data.frame(
    player_id   = c("A", "B", "C"),
    player_type = c("batter", "pitcher", "batter"),
    stringsAsFactors = FALSE
  )
  parts <- .partition_projections_by_side(df)
  expect_equal(parts$batter$player_id, c("A", "C"))
  expect_equal(parts$pitcher$player_id, "B")
})

test_that(".partition_projections_by_side() falls back to pos_eligibility regex", {
  df <- data.frame(
    player_id       = c("A", "B", "C"),
    pos_eligibility = c("OF", "SP", "1B|OF"),
    stringsAsFactors = FALSE
  )
  parts <- .partition_projections_by_side(df)
  expect_equal(parts$batter$player_id, c("A", "C"))
  expect_equal(parts$pitcher$player_id, "B")
})

test_that(".partition_projections_by_side() duplicates two-way players", {
  df <- data.frame(
    player_id   = "ohtani",
    player_type = "two_way",   # surfaced upstream; treated as both
    stringsAsFactors = FALSE
  )
  parts <- .partition_projections_by_side(df)
  expect_equal(parts$batter$player_id, "ohtani")
  expect_equal(parts$pitcher$player_id, "ohtani")
})
```

- [ ] **Step 2: Run, expecting FAIL**

```bash
Rscript -e 'devtools::test(filter = "replacement-internal")'
```

- [ ] **Step 3: Implement helper**

In `R/replacement_internal.R`:

```r
#' @noRd
.partition_projections_by_side <- function(df) {
  stopifnot(is.data.frame(df))

  if ("player_type" %in% names(df)) {
    pt <- df$player_type
    bat_idx <- which(pt %in% c("batter", "two_way"))
    pit_idx <- which(pt %in% c("pitcher", "two_way"))
  } else if ("pos_eligibility" %in% names(df)) {
    is_pit <- grepl(PITCHER_ELIG_REGEX, df$pos_eligibility)
    bat_idx <- which(!is_pit)
    pit_idx <- which(is_pit)
  } else {
    cli::cli_abort(
      c(
        "Cannot partition projections by side.",
        i = "Need either {.field player_type} or {.field pos_eligibility} column.",
        i = "Columns present: {.val {names(df)}}."
      ),
      class = "rotostats_error_missing_column"
    )
  }
  list(
    batter  = df[bat_idx, , drop = FALSE],
    pitcher = df[pit_idx, , drop = FALSE]
  )
}
```

- [ ] **Step 4: Run, expecting PASS**

- [ ] **Step 5: Commit**

```bash
git add R/replacement_internal.R tests/testthat/test-replacement-internal.R
git commit -m "feat(replacement): add .partition_projections_by_side() helper"
```

### Task 4.2: Rewrite `zaa()` main loop

**Files:**
- Modify: `R/zaa.R`

The current loop (lines ~571-704 of `R/zaa.R`) iterates `for (cat in categories) for (pool in pools)` with no side awareness. The rewrite first partitions the pool by side, then iterates `batting_categories` × hitter-pools and `pitcher_categories` × pitcher-pools separately. After computing both sides, it `rbind()`s the two output frames with cross-side cells set to NA.

- [ ] **Step 1: Write the failing test**

```r
# Add to tests/testthat/test-zaa.R
test_that("zaa() output has NA for cross-side categories", {
  fx <- make_zar_fixture()  # batting_categories = c("HR","R","SB"),
                             # pitcher_categories = c("K","SV")
  out <- zaa(fx$replacement)

  pitcher_rows <- subset(out, player_type == "pitcher")
  batter_rows  <- subset(out, player_type == "batter")

  expect_true(all(is.na(pitcher_rows$zaa_hr)))
  expect_true(all(is.na(pitcher_rows$zaa_r)))
  expect_true(all(is.na(pitcher_rows$zaa_sb)))
  expect_true(all(is.na(batter_rows$zaa_k)))
  expect_true(all(is.na(batter_rows$zaa_sv)))

  # Same-side cells are finite (or NA only for valid same-side reasons like
  # missing playing-time inputs).
  expect_true(any(is.finite(pitcher_rows$zaa_k)))
  expect_true(any(is.finite(batter_rows$zaa_hr)))
})
```

- [ ] **Step 2: Run, expecting FAIL**

```bash
Rscript -e 'devtools::test(filter = "zaa")'
```

- [ ] **Step 3: Read `R/zaa.R` end-to-end** (file is large — read in chunks)

```bash
Rscript -e 'cat(readLines("R/zaa.R"), sep = "\n")' | head -300
Rscript -e 'cat(readLines("R/zaa.R"), sep = "\n")' | sed -n "270,710p"
```

- [ ] **Step 4: Replace the categories binding (line ~279)**

Find:
```r
categories <- working_config$categories
```

Replace with:
```r
batting_categories <- working_config$batting_categories
pitcher_categories <- working_config$pitcher_categories
```

- [ ] **Step 5: Refactor the main loop into a per-side helper**

Extract the existing `for (cat in categories)` body (lines ~571-704 of `R/zaa.R`) verbatim into an internal helper `.zaa_compute_one_side()`. **The body of the helper is identical to the existing code** — the only changes are the function header and three name substitutions performed by find-and-replace within the moved block:

| Old name (in current loop) | New name (inside helper) |
|----------------------------|--------------------------|
| `categories`               | `side_categories`        |
| `pools`                    | `side_pools`             |
| `projections`              | `side_projections`       |

```r
#' @noRd
.zaa_compute_one_side <- function(
  side,                # "batter" or "pitcher"
  side_categories,     # character; must already be uppercase
  side_projections,    # data frame, side-only
  side_pools,          # named list of player-id vectors (positional / split)
  working_config,
  weight_method,
  category_weight,
  pitcher_pool,
  player_replacement
) {
  # ----------------------------------------------------------------------
  # Body: paste the current contents of R/zaa.R lines 571-704 verbatim,
  # then run the three substitutions in the table above. No logic edits.
  # ----------------------------------------------------------------------
}
```

After moving the lines, the original site (lines 571-704) is replaced by the two-call dispatch shown in Step 6.

- [ ] **Step 6: Replace the call site with two invocations + a union**

Where the old loop ended and packaged its result into `zaa_matrix` / `zaa_long`, replace with:

```r
parts <- .partition_projections_by_side(projections)

batter_pools  <- .filter_pools_to_side(pools, side = "batter",  parts = parts)
pitcher_pools <- .filter_pools_to_side(pools, side = "pitcher", parts = parts)

batter_zaa <- .zaa_compute_one_side(
  side               = "batter",
  side_categories    = batting_categories,
  side_projections   = parts$batter,
  side_pools         = batter_pools,
  working_config     = working_config,
  weight_method      = weight_method,
  category_weight    = category_weight,
  pitcher_pool       = pitcher_pool,
  player_replacement = player_replacement
)

pitcher_zaa <- .zaa_compute_one_side(
  side               = "pitcher",
  side_categories    = pitcher_categories,
  side_projections   = parts$pitcher,
  side_pools         = pitcher_pools,
  working_config     = working_config,
  weight_method      = weight_method,
  category_weight    = category_weight,
  pitcher_pool       = pitcher_pool,
  player_replacement = player_replacement
)

zaa_long <- .union_with_na_cross_side(batter_zaa, pitcher_zaa)
```

`.filter_pools_to_side()` is a one-liner helper:

```r
#' @noRd
.filter_pools_to_side <- function(pools, side, parts) {
  ids <- parts[[side]]$player_id
  lapply(pools, function(pool_ids) intersect(pool_ids, ids))
}
```

`.union_with_na_cross_side()` rbinds two frames and fills the union of columns with NA where missing:

```r
#' @noRd
.union_with_na_cross_side <- function(bat, pit) {
  if (nrow(bat) == 0L) return(pit)
  if (nrow(pit) == 0L) return(bat)
  all_cols <- union(names(bat), names(pit))
  fill <- function(df) {
    for (c in setdiff(all_cols, names(df))) df[[c]] <- NA
    df[, all_cols, drop = FALSE]
  }
  rbind(fill(bat), fill(pit))
}
```

- [ ] **Step 7: Update the distribution attribute schema**

The distribution attribute (currently flat for non-positional pools, nested for positional/split pools — lines ~685-703) must now be keyed by side first. Old shape:

```r
distribution[[cat]][[pos]] <- list(mu = ..., sigma = ..., n = ..., source = ...)
```

New shape:

```r
distribution$batter[[cat]][[pos]]  <- list(...)
distribution$pitcher[[cat]][[pos]] <- list(...)
```

Document this in the function-level roxygen `@return` block.

- [ ] **Step 8: Run zaa tests, expecting PASS**

```bash
Rscript -e 'devtools::document(); devtools::test(filter = "zaa")'
```

- [ ] **Step 9: Commit**

```bash
git add R/zaa.R man/zaa.Rd tests/testthat/test-zaa.R
git commit -m "$(cat <<'EOF'
fix(zaa)!: compute per-side z-scores against same-side pools only

BREAKING: zaa() output has NA (not 0) for cross-side category cells.
Pitchers no longer receive zaa_hr / zaa_r / zaa_sb because the FanGraphs
pitcher-endpoint hr/r columns (HR allowed, R allowed) used to collide
with hitter columns of the same name and contaminate downstream values.

The distribution attribute is now keyed by side first:
  attr(zaa_out, "distribution")$batter[[cat]][[pos]]
  attr(zaa_out, "distribution")$pitcher[[cat]][[pos]]
EOF
)"
```

### Task 4.3: Throttle the verbose `rotostats_warning_zero_playing_time` warning

**Files:**
- Modify: `R/zaa.R` (lines ~622-640)

The current implementation emits one warning per offending player. After the side split, this warning should rarely fire — but when a same-side player legitimately has zero playing time (an SP listed with 0 IP), we still want one warning, not hundreds.

- [ ] **Step 1: Write the failing test**

```r
# tests/testthat/test-zaa.R
test_that("zaa() emits at most one zero-playing-time warning per side per cat", {
  proj <- make_projections_data(seed = 11L)
  # Force half the SP pool to have 0 IP — pre-fix would warn N times.
  sp_idx <- which(proj$pos_eligibility == "SP")
  proj$IP[sp_idx[1:5]] <- 0

  cfg <- league_config(
    n_teams            = 4L,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 3L, RP = 2L),
    batting_categories = c("HR", "R"),
    pitcher_categories = c("ERA")
  )
  repl <- replacement_level(proj, cfg)

  warnings_emitted <- testthat::capture_warnings(zaa(repl))
  zero_pt <- grep("zero.*playing.*time|0 IP|0 AB", warnings_emitted,
                  ignore.case = TRUE, value = TRUE)
  expect_lte(length(zero_pt), 2L)  # one summary per affected cat-side, not per player
})
```

- [ ] **Step 2: Run, expecting FAIL**

- [ ] **Step 3: Replace per-player warning with per-(side, cat) summary**

Inside `.zaa_compute_one_side()`, where the per-player check currently fires `cli::cli_warn(... class = "rotostats_warning_zero_playing_time")`, accumulate offending player IDs into a side-scoped vector and emit at most one summary per side-and-category combination at the end of the side computation.

```r
# inside .zaa_compute_one_side:
zero_pt_ids <- character(0)
# ... in the loop, instead of warning per player:
zero_pt_ids <- c(zero_pt_ids, offending_player_id)
# ... after the loop, before returning:
if (length(zero_pt_ids)) {
  cli::cli_warn(
    c(
      "{.val {length(zero_pt_ids)}} {side} player{?s} {?has/have} zero \\
       playing time for {.val {cat}}; their {.val {cat}} z-score is NA.",
      i = "Sample IDs: {.val {head(zero_pt_ids, 5)}}{cli::qty(length(zero_pt_ids))}{?./...}"
    ),
    class = "rotostats_warning_zero_playing_time"
  )
}
```

- [ ] **Step 4: Run, expecting PASS**

- [ ] **Step 5: Commit**

```bash
git add R/zaa.R tests/testthat/test-zaa.R
git commit -m "$(cat <<'EOF'
fix(zaa): summarize zero-playing-time warnings instead of one-per-player

After the side split this warning should mostly disappear because pitchers
are no longer evaluated against AB-denominated AVG and hitters against
IP-denominated ERA. For the residual same-side cases (e.g. an SP with
0 IP), emit one summary per (side, category) instead of one warning per
offending player.
EOF
)"
```

### Task 4.4: Re-enable the regression test from Task 0.2

**Files:**
- Modify: `tests/testthat/test-zar-cross-side-regression.R`

Wait — `zar()` is not yet split (Phase 5). Don't re-enable yet; the regression test will be re-enabled in Phase 10. Skip this step here. (Listed for traceability.)

---

## Phase 5 — Consumers (`zar`, `par`, `pvm`)

### Task 5.1: Update `zar()`

**Files:**
- Modify: `R/zar.R`

`R/zar.R:222-223`:
```r
distribution <- attr(zaa_result, "distribution")
categories   <- config$categories
```

The new `distribution` is keyed by side. The new loop iterates `batting_categories` against the batter slice and `pitcher_categories` against the pitcher slice.

- [ ] **Step 1: Write failing test (already in test-zar-cross-side-regression.R from Task 0.2 — re-enable later in Phase 10)**

For unit-level coverage, add to `tests/testthat/test-zar.R`:

```r
test_that("zar() output respects per-side category scoping", {
  fx <- make_zar_fixture()
  out <- zar(fx$replacement)

  pitcher_rows <- subset(out, player_type == "pitcher")
  batter_rows  <- subset(out, player_type == "batter")

  # Pitcher rows: NA for batting cats; finite (or NA-with-reason) for pitcher cats.
  expect_true(all(is.na(pitcher_rows$zar_hr)))
  expect_true(all(is.na(pitcher_rows$zar_r)))
  expect_true(all(is.na(pitcher_rows$zar_sb)))
  expect_true(all(is.na(batter_rows$zar_k)))
  expect_true(all(is.na(batter_rows$zar_sv)))

  # total_zar uses na.rm = TRUE so each side's intra-side total is well defined.
  expect_true(all(is.finite(pitcher_rows$total_zar)))
  expect_true(all(is.finite(batter_rows$total_zar)))
})
```

- [ ] **Step 2: Run, expecting FAIL**

- [ ] **Step 3: Update `R/zar.R`**

Find the categories binding (line ~222-223):

```r
distribution <- attr(zaa_result, "distribution")
categories   <- config$categories
```

Replace with:

```r
distribution       <- attr(zaa_result, "distribution")
batting_categories <- config$batting_categories
pitcher_categories <- config$pitcher_categories
```

Replace the single category loop with two side-scoped loops. Skeleton:

```r
# Batter side: iterate batting cats over batter rows of zaa_result.
is_batter <- zaa_result$player_type %in% c("batter", "two_way")
for (cat in batting_categories) {
  cat_lc   <- tolower(cat)
  zaa_col  <- paste0("zaa_", cat_lc)
  rep_col  <- paste0("repl_z_", cat_lc)
  zar_col  <- paste0("zar_", cat_lc)
  zar_matrix[is_batter, zar_col] <-
    zaa_result[is_batter, zaa_col] - replacement_z[is_batter, rep_col]
  # Cross-side rows stay NA — pre-allocated as NA_real_.
}

# Pitcher side: identical structure scoped to pitcher rows.
is_pitcher <- zaa_result$player_type %in% c("pitcher", "two_way")
for (cat in pitcher_categories) {
  cat_lc   <- tolower(cat)
  zaa_col  <- paste0("zaa_", cat_lc)
  rep_col  <- paste0("repl_z_", cat_lc)
  zar_col  <- paste0("zar_", cat_lc)
  zar_matrix[is_pitcher, zar_col] <-
    zaa_result[is_pitcher, zaa_col] - replacement_z[is_pitcher, rep_col]
}
```

`zar_matrix` is pre-allocated as a matrix of `NA_real_` with one column per category in the union; only same-side rows are filled in.

The `total_zar` computation at line 423:

```r
total_zar <- rowSums(zar_matrix, na.rm = TRUE)
```

is already correct — `na.rm = TRUE` means cross-side NAs don't contribute, and each side sums only its own intra-side cells.

- [ ] **Step 4: Run, expecting PASS**

```bash
Rscript -e 'devtools::test(filter = "zar")'
```

- [ ] **Step 5: Commit**

```bash
git add R/zar.R tests/testthat/test-zar.R
git commit -m "$(cat <<'EOF'
fix(zar)!: iterate batting/pitcher categories against same-side pools

BREAKING: zar() output cross-side cells are NA. total_zar already uses
rowSums(na.rm = TRUE) so the per-side intra-side total is unchanged.
EOF
)"
```

### Task 5.2: Update `par()`

**Files:**
- Modify: `R/par.R`

`R/par.R` consumes `attr(replacement, "config")` and iterates `names(replacement_sgp)` (already keyed by `sgp_<cat>`). Most of the loop is already category-name-driven; the remaining work is to ensure pitcher cats are only summed for pitcher rows and vice versa.

- [ ] **Step 1: Write failing test**

```r
# tests/testthat/test-par.R
test_that("par() output respects per-side category scoping", {
  fx <- make_par_fixture()  # parallel to make_zar_fixture
  out <- par(fx$replacement, fx$sgp_output)

  pitcher_rows <- subset(out, player_type == "pitcher")
  batter_rows  <- subset(out, player_type == "batter")

  expect_true(all(is.na(pitcher_rows$par_hr)))
  expect_true(all(is.na(batter_rows$par_k)))
  expect_true(all(is.finite(pitcher_rows$total_par)))
  expect_true(all(is.finite(batter_rows$total_par)))
})
```

- [ ] **Step 2: Run, expecting FAIL**

- [ ] **Step 3: Update `R/par.R`**

In the `for (cat in scored_cats)` loop (around `R/par.R:305`), gate the per-cat assignment by side:

```r
for (cat in batting_categories) {
  # ... existing body ...
  out[!is_batter_row, paste0("par_", tolower(cat))] <- NA
}
for (cat in pitcher_categories) {
  # ... existing body ...
  out[!is_pitcher_row, paste0("par_", tolower(cat))] <- NA
}
```

Where `is_batter_row` / `is_pitcher_row` are derived from `out$player_type` (carrying through from `zaa()` output).

The `total_par` line 349 already uses `na.rm = TRUE` — no change needed.

- [ ] **Step 4: Run, expecting PASS**

- [ ] **Step 5: Commit**

```bash
git add R/par.R tests/testthat/test-par.R
git commit -m "fix(par)!: NA cross-side category cells; total_par unchanged"
```

### Task 5.3: Update `pvm()`

**Files:**
- Modify: `R/pvm.R`

`R/pvm.R:391`:
```r
scored_cats <- toupper(config$categories)
```

The `cat_pct = "auto"` split (lines ~470-471) and the slot-weighting branch (line ~596) already used the local `PVM_PITCHER_CATEGORIES` to classify side. Task 1.2 already redirected those to `CANONICAL_PITCHER_CATEGORIES`. The remaining change is to scope the cat-pct partition to the league's actual scored cats per side.

- [ ] **Step 1: Write failing test**

```r
# tests/testthat/test-pvm.R
test_that("pvm() splits cat_pct correctly using config$batting/pitcher_categories", {
  fx <- make_pvm_fixture()  # uses split categories
  out <- pvm(fx$replacement, fx$dollar_values, cat_pct = "auto")

  pitcher_rows <- subset(out, player_type == "pitcher")
  batter_rows  <- subset(out, player_type == "batter")

  expect_true(all(is.na(pitcher_rows$pvm_hr)))
  expect_true(all(is.na(batter_rows$pvm_era)))
})
```

- [ ] **Step 2: Run, expecting FAIL**

- [ ] **Step 3: Update `R/pvm.R`**

Replace `scored_cats <- toupper(config$categories)` with:

```r
batting_categories <- toupper(config$batting_categories)
pitcher_categories <- toupper(config$pitcher_categories)
scored_cats        <- c(batting_categories, pitcher_categories)
```

In the per-category loop, gate the pvm cell assignment by side. In the `cat_pct = "auto"` resolution block, sum hitter weights only over `batting_categories` and pitcher weights only over `pitcher_categories`:

```r
# old:
is_pitcher_cat <- cat %in% PVM_PITCHER_CATEGORIES
# new:
is_pitcher_cat <- cat %in% pitcher_categories
```

(Falling back to the package canonical list is no longer necessary because the league's own list is now explicit.)

- [ ] **Step 4: Run, expecting PASS**

- [ ] **Step 5: Commit**

```bash
git add R/pvm.R tests/testthat/test-pvm.R
git commit -m "fix(pvm)!: scope cat_pct partition to config's per-side category lists"
```

---

## Phase 6 — Replacement layer

### Task 6.1: `replacement_level()` partition before per-side computation

**Files:**
- Modify: `R/replacement.R`

Two key sites:

- `R/replacement.R:312`: `cats_upper <- toupper(config$categories)`
- `R/replacement.R:520-525`: hitter_rows / pitcher_rows split via `PITCHER_ELIG_REGEX` (already side-aware!)

The split already happens; the bug is that `cats_upper` carries both sides into a side-aware downstream pipeline. The fix is to bind two side-specific sets and pass each into the matching pool's z-score computation.

- [ ] **Step 1: Write failing test**

```r
# tests/testthat/test-replacement.R
test_that("replacement_level() carries split categories into the output config", {
  proj <- make_projections_data(seed = 13L)
  cfg <- league_config(
    n_teams            = 12L,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 3L, RP = 3L),
    batting_categories = c("HR", "R"),
    pitcher_categories = c("K", "ERA")
  )
  repl <- replacement_level(proj, cfg)

  cfg_out <- attr(repl, "config")
  expect_equal(cfg_out$batting_categories, c("HR", "R"))
  expect_equal(cfg_out$pitcher_categories, c("K", "ERA"))
})

test_that("replacement_level() preserves Ohtani-style two-way duplication", {
  proj <- make_projections_data(seed = 17L)
  # Mark a player as two-way: appears in both pos lists.
  proj$pos_eligibility[1L] <- "OF|SP"
  proj$player_type[1L]    <- "two_way"

  cfg <- league_config(
    n_teams            = 12L,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 3L, RP = 3L),
    batting_categories = c("HR", "R"),
    pitcher_categories = c("K", "ERA")
  )
  repl <- replacement_level(proj, cfg)

  # The two-way player appears once on each side.
  pid <- proj$player_id[1L]
  pids_in_repl <- if (is.data.frame(repl)) repl$player_id else attr(repl, "player_assignments")$player_id
  expect_equal(sum(pids_in_repl == pid), 2L)
})
```

- [ ] **Step 2: Run, expecting FAIL**

- [ ] **Step 3: Update `R/replacement.R`**

At line 312:

```r
# old:
cats_upper <- toupper(config$categories)
needs_ab   <- any(c("AVG", "OBP") %in% cats_upper)
needs_ip   <- TRUE
# new:
batting_cats_upper <- toupper(config$batting_categories)
pitcher_cats_upper <- toupper(config$pitcher_categories)
cats_upper         <- c(batting_cats_upper, pitcher_cats_upper)
needs_ab           <- any(c("AVG", "OBP") %in% batting_cats_upper)
needs_ip           <- length(pitcher_cats_upper) > 0L
```

In the band-and-replacement-line computation (per `compute_replacement_stat_line`, lines 740-751), pass the side-scoped categories:

```r
# When computing replacement for a hitter position:
compute_replacement_stat_line(..., scored_cats = batting_cats_upper, ...)
# When computing replacement for a pitcher position:
compute_replacement_stat_line(..., scored_cats = pitcher_cats_upper, ...)
```

- [ ] **Step 4: Update `replacement_from_prices()` (line 1163)**

`replacement_from_prices(categories, ...)` takes a single `categories` argument. Replace with:

```r
replacement_from_prices <- function(
  batting_categories,
  pitcher_categories,
  ...
)
```

Inside, set `categories <- c(batting_categories, pitcher_categories)` for the existing internal flow, then store both fields on the returned object's `config` attr.

- [ ] **Step 5: Run, expecting PASS**

```bash
Rscript -e 'devtools::test(filter = "replacement")'
```

- [ ] **Step 6: Commit**

```bash
git add R/replacement.R tests/testthat/test-replacement.R tests/testthat/test-replacement-from-prices.R
git commit -m "$(cat <<'EOF'
feat(replacement)!: carry batting/pitcher categories through orchestrator

replacement_level() and replacement_from_prices() consume the split
fields explicitly. The two-way duplication path (Ohtani) is unchanged
and continues to seat the player on both pools. Output config attr
preserves both fields.
EOF
)"
```

### Task 6.2: Update `replacement_internal.R` helpers

**Files:**
- Modify: `R/replacement_internal.R`

Most internals are already side-aware via the `is_pitcher` argument that flows through `compute_pool_zscores()` at `R/replacement_internal.R:947-995`. The remaining change is to pass `scored_cats` as side-specific (not the union) so per-side composite z-scores don't reference the wrong cats.

- [ ] **Step 1: Trace call sites**

```bash
Rscript -e 'system("grep -n scored_cats R/replacement_internal.R")'
```

- [ ] **Step 2: Update `compute_par_at_pos()` (line ~1101) signature**

```r
# old:
compute_par_at_pos <- function(..., scored_cats, ...)
# new: same signature; callers must pass the side-scoped list
```

No code change in the helper itself. Change call sites in `R/replacement.R` to pass `batting_cats_upper` for hitter positions and `pitcher_cats_upper` for pitcher positions.

- [ ] **Step 3: Run replacement-internal tests**

```bash
Rscript -e 'devtools::test(filter = "replacement-internal|replacement$|replacement-integration")'
```

- [ ] **Step 4: Commit**

```bash
git add R/replacement_internal.R
git commit -m "refactor(replacement-internal): pass per-side scored_cats from caller"
```

---

## Phase 7 — SGP

`sgp()` is already mostly side-aware via the `pool_type` field on each rate-stat formula entry (see `R/sgp.R:415-445` and the `RATE_STAT_FORMULAS` registry). The change here is to consume the split `config` fields when building the projection-pool baselines, and to optionally accept either a single `scoring_categories` arg (existing API for callers who don't have a `config`) or two side-keyed args.

### Task 7.1: `sgp()` consumes split config fields

**Files:**
- Modify: `R/sgp.R`

- [ ] **Step 1: Write failing test**

```r
# tests/testthat/test-sgp.R — add at the bottom
test_that("sgp() output keys sgp_<cat> by uppercase, scoping each cat to its side", {
  proj <- make_projections_data(seed = 19L)
  # Use a denominators object built from the same split config:
  cfg <- league_config(
    n_teams            = 12L,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 3L, RP = 3L),
    batting_categories = c("HR", "R", "AVG"),
    pitcher_categories = c("K", "ERA")
  )
  denoms <- sgp_denominators(
    league_history = make_league_history_fixture(),
    config         = cfg
  )
  out <- sgp(proj, denoms, config = cfg)

  pitcher_rows <- subset(out, player_type == "pitcher")
  batter_rows  <- subset(out, player_type == "batter")

  expect_true(all(is.na(pitcher_rows$sgp_hr)))
  expect_true(all(is.na(pitcher_rows$sgp_avg)))
  expect_true(all(is.na(batter_rows$sgp_k)))
  expect_true(all(is.na(batter_rows$sgp_era)))
})
```

- [ ] **Step 2: Run, expecting FAIL**

- [ ] **Step 3: Update `R/sgp.R`**

In the per-category loop (around `R/sgp.R:415-445`), gate the assignment by side using the `pool_type` already on each formula entry:

```r
for (cat in scored_cats) {
  formula <- merged_formulas[[toupper(cat)]]
  pool_type <- if (!is.null(formula)) formula$pool_type else .classify_category_side(cat)
  is_target_side <- if (pool_type == "pitcher") {
    out$player_type %in% c("pitcher", "two_way")
  } else {
    out$player_type %in% c("batter", "two_way")
  }
  # compute sgp_<cat> for is_target_side rows; fill !is_target_side with NA
  out[[paste0("sgp_", tolower(cat))]] <- ifelse(
    is_target_side,
    computed_values,
    NA_real_
  )
}
```

For non-rate (counting) categories, `pool_type` is not present in the registry — fall through to `.classify_category_side(cat)`.

- [ ] **Step 4: Run, expecting PASS**

- [ ] **Step 5: Commit**

```bash
git add R/sgp.R tests/testthat/test-sgp.R
git commit -m "fix(sgp): NA cross-side sgp_<cat> cells using formula$pool_type"
```

### Task 7.2: `sgp_denominators()` accepts split fields when given a config

**Files:**
- Modify: `R/sgp-denominators.R`

`sgp_denominators()` already takes `scoring_categories` independently (line ~302). When called with an explicit `config` argument, it should derive `scoring_categories` as the union of `config$batting_categories` and `config$pitcher_categories`. Test that this works.

- [ ] **Step 1: Write failing test**

```r
# tests/testthat/test-sgp-denominators.R
test_that("sgp_denominators() derives scoring_categories from split config fields", {
  cfg <- league_config(
    n_teams            = 12L,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 3L, RP = 3L),
    batting_categories = c("HR", "R"),
    pitcher_categories = c("K", "ERA")
  )
  denoms <- sgp_denominators(
    league_history = make_league_history_fixture(),
    config         = cfg
  )
  expect_setequal(names(denoms), c("HR", "R", "K", "ERA"))
})
```

- [ ] **Step 2: Run, expecting FAIL**

- [ ] **Step 3: Inside `sgp_denominators()`, where it currently consults `config$categories`, redirect to the union**

Find the binding (likely near the top of `sgp_denominators` where `scoring_categories` is resolved from `config`) and replace with:

```r
if (is.null(scoring_categories) && !is.null(config)) {
  scoring_categories <- c(config$batting_categories, config$pitcher_categories)
}
```

The three-layer `inverse_categories` resolution at lines 460-507 is unchanged — `inverse_categories` is already a separate flat list.

- [ ] **Step 4: Run, expecting PASS**

- [ ] **Step 5: Commit**

```bash
git add R/sgp-denominators.R tests/testthat/test-sgp-denominators.R
git commit -m "feat(sgp-denominators): derive scoring_categories from split config fields"
```

---

## Phase 8 — `get_projections()` integration

### Task 8.1: Side classification for `source = "custom"` data lacking `player_type`

**Files:**
- Modify: `R/get-projections-internal.R`

Today, `.combine_batter_pitcher()` (lines 300-309) is the source of the column collision. Step 4 of `.attach_player_type()` (lines 293-297) attaches a clean `player_type` column on the FanGraphs-fetched paths. For `source = "custom"`, the user might not include `player_type`. We need a helper that infers it.

- [ ] **Step 1: Write failing test**

```r
# tests/testthat/test-get-projections.R
test_that("custom source without player_type column is auto-classified", {
  custom_df <- data.frame(
    name            = c("Hitter Bob", "Pitcher Sue"),
    pos_eligibility = c("OF", "SP"),
    HR  = c(25L, NA),
    R   = c(80L, NA),
    K   = c(NA,  220L),
    ERA = c(NA,  3.20),
    stringsAsFactors = FALSE
  )
  out <- get_projections(source = "custom", data = custom_df)
  expect_setequal(out$player_type, c("batter", "pitcher"))
})

test_that("custom source with player_type column is honored", {
  custom_df <- data.frame(
    name        = "Two-Way",
    player_type = "two_way",
    HR          = 30L,
    K           = 200L,
    stringsAsFactors = FALSE
  )
  out <- get_projections(source = "custom", data = custom_df)
  expect_equal(out$player_type, "two_way")
})
```

- [ ] **Step 2: Run, expecting FAIL**

- [ ] **Step 3: Add `.classify_custom_player_type()` to `R/get-projections-internal.R`**

```r
#' @noRd
.classify_custom_player_type <- function(df) {
  # Honor an explicit player_type column.
  if ("player_type" %in% names(df)) return(df)

  # Infer from pos_eligibility regex (same regex used in replacement_internal).
  if ("pos_eligibility" %in% names(df)) {
    is_pit <- grepl(PITCHER_ELIG_REGEX, df$pos_eligibility)
    df$player_type <- ifelse(is_pit, "pitcher", "batter")
    return(df)
  }

  # Last resort: presence of pitching-only columns implies pitcher; otherwise batter.
  pitcher_cols <- intersect(c("ip", "era", "whip", "k_per_9"), tolower(names(df)))
  if (length(pitcher_cols) > 0L) {
    has_ip <- if ("ip" %in% tolower(names(df))) {
      df[[grep("^ip$", names(df), ignore.case = TRUE, value = TRUE)[1L]]]
    } else NULL
    if (!is.null(has_ip)) {
      df$player_type <- ifelse(!is.na(has_ip) & has_ip > 0, "pitcher", "batter")
      return(df)
    }
  }

  cli::cli_abort(
    c(
      "Cannot infer {.field player_type} for custom projections.",
      i = "Add a {.field player_type} column with values {.val batter}, \\
           {.val pitcher}, or {.val two_way}, or include {.field pos_eligibility} \\
           or {.field IP}."
    ),
    class = "rotostats_error_missing_player_type"
  )
}
```

- [ ] **Step 4: Wire it into the custom-source path in `R/get-projections.R`**

Locate the call site in `R/get-projections.R` where `.validate_custom_data(source, data)` returns the validated data frame (the only call site for that function). Immediately after that line, insert:

```r
data <- .classify_custom_player_type(data)
```

The classifier is a no-op when `player_type` is already present, so this is safe in all custom-source paths. FanGraphs-fetched paths bypass `.validate_custom_data()` and call `.attach_player_type()` directly, so they're unaffected.

- [ ] **Step 5: Run, expecting PASS**

- [ ] **Step 6: Commit**

```bash
git add R/get-projections-internal.R R/get-projections.R tests/testthat/test-get-projections.R
git commit -m "feat(get-projections): auto-classify custom data without player_type"
```

---

## Phase 9 — Documentation

### Task 9.1: NEWS.md entry

**Files:**
- Modify: `NEWS.md`

- [ ] **Step 1: Add a `## Breaking changes` section at the top of the development version block**

```markdown
## Breaking changes

* `league_config()`: the singular `categories` argument is replaced by two
  required arguments, `batting_categories` and `pitcher_categories`. Calls
  using the old single-argument form will fail with
  `rotostats_error_invalid_categories`. The convenience field
  `config$categories` is preserved as the derived union of both sides.

* `zaa()`, `zar()`, `par()`, `pvm()`: cross-side category cells in the
  output frame are now `NA` instead of `0` or a contaminated value. For
  example, a pitcher row's `zar_hr`, `zar_r`, `zar_sb` are `NA`; a hitter
  row's `zar_k`, `zar_era` are `NA`. The `total_zar` / `total_par` /
  `total_pvm` columns continue to use `na.rm = TRUE` so each side's
  intra-side total is unchanged.

* `attr(zaa_out, "distribution")` is now keyed by side first:
  `attr(zaa_out, "distribution")$batter[[cat]][[pos]]` and similarly for
  `$pitcher`.

* `replacement_from_prices()`: argument `categories` is replaced by
  `batting_categories` + `pitcher_categories`.

* The verbose `rotostats_warning_zero_playing_time` warning, which
  previously fired once per offending player, now emits at most one
  summary per (side, category) and lists a sample of affected IDs.

## Bug fixes

* `zar()` / `zaa()`: fix cross-side z-score contamination caused by the
  FanGraphs pitcher endpoint returning columns named `hr` / `r` / `avg`
  (HR allowed, R allowed, opponent BAA) that used to collide with hitter
  columns of the same name during `.combine_batter_pitcher()`. After
  this change, hitter z-scores are computed against the hitter pool
  only, and pitcher z-scores against the pitcher pool only.
```

- [ ] **Step 2: Commit**

```bash
git add NEWS.md
git commit -m "docs(news): document breaking change to split categories by side"
```

### Task 9.2: error-messages.md additions

**Files:**
- Modify: `plans/error-messages.md`

- [ ] **Step 1: Add new warning class entry to the Warnings table**

Insert (alphabetical-ish — after `rotostats_warning_unknown_category`):

```markdown
| `rotostats_warning_category_side_mismatch` | `league_config()` | A category appears in `batting_categories` whose canonical side is pitcher (or vice versa) | If intentional, ignore; if a typo, move the category to the correct side argument |
```

- [ ] **Step 2: Update the `rotostats_error_invalid_categories` row**

Existing entry: `categories not a non-empty character vector`. Update the "Thrown by" column to: `league_config()` (covers both `batting_categories` and `pitcher_categories`); the recovery guidance becomes: "Pass at least one scored category name on each side."

- [ ] **Step 3: Update the `rotostats_warning_zero_playing_time` row**

Existing entry says "names affected players". Add to "Thrown by" the note: "now emitted at most once per (side, category) with a sample of IDs".

- [ ] **Step 4: Add `rotostats_error_missing_player_type` if not present** (it already exists for `calibrate_budget_split()` — extend its "Thrown by" with `, .classify_custom_player_type() (via get_projections() with source = "custom")`).

- [ ] **Step 5: Commit**

```bash
git add plans/error-messages.md
git commit -m "docs(error-messages): register category_side_mismatch and update related rows"
```

### Task 9.3: Roxygen examples in consumer functions

**Files:**
- Modify: `R/zaa.R`, `R/zar.R`, `R/par.R`, `R/pvm.R`, `R/replacement.R`, `R/sgp.R`, `R/sgp-denominators.R`

Every `@examples` block that constructs a `league_config(... categories = ...)` must be migrated.

- [ ] **Step 1: Find all roxygen examples**

```bash
Rscript -e 'system("grep -rn -- \"categories *=\" R/ | grep -v -- \"_categories\" | grep -v inverse_categories | grep -v rate_stat")'
```

- [ ] **Step 2: For each `categories = c(...)` in `@examples`, split by side**

Apply the same partition used in fixture migration (Phase 3).

- [ ] **Step 3: Regenerate Rd files**

```bash
Rscript -e 'devtools::document()'
```

- [ ] **Step 4: Commit**

```bash
git add R/ man/
git commit -m "docs(roxygen): migrate all @examples to split categories"
```

---

## Phase 10 — Regression closure & final check

### Task 10.1: Re-enable the regression test from Task 0.2

**Files:**
- Modify: `tests/testthat/test-zar-cross-side-regression.R`

- [ ] **Step 1: Remove the `skip(...)` line**

Find:
```r
skip("Re-enabled in Task 10.1 once split-by-side architecture lands.")
```

Delete that line.

- [ ] **Step 2: Run the regression test, expecting PASS**

```bash
Rscript -e 'devtools::test(filter = "zar-cross-side-regression")'
```
Expected: PASS — pitcher rows have NA for batting cats, hitter rows have NA for pitcher cats, and `total_zar` is finite on both sides.

- [ ] **Step 3: Commit**

```bash
git add tests/testthat/test-zar-cross-side-regression.R
git commit -m "test(zar): re-enable cross-side contamination regression — now passes"
```

### Task 10.2: Run the full test suite

- [ ] **Step 1: Document and test**

```bash
Rscript -e 'devtools::document(); devtools::test()'
```
Expected: all tests pass. If anything is red, return to the relevant phase and fix.

- [ ] **Step 2: Run R CMD check**

```bash
Rscript -e 'devtools::check()'
```
Expected: 0 errors, 0 warnings, 0 notes (or only known-acceptable notes).

### Task 10.3: Open the PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin fix/zar-split-categories-by-side
```

- [ ] **Step 2: Open the PR against `develop`**

```bash
gh pr create --base develop --title "fix(zar)!: split categories by side end-to-end" --body "$(cat <<'EOF'
## Summary

- Splits `config$categories` into `config$batting_categories` + `config$pitcher_categories` end-to-end.
- Fixes cross-side z-score contamination in `zar()` / `zaa()` / `par()` / `pvm()`.
- Eliminates the verbose per-player `rotostats_warning_zero_playing_time` warning by collapsing to one summary per (side, category).

Breaking change. Pre-1.0; no migration shim.

Root cause: the FanGraphs pitcher endpoint returns columns named `hr` / `r` / `avg` (meaning HR allowed, R allowed, opponent BAA) which used to collide with hitter columns of the same name when `.combine_batter_pitcher()` did a `union(names(bat), names(pit))`. Downstream, every category was iterated against every player, so pitchers got a non-NA `zar_hr` derived from their HRA value and hitters got a non-NA `zar_era` derived from a 0-IP rate.

## Test plan

- [x] New regression test `test-zar-cross-side-regression.R` passes.
- [x] All existing tests pass under the new split-categories architecture.
- [x] `devtools::check()` clean.
- [ ] Smoke test the user's original failing pipeline:
      `get_projections("thebatx") |> mutate(player_id = player_name) |> replacement_level(cfg) |> zar()`
      and confirm pitcher rows have NA `zar_hr` / `zar_r` / `zar_sb`, hitters have NA `zar_k` / `zar_era`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review checklist (run after the plan is fully drafted)

1. **Spec coverage:** every file enumerated in the "Files modified" list has at least one task that touches it. ✅
2. **Type consistency:** `batting_categories` / `pitcher_categories` are used uniformly; no instances of `hitting_categories` or other variants. ✅
3. **No placeholders:** every step has either explicit code or an exact bash/git command; no "TBD" / "implement later". ✅
4. **TDD discipline:** every behavioral change has a failing-test step before the implementation step. ✅
5. **Two-way preservation:** Task 6.1 explicitly tests Ohtani-style duplication. ✅
6. **Distribution-attribute schema change:** Task 4.2 Step 7 documents the new nested shape. ✅
7. **Cross-cutting `total_zar` / `total_par` correctness:** noted in Task 5.1 / 5.2 that the existing `na.rm = TRUE` is sufficient. ✅
8. **No silent migration shim:** confirmed in the architecture summary and Phase 2 commits. ✅

---

## Out of scope (intentionally deferred)

- **Vignette updates.** No vignettes exist yet (`ls vignettes/` returns nothing). When the first vignette lands, its examples will be authored against the new API.
- **`league_history()` / `cal_spec()` integration with split categories.** These accept categories indirectly through `team_season` column matching; their interface does not need a code change for this fix. A future plan can split them when calibration begins to differ across sides.
- **Migration helper for users on the old `categories` arg.** Pre-1.0; intentionally fail loud.
