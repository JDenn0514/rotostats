# Tout Wars Auction CSV Normalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Normalize 45 irregular Tout Wars auction CSVs into a uniform `tout_wars_auctions` package data object via a two-stage R pipeline.

**Architecture:** Stage 1 (`data-raw/normalize-tout-wars-auctions.R`) reads each raw CSV, dispatches to a per-layout parser (standard or year-specific), and writes a long-tidy cleaned CSV per file. Stage 2 (`data-raw/tout-wars-auctions.R`) reads all cleaned CSVs, adds `year`/`league` from filename, binds them, and calls `usethis::use_data()`. All parser internals live in `R/utils-tout-wars.R` so they are testable from `testthat`.

**Tech Stack:** R, `readr`, `dplyr`, `tibble`, `purrr`, `fs`, `glue`, `cli`, `usethis`, `testthat`, `devtools`.

**Spec:** [plans/specs/2026-04-27-auction-csv-normalization-design.md](../specs/2026-04-27-auction-csv-normalization-design.md)

---

## File structure

**Created by this plan:**

| Path                                                         | Responsibility                                             |
| ------------------------------------------------------------ | ---------------------------------------------------------- |
| `R/utils-tout-wars.R`                                        | Internal helpers: `.canonicalize_tw_owner()`, all parsers, dispatcher, golden tables. |
| `R/data-tout-wars-auctions.R`                                | Roxygen docs for the `tout_wars_auctions` dataset.         |
| `data-raw/normalize-tout-wars-auctions.R`                    | Stage 1 driver — runs dispatcher across raw files.          |
| `data-raw/tout-wars-auctions.R`                              | Stage 2 driver — binds cleaned CSVs, writes `.rda`.         |
| `tests/testthat/test-canonicalize-tw-owner.R`                | Unit tests for owner canonicalization.                     |
| `tests/testthat/test-normalize-tout-wars-auctions.R`         | Branch-parser tests against synthetic fixtures.            |
| `tests/testthat/test-tout-wars-auctions.R`                   | Schema/domain checks on the committed `.rda`.              |
| `tests/testthat/fixtures/tout-wars-auctions/standard-mini.csv` | Synthetic standard-layout fixture (3 teams × 3 slots).      |
| `tests/testthat/fixtures/tout-wars-auctions/2012-al-mini.csv`  | Synthetic 2012-al-layout fixture.                           |
| `tests/testthat/fixtures/tout-wars-auctions/2012-nl-mini.csv`  | Synthetic 2012-nl-layout fixture.                           |
| `tests/testthat/fixtures/tout-wars-auctions/2012-mixed-mini.csv`| Synthetic 2012-mixed-layout fixture.                       |
| `tests/testthat/fixtures/tout-wars-auctions/2015-nl-mini.csv`  | Synthetic 2015-nl-layout fixture (embedded newline).        |
| `data-raw/sources/tout-wars/auctions-clean/auction-{league}-{year}.csv` × 45 | Stage 1 outputs (generated; committed).        |
| `data/tout_wars_auctions.rda`                                | Stage 2 output (generated; committed).                     |

**Modified:** none. (The plan does not touch the existing scrapers or any other R code.)

---

## Task 1: Owner canonicalization helper

**Files:**
- Create: `R/utils-tout-wars.R`
- Create: `tests/testthat/test-canonicalize-tw-owner.R`

- [ ] **Step 1: Write the failing test**

Create `tests/testthat/test-canonicalize-tw-owner.R`:

```r
test_that(".canonicalize_tw_owner trims whitespace", {
  expect_identical(.canonicalize_tw_owner("  PODHORZER  "), "PODHORZER")
})

test_that(".canonicalize_tw_owner uppercases simple last names", {
  expect_identical(.canonicalize_tw_owner("Podhorzer"), "PODHORZER")
})

test_that(".canonicalize_tw_owner alphabetizes partnership tokens", {
  expect_identical(.canonicalize_tw_owner("WOLF/COLTON"), "COLTON/WOLF")
  expect_identical(.canonicalize_tw_owner("COLTON/WOLF"), "COLTON/WOLF")
})

test_that(".canonicalize_tw_owner alphabetizes 3-way partnerships", {
  expect_identical(
    .canonicalize_tw_owner("WOLF/COLTON/SMITH"),
    "COLTON/SMITH/WOLF"
  )
})

test_that(".canonicalize_tw_owner applies aliases before tokenizing", {
  expect_identical(.canonicalize_tw_owner("Wolf and Colton"), "COLTON/WOLF")
  expect_identical(.canonicalize_tw_owner("Van RIPER"), "VANRIPER")
  expect_identical(.canonicalize_tw_owner("VAN RIPER"), "VANRIPER")
  expect_identical(.canonicalize_tw_owner("VanRiper"), "VANRIPER")
})

test_that(".canonicalize_tw_owner is idempotent", {
  inputs <- c("PODHORZER", "COLTON/WOLF", "VANRIPER", "WOLF/COLTON/SMITH")
  for (x in inputs) {
    expect_identical(.canonicalize_tw_owner(.canonicalize_tw_owner(x)), .canonicalize_tw_owner(x))
  }
})

test_that(".canonicalize_tw_owner errors on NA or empty", {
  expect_error(.canonicalize_tw_owner(NA_character_), class = "rotostats_error_owner_blank")
  expect_error(.canonicalize_tw_owner(""), class = "rotostats_error_owner_blank")
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript -e 'devtools::test(filter = "canonicalize-tw-owner")'`
Expected: FAIL — function `.canonicalize_tw_owner` not found.

- [ ] **Step 3: Write minimal implementation**

Create `R/utils-tout-wars.R`:

```r
# Internal helpers for the tout_wars_auctions dataset.
# See plans/specs/2026-04-27-auction-csv-normalization-design.md.

# Aliases applied BEFORE tokenization. Map raw input → canonical output.
.tw_owner_aliases <- c(
  "Wolf and Colton" = "COLTON/WOLF",
  "Van RIPER"       = "VANRIPER",
  "VAN RIPER"       = "VANRIPER",
  "VanRiper"        = "VANRIPER"
)

#' Canonicalize a Tout Wars team-owner string.
#'
#' Trim whitespace, apply aliases, then split on `/`, uppercase tokens,
#' alphabetize, rejoin. Deterministic — `WOLF/COLTON` and `COLTON/WOLF` both
#' collapse to `COLTON/WOLF`.
#'
#' @param x A length-1 character vector.
#' @return Length-1 canonicalized character vector.
#' @keywords internal
#' @noRd
.canonicalize_tw_owner <- function(x) {
  if (is.na(x) || !nzchar(trimws(x))) {
    cli::cli_abort(
      "Owner string is blank or NA.",
      class = "rotostats_error_owner_blank"
    )
  }
  x <- trimws(x)
  if (x %in% names(.tw_owner_aliases)) {
    return(unname(.tw_owner_aliases[x]))
  }
  tokens <- strsplit(x, "/", fixed = TRUE)[[1]]
  tokens <- toupper(trimws(tokens))
  paste(sort(tokens), collapse = "/")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript -e 'devtools::test(filter = "canonicalize-tw-owner")'`
Expected: PASS — all 7 tests.

- [ ] **Step 5: Commit**

```bash
git add R/utils-tout-wars.R tests/testthat/test-canonicalize-tw-owner.R
git commit -m "feat(auctions): add owner canonicalization helper"
```

---

## Task 2: Standard-layout parser (TDD against synthetic fixture)

**Files:**
- Create: `tests/testthat/fixtures/tout-wars-auctions/standard-mini.csv`
- Modify: `R/utils-tout-wars.R`
- Create: `tests/testthat/test-normalize-tout-wars-auctions.R`

