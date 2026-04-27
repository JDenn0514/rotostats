# Tout Wars Onroto Scrapers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port two Python scrapers (standings, end-of-season rosters) from `~/roto-models/scrapers/` into `rotostats/data-raw/sources/tout-wars/scrape/`, scrape all three Tout Wars leagues × all available years, and reorganize existing auction CSVs into a parallel `auctions/` subfolder.

**Architecture:** Three sibling subfolders under `data-raw/sources/tout-wars/`: `auctions/` (existing CSVs, moved), `standings/` (new scraper output), `rosters/` (new scraper output). A `scrape/` folder holds the Python code: `auth.py` (guest session), `standings.py`, `rosters.py`, `run_all.py` (orchestrator). Parsers are tested against saved HTML fixtures using pytest.

**Tech Stack:** Python 3.11+, `requests`, `beautifulsoup4`, `lxml`, `pandas`, `pytest`. No credentials — Onroto accepts `session_id=guest` for all read pages.

**Reference spec:** `plans/specs/2026-04-26-tout-wars-scrapers-design.md`

**Source code being ported:** `~/roto-models/scrapers/{auth,standings,rosters}.py`

---

## File map

**Created:**
- `data-raw/sources/tout-wars/scrape/auth.py`
- `data-raw/sources/tout-wars/scrape/standings.py`
- `data-raw/sources/tout-wars/scrape/rosters.py`
- `data-raw/sources/tout-wars/scrape/run_all.py`
- `data-raw/sources/tout-wars/scrape/requirements.txt`
- `data-raw/sources/tout-wars/scrape/README.md`
- `data-raw/sources/tout-wars/scrape/.gitignore`
- `data-raw/sources/tout-wars/scrape/tests/__init__.py`
- `data-raw/sources/tout-wars/scrape/tests/test_standings.py`
- `data-raw/sources/tout-wars/scrape/tests/test_rosters.py`
- `data-raw/sources/tout-wars/scrape/tests/fixtures/standings_2025_al.html`
- `data-raw/sources/tout-wars/scrape/tests/fixtures/rosters_2025_al.html`
- `data-raw/sources/tout-wars/auctions/` (directory; receives moved CSVs)
- `data-raw/sources/tout-wars/standings/` (directory; receives output CSVs)
- `data-raw/sources/tout-wars/rosters/` (directory; receives output CSVs)

**Moved (via `git mv`):**
- 45 files: `data-raw/sources/tout-wars/{2012..2026}-{al,mixed,nl}.csv` → `data-raw/sources/tout-wars/auctions/{year}-{league}.csv`

---

## Task 0: Branch + scaffolding

**Files:**
- Create directories only

- [ ] **Step 1: Create feature branch from `develop`**

```bash
cd /Users/jacobdennen/rotostats
git checkout develop
git pull
git checkout -b feature/tout-wars-scrapers
```

- [ ] **Step 2: Create the three output directories and the scrape/ skeleton**

```bash
mkdir -p data-raw/sources/tout-wars/auctions
mkdir -p data-raw/sources/tout-wars/standings
mkdir -p data-raw/sources/tout-wars/rosters
mkdir -p data-raw/sources/tout-wars/scrape/tests/fixtures
touch data-raw/sources/tout-wars/scrape/tests/__init__.py
```

- [ ] **Step 3: Verify**

```bash
ls -d data-raw/sources/tout-wars/{auctions,standings,rosters,scrape,scrape/tests,scrape/tests/fixtures}
```

Expected: all six paths print without error.

---

## Task 1: Move existing auction CSVs into `auctions/`

**Files:**
- Move: 45 CSVs from `data-raw/sources/tout-wars/*.csv` → `data-raw/sources/tout-wars/auctions/`

- [ ] **Step 1: Confirm count of files to move**

```bash
ls data-raw/sources/tout-wars/*.csv | wc -l
```

Expected: `45`

- [ ] **Step 2: Move them with `git mv` (preserves history)**

```bash
cd /Users/jacobdennen/rotostats
for f in data-raw/sources/tout-wars/*.csv; do
  git mv "$f" "data-raw/sources/tout-wars/auctions/$(basename "$f")"
done
```

- [ ] **Step 3: Verify**

```bash
ls data-raw/sources/tout-wars/*.csv 2>&1 | head
ls data-raw/sources/tout-wars/auctions/*.csv | wc -l
```

