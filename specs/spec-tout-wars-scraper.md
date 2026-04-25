# Spec: Tout Wars historical auction scraper

**Status:** approved (brainstorm) — pending implementation plan
**Date:** 2026-04-25
**Branch:** `claude/recursing-hoover-bd1737`

## Goal

Scrape historical auction results from Tout Wars (2011-present) and ship the
result as a bundled package dataset, `tout_wars_auctions`. The schema is
designed to accept LABR (and other source) data later as siblings.

## Non-goals

- No exported scraping function. The scraper is a `data-raw/` build-time tool.
- No joining to a `player_id` system. None exists in the package yet.
- No FAAB, mid-season pickups, or in-season transactions. Draft-day auction
  only.
- No scraping of H2H or other non-auction tabs.
- No wiring the dataset into a `league_history()` example. Follow-up.

## Approach

Two-language workflow:

1. **Python scraper** (`data-raw/scrape-tout-wars.py`): reads a hand-curated
   YAML manifest of `(year, league_type) → {sheet_id, gid}`, fetches the CSV
   export and an HTML snapshot for each cell, parses to a tidy long-format
   CSV at `data-raw/tout-wars-auctions.csv`, and validates row counts and
   schema invariants.
2. **R bundler** (`data-raw/tout-wars-auctions.R`): reads the CSV, re-asserts
   the schema with `checkmate`, calls `usethis::use_data(tout_wars_auctions,
   overwrite = TRUE)` to produce `data/tout_wars_auctions.rda`.

The package gains `tout_wars_auctions` as bundled data accessible via
`data(tout_wars_auctions)`. Python is not added to package dependencies; it
is only used at build time inside `data-raw/`.

## Files

```
data-raw/
├── tout-wars-manifest.yaml          # year → {sheet_id, mixed_gid, al_gid, nl_gid}
├── scrape-tout-wars.py              # Python scraper + parser + validator
├── tout-wars-auctions.R             # R bundler (use_data)
├── tout-wars-auctions.csv           # tidy long-format output (committed)
└── cache/tout-wars/
    └── <year>-<league>.html         # raw HTML snapshots (committed, ~5 MB total)

data/tout_wars_auctions.rda          # bundled data object (committed)
R/data-tout-wars.R                   # roxygen documentation for ?tout_wars_auctions
tests/testthat/test-data-tout-wars.R # invariants re-asserted on loaded .rda
```

## Manifest format

YAML, hand-curated by inspecting each year's sheet once. Spot-checked by the
user before the full scrape runs.

```yaml
2011:
  sheet_id: 1IjIsM_h3D-zC4wyZ1VO9Y5U0Z3lCd7hw_NEH3yZYn68
  mixed_gid: ~        # null if league absent that year
  al_gid: 1234
  nl_gid: 5678
2021:
  sheet_id: 1jQ_CIaZjvfoqGrC0dDyMSlfTgSQ3OHfgEOvWwY9MEFk
  mixed_gid: <gid for "Mixed Salary">
  al_gid: <gid for "American League">
  nl_gid: <gid for "National League">
2025:
  sheet_id: 1YXAVAbQ1ESAdjoo0xSKTcdlYW0RNxR611DIydIPFTZo
  mixed_gid: <gid for "Mixed Auction">
  al_gid: <gid for "AL Only">
  nl_gid: <gid for "NL Only">
2026:
  sheet_id: 1FUC4bQIEBWB_Uls78le749zlaFIUcRo8HreKAlcdQUo
  ...
```

A null `*_gid` means that league did not exist (or did not have an auction)
for that year and is skipped without error. A missing top-level year is an
error.

## Schema

Output: tidy long format. One row per `(year, league_type, team_name,
player_name)`.

| column        | R type    | notes                                                     |
|---------------|-----------|-----------------------------------------------------------|
| `year`        | integer   | from manifest                                             |
| `league_type` | character | one of `"AL"`, `"NL"`, `"mixed"`                          |
| `team_name`   | character | as-scraped                                                |
| `player_name` | character | as-scraped (no normalization)                             |
| `position`    | character | raw, e.g. `"OF"`, `"1B/3B"`, `"SP"`, `"P"`                |
| `player_type` | character | `"batter"` or `"pitcher"` (derived from position)         |
| `price`       | integer   | dollars; ≥ 0                                              |
| `is_keeper`   | logical   | `FALSE` (constant; column reserved for future scrapes)    |
| `source`      | character | `"Tout Wars"` (display-friendly; matches future `"LABR"`) |

