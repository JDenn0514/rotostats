# Tout Wars Auction CSV Normalization — Design

**Date:** 2026-04-27
**Status:** Draft → ready for implementation plan
**Owner:** Jacob Dennen

## Goal

Normalize the 45 irregular Tout Wars auction CSVs in
`data-raw/sources/tout-wars/auctions/` into a uniform long-tidy structure, then
expose them as a single combined package data object `tout_wars_auctions`.

The raw files vary in column count, layout, and quoting; some have year-specific
quirks. After this work, downstream code can `dplyr::filter()` a single tibble
instead of writing parser branches.

## Non-goals

This spec deliberately excludes the following:

1. **Player-name normalization for projection-source matching.** Names are
   preserved as written (modulo whitespace trimming). Cross-source name
   reconciliation (e.g., FanGraphs IDs) is a separate effort.
2. **Multi-position eligibility derivation.** `pos_eligibility` is omitted —
   auction CSVs only record the slot the player was rostered into, not all
   positions they qualify for. Consumers wanting `replacement_from_prices()`
   can `mutate(pos_eligibility = position_slot)` for an approximation.
3. **Backwards-compatibility shims.** No per-league-year exports
   (`tout_wars_auctions_al_2018`, etc.). Consumers filter the combined tibble.
4. **Auction-source data beyond Tout Wars.** Only files in
   `data-raw/sources/tout-wars/auctions/`. NFBC, LABR, etc. are out of scope.
5. **Scraping new auction data.** This spec normalizes already-downloaded raw
   CSVs. A live auction-results scraper is out of scope.
6. **Reserve picks.** Rows with `position_slot = "R"` (reserve / farm) have no
   auction price and are excluded from the normalized dataset. The dataset is
   "auction-priced picks only." Reserves remain in the raw CSVs if ever needed.
7. **The two pre-existing follow-ups in
   [plans/follow-ups.md](../follow-ups.md)** (`pos_eligibility` delimiter
   mismatch, `player_type` vocabulary drift). This spec does not resolve them.

## Architecture

Two-stage R pipeline, both scripts in `data-raw/`:

```
data-raw/sources/tout-wars/auctions/{year}-{league}.csv      (raw, untouched)
        │
        │  Stage 1: data-raw/normalize-tout-wars-auctions.R
        ▼
data-raw/sources/tout-wars/auctions-clean/auction-{league}-{year}.csv
        │
        │  Stage 2: data-raw/tout-wars-auctions.R
        ▼
data/tout_wars_auctions.rda  (exposed via usethis::use_data)
```

**Why two stages:**

- Stage 1 outputs **inspectable per-pick CSVs** — easy to spot-check, easy to
  diff in `git`. Raw files stay untouched.
- Stage 2 is a thin bind-rows + filename parse + `use_data()` call. If Stage 1
  outputs are correct, Stage 2 is mechanical.

**Filename convention:**

- Raw: `{year}-{league}.csv` (e.g. `2018-al.csv`).
- Cleaned: `auction-{league}-{year}.csv` (e.g. `auction-al-2018.csv`).

The prefix and reordered suffix make raw vs. cleaned visually distinct in
`git status` and prevent accidental overwrites.

## Schema

### Stage 1 — cleaned per-pick CSV

One row per auctioned player. Year and league are implicit in the filename.

| Column          | Type      | Notes                                                          |
| --------------- | --------- | -------------------------------------------------------------- |
| `team_owner`    | character | Canonicalized — see Owner canonicalization below.              |
| `position_slot` | character | Slot the player was rostered into (`C`, `1B`, `OF`, `SP`, etc.). |
| `player_type`   | character | `"batter"` or `"pitcher"`. Derived from `position_slot`.       |
| `player_name`   | character | Preserved as written, whitespace-trimmed.                      |
| `price`         | integer   | Auction price in dollars. Non-negative.                        |
| `is_keeper`     | logical   | Always `FALSE` — Tout Wars is not a keeper league.             |

### Stage 2 — combined tibble (`tout_wars_auctions`)

| Column          | Type      | Notes                                |
| --------------- | --------- | ------------------------------------ |
| `year`          | integer   | From filename.                       |
| `league`        | character | `"al"`, `"nl"`, or `"mixed"`. From filename. |
| `team_owner`    | character | (as Stage 1)                         |
| `position_slot` | character | (as Stage 1)                         |
| `player_type`   | character | (as Stage 1)                         |
| `player_name`   | character | (as Stage 1)                         |
| `price`         | integer   | (as Stage 1)                         |
| `is_keeper`     | logical   | (as Stage 1)                         |