Expected: top command prints `No matches`. Bottom prints `45`.

- [ ] **Step 4: Search for any R code referencing the old paths**

```bash
grep -rn 'sources/tout-wars/[0-9]' R/ data-raw/ 2>/dev/null
```

If anything matches, update those references to add `/auctions/` to the path. If nothing matches, no further action needed.

- [ ] **Step 5: Commit**

```bash
git commit -m "data(tout-wars): move auction CSVs into auctions/ subfolder

Reorganize data-raw/sources/tout-wars/ to make room for parallel
standings/ and rosters/ subfolders fed by the new Python scrapers."
```

---

## Task 2: scrape/ scaffolding (requirements, README, gitignore, auth)

**Files:**
- Create: `data-raw/sources/tout-wars/scrape/requirements.txt`
- Create: `data-raw/sources/tout-wars/scrape/.gitignore`
- Create: `data-raw/sources/tout-wars/scrape/README.md`
- Create: `data-raw/sources/tout-wars/scrape/auth.py`

- [ ] **Step 1: Write `requirements.txt`**

```
beautifulsoup4>=4.12
lxml>=5.0
pandas>=2.0
pytest>=8.0
requests>=2.31
```

- [ ] **Step 2: Write `.gitignore`**

```
__pycache__/
*.pyc
.venv/
venv/
.pytest_cache/
```

- [ ] **Step 3: Write `auth.py`**

```python
"""Onroto guest-session helper for Tout Wars scrapers.

Onroto accepts session_id=guest for all read-only pages — no login required.
"""

import requests

BASE_URL = "https://onroto.fangraphs.com"
GUEST_SESSION_ID = "guest"


def guest_session() -> tuple[requests.Session, str]:
    """Return a fresh requests.Session and the guest session id.

    The session has a UA header set so we don't look like a default
    python-requests user agent.
    """
    session = requests.Session()
    session.headers.update(
        {"User-Agent": "rotostats-tout-scraper/0.1 (+https://github.com/jdennen/rotostats)"}
    )
    return session, GUEST_SESSION_ID
```

- [ ] **Step 4: Write `README.md`**

````markdown
# Tout Wars Onroto scrapers