The standard layout (verified on `2018-al.csv`):
- Row 1: owners in even columns (col 2, 4, 6, …); odd columns blank.
- Rows 2–4: meta rows starting with `Left to Spend` / `Players Needed` / `Max Bid` in col 2.
- Row 5+: col 1 = `position_slot`; even cols = player name; odd cols = price.
- Trailing all-empty columns may exist.

- [ ] **Step 1: Create the synthetic fixture**

Create `tests/testthat/fixtures/tout-wars-auctions/standard-mini.csv` — 3 teams × 2 slots, mimicking the standard layout:

```csv
,SMITH,,JONES,,WOLF/COLTON,
,Left to Spend,0,Left to Spend,2,Left to Spend,0
,Players Needed,0,Players Needed,0,Players Needed,0
,Max Bid,1,Max Bid,3,Max Bid,1
C,Player A,10,Player B,12,Player C,8
SP,Pitcher A,20,Pitcher B,18,Pitcher C,15
```

(Note the trailing comma on row 1 — represents one trailing all-empty column to be trimmed.)

- [ ] **Step 2: Write the failing test**

Create `tests/testthat/test-normalize-tout-wars-auctions.R`:

```r
fixture_path <- function(name) {
  testthat::test_path("fixtures", "tout-wars-auctions", name)
}

test_that(".parse_tw_auction_standard returns long-tidy rows", {
  result <- .parse_tw_auction_standard(
    fixture_path("standard-mini.csv"),
    expected_teams = 3
  )
  expect_named(
    result,
    c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")
  )
  expect_equal(nrow(result), 6)  # 3 teams × 2 slots
  expect_setequal(unique(result$team_owner), c("SMITH", "JONES", "COLTON/WOLF"))
  expect_setequal(unique(result$position_slot), c("C", "SP"))
  expect_setequal(unique(result$player_type), c("batter", "pitcher"))
  expect_true(all(!result$is_keeper))
  expect_type(result$price, "integer")
  expect_true(all(result$price > 0))
})

test_that(".parse_tw_auction_standard errors on wrong column count", {
  # write a fixture inline with 5 cols instead of 7
  tf <- tempfile(fileext = ".csv")
  writeLines(c(",SMITH,,JONES,", ",Left to Spend,0,Left to Spend,0",
               ",Players Needed,0,Players Needed,0", ",Max Bid,1,Max Bid,1",
               "C,Player A,10,Player B,12"), tf)
  expect_error(
    .parse_tw_auction_standard(tf, expected_teams = 3),
    class = "rotostats_error_auction_col_count"
  )
})

test_that(".parse_tw_auction_standard errors on missing meta rows", {
  tf <- tempfile(fileext = ".csv")
  writeLines(c(",SMITH,,JONES,,WOLF,",
               ",Wrong Label,0,Wrong Label,0,Wrong Label,0",
               ",Players Needed,0,Players Needed,0,Players Needed,0",
               ",Max Bid,1,Max Bid,1,Max Bid,1",
               "C,A,1,B,2,C,3"), tf)
  expect_error(
    .parse_tw_auction_standard(tf, expected_teams = 3),
    class = "rotostats_error_auction_meta_rows"
  )
})

test_that(".parse_tw_auction_standard derives player_type correctly", {
  result <- .parse_tw_auction_standard(
    fixture_path("standard-mini.csv"),
    expected_teams = 3
  )
  expect_equal(result$player_type[result$position_slot == "C"], rep("batter", 3))
  expect_equal(result$player_type[result$position_slot == "SP"], rep("pitcher", 3))
})
```

- [ ] **Step 3: Run test to verify it fails**

Run: `Rscript -e 'devtools::test(filter = "normalize-tout-wars-auctions")'`
Expected: FAIL — `.parse_tw_auction_standard` not found.

- [ ] **Step 4: Add the parser to `R/utils-tout-wars.R`**

Append to `R/utils-tout-wars.R`:

```r
.tw_pitcher_slots <- c("SP", "RP", "P")

#' Derive player_type from position_slot vector.
#' @keywords internal
#' @noRd
.derive_player_type <- function(position_slot) {
  ifelse(position_slot %in% .tw_pitcher_slots, "pitcher", "batter")
}

#' Parse a standard-layout Tout Wars auction CSV.
#'
#' @param path Path to the raw CSV.
#' @param expected_teams Integer team count (12 for AL/NL, 15 for Mixed).
#' @return Tibble with columns team_owner, position_slot, player_type,
#'   player_name, price, is_keeper.
#' @keywords internal
#' @noRd
.parse_tw_auction_standard <- function(path, expected_teams) {
  raw <- readr::read_csv(
    path,
    col_types = readr::cols(.default = "c"),
    col_names = FALSE,
    progress = FALSE
  )

  # Trim trailing all-NA columns.
  is_trailing_na <- vapply(raw, function(col) all(is.na(col)), logical(1))
  last_keep <- max(which(!is_trailing_na))
  raw <- raw[, seq_len(last_keep), drop = FALSE]

  expected_cols <- 1L + 2L * expected_teams
  if (ncol(raw) != expected_cols) {
    cli::cli_abort(
      c("Wrong column count in {.file {path}}.",
        "i" = "Expected {expected_cols} columns ({expected_teams} teams), got {ncol(raw)}."),
      class = "rotostats_error_auction_col_count"
    )
  }

  # Validate meta rows (rows 2-4): col 2 of each must start with the labels.
  meta_labels <- c("Left to Spend", "Players Needed", "Max Bid")
  meta_actual <- vapply(2:4, function(i) as.character(raw[i, 2, drop = TRUE]), character(1))
  if (!identical(meta_actual, meta_labels)) {
    cli::cli_abort(
      c("Meta rows 2-4 do not match expected labels in {.file {path}}.",
        "i" = "Expected {.val {meta_labels}}, got {.val {meta_actual}}."),
      class = "rotostats_error_auction_meta_rows"
    )
  }

  # Extract owners from row 1, even cols (2, 4, 6, ...).
  owner_cols <- seq(2L, by = 2L, length.out = expected_teams)
  owners_raw <- as.character(raw[1, owner_cols, drop = TRUE])
  owners <- vapply(owners_raw, .canonicalize_tw_owner, character(1))

  # Data rows: row 5 onward.
  data_rows <- raw[-(1:4), , drop = FALSE]

  # For each team k (1..expected_teams): cols 2k = name, 2k+1 = price.
  per_team <- lapply(seq_len(expected_teams), function(k) {
    name_col <- 2L * k
    price_col <- 2L * k + 1L
    tibble::tibble(
      team_owner    = owners[k],
      position_slot = as.character(data_rows[[1]]),
      player_name   = as.character(data_rows[[name_col]]),
      price_chr     = as.character(data_rows[[price_col]])
    )
  })
  long <- dplyr::bind_rows(per_team)

  # Drop empty rows.
  long <- dplyr::filter(long, !is.na(.data$player_name) & nzchar(trimws(.data$player_name)))
  long$player_name <- trimws(long$player_name)

  # Coerce price to non-negative integer.
  price_int <- suppressWarnings(as.integer(long$price_chr))
  if (any(is.na(price_int)) || any(price_int < 0)) {
    bad <- long$price_chr[is.na(price_int) | (price_int < 0)]
    cli::cli_abort(
      c("Non-integer or negative prices in {.file {path}}.",
        "i" = "Offending values: {.val {bad}}."),
      class = "rotostats_error_auction_price"
    )
  }
  long$price <- price_int
  long$price_chr <- NULL

  long$position_slot <- trimws(long$position_slot)
  long$player_type <- .derive_player_type(long$position_slot)
  long$is_keeper <- FALSE

  long <- dplyr::arrange(
    long,
    .data$team_owner, .data$position_slot, dplyr::desc(.data$price)
  )

  long[, c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")]
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `Rscript -e 'devtools::test(filter = "normalize-tout-wars-auctions")'`
Expected: PASS — 4 tests.

- [ ] **Step 6: Spot-check against a real standard file**

Run interactively:

```r
devtools::load_all()
res <- .parse_tw_auction_standard(
  "data-raw/sources/tout-wars/auctions/2018-al.csv",
  expected_teams = 12
)
print(res, n = 5)
nrow(res)
unique(res$team_owner)
```

Expected: ~276 rows (12 teams × 23 slots), 12 distinct canonical owners including `COLTON/WOLF`.

- [ ] **Step 7: Commit**

```bash
git add R/utils-tout-wars.R \
        tests/testthat/test-normalize-tout-wars-auctions.R \
        tests/testthat/fixtures/tout-wars-auctions/standard-mini.csv