**`player_type` derivation:** `position_slot %in% c("SP", "RP", "P")` →
`"pitcher"`; else `"batter"`. Lowercase. Matches `league_history(prices=)`
validation; see `R/league-history.R:243`.

**Sort order (final tibble):** `year, league, team_owner, position_slot, -price`.

## Normalizer logic (Stage 1)

### Standard-layout parser (default branch)

Verified shape on `2018-al.csv`:

- **Row 1:** team-owner headers in even columns (col 2, 4, 6, …); blanks in odd
  columns. Col 1 empty.
- **Rows 2–4:** meta rows (`Left to Spend`, `Players Needed`, `Max Bid`) — skipped.
- **Rows 5+:** col 1 = `position_slot`; even cols = player name; odd cols = price.
- **Trailing empty columns:** all-NA columns at the right edge — dropped.
- **Column counts:** AL/NL = `1 + 2 × 12 = 25`; Mixed = `1 + 2 × 15 = 31`.
- **Footer / reserve rows:** several files have summary-stat rows below the
  rosters (e.g., row 36–37 of `2018-al.csv`) with stray non-NA values in
  trailing columns; reserve picks (`R` slot) appear at the bottom of each
  team's roster with no price. Both are filtered out before column-count
  validation by restricting to rows whose first cell is a canonical priced
  slot.

Steps:

1. **Read raw bytes.** Apply year-specific preprocessing if applicable, then
   `readr::read_csv(col_types = cols(.default = "c"), col_names = FALSE)`.
2. **Filter to header + meta + priced-roster rows.** Keep rows 1–4
   unconditionally (header + 3 meta rows). For the rest, keep only rows whose
   col-1 value (trimmed, uppercased) is in the canonical priced-slot set:
   `C, 1B, 3B, CI, 2B, SS, MI, OF, UT, SW, P, SP, RP`. This drops footer /
   summary rows and reserve (`R`) rows in one pass.
3. **Trim trailing all-NA columns** on the filtered matrix.
4. **Validate column count** matches `1 + 2 * expected_teams` for the league.
   Strict — `cli::cli_abort()` if not.
5. **Extract team owners** from row 1, even columns. Apply `canonicalize_owner()`.
6. **Validate and drop rows 2–4.** Their first non-NA value must match
   `Left to Spend` / `Players Needed` / `Max Bid` — abort otherwise.
7. **Pivot wide → long.** For each team owner *i* (cols `2i` and `2i+1`):
   - Slice priced-roster rows, cols `[1, 2i, 2i+1]` → `(position_slot, player_name, price)`.
   - Tag with `team_owner = owners[i]`.
   - Bind across all teams.
8. **Drop empty rows** where `player_name` is `NA` or empty.
9. **Coerce `price`** to non-negative integer. Abort on failure.
10. **Derive `player_type`** from `position_slot` (rule above).
11. **Validate `position_slot`** against a per-league-year canonical set.
12. **Add `is_keeper = FALSE`.**
13. **Sort** by `team_owner, position_slot, -price`.
14. **Write** to `data-raw/sources/tout-wars/auctions-clean/auction-{league}-{year}.csv`.

### Year-specific branches

A dispatch table maps `(year, league)` to a parser function. Default is the
standard parser; three files override:

| File           | Reason                                                            |
| -------------- | ----------------------------------------------------------------- |
| `2012-al`      | Layout deviates from standard — bespoke parser.                    |
| `2012-nl`      | Layout deviates from standard — bespoke parser.                    |
| `2012-mixed`   | Layout deviates from standard — bespoke parser.                    |

The 2015-nl file contains literal newlines inside quoted owner / player-name
fields. `readr::read_csv` handles RFC-4180-style quoted-multiline fields
natively, and the standard parser already trims whitespace from owners (via
`canonicalize_owner()`) and player names (via `trimws()`). The file therefore
needs no override — the dispatcher routes it to the standard parser and a
smoke test asserts the round-trip works.

Each non-default parser emits the same long-tidy schema as the standard parser
and runs the same validations from step 8 onward. The exact 2012 deviations are
to be characterized at implementation time and documented in each parser's
roxygen.

### Owner canonicalization

Single helper, exported as **internal package function**
`.canonicalize_tw_owner()` in `R/utils-tout-wars.R`. Lives in `R/` (not
data-raw) so it is reusable for joining auctions to rosters/standings later, and
testable from CI.

Algorithm:

1. **Trim whitespace.**
2. **Alias lookup first** — small named character vector, e.g.:
   - `"Wolf and Colton"` → `"WOLF/COLTON"`
   - `"Van RIPER"`, `"VAN RIPER"`, `"VanRiper"` → `"VANRIPER"`
