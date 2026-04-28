"""Scrape per-team rosters + team-attributed stats for all three Tout Wars
leagues, replacing the older rosters.py scraper.

Output (per league-year):
  ../rosters/{year}-{league}-batters.csv
  ../rosters/{year}-{league}-pitchers.csv

Two endpoints are called per league-year:
  - display_roster.pl?<code>+0+all+<year>      (once; for the eligibility column)
  - display_team_stats.pl?<code>+0+<idx>+<year>  (once per team; for stats + sections)

See plans/specs/2026-04-28-tout-wars-team-stats-scraper-design.md for the
design rationale.
"""

from __future__ import annotations

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

MAX_TEAM_IDX = 20  # safety cap; no Tout league has been larger
SALARY_WARN_THRESHOLD = 750
TOTAL_RATE_TOLERANCE = 1e-3

PLAYER_ID_RE = re.compile(r"\+(\d+)&")
ANNOTATION_RE = re.compile(r"\s*\((?:Off DL|Non Elig Pos|DL|Farm|Res)\s*\)\s*$")


def parse_int(text: str) -> int:
    s = (text or "").strip()
    try:
        return int(s)
    except ValueError:
        return 0


def parse_float(text: str) -> float:
    s = (text or "").strip()
    try:
        return float(s)
    except ValueError:
        return 0.0


BATTER_COLUMNS = [
    "year", "league", "team",
    "player_name", "player_id", "mlb_team",
    "position", "salary", "status", "roster_section", "eligibility",
    "ab", "g", "r", "hr", "rbi", "sb", "so", "bb",
    "avg", "obp", "slg",
    "gp_dh", "gp_c", "gp_1b", "gp_2b", "gp_3b", "gp_ss", "gp_of",
]

PITCHER_COLUMNS = [
    "year", "league", "team",
    "player_name", "player_id", "mlb_team",
    "position", "salary", "status", "roster_section", "eligibility",
    "g", "w", "l", "sv", "ip", "bb", "hr", "so", "era", "whip",
]


def parse_ip(text: str) -> float:
    """Parse innings-pitched in either X.Y baseball convention or plain decimal.

    .1 → 1/3 inning, .2 → 2/3 inning. Anything else parses as a normal float.
    Empty / non-numeric input returns 0.0.
    """
    s = (text or "").strip()
    if not s:
        return 0.0
    try:
        whole_str, _, frac_str = s.partition(".")
        whole = int(whole_str) if whole_str else 0
        if frac_str == "" or frac_str == "0":
            return float(whole)
        if frac_str == "1":
            return whole + 1 / 3
        if frac_str == "2":
            return whole + 2 / 3
        return float(s)
    except ValueError:
        return 0.0


def parse_player_name_and_id(name_cell: Tag) -> tuple[str, str]:
    """Extract (player_name, player_id) from a <td> in the Name column.

    Strips Onroto's parenthesized status annotations (e.g. "(DL)", "(Off DL)")
    and any leading "#" marker. Returns ("", "") when the cell is blank.
    """
    link = name_cell.find("a", href=True)
    if link is None:
        raw = name_cell.get_text(strip=True)
        cleaned = raw.lstrip("#").strip()
        return (cleaned, "")
    raw_name = ANNOTATION_RE.sub("", link.get_text()).lstrip("#").strip()
    m = PLAYER_ID_RE.search(link["href"])
    return (raw_name, m.group(1) if m else "")
