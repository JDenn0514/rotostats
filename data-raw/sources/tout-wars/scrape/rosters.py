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


def _team_class(team_p: Tag) -> str:
    """Return the 'team_NNNN' CSS class from a team <p> tag, or empty string."""
    for c in team_p.get("class", []):
        if c.startswith("team_"):
            return c
    return ""


def _team_tables(team_p: Tag, team_p_class: str) -> list[tuple[Tag, str]]:
    """Walk forward from a team's <p> tag, collecting (table, section) pairs
    until a <p> with a *different* team_NNNN class is encountered.

    Onroto emits validation messages as <p class='team_NNNN'> siblings that
    share the same class as the real team header. Those are skipped; only a
    different team_NNNN class signals the start of the next team.
    """
    out: list[tuple[Tag, str]] = []
    sib = team_p.next_sibling
    while sib is not None:
        if isinstance(sib, Tag):
            if sib.name == "p":
                cls = next(
                    (c for c in sib.get("class", []) if c.startswith("team_")), None
                )
                if cls is not None and cls != team_p_class:
                    break
                # same team_NNNN — it's a validation message; skip and continue
            elif sib.name == "table":
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

    # Onroto emits validation messages as <p class='team_NNNN'> siblings
    # inside each team block, sharing the same numeric class as the real team
    # header. Dedupe by class id so only the first <p> per team (the header
    # with the <b>name</b>) is kept.
    seen: set[str] = set()
    team_ps: list[Tag] = []
    for p in soup.find_all("p", class_=re.compile(r"^team_\d+$")):
        cls = next((c for c in p.get("class", []) if c.startswith("team_")), None)
        if cls is None or cls in seen:
            continue
        seen.add(cls)
        team_ps.append(p)

    if not team_ps:
        return records

    for team_p in team_ps:
        team_name = _team_name(team_p)
        for table, section in _team_tables(team_p, team_p_class=_team_class(team_p)):
            for player in _parse_player_table(table, section):
                records.append({
                    "year": year,
                    "league": league_short,
                    "team": team_name,
                    **player,
                })
    return records


def scrape_one(session, sid, league_code: str, league_short: str, year: int) -> pd.DataFrame | None:
    html = fetch_rosters(session, sid, league_code, year)
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
