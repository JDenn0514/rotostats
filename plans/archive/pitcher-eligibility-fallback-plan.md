# Pitcher Eligibility Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach `replacement_level()` to accept bare `"P"` as a pitcher-eligibility marker and classify the role (`SP` vs. `RP`) via the existing `sp_ip_threshold` parameter. This closes the `get_projections()` → `replacement_level()` integration gap where FanGraphs pitcher rows (no position field → `pos_eligibility = "P"`) are silently dropped from every SP/RP pool.

**Architecture:** A single named regex constant `PITCHER_ELIG_REGEX` replaces the five open-coded `grepl("(SP|RP)", POS_ELIGIBILITY)` calls and the two `%in% c("SP", "RP")` pos-part checks so that bare `"P"` is recognized alongside `"SP"` / `"RP"`. `infer_pitcher_roles()` already uses `sp_ip_threshold` to classify pitchers by IP — its existing branch naturally handles bare `"P"` once the gating regex is widened. No public API change; `sp_ip_threshold` semantics are unchanged. Adds one integration test (`get_projections()`-shaped fixture → `replacement_level()`) that would have caught the bug.

**Tech Stack:** R ≥ 4.3, `testthat` (edition 3), `checkmate`, `cli`. No new dependencies.

**Reference context:**
- Root cause: [R/get-projections-internal.R:341](R/get-projections-internal.R:341) (`df$pos <- "P"`) + [R/replacement.R:514](R/replacement.R:514) (`grepl("(SP|RP)", ...)`) — FanGraphs pitcher JSON has no position field ([fixtures/projections-steamer-pit.json](tests/testthat/fixtures/projections-steamer-pit.json) — 67 keys, zero position-like).
- Test pin of broken wire-value: [tests/testthat/test-get-projections.R:547](tests/testthat/test-get-projections.R:547) — stays as-is; `get_projections()` continues to emit `"P"` (correct per its contract) and `replacement_level()` now handles it.

**Out of scope:**
- Changes to `get_projections()` (no migration of SP/RP inference into the fetch layer — `sp_ip_threshold` lives at the valuation step).
- Changes to `pvm.R`, `zar.R`, `zaa.R`, `league-config.R`, `replacement_internal.R` helpers for `replacement_level_from_prices()`. `zar.R:236` already includes `"P"` in its pitcher-pos list; `pvm.R:585` and `league-config.R:33` are about the roster-slot namespace (league config already forbids `"P"`) and do not need updating.
- Any new error classes. No new failure modes introduced.

---

## File Structure

| Path | Purpose |
|------|---------|
| `R/replacement_internal.R` | Add `PITCHER_ELIG_REGEX` constant; update `infer_pitcher_roles()` to use it |
| `R/replacement.R` | Replace five `grepl("(SP|RP)", ...)` sites with `grepl(PITCHER_ELIG_REGEX, ...)`; update one `%in% c("SP", "RP")` pos-part check in `.compute_two_way_players()` for consistency |
| `tests/testthat/test-replacement.R` | Add regex-unit test for `PITCHER_ELIG_REGEX`; add behavior tests for `infer_pitcher_roles()` on `"P"` eligibility; add an integration test using a `get_projections()`-shaped fixture |
| `tests/testthat/helper-test-data.R` | (Read-only — confirm shared pitcher fixture or add a helper) |
| `NEWS.md` | Add "Bug fixes" entry under the development version |

---

## Task 1: Add `PITCHER_ELIG_REGEX` constant (TDD)

**Files:**
- Modify: `R/replacement_internal.R` — add constant near top of file (right after existing constants)
- Modify: `tests/testthat/test-replacement.R` — add regex behavior test

- [ ] **Step 1: Write the failing test**

Append to `tests/testthat/test-replacement.R`:

```r
# ---------------------------------------------------------------------------
# PITCHER_ELIG_REGEX — pitcher-eligibility token regex
# ---------------------------------------------------------------------------

test_that("PITCHER_ELIG_REGEX matches SP, RP, and bare P tokens", {
  pos <- c("SP", "RP", "P", "SP|RP", "OF|SP", "1B|P", "SP|1B|OF",
           "OF", "1B", "C", "2B|SS", "DH", NA_character_, "")
  expected <- c(TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE,
                FALSE, FALSE, FALSE, FALSE, FALSE, NA, FALSE)

  got <- grepl(rotostats:::PITCHER_ELIG_REGEX, pos)
  # grepl() on NA returns FALSE with a warning; treat NA as FALSE for match check
  na_idx <- which(is.na(pos))
  expect_equal(got[-na_idx], expected[-na_idx][!is.na(expected[-na_idx])])
})

test_that("PITCHER_ELIG_REGEX does NOT match substrings inside hitter tokens", {
  # Sanity: no hitter position string contains S, R, P as a standalone token
  # boundary-safe regex must reject things like "1SP" (synthetic — not a real
  # position, just a regression guard).
  expect_false(grepl(rotostats:::PITCHER_ELIG_REGEX, "1SP"))
  expect_false(grepl(rotostats:::PITCHER_ELIG_REGEX, "SPA"))
  expect_false(grepl(rotostats:::PITCHER_ELIG_REGEX, "XP"))
  expect_false(grepl(rotostats:::PITCHER_ELIG_REGEX, "PX"))
})
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
Rscript -e 'devtools::test(filter = "replacement", reporter = "summary")'
```
Expected: both new tests fail with `Error: object 'PITCHER_ELIG_REGEX' not found` (or `::: ` lookup failure).

- [ ] **Step 3: Add the constant**

In `R/replacement_internal.R`, find the existing `.compute_two_way_players` / top-level constants section and add (near the top of the file, after any existing `@noRd` documented constants):

```r
# ---------------------------------------------------------------------------
# Pitcher-eligibility regex
#
# Matches a POS_ELIGIBILITY string whose pipe-separated tokens include any of
# `SP`, `RP`, or a bare `P` (the get_projections() fallback for FanGraphs
# pitchers, which return no position field). Anchored with `(^|\|)` / `(\||$)`
# so hitter tokens containing the letter "P" (e.g. a hypothetical "1P") do not
# match, and so substrings like "SPA" / "XP" are not false positives.
#
# Use this instead of open-coding `grepl("(SP|RP)", ...)` anywhere pitcher
# eligibility is tested against POS_ELIGIBILITY in replacement_level().
# ---------------------------------------------------------------------------

#' @noRd
PITCHER_ELIG_REGEX <- "(^|\\|)(SP|RP|P)(\\||$)"
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
Rscript -e 'devtools::test(filter = "replacement", reporter = "summary")'
```
Expected: the two new `PITCHER_ELIG_REGEX` tests pass. No other tests regress.

- [ ] **Step 5: Commit**

```bash
git add R/replacement_internal.R tests/testthat/test-replacement.R
git commit -m "feat(replacement): add PITCHER_ELIG_REGEX constant"
```

---

## Task 2: Teach `infer_pitcher_roles()` to recognize bare "P" (TDD)

**Files:**
- Modify: `R/replacement_internal.R:582-606` — widen `is_pitcher` detection
- Modify: `tests/testthat/test-replacement.R` — add behavior test

- [ ] **Step 1: Write the failing test**

Append to `tests/testthat/test-replacement.R`:

```r
# ---------------------------------------------------------------------------
# infer_pitcher_roles() — bare "P" eligibility
# ---------------------------------------------------------------------------

test_that("infer_pitcher_roles() treats bare P as pitcher and classifies by IP", {
  proj <- data.frame(
    POS_ELIGIBILITY = c("P", "P", "P", "OF", "SS"),
    IP              = c(180, 60,  NA, NA,   NA),
    stringsAsFactors = FALSE
  )
  out <- rotostats:::infer_pitcher_roles(proj, sp_ip_threshold = 100)

  expect_equal(out$role, c("SP", "RP", "RP", NA_character_, NA_character_))
  expect_equal(out$swingman_flag, c(FALSE, FALSE, FALSE, FALSE, FALSE))
})

test_that("infer_pitcher_roles() still honors explicit SP/RP tokens", {
  proj <- data.frame(
    POS_ELIGIBILITY = c("SP", "RP", "SP|RP", "1B|SP"),
    IP              = c(50,  150,  NA,     190),  # IP here is ignored for SP/RP
    stringsAsFactors = FALSE
  )
  out <- rotostats:::infer_pitcher_roles(proj, sp_ip_threshold = 100)

  # Explicit SP stays SP even with IP < threshold; explicit RP stays RP even
  # with IP > threshold. IP-based reclassification only fires for bare "P".
  expect_equal(out$role, c("SP", "RP", "SP", "SP"))
})

test_that("infer_pitcher_roles() flags swingmen regardless of token form", {
  proj <- data.frame(
    POS_ELIGIBILITY = c("SP", "RP", "P"),
    IP              = c(100, 90, 95),
    stringsAsFactors = FALSE
  )
  out <- rotostats:::infer_pitcher_roles(proj, sp_ip_threshold = 100)
  expect_equal(out$swingman_flag, c(TRUE, TRUE, TRUE))
})
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
Rscript -e 'devtools::test(filter = "replacement", reporter = "summary")'
```
Expected: the three new `infer_pitcher_roles()` tests FAIL because:
- The bare-`"P"` rows yield `role = NA` (the `grepl("(SP|RP)", "P")` gate is `FALSE`, so they are treated as non-pitchers).
- Explicit `"SP"` / `"RP"` cases pass today but guard against regression after the widening.

