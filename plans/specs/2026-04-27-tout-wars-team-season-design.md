# Tout Wars Team-Season Dataset — Design

**Date:** 2026-04-27 (revised 2026-04-28)
**Status:** Draft → ready for implementation plan
**Owner:** Jacob Dennen

## Goal

Build a single package dataset, `tout_wars_team_season`, in the exact wide
shape `league_history()` expects, covering Tout Wars 2010–2025 across the AL,
NL, and Mixed leagues. The dataset enables historical-data testing of
`sgp_denominators()`, `sgp()`, and `par()` — the three functions whose
correctness depends on a realistic `team_season` plus team-level `IP` and `AB`
totals for blended-pool rate-stat baselines.

The standings CSVs in `data-raw/sources/tout-wars/standings/` provide the
counting and rate categories; they do not include `IP` or `AB`. Those two
columns are summed directly from the per-player rows in the new
`{year}-{league}-batters.csv` / `{year}-{league}-pitchers.csv` files produced
by `data-raw/sources/tout-wars/scrape/team_stats.py`.

## Background: data sources

Two raw inputs, both already on this branch:

1. **Standings** — `data-raw/sources/tout-wars/standings/{year}-{league}.csv`.
   45 files, 2010–2025. Wide team-season totals: R, HR, RBI, SB, OBP, AVG, W,
   SV, ERA, WHIP, SO plus per-category `_pts` columns. Schema is uniform
   across years.
2. **Team-stats rosters** — `data-raw/sources/tout-wars/rosters/{year}-{league}-batters.csv`
   and `{year}-{league}-pitchers.csv`. 90 files (45 batter + 45 pitcher),
   produced by `team_stats.py` (specced in
   `plans/specs/2026-04-28-tout-wars-team-stats-scraper-design.md`). Each row
   is one player on one Tout team in one year, with that player's stats
   attributed to the team's ownership window. Each row carries a
   `roster_section` ∈ `{active, reserved, previously_active, previously_reserved}`.

Because per-player stats are already team-attributed, no external stats
source is needed and no name-matching join is required.

## Non-goals

1. **A second per-player dataset.** Per-player stats are a transient join
   layer used to build `team_season`. They are not exported. (`tout_wars_auctions`
   already covers the player-price layer; per-player season stats are a clean
   future follow-up if/when needed.)
2. **A live scraper.** Standings and rosters are read from already-downloaded
   raw CSVs.
3. **2026 season.** In-progress; out of scope for this build.
4. **Player-ID normalization to MLBAM / Fangraphs IDs.** Onroto's
   `player_id` is preserved at the per-player layer; the team-season output
   does not carry player IDs.
5. **Other expert leagues.** NFBC, LABR, etc. are out of scope.

## Architecture

Two-stage R pipeline, both scripts in `data-raw/`. Same shape as the auction
pipeline.

```
data-raw/sources/tout-wars/standings/{year}-{league}.csv         (raw)
data-raw/sources/tout-wars/rosters/{year}-{league}-batters.csv   (raw)
data-raw/sources/tout-wars/rosters/{year}-{league}-pitchers.csv  (raw)
        │
        │  Stage 1: data-raw/build-tout-wars-team-season.R
        │           (filter sections, aggregate to team,
        │            inner-join with standings, run reconciliation)
        ▼
data-raw/sources/cache/tout-wars-team-season.rds                 (gitignored)
        │
        │  Stage 2: data-raw/tout-wars-team-season.R
        ▼
data/tout_wars_team_season.rda      (exposed via usethis::use_data)
```

**Why two stages:**

- Stage 1 holds the substantive logic — section filtering, aggregation,
  reconciliation. Inspectable intermediate; easy to diff in git.
- Stage 2 is a thin wrapper that mirrors `data-raw/tout-wars-auctions.R` —
  only this stage writes to `data/`.

## Scope

- **Years:** 2010–2025 inclusive.
- **Leagues:** `"al"`, `"nl"` for 2010–2012; add `"mixed"` from 2013 onward.
- **Standings rows:** all teams in each league-year (typically 12 AL, 13 NL,
  15 Mixed; verified per year, not hardcoded).
- **Roster rows summed for IP / AB / reconciliation numerators:**
  `roster_section ∈ {active, previously_active}`. See "Section selection"
  below.

## Schema

`tout_wars_team_season` is a tibble with class
`c("tbl_df", "tbl", "data.frame")`. Columns, in order:

