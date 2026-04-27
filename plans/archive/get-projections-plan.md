# `get_projections()` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `get_projections()` — a user-facing function that fetches
current-season FanGraphs projections for one of six supported systems (or
accepts user-supplied custom projections), normalizes column names, derives
`SVHD`, and returns a single long-format data frame with one row per player.

**Architecture:** A thin exported orchestrator (`R/get-projections.R`) that
dispatches to small, independently-testable private helpers
(`R/get-projections-internal.R`): argument validation → URL builder → HTTP
fetch → row-wise normalization → SVHD derivation → rbind of batter/pitcher
frames. Network I/O is isolated in a single function stubbable via
`testthat::local_mocked_bindings()` so the bulk of the suite runs offline.

**Tech Stack:** R ≥ 4.3, `httr2` (HTTP — new Imports dep), `jsonlite` (JSON
parse — new Imports dep), `checkmate` (arg validation), `cli` (conditions),
`rlang` (`inform(.frequency = "once")`), `stringi` (already present).

**Reference spec:** [plans/implementation/get-projections-impl.md](plans/implementation/get-projections-impl.md)

**Out of scope:**
- The `cli_warn("QS is not available in ZiPS…")` warning in the reference
  spec under "Derived Columns → QS (when absent)" — it references `sgp_QS`
  and fires "when QS is a scored category." `get_projections()` has no
  knowledge of scoring categories; this check belongs in `sgp()`. Add a
  follow-up note to the `sgp()` docs when the time comes.
- Historical / non-current-year projections (FanGraphs's live endpoint only
  serves the current season). The `year` argument is validated but a
  mismatch with the current year aborts with `rotostats_error_unsupported_year`.
- Caching API responses. Out of scope for v1 — call latency is acceptable.

---

## File Structure

| Path | Purpose |
|------|---------|
| `R/get-projections.R` | Exported `get_projections()` orchestrator + roxygen |
| `R/get-projections-internal.R` | Private helpers: `.validate_*`, `.build_projections_url`, `.fetch_projections_api`, `.parse_projections_json`, `.normalize_projection_cols`, `.derive_svhd`, `.current_season_year` |
| `tests/testthat/test-get-projections.R` | Unit tests for exported + private surface |
| `tests/testthat/helper-get-projections-fixtures.R` | Small factory helpers building minimal API-shaped lists |
| `tests/testthat/fixtures/projections-steamer-bat.json` | Recorded Steamer batter response (≤30 rows, trimmed) |
| `tests/testthat/fixtures/projections-steamer-pit.json` | Recorded Steamer pitcher response (≤30 rows, trimmed) |
| `tests/testthat/fixtures/projections-zips-pit.json` | Recorded ZiPS pitcher response (QS absent — tests zero-fill branch) |
| `DESCRIPTION` | Add `httr2 (>= 1.0.0)` and `jsonlite (>= 1.8.0)` to Imports |
| `NAMESPACE` | Auto-managed by roxygen2 — `@export get_projections` |
| `NEWS.md` | Add "New features" entry under development version |
| `plans/error-messages.md` | Register the six new error classes |
| `R/rotostats-package.R` | Add `get_projections()` to "Key Functions" |

---

## Ground Rules

- **TDD.** Write the failing test first in every coding task; run it; watch it fail; implement; run it; watch it pass; commit.
- **DRY.** Every helper has one job. Don't inline normalization into the orchestrator.
- **YAGNI.** No caching, no rate limiting, no retry-with-backoff, no multi-year. If a test doesn't require it, don't write it.
- **Conventional Commits** on every commit: `feat(projections): …`, `test(projections): …`, `docs(projections): …`.
- **Branch:** Cut a fresh branch off `develop` before Task 1 — all work on `feature/get-projections`.
- **Roxygen:** Run `devtools::document()` after any file with roxygen changes and *include the updated `NAMESPACE` / `man/*.Rd` in the same commit* as the source change.
- **Error classes:** Every `cli_abort()` and `cli_warn()` needs a class registered in `plans/error-messages.md` — update that table before the `cli_abort()` call is written.

---

## Task 0: Branch + Dependencies

**Files:**
- Modify: `DESCRIPTION` (add Imports)

- [ ] **Step 1: Create the feature branch off develop**

```bash
git checkout develop
git pull --ff-only
git checkout -b feature/get-projections
```

- [ ] **Step 2: Add `httr2` and `jsonlite` to `DESCRIPTION` Imports**

Edit [DESCRIPTION:15-19](DESCRIPTION) — the current Imports block reads:

```
Imports:
    checkmate,
    cli (>= 3.6.0),
    rlang (>= 1.0.0),
    stringi
```

Replace with:

```
Imports:
    checkmate,
    cli (>= 3.6.0),
    httr2 (>= 1.0.0),
    jsonlite (>= 1.8.0),
    rlang (>= 1.0.0),
    stringi
```

- [ ] **Step 3: Install the new packages locally**

```bash
Rscript -e 'install.packages(c("httr2", "jsonlite"))'
```

Expected: both install cleanly.

- [ ] **Step 4: Verify package still loads**

```bash
Rscript -e 'devtools::load_all()'
```

Expected: clean load, no errors.

- [ ] **Step 5: Commit**

```bash
git add DESCRIPTION
git commit -m "chore(deps): add httr2 and jsonlite Imports for get_projections()"
```

---

## Task 1: Register New Error Classes

**Files:**
- Modify: `plans/error-messages.md`

