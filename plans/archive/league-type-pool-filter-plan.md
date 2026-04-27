# League-Type Pool Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `config$league_type` actually filter the player pool inside `replacement_level()` so that an AL-only league configuration excludes NL players (and vice versa), matching the contract documented in `R/league-config.R` and `plans/implementation/league-config-impl.md`.

**Architecture:** Filter `projections` at the top of `replacement_level()`, after the existing `LEAGUE` column validation but before `stored_projections` is captured. Filtering at this point means every downstream consumer (`zaa()`, `zar()`, `par()`, `pvm()`) sees only the matching-league players via `attr(replacement, "projections")` — no other call sites need to change. `league_type = "mixed"` keeps the current behavior (no filter). `league_type = "AL"` / `"NL"` drops rows where `projections$LEAGUE != config$league_type`. An empty filtered pool aborts with a new classed error.

**Tech Stack:** R, testthat, checkmate, cli.

---

## Files

- **Modify:** `R/replacement.R` — add the filter block + docstring update.
- **Modify:** `R/league-config.R` — sharpen the `league_type` doc to name the filtering function.
- **Modify:** `plans/error-messages.md` — register the new `rotostats_error_empty_league_pool` class.
- **Modify:** `NEWS.md` — note the breaking behavior change.
- **Create:** `tests/testthat/test-replacement-league-filter.R` — regression test covering AL / NL / mixed filtering.

---

## Task 1: Failing regression test for league-type filtering

**Files:**
- Create: `tests/testthat/test-replacement-league-filter.R`