3. **Otherwise:** split on `/` (partnership delimiter), uppercase each token,
   alphabetize tokens, rejoin with `/`.
4. **Result is deterministic** — `WOLF/COLTON` and `COLTON/WOLF` both collapse to
   `COLTON/WOLF`.

The alias table is defined at the top of `R/utils-tout-wars.R` so it is easy to
extend when a new variant surfaces.

### Strictness

Every validation point uses `cli::cli_abort()` with a class-prefixed message per
[plans/error-messages.md](../error-messages.md). No silent fallbacks — if a
future file breaks a parser, the error names the file and the failed assertion.
The fix is to either patch the file's branch or add a new alias.

## Testing & validation

Two layers: in-script assertions catch parser bugs at regeneration time;
testthat tests on the committed `.rda` catch drift in CI.

### A. In-script assertions

Run on every `source()` of the data-raw scripts. All `cli::cli_abort()` with
classed messages.

**Stage 1 (per file):**

- Column count matches expected for league.
- Meta rows 2–4 begin with the expected labels.
- Owner row produces exactly `expected_teams` non-blank entries after canonicalization.
- All `position_slot` values are in the canonical set.
- All `price` values coerce to non-negative integers.
- Per-file row count matches a hardcoded golden number (lookup table by
  `(year, league)`).
- Per-team price sum within sanity bounds `[0, 400]` (cap is believed to be
  ~$260 but not strictly enforced).
- Per-`(year, league)` total price within sanity bounds `[2000, 5000]`.

**Stage 2 (combined):**

- All 45 cleaned CSVs exist before binding.
- Combined row count = sum of per-file golden numbers.

### B. testthat tests on the committed `.rda` (CI)

`tests/testthat/test-tout-wars-auctions.R` — runs without raw inputs:

- Schema check: 8 columns; types match (`integer year`, character columns,
  `integer price`, `logical is_keeper`).
- Domain checks: `league %in% c("al", "nl", "mixed")`,
  `player_type %in% c("batter", "pitcher")`.
- `all(!is_keeper)`.
- No `NA` in any column.
- Row count per `(year, league)` matches the golden table.
- Per-`(year, league)` total price within the same `[2000, 5000]` sanity bounds
  used in Stage 1.

### C. Owner canonicalization (pure-function tests)

`tests/testthat/test-canonicalize-tw-owner.R`. Cases:

- Simple last-name (`"PODHORZER"` → `"PODHORZER"`).
- Alphabetization (`"WOLF/COLTON"` → `"COLTON/WOLF"`).
- Alias lookup (`"Wolf and Colton"` → `"COLTON/WOLF"`,
  `"Van RIPER"` → `"VANRIPER"`).
- Idempotency (`f(f(x)) == f(x)` for representative inputs).
- Whitespace tolerance (leading/trailing spaces stripped).

### D. Year-specific branch fixtures

`tests/testthat/fixtures/tout-wars-auctions/` holds tiny synthetic CSVs (2–3
teams × 2–3 slots) mimicking each non-default parser's quirk. One testthat case
per branch parser, asserting the parser produces the expected long-tidy rows.
Protects against silent parser-branch regression during refactors when raw data
hasn't changed.

## File layout summary

```
rotostats/
├── data-raw/
│   ├── normalize-tout-wars-auctions.R              ← Stage 1 (NEW)
│   ├── tout-wars-auctions.R                        ← Stage 2 (NEW)
│   └── sources/tout-wars/
│       ├── auctions/                               ← raw, untouched
│       │   ├── 2012-al.csv … 2025-mixed.csv        (45 files)
│       └── auctions-clean/                         ← Stage 1 output (NEW)
│           ├── auction-al-2012.csv … auction-mixed-2025.csv
├── R/
│   └── utils-tout-wars.R                           ← .canonicalize_tw_owner() (NEW)
├── data/
│   └── tout_wars_auctions.rda                      ← Stage 2 output (NEW)
└── tests/testthat/
    ├── test-tout-wars-auctions.R                   ← combined-tibble checks (NEW)
    ├── test-canonicalize-tw-owner.R                ← helper checks (NEW)
    └── fixtures/tout-wars-auctions/                ← branch fixtures (NEW)
```

## Open questions deferred to implementation

- The exact deviations in `2012-al`, `2012-nl`, `2012-mixed` — characterize
  during implementation; document each in its parser's roxygen.
- Per-league-year canonical set of `position_slot` values — derive empirically
  during implementation by scanning the cleaned outputs once the standard parser
  is working.
- Golden row-count table — populate during implementation by parsing each file
  once the parser is correct, then committing the table as a lookup constant.
