"""Tests for the team_stats parser, run against saved HTML fixtures."""

from pathlib import Path

import pytest

import team_stats

FIXTURE_DIR = Path(__file__).parent / "fixtures"


def test_module_importable():
    assert hasattr(team_stats, "LEAGUES")
    assert isinstance(team_stats.LEAGUES, list)
    assert len(team_stats.LEAGUES) == 3


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
