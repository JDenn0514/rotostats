"""Tests for the team_stats parser, run against saved HTML fixtures."""

from pathlib import Path

import pytest
from bs4 import BeautifulSoup

import team_stats

FIXTURE_DIR = Path(__file__).parent / "fixtures"


def test_module_importable():
    assert hasattr(team_stats, "LEAGUES")
    assert isinstance(team_stats.LEAGUES, list)
    assert len(team_stats.LEAGUES) == 3


@pytest.mark.parametrize("raw,expected", [
    ("0", 0), ("17", 17), (" 17 ", 17), ("", 0), ("---", 0), ("N/A", 0),
])
def test_parse_int(raw, expected):
    assert team_stats.parse_int(raw) == expected


@pytest.mark.parametrize("raw,expected", [
    ("0.000", 0.0),
    (".286", pytest.approx(0.286)),
    ("0.286", pytest.approx(0.286)),
    ("3.45", pytest.approx(3.45)),
    ("", 0.0),
    ("---", 0.0),
    ("N/A", 0.0),
])
def test_parse_float(raw, expected):
    assert team_stats.parse_float(raw) == expected


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("12.0", 12.0),
        ("12.1", pytest.approx(12.0 + 1/3)),
        ("12.2", pytest.approx(12.0 + 2/3)),
        ("0.0", 0.0),
        ("0.1", pytest.approx(1/3)),
        ("", 0.0),
        ("---", 0.0),
        (" 12.1 ", pytest.approx(12.0 + 1/3)),
        ("100.2", pytest.approx(100.0 + 2/3)),
        ("12.5", 12.5),  # plain decimal fallback (decimal digit not 0/1/2)
    ],
)
def test_parse_ip(raw, expected):
    assert team_stats.parse_ip(raw) == expected


def _td(html_fragment: str):
    """Build a <td> tag from an HTML fragment, for parser testing."""
    return BeautifulSoup(f"<table><tr><td>{html_fragment}</td></tr></table>", "lxml").td


def test_parse_player_name_and_id_with_link():
    cell = _td('<a href="/x?+1010&y">Derek Jeter</a>')
    assert team_stats.parse_player_name_and_id(cell) == ("Derek Jeter", "1010")


def test_parse_player_name_and_id_strips_annotations():
    cell = _td('<a href="/x?+2080&y">Jake Arrieta (DL)</a>')
    assert team_stats.parse_player_name_and_id(cell) == ("Jake Arrieta", "2080")


def test_parse_player_name_and_id_strips_off_dl_annotation():
    cell = _td('<a href="/x?+2080&y">#Jake Arrieta (Off DL)</a>')
    assert team_stats.parse_player_name_and_id(cell) == ("Jake Arrieta", "2080")


def test_parse_player_name_and_id_no_link():
    cell = _td("Some Player")
    assert team_stats.parse_player_name_and_id(cell) == ("Some Player", "")


def test_parse_player_name_and_id_blank():
    cell = _td("")
    assert team_stats.parse_player_name_and_id(cell) == ("", "")


@pytest.mark.parametrize("heading,expected", [
    ("Active Hitters",                          "active"),
    ("Active Pitchers",                         "active"),
    ("Reserved Hitters",                        "reserved"),
    ("Reserved Pitchers",                       "reserved"),
    ("stats of previously active hitters",      "previously_active"),
    ("Stats Of Previously Active Pitchers",     "previously_active"),
    ("stats of previously reserved hitters",    "previously_reserved"),
    ("STATS OF PREVIOUSLY RESERVED PITCHERS",   "previously_reserved"),
    ("Random unrelated heading",                None),
    ("",                                        None),
])
def test_section_label_from_heading(heading, expected):
    assert team_stats.section_label_from_heading(heading) == expected


@pytest.fixture
def html_2025_al_team1():
    return (FIXTURE_DIR / "team_stats_2025_al_team1.html").read_text()


def test_parse_team_page_returns_team_name_and_rows(html_2025_al_team1):
    result = team_stats.parse_team_page(html_2025_al_team1, year=2025, league_short="al")
    assert isinstance(result.team_name, str) and result.team_name != ""
    assert len(result.batter_rows) > 0, "expected at least one batter row"
    assert len(result.pitcher_rows) > 0, "expected at least one pitcher row"

    first_b = result.batter_rows[0]
    assert set(first_b.keys()) == set(team_stats.BATTER_COLUMNS) - {"eligibility"}
    # eligibility is joined later; team_page parser leaves it absent
    assert first_b["year"] == 2025
    assert first_b["league"] == "al"
    assert first_b["team"] == result.team_name
    assert isinstance(first_b["salary"], int)
    assert isinstance(first_b["ab"], int)
    assert isinstance(first_b["avg"], float)

    first_p = result.pitcher_rows[0]
    assert set(first_p.keys()) == set(team_stats.PITCHER_COLUMNS) - {"eligibility"}
    assert isinstance(first_p["ip"], float)
    assert isinstance(first_p["era"], float)


def test_parse_team_page_sections_present(html_2025_al_team1):
    result = team_stats.parse_team_page(html_2025_al_team1, year=2025, league_short="al")
    bat_sections = {r["roster_section"] for r in result.batter_rows}
    pit_sections = {r["roster_section"] for r in result.pitcher_rows}
    valid = {"active", "reserved", "previously_active", "previously_reserved"}
    assert bat_sections.issubset(valid)
    assert pit_sections.issubset(valid)
    assert "active" in bat_sections
    assert "active" in pit_sections