git commit -m "feat(auctions): standard-layout parser for tout-wars auction CSVs"
```

---

## Task 3: 2012-al / 2012-nl bespoke parser

**Files:**
- Create: `tests/testthat/fixtures/tout-wars-auctions/2012-al-mini.csv`
- Create: `tests/testthat/fixtures/tout-wars-auctions/2012-nl-mini.csv`
- Modify: `R/utils-tout-wars.R`
- Modify: `tests/testthat/test-normalize-tout-wars-auctions.R`

The 2012-al / 2012-nl deviation (verified on `2012-al.csv`):
- **Owner row is row 1, owners in odd columns** (1, 3, 5, …, 23) — not even columns.
- **Position slot column is col 2** (not col 1).
- **Meta rows 2–4:** col 1 blank, col 2 blank, then `Left to Spend`/`Players Needed`/`Max Bid` starting in col 3 (paired with values in col 4, 6, …).
- **Data rows:** col 1 blank, col 2 = `position_slot`, cols 3, 5, 7, … = player names, cols 4, 6, 8, … = prices.
- **Owner-to-data mapping:** owner at col `2k - 1` corresponds to player name at col `2k + 1` and price at col `2k + 2` for team k = 1..12.
- Total cols: 25 (same as standard).

The 2012-nl is structurally identical — same parser handles both. Confirm during implementation by reading `data-raw/sources/tout-wars/auctions/2012-nl.csv`.

- [ ] **Step 1: Inspect both raw files and confirm the layout**

Run:

```bash
head -5 data-raw/sources/tout-wars/auctions/2012-al.csv
head -5 data-raw/sources/tout-wars/auctions/2012-nl.csv
```

Verify both follow the layout described above. If 2012-nl deviates, document the deviation in this plan (edit before continuing) and split into a separate parser.

- [ ] **Step 2: Create synthetic fixtures**

Create `tests/testthat/fixtures/tout-wars-auctions/2012-al-mini.csv` (3 teams × 2 slots):

```csv
SMITH,,JONES,,WOLF/COLTON,,
,,Left to Spend,0,Left to Spend,2,Left to Spend,0
,,Players Needed,0,Players Needed,0,Players Needed,0
,,Max Bid,1,Max Bid,3,Max Bid,1
,C,Player A,10,Player B,12,Player C,8
,SP,Pitcher A,20,Pitcher B,18,Pitcher C,15
```

Create `tests/testthat/fixtures/tout-wars-auctions/2012-nl-mini.csv` — copy with different owner names:

```csv
ALPHA,,BETA,,GAMMA,,
,,Left to Spend,0,Left to Spend,0,Left to Spend,0
,,Players Needed,0,Players Needed,0,Players Needed,0
,,Max Bid,1,Max Bid,1,Max Bid,1
,C,X1,5,X2,6,X3,7
,RP,Y1,10,Y2,11,Y3,12
```

- [ ] **Step 3: Write the failing test**

Append to `tests/testthat/test-normalize-tout-wars-auctions.R`:

```r
test_that(".parse_tw_auction_2012_alnl handles 2012-al layout", {
  result <- .parse_tw_auction_2012_alnl(
    fixture_path("2012-al-mini.csv"),
    expected_teams = 3
  )
  expect_named(
    result,
    c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")
  )
  expect_equal(nrow(result), 6)
  expect_setequal(unique(result$team_owner), c("SMITH", "JONES", "COLTON/WOLF"))
  expect_setequal(unique(result$position_slot), c("C", "SP"))
})