Two Python scrapers that pull final standings and end-of-season rosters
for all three Tout Wars leagues (`toutal`, `toutnl`, `toutmixed`) from
[Onroto](https://onroto.fangraphs.com). Output goes to
`../standings/{year}-{league}.csv` and `../rosters/{year}-{league}.csv`.

The site accepts `session_id=guest` for all read pages — no credentials.

## Setup

```bash
cd data-raw/sources/tout-wars/scrape
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

Full scrape (45 league-years, ~1 minute):

```bash
python run_all.py
```

Single scraper:

```bash
python standings.py        # writes ../standings/*.csv
python rosters.py          # writes ../rosters/*.csv
```

## Tests

```bash
pytest tests/
```

Tests run the parsers against saved HTML fixtures in `tests/fixtures/` —
they don't hit the network.

## Year coverage

| League        | Years      |
|---------------|------------|
| `toutal` (AL) | 2010–2025  |
| `toutnl` (NL) | 2010–2025  |
| `toutmixed`   | 2013–2025  |
````

- [ ] **Step 5: Verify auth module imports cleanly**

```bash
cd data-raw/sources/tout-wars/scrape
python -c "from auth import guest_session; s, sid = guest_session(); print(sid)"
```

Expected: prints `guest`.

- [ ] **Step 6: Commit**

```bash
cd /Users/jacobdennen/rotostats
git add data-raw/sources/tout-wars/scrape/
git commit -m "feat(tout-wars): add scraper scaffolding

requirements.txt, README, gitignore, and a guest-session auth helper.
Onroto accepts session_id=guest for all read pages, so no credentials
are needed."
```

---

## Task 3: Save HTML fixtures for parser tests

**Files:**
- Create: `data-raw/sources/tout-wars/scrape/tests/fixtures/standings_2025_al.html`
- Create: `data-raw/sources/tout-wars/scrape/tests/fixtures/rosters_2025_al.html`

- [ ] **Step 1: Download the 2025 AL standings page**

```bash
cd /Users/jacobdennen/rotostats
curl -s 'https://onroto.fangraphs.com/baseball/webnew/display_stand.pl?toutal+0+2025&session_id=guest' \
  -o data-raw/sources/tout-wars/scrape/tests/fixtures/standings_2025_al.html
```

- [ ] **Step 2: Download the 2025 AL rosters page**

```bash
curl -s 'https://onroto.fangraphs.com/baseball/webnew/display_roster.pl?toutal+0+all+2025&session_id=guest' \
  -o data-raw/sources/tout-wars/scrape/tests/fixtures/rosters_2025_al.html
```

- [ ] **Step 3: Sanity-check both files**

```bash
wc -l data-raw/sources/tout-wars/scrape/tests/fixtures/*.html
grep -c "Team Name" data-raw/sources/tout-wars/scrape/tests/fixtures/standings_2025_al.html
grep -c "team_2008064" data-raw/sources/tout-wars/scrape/tests/fixtures/rosters_2025_al.html
```

Expected: both files have hundreds of lines; standings has at least 1 "Team Name" match; rosters has at least 12 "team_2008064" matches (one per team).

- [ ] **Step 4: Commit**

```bash
git add data-raw/sources/tout-wars/scrape/tests/fixtures/
git commit -m "test(tout-wars): add 2025 AL HTML fixtures for parser tests

Standings and rosters pages saved verbatim for offline parser tests."
```

---

## Task 4: Standings parser + scraper

**Files:**
- Create: `data-raw/sources/tout-wars/scrape/standings.py`
- Create: `data-raw/sources/tout-wars/scrape/tests/test_standings.py`

- [ ] **Step 1: Write the failing parser test**

Create `data-raw/sources/tout-wars/scrape/tests/test_standings.py`:

```python
"""Tests for the standings parser, run against saved HTML fixtures."""

from pathlib import Path

import pytest
from bs4 import BeautifulSoup

from standings import parse_summary_table, parse_category_tables

FIXTURE_DIR = Path(__file__).parent / "fixtures"


@pytest.fixture
def soup_2025_al():
    html = (FIXTURE_DIR / "standings_2025_al.html").read_text()
    return BeautifulSoup(html, "lxml")


def test_parse_summary_table_2025_al(soup_2025_al):
    cats, teams = parse_summary_table(soup_2025_al)
    # Tout Wars 2025 uses 10 cats, OBP not AVG
    assert cats == ["R", "HR", "RBI", "SB", "OBP", "W", "SV", "ERA", "WHIP", "SO"]
    # Tout Wars AL has 12 teams
    assert len(teams) == 12
    # Sample row from the verification: Andy Andres scored 101.0 total
    assert teams["Andy Andres"]["total_pts"] == 101.0
    assert teams["Andy Andres"]["R_pts"] == 10.0
    assert teams["Andy Andres"]["OBP_pts"] == 12.0


def test_parse_category_tables_2025_al(soup_2025_al):
    raw = parse_category_tables(soup_2025_al)
    # Every team should have all 10 raw stats
    expected_cats = {"R", "HR", "RBI", "SB", "OBP", "W", "SV", "ERA", "WHIP", "SO"}
    assert len(raw) == 12
    for team, stats in raw.items():
        missing = expected_cats - stats.keys()
        assert not missing, f"{team} missing {missing}"
```

- [ ] **Step 2: Run test — expect import error**

```bash
cd data-raw/sources/tout-wars/scrape
pytest tests/test_standings.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'standings'`.

- [ ] **Step 3: Write `standings.py`**

```python
"""Scrape final standings + per-category totals for all three Tout Wars
leagues from Onroto.

Output: ../standings/{year}-{league}.csv

Each CSV row is one team in one league-year, with columns:
  year, league, team,
  R, R_pts, HR, HR_pts, ..., SO, SO_pts,
  total_pts

Categories are detected dynamically from the page header, so any layout
shift across years is handled transparently. ALL_CATS is the union order
used when writing the CSV.
"""

import time
from pathlib import Path

import pandas as pd
import requests
from bs4 import BeautifulSoup

from auth import BASE_URL, guest_session

OUT_DIR = Path(__file__).parent.parent / "standings"

LEAGUES = [
    ("toutal", "al", range(2010, 2026)),
    ("toutnl", "nl", range(2010, 2026)),
    ("toutmixed", "mixed", range(2013, 2026)),
]

ALL_CATS = ["R", "HR", "RBI", "SB", "OBP", "AVG", "W", "SV", "ERA", "WHIP", "SO"]

CAT_HEADER_MAP = {
    "RUNS": "R",
    "HOME RUNS": "HR",
    "RBIS": "RBI",
    "STOLEN BASES": "SB",
    "ON BASE PCT": "OBP",
    "AVERAGE": "AVG",
    "WINS": "W",
    "SAVES": "SV",
    "ERA": "ERA",
    "(W + H) / IP": "WHIP",
    "STRIKE OUTS": "SO",
}


def fetch_standings(session: requests.Session, sid: str, league_code: str, year: int) -> str:
    url = (
        f"{BASE_URL}/baseball/webnew/display_stand.pl?"
        f"{league_code}+0+{year}&session_id={sid}"
    )
    resp = session.get(url)
    resp.raise_for_status()
    return resp.text


def parse_summary_table(soup: BeautifulSoup) -> tuple[list[str], dict[str, dict]]:
    """Parse the main standings summary table.

    Returns (year_cats_in_order, {team_name: {cat_pts: ..., total_pts: ...}}).
    """
    teams: dict[str, dict] = {}
    year_cats: list[str] = []
    for table in soup.find_all("table"):
        ths = table.find_all("th")
        headers = [th.get_text(strip=True) for th in ths]
        if "Team Name" not in headers or "TOTAL" not in headers:
            continue
        if len(headers) > 15:
            continue

        total_idx = headers.index("TOTAL")
        year_cats = headers[1:total_idx]

        for row in table.find_all("tr"):
            cells = row.find_all("td")
            if not cells or len(cells) < len(year_cats) + 2:
                continue
            team_name = cells[0].get_text(strip=True)
            if not team_name:
                continue
            team_data = {}
            for i, cat in enumerate(year_cats):
                team_data[f"{cat}_pts"] = float(cells[i + 1].get_text(strip=True))
            team_data["total_pts"] = float(cells[total_idx].get_text(strip=True))
            teams[team_name] = team_data
        if teams:
            break
    return year_cats, teams


def parse_category_tables(soup: BeautifulSoup) -> dict[str, dict]:
    """Parse the per-category breakdown tables to extract raw stat values."""
    teams: dict[str, dict] = {}

    for table in soup.find_all("table"):
        ths = table.find_all("th")
        if not ths:
            continue
        first_th = ths[0].get_text(strip=True)
        if first_th not in CAT_HEADER_MAP:
            continue
        if len(ths) > 8:
            continue

        cat_key = CAT_HEADER_MAP[first_th]

        for row in table.find_all("tr"):
            cells = row.find_all("td")
            if not cells:
                continue
            i = 0
            while i + 4 < len(cells):
                team_name = cells[i].get_text(strip=True)
                raw_str = cells[i + 1].get_text(strip=True)
                i += 5

                if not team_name or not raw_str:
                    continue

                try:
                    if cat_key in ("AVG", "OBP", "ERA", "WHIP"):
                        raw_value = float(raw_str)
                    else:
                        raw_value = int(raw_str)
                except ValueError:
                    continue

                teams.setdefault(team_name, {})[cat_key] = raw_value

    return teams


def scrape_one(session, sid, league_code: str, league_short: str, year: int) -> pd.DataFrame | None:
    """Fetch and parse one league-year. Returns a DataFrame or None on empty."""
    html = fetch_standings(session, sid, league_code, year)
    soup = BeautifulSoup(html, "lxml")

    year_cats, points_data = parse_summary_table(soup)
    raw_data = parse_category_tables(soup)

    if not points_data:
        print(f"  WARN: no summary table for {league_short} {year}")
        return None

    rows = []
    for team_name, pts in points_data.items():
        record = {"year": year, "league": league_short, "team": team_name}
        raw = raw_data.get(team_name, {})
        for cat in ALL_CATS:
            record[cat] = raw.get(cat)
            record[f"{cat}_pts"] = pts.get(f"{cat}_pts")
        record["total_pts"] = pts.get("total_pts")
        rows.append(record)

    cols = ["year", "league", "team"]
    for cat in ALL_CATS:
        cols.extend([cat, f"{cat}_pts"])
    cols.append("total_pts")
    return pd.DataFrame(rows)[cols]


def main() -> None:
    session, sid = guest_session()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    for league_code, league_short, years in LEAGUES:
        for year in years:
            print(f"Fetching {league_short} {year}...")
            try:
                df = scrape_one(session, sid, league_code, league_short, year)
            except requests.HTTPError as e:
                print(f"  WARN: HTTP error for {league_short} {year}: {e}")
                continue

            if df is None or df.empty:
                continue

            out = OUT_DIR / f"{year}-{league_short}.csv"
            df.to_csv(out, index=False)
            print(f"  -> {out.name} ({len(df)} teams)")
            time.sleep(0.5)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
cd data-raw/sources/tout-wars/scrape
pytest tests/test_standings.py -v
```

Expected: 2 passed. If `parse_summary_table` returns the wrong cats, check the fixture is valid HTML; if `Andy Andres` isn't found, the team naming on the page may have a leading non-breaking space — strip more aggressively.

- [ ] **Step 5: Smoke-test against the live site for one year**

```bash
cd data-raw/sources/tout-wars/scrape
python -c "
from auth import guest_session
import standings
s, sid = guest_session()
df = standings.scrape_one(s, sid, 'toutal', 'al', 2025)
print(df.head())
print('shape:', df.shape)
assert df.shape == (12, 26), df.shape
print('OK')
"
```

Expected: prints a DataFrame head and `OK`. (12 teams × 26 columns: 3 id cols + 11 cats × 2 (raw + pts) + total_pts. AVG cols are all NaN since Tout Wars uses OBP.)

- [ ] **Step 6: Run the full scrape**

```bash
cd data-raw/sources/tout-wars/scrape
python standings.py
```

Expected: prints ~45 "-> YYYY-{league}.csv (N teams)" lines and writes 45 CSVs to `../standings/`.

- [ ] **Step 7: Verify output**

```bash
ls /Users/jacobdennen/rotostats/data-raw/sources/tout-wars/standings/ | wc -l
head -2 /Users/jacobdennen/rotostats/data-raw/sources/tout-wars/standings/2025-al.csv
```

Expected: 45 files; header line shows `year,league,team,R,R_pts,HR,HR_pts,...`.

- [ ] **Step 8: Commit**

```bash
cd /Users/jacobdennen/rotostats
git add data-raw/sources/tout-wars/scrape/standings.py \
        data-raw/sources/tout-wars/scrape/tests/test_standings.py \
        data-raw/sources/tout-wars/standings/
git commit -m "feat(tout-wars): scrape final standings for all three leagues

Adds standings.py and tests/test_standings.py. Supports both AVG (older
seasons) and OBP (Tout Wars from 2010+) by treating the category list as
dynamic per-page. Output is ../standings/{year}-{league}.csv covering
toutal/toutnl 2010-2025 and toutmixed 2013-2025."
```

---

## Task 5: Rosters parser + scraper

**Files:**
- Create: `data-raw/sources/tout-wars/scrape/rosters.py`
- Create: `data-raw/sources/tout-wars/scrape/tests/test_rosters.py`

- [ ] **Step 1: Write the failing parser test**

Create `data-raw/sources/tout-wars/scrape/tests/test_rosters.py`:

```python
"""Tests for the rosters parser, run against saved HTML fixtures."""

from pathlib import Path

import pytest

from rosters import parse_roster_page

FIXTURE_DIR = Path(__file__).parent / "fixtures"


@pytest.fixture
def html_2025_al():
    return (FIXTURE_DIR / "rosters_2025_al.html").read_text()


def test_parse_roster_page_2025_al(html_2025_al):
    records = parse_roster_page(html_2025_al, year=2025, league_short="al")

    # 12 teams, each with ~23 active + a handful reserved
    teams = {r["team"] for r in records}
    assert len(teams) == 12, f"got {len(teams)} teams, expected 12"

    # Schema check on the first record
    first = records[0]
    expected_keys = {
        "year", "league", "team", "player_name", "player_id", "mlb_team",
        "position", "salary", "status", "eligibility", "roster_section",
    }
    assert set(first.keys()) == expected_keys, set(first.keys()) ^ expected_keys

    # Schema check: no contract_year column
    assert "contract_year" not in first

    # Both active and reserved sections present
    sections = {r["roster_section"] for r in records}
    assert sections == {"active", "reserved"}

    # league + year propagated
    assert first["year"] == 2025
    assert first["league"] == "al"

    # Salary parses as int; status/elig as strings
    salaries = [r["salary"] for r in records if r["salary"] > 0]
    assert all(isinstance(s, int) for s in salaries)
    assert len(salaries) >= 200, f"expected lots of nonzero salaries, got {len(salaries)}"
```

- [ ] **Step 2: Run test — expect import error**

```bash
cd data-raw/sources/tout-wars/scrape
pytest tests/test_rosters.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'rosters'`.

- [ ] **Step 3: Write `rosters.py`**

```python
"""Scrape end-of-season rosters for all three Tout Wars leagues.

Output: ../rosters/{year}-{league}.csv

Tout Wars roster pages have 6 stat columns per player (Pos, Name, Team,
Sal, Stat, Elig) — no contract-year column, since Tout Wars is a redraft
auction league. The parser detects the column positions from the table
header so it stays robust if the layout changes.
"""

import re
import time
from pathlib import Path

import pandas as pd
import requests
from bs4 import BeautifulSoup, Tag

from auth import BASE_URL, guest_session

OUT_DIR = Path(__file__).parent.parent / "rosters"

LEAGUES = [
    ("toutal", "al", range(2010, 2026)),
    ("toutnl", "nl", range(2010, 2026)),
    ("toutmixed", "mixed", range(2013, 2026)),
]

PLAYER_ID_RE = re.compile(r"\+(\d+)&")
ANNOTATION_RE = re.compile(r"\s*\((?:Off DL|Non Elig Pos|DL|Farm|Res)\s*\)\s*$")


def fetch_rosters(session: requests.Session, sid: str, league_code: str, year: int) -> str:
    url = (
        f"{BASE_URL}/baseball/webnew/display_roster.pl?"
        f"{league_code}+0+all+{year}&session_id={sid}"
    )
    resp = session.get(url)
    resp.raise_for_status()
    return resp.text


def _player_name_and_id(name_cell: Tag) -> tuple[str | None, str | None]:
    link = name_cell.find("a", href=True)
    if link is None:
        raw = name_cell.get_text(strip=True)
        return (raw.lstrip("#").strip() or None), None
    raw_name = ANNOTATION_RE.sub("", link.get_text()).lstrip("#").strip()
    m = PLAYER_ID_RE.search(link["href"])
    return (raw_name or None), (m.group(1) if m else None)


def _column_indices(table: Tag) -> dict[str, int] | None:
    """Map header text -> column index for the stat columns we care about.

    Returns None if the table isn't a player table (no recognizable headers).
    Header row uses <th class="white_on_grey12">. Tout Wars headers:
      Pos | Active Players | Team | Sal | Stat | Elig | Games Played By Position | DH | C | 1B | ...
    """
    th_row = table.find("tr")
    if th_row is None:
        return None
    headers = [th.get_text(strip=True) for th in th_row.find_all("th")]
    idx = {h: i for i, h in enumerate(headers)}
    required = {"Pos", "Team", "Sal", "Stat", "Elig"}
    if not required.issubset(idx):
        return None
    # Player-name column has variable label across leagues ("Name",
    # "Active Players", "Reserved Players"). Find it by exclusion.
    name_cols = [
        h for h in headers
        if h not in {"Pos", "Team", "Sal", "Stat", "Elig",
                     "Games Played By Position",
                     "DH", "C", "1B", "2B", "3B", "SS", "OF"}
    ]
    if not name_cols:
        return None
    idx["__name__"] = idx[name_cols[0]]
    return idx


def _parse_player_table(table: Tag, section: str) -> list[dict]:
    cols = _column_indices(table)
    if cols is None:
        return []

    players: list[dict] = []
    for row in table.find_all("tr"):
        cells = row.find_all("td")
        if len(cells) < max(cols.values()) + 1:
            continue
        # Skip rows that are sub-headers (no <td>, just <th>) — already filtered
        # because find_all("td") returns []. Skip TOTAL/footer rows too.
        first_text = cells[0].get_text(strip=True)
        if first_text.upper().startswith("TOTAL"):
            continue

        position = first_text
        name_cell = cells[cols["__name__"]]
        player_name, player_id = _player_name_and_id(name_cell)
        if not player_name:
            continue

        sal_text = cells[cols["Sal"]].get_text(strip=True)
        try:
            salary = int(sal_text)
        except (ValueError, TypeError):
            salary = 0

        players.append({
            "player_name": player_name,
            "player_id": player_id,
            "mlb_team": cells[cols["Team"]].get_text(strip=True),
            "position": position,
            "salary": salary,
            "status": cells[cols["Stat"]].get_text(strip=True),
            "eligibility": cells[cols["Elig"]].get_text(strip=True),
            "roster_section": section,
        })
    return players


def _team_name(team_p: Tag) -> str:
    b = team_p.find("b")
    if b:
        return b.get_text(strip=True)
    return team_p.get_text(strip=True).split(",")[0].strip()


def _team_tables(team_p: Tag) -> list[tuple[Tag, str]]:
    """Walk forward from a team's <p> tag, collecting (table, section) pairs
    until the next team's <p> tag."""
    out: list[tuple[Tag, str]] = []
    sib = team_p.next_sibling
    while sib is not None:
        if isinstance(sib, Tag):
            if sib.name == "p" and sib.get("class") and any(
                c.startswith("team_") for c in sib.get("class", [])
            ):
                break
            if sib.name == "table":
                classes = " ".join(sib.get("class", []))
                if "Active_table" in classes:
                    out.append((sib, "active"))
                elif "Reserved_table" in classes:
                    out.append((sib, "reserved"))
        sib = sib.next_sibling
    return out


def parse_roster_page(html: str, year: int, league_short: str) -> list[dict]:
    soup = BeautifulSoup(html, "lxml")
    records: list[dict] = []
    team_ps = soup.find_all("p", class_=re.compile(r"^team_"))
    if not team_ps:
        return records

    for team_p in team_ps:
        team_name = _team_name(team_p)
        for table, section in _team_tables(team_p):
            for player in _parse_player_table(table, section):
                records.append({
                    "year": year,
                    "league": league_short,
                    "team": team_name,
                    **player,
                })
    return records


def scrape_one(session, sid, league_code: str, league_short: str, year: int) -> pd.DataFrame | None:
    html = fetch_rosters(session, sid, league_code, league_short, year)
    records = parse_roster_page(html, year, league_short)
    if not records:
        print(f"  WARN: no roster data for {league_short} {year}")
        return None
    cols = [
        "year", "league", "team", "player_name", "player_id", "mlb_team",
        "position", "salary", "status", "eligibility", "roster_section",
    ]
    return pd.DataFrame(records)[cols]


def main() -> None:
    session, sid = guest_session()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    for league_code, league_short, years in LEAGUES:
        for year in years:
            print(f"Fetching {league_short} {year} rosters...")
            try:
                df = scrape_one(session, sid, league_code, league_short, year)
            except requests.HTTPError as e:
                print(f"  WARN: HTTP error for {league_short} {year}: {e}")
                continue

            if df is None or df.empty:
                continue

            out = OUT_DIR / f"{year}-{league_short}.csv"
            df.to_csv(out, index=False)
            n_teams = df["team"].nunique()
            print(f"  -> {out.name} ({n_teams} teams, {len(df)} players)")
            time.sleep(0.5)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
cd data-raw/sources/tout-wars/scrape
pytest tests/test_rosters.py -v
```

Expected: 1 passed. If it fails on team-count, check whether the fixture has all 12 `team_2008064` blocks (should — verified during fixture download). If schema check fails, the parser is producing extra/missing keys — print `set(first.keys())` to debug.

- [ ] **Step 5: Smoke-test against the live site**

```bash
cd data-raw/sources/tout-wars/scrape
python -c "
from auth import guest_session
import rosters
s, sid = guest_session()
df = rosters.scrape_one(s, sid, 'toutal', 'al', 2025)
print(df.head())
print('teams:', df['team'].nunique(), 'players:', len(df))
print('sections:', df['roster_section'].value_counts().to_dict())
"
```

Expected: 12 teams, ~280-340 players total (23 active × 12 + reserves), both sections present.

- [ ] **Step 6: Run the full scrape**

```bash
cd data-raw/sources/tout-wars/scrape
python rosters.py
```

Expected: prints ~45 "-> YYYY-{league}.csv (N teams, M players)" lines.

- [ ] **Step 7: Verify output**

```bash
ls /Users/jacobdennen/rotostats/data-raw/sources/tout-wars/rosters/ | wc -l
head -2 /Users/jacobdennen/rotostats/data-raw/sources/tout-wars/rosters/2025-al.csv
```

Expected: 45 files; header line shows `year,league,team,player_name,player_id,mlb_team,position,salary,status,eligibility,roster_section`.

- [ ] **Step 8: Commit**

```bash
cd /Users/jacobdennen/rotostats
git add data-raw/sources/tout-wars/scrape/rosters.py \
        data-raw/sources/tout-wars/scrape/tests/test_rosters.py \
        data-raw/sources/tout-wars/rosters/
git commit -m "feat(tout-wars): scrape end-of-season rosters for all three leagues

Adds rosters.py and tests/test_rosters.py. The parser detects column
positions from each table's header row, so it works against Tout Wars'
6-column layout (no contract column, since the league is redraft) and
would adapt to a different layout without changes."
```

---

## Task 6: `run_all.py` orchestrator

**Files:**
- Create: `data-raw/sources/tout-wars/scrape/run_all.py`

- [ ] **Step 1: Write `run_all.py`**

```python
"""Run both scrapers end-to-end.

Usage: python run_all.py
"""

import standings
import rosters


def main() -> None:
    print("=== Standings ===")
    standings.main()
    print("\n=== Rosters ===")
    rosters.main()
    print("\nDone.")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Smoke-test the orchestrator**

```bash
cd data-raw/sources/tout-wars/scrape
python run_all.py 2>&1 | tail -10
```

Expected: ends with "=== Rosters ===" output and "Done.". (This re-runs both scrapes — about 1 minute. Files in standings/ and rosters/ get overwritten with the same content, which `git status` should confirm shows no diff.)

- [ ] **Step 3: Confirm no diffs after re-run**

```bash
cd /Users/jacobdennen/rotostats
git status -s data-raw/sources/tout-wars/standings/ data-raw/sources/tout-wars/rosters/
```

Expected: empty output (idempotent re-run produced byte-identical CSVs).

- [ ] **Step 4: Commit**

```bash
git add data-raw/sources/tout-wars/scrape/run_all.py
git commit -m "feat(tout-wars): add run_all.py orchestrator

Single entry point that runs the standings scrape followed by the
rosters scrape. Idempotent — re-running produces byte-identical CSVs."
```

---

## Task 7: Open PR

- [ ] **Step 1: Push the branch**

```bash
cd /Users/jacobdennen/rotostats
git push -u origin feature/tout-wars-scrapers
```

- [ ] **Step 2: Open the PR against `develop`**

```bash
gh pr create --base develop --title "feat(tout-wars): scrape historical standings + rosters from Onroto" \
  --body "$(cat <<'EOF'
## Summary

- Reorganize `data-raw/sources/tout-wars/`: existing auction CSVs moved to `auctions/` subfolder.
- Add Python scrapers under `data-raw/sources/tout-wars/scrape/` that pull final standings and end-of-season rosters from Onroto for all three Tout Wars leagues (AL, NL, Mixed).
- Output 90 new CSVs: 45 in `standings/` and 45 in `rosters/`, covering AL/NL 2010-2025 and Mixed 2013-2025.

These feed `sgp()` and `par()` work on the R side.

Spec: `plans/specs/2026-04-26-tout-wars-scrapers-design.md`

## Test plan

- [ ] `pytest data-raw/sources/tout-wars/scrape/tests/` passes locally
- [ ] Spot-check a couple of CSVs in `standings/` and `rosters/` for the expected schema and team count
- [ ] Confirm `python run_all.py` is idempotent (re-running produces no git diff)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed. Returns control to the user.

---

## Self-review notes

- **Spec coverage:** Auctions move (Task 1), guest auth (Task 2 → `auth.py`), standings scraper with OBP map + dynamic cats + 3-league loop (Task 4), rosters scraper with header-driven column detection + no `contract_year` + `league` + `roster_section` columns (Task 5), `run_all.py` orchestrator (Task 6), validation via warning logs is built into both scrapers' `main()`. All spec sections covered.
- **Scope:** No transactions, no `team_stats`, no `prev_active`, no preauction — matches "Non-goals" in the spec.
- **Type/name consistency:** `parse_summary_table` / `parse_category_tables` / `parse_roster_page` / `scrape_one` / `main` named consistently across both scrapers and tests. `LEAGUES` tuple shape `(code, short, years)` identical in `standings.py` and `rosters.py`. CSV column naming matches the design spec verbatim.
- **Open considerations:** earlier years (2010–2014) may use `AVERAGE` instead of `ON BASE PCT` — both are in `CAT_HEADER_MAP` and `ALL_CATS`, so either works. If Onroto doesn't host pre-2013 Mixed data, the per-year HTTP request will likely return an empty page and `scrape_one` will print a warning and move on.
