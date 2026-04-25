# Spec: Tout Wars historical auction loader

**Status:** approved (brainstorm) — pending implementation plan
**Date:** 2026-04-25 (revised after manual data acquisition)
**Branch:** `claude/recursing-hoover-bd1737`

## Goal

Bundle Tout Wars historical auction results (2012-present) as the
`tout_wars_auctions` package dataset. The schema is designed to accept
LABR (and other source) data later as siblings.

The user has manually downloaded the per-year, per-league CSVs from the
Tout Wars Google Sheets and they live in
`data-raw/sources/tout-wars/{year}-{league}.csv`. This spec describes the
loader/parser that turns those raw wide-format CSVs into a tidy long
dataset. **No web scraping is in scope** — that was deferred when manual
acquisition was easier.

## Non-goals

- No exported parser/loader function. The loader is a `data-raw/`
  build-time tool only.
- No web scraping. New years are added by manually downloading the CSV
  from the Tout Wars Google Sheet for that year-league and dropping it
  into `data-raw/sources/tout-wars/`.
- No 2011 data. Not available among the manual downloads; dropped.
- No joining to a `player_id` system. None exists in the package yet.
- No FAAB, mid-season pickups, reserve rounds, or in-season transactions.
  Draft-day auction roster only.
- No H2H or other non-auction tabs.
- No wiring the dataset into a `league_history()` example. Follow-up.

## Approach

Single-language R workflow:

1. **R parser/bundler** (`data-raw/tout-wars-auctions.R`): iterates the
   `data-raw/sources/tout-wars/*.csv` files, parses each wide-format sheet
   into long-format rows, concatenates, validates, calls
   `usethis::use_data(tout_wars_auctions, overwrite = TRUE)` to produce
   `data/tout_wars_auctions.rda`.

The package gains `tout_wars_auctions` as bundled data accessible via
`data(tout_wars_auctions)`. No new package dependencies — `read.csv`,
`checkmate`, and `usethis` (already in Suggests for dev) cover it.

## Files

```
data-raw/
├── sources/tout-wars/              # 45 raw CSVs, one per year-league (committed)
│   ├── 2012-al.csv
│   ├── 2012-mixed.csv
│   ├── 2012-nl.csv
│   ├── ... (15 years × 3 leagues = 45 files)
│   └── 2026-nl.csv
└── tout-wars-auctions.R            # parser + validator + use_data() bundler

data/tout_wars_auctions.rda         # bundled data object (committed)
R/data-tout-wars.R                  # roxygen documentation for ?tout_wars_auctions
tests/testthat/test-data-tout-wars.R # invariants re-asserted on loaded .rda
```

## Input CSV format

Each `data-raw/sources/tout-wars/{year}-{league}.csv` is a **wide-format**
auction-board sheet exported from the Tout Wars Google Sheet for that
year-league. The structure is consistent across years:

| row    | column 1            | columns 2..N (paired: name, value)                                |
|--------|---------------------|-------------------------------------------------------------------|
| 1      | (empty or `_ `)     | team-owner name in even cols, empty in odd cols                   |
| 2      | (empty)             | `"$ To Spend"` or `"Left to Spend"` label, then dollar amount     |
| 3      | (count or empty)    | `"# Needed"` or `"Players Needed"`, then count                    |
| 4      | (empty)             | `"Max Bid"`, then dollar amount                                   |
| 5..    | position label      | for each team: `(player_name, price)` pair across two columns     |

A team consumes two columns: even-indexed col holds the name (in row 1)
and player names (in data rows); odd-indexed col holds the dollar amount.
Typical sheet has 12 teams → 25 columns (1 position + 12 × 2).

Data rows continue until the roster is exhausted. The roster fills
position slots in a fixed order (`C, C, 1B, 2B, ..., OF, OF, OF, OF, OF,
UT, P, P, P, P, P, P, P, P, P`). The loader treats every non-empty
position-labeled row as a roster entry; the per-year set of expected
position codes is derived from observed data, not hardcoded.

Price columns mix bare integers (`15`) and dollar-prefixed strings
(`"$15"`); the parser strips a leading `$` before integer coercion.

## Schema (output)

Tidy long format. One row per `(year, league_type, team_name,
player_name)`.

| column        | R type    | notes                                                     |
|---------------|-----------|-----------------------------------------------------------|
| `year`        | integer   | parsed from filename                                      |
| `league_type` | character | `"AL"`, `"NL"`, or `"mixed"` (parsed from filename)       |
| `team_name`   | character | team-owner name from row 1, as-scraped                    |
| `player_name` | character | as-scraped (no normalization)                             |
| `position`    | character | raw position label from column 1, e.g. `"OF"`, `"1B"`, `"P"` |
| `player_type` | character | `"batter"` or `"pitcher"` (derived from `position`)       |
| `price`       | integer   | dollars; ≥ 0; `$` prefix stripped before coercion         |
| `is_keeper`   | logical   | `FALSE` (constant; column reserved for future scrapes)    |
| `source`      | character | `"Tout Wars"` (display-friendly; matches future `"LABR"`) |