test_that(".parse_tw_auction_2012_alnl handles 2012-nl layout", {
  result <- .parse_tw_auction_2012_alnl(
    fixture_path("2012-nl-mini.csv"),
    expected_teams = 3
  )
  expect_equal(nrow(result), 6)
  expect_setequal(unique(result$team_owner), c("ALPHA", "BETA", "GAMMA"))
  expect_setequal(unique(result$player_type), c("batter", "pitcher"))
})
```

- [ ] **Step 4: Run test to verify it fails**

Run: `Rscript -e 'devtools::test(filter = "normalize-tout-wars-auctions")'`
Expected: FAIL — `.parse_tw_auction_2012_alnl` not found.

- [ ] **Step 5: Add the parser to `R/utils-tout-wars.R`**

Append to `R/utils-tout-wars.R`:

```r
#' Parse a 2012 AL or NL Tout Wars auction CSV.
#'
#' Layout deviation from standard:
#' - Owner row 1: owners in odd columns (1, 3, 5, ..., 23).
#' - Position slot in column 2 (not column 1).
#' - For team k: name at col 2k+1, price at col 2k+2.
#'
#' @keywords internal
#' @noRd
.parse_tw_auction_2012_alnl <- function(path, expected_teams) {
  raw <- readr::read_csv(
    path,
    col_types = readr::cols(.default = "c"),
    col_names = FALSE,
    progress = FALSE
  )

  is_trailing_na <- vapply(raw, function(col) all(is.na(col)), logical(1))
  last_keep <- max(which(!is_trailing_na))
  raw <- raw[, seq_len(last_keep), drop = FALSE]

  expected_cols <- 1L + 2L * expected_teams
  if (ncol(raw) != expected_cols) {
    cli::cli_abort(
      c("Wrong column count in {.file {path}}.",
        "i" = "Expected {expected_cols} columns, got {ncol(raw)}."),
      class = "rotostats_error_auction_col_count"
    )
  }

  # Validate meta rows: col 3 of rows 2-4 must match the meta labels.
  meta_labels <- c("Left to Spend", "Players Needed", "Max Bid")
  meta_actual <- vapply(2:4, function(i) as.character(raw[i, 3, drop = TRUE]), character(1))
  if (!identical(meta_actual, meta_labels)) {
    cli::cli_abort(
      c("Meta rows 2-4 do not match expected labels in {.file {path}}.",
        "i" = "Expected {.val {meta_labels}}, got {.val {meta_actual}}."),
      class = "rotostats_error_auction_meta_rows"
    )
  }

  # Owners are in row 1, odd columns: 1, 3, 5, ..., 2*expected_teams - 1.
  owner_cols <- seq(1L, by = 2L, length.out = expected_teams)
  owners_raw <- as.character(raw[1, owner_cols, drop = TRUE])
  owners <- vapply(owners_raw, .canonicalize_tw_owner, character(1))

  # Data rows: row 5 onward. Position slot in col 2.
  data_rows <- raw[-(1:4), , drop = FALSE]

  per_team <- lapply(seq_len(expected_teams), function(k) {
    name_col <- 2L * k + 1L
    price_col <- 2L * k + 2L
    tibble::tibble(
      team_owner    = owners[k],
      position_slot = as.character(data_rows[[2]]),
      player_name   = as.character(data_rows[[name_col]]),
      price_chr     = as.character(data_rows[[price_col]])
    )
  })
  long <- dplyr::bind_rows(per_team)

  long <- dplyr::filter(long, !is.na(.data$player_name) & nzchar(trimws(.data$player_name)))
  long$player_name <- trimws(long$player_name)

  price_int <- suppressWarnings(as.integer(long$price_chr))
  if (any(is.na(price_int)) || any(price_int < 0)) {
    bad <- long$price_chr[is.na(price_int) | (price_int < 0)]
    cli::cli_abort(
      c("Non-integer or negative prices in {.file {path}}.",
        "i" = "Offending values: {.val {bad}}."),
      class = "rotostats_error_auction_price"
    )
  }
  long$price <- price_int
  long$price_chr <- NULL

  long$position_slot <- trimws(long$position_slot)
  long$player_type <- .derive_player_type(long$position_slot)
  long$is_keeper <- FALSE

  long <- dplyr::arrange(
    long,
    .data$team_owner, .data$position_slot, dplyr::desc(.data$price)
  )

  long[, c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")]
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `Rscript -e 'devtools::test(filter = "normalize-tout-wars-auctions")'`
Expected: PASS — 2 new tests.

- [ ] **Step 7: Spot-check against real 2012-al and 2012-nl files**

Run interactively:

```r
devtools::load_all()
al <- .parse_tw_auction_2012_alnl(
  "data-raw/sources/tout-wars/auctions/2012-al.csv", expected_teams = 12)
nl <- .parse_tw_auction_2012_alnl(
  "data-raw/sources/tout-wars/auctions/2012-nl.csv", expected_teams = 12)
nrow(al); nrow(nl)
head(al); head(nl)
```

Expected: both ~276 rows (12 × 23). All distinct owners canonicalized. If either fails, characterize the deviation, document it in the parser's roxygen, and fix before continuing.

- [ ] **Step 8: Commit**

```bash
git add R/utils-tout-wars.R \
        tests/testthat/test-normalize-tout-wars-auctions.R \
        tests/testthat/fixtures/tout-wars-auctions/2012-al-mini.csv \
        tests/testthat/fixtures/tout-wars-auctions/2012-nl-mini.csv
git commit -m "feat(auctions): bespoke parser for 2012 AL/NL auction layout"
```

---

## Task 4: 2012-mixed bespoke parser

**Files:**
- Create: `tests/testthat/fixtures/tout-wars-auctions/2012-mixed-mini.csv`
- Modify: `R/utils-tout-wars.R`
- Modify: `tests/testthat/test-normalize-tout-wars-auctions.R`

The 2012-mixed deviation (verified on `2012-mixed.csv`):
- **Row 1 is entirely empty.**
- **Owner row is row 2** (not row 1), owners in odd columns (3, 5, 7, …, 31).
- **Meta rows 3–5** (not 2–4): `Left to Spend` / `Players Needed` / `Max Bid` in col 3.
- **Data rows: row 6 onward.**
- **Position slot in col 2** but **sparse** — verified on `2012-mixed.csv` row 6 (Montero / Wieters / Votto rows): the slot label appears on the **last** row of each slot group, with prior rows in the same group having an empty slot cell. The parser must **backward-fill** col 2 (inherit from the next non-empty cell, not the previous one).
- **For team k:** name at col `2k + 1`, price at col `2k + 2` for k = 1..15.
- Total cols: 31 (same as standard mixed).

- [ ] **Step 1: Inspect raw file and confirm sparse-slot semantics**

Run:

```bash
head -10 data-raw/sources/tout-wars/auctions/2012-mixed.csv
```

Verify: row 1 empty; row 2 has owners; row 6 has empty col 2 (Montero/Martin/Soto row); row 7 has `C` in col 2 (Wieters/Ruiz row). I.e. the slot label appears on the *last* row of each slot group, and the parser must **backward-fill** col 2.

If the actual semantics differ (e.g., forward-fill, or the missing slot represents a distinct un-labelled slot), update Step 5's fill-loop direction before continuing.

- [ ] **Step 2: Create synthetic fixture**

Create `tests/testthat/fixtures/tout-wars-auctions/2012-mixed-mini.csv` (3 teams × 3 data rows, with sparse slot inheritance — slot label is on the *last* row of each group):

```csv
,,,,,,,
,,SMITH,,JONES,,WOLF/COLTON,
,,Left to Spend,0,Left to Spend,0,Left to Spend,0
,,Players Needed,0,Players Needed,0,Players Needed,0
,,Max Bid,1,Max Bid,1,Max Bid,1
,,A1,5,A2,6,A3,7
,C,B1,10,B2,11,B3,12
,SP,D1,20,D2,21,D3,22
```

(Row 6 has empty col 2 — its slot is `C` backward-inherited from row 7. Row 7 has `C`. Row 8 has `SP`.)

- [ ] **Step 3: Write the failing test**

Append to `tests/testthat/test-normalize-tout-wars-auctions.R`:

```r
test_that(".parse_tw_auction_2012_mixed handles empty row 1 and sparse slots", {
  result <- .parse_tw_auction_2012_mixed(
    fixture_path("2012-mixed-mini.csv"),
    expected_teams = 3
  )
  expect_equal(nrow(result), 9)  # 3 teams × 3 data rows
  expect_setequal(unique(result$team_owner), c("SMITH", "JONES", "COLTON/WOLF"))
  # Both row-6 and row-7 entries should have position_slot = "C"
  smith_rows <- dplyr::filter(result, .data$team_owner == "SMITH")
  expect_equal(sum(smith_rows$position_slot == "C"), 2)
  expect_equal(sum(smith_rows$position_slot == "SP"), 1)
})
```

- [ ] **Step 4: Run test to verify it fails**

Run: `Rscript -e 'devtools::test(filter = "normalize-tout-wars-auctions")'`
Expected: FAIL.

- [ ] **Step 5: Add the parser**

Append to `R/utils-tout-wars.R`:

```r
#' Parse a 2012 Mixed Tout Wars auction CSV.
#'
#' Layout deviation from standard:
#' - Row 1 is entirely empty.
#' - Owner row is row 2; owners in odd columns (3, 5, ..., 2k+1, ..., 31).
#' - Meta rows are rows 3-5 (not 2-4).
#' - Data rows start at row 6.
#' - Position slot in col 2; may be sparse (forward-fill from preceding row).
#' - For team k: name at col 2k+1, price at col 2k+2.
#'
#' @keywords internal
#' @noRd
.parse_tw_auction_2012_mixed <- function(path, expected_teams) {
  raw <- readr::read_csv(
    path,
    col_types = readr::cols(.default = "c"),
    col_names = FALSE,
    progress = FALSE
  )

  is_trailing_na <- vapply(raw, function(col) all(is.na(col)), logical(1))
  last_keep <- max(which(!is_trailing_na))
  raw <- raw[, seq_len(last_keep), drop = FALSE]

  expected_cols <- 1L + 2L * expected_teams
  if (ncol(raw) != expected_cols) {
    cli::cli_abort(
      c("Wrong column count in {.file {path}}.",
        "i" = "Expected {expected_cols} columns, got {ncol(raw)}."),
      class = "rotostats_error_auction_col_count"
    )
  }

  # Validate row 1 is empty, meta rows 3-5 match labels.
  row1_nonempty <- sum(!is.na(raw[1, ]) & nzchar(trimws(as.character(raw[1, ]))))
  if (row1_nonempty > 0) {
    cli::cli_abort(
      "2012-mixed parser expects row 1 empty in {.file {path}}, found {row1_nonempty} non-empty cells.",
      class = "rotostats_error_auction_row1_nonempty"
    )
  }
  meta_labels <- c("Left to Spend", "Players Needed", "Max Bid")
  meta_actual <- vapply(3:5, function(i) as.character(raw[i, 3, drop = TRUE]), character(1))
  if (!identical(meta_actual, meta_labels)) {
    cli::cli_abort(
      c("Meta rows 3-5 do not match expected labels in {.file {path}}.",
        "i" = "Expected {.val {meta_labels}}, got {.val {meta_actual}}."),
      class = "rotostats_error_auction_meta_rows"
    )
  }

  owner_cols <- seq(3L, by = 2L, length.out = expected_teams)
  owners_raw <- as.character(raw[2, owner_cols, drop = TRUE])
  owners <- vapply(owners_raw, .canonicalize_tw_owner, character(1))

  data_rows <- raw[-(1:5), , drop = FALSE]

  # Backward-fill position slot column (col 2). The slot label appears on the
  # last row of each slot group; preceding empty cells inherit from below.
  slot_raw <- as.character(data_rows[[2]])
  slot_filled <- slot_raw
  n <- length(slot_filled)
  for (i in rev(seq_along(slot_filled))) {
    if (i == n) {
      if (is.na(slot_filled[i]) || !nzchar(trimws(slot_filled[i]))) {
        cli::cli_abort(
          "Last data row in {.file {path}} has empty position slot \u2014 cannot backward-fill.",
          class = "rotostats_error_auction_slot_orphan"
        )
      }
    } else if (is.na(slot_filled[i]) || !nzchar(trimws(slot_filled[i]))) {
      slot_filled[i] <- slot_filled[i + 1L]
    }
  }
  slot_filled <- trimws(slot_filled)

  per_team <- lapply(seq_len(expected_teams), function(k) {
    name_col <- 2L * k + 1L
    price_col <- 2L * k + 2L
    tibble::tibble(
      team_owner    = owners[k],
      position_slot = slot_filled,
      player_name   = as.character(data_rows[[name_col]]),
      price_chr     = as.character(data_rows[[price_col]])
    )
  })
  long <- dplyr::bind_rows(per_team)

  long <- dplyr::filter(long, !is.na(.data$player_name) & nzchar(trimws(.data$player_name)))
  long$player_name <- trimws(long$player_name)

  price_int <- suppressWarnings(as.integer(long$price_chr))
  if (any(is.na(price_int)) || any(price_int < 0)) {
    bad <- long$price_chr[is.na(price_int) | (price_int < 0)]
    cli::cli_abort(
      c("Non-integer or negative prices in {.file {path}}.",
        "i" = "Offending values: {.val {bad}}."),
      class = "rotostats_error_auction_price"
    )
  }
  long$price <- price_int
  long$price_chr <- NULL

  long$player_type <- .derive_player_type(long$position_slot)
  long$is_keeper <- FALSE

  long <- dplyr::arrange(
    long,
    .data$team_owner, .data$position_slot, dplyr::desc(.data$price)
  )

  long[, c("team_owner", "position_slot", "player_type", "player_name", "price", "is_keeper")]
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `Rscript -e 'devtools::test(filter = "normalize-tout-wars-auctions")'`
Expected: PASS.

- [ ] **Step 7: Spot-check against real 2012-mixed file**

```r
devtools::load_all()
m <- .parse_tw_auction_2012_mixed(
  "data-raw/sources/tout-wars/auctions/2012-mixed.csv", expected_teams = 15)
nrow(m)
unique(m$team_owner)
unique(m$position_slot)
```

Expected: ~345 rows (15 × 23). All canonical owners. No NA in position_slot (forward-fill worked). If row count is wildly off, the sparse-slot logic likely needs revision.

- [ ] **Step 8: Commit**

```bash
git add R/utils-tout-wars.R \
        tests/testthat/test-normalize-tout-wars-auctions.R \
        tests/testthat/fixtures/tout-wars-auctions/2012-mixed-mini.csv
git commit -m "feat(auctions): bespoke parser for 2012-mixed auction layout"
```

---

## Task 5: 2015-nl preprocessor + standard parser

**Files:**
- Create: `tests/testthat/fixtures/tout-wars-auctions/2015-nl-mini.csv`
- Modify: `R/utils-tout-wars.R`
- Modify: `tests/testthat/test-normalize-tout-wars-auctions.R`

The 2015-nl deviation: an embedded literal newline inside a quoted field breaks `readr::read_csv`. The fix: read raw bytes, repair the malformed quote/newline, write to a tempfile, then delegate to the standard parser.

- [ ] **Step 1: Inspect 2015-nl.csv to characterize the embedded newline**

Run:

```bash
awk -F, 'NR<=10 {print NR": "NF" cols"}' data-raw/sources/tout-wars/auctions/2015-nl.csv
head -10 data-raw/sources/tout-wars/auctions/2015-nl.csv
```

Identify the line(s) where field counts are anomalously low — those are the lines with the embedded newline. Document the exact byte sequence of the malformed quote so the preprocessor can target it precisely. Update Step 2 below if your fix differs from "remove embedded newline within quoted field".

- [ ] **Step 2: Create synthetic fixture**

Create `tests/testthat/fixtures/tout-wars-auctions/2015-nl-mini.csv`. The fixture must reproduce the embedded-newline pathology — write it via R rather than as a literal CSV to control the bytes:

```r
# Run this once to generate the fixture:
fixture_lines <- c(
  ',SMITH,,JONES,,WOLF/COLTON,',
  ',Left to Spend,0,Left to Spend,0,Left to Spend,0',
  ',Players Needed,0,Players Needed,0,Players Needed,0',
  ',Max Bid,1,Max Bid,1,Max Bid,1',
  'C,Player A,10,"Player',     # <-- embedded newline starts here
  ' B with embedded newline",12,Player C,8',
  'SP,Pitcher A,20,Pitcher B,18,Pitcher C,15'
)
writeLines(fixture_lines, "tests/testthat/fixtures/tout-wars-auctions/2015-nl-mini.csv")
```

The pathology: row 5 starts a quoted field that does not close until row 6.

- [ ] **Step 3: Write the failing test**

Append to `tests/testthat/test-normalize-tout-wars-auctions.R`:

```r
test_that(".parse_tw_auction_2015_nl repairs embedded newline and parses", {
  result <- .parse_tw_auction_2015_nl(
    fixture_path("2015-nl-mini.csv"),
    expected_teams = 3
  )
  expect_equal(nrow(result), 6)
  expect_true(any(grepl("embedded newline", result$player_name)))
})
```

- [ ] **Step 4: Run test to verify it fails**

Run: `Rscript -e 'devtools::test(filter = "normalize-tout-wars-auctions")'`
Expected: FAIL.

- [ ] **Step 5: Add the preprocessor + parser**

Append to `R/utils-tout-wars.R`:

```r
#' Parse the 2015 NL Tout Wars auction CSV (with embedded-newline preprocessing).
#'
#' The raw 2015-nl.csv has a literal newline inside a quoted field, which
#' breaks readr::read_csv. We read the raw bytes, collapse newlines that
#' fall inside an unmatched quote, then delegate to the standard parser.
#'
#' @keywords internal
#' @noRd
.parse_tw_auction_2015_nl <- function(path, expected_teams) {
  raw_bytes <- readLines(path, warn = FALSE)
  text <- paste(raw_bytes, collapse = "\n")

  # Walk the text; flip an "in-quote" flag at each unescaped `"`. When in-quote,
  # replace any `\n` with a single space.
  chars <- strsplit(text, "", fixed = TRUE)[[1]]
  in_quote <- FALSE
  for (i in seq_along(chars)) {
    if (chars[i] == '"') {
      in_quote <- !in_quote
    } else if (in_quote && chars[i] == "\n") {
      chars[i] <- " "
    }
  }
  repaired <- paste(chars, collapse = "")

  tf <- tempfile(fileext = ".csv")
  on.exit(unlink(tf), add = TRUE)
  writeLines(repaired, tf)

  .parse_tw_auction_standard(tf, expected_teams = expected_teams)
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `Rscript -e 'devtools::test(filter = "normalize-tout-wars-auctions")'`
Expected: PASS.

- [ ] **Step 7: Spot-check against real 2015-nl file**

```r
devtools::load_all()
nl15 <- .parse_tw_auction_2015_nl(
  "data-raw/sources/tout-wars/auctions/2015-nl.csv", expected_teams = 12)
nrow(nl15)
nl15[grepl("\\s", nl15$player_name) & nchar(nl15$player_name) > 25, ]  # find rows that absorbed the newline
```

Expected: ~276 rows. The repaired row should appear with a single-space-joined player name.

- [ ] **Step 8: Commit**

```bash
git add R/utils-tout-wars.R \
        tests/testthat/test-normalize-tout-wars-auctions.R \
        tests/testthat/fixtures/tout-wars-auctions/2015-nl-mini.csv
git commit -m "feat(auctions): preprocessor + parser for 2015-nl embedded-newline file"
```

---

## Task 6: Dispatcher + canonical position_slot validation

**Files:**
- Modify: `R/utils-tout-wars.R`

- [ ] **Step 1: Add the dispatcher to `R/utils-tout-wars.R`**

Append:

```r
# Maps (year, league) -> override parser. Default is .parse_tw_auction_standard.
.tw_auction_overrides <- list(
  "2012-al"    = ".parse_tw_auction_2012_alnl",
  "2012-nl"    = ".parse_tw_auction_2012_alnl",
  "2012-mixed" = ".parse_tw_auction_2012_mixed",
  "2015-nl"    = ".parse_tw_auction_2015_nl"
)

# Team count by league.
.tw_team_counts <- c(al = 12L, nl = 12L, mixed = 15L)

#' Normalize a single Tout Wars auction CSV via dispatch on (year, league).
#'
#' @param path Path to raw CSV.
#' @param year Integer.
#' @param league One of "al", "nl", "mixed".
#' @return Long-tidy tibble (Stage 1 schema).
#' @keywords internal
#' @noRd
.normalize_tw_auction <- function(path, year, league) {
  if (!league %in% names(.tw_team_counts)) {
    cli::cli_abort(
      "Unknown league {.val {league}} (expected one of {.val {names(.tw_team_counts)}}).",
      class = "rotostats_error_auction_unknown_league"
    )
  }
  expected_teams <- .tw_team_counts[[league]]
  key <- paste0(year, "-", league)
  parser_name <- .tw_auction_overrides[[key]]
  if (is.null(parser_name)) parser_name <- ".parse_tw_auction_standard"
  parser <- get(parser_name, mode = "function")
  parser(path, expected_teams = expected_teams)
}
```

- [ ] **Step 2: Add dispatcher tests**

Append to `tests/testthat/test-normalize-tout-wars-auctions.R`:

```r
test_that(".normalize_tw_auction dispatches to the standard parser by default", {
  result <- .normalize_tw_auction(
    fixture_path("standard-mini.csv"),
    year = 2018, league = "al"
  )
  expect_equal(nrow(result), 6)
})

test_that(".normalize_tw_auction routes 2012-al to the bespoke parser", {
  result <- .normalize_tw_auction(
    fixture_path("2012-al-mini.csv"),
    year = 2012, league = "al"
  )
  expect_equal(nrow(result), 6)
})

test_that(".normalize_tw_auction errors on unknown league", {
  expect_error(
    .normalize_tw_auction(fixture_path("standard-mini.csv"), year = 2018, league = "xyz"),
    class = "rotostats_error_auction_unknown_league"
  )
})
```

- [ ] **Step 3: Run all tests**

Run: `Rscript -e 'devtools::test(filter = "normalize-tout-wars-auctions")'`
Expected: PASS — all branch parsers + dispatcher tests.

- [ ] **Step 4: Commit**

```bash
git add R/utils-tout-wars.R tests/testthat/test-normalize-tout-wars-auctions.R
git commit -m "feat(auctions): dispatcher routing year-league to parser"
```

---

## Task 7: Stage 1 driver — run dispatcher across all 45 raw files

**Files:**
- Create: `data-raw/normalize-tout-wars-auctions.R`

- [ ] **Step 1: Write the Stage 1 script**

Create `data-raw/normalize-tout-wars-auctions.R`:

```r
# Stage 1: Normalize raw Tout Wars auction CSVs into per-pick long-tidy CSVs.
# Reads from data-raw/sources/tout-wars/auctions/{year}-{league}.csv
# Writes to data-raw/sources/tout-wars/auctions-clean/auction-{league}-{year}.csv
#
# Spec: plans/specs/2026-04-27-auction-csv-normalization-design.md

devtools::load_all()

raw_dir   <- "data-raw/sources/tout-wars/auctions"
clean_dir <- "data-raw/sources/tout-wars/auctions-clean"
fs::dir_create(clean_dir)

raw_files <- list.files(raw_dir, pattern = "\\.csv$", full.names = TRUE)
stopifnot(length(raw_files) == 45L)

per_file_rows <- integer(0)

for (f in raw_files) {
  stem <- fs::path_ext_remove(fs::path_file(f))
  parts <- strsplit(stem, "-", fixed = TRUE)[[1]]
  stopifnot(length(parts) == 2L)
  year   <- as.integer(parts[1])
  league <- parts[2]

  tidy <- .normalize_tw_auction(f, year = year, league = league)

  out_path <- fs::path(clean_dir, glue::glue("auction-{league}-{year}.csv"))
  readr::write_csv(tidy, out_path)

  per_file_rows[stem] <- nrow(tidy)
  cli::cli_inform("normalized {.file {basename(f)}} → {.file {basename(out_path)}} ({nrow(tidy)} rows)")
}

cli::cli_inform("--- per-file row counts (paste into .tw_auction_row_counts) ---")
print(per_file_rows)
```

- [ ] **Step 2: Run the script**

Run: `Rscript data-raw/normalize-tout-wars-auctions.R`

Expected: 45 lines of `normalized ...` output, plus a printed named integer vector at the end. No errors.

If a file fails: read the error message, identify which assertion failed, characterize the deviation, either patch the relevant parser or add a new alias to `.tw_owner_aliases`. Do not relax assertions to silence errors.

- [ ] **Step 3: Inspect cleaned outputs**

Run:

```bash
ls data-raw/sources/tout-wars/auctions-clean | wc -l
head -5 data-raw/sources/tout-wars/auctions-clean/auction-al-2018.csv
```

Expected: 45 cleaned files; first cleaned file has the 6-column header `team_owner,position_slot,player_type,player_name,price,is_keeper` and sensible rows.

- [ ] **Step 4: Capture the canonical position_slot set**

Run interactively:

```r
clean_files <- list.files("data-raw/sources/tout-wars/auctions-clean", full.names = TRUE)
all_slots <- unique(unlist(lapply(clean_files, function(f) {
  readr::read_csv(f, col_types = "ccccil", progress = FALSE)$position_slot
})))
sort(all_slots)
```

Inspect the printed list. Add expected slots (e.g., `C, 1B, 2B, 3B, SS, MI, CI, OF, UT, SP, RP, P, BN, DH, SW`) to a named constant `.tw_canonical_slots` in `R/utils-tout-wars.R`. Investigate any unexpected entries (typos, whitespace, mis-parsed cells).

- [ ] **Step 5: Add slot validation back into all parsers**

Add to `R/utils-tout-wars.R` near the top:

```r
.tw_canonical_slots <- c(
  # populate from Step 4 output, e.g.:
  "C", "1B", "2B", "3B", "SS", "MI", "CI", "OF", "UT", "DH",
  "SP", "RP", "P", "BN", "SW"
)

.validate_tw_position_slots <- function(slots, path) {
  bad <- setdiff(unique(slots), .tw_canonical_slots)
  if (length(bad) > 0) {
    cli::cli_abort(
      c("Unknown position_slot value(s) in {.file {path}}.",
        "i" = "Offending: {.val {bad}}.",
        "i" = "If valid, add to .tw_canonical_slots in R/utils-tout-wars.R."),
      class = "rotostats_error_auction_unknown_slot"
    )
  }
  invisible(slots)
}
```

In each parser (`standard`, `2012_alnl`, `2012_mixed`), add a single line right after `long$position_slot <- trimws(long$position_slot)` (or its equivalent for `2012_mixed`):

```r
.validate_tw_position_slots(long$position_slot, path)
```

- [ ] **Step 6: Re-run Stage 1 and tests**

```bash
Rscript data-raw/normalize-tout-wars-auctions.R
Rscript -e 'devtools::test(filter = "normalize-tout-wars-auctions")'
```

Both expected to pass without changes (since the canonical set was derived from the actual outputs).

- [ ] **Step 7: Commit**

```bash
git add data-raw/normalize-tout-wars-auctions.R \
        data-raw/sources/tout-wars/auctions-clean \
        R/utils-tout-wars.R
git commit -m "feat(auctions): Stage 1 driver + canonical position_slot validation"
```

---

## Task 8: Golden row-count table

**Files:**
- Modify: `R/utils-tout-wars.R`

- [ ] **Step 1: Capture the golden row counts**

Take the named integer vector printed at the end of Task 7 Step 2. Add it to `R/utils-tout-wars.R`:

```r
# Golden per-file row counts. Populated empirically after Stage 1's first
# clean run. Used by Stage 1 (in-script assertion) and Stage 2 (combined
# row-count assertion). Update when raw files change.
.tw_auction_row_counts <- c(
  "2012-al"    = 999L,  # replace with actual values from Task 7 Step 2
  "2012-nl"    = 999L,
  "2012-mixed" = 999L,
  "2013-al"    = 999L
  # ... all 45 entries
)
```

Replace each `999L` with the actual integer printed by the Stage 1 driver.

- [ ] **Step 2: Wire the assertion into the Stage 1 driver**

Edit `data-raw/normalize-tout-wars-auctions.R` — replace the existing `for` loop with:

```r
for (f in raw_files) {
  stem <- fs::path_ext_remove(fs::path_file(f))
  parts <- strsplit(stem, "-", fixed = TRUE)[[1]]
  year   <- as.integer(parts[1])
  league <- parts[2]

  tidy <- .normalize_tw_auction(f, year = year, league = league)

  expected_rows <- .tw_auction_row_counts[[stem]]
  if (nrow(tidy) != expected_rows) {
    cli::cli_abort(
      c("Row count drift in {.file {basename(f)}}.",
        "i" = "Expected {expected_rows}, got {nrow(tidy)}.",
        "i" = "If intentional, update .tw_auction_row_counts in R/utils-tout-wars.R."),
      class = "rotostats_error_auction_row_count_drift"
    )
  }

  out_path <- fs::path(clean_dir, glue::glue("auction-{league}-{year}.csv"))
  readr::write_csv(tidy, out_path)
  cli::cli_inform("normalized {.file {basename(f)}} → {.file {basename(out_path)}} ({nrow(tidy)} rows)")
}
```

(Remove the `per_file_rows` accumulator and the trailing print — they were scaffolding for capturing the table.)

- [ ] **Step 3: Run Stage 1 again**

Run: `Rscript data-raw/normalize-tout-wars-auctions.R`
Expected: PASS — no drift errors.

- [ ] **Step 4: Sanity-bound checks (per-team and per-league totals)**

Add to `data-raw/normalize-tout-wars-auctions.R`, just before the `cli::cli_inform` line:

```r
team_totals <- aggregate(price ~ team_owner, data = tidy, FUN = sum)
if (any(team_totals$price < 0) || any(team_totals$price > 400)) {
  bad <- team_totals[team_totals$price < 0 | team_totals$price > 400, ]
  cli::cli_abort(
    c("Per-team total price out of sanity bounds [0, 400] in {.file {basename(f)}}.",
      "i" = "Offending: {paste(bad$team_owner, bad$price, sep = '=', collapse = ', ')}."),
    class = "rotostats_error_auction_team_total_oob"
  )
}
file_total <- sum(tidy$price)
if (file_total < 2000 || file_total > 5000) {
  cli::cli_abort(
    c("League-year total price out of sanity bounds [2000, 5000] in {.file {basename(f)}}.",
      "i" = "Got {file_total}."),
    class = "rotostats_error_auction_file_total_oob"
  )
}
```

- [ ] **Step 5: Run Stage 1 once more**

Run: `Rscript data-raw/normalize-tout-wars-auctions.R`
Expected: PASS — no sanity-bound errors. If any file fails, the bounds may be too tight; widen them or investigate the file.

- [ ] **Step 6: Commit**

```bash
git add R/utils-tout-wars.R data-raw/normalize-tout-wars-auctions.R
git commit -m "feat(auctions): golden row counts + sanity-bound checks"
```

---

## Task 9: Stage 2 — bind cleaned CSVs into `tout_wars_auctions`

**Files:**
- Create: `data-raw/tout-wars-auctions.R`

- [ ] **Step 1: Write the Stage 2 script**

Create `data-raw/tout-wars-auctions.R`:

```r
# Stage 2: Bind all cleaned per-pick CSVs into the tout_wars_auctions package
# data object.
#
# Spec: plans/specs/2026-04-27-auction-csv-normalization-design.md

devtools::load_all()

clean_dir <- "data-raw/sources/tout-wars/auctions-clean"
clean_files <- list.files(clean_dir, pattern = "\\.csv$", full.names = TRUE)

if (length(clean_files) != 45L) {
  cli::cli_abort(
    "Expected 45 cleaned auction CSVs, found {length(clean_files)}.",
    class = "rotostats_error_auction_missing_clean_files"
  )
}

read_one <- function(path) {
  stem <- fs::path_ext_remove(fs::path_file(path))  # auction-{league}-{year}
  parts <- strsplit(stem, "-", fixed = TRUE)[[1]]
  stopifnot(length(parts) == 3L && parts[1] == "auction")
  league <- parts[2]
  year   <- as.integer(parts[3])

  readr::read_csv(path, col_types = "ccccil", progress = FALSE) |>
    tibble::add_column(year = year, league = league, .before = 1)
}

tout_wars_auctions <- purrr::map_dfr(clean_files, read_one)

# Combined row-count assertion.
expected_total <- sum(.tw_auction_row_counts)
if (nrow(tout_wars_auctions) != expected_total) {
  cli::cli_abort(
    c("Combined row count mismatch.",
      "i" = "Expected {expected_total} (sum of golden table), got {nrow(tout_wars_auctions)}."),
    class = "rotostats_error_auction_combined_row_count"
  )
}

tout_wars_auctions <- dplyr::arrange(
  tout_wars_auctions,
  year, league, team_owner, position_slot, dplyr::desc(price)
)

usethis::use_data(tout_wars_auctions, overwrite = TRUE)
cli::cli_inform("Wrote tout_wars_auctions: {nrow(tout_wars_auctions)} rows.")
```

- [ ] **Step 2: Run the script**

Run: `Rscript data-raw/tout-wars-auctions.R`
Expected: `Wrote tout_wars_auctions: <N> rows.` where N = sum of golden row counts. `data/tout_wars_auctions.rda` exists.

- [ ] **Step 3: Commit**

```bash
git add data-raw/tout-wars-auctions.R data/tout_wars_auctions.rda
git commit -m "feat(auctions): Stage 2 bind + tout_wars_auctions package data"
```

---

## Task 10: Roxygen documentation for the dataset

**Files:**
- Create: `R/data-tout-wars-auctions.R`

- [ ] **Step 1: Write the dataset doc**

Create `R/data-tout-wars-auctions.R`:

```r
#' Tout Wars Auction Results, 2012–most recent year
#'
#' Long-tidy auction results for all three Tout Wars expert leagues
#' (American League, National League, Mixed). One row per auctioned player.
#'
#' @format A tibble with 8 columns:
#' \describe{
#'   \item{year}{Integer. Auction year.}
#'   \item{league}{Character. One of `"al"`, `"nl"`, or `"mixed"`.}
#'   \item{team_owner}{Character. Canonicalized owner name. Last name uppercase;
#'     partnerships joined with `/` and alphabetized (e.g., `"COLTON/WOLF"`).}
#'   \item{position_slot}{Character. Roster slot the player occupied (`"C"`,
#'     `"1B"`, `"OF"`, `"SP"`, `"RP"`, etc.). Not multi-position eligibility.}
#'   \item{player_type}{Character. `"batter"` or `"pitcher"`. Derived from
#'     `position_slot`: `c("SP", "RP", "P")` → `"pitcher"`; else `"batter"`.}
#'   \item{player_name}{Character. Player name as recorded in the source CSV,
#'     whitespace-trimmed. Not normalized to any external player-ID source.}
#'   \item{price}{Integer. Auction price in dollars. Non-negative.}
#'   \item{is_keeper}{Logical. Always `FALSE` — Tout Wars is not a keeper league.}
#' }
#'
#' @source Tout Wars auction CSVs at
#'   <https://www.toutwars.com>, normalized via
#'   `data-raw/normalize-tout-wars-auctions.R` and
#'   `data-raw/tout-wars-auctions.R`.
"tout_wars_auctions"
```

- [ ] **Step 2: Generate the .Rd file**

Run: `Rscript -e 'devtools::document()'`
Expected: `man/tout_wars_auctions.Rd` created.

- [ ] **Step 3: Commit**

```bash
git add R/data-tout-wars-auctions.R man/tout_wars_auctions.Rd NAMESPACE
git commit -m "docs(auctions): roxygen for tout_wars_auctions dataset"
```

---

## Task 11: testthat tests on the committed `.rda`

**Files:**
- Create: `tests/testthat/test-tout-wars-auctions.R`

- [ ] **Step 1: Write the test file**

Create `tests/testthat/test-tout-wars-auctions.R`:

```r
test_that("tout_wars_auctions has the expected schema", {
  expect_named(
    tout_wars_auctions,
    c("year", "league", "team_owner", "position_slot",
      "player_type", "player_name", "price", "is_keeper")
  )
  expect_type(tout_wars_auctions$year, "integer")
  expect_type(tout_wars_auctions$league, "character")
  expect_type(tout_wars_auctions$team_owner, "character")
  expect_type(tout_wars_auctions$position_slot, "character")
  expect_type(tout_wars_auctions$player_type, "character")
  expect_type(tout_wars_auctions$player_name, "character")
  expect_type(tout_wars_auctions$price, "integer")
  expect_type(tout_wars_auctions$is_keeper, "logical")
})

test_that("tout_wars_auctions domain values are valid", {
  expect_setequal(unique(tout_wars_auctions$league), c("al", "nl", "mixed"))
  expect_setequal(unique(tout_wars_auctions$player_type), c("batter", "pitcher"))
  expect_true(all(!tout_wars_auctions$is_keeper))
})

test_that("tout_wars_auctions has no NA values", {
  for (col in names(tout_wars_auctions)) {
    expect_false(any(is.na(tout_wars_auctions[[col]])), info = paste("column:", col))
  }
})

test_that("tout_wars_auctions has expected row count by year-league", {
  observed <- dplyr::count(tout_wars_auctions, year, league, name = "n")
  expected <- tibble::tibble(
    key = names(rotostats:::.tw_auction_row_counts),
    n   = unname(rotostats:::.tw_auction_row_counts)
  )
  expected$year   <- as.integer(sub("-.*", "", expected$key))
  expected$league <- sub("^[^-]+-", "", expected$key)
  expected$key    <- NULL
  joined <- dplyr::left_join(observed, expected, by = c("year", "league"),
                             suffix = c("_obs", "_exp"))
  expect_equal(joined$n_obs, joined$n_exp)
})

test_that("per-(year, league) total price is in sanity bounds", {
  totals <- dplyr::summarise(
    dplyr::group_by(tout_wars_auctions, year, league),
    total = sum(price), .groups = "drop"
  )
  expect_true(all(totals$total >= 2000 & totals$total <= 5000))
})

test_that("price values are non-negative integers", {
  expect_true(all(tout_wars_auctions$price >= 0))
  expect_type(tout_wars_auctions$price, "integer")
})
```

- [ ] **Step 2: Run the tests**

Run: `Rscript -e 'devtools::test(filter = "tout-wars-auctions")'`
Expected: PASS — all 6 tests.

- [ ] **Step 3: Commit**

```bash
git add tests/testthat/test-tout-wars-auctions.R
git commit -m "test(auctions): schema and domain checks on tout_wars_auctions"
```

---

## Task 12: Full check + final commit

- [ ] **Step 1: Run the full test suite**

Run: `Rscript -e 'devtools::test()'`
Expected: PASS — all tests in the package, including pre-existing ones.

- [ ] **Step 2: Run R CMD check**

Run: `Rscript -e 'devtools::check()'`
Expected: 0 errors, 0 warnings. Notes are acceptable if they relate to the new dataset size.

If `devtools::check()` flags new NOTEs/WARNINGs:
- "no visible binding for global variable" — add `utils::globalVariables()` for the affected names in `R/utils-tout-wars.R` or `R/data-tout-wars-auctions.R`.
- "Data with usage in documentation object 'tout_wars_auctions' but not in code" — ignore, expected for dataset doc.
- Any other warning — fix before continuing.

- [ ] **Step 3: Verify `git status` is clean except for any check artifacts**

Run: `git status --short`
Expected: clean tree on the feature branch (or only check-output artifacts that should be gitignored).

- [ ] **Step 4: Push and open PR against develop**

Run:

```bash
git push -u origin feature/auction-csv-normalization
gh pr create --base develop --title "feat(auctions): tout_wars_auctions package data" --body "$(cat <<'EOF'
## Summary
- Two-stage R pipeline normalizing 45 irregular Tout Wars auction CSVs into a uniform `tout_wars_auctions` package data object.
- Stage 1: per-file dispatch to standard parser or one of four bespoke parsers (2012-al, 2012-nl, 2012-mixed, 2015-nl); writes cleaned per-pick CSVs.
- Stage 2: binds cleaned CSVs, adds year/league from filename, writes `data/tout_wars_auctions.rda`.

## Spec
- [plans/specs/2026-04-27-auction-csv-normalization-design.md](../blob/feature/auction-csv-normalization/plans/specs/2026-04-27-auction-csv-normalization-design.md)

## Test plan
- [ ] `devtools::test()` passes
- [ ] `devtools::check()` returns 0 errors / 0 warnings
- [ ] Spot-check `tout_wars_auctions |> dplyr::filter(year == 2018, league == "al")` matches the raw 2018-al.csv content

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

---

## Self-review checklist (for plan author)

- [x] Every spec section has a corresponding task (canonicalization → Task 1; standard parser → Task 2; year-specific → Tasks 3–5; dispatcher → Task 6; Stage 1 → Tasks 7–8; Stage 2 → Task 9; docs → Task 10; CI tests → Task 11; full check → Task 12).
- [x] No "TBD" / "TODO" / "implement later" placeholders in code blocks. The two intentional discovery steps (Task 7 Step 4 — canonical slot set; Task 8 Step 1 — golden row counts) are explicit empirical-capture steps, not placeholders.
- [x] All function names consistent across tasks (`.canonicalize_tw_owner`, `.derive_player_type`, `.parse_tw_auction_standard`, `.parse_tw_auction_2012_alnl`, `.parse_tw_auction_2012_mixed`, `.parse_tw_auction_2015_nl`, `.normalize_tw_auction`, `.validate_tw_position_slots`, `.tw_owner_aliases`, `.tw_canonical_slots`, `.tw_team_counts`, `.tw_auction_overrides`, `.tw_auction_row_counts`, `.tw_pitcher_slots`).
- [x] Schema consistent with spec across all tasks (8 cols in combined; 6 cols in per-file CSV; types specified explicitly).
- [x] Error classes follow `rotostats_error_*` convention from `plans/error-messages.md`.
- [x] Each task ends with a commit step.
- [x] Synthetic fixtures cover every parser branch (standard, 2012-alnl, 2012-mixed, 2015-nl).