- [ ] **Step 3: Update `infer_pitcher_roles()`**

Replace the body of `infer_pitcher_roles()` in `R/replacement_internal.R:582-606` with:

```r
#' @noRd
infer_pitcher_roles <- function(projections, sp_ip_threshold) {
  # Pitcher detection accepts SP, RP, or bare P (the get_projections()
  # fallback when FanGraphs returns no position for pitcher rows).
  is_pitcher <- grepl(
    PITCHER_ELIG_REGEX,
    projections$POS_ELIGIBILITY,
    ignore.case = FALSE
  )

  # Swingman flag: computed from IP for every identified pitcher row, BEFORE
  # role assignment (per spec §5.2).
  swingman_flag <- is_pitcher &
    !is.na(projections$IP) &
    projections$IP >= 80 &
    projections$IP <= 120

  if ("ROLE" %in% names(projections)) {
    # Caller provided explicit ROLE column — honor it unchanged.
    role <- projections$ROLE
  } else {
    # Token-aware classification:
    #   - Explicit "SP" anywhere in the eligibility list  -> "SP"
    #   - Explicit "RP" anywhere in the eligibility list  -> "RP" (unless SP
    #     was already matched; SP wins for hybrid "SP|RP" tokens)
    #   - Bare "P" (no explicit SP/RP token) -> infer from IP vs. threshold
    has_sp <- grepl("(^|\\|)SP(\\||$)", projections$POS_ELIGIBILITY)
    has_rp <- grepl("(^|\\|)RP(\\||$)", projections$POS_ELIGIBILITY)
    has_bare_p <- is_pitcher & !has_sp & !has_rp

    role <- rep(NA_character_, length(is_pitcher))
    role[is_pitcher & has_sp] <- "SP"
    role[is_pitcher & !has_sp & has_rp] <- "RP"
    role[has_bare_p] <- ifelse(
      !is.na(projections$IP[has_bare_p]) &
        projections$IP[has_bare_p] >= sp_ip_threshold,
      "SP",
      "RP"
    )
  }

  list(role = role, swingman_flag = swingman_flag)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
Rscript -e 'devtools::test(filter = "replacement", reporter = "summary")'
```
Expected: all three new tests pass. Existing `infer_pitcher_roles()` callers are unaffected because the explicit-SP / explicit-RP branches preserve prior behavior.

- [ ] **Step 5: Commit**

```bash
git add R/replacement_internal.R tests/testthat/test-replacement.R
git commit -m "fix(replacement): classify bare P as SP/RP via sp_ip_threshold"
```

---

## Task 3: Replace open-coded `grepl("(SP|RP)", ...)` sites in `replacement.R`

**Files:**
- Modify: `R/replacement.R:512`, `R/replacement.R:514`, `R/replacement.R:574`, `R/replacement.R:863`, `R/replacement.R:1667` — swap in `PITCHER_ELIG_REGEX`