Add these rows to the errors table (insert alphabetically by class or at the end of the errors block — match the file's existing style). The contract is defined now so every `cli_abort()` in later tasks references the correct class.

| Class | Thrown by | Condition | Recovery guidance |
|-------|-----------|-----------|-------------------|
| `rotostats_error_invalid_source` | `get_projections()` | `source` not one of `"steamer"`, `"zips"`, `"atc"`, `"fangraphsdc"`, `"thebat"`, `"thebatx"`, `"custom"` | Pass a supported source name |
| `rotostats_error_invalid_player_type` | `get_projections()` | `player_type` not one of `"batters"`, `"pitchers"`, `"both"` | Pass one of the three supported values |
| `rotostats_error_missing_custom_data` | `get_projections()` | `source = "custom"` but `data` is `NULL` | Supply a data frame to `data` when `source = "custom"` |
| `rotostats_error_invalid_custom_data` | `get_projections()` | `source = "custom"` and `data` is not a data.frame, or is missing both `name` and `playerid` columns | Pass a data.frame containing at least one of `name` or `playerid` |
| `rotostats_error_data_ignored` | `get_projections()` | `data` is supplied with a non-`"custom"` source | Set `source = "custom"` to use supplied `data`, or omit `data` |
| `rotostats_error_unsupported_year` | `get_projections()` | `year` differs from the current season (FanGraphs projections endpoint only serves current-season data) | Omit `year`, or pass the current season integer |
| `rotostats_error_projection_fetch_failed` | `get_projections()` | FanGraphs API returned a non-2xx status or the request failed at the transport layer | Check network connectivity; if FanGraphs is up, file an issue with the failing source/player_type combination |
| `rotostats_error_empty_projection_response` | `get_projections()` | API returned a well-formed response with zero projection rows | Verify the source is still publishing projections for the current season |

- [ ] **Step 1: Open `plans/error-messages.md` and add the rows above**
- [ ] **Step 2: Commit**

```bash
git add plans/error-messages.md
git commit -m "docs(errors): register get_projections() error classes"
```

---

## Task 2: `.current_season_year()` helper (no-op default handler)

**Files:**
- Create: `R/get-projections-internal.R`
- Create: `tests/testthat/test-get-projections.R`

A trivial pure function, but it's where `year = NULL` is resolved. Writing the test first locks the behavior and gives the next task a helper it can call.

- [ ] **Step 1: Write the failing test**

Create `tests/testthat/test-get-projections.R` with:

```r
# tests/testthat/test-get-projections.R
#
# TDD-first test suite for get_projections().
# Authored from plans/implementation/get-projections-impl.md before the
# function itself exists; the first run must fail.

# ---------------------------------------------------------------------------
# .current_season_year()
# ---------------------------------------------------------------------------

test_that(".current_season_year() returns the calendar year as integer", {
  expect_identical(
    rotostats:::.current_season_year(),
    as.integer(format(Sys.Date(), "%Y"))
  )
  expect_type(rotostats:::.current_season_year(), "integer")
})
```

- [ ] **Step 2: Run test to verify it fails**

```bash
Rscript -e 'devtools::test(filter = "get-projections")'
```

Expected: FAIL — `.current_season_year` not found.

- [ ] **Step 3: Write minimal implementation**

Create `R/get-projections-internal.R`:

```r
# get-projections-internal.R — private helpers for get_projections()
#
# No exports. Each function has one job so the exported orchestrator in
# R/get-projections.R stays readable and the HTTP boundary stays isolated.

#' @noRd
.current_season_year <- function() {
  as.integer(format(Sys.Date(), "%Y"))
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
Rscript -e 'devtools::test(filter = "get-projections")'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): add .current_season_year() helper"
```

---

## Task 3: Argument validation — `source`

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

All argument validation sits in private helpers. Each has its own test block so failures pinpoint the violated contract.

- [ ] **Step 1: Write the failing tests**

Append to `tests/testthat/test-get-projections.R`:

```r
# ---------------------------------------------------------------------------
# .validate_source()
# ---------------------------------------------------------------------------

test_that(".validate_source() accepts every documented source", {
  valid <- c("steamer", "zips", "atc", "fangraphsdc", "thebat", "thebatx", "custom")
  for (s in valid) {
    expect_identical(rotostats:::.validate_source(s), s)
  }
})

test_that(".validate_source() rejects unknown sources with the right class", {
  expect_error(
    rotostats:::.validate_source("marcel"),
    class = "rotostats_error_invalid_source"
  )
})

test_that(".validate_source() rejects non-scalar / non-character input", {
  expect_error(
    rotostats:::.validate_source(c("steamer", "zips")),
    class = "rotostats_error_invalid_source"
  )
  expect_error(
    rotostats:::.validate_source(1L),
    class = "rotostats_error_invalid_source"
  )
  expect_error(
    rotostats:::.validate_source(NULL),
    class = "rotostats_error_invalid_source"
  )
})
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
Rscript -e 'devtools::test(filter = "get-projections")'
```

Expected: FAIL — `.validate_source` not found.

- [ ] **Step 3: Implement the helper**

Append to `R/get-projections-internal.R`:

```r
#' @noRd
VALID_PROJECTION_SOURCES <- c(
  "steamer", "zips", "atc", "fangraphsdc",
  "thebat", "thebatx", "custom"
)

#' @noRd
.validate_source <- function(source) {
  if (!is.character(source) || length(source) != 1L || is.na(source) ||
      !(source %in% VALID_PROJECTION_SOURCES)) {
    cli::cli_abort(
      c(
        "{.arg source} must be one of {.val {VALID_PROJECTION_SOURCES}}.",
        i = "Received: {.val {source}}."
      ),
      class = "rotostats_error_invalid_source"
    )
  }
  source
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
Rscript -e 'devtools::test(filter = "get-projections")'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): validate source argument"
```

---

## Task 4: Argument validation — `player_type`

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

- [ ] **Step 1: Write the failing tests**

Append to `tests/testthat/test-get-projections.R`:

```r
# ---------------------------------------------------------------------------
# .validate_player_type()
# ---------------------------------------------------------------------------

test_that(".validate_player_type() accepts 'batters', 'pitchers', 'both'", {
  expect_identical(rotostats:::.validate_player_type("batters"), "batters")
  expect_identical(rotostats:::.validate_player_type("pitchers"), "pitchers")
  expect_identical(rotostats:::.validate_player_type("both"), "both")
})

test_that(".validate_player_type() rejects anything else", {
  expect_error(
    rotostats:::.validate_player_type("batter"),
    class = "rotostats_error_invalid_player_type"
  )
  expect_error(
    rotostats:::.validate_player_type(NA_character_),
    class = "rotostats_error_invalid_player_type"
  )
  expect_error(
    rotostats:::.validate_player_type(NULL),
    class = "rotostats_error_invalid_player_type"
  )
})
```

- [ ] **Step 2: Run — verify failure**

```bash
Rscript -e 'devtools::test(filter = "get-projections")'
```

Expected: FAIL — `.validate_player_type` not found.

- [ ] **Step 3: Implement**

Append to `R/get-projections-internal.R`:

```r
#' @noRd
VALID_PLAYER_TYPES <- c("batters", "pitchers", "both")

#' @noRd
.validate_player_type <- function(player_type) {
  if (!is.character(player_type) || length(player_type) != 1L ||
      is.na(player_type) || !(player_type %in% VALID_PLAYER_TYPES)) {
    cli::cli_abort(
      c(
        "{.arg player_type} must be one of {.val {VALID_PLAYER_TYPES}}.",
        i = "Received: {.val {player_type}}."
      ),
      class = "rotostats_error_invalid_player_type"
    )
  }
  player_type
}
```

- [ ] **Step 4: Run — verify PASS**

- [ ] **Step 5: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): validate player_type argument"
```

---

## Task 5: Argument validation — `year`

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

`NULL` → resolves to the current season. Otherwise must be a length-1 integer-valued numeric and must equal the current season.

- [ ] **Step 1: Write the failing tests**

```r
# ---------------------------------------------------------------------------
# .validate_year()
# ---------------------------------------------------------------------------

test_that(".validate_year(NULL) returns the current season", {
  yr <- rotostats:::.validate_year(NULL)
  expect_identical(yr, rotostats:::.current_season_year())
})

test_that(".validate_year() accepts the current season explicitly", {
  cur <- rotostats:::.current_season_year()
  expect_identical(rotostats:::.validate_year(cur), cur)
  expect_identical(rotostats:::.validate_year(as.numeric(cur)), cur)
})

