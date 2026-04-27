# Get Projections Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Evolve `get_projections()` so its output plugs directly into `replacement_level()`, `sgp()`, and the rest of the valuation pipeline without user-side adapter code.

**Architecture:** All changes stay inside the existing pipeline of private helpers in `R/get-projections-internal.R`. We extend the FG rename map to emit snake_case identifier columns, add two new per-row derivations (`k`, `pos_eligibility`), a post-combine `.filter_mlb()` pass, a new `mlb_only` argument, and a final `tibble::as_tibble()` cast. No new file layout.

**Tech Stack:**
- R (>= 4.3.0), roxygen2, testthat 3e
- `httr2` (fetch), `rlang` (inform), `cli` (abort), `checkmate` (validation), `tibble` (return type — **new Imports dep**)

---

## Context

### What `get_projections()` does today

Returns a base R `data.frame` with one row per player:
- Non-snake-case identifier columns: `playerid` (numeric), `name`, `team`, `League`, `pos`, `player_type`
- Uppercase stat columns: `AB`, `HR`, `RBI`, `SB`, `AVG`, `OBP`, …, `IP`, `ERA`, `WHIP`, `SV`, `HLD`, `SVHD`, `K_per_9`, `BB_per_9`, …
- Includes rows for non-MLB leagues (AAA, FA, etc.) when the FG response contains them.
- `pos` uses `/` as its multi-position separator (e.g. `"SS/OF"`).
- Pitchers have no raw `K` column — only `K_per_9`.

### What consumers need (from the Phase 0 investigation)

- `replacement_level()` (hard-validates): `PLAYER_ID`, `PLAYER_NAME`, `POS_ELIGIBILITY` with `|` separator, `LEAGUE ∈ {"AL","NL"}`.
- `sgp()`, `zaa()`: case-insensitive; look up categories by name. Lenient.
- `par()`, `zar()`, `pvm()`: inherit `replacement_level()`'s contract via `attr(replacement, "projections")`.

All consumers normalize names to UPPER internally, so emitting snake_case is compatible.

### Scope

Seven user-visible changes, all on the non-custom path (API fetch):
1. Snake_case every column (`PlayerName → player_name`, `playerid → player_id`, `League → league`, `AB → ab`, …).
2. Rename `pos → pos_eligibility` and replace `/` with `|` in its values.
3. Derive a raw `k` column for pitchers: `k = k_per_9 * ip / 9`.
4. New `mlb_only = TRUE` argument — drops rows where `league` is not in `c("AL","NL")`.
5. Return a `tibble` (class `c("tbl_df","tbl","data.frame")`).
6. Apply the tibble cast to the custom-data path too (for return-type consistency).
7. Update docs (roxygen, `NEWS.md`) to announce the breaking column-name changes.

### Out of scope

- Any change to consumer functions (`replacement_level`, `sgp`, etc.). They already accept the new shape.
- The `K/9` vs `k_per_9` vs `sgp()`'s `K/9` rate-stat registry key mismatch — separate pre-existing issue.
- `K` derivation for batters (rotisserie convention only scores K for pitchers).
- Validation of custom-data column shape.
- Changing the custom-data pass-through policy (still pass through columns unchanged; only cast to tibble).

### Breaking changes callout

Because 100% of non-custom output columns are renamed, any caller that references raw `get_projections()` output by column name will break. The package is at version `0.0.0.9000` (pre-release), so this is acceptable — but `NEWS.md` must announce it prominently.

---

## File Structure

**Modify:**
- `R/get-projections-internal.R` — extend `PROJECTION_COLUMN_RENAME`, add `.normalize_pos_eligibility()`, `.derive_k()`, `.filter_mlb()`, `.validate_mlb_only()`; adjust `.fetch_one_side()` and `.fetch_and_assemble_projections()` signatures.
- `R/get-projections.R` — add `mlb_only` parameter, update roxygen, wire tibble cast on custom path.
- `tests/testthat/test-get-projections.R` — update every assertion that inspects column names; add tests for the new behaviors.
- `DESCRIPTION` — add `tibble` to Imports.
- `NEWS.md` — add a breaking-changes entry.
- `plans/error-messages.md` — register `rotostats_error_invalid_mlb_only`.

**Do not modify:**
- `tests/testthat/helper-get-projections-fixtures.R` — produces raw FG JSON; FG's raw column names are what they are.
- `tests/testthat/fixtures/projections-*.json` — recorded API responses; untouched.

---

## Task 0: Branch + Dependencies

**Files:**
- Modify: `DESCRIPTION`

**Context:** Create the feature branch off `develop` and add `tibble` to Imports. The existing Imports list is alphabetized — preserve that.

- [ ] **Step 1: Cut the feature branch**

```bash
git fetch origin develop
git checkout -b feature/get-projections-enhancements origin/develop
```

- [ ] **Step 2: Add `tibble` to Imports in DESCRIPTION**

Open `DESCRIPTION`. Current Imports block:

```
Imports:
    checkmate,
    cli (>= 3.6.0),
    httr2 (>= 1.0.0),
    rlang (>= 1.0.0),
    stringi
```

Change to (alphabetical, add `tibble (>= 3.0.0)`):

```
Imports:
    checkmate,
    cli (>= 3.6.0),
    httr2 (>= 1.0.0),
    rlang (>= 1.0.0),
    stringi,
    tibble (>= 3.0.0)
```