def test_parse_team_page_skips_total_rows_from_player_rows(html_2025_al_team1):
    result = team_stats.parse_team_page(html_2025_al_team1, year=2025, league_short="al")
    for r in result.batter_rows + result.pitcher_rows:
        assert not r["player_name"].upper().startswith("TOTAL")


def test_total_row_check_passes_on_real_fixture(html_2025_al_team1):
    result = team_stats.parse_team_page(html_2025_al_team1, year=2025, league_short="al")
    warnings = team_stats.check_section_totals(result)
    # Real Onroto data should reconcile cleanly. Any failure here means our
    # parser disagrees with Onroto's TOTAL row — a parsing bug.
    assert warnings == [], f"unexpected total mismatches: {warnings}"


def test_total_row_check_detects_synthetic_mismatch():
    result = team_stats.TeamPageResult(team_name="Test")
    result.batter_rows.append(
        {"player_type": "batter", "roster_section": "active",
         "ab": 100, "g": 30, "r": 10, "hr": 5, "rbi": 20,
         "sb": 1, "so": 25, "bb": 8,
         **{k: 0 for k in ("avg","obp","slg",
                            "gp_dh","gp_c","gp_1b","gp_2b","gp_3b","gp_ss","gp_of",
                            "year","league","team","player_name","player_id",
                            "mlb_team","position","salary","status")}}
    )
    result.totals.append({
        "player_type": "batter", "section": "active",
        "ab": 999,  # mismatch
        "g": 30, "r": 10, "hr": 5, "rbi": 20, "sb": 1, "so": 25, "bb": 8,
        "avg": 0.0, "obp": 0.0, "slg": 0.0,
    })
    warnings = team_stats.check_section_totals(result)
    assert any("ab" in w.lower() for w in warnings), warnings


@pytest.fixture
def html_2025_al_team_empty():
    return (FIXTURE_DIR / "team_stats_2025_al_team_empty.html").read_text()


def test_is_empty_team_page_true(html_2025_al_team_empty):
    assert team_stats.is_empty_team_page(html_2025_al_team_empty) is True


def test_is_empty_team_page_false(html_2025_al_team1):
    assert team_stats.is_empty_team_page(html_2025_al_team1) is False


@pytest.fixture
def html_rosters_2025_al():
    return (FIXTURE_DIR / "rosters_2025_al.html").read_text()


def test_parse_roster_page_for_eligibility(html_rosters_2025_al):
    elig_map = team_stats.parse_roster_page_for_eligibility(html_rosters_2025_al)
    # Map is keyed by (team, key) with key = "id:<pid>" or "name:<name>"
    assert isinstance(elig_map, dict)
    assert len(elig_map) > 100, f"expected lots of player rows, got {len(elig_map)}"
    # At least some non-empty eligibility values
    sample_values = [v for v in elig_map.values() if v]
    assert len(sample_values) > 50


def test_lookup_eligibility_prefers_id_over_name():
    elig_map = {
        ("Team A", "id:1010"): "SS,MI",
        ("Team A", "name:Derek Jeter"): "WRONG",
    }
    assert team_stats.lookup_eligibility(elig_map, "Team A", "1010", "Derek Jeter") == "SS,MI"


def test_lookup_eligibility_falls_back_to_name():
    elig_map = {("Team A", "name:Some Player"): "OF"}
    assert team_stats.lookup_eligibility(elig_map, "Team A", "", "Some Player") == "OF"


def test_lookup_eligibility_returns_blank_when_missing():
    elig_map = {}
    assert team_stats.lookup_eligibility(elig_map, "Team A", "999", "Nobody") == ""


def _bat_row(team, name, pid, section, ab=0):
    base = {k: 0 for k in (
        "g","r","hr","rbi","sb","so","bb","avg","obp","slg",
        "gp_dh","gp_c","gp_1b","gp_2b","gp_3b","gp_ss","gp_of",
    )}
    base.update({
        "year": 2025, "league": "al", "team": team,
        "player_name": name, "player_id": pid, "mlb_team": "FA",
        "position": "OF", "salary": 1, "status": "act",
        "roster_section": section, "ab": ab,
    })
    return base


def test_audit_player_sections_dedupes_same_section():
    rows = [
        _bat_row("Team A", "Pat", "100", "active", ab=10),
        _bat_row("Team A", "Pat", "100", "active", ab=99),  # duplicate
        _bat_row("Team A", "Sam", "200", "active", ab=5),
    ]
    deduped, info, warns = team_stats.audit_player_sections(rows)
    assert len(deduped) == 2
    assert deduped[0]["player_name"] == "Pat"
    assert deduped[0]["ab"] == 10  # first occurrence kept
    assert deduped[1]["player_name"] == "Sam"
    assert any("Pat" in w for w in warns)
    assert info == []


def test_audit_player_sections_logs_cross_section():
    rows = [
        _bat_row("Team A", "Pat", "100", "active", ab=10),
        _bat_row("Team A", "Pat", "100", "previously_reserved", ab=0),
    ]
    deduped, info, warns = team_stats.audit_player_sections(rows)
    assert len(deduped) == 2  # both rows kept
    assert any("Pat" in m for m in info)
    assert warns == []


def test_audit_player_sections_clean_input():
    rows = [
        _bat_row("Team A", "Pat", "100", "active"),
        _bat_row("Team A", "Sam", "200", "previously_active"),
        _bat_row("Team B", "Pat", "100", "reserved"),  # different team — fine
    ]
    deduped, info, warns = team_stats.audit_player_sections(rows)
    assert len(deduped) == 3
    assert info == []
    assert warns == []