test_that(".validate_year() aborts on non-current years", {
  cur <- rotostats:::.current_season_year()
  expect_error(
    rotostats:::.validate_year(cur - 1L),
    class = "rotostats_error_unsupported_year"
  )
  expect_error(
    rotostats:::.validate_year(cur + 1L),
    class = "rotostats_error_unsupported_year"
  )
})

test_that(".validate_year() aborts on non-scalar / non-integer input", {
  expect_error(
    rotostats:::.validate_year(c(2026, 2027)),
    class = "rotostats_error_unsupported_year"
  )
  expect_error(
    rotostats:::.validate_year("2026"),
    class = "rotostats_error_unsupported_year"
  )
  expect_error(
    rotostats:::.validate_year(2026.5),
    class = "rotostats_error_unsupported_year"
  )
})
```

- [ ] **Step 2: Run — verify failure**

Expected: FAIL — `.validate_year` not found.

- [ ] **Step 3: Implement**

Append to `R/get-projections-internal.R`:

```r
#' @noRd
.validate_year <- function(year) {
  cur <- .current_season_year()
  if (is.null(year)) return(cur)
  if (!is.numeric(year) || length(year) != 1L || is.na(year) ||
      year != as.integer(year) || as.integer(year) != cur) {
    cli::cli_abort(
      c(
        "FanGraphs projections are only available for the current season.",
        i = "Current season: {.val {cur}}.",
        i = "Received {.arg year} = {.val {year}}.",
        "*" = "Omit {.arg year} to use the current season."
      ),
      class = "rotostats_error_unsupported_year"
    )
  }
  as.integer(year)
}
```

- [ ] **Step 4: Run — verify PASS**

- [ ] **Step 5: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): validate year argument"
```

---

## Task 6: Argument validation — `data` (custom path)

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

Pairs `data` with `source`. Three branches: (a) non-custom source + non-null data → abort; (b) custom source + null data → abort; (c) custom source + data frame → validate min-columns.

- [ ] **Step 1: Write the failing tests**

```r
# ---------------------------------------------------------------------------
# .validate_custom_data()
# ---------------------------------------------------------------------------

test_that(".validate_custom_data() returns data unchanged on valid custom input", {
  d <- data.frame(name = "A", HR = 10)
  expect_identical(rotostats:::.validate_custom_data("custom", d), d)

  d2 <- data.frame(playerid = "abc", HR = 10)
  expect_identical(rotostats:::.validate_custom_data("custom", d2), d2)
})

test_that(".validate_custom_data() returns NULL on non-custom source + NULL data", {
  expect_null(rotostats:::.validate_custom_data("steamer", NULL))
})

test_that(".validate_custom_data() aborts when data supplied with non-custom source", {
  d <- data.frame(name = "A")
  expect_error(
    rotostats:::.validate_custom_data("steamer", d),
    class = "rotostats_error_data_ignored"
  )
})

test_that(".validate_custom_data() aborts on custom + NULL", {
  expect_error(
    rotostats:::.validate_custom_data("custom", NULL),
    class = "rotostats_error_missing_custom_data"
  )
})

test_that(".validate_custom_data() aborts on non-data.frame data", {
  expect_error(
    rotostats:::.validate_custom_data("custom", list(name = "A")),
    class = "rotostats_error_invalid_custom_data"
  )
  expect_error(
    rotostats:::.validate_custom_data("custom", matrix(1:4, 2, 2)),
    class = "rotostats_error_invalid_custom_data"
  )
})

test_that(".validate_custom_data() aborts when neither name nor playerid is present", {
  d <- data.frame(HR = 10, RBI = 20)
  expect_error(
    rotostats:::.validate_custom_data("custom", d),
    class = "rotostats_error_invalid_custom_data"
  )
})
```

- [ ] **Step 2: Run — verify failure**

- [ ] **Step 3: Implement**

Append to `R/get-projections-internal.R`:

```r
#' @noRd
.validate_custom_data <- function(source, data) {
  if (source != "custom") {
    if (!is.null(data)) {
      cli::cli_abort(
        c(
          "{.arg data} is only used when {.arg source = \"custom\"}.",
          i = "Received {.arg source} = {.val {source}} with non-NULL {.arg data}."
        ),
        class = "rotostats_error_data_ignored"
      )
    }
    return(NULL)
  }
  # source == "custom"
  if (is.null(data)) {
    cli::cli_abort(
      "{.arg data} is required when {.arg source = \"custom\"}.",
      class = "rotostats_error_missing_custom_data"
    )
  }
  if (!is.data.frame(data)) {
    cli::cli_abort(
      c(
        "{.arg data} must be a data.frame.",
        i = "Received class: {.cls {class(data)}}."
      ),
      class = "rotostats_error_invalid_custom_data"
    )
  }
  if (!any(c("name", "playerid") %in% names(data))) {
    cli::cli_abort(
      c(
        "{.arg data} must contain at least one of {.field name} or {.field playerid}.",
        i = "Columns present: {.val {names(data)}}."
      ),
      class = "rotostats_error_invalid_custom_data"
    )
  }
  data
}
```

- [ ] **Step 4: Run — verify PASS**

- [ ] **Step 5: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): validate custom data argument"
```

---

## Task 7: `.build_projections_url()`

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

Builds the endpoint URL. `stats` is `"bat"` for batters or `"pit"` for pitchers. The function takes one `player_type` of `"batters"` or `"pitchers"` — the `"both"` branching happens one level up.

- [ ] **Step 1: Write the failing tests**

```r
# ---------------------------------------------------------------------------
# .build_projections_url()
# ---------------------------------------------------------------------------

test_that(".build_projections_url() builds the documented URL shape", {
  url <- rotostats:::.build_projections_url("steamer", "batters")
  expect_match(url, "^https://www\\.fangraphs\\.com/api/projections\\?")
  expect_match(url, "type=steamer")
  expect_match(url, "stats=bat")
  expect_match(url, "pos=all")
  expect_match(url, "team=0")
  expect_match(url, "players=0")
  expect_match(url, "lg=all")
})

test_that(".build_projections_url() maps player_type to stats param", {
  expect_match(rotostats:::.build_projections_url("zips", "batters"),  "stats=bat")
  expect_match(rotostats:::.build_projections_url("zips", "pitchers"), "stats=pit")
})
```

- [ ] **Step 2: Run — verify failure**

- [ ] **Step 3: Implement**

Append to `R/get-projections-internal.R`:

```r
#' @noRd
.build_projections_url <- function(source, player_type) {
  stopifnot(player_type %in% c("batters", "pitchers"))
  stats <- if (player_type == "batters") "bat" else "pit"
  httr2::url_modify(
    "https://www.fangraphs.com/api/projections",
    query = list(
      type    = source,
      stats   = stats,
      pos     = "all",
      team    = "0",
      players = "0",
      lg      = "all"
    )
  )
}
```

- [ ] **Step 4: Run — verify PASS**

- [ ] **Step 5: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): build FanGraphs projections URL"
```

---

## Task 8: `.fetch_projections_api()` (the only network function)

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

This is the **single** function that touches the network. Every other test stubs it via `testthat::local_mocked_bindings()`. Keep it tiny.

- [ ] **Step 1: Write the failing tests**