- [ ] **Step 3: Verify package loads**

Run:
```r
devtools::load_all()
```
Expected: loads without errors.

- [ ] **Step 4: Commit**

```bash
git add DESCRIPTION
git commit -m "chore(deps): add tibble Imports for get_projections() tibble return"
```

---

## Task 1: Register `rotostats_error_invalid_mlb_only`

**Files:**
- Modify: `plans/error-messages.md`

**Context:** The `mlb_only` argument is a logical flag. We follow the existing convention (see `get-projections-plan.md` Task 1) of registering an explicit classed error for every abort.

- [ ] **Step 1: Append the new error class**

Open `plans/error-messages.md`. Find the Errors table. Append a new row after the existing `rotostats_error_empty_projection_response` row:

```
| `rotostats_error_invalid_mlb_only` | `get_projections()` `mlb_only` must be a length-1 non-NA logical. |
```

- [ ] **Step 2: Commit**

```bash
git add plans/error-messages.md
git commit -m "docs(errors): register rotostats_error_invalid_mlb_only"
```

---

## Task 2: Snake_case the rename map + propagate through internals + tests

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

**Context:** This is the largest single change. We extend `PROJECTION_COLUMN_RENAME` to produce final snake_case names (not just mid-pipeline ones), add a generic `tolower()` fallback for untouched columns, and update `.derive_svhd()` and the test suite to match.

Keep `.attach_player_type()` as-is — it already sets `player_type` (lowercase) unconditionally.

The `pos` column stays as `pos` through this task (the rename to `pos_eligibility` happens in Task 3).

- [ ] **Step 1: Update test expectations (TDD: tests first)**

In `tests/testthat/test-get-projections.R`, update every assertion that expects the old column names. Use a mechanical substitution — any reference to these names in assertions must become snake_case:

| Old | New |
|-----|-----|
| `playerid` | `player_id` |
| `PlayerName` | N/A (only appears in fixture builders — leave alone) |
| `name` (as the renamed output column) | `player_name` |
| `Team` (as an output column) | `team` (already lowercase in assertions; keep) |
| `team` | `team` (unchanged) |
| `League` | `league` |
| `minpos` | N/A (fixture input only) |
| `pos` | `pos` (unchanged — Task 3 renames) |
| `AB` | `ab` |
| `HR` | `hr` |
| `RBI` | `rbi` |
| `SB` | `sb` |
| `AVG` | `avg` |
| `OBP` | `obp` |
| `SLG` | `slg` |
| `OPS` | `ops` |
| `wRC+` | `wrc_plus` (was `wRC_plus`) |
| `G` | `g` |
| `IP` | `ip` |
| `W` | `w` |
| `L` | `l` |
| `GS` | `gs` |
| `ERA` | `era` |
| `WHIP` | `whip` |
| `SV` | `sv` |
| `HLD` | `hld` |
| `QS` | `qs` |
| `K/9`, `K_per_9` | `k_per_9` |
| `BB/9`, `BB_per_9` | `bb_per_9` |
| `HR/9`, `HR_per_9` | `hr_per_9` |
| `K/BB`, `K_per_BB` | `k_per_bb` |
| `K%`, `K_pct` | `k_pct` |
| `BB%`, `BB_pct` | `bb_pct` |
| `SVHD` | `svhd` |

Concrete examples of typical updates. If you see:

```r
expect_true("playerid" %in% names(out))
expect_true("PlayerName" %in% names(out))
```

Replace with:

```r
expect_true("player_id" %in% names(out))
expect_true("player_name" %in% names(out))
```

If you see:

```r
expect_equal(out$SVHD, out$SV + out$HLD)
```

Replace with:

```r
expect_equal(out$svhd, out$sv + out$hld)
```

If you see:

```r
expect_true(all(c("playerid", "name", "team", "pos", "player_type") %in% names(out)))
```

Replace with:

```r
expect_true(all(c("player_id", "player_name", "team", "pos", "player_type") %in% names(out)))
```

Leave fixture tests (those gated by `skip_if_not_installed("jsonlite")`) to also use snake_case assertions.

- [ ] **Step 2: Run tests to confirm they fail**

```r
devtools::test(filter = "get-projections")
```
Expected: many failures — the rename map still emits `name`, `playerid`, etc.

- [ ] **Step 3: Update `PROJECTION_COLUMN_RENAME`**

In `R/get-projections-internal.R`, replace the current `PROJECTION_COLUMN_RENAME` block (roughly lines 193–206) with:

```r
#' @noRd
#' @description
#' Maps raw FanGraphs column names to rotostats' snake_case contract.
#' Every entry points at the final output name (no intermediate stop).
#' Columns not in this map fall through to a generic `tolower()` pass
#' inside `.normalize_projection_cols()`.
PROJECTION_COLUMN_RENAME <- c(
  playerid   = "player_id",
  PlayerName = "player_name",
  Team       = "team",
  League     = "league",
  minpos     = "pos",
  `wRC+`     = "wrc_plus",
  `K/9`      = "k_per_9",
  `BB/9`     = "bb_per_9",
  `HR/9`     = "hr_per_9",
  `K/BB`     = "k_per_bb",
  `K%`       = "k_pct",
  `BB%`      = "bb_pct"
)
```

