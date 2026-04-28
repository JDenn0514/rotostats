"""Tests for the team_stats parser, run against saved HTML fixtures."""

from pathlib import Path

import pytest

import team_stats

FIXTURE_DIR = Path(__file__).parent / "fixtures"


def test_module_importable():
    assert hasattr(team_stats, "LEAGUES")
    assert isinstance(team_stats.LEAGUES, list)
    assert len(team_stats.LEAGUES) == 3