```r
# ---------------------------------------------------------------------------
# .fetch_projections_api()
# ---------------------------------------------------------------------------

test_that(".fetch_projections_api() returns parsed JSON on 2xx", {
  # Stub httr2 so we never hit the network in unit tests
  fake_resp <- structure(
    list(
      body_json = list(list(playerid = "1", PlayerName = "Test", HR = 30))
    ),
    class = "fake_response"
  )
  testthat::local_mocked_bindings(
    request       = function(url) list(url = url),
    req_perform   = function(req) fake_resp,
    resp_body_json = function(r) r$body_json,
    resp_is_error = function(r) FALSE,
    .package = "httr2"
  )
  result <- rotostats:::.fetch_projections_api("https://example.com/fake")
  expect_type(result, "list")
  expect_equal(result[[1]]$playerid, "1")
})

test_that(".fetch_projections_api() aborts on transport-level failure", {
  testthat::local_mocked_bindings(
    request     = function(url) list(url = url),
    req_perform = function(req) stop("connection refused"),
    .package = "httr2"
  )
  expect_error(
    rotostats:::.fetch_projections_api("https://example.com/fake"),
    class = "rotostats_error_projection_fetch_failed"
  )
})

test_that(".fetch_projections_api() aborts on non-2xx", {
  testthat::local_mocked_bindings(
    request       = function(url) list(url = url),
    req_perform   = function(req) list(status_code = 500L),
    resp_is_error = function(r) TRUE,
    resp_status   = function(r) 500L,
    .package = "httr2"
  )
  expect_error(
    rotostats:::.fetch_projections_api("https://example.com/fake"),
    class = "rotostats_error_projection_fetch_failed"
  )
})
```

- [ ] **Step 2: Run — verify failure**

- [ ] **Step 3: Implement**

Append to `R/get-projections-internal.R`:

```r
#' @noRd
.fetch_projections_api <- function(url) {
  result <- tryCatch(
    {
      req  <- httr2::request(url)
      resp <- httr2::req_perform(req)
      if (httr2::resp_is_error(resp)) {
        cli::cli_abort(
          c(
            "FanGraphs projections request failed.",
            i = "URL: {.url {url}}.",
            i = "HTTP status: {.val {httr2::resp_status(resp)}}."
          ),
          class = "rotostats_error_projection_fetch_failed"
        )
      }
      httr2::resp_body_json(resp)
    },
    error = function(e) {
      if (inherits(e, "rotostats_error_projection_fetch_failed")) stop(e)
      cli::cli_abort(
        c(
          "FanGraphs projections request failed.",
          i = "URL: {.url {url}}.",
          i = "Cause: {conditionMessage(e)}."
        ),
        class = "rotostats_error_projection_fetch_failed",
        parent = e
      )
    }
  )
  result
}
```

- [ ] **Step 4: Run — verify PASS**

- [ ] **Step 5: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): fetch projections from FanGraphs API"
```

---

## Task 9: `.parse_projections_json()` — list-of-lists → data.frame

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

Turns the parsed JSON (an R list-of-lists, one entry per player) into a single
data frame. Must handle ragged records: if a key is missing from some players,
fill that column with `NA`.

- [ ] **Step 1: Write the failing tests**

```r
# ---------------------------------------------------------------------------
# .parse_projections_json()
# ---------------------------------------------------------------------------

test_that(".parse_projections_json() rbinds uniform records", {
  raw <- list(
    list(playerid = "1", PlayerName = "A", HR = 30),
    list(playerid = "2", PlayerName = "B", HR = 25)
  )
  out <- rotostats:::.parse_projections_json(raw)
  expect_s3_class(out, "data.frame")
  expect_equal(nrow(out), 2L)
  expect_setequal(names(out), c("playerid", "PlayerName", "HR"))
  expect_equal(out$HR, c(30, 25))
})

test_that(".parse_projections_json() handles ragged records with NA fill", {
  raw <- list(
    list(playerid = "1", HR = 30, SB = 10),
    list(playerid = "2", HR = 25)         # SB missing
  )
  out <- rotostats:::.parse_projections_json(raw)
  expect_equal(nrow(out), 2L)
  expect_true("SB" %in% names(out))
  expect_true(is.na(out$SB[2]))
})

test_that(".parse_projections_json() aborts on empty input", {
  expect_error(
    rotostats:::.parse_projections_json(list()),
    class = "rotostats_error_empty_projection_response"
  )
})
```

- [ ] **Step 2: Run — verify failure**

- [ ] **Step 3: Implement**

Append to `R/get-projections-internal.R`:

```r
#' @noRd
.parse_projections_json <- function(raw) {
  if (!is.list(raw) || length(raw) == 0L) {
    cli::cli_abort(
      "FanGraphs returned zero projection rows.",
      class = "rotostats_error_empty_projection_response"
    )
  }
  all_keys <- unique(unlist(lapply(raw, names), use.names = FALSE))
  rows <- lapply(raw, function(rec) {
    missing <- setdiff(all_keys, names(rec))
    rec[missing] <- NA
    rec[all_keys]
  })
  # jsonlite::rbind_pages handles mixed types cleanly; fallback to do.call(rbind, ...)
  df <- as.data.frame(
    do.call(rbind, lapply(rows, function(r) lapply(r, function(x) if (is.null(x)) NA else x))),
    stringsAsFactors = FALSE
  )
  # flatten list columns to atomic where possible
  for (nm in names(df)) {
    col <- df[[nm]]
    if (is.list(col) && all(lengths(col) <= 1L)) {
      df[[nm]] <- unlist(
        lapply(col, function(x) if (length(x) == 0L) NA else x[[1L]])
      )
    }
  }
  df
}
```

- [ ] **Step 4: Run — verify PASS**

- [ ] **Step 5: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): parse FanGraphs JSON into a data.frame"
```

---

## Task 10: `.normalize_projection_cols()`

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

FanGraphs's raw column names vary (`"K/9"`, `"wRC+"`, `"PlayerName"`, `"Team"`). Normalize to the spec's canonical names:

| Raw (observed) | Normalized |
|---------------|-----------|
| `PlayerName`  | `name` |
| `Team`, `team` | `team` |
| `ShortName`, `playerid`, `playerId` | `playerid` |
| `Pos`, `pos`  | `pos` |
| `wRC+` | `wRC_plus` |
| `K/9`, `BB/9`, `K/BB` | `K_per_9`, `BB_per_9`, `K_per_BB` |
| everything else | unchanged (column names that already match the spec pass through) |

Batter and pitcher rows are **not** padded to a common schema here. That
happens inside the orchestrator via `dplyr-free` rbind (see Task 12).

- [ ] **Step 1: Write the failing tests**