- [ ] **Step 4: Add a `tolower()` fallback in `.normalize_projection_cols()`**

Replace the current body (lines 208–220) with:

```r
#' @noRd
.normalize_projection_cols <- function(df) {
  nm <- names(df)
  # Step 1: explicit renames from the map.
  for (raw in names(PROJECTION_COLUMN_RENAME)) {
    target <- PROJECTION_COLUMN_RENAME[[raw]]
    hits <- which(nm == raw)
    if (length(hits) == 1L && !(target %in% nm)) {
      nm[hits] <- target
    }
  }
  # Step 2: any column not already snake_case gets lowercased.
  # Leaves map-produced names untouched (they're already snake_case).
  untouched <- !(nm %in% unname(PROJECTION_COLUMN_RENAME))
  nm[untouched] <- tolower(nm[untouched])
  names(df) <- nm
  df
}
```

- [ ] **Step 5: Update `.derive_svhd()` to use lowercase columns**

Replace the body (lines 222–234) with:

```r
#' @noRd
.derive_svhd <- function(df) {
  if (!all(c("sv", "hld") %in% names(df))) return(df)
  sv  <- ifelse(is.na(df$sv),  0, df$sv)
  hld <- ifelse(is.na(df$hld), 0, df$hld)
  df$svhd <- sv + hld
  rlang::inform(
    "SVHD computed as SV + HLD. Verify this matches your league's SVHD definition.",
    .frequency = "once",
    .frequency_id = "rotostats_svhd_definition"
  )
  df
}
```

- [ ] **Step 6: Run tests to confirm they pass**

```r
devtools::test(filter = "get-projections")
```
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "refactor(projections): emit snake_case column names"
```

---

## Task 3: `.normalize_pos_eligibility()` — `pos → pos_eligibility` + `/` → `|`

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

**Context:** `replacement_level()` requires a `POS_ELIGIBILITY` column with `|` as the multi-position separator. FG gives us `pos` (after normalize) with `/` as the separator. This helper does the rename and the `gsub`. Called from `.fetch_one_side()` after the pitcher `pos = "P"` fallback.

- [ ] **Step 1: Write failing tests**

Append to `tests/testthat/test-get-projections.R`:

```r
test_that(".normalize_pos_eligibility() renames pos to pos_eligibility", {
  df <- data.frame(pos = c("2B", "SS/OF"), stringsAsFactors = FALSE)
  out <- .normalize_pos_eligibility(df)
  expect_true("pos_eligibility" %in% names(out))
  expect_false("pos" %in% names(out))
})

test_that(".normalize_pos_eligibility() converts / separators to |", {
  df <- data.frame(pos = c("2B", "SS/OF", "1B/3B/OF"), stringsAsFactors = FALSE)
  out <- .normalize_pos_eligibility(df)
  expect_equal(out$pos_eligibility, c("2B", "SS|OF", "1B|3B|OF"))
})

test_that(".normalize_pos_eligibility() leaves single positions alone", {
  df <- data.frame(pos = c("P", "C", "DH"), stringsAsFactors = FALSE)
  out <- .normalize_pos_eligibility(df)
  expect_equal(out$pos_eligibility, c("P", "C", "DH"))
})

test_that(".normalize_pos_eligibility() is a no-op when pos is absent", {
  df <- data.frame(player_name = "X", stringsAsFactors = FALSE)
  out <- .normalize_pos_eligibility(df)
  expect_identical(out, df)
  expect_false("pos_eligibility" %in% names(out))
})

test_that(".normalize_pos_eligibility() preserves NA in pos", {
  df <- data.frame(pos = c("2B", NA_character_, "SS/OF"), stringsAsFactors = FALSE)
  out <- .normalize_pos_eligibility(df)
  expect_equal(out$pos_eligibility, c("2B", NA_character_, "SS|OF"))
})
```

- [ ] **Step 2: Run tests to confirm failure**

```r
devtools::test(filter = "get-projections")
```
Expected: the 5 new tests fail with `could not find function ".normalize_pos_eligibility"`.

- [ ] **Step 3: Implement the helper**

In `R/get-projections-internal.R`, immediately after `.derive_svhd()` (around line 234) add:

```r
#' @noRd
.normalize_pos_eligibility <- function(df) {
  if (!("pos" %in% names(df))) return(df)
  df$pos_eligibility <- gsub("/", "|", df$pos, fixed = TRUE)
  df$pos <- NULL
  df
}
```

- [ ] **Step 4: Wire it into `.fetch_one_side()`**

Replace the existing `.fetch_one_side()` body (lines 266–276) with:

```r
#' @noRd
.fetch_one_side <- function(source, player_type) {
  stopifnot(player_type %in% c("batters", "pitchers"))
  url <- .build_projections_url(source, player_type)
  raw <- .fetch_projections_api(url)
  df  <- .parse_projections_json(raw)
  df  <- .normalize_projection_cols(df)
  if (player_type == "pitchers") {
    df <- .derive_svhd(df)
    if (!("pos" %in% names(df))) df$pos <- "P"
  }
  df <- .normalize_pos_eligibility(df)
  .attach_player_type(df, if (player_type == "batters") "batter" else "pitcher")
}
```

- [ ] **Step 5: Update any existing tests that assert `pos` is present in the final output**

Search `tests/testthat/test-get-projections.R` for `"pos" %in% names` and for `out$pos`. For assertions against the *final* orchestrator output (e.g. the `get_projections()` or `.fetch_and_assemble_projections()` tests), change `pos` → `pos_eligibility`. For assertions against intermediate helpers (`.normalize_projection_cols()`, `.derive_svhd()`), leave them — those run before `.normalize_pos_eligibility()`.

Specifically, the pitcher `pos = "P"` assertion at the orchestrator level should become:

```r
expect_true(all(out$pos_eligibility[out$player_type == "pitcher"] == "P"))
```

And the batter assertion that checked `nchar(out$pos) <= 6` should become:

```r
expect_true(all(nchar(out$pos_eligibility) <= 6, na.rm = TRUE))
# Pipe-delimited now — no slashes should remain
expect_false(any(grepl("/", out$pos_eligibility, fixed = TRUE), na.rm = TRUE))
```

- [ ] **Step 6: Run tests to confirm they pass**

```r
devtools::test(filter = "get-projections")
```
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): add pos_eligibility with pipe separator"
```

