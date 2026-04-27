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