| Column        | Type      | Notes |
|---------------|-----------|-------|
| `year`        | integer   | 2010..2025 |
| `league`      | character | `"al"`, `"nl"`, `"mixed"` (lowercase) |
| `team_id`     | character | canonical owner; same canonicalization as `tout_wars_auctions$team_owner` |
| `R`           | integer   | runs scored (batting) |
| `HR`          | integer   | home runs (batting) |
| `RBI`         | integer   | runs batted in (batting) |
| `SB`          | integer   | stolen bases (batting) |
| `OBP`         | double    | on-base pct (batting); `NA` when not scored that league-year |
| `AVG`         | double    | batting avg; `NA` when not scored that league-year |
| `W`           | integer   | wins (pitching) |
| `SV`          | integer   | saves (pitching) |
| `SO`          | integer   | strikeouts (pitching) |
| `ERA`         | double    | earned-run avg (pitching) |
| `WHIP`        | double    | walks+hits per IP (pitching) |
| `AB`          | integer   | summed roster AB across selected sections |
| `IP`          | double    | summed roster IP across selected sections |
| `R_pts ... SO_pts` | double | per-category standings points; `NA` when category unscored |
| `total_pts`   | double    | total roto points |

Approximate row count: 2010-2012 (2 leagues × ~12-13 teams × 3 years) +
2013-2025 (3 leagues × ~12-15 teams × 13 years) ≈ **579 team-seasons**.

### Notes on the schema

- **OBP vs AVG.** Both columns always present; whichever rate cat the league
  did not score in a given year is `NA`. `sgp_denominators()` only fits the
  categories you pass in `scoring_categories`, so the `NA` column is harmless.
- **No `IP_pts` / `AB_pts` columns.** `IP` and `AB` are denominators for rate
  stats, not scored categories.
- **`team_id`** intentionally matches the `team_owner` canonicalization in
  `tout_wars_auctions` (last name uppercase, partnerships joined with `/` and
  alphabetized). This lets users do a clean `dplyr::inner_join()` between the
  two datasets on `(year, league, team_id) ↔ (year, league, team_owner)`.

## Stage 1 — Build team-season

**Script:** `data-raw/build-tout-wars-team-season.R`

### Read inputs

- All 45 standings CSVs in `data-raw/sources/tout-wars/standings/` (2010–2025).
- All 45 batter roster CSVs and 45 pitcher roster CSVs in
  `data-raw/sources/tout-wars/rosters/`.

### Section selection

Sum stats only from rows where
`roster_section ∈ {active, previously_active}`. Drop `reserved` and
`previously_reserved`.

Reasoning:

- `active` players are currently on the team's active roster; their stats
  earned during the active window count toward the team's standings totals.
- `previously_active` players were active for some span during the season,
  then released / traded / moved to reserve. Their pre-departure stats
  also counted toward the team. Including them captures injured-but-active
  players, which is the asymmetric case the section selection must get right.
- `reserved` players (currently on reserve / DL) accumulated their reserve
  stats while NOT contributing to the team's totals. Including them would
  overcount.
- `previously_reserved` is similar: their stats accrued during a window
  when the player was on reserve, not contributing.

This decision is documented in the dataset roxygen so future maintainers
understand the trade-off.

### Aggregate to team

For each `(year, league, team)` from the per-player CSVs:

- **Batters (filtered to selected sections):** sum `ab`, plus retain
  `h`-equivalent (= `ab × avg`, rounded), `bb`, `hbp` (if available; absent
  in current scraper output — handle defensively as `NA`-tolerant), and
  `sf` for OBP reconciliation.
- **Pitchers (filtered to selected sections):** sum `ip`, plus retain
  `er`-equivalent (= `ip × era / 9`), `bb`, and `h`-equivalent (= `whip × ip − bb`)
  for ERA / WHIP reconciliation.

Note: the scraper output gives per-player rate columns (`avg`, `obp`, `era`,
`whip`) but no per-player counting columns for hits, earned runs, or
walks-with-hits. Reconstruct per-player numerators from `(rate × denom)` for
reconciliation purposes; round before summing to mirror Onroto's display
precision.

Canonicalize `team` to `team_id` using the same algorithm as
`tout_wars_auctions$team_owner` (last name uppercase, partnerships joined
with `/` and alphabetized).

### Inner-join with standings

For each standings row, canonicalize `team` to `team_id` and join on
`(year, league, team_id)` to bring in the team-aggregated AB / IP plus
reconciliation numerators.

### Reconciliation check

For each team-season, compute:

- `joined_AVG = sum_h_bat / sum_ab`
- `joined_OBP = (sum_h_bat + sum_bb_bat + sum_hbp) / (sum_ab + sum_bb_bat + sum_hbp + sum_sf)`
  (gracefully degraded if HBP/SF absent: `(sum_h_bat + sum_bb_bat) / (sum_ab + sum_bb_bat)`)
- `joined_ERA = sum_er * 9 / sum_ip`
- `joined_WHIP = (sum_bb_pit + sum_h_pit) / sum_ip`

For each scored rate stat present in the standings row:

- Compute the per-team residual: `|joined_<RATE> − standings_<RATE>|`.
- **Tighter tolerances than the original Fangraphs design**, since stats are
  team-attributed, not full-season:
  - AVG / OBP `≤ 0.005`
  - ERA `≤ 0.15`
  - WHIP `≤ 0.020`