---

## Task 4: `.derive_k()` — raw `K` count for pitchers

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

**Context:** Most rotisserie leagues score pitcher strikeouts (`K`) as a counting category. FG only returns the rate `k_per_9`, so we derive `k = k_per_9 * ip / 9`. This runs in the pitcher branch of `.fetch_one_side()` (between `.derive_svhd` and the pos fallback).

- [ ] **Step 1: Write failing tests**

Append to `tests/testthat/test-get-projections.R`:

```r
test_that(".derive_k() computes k = k_per_9 * ip / 9", {
  df <- data.frame(ip = c(180, 90), k_per_9 = c(9.0, 10.0), stringsAsFactors = FALSE)
  out <- .derive_k(df)
  expect_equal(out$k, c(180, 100))
})

test_that(".derive_k() is a no-op if k_per_9 is absent", {
  df <- data.frame(ip = 180, stringsAsFactors = FALSE)
  out <- .derive_k(df)
  expect_identical(out, df)
  expect_false("k" %in% names(out))
})

test_that(".derive_k() is a no-op if ip is absent", {
  df <- data.frame(k_per_9 = 9.0, stringsAsFactors = FALSE)
  out <- .derive_k(df)
  expect_identical(out, df)
  expect_false("k" %in% names(out))
})

test_that(".derive_k() does not overwrite an existing k column", {
  df <- data.frame(ip = 180, k_per_9 = 9.0, k = 42, stringsAsFactors = FALSE)
  out <- .derive_k(df)
  expect_equal(out$k, 42)
})

test_that(".derive_k() propagates NA in ip or k_per_9", {
  df <- data.frame(
    ip      = c(180, NA_real_, 90),
    k_per_9 = c(9.0, 10.0,     NA_real_),
    stringsAsFactors = FALSE
  )
  out <- .derive_k(df)
  expect_equal(out$k, c(180, NA_real_, NA_real_))
})
```

- [ ] **Step 2: Run tests to confirm failure**

```r
devtools::test(filter = "get-projections")
```
Expected: 5 new failures with `could not find function ".derive_k"`.

- [ ] **Step 3: Implement the helper**

In `R/get-projections-internal.R`, immediately after `.derive_svhd()` (and before `.normalize_pos_eligibility()`) add:

```r
#' @noRd
.derive_k <- function(df) {
  if (!all(c("k_per_9", "ip") %in% names(df))) return(df)
  if ("k" %in% names(df)) return(df)
  df$k <- df$k_per_9 * df$ip / 9
  df
}
```

- [ ] **Step 4: Wire it into `.fetch_one_side()`**

Replace the pitcher branch of `.fetch_one_side()` to include `.derive_k()`:

```r
  if (player_type == "pitchers") {
    df <- .derive_svhd(df)
    df <- .derive_k(df)
    if (!("pos" %in% names(df))) df$pos <- "P"
  }
```

- [ ] **Step 5: Update the pitcher orchestrator tests**

In `tests/testthat/test-get-projections.R`, find the pitcher-branch test (the one stubbing `.fetch_one_side` via `fx_pitcher_json`) and add:

```r
expect_true("k" %in% names(out))
expect_equal(
  out$k[out$player_type == "pitcher"],
  out$k_per_9[out$player_type == "pitcher"] *
    out$ip[out$player_type == "pitcher"] / 9
)
```

- [ ] **Step 6: Run tests to confirm they pass**

```r
devtools::test(filter = "get-projections")
```
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): derive raw K column for pitchers"
```

---

## Task 5: `.filter_mlb()` — drop non-AL/NL rows

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

**Context:** FG responses can include minor-league players (e.g. `league = "AAA"`, `"FA"`, or `NA`). Rotisserie valuation typically restricts to AL + NL. We add a helper that drops everything else. Called from `.fetch_and_assemble_projections()` after combine, before the tibble cast.

- [ ] **Step 1: Write failing tests**

Append to `tests/testthat/test-get-projections.R`:

```r
test_that(".filter_mlb() keeps AL and NL rows", {
  df <- data.frame(
    player_name = c("A", "B", "C"),
    league      = c("AL", "NL", "AL"),
    stringsAsFactors = FALSE
  )
  out <- .filter_mlb(df)
  expect_equal(nrow(out), 3L)
})

