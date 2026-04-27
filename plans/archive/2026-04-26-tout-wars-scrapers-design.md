# Tout Wars Onroto Scrapers — Design

**Date:** 2026-04-26
**Status:** Draft → ready for implementation plan
**Owner:** Jacob Dennen

## Goal

Port two Python scrapers from `~/roto-models/scrapers/` into `rotostats/data-raw/` so we can produce, for each Tout Wars league-year, two CSVs that feed `sgp()` and `par()`:

1. **Standings** — final per-team points + raw category totals.
2. **End-of-season rosters** — player-level data (team, position, salary, status, eligibility).

Auction results are out of scope; the CSVs already exist in `data-raw/sources/tout-wars/{year}-{league}.csv`.

## Source

- **Site:** `https://onroto.fangraphs.com`
- **League codes:** `toutal` (AL), `toutnl` (NL), `toutmixed` (Mixed)
- **Auth:** guest session — every page accepts `session_id=guest` (verified against 2025 standings and roster pages).
- **URL grammar:**
  - Standings: `display_stand.pl?{LEAGUE}+0+{YEAR}&session_id=guest`
  - Rosters: `display_roster.pl?{LEAGUE}+0+all+{YEAR}&session_id=guest`

## Year × league coverage

| League | Years scraped |
|---|---|
| `toutal` | 2010–2025 |
| `toutnl` | 2010–2025 |
| `toutmixed` | 2013–2025 (Mixed launched in 2013) |

Total: 16 + 16 + 13 = **45 league-years**, two pages each = **90 fetches**. With 0.5 s polite sleep, end-to-end runtime ≈ 1 minute.

## Layout in rotostats

```
rotostats/
└── data-raw/
    └── sources/
        └── tout-wars/
            ├── auctions/                    ← MOVED: existing auction CSVs
            │   ├── 2012-al.csv
            │   ├── 2012-mixed.csv
            │   ├── 2012-nl.csv
            │   └── …
            ├── standings/                   ← NEW: scraper output
            │   ├── 2010-al.csv
            │   ├── 2010-nl.csv
            │   ├── 2013-mixed.csv
            │   └── …
            ├── rosters/                     ← NEW: scraper output
            │   ├── 2010-al.csv
            │   └── …
            └── scrape/                      ← NEW: Python scrapers
                ├── README.md
                ├── requirements.txt         ← requests, beautifulsoup4, lxml, pandas
                ├── auth.py                  ← guest-session helper
                ├── standings.py
                ├── rosters.py
                └── run_all.py               ← orchestrator over (league, year) grid
```

All three data products (auctions, standings, rosters) live in parallel subfolders. Filename pattern `{year}-{league}.csv` is consistent across all three. Code is colocated under `tout-wars/scrape/`.

**Migration step:** the existing auction CSVs at `data-raw/sources/tout-wars/{year}-{league}.csv` need to be moved (via `git mv`) into `data-raw/sources/tout-wars/auctions/`. Any R-side ingest code that reads them will need its glob/path updated.

## Output schemas

### `standings/{year}-{league}.csv`

| Column | Type | Description |
|---|---|---|
| `year` | int | Season |
| `league` | str | One of `al`, `nl`, `mixed` |
| `team` | str | Team display name from summary row |
| `R`, `HR`, `RBI`, `SB`, `OBP`, `W`, `SV`, `ERA`, `WHIP`, `SO` | numeric | Raw season totals (one column per category) |
| `R_pts`, `HR_pts`, …, `SO_pts` | float | Points awarded per category |
| `total_pts` | float | Sum of category points |

Categories are emitted in the order returned by the page (Tout Wars uses 10 cats consistently 2010–2025; if a league-year ever has fewer cats, missing columns are left `NA`).

### `rosters/{year}-{league}.csv`

| Column | Type | Description |
|---|---|---|
| `year` | int | Season |
| `league` | str | `al` / `nl` / `mixed` |
| `team` | str | Fantasy team display name (from `<p class='team_NNNN'>` block) |
| `player_name` | str | Cleaned (annotations like `(Off DL)` stripped) |
| `player_id` | str \| NA | OnRoto numeric player ID parsed from profile-link URL |
| `mlb_team` | str | MLB team abbreviation |
| `position` | str | Roster position (slot) |
| `salary` | int | Auction salary (0 if blank) |
| `status` | str | `act`, `res`, `dl`, etc. |
| `eligibility` | str | Position eligibility list (e.g. `1B,SW,INF`) |
| `roster_section` | str | `active` or `reserved` |

**No `contract_year`** — Tout Wars is redraft, so the column doesn't exist on the page. (The Moonlight Graham version had it because that league has keepers.)

## Code changes from the originals

### `auth.py` — simplify to guest

```python
def guest_session() -> tuple[requests.Session, str]:
    session = requests.Session()
    session.get(BASE_URL)
    return session, "guest"
```

No `.env`, no credentials, no `index.pl` POST. Hardcoded `BASE_URL = "https://onroto.fangraphs.com"`.

### `standings.py`

- Add `"ON BASE PCT": "OBP"` to `CAT_HEADER_MAP`.
- Replace hardcoded `ALL_CATS = [...]` with dynamic emission: write whatever cats appear in `year_cats`. (Tout Wars uses the same 10 cats every year, so in practice this just produces the same column set.)
- Loop the outer scrape over `[(league_code, league_short, years), …]`:
  - `("toutal", "al", range(2010, 2026))`
  - `("toutnl", "nl", range(2010, 2026))`
  - `("toutmixed", "mixed", range(2013, 2026))`
- Write one CSV per `(league, year)` to `standings/{year}-{league}.csv`.

### `rosters.py`

- **Detect column positions from headers**, not hardcoded indices. Read the table's `<th>` row, find the indices of `Sal`, `Stat`, `Elig`, and the player-name column, then use those to extract values. This keeps the parser robust across leagues with different column layouts.
- Drop the `contract_year` field; add `roster_section` (`active` / `reserved`).
- Add `league` column.
- Remove the hardcoded 10/11-team validation; replace with a soft per-(league, year) sanity check that just logs the team count.
- Same `(league, year)` outer loop as standings.

### `run_all.py`

Thin orchestrator: invokes `scrape_standings()` and `scrape_rosters()` from the two modules. Single entry point so a contributor can run `python -m scrape.run_all` from `data-raw/sources/tout-wars/`.

## Validation

Run-time sanity logging (printed, not asserted):

- **Standings:** team count per (league, year). Warn if `total_pts` doesn't sum the per-category point columns.
- **Rosters:** team count and player count per (league, year). Warn if a team has fewer than 23 players (the standard Tout Wars roster size).

No hard fails — log warnings and keep going so a single bad year doesn't tank the whole scrape.

## Non-goals

- Transactions, AB/IP team-stats totals, previously-active players, current-season pre-auction rosters. (Easy to port from `~/roto-models/scrapers/` later if `sgp()`/`par()` work surfaces a need.)
- R-side ingestion (turning these CSVs into package data via `data-raw/`'s R scripts). That's a separate piece of work, downstream of this scrape.
- Backfill of pre-2010 years. The user has confirmed Onroto only exposes 2010–2025.

## Open questions

None blocking. Two minor things to confirm during implementation:

1. Whether the Tout Wars 2010–2012 standings pages use the same 10-cat layout as 2025, or an earlier 8-cat layout. If different, the dynamic-headers approach in `standings.py` will handle it transparently — the CSV will just have fewer raw-stat columns for those years.
2. Whether early-year Mixed pages (2013) match the 2025 HTML structure. Visit one manually before bulk-running.