`player_type` derivation: position string is split on `/` and `,`, then
any component matching `^(P|SP|RP)$` (case-insensitive) marks the player
as `"pitcher"`. Otherwise `"batter"`. Multi-position eligibility is kept
as the raw string.

## Data flow

1. **Discover sources**: list files matching
   `data-raw/sources/tout-wars/[0-9]{4}-(al|nl|mixed)\.csv`.
   Abort if any unexpected filename is present.
2. **For each source file**:
   - Parse `(year, league_type)` from the filename.
   - Read the CSV with `read.csv(..., header = FALSE, stringsAsFactors =
     FALSE, check.names = FALSE)`.
   - Extract team-owner names from row 1 (even-indexed columns starting
     at col 2).
   - Skip rows 2-4 (`$ To Spend`, `# Needed`, `Max Bid`). Optionally use
     row 2 / row 4 to validate that the auction was fully spent (`Left to
     Spend = 0` for each team).
   - For each remaining data row: column 1 is the position; for each
     team `t` (1..N), columns `2t` and `2t+1` are `(player_name, price)`.
     Skip cells where `player_name` is empty.
   - Pivot to long format with `(year, league_type, team_name,
     player_name, position, price)`.
3. **Derive** `player_type`, `is_keeper = FALSE`, `source = "Tout Wars"`.
4. **Concatenate** all per-file frames into one tibble.
5. **Validate** (see below). Abort the script on any violation; do not
   write a partial `.rda`.
6. **Bundle**: `usethis::use_data(tout_wars_auctions, overwrite = TRUE)`
   writes `data/tout_wars_auctions.rda`.
7. **Roxygen doc** in `R/data-tout-wars.R` documents the dataset;
   `devtools::document()` regenerates `man/tout_wars_auctions.Rd`.
8. **Tests** in `tests/testthat/test-data-tout-wars.R` re-assert the same
   invariants on the loaded `.rda` so CI catches regressions if the
   sources are hand-edited.

## Validation

Run inside the R loader before `use_data`. Re-asserted in `testthat`
tests after the `.rda` is loaded.

- Row count per `(year, league_type)` is in expected range. Default
  baseline: 12 teams × ~23 roster slots ≈ 276. Hard abort below 150 or
  above 400; warn-only between 220 and 330.
- No NA in `player_name`, `team_name`, `price`, `position`,
  `league_type`, `year`.
- `price` integer, ≥ 0.
- `player_type ∈ {"batter", "pitcher"}`.
- `league_type ∈ {"AL", "NL", "mixed"}`.
- `(year, league_type, team_name, player_name)` unique within the
  dataset.
- `is_keeper` is `FALSE` everywhere (constant invariant).
- `source` is `"Tout Wars"` everywhere.
- File-set invariant: every `(year, league)` combo for years 2012-2026
  is present (45 files total).

## Error handling

- **Missing source file** for an expected `(year, league)`: abort with
  the missing combo printed.
- **Unexpected filename** in `data-raw/sources/tout-wars/`: abort with
  the offender printed.
- **Header layout drift** (row 1 doesn't have team names in expected
  positions, or row 2-4 don't match the expected labels): abort with the
  detected first 4 rows printed so the user can hand-edit the source CSV
  to fix it.
- **Row-count out of bounds** (hard limits): abort with `(year,
  league_type, count, expected_range)`.
- **Non-coercible price** (e.g., `"$N/A"`, blank in a row that has a
  player name): abort with the offending cell coordinates.

## Adding a new year

1. Open the new year's Tout Wars Google Sheet, export each of the three
   league tabs (AL, NL, mixed) as CSV via File → Download → CSV.
2. Place the CSVs at `data-raw/sources/tout-wars/{year}-{league}.csv`.
3. Run `Rscript data-raw/tout-wars-auctions.R` to rebuild the `.rda`,
   then `devtools::document()`, and commit.

## Future-proofing for LABR and other sources

The `source` column and the `(source, year, league_type, team_name,
player_name)` natural key are designed so future loaders (LABR, etc.)
produce sibling datasets with the same schema. A combined view (e.g.,
`auctions <- rbind(tout_wars_auctions, labr_auctions)`) is straightforward
later without schema migration.

The expected directory layout for LABR would mirror this one:
`data-raw/sources/labr/{year}-{league}.csv`, with a parallel R loader.

## Reproducibility

The 45 raw source CSVs are committed to the repo. Anyone with R + the
package source can rebuild the `.rda` from the sources, no network
access required.

## Open items deferred to plan

- Exact handling of edge cells in the raw CSVs (e.g., whether any year
  uses different summary-row labels that break header detection — to be
  discovered during implementation).
- Whether the loader writes an intermediate
  `data-raw/tout-wars-auctions.csv` for human inspection in addition to
  the `.rda`, or only the `.rda`.
- Whether to validate per-team total spend equals $260 against row 2 of
  each source file (nice-to-have audit; not strictly required for the
  output schema).
- Whether the leftover `.tsv` in `~/Downloads` should be deleted or kept
  (housekeeping, out of scope for the spec).