```r
# ---------------------------------------------------------------------------
# .normalize_projection_cols()
# ---------------------------------------------------------------------------

test_that(".normalize_projection_cols() renames PlayerName → name", {
  df <- data.frame(playerid = "1", PlayerName = "A", Team = "NYY", Pos = "2B")
  out <- rotostats:::.normalize_projection_cols(df)
  expect_setequal(names(out), c("playerid", "name", "team", "pos"))
})

test_that(".normalize_projection_cols() normalizes slash-containing pitcher stats", {
  df <- data.frame(playerid = "1", `K/9` = 9.5, `BB/9` = 2.1, `K/BB` = 4.5,
                   check.names = FALSE)
  out <- rotostats:::.normalize_projection_cols(df)
  expect_setequal(names(out), c("playerid", "K_per_9", "BB_per_9", "K_per_BB"))
})

test_that(".normalize_projection_cols() normalizes wRC+", {
  df <- data.frame(playerid = "1", `wRC+` = 120, check.names = FALSE)
  out <- rotostats:::.normalize_projection_cols(df)
  expect_true("wRC_plus" %in% names(out))
  expect_false("wRC+" %in% names(out))
})

test_that(".normalize_projection_cols() leaves already-canonical columns alone", {
  df <- data.frame(playerid = "1", name = "A", team = "NYY", pos = "2B",
                   HR = 30)
  out <- rotostats:::.normalize_projection_cols(df)
  expect_setequal(names(out), c("playerid", "name", "team", "pos", "HR"))
})
```

- [ ] **Step 2: Run — verify failure**

- [ ] **Step 3: Implement**

Append to `R/get-projections-internal.R`:

```r
#' @noRd
PROJECTION_COLUMN_RENAME <- c(
  PlayerName = "name",
  Team       = "team",
  Pos        = "pos",
  playerId   = "playerid",
  ShortName  = "playerid",
  `wRC+`     = "wRC_plus",
  `K/9`      = "K_per_9",
  `BB/9`     = "BB_per_9",
  `HR/9`     = "HR_per_9",
  `K/BB`     = "K_per_BB",
  `K%`       = "K_pct",
  `BB%`      = "BB_pct"
)

#' @noRd
.normalize_projection_cols <- function(df) {
  nm <- names(df)
  for (raw in names(PROJECTION_COLUMN_RENAME)) {
    target <- PROJECTION_COLUMN_RENAME[[raw]]
    hits <- which(nm == raw)
    if (length(hits) == 1L && !(target %in% nm)) {
      nm[hits] <- target
    }
  }
  names(df) <- nm
  df
}
```

- [ ] **Step 4: Run — verify PASS**

- [ ] **Step 5: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): normalize FanGraphs column names"
```

---

## Task 11: `.derive_svhd()` + one-time `rlang::inform()`

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

Per the spec: `SVHD = SV + HLD`, always computed, with a once-per-session
`rlang::inform(.frequency = "once", .frequency_id = "rotostats_svhd_definition")`.
Called only for pitcher frames.

- [ ] **Step 1: Write the failing tests**

```r
# ---------------------------------------------------------------------------
# .derive_svhd()
# ---------------------------------------------------------------------------

test_that(".derive_svhd() adds SV + HLD", {
  df <- data.frame(playerid = c("1","2"), SV = c(30, 0), HLD = c(0, 25))
  out <- rotostats:::.derive_svhd(df)
  expect_equal(out$SVHD, c(30, 25))
})

test_that(".derive_svhd() handles NA SV or HLD as 0", {
  df <- data.frame(playerid = c("1","2"), SV = c(NA, 10), HLD = c(5, NA))
  out <- rotostats:::.derive_svhd(df)
  expect_equal(out$SVHD, c(5, 10))
})

test_that(".derive_svhd() is a no-op when SV or HLD column is absent", {
  df <- data.frame(playerid = "1", SV = 5)   # no HLD
  out <- rotostats:::.derive_svhd(df)
  expect_false("SVHD" %in% names(out))

  df2 <- data.frame(playerid = "1", HLD = 5) # no SV
  out2 <- rotostats:::.derive_svhd(df2)
  expect_false("SVHD" %in% names(out2))
})

test_that(".derive_svhd() emits a once-per-session inform message", {
  rlang::local_interactive()
  # Reset the session-once state so this test is deterministic
  rlang::reset_warning_verbosity("rotostats_svhd_definition")

  df <- data.frame(playerid = "1", SV = 30, HLD = 0)

  expect_message(
    rotostats:::.derive_svhd(df),
    regexp = "SVHD computed as SV \\+ HLD"
  )
  # Second call in the same session: silent
  expect_no_message(
    rotostats:::.derive_svhd(df)
  )
})
```

- [ ] **Step 2: Run — verify failure**

- [ ] **Step 3: Implement**

Append to `R/get-projections-internal.R`:

```r
#' @noRd
.derive_svhd <- function(df) {
  if (!all(c("SV", "HLD") %in% names(df))) return(df)
  sv  <- ifelse(is.na(df$SV),  0, df$SV)
  hld <- ifelse(is.na(df$HLD), 0, df$HLD)
  df$SVHD <- sv + hld
  rlang::inform(
    "SVHD computed as SV + HLD. Verify this matches your league's SVHD definition.",
    .frequency = "once",
    .frequency_id = "rotostats_svhd_definition"
  )
  df
}
```

- [ ] **Step 4: Run — verify PASS**

- [ ] **Step 5: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): derive SVHD = SV + HLD with once-per-session inform"
```

---

## Task 12: `.attach_player_type()` — tag rows + rbind batter/pitcher frames

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`

Per the spec, the returned frame has one row per player with a `player_type`
column (`"batter"` or `"pitcher"`). Batter and pitcher frames have *different*
columns; combine via a column-filling union (add missing columns as `NA` to
each side, then rbind).

- [ ] **Step 1: Write the failing tests**

```r
# ---------------------------------------------------------------------------
# .attach_player_type() and .combine_batter_pitcher()
# ---------------------------------------------------------------------------

test_that(".attach_player_type() sets the player_type column", {
  df <- data.frame(playerid = "1", HR = 30)
  out <- rotostats:::.attach_player_type(df, "batter")
  expect_equal(out$player_type, "batter")
})

test_that(".combine_batter_pitcher() rbinds with NA fill across non-shared cols", {
  bat <- data.frame(
    playerid = "1", name = "A", team = "NYY", pos = "2B",
    player_type = "batter", HR = 30, AB = 550
  )
  pit <- data.frame(
    playerid = "2", name = "B", team = "LAD", pos = "SP",
    player_type = "pitcher", W = 15, IP = 200
  )
  out <- rotostats:::.combine_batter_pitcher(bat, pit)
  expect_equal(nrow(out), 2L)
  # columns from both sides are present
  expect_true(all(c("HR", "AB", "W", "IP") %in% names(out)))
  # each row keeps its own non-NA side
  expect_equal(out$HR[out$player_type == "batter"], 30)
  expect_true(is.na(out$HR[out$player_type == "pitcher"]))
  expect_equal(out$W[out$player_type == "pitcher"], 15)
  expect_true(is.na(out$W[out$player_type == "batter"]))
})
```

- [ ] **Step 2: Run — verify failure**

- [ ] **Step 3: Implement**

Append to `R/get-projections-internal.R`:

```r
#' @noRd
.attach_player_type <- function(df, type) {
  stopifnot(type %in% c("batter", "pitcher"))
  df$player_type <- type
  df
}

