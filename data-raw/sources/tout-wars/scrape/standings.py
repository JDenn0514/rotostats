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