- If a residual exceeds tolerance, the row is flagged. If more than 5% of
  team-seasons in any league-year are flagged, Stage 1 aborts with
  `rotostats_error_team_season_reconciliation`.
- A summary table of residuals by league-year is written to
  `data-raw/sources/cache/team-season-residuals.csv` for inspection.

If the reconstruction-from-rate approach proves too lossy (because Onroto
displays AVG to 3 digits, ERA to 2), tolerances may be relaxed during
implementation. The summary table makes this visible.

### Sanity bounds

Per-row asserts before writing the cache:

- `IP ∈ [800, 2000]`.
- `AB ∈ [3500, 6500]`.
- `team_id` non-empty and matches the canonical form regex.
- `(year, league, team_id)` is unique.
- For each league-year where `tout_wars_auctions` has coverage (2012+), the
  set of `team_id` values matches the set of `team_owner` values in
  `tout_wars_auctions` for that same league-year.

Out-of-bounds rows abort with `rotostats_error_team_season_oob`.

### Cache write

Write the validated tibble to
`data-raw/sources/cache/tout-wars-team-season.rds`.

## Stage 2 — Expose as package data

**Script:** `data-raw/tout-wars-team-season.R`

Thin: load the cache, sort by `(year, league, team_id)`, set tibble class,
strip transient attributes, and `usethis::use_data(tout_wars_team_season,
overwrite = TRUE)`.

## Tests

New tests in `tests/testthat/`:

- **`test-tout-wars-team-season.R`** — analogous to
  `test-tout-wars-auctions.R`:
  - Dataset loads; class is `c("tbl_df", "tbl", "data.frame")`.
  - Year range is exactly 2010–2025; no 2026 rows.
  - League values ⊆ `{"al", "nl", "mixed"}`; Mixed only present for years
    ≥ 2013.
  - Per-league-year team count matches the standings file row count.
  - `team_id` set per league-year matches `tout_wars_auctions$team_owner`
    set, where both datasets cover the same league-year.
  - Sanity bounds row-wise: `IP ∈ [800, 2000]`, `AB ∈ [3500, 6500]`.
  - Reconciliation residuals computed at build time pass the documented
    tolerances (residuals fixture committed at
    `tests/testthat/fixtures/team-season-residuals.csv` and re-checked).
- **`test-sgp-denominators-tout-wars.R`** — golden-path integration:
  - Build `league_history()` from `tout_wars_team_season`.
  - Run `sgp_denominators()` on the standard 5×5+OBP categories.
  - Snapshot the resulting denominator vector via `expect_snapshot_value()`.
- **`test-sgp-tout-wars.R`** — small integration: build `league_history()`,
  use the existing Steamer projection fixtures from
  `tests/testthat/fixtures/`, run `sgp()` blended-pool, assert that all rows
  have finite SGP for hitter cats (hitters) and pitcher cats (pitchers).
- **`test-par-tout-wars.R`** — same shape as `test-sgp-tout-wars.R` but
  through `par()`, asserting `total_par` is finite and within plausible
  bounds.

## Documentation

- `R/data-tout-wars-team-season.R` — roxygen `@format` block matching the
  style of `R/data-tout-wars-auctions.R`. Sections cover:
  - Source URLs (Tout Wars standings + the team-stats scraper output).
  - Build provenance (the two `data-raw/` scripts).
  - The section-selection decision (`active + previously_active`) and the
    reconciliation tolerances.
  - The OBP / AVG split per league-year.
- `data-raw/sources/cache/` added to `.gitignore`.

## Dependencies

No new dependencies. `dplyr`, `purrr`, `readr`, `tibble`, `fs`, `glue`,
`cli` are already in DESCRIPTION (used by the auction pipeline).

## Error and warning classes

New classes (registered in `plans/error-messages.md` per project convention):

- `rotostats_error_team_season_reconciliation` — too many residuals out of
  tolerance.
- `rotostats_error_team_season_oob` — IP or AB outside sanity bounds.
- `rotostats_error_team_owner_mismatch` — team_id set doesn't match
  `tout_wars_auctions$team_owner` set for a league-year that overlaps.

## Open questions and follow-ups

These do not block the implementation plan:

1. **Reconciliation tolerances** are initial guesses based on Onroto's
   display precision. After the first build, inspect the residual
   distribution and tighten if possible.
2. **Per-player dataset.** With team-attributed per-player stats already on
   disk, exposing a `tout_wars_player_seasons` dataset is a small follow-up
   if/when consumers need it.
3. **`previously_*` eligibility.** The team-stats scraper currently writes
   empty `eligibility` for `previously_*` rows (Phase 2 follow-up in the
   scraper spec). The team-season build doesn't depend on `eligibility`, so
   this doesn't block here.