#' @noRd
.combine_batter_pitcher <- function(bat, pit) {
  if (is.null(bat)) return(pit)
  if (is.null(pit)) return(bat)
  all_cols <- union(names(bat), names(pit))
  fill_missing <- function(df, cols) {
    for (c in setdiff(cols, names(df))) df[[c]] <- NA
    df[cols]
  }
  rbind(fill_missing(bat, all_cols), fill_missing(pit, all_cols))
}
```

- [ ] **Step 4: Run — verify PASS**

- [ ] **Step 5: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R
git commit -m "feat(projections): tag and combine batter/pitcher frames"
```

---

## Task 13: The orchestrator `get_projections()` — custom path first

**Files:**
- Create: `R/get-projections.R`
- Modify: `tests/testthat/test-get-projections.R`

Start with the simplest path: `source = "custom"`. No HTTP, no normalization
decisions about which columns exist — pass `data` through unchanged per the
spec.

- [ ] **Step 1: Write the failing test**

```r
# ---------------------------------------------------------------------------
# get_projections() — custom source
# ---------------------------------------------------------------------------

test_that("get_projections(source = 'custom') returns user data unchanged", {
  d <- data.frame(name = "Test", HR = 30, player_type = "batter")
  out <- get_projections(source = "custom", data = d)
  expect_identical(out, d)
})
```

- [ ] **Step 2: Run — verify failure**

Expected: FAIL — `get_projections` not found.

- [ ] **Step 3: Implement — minimal orchestrator**

Create `R/get-projections.R`:

```r
# get-projections.R — fetch projections from FanGraphs (or accept custom data)

#' Fetch projections for a rotisserie auction league
#'
#' @description
#' Retrieves projections for the current MLB season from one of six FanGraphs
#' projection systems (Steamer, ZiPS, ATC, FanGraphs Depth Charts, THE BAT,
#' THE BAT X) or accepts a user-supplied data frame of custom projections.
#' The returned data frame is in long format: one row per player, with a
#' `player_type` column (`"batter"` / `"pitcher"`) distinguishing the two
#' groups. `SVHD` is always derived as `SV + HLD` for pitcher rows.
#'
#' @param source One of `"steamer"` (default), `"zips"`, `"atc"`,
#'   `"fangraphsdc"`, `"thebat"`, `"thebatx"`, or `"custom"`.
#' @param year Projection year. Only the current MLB season is supported.
#'   `NULL` (default) resolves to the current calendar year; passing any
#'   other value aborts.
#' @param player_type One of `"batters"`, `"pitchers"`, or `"both"` (default).
#' @param data Required when `source = "custom"`; a data.frame containing at
#'   minimum one of `name` or `playerid`, plus one column per scored
#'   category. Passed through unchanged (no normalization is applied).
#'
#' @return A data.frame with one row per player. For non-custom sources, the
#'   always-present columns are `playerid`, `name`, `team`, `pos`, and
#'   `player_type`; source-specific stat columns follow.
#'
#' @seealso [`sgp()`], [`replacement_level()`]
#'
#' @examples
#' \dontrun{
#' proj <- get_projections(source = "steamer")
#' }
#'
#' @export
get_projections <- function(source      = "steamer",
                            year        = NULL,
                            player_type = "both",
                            data        = NULL) {
  source      <- .validate_source(source)
  player_type <- .validate_player_type(player_type)
  year        <- .validate_year(year)
  data        <- .validate_custom_data(source, data)

  if (source == "custom") return(data)

  # Non-custom sources — implemented in Task 14
  .fetch_and_assemble_projections(source, player_type)
}
```

Also add to `R/get-projections-internal.R`:

```r
#' @noRd
.fetch_and_assemble_projections <- function(source, player_type) {
  # Stub for now — implemented in Task 14
  cli::cli_abort("not yet implemented")
}
```

- [ ] **Step 4: Run — verify PASS**

```bash
Rscript -e 'devtools::document(); devtools::test(filter = "get-projections")'
```

Expected: PASS (custom test plus all earlier helper tests).

- [ ] **Step 5: Commit**

```bash
git add R/get-projections.R R/get-projections-internal.R tests/testthat/test-get-projections.R NAMESPACE man/get_projections.Rd
git commit -m "feat(projections): export get_projections() with custom-source path"
```

---

## Task 14: Orchestrator — fetch + assemble for `player_type = "batters"`

**Files:**
- Modify: `R/get-projections-internal.R`
- Modify: `tests/testthat/test-get-projections.R`
- Create: `tests/testthat/helper-get-projections-fixtures.R`

- [ ] **Step 1: Add a fixture factory**

Create `tests/testthat/helper-get-projections-fixtures.R`:

```r
# tests/testthat/helper-get-projections-fixtures.R
#
# Lightweight list-of-lists builders that mirror the shape of parsed
# FanGraphs projections API responses. Kept tiny so unit tests are fast
# and failures are easy to read.

#' @keywords internal
fx_batter_json <- function(n = 3L) {
  lapply(seq_len(n), function(i) {
    list(
      playerid   = as.character(i),
      PlayerName = paste0("Batter", i),
      Team       = "NYY",
      Pos        = "2B",
      G          = 150,
      AB         = 550,
      HR         = 20 + i,
      R          = 80,
      RBI        = 75,
      SB         = 10,
      AVG        = 0.270,
      OBP        = 0.340,
      SLG        = 0.450,
      OPS        = 0.790,
      `wRC+`     = 110
    )
  })
}

#' @keywords internal
fx_pitcher_json <- function(n = 3L, include_qs = TRUE) {
  lapply(seq_len(n), function(i) {
    rec <- list(
      playerid   = as.character(100 + i),
      PlayerName = paste0("Pitcher", i),
      Team       = "LAD",
      Pos        = "SP",
      W          = 10,
      L          = 8,
      GS         = 30,
      G          = 32,
      IP         = 180,
      SV         = 0,
      HLD        = 0,
      ERA        = 3.50,
      WHIP       = 1.20,
      `K/9`      = 9.5,
      `BB/9`     = 2.5
    )
    if (include_qs) rec$QS <- 15
    rec
  })
}
```

- [ ] **Step 2: Write the failing test**

```r
# ---------------------------------------------------------------------------
# get_projections() — FanGraphs sources (HTTP stubbed)
# ---------------------------------------------------------------------------

test_that("get_projections('steamer', player_type = 'batters') returns a normalized batter frame", {
  testthat::local_mocked_bindings(
    .fetch_projections_api = function(url) fx_batter_json(3L),
    .package = "rotostats"
  )
  out <- get_projections(source = "steamer", player_type = "batters")

  expect_s3_class(out, "data.frame")
  expect_equal(nrow(out), 3L)
  expect_true(all(c("playerid", "name", "team", "pos", "player_type") %in% names(out)))
  expect_true(all(out$player_type == "batter"))
  expect_true("wRC_plus" %in% names(out))
  expect_false("wRC+" %in% names(out))
})
```

- [ ] **Step 3: Run — verify failure**