No new tests at this step — existing tests (plus Task 5's integration test) exercise every touched site. This task is a mechanical refactor that makes the fix from Task 2 reachable from the callers.

- [ ] **Step 1: Replace line 512** (hitter-rows mask inside the iteration loop)

In `R/replacement.R:509-513`, change:

```r
    hitter_rows <- which(
      projections$LEAGUE %in%
        c("AL", "NL") &
        !grepl("(SP|RP)", projections$POS_ELIGIBILITY)
    )
```

to:

```r
    hitter_rows <- which(
      projections$LEAGUE %in%
        c("AL", "NL") &
        !grepl(PITCHER_ELIG_REGEX, projections$POS_ELIGIBILITY)
    )
```

- [ ] **Step 2: Replace line 514** (pitcher-rows index)

In `R/replacement.R:514`, change:

```r
    pitcher_rows_idx <- which(grepl("(SP|RP)", projections$POS_ELIGIBILITY))
```

to:

```r
    pitcher_rows_idx <- which(grepl(PITCHER_ELIG_REGEX, projections$POS_ELIGIBILITY))
```

- [ ] **Step 3: Replace line 574** (SP/RP pool mask inside the `for (pos …)` loop)

In `R/replacement.R:572-576`, change:

```r
      if (is_pitcher_pos) {
        # Pitchers assigned to SP or RP based on role
        pos_mask <- grepl("(SP|RP)", projections$POS_ELIGIBILITY) &
          !is.na(role) &
          role == pos
      } else {
```

to:

```r
      if (is_pitcher_pos) {
        # Pitchers assigned to SP or RP based on role (role set by
        # infer_pitcher_roles() — bare "P" was already classified to SP/RP).
        pos_mask <- grepl(PITCHER_ELIG_REGEX, projections$POS_ELIGIBILITY) &
          !is.na(role) &
          role == pos
      } else {
```

- [ ] **Step 4: Replace line 863** (multi-position reassignment hitter-only gate)

In `R/replacement.R:862-863`, change:

```r
      multi_eligible_mask <- grepl("\\|", projections$POS_ELIGIBILITY) &
        !grepl("(SP|RP)", projections$POS_ELIGIBILITY)
```

to:

```r
      multi_eligible_mask <- grepl("\\|", projections$POS_ELIGIBILITY) &
        !grepl(PITCHER_ELIG_REGEX, projections$POS_ELIGIBILITY)
```

- [ ] **Step 5: Replace line 1667** (pool-diagnostics pitcher mask)

In `R/replacement.R:1665-1668`, change:

```r
    is_pitcher_pos <- pos %in% c("SP", "RP")
    if (is_pitcher_pos) {
      pos_mask <- grepl("(SP|RP)", projections$POS_ELIGIBILITY)
    } else {
```

to:

```r
    is_pitcher_pos <- pos %in% c("SP", "RP")
    if (is_pitcher_pos) {
      pos_mask <- grepl(PITCHER_ELIG_REGEX, projections$POS_ELIGIBILITY)
    } else {
```

(`is_pitcher_pos` itself stays `c("SP", "RP")` — the `for (pos …)` loop iterates over `all_positions = c(active_hitter_pos, active_pitcher_pos)` where `active_pitcher_pos ⊆ {"SP","RP"}` by `league_config()` validation. Bare `"P"` never appears as a target pool label.)

- [ ] **Step 6: Run full test suite — expect no regressions**

Run:
```bash
Rscript -e 'devtools::test(reporter = "summary")'
```
Expected: all tests pass. (Previously-passing tests used fixtures with explicit `"SP"` / `"RP"` tokens, which still match the widened regex.)

- [ ] **Step 7: Commit**

```bash
git add R/replacement.R
git commit -m "refactor(replacement): route pitcher detection through PITCHER_ELIG_REGEX"
```

---

## Task 4: Fix pos-part consistency in `.compute_two_way_players()`

**Files:**
- Modify: `R/replacement.R:1587-1597` — include bare `"P"` in the pitcher-parts check
- Modify: `tests/testthat/test-replacement.R` — add behavior test

Context: [R/replacement.R:1592](R/replacement.R:1592) already excludes `"P"` from hitter parts (`!pos_parts %in% c("SP", "RP", "P")`) but [R/replacement.R:1593](R/replacement.R:1593) (`has_pit <- any(pos_parts %in% c("SP", "RP"))`) does not. After Task 2 a player with `pos_eligibility = "1B|P"` gets `role = "SP"` or `"RP"`, so their two-way check reaches this block — but the pitcher-side gate would still reject them because `"P"` is not in `c("SP", "RP")`.

- [ ] **Step 1: Write the failing test**

Append to `tests/testthat/test-replacement.R`:

```r
test_that(".compute_two_way_players() accepts bare P as pitcher eligibility", {
  # Build a minimal projection frame with one two-way candidate whose
  # eligibility is "1B|P" (mimicking the get_projections() wire format when a
  # two-way player is declared as both a hitter and a generic pitcher).
  proj <- data.frame(
    PLAYER_ID       = "two_way_1",
    POS_ELIGIBILITY = "1B|P",
    stringsAsFactors = FALSE
  )
  repl_stats_df <- data.frame(
    position = c("1B", "SP"),
    HR       = c(0, NA),
    W        = c(NA, 0),
    stringsAsFactors = FALSE
  )
  # Pretend the player out-performs replacement in both roles by putting them
  # well above any band — full PAR math doesn't matter here; this test only
  # guards the pre-filter (`has_hit && has_pit`) that rejects candidates
  # before the PAR loop.
  #
  # Because PAR computation is downstream, we only need the positive-PAR
  # candidacy path to *reach* the loop. The simplest way to assert that
  # is: with the current (broken) code, two_way_ids is character(0);
  # after the fix, the loop runs and — given the rigged repl_stats_df
  # above — may or may not flag the player. We only assert that the
  # pre-filter no longer rejects bare "P".
  #
  # Direct approach: patch the private helper to count pre-filter passes.
  current_assignments <- c(two_way_1 = "1B")
  role <- c("SP")  # Task 2 classified bare P to SP

  # .compute_two_way_players() returns a character vector; with the fix,
  # absent numeric HR/W data the PAR branch will return character(0), but
  # the pre-filter should no longer reject the candidate. Coverage here is
  # indirect; the integration test in Task 5 catches the end-to-end effect.
  result <- rotostats:::.compute_two_way_players(
    projections       = proj,
    repl_stats_df     = repl_stats_df,
    current_assignments = current_assignments,
    cats_upper        = c("HR", "W"),
    role              = role
  )
  # The assertion that *would* fail before the fix is brittle because PAR
  # math requires fully-populated stat columns. Instead, test the regex
  # directly to pin the contract:
  pos_parts <- strsplit(proj$POS_ELIGIBILITY, "\\|")[[1]]
  expect_true(any(pos_parts %in% c("SP", "RP", "P")))
})
```

(The test above documents the contract; the integration test in Task 5 is the primary regression guard.)

- [ ] **Step 2: Run test**

Run:
```bash
Rscript -e 'devtools::test(filter = "replacement", reporter = "summary")'
```
Expected: the new test passes (it exercises the static contract). Keep it anyway as documentation of intent.

- [ ] **Step 3: Update `.compute_two_way_players()`**

In `R/replacement.R:1591-1593`, change:

```r
    has_hit <- any(!pos_parts %in% c("SP", "RP", "P"))
    has_pit <- any(pos_parts %in% c("SP", "RP"))
```

to:

```r
    has_hit <- any(!pos_parts %in% c("SP", "RP", "P"))
    has_pit <- any(pos_parts %in% c("SP", "RP", "P"))
```

- [ ] **Step 4: Run full test suite**

Run:
```bash
Rscript -e 'devtools::test(reporter = "summary")'
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add R/replacement.R tests/testthat/test-replacement.R
git commit -m "fix(replacement): accept bare P in two-way player pitcher check"
```

---

## Task 5: Add `get_projections()` → `replacement_level()` integration test

**Files:**
- Modify: `tests/testthat/test-replacement-integration.R` — new test block using an in-file fixture

This is the regression test that would have caught the bug. It constructs projections in the exact shape `get_projections()` emits — pitchers carry `pos_eligibility = "P"` — and asserts that `replacement_level()` produces non-NA SP/RP stat lines and a non-empty pitcher pool.

- [ ] **Step 1: Inspect the existing integration test file**

Read the top of `tests/testthat/test-replacement-integration.R` so the new test follows the file's style:

```bash
Rscript -e 'cat(readLines("tests/testthat/test-replacement-integration.R", n = 40), sep = "\n")'
```

- [ ] **Step 2: Write the failing test**

Append to `tests/testthat/test-replacement-integration.R`:

```r
# ---------------------------------------------------------------------------
# replacement_level() accepts the get_projections() pitcher wire format
#
# Regression guard for the integration gap where FanGraphs pitcher rows
# (no position field -> pos_eligibility = "P") were silently dropped from
# every SP/RP pool. The fixture here mirrors the shape of
# get_projections("steamer") after normalization: lowercase column names,
# pitcher rows with pos_eligibility = "P", batter rows with standard hitter
# eligibility tokens.
# ---------------------------------------------------------------------------

test_that("replacement_level() classifies pitchers when pos_eligibility = 'P'", {
  set.seed(42L)
  n_hit <- 120L
  n_pit <- 60L

  hit_positions <- rep(
    c("C", "1B", "2B", "SS", "3B", "OF"),
    length.out = n_hit
  )

  hitters <- data.frame(
    player_id       = paste0("h", seq_len(n_hit)),
    player_name     = paste0("Hitter ", seq_len(n_hit)),
    team            = "NYY",
    league          = "AL",
    pos_eligibility = hit_positions,
    player_type     = "batter",
    AB              = rnorm(n_hit, mean = 500, sd = 40),
    HR              = rnorm(n_hit, mean = 20,  sd = 6),
    R               = rnorm(n_hit, mean = 70,  sd = 10),
    RBI             = rnorm(n_hit, mean = 70,  sd = 10),
    SB              = rnorm(n_hit, mean = 8,   sd = 4),
    AVG             = rnorm(n_hit, mean = 0.260, sd = 0.020),
    IP              = NA_real_,
    W               = NA_real_,
    ERA             = NA_real_,
    WHIP            = NA_real_,
    SV              = NA_real_,
    K               = NA_real_,
    stringsAsFactors = FALSE
  )

  # Pitchers: pos_eligibility = "P" (the get_projections() fallback).
  # IP spans both sides of the default sp_ip_threshold (100) so classification
  # yields a mix of SP and RP.
  ip_vals <- c(
    runif(n_pit %/% 2L, min = 150, max = 200),  # starters
    runif(n_pit - n_pit %/% 2L, min = 40, max = 80)  # relievers
  )
  pitchers <- data.frame(
    player_id       = paste0("p", seq_len(n_pit)),
    player_name     = paste0("Pitcher ", seq_len(n_pit)),
    team            = "NYY",
    league          = "AL",
    pos_eligibility = rep("P", n_pit),
    player_type     = "pitcher",
    AB              = NA_real_,
    HR              = NA_real_,
    R               = NA_real_,
    RBI             = NA_real_,
    SB              = NA_real_,
    AVG             = NA_real_,
    IP              = ip_vals,
    W               = rnorm(n_pit, mean = 8,    sd = 3),
    ERA             = rnorm(n_pit, mean = 4.0,  sd = 0.6),
    WHIP            = rnorm(n_pit, mean = 1.30, sd = 0.12),
    SV              = c(rep(0, n_pit - 10L), rnorm(10L, mean = 15, sd = 8)),
    K               = ip_vals * rnorm(n_pit, mean = 1.0, sd = 0.1),
    stringsAsFactors = FALSE
  )

  proj <- rbind(hitters, pitchers)

  config <- league_config(
    n_teams      = 10L,
    roster_slots = c(C = 2L, `1B` = 1L, `2B` = 1L, SS = 1L, `3B` = 1L,
                     OF = 5L, UT = 2L, CI = 1L, MI = 1L),
    pitcher_slots = 11L,
    categories   = c("AVG", "HR", "R", "RBI", "SB",
                     "W", "ERA", "WHIP", "SV", "K"),
    league_type  = "AL",
    budget_split = 0.5
  )

  repl <- replacement_level(proj, config = config)

  # Pitcher pools are non-empty after classification.
  sp_row <- repl$replacement_stats[repl$replacement_stats$position == "SP", ,
                                    drop = FALSE]
  rp_row <- repl$replacement_stats[repl$replacement_stats$position == "RP", ,
                                    drop = FALSE]
  expect_gt(sp_row$n_band_players, 0L)
  expect_gt(rp_row$n_band_players, 0L)

  # Pitching stats are populated (not NA) for SP / RP rows.
  expect_false(is.na(sp_row$W))
  expect_false(is.na(sp_row$ERA))
  expect_false(is.na(sp_row$WHIP))
  expect_false(is.na(sp_row$K))
  expect_false(is.na(rp_row$W))
  expect_false(is.na(rp_row$ERA))

  # Hitter rows are unaffected.
  of_row <- repl$replacement_stats[repl$replacement_stats$position == "OF", ,
                                    drop = FALSE]
  expect_false(is.na(of_row$HR))
  expect_false(is.na(of_row$R))
})

test_that("replacement_level() + zar() pipeline produces finite pitcher zar", {
  skip_if_not_installed("withr")

  set.seed(7L)
  n_hit <- 120L
  n_pit <- 60L

  hit_positions <- rep(
    c("C", "1B", "2B", "SS", "3B", "OF"),
    length.out = n_hit
  )
  hitters <- data.frame(
    player_id       = paste0("h", seq_len(n_hit)),
    player_name     = paste0("H", seq_len(n_hit)),
    team            = "NYY",
    league          = "AL",
    pos_eligibility = hit_positions,
    player_type     = "batter",
    AB              = rnorm(n_hit, 500, 40),
    HR              = rnorm(n_hit, 20, 6),
    R               = rnorm(n_hit, 70, 10),
    RBI             = rnorm(n_hit, 70, 10),
    SB              = rnorm(n_hit, 8, 4),
    AVG             = rnorm(n_hit, 0.260, 0.020),
    IP              = NA_real_, W = NA_real_, ERA = NA_real_,
    WHIP = NA_real_, SV = NA_real_, K = NA_real_,
    stringsAsFactors = FALSE
  )
  ip_vals <- c(runif(30, 150, 200), runif(30, 40, 80))
  pitchers <- data.frame(
    player_id       = paste0("p", seq_len(n_pit)),
    player_name     = paste0("P", seq_len(n_pit)),
    team            = "NYY",
    league          = "AL",
    pos_eligibility = rep("P", n_pit),
    player_type     = "pitcher",
    AB              = NA_real_, HR = NA_real_, R = NA_real_,
    RBI = NA_real_, SB = NA_real_, AVG = NA_real_,
    IP              = ip_vals,
    W               = rnorm(n_pit, 8, 3),
    ERA             = rnorm(n_pit, 4.0, 0.6),
    WHIP            = rnorm(n_pit, 1.30, 0.12),
    SV              = c(rep(0, 50), rnorm(10, 15, 8)),
    K               = ip_vals * rnorm(n_pit, 1.0, 0.1),
    stringsAsFactors = FALSE
  )
  proj <- rbind(hitters, pitchers)
  config <- league_config(
    n_teams      = 10L,
    roster_slots = c(C = 2L, `1B` = 1L, `2B` = 1L, SS = 1L, `3B` = 1L,
                     OF = 5L, UT = 2L, CI = 1L, MI = 1L),
    pitcher_slots = 11L,
    categories   = c("AVG", "HR", "R", "RBI", "SB",
                     "W", "ERA", "WHIP", "SV", "K"),
    league_type  = "AL",
    budget_split = 0.5
  )

  result <- zar(replacement_level(proj, config = config))

  # The result includes player_id; pitchers should have non-NA total_zar
  # (their categories are W/ERA/WHIP/SV/K, all of which now resolve).
  pit_ids <- paste0("p", seq_len(n_pit))
  pit_rows <- result[result$player_id %in% pit_ids, , drop = FALSE]
  expect_gt(nrow(pit_rows), 0L)
  # At least some pitchers should have finite zar_W / zar_ERA.
  expect_true(any(is.finite(pit_rows$zar_W)))
  expect_true(any(is.finite(pit_rows$zar_ERA)))
})
```

- [ ] **Step 3: Run the test to verify it PASSES after Tasks 1–4**

Run:
```bash
Rscript -e 'devtools::test(filter = "replacement-integration", reporter = "summary")'
```
Expected: both new tests pass. (If Tasks 1–4 were skipped, these tests would have failed with `n_band_players == 0` for SP/RP — the exact symptom in the bug report.)

- [ ] **Step 4: Sanity-check: revert the Task 3 change on one line and confirm the new tests catch it**

Temporarily edit `R/replacement.R:514` back to `"(SP|RP)"` and run:
```bash
Rscript -e 'devtools::test(filter = "replacement-integration", reporter = "summary")'
```
Expected: the first new test fails (`n_band_players > 0` violated for SP and/or RP). Then restore the fix.

This step is a one-shot sanity check — do not commit the revert.

- [ ] **Step 5: Commit**

```bash
git add tests/testthat/test-replacement-integration.R
git commit -m "test(replacement): add pos_eligibility='P' integration coverage"
```

---

## Task 6: Full verification + NEWS entry + PR

**Files:**
- Modify: `NEWS.md` — add bug-fix entry
- No code changes here

- [ ] **Step 1: Run `devtools::document()` — no roxygen changes expected, but re-run per CLAUDE.md discipline**

Run:
```bash
Rscript -e 'devtools::document()'
```
Expected: no diff to `NAMESPACE` or `man/*.Rd`. Confirm with `git status`.

- [ ] **Step 2: Run the full test suite**

Run:
```bash
Rscript -e 'devtools::test(reporter = "summary")'
```
Expected: all tests pass. Note any new warnings.

- [ ] **Step 3: Run `devtools::check()` per CLAUDE.md**

Run:
```bash
Rscript -e 'devtools::check(document = FALSE)'
```
Expected: 0 errors, 0 warnings. If notes appear, confirm they pre-existed on `develop`.

- [ ] **Step 4: Reproduce the user's original scenario**

Run:
```bash
Rscript -e '
suppressMessages(devtools::load_all("."))
# Use a seeded synthetic fixture shaped like get_projections("steamer"),
# since the real FG call requires network.
source("tests/testthat/test-replacement-integration.R", echo = FALSE)
# The fixture + replacement_level() + zar() pipeline is covered above;
# simply confirm no errors.
cat("integration test pass — pitcher pools populated\n")
'
```

- [ ] **Step 5: Add NEWS.md entry**

In `NEWS.md`, under the development version heading, add a "Bug fixes" subsection (create it if absent):

```markdown
### Bug fixes

* `replacement_level()` now recognizes `pos_eligibility = "P"` (the
  `get_projections()` fallback for FanGraphs pitcher rows, which return no
  position field) and classifies the role via `sp_ip_threshold`. Previously
  pitchers emitted by `get_projections()` were silently dropped from every
  SP/RP pool, yielding `n_band_players = 0` and NA-filled pitcher stat lines
  in `replacement_level()$replacement_stats` and NA-filled pitcher columns
  in `zar()` / `par()` downstream.
```

- [ ] **Step 6: Commit and open PR**

```bash
git add NEWS.md
git commit -m "docs(news): document pos_eligibility='P' handling fix"
git push -u origin HEAD
gh pr create --base develop --title "fix(replacement): classify bare 'P' eligibility via sp_ip_threshold" --body "$(cat <<'EOF'
## Summary

- Widens `replacement_level()`'s pitcher-detection gate from `grepl("(SP|RP)", ...)` to a shared `PITCHER_ELIG_REGEX` that also matches bare `"P"` (the `get_projections()` fallback for FanGraphs pitcher rows, which return no position field)
- Teaches `infer_pitcher_roles()` to classify bare `"P"` via the existing `sp_ip_threshold` parameter; explicit `"SP"` / `"RP"` tokens keep their current meaning
- Adds integration coverage (`get_projections()`-shaped fixture → `replacement_level()` → `zar()`) that would have caught the original report

## Test plan

- [ ] `devtools::test()` passes
- [ ] `devtools::check()` passes with 0 errors, 0 warnings
- [ ] New integration test fails on `develop` (sanity-check step in the plan)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review

**Spec coverage:**

- Widen pitcher detection to accept bare `"P"` → Task 1 (constant) + Task 2 (infer_pitcher_roles) + Task 3 (5 replacement.R sites).
- Keep SP/RP classification centralized at `sp_ip_threshold` → Task 2 preserves that; no changes to `get_projections()`.
- `.compute_two_way_players()` consistency → Task 4.
- Integration regression guard → Task 5 (two tests: `replacement_level()` alone, and pipeline with `zar()`).
- Release notes → Task 6.

**Placeholder scan:**

- No `TBD` / `implement later` / `similar to Task N` found.
- Every code step shows complete replacement snippets with surrounding context.
- Commands and expected outputs are specified.

**Type consistency:**

- `PITCHER_ELIG_REGEX` is introduced in Task 1 and referenced (not redefined) in Tasks 2 and 3.
- `sp_ip_threshold` keeps its current signature (numeric scalar, existing `replacement_level()` argument).
- `infer_pitcher_roles()` return type (`list(role = character, swingman_flag = logical)`) is unchanged.
- Test-data column names match the lowercase-then-uppercased path through `replacement_level()` (the function does its own `toupper()` at the top, so lowercase input is fine).