The fixture generator `make_projections_data()` already assigns `league = "AL"` to teams in `c("NYY","BOS","HOU","MIN","SEA")` and `league = "NL"` to the rest, giving us a mixed pool to filter. The test verifies the contract at the `replacement_level()` boundary (using its `attr(., "projections")` snapshot) and at the `zar()` output (since the user's bug report was that NL players appear in `zar()`).

- [ ] **Step 1: Write the failing test file**

```r
# tests/testthat/test-replacement-league-filter.R
#
# Regression tests for league_type pool filtering inside replacement_level().
# Per league_config()'s documented contract, league_type = "AL" / "NL" must
# restrict the player pool to that league; "mixed" keeps both.

base_config <- function(league_type) {
  league_config(
    n_teams            = 2L,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 1L, RP = 1L),
    batting_categories = c("HR", "R", "SB"),
    pitcher_categories = c("K", "SV"),
    league_type        = league_type
  )
}

test_that("league_type = 'AL' drops NL players from the replacement pool", {
  proj <- make_projections_data(seed = 99L)
  expect_true(any(proj$league == "AL"))
  expect_true(any(proj$league == "NL"))

  repl <- replacement_level(proj, base_config("AL"))
  stored <- attr(repl, "projections")

  expect_true(all(stored$LEAGUE == "AL"))
  expect_equal(nrow(stored), sum(proj$league == "AL"))
})

test_that("league_type = 'NL' drops AL players from the replacement pool", {
  proj <- make_projections_data(seed = 99L)

  repl <- replacement_level(proj, base_config("NL"))
  stored <- attr(repl, "projections")

  expect_true(all(stored$LEAGUE == "NL"))
  expect_equal(nrow(stored), sum(proj$league == "NL"))
})

test_that("league_type = 'mixed' keeps both leagues (no filter)", {
  proj <- make_projections_data(seed = 99L)

  repl <- replacement_level(proj, base_config("mixed"))
  stored <- attr(repl, "projections")

  expect_equal(nrow(stored), nrow(proj))
  expect_setequal(unique(stored$LEAGUE), c("AL", "NL"))
})

test_that("zar() output contains no NL players when league_type = 'AL'", {
  proj <- make_projections_data(seed = 99L)
  repl <- replacement_level(proj, base_config("AL"))
  out  <- zar(repl)

  nl_ids <- proj$player_id[proj$league == "NL"]
  expect_true(!any(out$player_id %in% nl_ids))
})

test_that("empty filtered pool aborts with rotostats_error_empty_league_pool", {
  proj <- make_projections_data(seed = 99L)
  proj$league <- "AL"  # remove all NL rows by relabeling

  expect_error(
    replacement_level(proj, base_config("NL")),
    class = "rotostats_error_empty_league_pool"
  )
})
```

- [ ] **Step 2: Run the new test file to verify it fails**

Run: `Rscript -e 'devtools::test(filter = "replacement-league-filter")'`

Expected: the first four tests fail (the filter is not implemented yet, so the AL run still contains NL players and `nrow(stored) != sum(proj$league == "AL")`); the fifth test fails because `rotostats_error_empty_league_pool` does not yet exist (the existing `rotostats_error_pool_too_small` may fire instead, or a different generic error). All five failures are expected at this point.

- [ ] **Step 3: Commit the failing test**

```bash
git checkout -b fix/league-type-pool-filter
git add tests/testthat/test-replacement-league-filter.R
git commit -m "test(replacement): add failing regression for league_type pool filter"
```

---

## Task 2: Implement the filter in `replacement_level()`

**Files:**
- Modify: `R/replacement.R` — insert filter block between line 359 (existing `assert_subset(projections$LEAGUE, c("AL", "NL"))`) and the rate-stat denominator lookup at line 361.

- [ ] **Step 1: Insert the filter block**

Open `R/replacement.R` and locate this region (currently around lines 358–360):

```r
  # Step 31: league values
  checkmate::assert_subset(projections$LEAGUE, c("AL", "NL"))

  # Step 32: Rate stat denominator lookup
```

Replace it with:

```r
  # Step 31: league values
  checkmate::assert_subset(projections$LEAGUE, c("AL", "NL"))

  # Step 31b: league_type pool filter
  # When config$league_type is "AL" or "NL", restrict the pool to that league.
  # "mixed" keeps both leagues. Filtering here means stored_projections (and
  # therefore attr(result, "projections")) carry the filtered set, so all
  # downstream consumers (zaa, zar, par, pvm) see only the matching league.
  if (config$league_type %in% c("AL", "NL")) {
    keep <- projections$LEAGUE == config$league_type
    if (!any(keep)) {
      cli::cli_abort(
        c(
          "No rows in {.arg projections} have {.code LEAGUE == {.val {config$league_type}}}.",
          "i" = "Check the projection source's league coverage, or set {.code league_type = \"mixed\"} in {.fn league_config}."
        ),
        class = "rotostats_error_empty_league_pool",
        call = call_env
      )
    }
    if (verbose) {
      n_dropped <- sum(!keep)
      if (n_dropped > 0L) {
        cli::cli_inform(
          "Filtered {.arg projections}: dropped {n_dropped} row{?s} not in league {.val {config$league_type}}."
        )
      }
    }
    projections <- projections[keep, , drop = FALSE]
  }

  # Step 32: Rate stat denominator lookup
```

- [ ] **Step 2: Run the regression tests to verify they pass**

Run: `Rscript -e 'devtools::test(filter = "replacement-league-filter")'`

Expected: all five tests in `test-replacement-league-filter.R` PASS.

- [ ] **Step 3: Run the full test suite**

Run: `Rscript -e 'devtools::test()'`

Expected: every test passes. The existing fixtures use `league_type = "mixed"` (see `helper-zar-fixtures.R:30, 66`), so they exercise the no-filter branch and should be unaffected. Any test that fails likely depended on cross-league projections leaking through under a non-mixed config — investigate before "fixing" the test.

- [ ] **Step 4: Commit the implementation**

```bash
git add R/replacement.R
git commit -m "fix(replacement)!: filter projections by config\$league_type

When league_type is \"AL\" or \"NL\", drop rows where projections\$LEAGUE
does not match. Previously the field was stored on the config but never
consulted, so AL-only and NL-only configurations silently received the
full mixed-league pool. Empty filtered pools now abort with the new
rotostats_error_empty_league_pool class."
```

---

## Task 3: Update the `league_type` parameter docstring

**Files:**
- Modify: `R/league-config.R:69-71`

The current docstring already promises filtering ("Controls DH eligibility and downstream player-pool filtering") — but it does not name the function that performs the filter. Now that the contract is real, point readers at it.

- [ ] **Step 1: Update the roxygen comment**

Open `R/league-config.R` and locate (lines 69–71):

```r
#' @param league_type One of `"mixed"`, `"AL"`, `"NL"`. Controls DH eligibility
#'   and downstream player-pool filtering. `"NL"` drops DH from `roster_slots`
#'   with a warning if present.
```

Replace with:

```r
#' @param league_type One of `"mixed"`, `"AL"`, `"NL"`. Default `"mixed"`.
#'   Controls DH eligibility and downstream player-pool filtering: `"AL"` /
#'   `"NL"` cause [replacement_level()] to drop rows where
#'   `projections$LEAGUE` does not match before computing the replacement
#'   pool. `"NL"` additionally drops `DH` from `roster_slots` with a warning
#'   if present. `"mixed"` keeps both leagues.
```

- [ ] **Step 2: Regenerate documentation**

Run: `Rscript -e 'devtools::document()'`

Expected: `man/league_config.Rd` is updated with the new param description and no other unintended diffs. If `R CMD check` complains about stale docs elsewhere, address those separately — they are not part of this change.

- [ ] **Step 3: Commit the docstring change**

```bash
git add R/league-config.R man/league_config.Rd
git commit -m "docs(league-config): clarify league_type filtering contract"
```

---

## Task 4: Register the new error class in `plans/error-messages.md`

**Files:**
- Modify: `plans/error-messages.md` — add a row next to the existing `replacement_level()` error rows (the rate-method / pool-too-small block, currently lines 57–72).

- [ ] **Step 1: Add the row**

Open `plans/error-messages.md`. Find the `rotostats_error_pool_too_small` row (currently around line 63) — that is the closest sibling. Add a new row immediately below it:

```markdown
| `rotostats_error_empty_league_pool` | `replacement_level()` (step-31b filter) | `config$league_type` is `"AL"` or `"NL"` and no rows in `projections` carry that `LEAGUE` value | Check the projection source's league coverage, or set `league_type = "mixed"` |
```

- [ ] **Step 2: Verify formatting**

Run: `Rscript -e 'cat(readLines("plans/error-messages.md")[1:80], sep = "\n")'`

Expected: the new row sits in the table without breaking column alignment; no other rows changed.

- [ ] **Step 3: Commit the registry update**

```bash
git add plans/error-messages.md
git commit -m "docs(error-messages): register rotostats_error_empty_league_pool"
```

---

## Task 5: Add a NEWS entry

**Files:**
- Modify: `NEWS.md` — add a new top-of-file bullet.

This is a behavior change that affects any caller using `league_type = "AL"` or `"NL"`: their replacement levels and z-scores will move because NL (resp. AL) players are no longer in the pool. Surface it loudly.

- [ ] **Step 1: Read the current NEWS header so the new entry matches the existing style**

Run: `Rscript -e 'cat(readLines("NEWS.md")[1:25], sep = "\n")'`

Expected: shows the development-version header and recent entries (style, level, voice).

- [ ] **Step 2: Add the entry**

Insert a new bullet under the in-development version's header in `NEWS.md`. Match the tone of nearby entries — terse, breaking-change-flagged where applicable. For example (adapt to actual neighboring style):

```markdown
- **Breaking:** `league_config(league_type = "AL")` and `league_type = "NL"`
  now actually filter the player pool inside `replacement_level()`. Previously
  the setting only affected DH-slot dropping; the projections were used in
  full regardless. Downstream `zaa()` / `zar()` / `par()` / `pvm()` results
  shift accordingly. Use `league_type = "mixed"` to keep the prior behavior.
  An empty filtered pool aborts with `rotostats_error_empty_league_pool`.
```

- [ ] **Step 3: Commit the NEWS entry**

```bash
git add NEWS.md
git commit -m "docs(news): document breaking league_type pool filter"
```

---

## Task 6: Final package check and PR

**Files:**
- None modified in this task.

- [ ] **Step 1: Run `devtools::check()`**

Run: `Rscript -e 'devtools::check()'`

Expected: zero errors, zero warnings, zero notes attributable to this change. (Pre-existing notes in `develop` are out of scope; document them as-is in the PR description if any persist.)

- [ ] **Step 2: Push the branch and open a PR against `develop`**

```bash
git push -u origin fix/league-type-pool-filter
gh pr create --base develop --title "fix(replacement)!: filter projections by config\$league_type" --body "$(cat <<'EOF'
## Summary
- `replacement_level()` now drops rows where `projections$LEAGUE` does not match `config$league_type` when `league_type` is `"AL"` or `"NL"`. Previously the field was stored on the config but never consulted, so AL-only and NL-only league setups silently received the full mixed-league pool — Ohtani showed up in AL z-scores, etc.
- `league_type = "mixed"` is unchanged.
- Empty filtered pool aborts with new `rotostats_error_empty_league_pool`.
- New regression test `tests/testthat/test-replacement-league-filter.R` covers AL / NL / mixed and the empty-pool error.
- `R/league-config.R` docstring sharpened to name the filtering function; `plans/error-messages.md` registers the new class; `NEWS.md` flags the breaking change.

## Breaking change
Any caller using `league_type = "AL"` or `"NL"` will see replacement levels and z-scores move because the off-league players are no longer in the pool. Use `league_type = "mixed"` to keep prior behavior.

## Test plan
- [x] `devtools::test(filter = "replacement-league-filter")` — all five new tests pass
- [x] `devtools::test()` — full suite green
- [x] `devtools::check()` — clean

## Out of scope (follow-up candidates)
- `replacement_from_prices()` does not take a `config` and has no `league_type` parameter today; matching league filtering there would be a separate API change.
- `get_projections()` could optionally pre-filter by `config$league_type`, but tighter coupling between the fetcher and config is a design decision worth its own discussion.
EOF
)"
```

Expected: PR opens against `develop` (per `CLAUDE.md` branching model). Verify the PR URL is returned.

---

## Self-Review Checklist

- [x] **Spec coverage:** the user's bug report ("Ohtani still appears under `league_type = \"AL\"`") is covered by Task 1's fourth test (zar output excludes NL `player_id`s). The documented contract in `plans/implementation/league-config-impl.md:83` is implemented in Task 2.
- [x] **No placeholders:** every code block contains the actual code/command/expected output. No "TBD" / "add appropriate handling" anywhere.
- [x] **Type consistency:** the new error class name `rotostats_error_empty_league_pool` is used identically in `R/replacement.R` (Task 2), `plans/error-messages.md` (Task 4), the regression test (Task 1), and the PR body (Task 6).
- [x] **Branching model:** branch is cut from `develop`, PR targets `develop`, per `CLAUDE.md`.
- [x] **Conventional Commits:** every commit uses a scoped Conventional Commits header; the breaking implementation commit carries the `!` flag.