`player_type` derivation: position string is split on `/` and `,`, and any
component matching `^(P|SP|RP)$` (case-insensitive) marks the player as
`"pitcher"`. Otherwise `"batter"`.

## Data flow

1. **Read manifest** → list of `(year, league_type, sheet_id, gid)` cells,
   skipping null gids.
2. **For each cell**:
   - Fetch CSV via
     `https://docs.google.com/spreadsheets/d/{sheet_id}/export?format=csv&gid={gid}`.
   - Fetch HTML via
     `https://docs.google.com/spreadsheets/d/{sheet_id}/edit?gid={gid}` →
     write to `data-raw/cache/tout-wars/<year>-<league>.html`.
   - Detect column layout by header inspection. Manifest may carry per-cell
     column-index overrides as an escape hatch when auto-detection fails.
   - Parse rows into the schema above.
3. **Concatenate** all cells into one DataFrame.
4. **Validate** (see below). Abort the script on any violation; do not write
   a partial CSV.
5. **Write** `data-raw/tout-wars-auctions.csv` (UTF-8, committed).
6. **R bundler** runs separately: `Rscript data-raw/tout-wars-auctions.R`
   reads the CSV, re-asserts the schema with `checkmate`, calls
   `usethis::use_data(tout_wars_auctions, overwrite = TRUE)`.
7. **Roxygen doc** in `R/data-tout-wars.R` documents the dataset; running
   `devtools::document()` regenerates `man/tout_wars_auctions.Rd`.
8. **Tests** in `tests/testthat/test-data-tout-wars.R` re-assert the same
   invariants on the loaded `.rda` so CI catches regressions if the CSV is
   hand-edited.

## Validation

Run inside the Python scraper before writing the CSV. Re-asserted in R tests
after `use_data`.

- Row count per `(year, league_type)` is in expected range. Defaults: 12
  teams × ~23 roster slots ≈ 276. Allow ±20% (i.e., 220-330) and warn-only at
  the edges; abort below 150 or above 400 unless an override is set in the
  manifest for that cell.
- No NA in `player_name`, `team_name`, `price`, `position`, `league_type`,
  `year`.
- `price` integer, ≥ 0.
- `player_type ∈ {"batter", "pitcher"}`.
- `league_type ∈ {"AL", "NL", "mixed"}`.
- `(year, league_type, team_name, player_name)` unique.
- `is_keeper` is `FALSE` everywhere (constant invariant).
- `source` is `"Tout Wars"` everywhere.

## Error handling

- **Manifest entry missing for a year** the user expected: Python aborts with
  a list of missing years.
- **Network failure on fetch**: retry 3× with exponential backoff. If still
  failing, fall back to the on-disk HTML cache if present, derive CSV from
  cached HTML; otherwise abort with the failing URL.
- **Header layout drift** (auto-detected columns don't match expected
  shape): abort with the detected headers printed; user adds an override to
  the manifest entry for that cell.
- **Row-count out of bounds** (hard limits): abort with `(year, league_type,
  count, expected_range)`. User extends manifest with an override or fixes
  the parser.

## Reproducibility

- HTML snapshots are committed so the dataset can be rebuilt without
  internet. The Python script supports a `--from-cache` flag that skips
  network and rebuilds the CSV from cached HTML alone.
- The CSV, the `.rda`, and the cache are all committed. Anyone with R + the
  package source can rebuild the `.rda` from the CSV; anyone with Python +
  the source can rebuild the CSV from the cache.

## Year-parameterized usage

Adding a new year is a three-step manual process:

1. Add a top-level entry to `tout-wars-manifest.yaml` with the new
   `sheet_id` and per-league gids.
2. Run `python data-raw/scrape-tout-wars.py` to fetch and write the CSV.
3. Run `Rscript data-raw/tout-wars-auctions.R` to rebuild the `.rda`, then
   `devtools::document()` and commit.

## Future-proofing for LABR and other sources

The `source` column and the `(source, year, league_type, team_name,
player_name)` natural key are designed so future scrapers (LABR, etc.)
produce sibling datasets with the same schema. A combined view (e.g.,
`auctions <- rbind(tout_wars_auctions, labr_auctions)`) is straightforward
later without schema migration.

## Open items deferred to plan

- Exact Python dependency set (likely `requests`, `pyyaml`, `pandas`,
  `lxml`/`beautifulsoup4` for HTML parsing).
- Whether to add a Makefile target or `data-raw/README.md` describing the
  build sequence.
- Per-year column-layout overrides discovered when actually inspecting each
  sheet (manifest gets extended as needed).