test_that(".filter_mlb() drops rows with other league values", {
  df <- data.frame(
    player_name = c("A", "B", "C", "D"),
    league      = c("AL", "AAA", "NL", "FA"),
    stringsAsFactors = FALSE
  )
  out <- .filter_mlb(df)
  expect_equal(nrow(out), 2L)
  expect_equal(out$player_name, c("A", "C"))
})

test_that(".filter_mlb() drops rows with NA league", {
  df <- data.frame(
    player_name = c("A", "B", "C"),
    league      = c("AL", NA_character_, "NL"),
    stringsAsFactors = FALSE
  )
  out <- .filter_mlb(df)
  expect_equal(nrow(out), 2L)
  expect_equal(out$player_name, c("A", "C"))
})

test_that(".filter_mlb() is a no-op when league column is absent", {
  df <- data.frame(player_name = "A", stringsAsFactors = FALSE)
  out <- .filter_mlb(df)
  expect_identical(out, df)
})
```

- [ ] **Step 2: Run tests to confirm failure**

```r
devtools::test(filter = "get-projections")
```
Expected: 4 new failures with `could not find function ".filter_mlb"`.

- [ ] **Step 3: Implement the helper**

Add to `R/get-projections-internal.R` immediately after `.combine_batter_pitcher()`:

```r
#' @noRd
.filter_mlb <- function(df) {
  if (!("league" %in% names(df))) return(df)
  keep <- !is.na(df$league) & df$league %in% c("AL", "NL")
  df[keep, , drop = FALSE]
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```r
devtools::test(filter = "get-projections")
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): add .filter_mlb() for AL/NL-only filtering"
```

---

## Task 6: `.validate_mlb_only()` + wire `mlb_only` through orchestrator

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

**Context:** Add the argument validator and update `.fetch_and_assemble_projections()` to call `.filter_mlb()` when `mlb_only = TRUE`. The public `get_projections()` function will be updated in Task 7.

- [ ] **Step 1: Write failing tests**

Append to `tests/testthat/test-get-projections.R`:

```r
test_that(".validate_mlb_only() accepts TRUE and FALSE", {
  expect_true(.validate_mlb_only(TRUE))
  expect_false(.validate_mlb_only(FALSE))
})

test_that(".validate_mlb_only() rejects non-logical", {
  expect_error(
    .validate_mlb_only("yes"),
    class = "rotostats_error_invalid_mlb_only"
  )
  expect_error(
    .validate_mlb_only(1),
    class = "rotostats_error_invalid_mlb_only"
  )
})

test_that(".validate_mlb_only() rejects length != 1", {
  expect_error(
    .validate_mlb_only(c(TRUE, FALSE)),
    class = "rotostats_error_invalid_mlb_only"
  )
  expect_error(
    .validate_mlb_only(logical(0)),
    class = "rotostats_error_invalid_mlb_only"
  )
})

test_that(".validate_mlb_only() rejects NA", {
  expect_error(
    .validate_mlb_only(NA),
    class = "rotostats_error_invalid_mlb_only"
  )
})

test_that(".fetch_and_assemble_projections() applies .filter_mlb when mlb_only is TRUE", {
  # Mock .fetch_one_side to return a frame with mixed leagues.
  fake_df <- data.frame(
    player_id   = 1:3,
    player_name = c("A", "B", "C"),
    league      = c("AL", "AAA", "NL"),
    player_type = "batter",
    stringsAsFactors = FALSE
  )
  testthat::local_mocked_bindings(
    .fetch_one_side = function(source, player_type) fake_df,
    .package = "rotostats"
  )
  out <- .fetch_and_assemble_projections("steamer", "batters", mlb_only = TRUE)
  expect_equal(nrow(out), 2L)
  expect_equal(out$player_name, c("A", "C"))
})

test_that(".fetch_and_assemble_projections() preserves all rows when mlb_only is FALSE", {
  fake_df <- data.frame(
    player_id   = 1:3,
    player_name = c("A", "B", "C"),
    league      = c("AL", "AAA", "NL"),
    player_type = "batter",
    stringsAsFactors = FALSE
  )
  testthat::local_mocked_bindings(
    .fetch_one_side = function(source, player_type) fake_df,
    .package = "rotostats"
  )
  out <- .fetch_and_assemble_projections("steamer", "batters", mlb_only = FALSE)
  expect_equal(nrow(out), 3L)
})
```

- [ ] **Step 2: Run tests to confirm failure**

```r
devtools::test(filter = "get-projections")
```
Expected: failures — `.validate_mlb_only` missing, and `.fetch_and_assemble_projections` has wrong arity.

- [ ] **Step 3: Implement the validator**

Add to `R/get-projections-internal.R` immediately after `.validate_custom_data()` (around line 109):

```r
#' @noRd
.validate_mlb_only <- function(mlb_only) {
  if (!is.logical(mlb_only) || length(mlb_only) != 1L || is.na(mlb_only)) {
    cli::cli_abort(
      c(
        "{.arg mlb_only} must be a length-1 non-NA logical.",
        i = "Received: {.val {mlb_only}}."
      ),
      class = "rotostats_error_invalid_mlb_only"
    )
  }
  mlb_only
}
```

- [ ] **Step 4: Extend `.fetch_and_assemble_projections()` signature**

Replace the current definition with:

```r
#' @noRd
.fetch_and_assemble_projections <- function(source, player_type, mlb_only) {
  bat <- if (player_type %in% c("batters", "both")) {
    .fetch_one_side(source, "batters")
  } else NULL
  pit <- if (player_type %in% c("pitchers", "both")) {
    .fetch_one_side(source, "pitchers")
  } else NULL
  df <- .combine_batter_pitcher(bat, pit)
  if (isTRUE(mlb_only)) df <- .filter_mlb(df)
  df
}
```

(Note: we add the `mlb_only` parameter but do not yet cast to tibble — that's Task 7.)

- [ ] **Step 5: Run tests to confirm they pass**

```r
devtools::test(filter = "get-projections")
```
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): validate and wire mlb_only filter"
```

---

## Task 7: Tibble return + exported `mlb_only` argument

**Files:**
- Modify: `R/get-projections.R`
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

**Context:** Add the `mlb_only` parameter to the exported `get_projections()`, wire the validator, cast both paths (custom + API) to tibble. The API path casts *after* the `.filter_mlb()` pass.

- [ ] **Step 1: Write failing tests**

Append to `tests/testthat/test-get-projections.R`:

```r
test_that("get_projections() returns a tibble (API path)", {
  fake_df <- data.frame(
    player_id   = 1:2,
    player_name = c("A", "B"),
    league      = c("AL", "NL"),
    player_type = "batter",
    stringsAsFactors = FALSE
  )
  testthat::local_mocked_bindings(
    .fetch_one_side = function(source, player_type) fake_df,
    .package = "rotostats"
  )
  out <- get_projections(source = "steamer", player_type = "batters")
  expect_s3_class(out, "tbl_df")
})

test_that("get_projections() returns a tibble (custom path)", {
  custom <- data.frame(
    name = c("X", "Y"),
    HR   = c(20, 25),
    stringsAsFactors = FALSE
  )
  out <- get_projections(source = "custom", data = custom)
  expect_s3_class(out, "tbl_df")
})

test_that("get_projections() defaults mlb_only = TRUE and drops non-AL/NL rows", {
  fake_df <- data.frame(
    player_id   = 1:3,
    player_name = c("A", "B", "C"),
    league      = c("AL", "AAA", "NL"),
    player_type = "batter",
    stringsAsFactors = FALSE
  )
  testthat::local_mocked_bindings(
    .fetch_one_side = function(source, player_type) fake_df,
    .package = "rotostats"
  )
  out <- get_projections(source = "steamer", player_type = "batters")
  expect_equal(nrow(out), 2L)
})

test_that("get_projections(mlb_only = FALSE) preserves all rows", {
  fake_df <- data.frame(
    player_id   = 1:3,
    player_name = c("A", "B", "C"),
    league      = c("AL", "AAA", "NL"),
    player_type = "batter",
    stringsAsFactors = FALSE
  )
  testthat::local_mocked_bindings(
    .fetch_one_side = function(source, player_type) fake_df,
    .package = "rotostats"
  )
  out <- get_projections(
    source      = "steamer",
    player_type = "batters",
    mlb_only    = FALSE
  )
  expect_equal(nrow(out), 3L)
})

test_that("get_projections() surfaces invalid mlb_only error class", {
  expect_error(
    get_projections(source = "steamer", mlb_only = "yes"),
    class = "rotostats_error_invalid_mlb_only"
  )
})
```

- [ ] **Step 2: Run tests to confirm failure**

```r
devtools::test(filter = "get-projections")
```
Expected: failures — `mlb_only` not an accepted arg, output is data.frame not tibble.

- [ ] **Step 3: Update `get_projections()`**

Replace the body of `R/get-projections.R` below the roxygen block (which you'll update in Task 9). The function code:

```r
get_projections <- function(source      = "steamer",
                            year        = NULL,
                            player_type = "both",
                            data        = NULL,
                            mlb_only    = TRUE) {
  source      <- .validate_source(source)
  player_type <- .validate_player_type(player_type)
  year        <- .validate_year(year)
  data        <- .validate_custom_data(source, data)
  mlb_only    <- .validate_mlb_only(mlb_only)

  if (source == "custom") return(tibble::as_tibble(data))

  tibble::as_tibble(
    .fetch_and_assemble_projections(source, player_type, mlb_only)
  )
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```r
devtools::test(filter = "get-projections")
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add R/get-projections.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): add mlb_only argument and return tibble"
```

---

## Task 8: Fixture-replay integration test for the full new contract

**Files:**
- Modify: `tests/testthat/test-get-projections.R`

**Context:** The three fixture-replay tests recorded in Phase 0 exercise the full pipeline. After the changes in Tasks 2–7 they should now return tibbles with snake_case columns, `pos_eligibility`, `k`, etc. Add explicit assertions for the new contract so any regression is caught by the existing fixtures.

- [ ] **Step 1: Extend existing fixture-replay tests**

Find the three tests gated by `skip_if_not_installed("jsonlite")` in `tests/testthat/test-get-projections.R`. For each, add after the existing assertions (preserving the `skip_if_not_installed("jsonlite")` guard):

```r
# Snake_case contract
expect_true(all(names(out) == tolower(names(out))))

# Required identifier columns
required_ids <- c("player_id", "player_name", "team", "league", "player_type")
expect_true(all(required_ids %in% names(out)))

# pos_eligibility present; pos absent; no slashes
expect_true("pos_eligibility" %in% names(out))
expect_false("pos" %in% names(out))
expect_false(any(grepl("/", out$pos_eligibility, fixed = TRUE), na.rm = TRUE))

# league filter default
expect_true(all(out$league %in% c("AL", "NL")))

# tibble return
expect_s3_class(out, "tbl_df")
```

For the **pitcher** and **both** fixture-replay tests specifically, also add:

```r
# k derivation for pitchers
pitcher_rows <- out[out$player_type == "pitcher", , drop = FALSE]
expect_true("k" %in% names(pitcher_rows))
expect_true(all(is.finite(pitcher_rows$k) | is.na(pitcher_rows$k)))
```

- [ ] **Step 2: Run tests to confirm they pass**

```r
devtools::test(filter = "get-projections")
```
Expected: all pass (including the 3 fixture-replay tests).

- [ ] **Step 3: Commit**

```bash
git add tests/testthat/test-get-projections.R
git commit -m "test(projections): assert full new contract in fixture replays"
```

---

## Task 9: Update `get_projections()` roxygen + regenerate man pages

**Files:**
- Modify: `R/get-projections.R`
- Regenerate: `man/get_projections.Rd`, `NAMESPACE`

**Context:** Document the new `mlb_only` arg, update the `@return` description, rewrite the always-present columns list, update the example to reflect new column names.

- [ ] **Step 1: Replace the roxygen block**

In `R/get-projections.R`, replace the entire roxygen block (lines 3–34) with:

```r
#' Fetch projections for a rotisserie auction league
#'
#' @description
#' Retrieves projections for the current MLB season from one of six FanGraphs
#' projection systems (Steamer, ZiPS, ATC, FanGraphs Depth Charts, THE BAT,
#' THE BAT X) or accepts a user-supplied data frame of custom projections.
#' The returned tibble is in long format: one row per player, with a
#' `player_type` column (`"batter"` / `"pitcher"`) distinguishing the two
#' groups. `svhd` is derived as `sv + hld` and `k` as `k_per_9 * ip / 9`
#' for pitchers.
#'
#' @param source One of `"steamer"` (default), `"zips"`, `"atc"`,
#'   `"fangraphsdc"`, `"thebat"`, `"thebatx"`, or `"custom"`.
#' @param year Projection year. Only the current MLB season is supported.
#'   `NULL` (default) resolves to the current calendar year; passing any
#'   other value aborts.
#' @param player_type One of `"batters"`, `"pitchers"`, or `"both"` (default).
#' @param data Required when `source = "custom"`; a data.frame containing at
#'   minimum one of `name` or `playerid`, plus one column per scored
#'   category. Passed through unchanged (no normalization is applied),
#'   coerced to a tibble on return.
#' @param mlb_only Logical, default `TRUE`. When `TRUE`, rows whose `league`
#'   value is not `"AL"` or `"NL"` (including `NA`) are dropped after fetch.
#'   Ignored on the `source = "custom"` path. Set to `FALSE` to retain minor
#'   league and free-agent rows.
#'
#' @return A tibble with one row per player. For non-custom sources, the
#'   always-present columns are `player_id`, `player_name`, `team`, `league`,
#'   `pos_eligibility`, and `player_type`. Position strings use `|` as the
#'   multi-position separator (e.g. `"SS|OF"`). Pitcher rows additionally
#'   include derived `svhd` and `k`. Other stat columns are passed through
#'   from FanGraphs with column names lowercased. The output plugs into
#'   [`replacement_level()`] and [`sgp()`] without further reshaping.
#'
#' @seealso [`sgp()`], [`replacement_level()`]
#'
#' @examples
#' \dontrun{
#' # Full current-season projections, AL/NL only
#' proj <- get_projections(source = "steamer")
#'
#' # Keep minor-league rows too
#' proj_all <- get_projections(source = "steamer", mlb_only = FALSE)
#'
#' # Pitchers only
#' pit <- get_projections(source = "thebat", player_type = "pitchers")
#' }
#'
#' @export
```

- [ ] **Step 2: Regenerate documentation**

```r
devtools::document()
```
Expected: regenerates `man/get_projections.Rd` and `NAMESPACE`.

- [ ] **Step 3: Verify examples still parse**

```r
devtools::check_man()
```
Expected: no warnings.

- [ ] **Step 4: Commit**

```bash
git add R/get-projections.R man/get_projections.Rd NAMESPACE
git commit -m "docs(projections): document mlb_only arg and new return contract"
```

---

## Task 10: Update `NEWS.md`

**Files:**
- Modify: `NEWS.md`

**Context:** This is a breaking change for any code that referenced old column names from `get_projections()`. Call it out prominently. Since the package is pre-release (`0.0.0.9000`), we do not bump the version.

- [ ] **Step 1: Edit `NEWS.md`**

Find the section under the current unreleased version heading. Under the existing `### New features` sub-heading (or create one below `# rotostats (development version)` if none exists), add:

```markdown
### Breaking changes

* `get_projections()` now returns a tibble with snake_case column names.
  Identifier columns are `player_id`, `player_name`, `team`, `league`,
  `pos_eligibility`, and `player_type`. Stat columns are lowercased
  (`ab`, `hr`, `k_per_9`, etc.). Existing code that referenced columns
  like `PlayerName`, `playerid`, `League`, `SVHD`, or `K_per_9` must be
  updated.
* Position eligibility is emitted in `pos_eligibility` with `|` as the
  multi-position separator (e.g. `"SS|OF"`). The previous `pos` column
  (with `/` separator) is removed.

### New features

* `get_projections()` gains an `mlb_only` argument (default `TRUE`) that
  drops rows whose `league` is not `"AL"` or `"NL"`. Set to `FALSE` to
  retain minor-league and free-agent rows.
* Pitcher rows gain a derived `k` column (`k = k_per_9 * ip / 9`) so that
  strikeouts can be scored as a counting category without downstream
  arithmetic.
* `get_projections()` output now plugs directly into `replacement_level()`
  and `sgp()` without an adapter step.
```

- [ ] **Step 2: Commit**

```bash
git add NEWS.md
git commit -m "docs(news): announce breaking column changes and mlb_only arg"
```

---

## Task 11: `devtools::check()` gate

**Files:** None (diagnostic)

**Context:** Confirm the package still passes R CMD check with 0 errors, 0 warnings, and the same pre-existing NOTE count that main has (currently 5).

- [ ] **Step 1: Run the check**

```r
devtools::check()
```
Expected: `0 errors ✓ | 0 warnings ✓ | 5 notes` (or fewer). All notes should be pre-existing (not introduced by this PR).

- [ ] **Step 2: Review any new NOTE**

If any new NOTE appears that wasn't present on `develop`, fix it. Common new issues to watch for:
- `no visible binding for global variable` — fix with `@importFrom` or `utils::globalVariables()`.
- `"tibble" Imports but not used in NAMESPACE, Depends or Imports` — shouldn't happen since we call `tibble::as_tibble()`, but if it does, verify the call site.

- [ ] **Step 3: Commit any fixes**

```bash
git add R/ NAMESPACE man/
git commit -m "fix(projections): resolve R CMD check findings"
```

(Skip this step if no fixes were needed.)

---

## Task 12: Open the PR

**Files:** None (git operation)

**Context:** Target `develop`, not `main`. Conventional commit title.

- [ ] **Step 1: Verify branch is up to date with develop**

```bash
git fetch origin develop
git log --oneline origin/develop..HEAD
```
Expected: sees all commits from Tasks 0–11.

- [ ] **Step 2: Push and open PR**

```bash
git push -u origin feature/get-projections-enhancements
gh pr create \
  --base develop \
  --title "feat(projections): snake_case output, k derivation, mlb_only filter, tibble return" \
  --body "$(cat <<'EOF'
## Summary

- `get_projections()` now emits snake_case column names with the contract the rest of the package expects: `player_id`, `player_name`, `team`, `league`, `pos_eligibility` (pipe-delimited), `player_type`. Stat columns are lowercased.
- New `mlb_only` argument (default `TRUE`) drops rows whose `league` is not `"AL"` or `"NL"`.
- Pitcher rows gain a derived `k = k_per_9 * ip / 9` column so strikeouts can be scored directly.
- Return value is a tibble on both the API and custom-data paths.
- Output plugs into `replacement_level()` and `sgp()` without an adapter step.

**Breaking:** any caller that referenced old column names (`PlayerName`, `playerid`, `SVHD`, `K_per_9`, `League`, `pos`, …) must migrate. Covered in `NEWS.md`.

## Test plan

- [x] `devtools::test(filter = "get-projections")` — all unit + fixture-replay tests pass
- [x] `devtools::check()` — 0 errors / 0 warnings / pre-existing NOTEs only
- [x] Smoke test in a clean R session:
  \`\`\`r
  devtools::load_all()
  p <- get_projections(source = "steamer")
  p |> rotostats::replacement_level(config = rotostats::league_config())
  \`\`\`

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Capture the PR URL**

```bash
gh pr view --json url --jq .url
```

Report this URL back to the user.

---

## Self-Review Checklist (author ran this before handoff)

**Spec coverage:**

| User-requested item | Covered by |
|---|---|
| K derivation (pitcher) | Task 4 |
| `mlb_only` arg with default `TRUE` | Tasks 5 + 6 + 7 |
| snake_case columns | Task 2 |
| Tibble return | Task 7 |
| `pos → pos_eligibility`, `/` → `|` (implied by `replacement_level()` compatibility) | Task 3 |
| `name → player_name` (implied) | Task 2 (rename map) |
| `playerid → player_id` (implied) | Task 2 (rename map) |
| `NEWS.md` breaking-change callout | Task 10 |
| Docs for new arg | Task 9 |
| Custom-data path also returns tibble | Task 7 |

**Placeholder scan:** No "TBD", "implement later", "similar to Task N", or "add appropriate error handling" remain. Every step has real code.

**Type consistency:**
- `.validate_mlb_only()` is introduced in Task 6 and called from Task 7 (consistent signature).
- `.fetch_and_assemble_projections()` gains a third parameter `mlb_only` in Task 6; Task 7 passes it from the exported function.
- `.derive_k()`, `.normalize_pos_eligibility()`, and `.filter_mlb()` are each introduced once and wired in the same or a later task.
- All column-name references in the plan use the final snake_case names after Task 2.

**Branch + commit hygiene:** fresh branch off `develop`, Conventional Commits, PR targets `develop`.
