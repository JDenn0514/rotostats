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


def test_parse_category_tables_value_correctness(soup_2025_al):
    raw = parse_category_tables(soup_2025_al)
    # Cross-checked against data-raw/sources/tout-wars/standings/2025-al.csv:
    # Andy Andres: R=893, HR=281, RBI=856, SB=144, OBP=.334, W=78, SV=35, ERA=3.34, WHIP=1.127, SO=1304
    assert raw["Andy Andres"]["R"] == 893
    assert raw["Andy Andres"]["HR"] == 281
    assert raw["Andy Andres"]["OBP"] == 0.334
    assert raw["Andy Andres"]["ERA"] == 3.34
