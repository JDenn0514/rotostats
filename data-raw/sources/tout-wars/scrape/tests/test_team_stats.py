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
