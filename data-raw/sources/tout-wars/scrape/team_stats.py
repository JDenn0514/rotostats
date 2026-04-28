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