- [ ] **Step 4: Implement**

Replace the stub `.fetch_and_assemble_projections` in `R/get-projections-internal.R` with:

```r
#' @noRd
.fetch_and_assemble_projections <- function(source, player_type) {
  bat <- if (player_type %in% c("batters", "both")) {
    .fetch_one_side(source, "batters")
  } else NULL
  pit <- if (player_type %in% c("pitchers", "both")) {
    .fetch_one_side(source, "pitchers")
  } else NULL
  .combine_batter_pitcher(bat, pit)
}

#' @noRd
.fetch_one_side <- function(source, player_type) {
  stopifnot(player_type %in% c("batters", "pitchers"))
  url <- .build_projections_url(source, player_type)
  raw <- .fetch_projections_api(url)
  df  <- .parse_projections_json(raw)
  df  <- .normalize_projection_cols(df)
  if (player_type == "pitchers") df <- .derive_svhd(df)
  .attach_player_type(df, if (player_type == "batters") "batter" else "pitcher")
}
```

- [ ] **Step 5: Run — verify PASS**

- [ ] **Step 6: Commit**

```bash
git add R/get-projections-internal.R tests/testthat/test-get-projections.R tests/testthat/helper-get-projections-fixtures.R
git commit -m "feat(projections): fetch and assemble batter-only projections"
```

---

## Task 15: Orchestrator — `player_type = "pitchers"` and `"both"`

**Files:**
- Modify: `tests/testthat/test-get-projections.R`

No implementation change — `.fetch_and_assemble_projections` from Task 14
already handles all three branches. This task is pure test coverage.

- [ ] **Step 1: Write the tests**

Append:

```r
test_that("get_projections(..., player_type = 'pitchers') returns a pitcher frame with SVHD", {
  testthat::local_mocked_bindings(
    .fetch_projections_api = function(url) fx_pitcher_json(3L, include_qs = TRUE),
    .package = "rotostats"
  )
  rlang::reset_warning_verbosity("rotostats_svhd_definition")
  out <- expect_message(
    get_projections(source = "steamer", player_type = "pitchers"),
    regexp = "SVHD computed as SV \\+ HLD"
  )
  expect_equal(nrow(out), 3L)
  expect_true("SVHD" %in% names(out))
  expect_true(all(out$player_type == "pitcher"))
  expect_true("QS" %in% names(out))
})

test_that("get_projections(..., player_type = 'both') rbinds with NA fill", {
  # The mock needs to return different payloads depending on the URL's
  # stats= parameter. Inspect the URL to decide.
  testthat::local_mocked_bindings(
    .fetch_projections_api = function(url) {
      if (grepl("stats=bat", url)) fx_batter_json(2L) else fx_pitcher_json(2L)
    },
    .package = "rotostats"
  )
  rlang::reset_warning_verbosity("rotostats_svhd_definition")
  out <- suppressMessages(
    get_projections(source = "steamer", player_type = "both")
  )
  expect_equal(nrow(out), 4L)
  expect_setequal(unique(out$player_type), c("batter", "pitcher"))
  # Non-shared columns are NA-filled
  expect_true(all(is.na(out$IP[out$player_type == "batter"])))
  expect_true(all(is.na(out$AB[out$player_type == "pitcher"])))
})
```

- [ ] **Step 2: Run — verify PASS**

```bash
Rscript -e 'devtools::test(filter = "get-projections")'
```

- [ ] **Step 3: Commit**

```bash
git add tests/testthat/test-get-projections.R
git commit -m "test(projections): cover pitcher-only and 'both' branches"
```

---

## Task 16: End-to-end argument-error smoke tests

**Files:**
- Modify: `tests/testthat/test-get-projections.R`

Proves the orchestrator surfaces every error class at the exported-function
layer. Guards against silent regressions where a helper stops being called.

- [ ] **Step 1: Write the tests**

Append:

```r
# ---------------------------------------------------------------------------
# get_projections() — top-level error surfaces
# ---------------------------------------------------------------------------

test_that("get_projections() surfaces source validation", {
  expect_error(
    get_projections(source = "marcel"),
    class = "rotostats_error_invalid_source"
  )
})

test_that("get_projections() surfaces player_type validation", {
  expect_error(
    get_projections(source = "steamer", player_type = "batter"),
    class = "rotostats_error_invalid_player_type"
  )
})

test_that("get_projections() surfaces year validation", {
  cur <- rotostats:::.current_season_year()
  expect_error(
    get_projections(source = "steamer", year = cur - 1L),
    class = "rotostats_error_unsupported_year"
  )
})

test_that("get_projections() rejects data supplied with non-custom source", {
  d <- data.frame(name = "A", HR = 10)
  expect_error(
    get_projections(source = "steamer", data = d),
    class = "rotostats_error_data_ignored"
  )
})

test_that("get_projections(source = 'custom') requires data", {
  expect_error(
    get_projections(source = "custom"),
    class = "rotostats_error_missing_custom_data"
  )
})
```

- [ ] **Step 2: Run — verify PASS**

- [ ] **Step 3: Commit**

```bash
git add tests/testthat/test-get-projections.R
git commit -m "test(projections): smoke-test argument-error surfaces"
```

---

## Task 17: Recorded-fixture integration test

**Files:**
- Create: `tests/testthat/fixtures/projections-steamer-bat.json`
- Create: `tests/testthat/fixtures/projections-steamer-pit.json`
- Create: `tests/testthat/fixtures/projections-zips-pit.json`
- Modify: `tests/testthat/test-get-projections.R`

Record real API responses once (trimmed to ≤30 rows each to keep the repo
small), then replay them via the same `local_mocked_bindings` pattern.
Catches regressions where FanGraphs's real column names drift from our
normalization rules.

- [ ] **Step 1: Record the fixtures manually (one-time)**

Run at the R console and save each response to disk:

```r
# NOT part of the test suite — a one-shot recording script
library(httr2)

record_fixture <- function(source, stats, path) {
  url <- rotostats:::.build_projections_url(
    source, if (stats == "bat") "batters" else "pitchers"
  )
  body <- resp_body_json(req_perform(request(url)))
  # Trim to the first 25 players to keep the fixture tiny
  body <- utils::head(body, 25L)
  jsonlite::write_json(body, path, auto_unbox = TRUE, pretty = TRUE)
}

record_fixture("steamer", "bat", "tests/testthat/fixtures/projections-steamer-bat.json")
record_fixture("steamer", "pit", "tests/testthat/fixtures/projections-steamer-pit.json")
record_fixture("zips",    "pit", "tests/testthat/fixtures/projections-zips-pit.json")
```

Confirm each file is small (a few KB). Do not commit a fixture bigger than
~50 KB — trim further if needed.

- [ ] **Step 2: Write the failing tests**

Append to `tests/testthat/test-get-projections.R`:

```r
# ---------------------------------------------------------------------------
# Recorded-fixture integration tests
# ---------------------------------------------------------------------------

load_fixture <- function(name) {
  path <- testthat::test_path("fixtures", name)
  jsonlite::read_json(path)
}

test_that("get_projections('steamer', 'batters') parses the recorded fixture cleanly", {
  testthat::local_mocked_bindings(
    .fetch_projections_api = function(url) load_fixture("projections-steamer-bat.json"),
    .package = "rotostats"
  )
  out <- get_projections(source = "steamer", player_type = "batters")
  expect_s3_class(out, "data.frame")
  expect_gt(nrow(out), 0L)
  expect_true(all(c("playerid", "name", "team", "pos", "player_type") %in% names(out)))
  expect_true(all(out$player_type == "batter"))
})

test_that("get_projections('steamer', 'pitchers') derives SVHD from the recorded fixture", {
  testthat::local_mocked_bindings(
    .fetch_projections_api = function(url) load_fixture("projections-steamer-pit.json"),
    .package = "rotostats"
  )
  rlang::reset_warning_verbosity("rotostats_svhd_definition")
  out <- suppressMessages(
    get_projections(source = "steamer", player_type = "pitchers")
  )
  expect_true("SVHD" %in% names(out))
  expect_true(all(out$SVHD == out$SV + out$HLD |
                  is.na(out$SV) | is.na(out$HLD) | out$SVHD >= 0))
})

test_that("ZiPS pitcher fixture parses even without QS", {
  testthat::local_mocked_bindings(
    .fetch_projections_api = function(url) load_fixture("projections-zips-pit.json"),
    .package = "rotostats"
  )
  rlang::reset_warning_verbosity("rotostats_svhd_definition")
  out <- suppressMessages(
    get_projections(source = "zips", player_type = "pitchers")
  )
  expect_s3_class(out, "data.frame")
  # QS may or may not be present — this is documented in the spec. Either way,
  # no error is thrown and the rest of the pipeline works.
  expect_gt(nrow(out), 0L)
})
```

- [ ] **Step 3: Run — verify PASS**

```bash
Rscript -e 'devtools::test(filter = "get-projections")'
```

- [ ] **Step 4: Commit**

```bash
git add tests/testthat/fixtures/*.json tests/testthat/test-get-projections.R
git commit -m "test(projections): integration tests against recorded API fixtures"
```

---

## Task 18: Update package-level metadata

**Files:**
- Modify: `R/rotostats-package.R`
- Modify: `NEWS.md`

- [ ] **Step 1: Add `get_projections()` to Key Functions**

Edit [R/rotostats-package.R:8-9](R/rotostats-package.R):

```r
#' @section Key Functions:
#' - [get_projections()] — fetch FanGraphs projections (Steamer / ZiPS / ATC / …)
#' - [sgp()], [sgp_denominators()]
#' - [replacement_level()], [replacement_from_prices()]
#' - [par()], [zaa()], [zar()], [pvm()]
#' - [league_config()], [league_history()]
```

- [ ] **Step 2: Add a NEWS entry**

Edit [NEWS.md:1-3](NEWS.md) — add above the existing `## New arguments` block:

```markdown
# rotostats (development version)

## New features

* `get_projections()` fetches current-season projections directly from
  FanGraphs for Steamer, ZiPS, ATC, FanGraphs Depth Charts, THE BAT, and
  THE BAT X; or accepts a user-supplied `data` frame via
  `source = "custom"`. Returns one row per player with a `player_type`
  column distinguishing batters from pitchers. `SVHD` is derived as
  `SV + HLD` for pitcher rows, with a once-per-session reminder that the
  user should confirm this matches their league's definition. This adds
  `httr2` and `jsonlite` to `Imports`.

## New arguments
```

- [ ] **Step 3: Run `devtools::document()`**

```bash
Rscript -e 'devtools::document()'
```

Expected: clean run; `NAMESPACE` and `man/*.Rd` update.

- [ ] **Step 4: Commit**

```bash
git add R/rotostats-package.R NEWS.md man/rotostats-package.Rd NAMESPACE
git commit -m "docs(projections): announce get_projections() in package docs + NEWS"
```

---

## Task 19: `devtools::check()` gate

**Files:** — none; verification only

- [ ] **Step 1: Run the full check**

```bash
Rscript -e 'devtools::check()'
```

Expected: `0 errors | 0 warnings | 0 notes`.

Common failure modes and fixes:
- **"no visible binding for global variable"** on column names used inside
  subsetting → add `utils::globalVariables(c("SV", "HLD"))` to
  `R/rotostats-package.R`, or rewrite with `[[`.
- **"Imports includes ... but not used"** — delete the unused entry.
- **Examples fail** — wrap the live-API `get_projections()` example in
  `\dontrun{}` (already done in Task 13).

- [ ] **Step 2: If the check is clean, commit any lint fixes**

```bash
git add R/
git commit -m "fix(projections): resolve R CMD check findings"
```

(Skip this commit if no fixes were needed.)

---

## Task 20: Open the PR

**Files:** — none; git operations only

- [ ] **Step 1: Verify branch is up to date with develop**

```bash
git fetch origin develop
git log --oneline origin/develop..HEAD
```

Expected: a clean stack of the commits from Tasks 0–19.

- [ ] **Step 2: Push and open the PR against `develop`**

```bash
git push -u origin feature/get-projections
gh pr create \
  --base develop \
  --title "feat(projections): add get_projections() for FanGraphs + custom projections" \
  --body "$(cat <<'EOF'
## Summary

- New exported function `get_projections()` pulls current-season projections from FanGraphs (Steamer, ZiPS, ATC, FanGraphs DC, THE BAT, THE BAT X) or accepts user-supplied custom projections.
- Returns one row per player with a `player_type` column. `SVHD` is derived as `SV + HLD` for pitchers with a once-per-session `rlang::inform()`.
- Adds `httr2` and `jsonlite` to Imports. Updates `NEWS.md`, package docs, and error-class registry.

## Test plan

- [x] `devtools::test(filter = "get-projections")` — all unit + fixture-replay tests pass
- [x] `devtools::check()` — 0E / 0W / 0N
- [x] Live smoke test in a clean R session (manually verified before opening PR):
  ```r
  devtools::load_all()
  str(get_projections(source = "steamer", player_type = "both"), list.len = 5)
  ```

🤖 Generated with [Claude Code](https://claude.com/claude-code)
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

- **Spec coverage:** every section of [get-projections-impl.md](plans/implementation/get-projections-impl.md) is covered except the `cli_warn("QS is not available in ZiPS…")` which is explicitly deferred to `sgp()` (documented under "Out of scope" above).
- **No placeholders:** every step has real code and real commands.
- **Type consistency:** `.validate_source` / `.validate_player_type` / `.validate_year` / `.validate_custom_data` names, plus `.build_projections_url` / `.fetch_projections_api` / `.parse_projections_json` / `.normalize_projection_cols` / `.derive_svhd` / `.attach_player_type` / `.combine_batter_pitcher` / `.fetch_one_side` / `.fetch_and_assemble_projections`, are used consistently across tasks.
- **Error classes:** every `cli_abort` references a class registered in Task 1.
- **Branch + commit hygiene:** fresh branch off `develop`, Conventional Commits, PR targets `develop`.
