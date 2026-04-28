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
from bs4 import BeautifulSoup, NavigableString, Tag

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


def section_label_from_heading(heading_text: str) -> str | None:
    """Map a section-heading string to one of four labels.

    Returns None when the heading doesn't match any known section.
    Ordering of checks matters: 'previously' must be tested before plain
    'reserved'/'active'.
    """
    s = (heading_text or "").strip().lower()
    if not s:
        return None
    if "previously active" in s:
        return "previously_active"
    if "previously reserved" in s:
        return "previously_reserved"
    if "reserved" in s:
        return "reserved"
    if "active" in s:
        return "active"
    return None


# ---------------------------------------------------------------------------
# Team-page parser
# ---------------------------------------------------------------------------
from dataclasses import dataclass, field


@dataclass
class TeamPageResult:
    team_name: str
    batter_rows: list[dict] = field(default_factory=list)
    pitcher_rows: list[dict] = field(default_factory=list)
    totals: list[dict] = field(default_factory=list)


# Headers required to classify a table as batter or pitcher.
# NOTE: The fixture uses "OBP" as the header for the column that actually
# displays both AVG (main text) and OBP (red sub-text), so "AVG" never
# appears as a standalone header.  "SLG" likewise doubles as SLG/OPS.
_BATTER_REQUIRED = {"Pos", "Name", "Tm", "Sal", "Sta",
                    "AB", "G", "R", "HR", "RBI", "SB", "SO", "BB",
                    "OBP", "SLG"}
_PITCHER_REQUIRED = {"Pos", "Name", "Tm", "Sal", "Sta",
                     "G", "W", "L", "SV", "IP", "BB", "HR", "SO", "ERA", "WHIP"}

_GP_HEADERS = ["DH", "C", "1B", "2B", "3B", "SS", "OF"]


def _cell_main_value(cell: Tag) -> str:
    """Return the primary (accumulated) value from a stats cell.

    Each cell may contain two values stacked with <br/>: the main accumulated
    value as a plain text node and the current-week value inside a red <font>.
    We return only the first non-empty NavigableString.
    """
    for content in cell.contents:
        if isinstance(content, NavigableString):
            val = str(content).strip()
            if val:
                return val
    return cell.get_text(strip=True)


def _build_header_indices(table: Tag) -> dict[str, int]:
    """Build a column-name → cell-index mapping from the table's header rows.

    Row 0 contains the main headers; a colspan=7 "Games by Position" span
    occupies physical columns 5-11.  Row 1 (when it exists) contains the
    individual GP position sub-headers (DH, C, 1B, …) which are mapped to
    those same physical column positions.

    The AVG/OBP and SLG/OPS columns are labelled "OBP" and "SLG" in row 0
    but we also expose "AVG" at the same index as "OBP" to keep callers
    consistent.
    """
    rows = table.find_all("tr", recursive=False)
    if not rows:
        return {}

    idx: dict[str, int] = {}
    col = 0
    for cell in rows[0].find_all(["th", "td"]):
        text = cell.get_text(strip=True)
        colspan = int(cell.get("colspan", 1))
        if text == "2025 Games by Position" or text.endswith("Games by Position"):
            # Skip — sub-headers will be filled from row 1
            col += colspan
            continue
        idx[text] = col
        # "OBP" column actually holds AVG (main) + OBP (red); expose both names
        if text == "OBP":
            idx["AVG"] = col
        col += colspan

    # Row 1: GP sub-headers (DH, C, 1B, 2B, 3B, SS, OF) start at column 5
    if len(rows) > 1:
        gp_start_col = 5  # fixed offset: Pos(0) Name(1) Tm(2) Sal(3) Sta(4)
        gp_cells = rows[1].find_all(["th", "td"])
        for i, cell in enumerate(gp_cells):
            text = cell.get_text(strip=True)
            if text:
                idx[text] = gp_start_col + i

    return idx


def _classify_table(idx: dict[str, int]) -> str | None:
    headers = set(idx.keys())
    if _BATTER_REQUIRED.issubset(headers):
        return "batter"
    if _PITCHER_REQUIRED.issubset(headers):
        return "pitcher"
    return None


def _team_name(soup: BeautifulSoup) -> str:
    """Extract team name from the page.

    The team name appears as the first NavigableString in a
    <td class='black_on_white12'> that follows the season-year header.
    The first such cell contains '20XX Final Stats'; the second contains
    the manager/team name followed by 'owned by …' on a second line.
    """
    cells = soup.find_all("td", class_="black_on_white12")
    for cell in cells:
        for content in cell.contents:
            if isinstance(content, NavigableString):
                text = str(content).strip()
                if text and "Final Stats" not in text:
                    return text
    return ""


def _parse_batter_row(
    cells: list[Tag],
    idx: dict[str, int],
    year: int,
    league_short: str,
    team_name: str,
    section: str,
) -> dict | None:
    pos = _cell_main_value(cells[idx["Pos"]]).strip()
    if not pos or pos.upper().startswith("TOTAL"):
        return None
    name, pid = parse_player_name_and_id(cells[idx["Name"]])
    if not name:
        return None

    # The "OBP" column header is reused for both AVG (main text) and OBP (red).
    # Extract OBP from the <font> sub-element of that cell.
    avg_obp_cell = cells[idx["OBP"]]
    avg_val = _cell_main_value(avg_obp_cell)
    font = avg_obp_cell.find("font")
    obp_val = font.get_text(strip=True) if font else ""

    # Similarly, "SLG" column holds SLG (main) + OPS (red).
    slg_cell = cells[idx["SLG"]]
    slg_val = _cell_main_value(slg_cell)

    row: dict = {
        "year": year,
        "league": league_short,
        "team": team_name,
        "player_name": name,
        "player_id": pid,
        "mlb_team": _cell_main_value(cells[idx["Tm"]]),
        "position": pos,
        "salary": parse_int(_cell_main_value(cells[idx["Sal"]])),
        "status": _cell_main_value(cells[idx["Sta"]]),
        "roster_section": section,
        "ab":  parse_int(_cell_main_value(cells[idx["AB"]])),
        "g":   parse_int(_cell_main_value(cells[idx["G"]])),
        "r":   parse_int(_cell_main_value(cells[idx["R"]])),
        "hr":  parse_int(_cell_main_value(cells[idx["HR"]])),
        "rbi": parse_int(_cell_main_value(cells[idx["RBI"]])),
        "sb":  parse_int(_cell_main_value(cells[idx["SB"]])),
        "so":  parse_int(_cell_main_value(cells[idx["SO"]])),
        "bb":  parse_int(_cell_main_value(cells[idx["BB"]])),
        "avg": parse_float(avg_val),
        "obp": parse_float(obp_val),
        "slg": parse_float(slg_val),
    }
    for h in _GP_HEADERS:
        col_key = f"gp_{h.lower()}"
        if h in idx and idx[h] < len(cells):
            row[col_key] = parse_int(_cell_main_value(cells[idx[h]]))
        else:
            row[col_key] = 0
    return row


def _parse_pitcher_row(
    cells: list[Tag],
    idx: dict[str, int],
    year: int,
    league_short: str,
    team_name: str,
    section: str,
) -> dict | None:
    pos = _cell_main_value(cells[idx["Pos"]]).strip()
    if not pos or pos.upper().startswith("TOTAL"):
        return None
    name, pid = parse_player_name_and_id(cells[idx["Name"]])
    if not name:
        return None
    return {
        "year": year,
        "league": league_short,
        "team": team_name,
        "player_name": name,
        "player_id": pid,
        "mlb_team": _cell_main_value(cells[idx["Tm"]]),
        "position": pos,
        "salary": parse_int(_cell_main_value(cells[idx["Sal"]])),
        "status": _cell_main_value(cells[idx["Sta"]]),
        "roster_section": section,
        "g":   parse_int(_cell_main_value(cells[idx["G"]])),
        "w":   parse_int(_cell_main_value(cells[idx["W"]])),
        "l":   parse_int(_cell_main_value(cells[idx["L"]])),
        "sv":  parse_int(_cell_main_value(cells[idx["SV"]])),
        "ip":  parse_ip(_cell_main_value(cells[idx["IP"]])),
        "bb":  parse_int(_cell_main_value(cells[idx["BB"]])),
        "hr":  parse_int(_cell_main_value(cells[idx["HR"]])),
        "so":  parse_int(_cell_main_value(cells[idx["SO"]])),
        "era": parse_float(_cell_main_value(cells[idx["ERA"]])),
        "whip": parse_float(_cell_main_value(cells[idx["WHIP"]])),
    }


def _is_total_row(cells: list[Tag], idx: dict[str, int]) -> bool:
    """Return True when the first cell marks a TOTAL summary row."""
    if not cells:
        return False
    pos_text = _cell_main_value(cells[idx.get("Pos", 0)]).upper()
    return pos_text.startswith("TOTAL")


def _parse_total_row_batter(cells: list[Tag], idx: dict[str, int], section: str) -> dict | None:
    if not _is_total_row(cells, idx):
        return None
    avg_obp_cell = cells[idx["OBP"]]
    avg_val = _cell_main_value(avg_obp_cell)
    font = avg_obp_cell.find("font")
    obp_val = font.get_text(strip=True) if font else ""
    slg_val = _cell_main_value(cells[idx["SLG"]])
    return {
        "player_type": "batter",
        "section": section,
        "ab":  parse_int(_cell_main_value(cells[idx["AB"]])),
        "g":   parse_int(_cell_main_value(cells[idx["G"]])),
        "r":   parse_int(_cell_main_value(cells[idx["R"]])),
        "hr":  parse_int(_cell_main_value(cells[idx["HR"]])),
        "rbi": parse_int(_cell_main_value(cells[idx["RBI"]])),
        "sb":  parse_int(_cell_main_value(cells[idx["SB"]])),
        "so":  parse_int(_cell_main_value(cells[idx["SO"]])),
        "bb":  parse_int(_cell_main_value(cells[idx["BB"]])),
        "avg": parse_float(avg_val),
        "obp": parse_float(obp_val),
        "slg": parse_float(slg_val),
    }


def _parse_total_row_pitcher(cells: list[Tag], idx: dict[str, int], section: str) -> dict | None:
    if not _is_total_row(cells, idx):
        return None
    return {
        "player_type": "pitcher",
        "section": section,
        "g":   parse_int(_cell_main_value(cells[idx["G"]])),
        "w":   parse_int(_cell_main_value(cells[idx["W"]])),
        "l":   parse_int(_cell_main_value(cells[idx["L"]])),
        "sv":  parse_int(_cell_main_value(cells[idx["SV"]])),
        "ip":  parse_ip(_cell_main_value(cells[idx["IP"]])),
        "bb":  parse_int(_cell_main_value(cells[idx["BB"]])),
        "hr":  parse_int(_cell_main_value(cells[idx["HR"]])),
        "so":  parse_int(_cell_main_value(cells[idx["SO"]])),
        "era": parse_float(_cell_main_value(cells[idx["ERA"]])),
        "whip": parse_float(_cell_main_value(cells[idx["WHIP"]])),
    }


def _process_table(
    table: Tag,
    kind: str,
    base_section: str,
    idx: dict[str, int],
    year: int,
    league_short: str,
    team_name: str,
    result: "TeamPageResult",
) -> None:
    """Walk all data rows in a player table, splitting on in-row dividers.

    Each table begins in *base_section* (e.g. "active" or "reserved").
    A divider row (class ``stats_light_grey10``) announces the start of a
    "previously_…" sub-section; the label is read from that row's text.
    """
    current_section = base_section
    for row in table.find_all("tr", recursive=False):
        cells = row.find_all(["td", "th"])
        if not cells:
            continue

        # Check for divider row that announces a new sub-section
        first_cell = cells[0]
        if "stats_light_grey10" in (first_cell.get("class") or []):
            label = section_label_from_heading(first_cell.get_text(strip=True))
            if label is not None:
                current_section = label
            continue

        # Skip header rows (white_on_grey11)
        if "white_on_grey11" in (first_cell.get("class") or []):
            continue

        try:
            if kind == "batter":
                total = _parse_total_row_batter(cells, idx, current_section)
                if total is not None:
                    result.totals.append(total)
                    continue
                parsed = _parse_batter_row(
                    cells, idx, year, league_short, team_name, current_section
                )
            else:
                total = _parse_total_row_pitcher(cells, idx, current_section)
                if total is not None:
                    result.totals.append(total)
                    continue
                parsed = _parse_pitcher_row(
                    cells, idx, year, league_short, team_name, current_section
                )
        except (KeyError, IndexError):
            continue

        if parsed is None:
            continue
        if kind == "batter":
            result.batter_rows.append(parsed)
        else:
            result.pitcher_rows.append(parsed)


def parse_team_page(html: str, year: int, league_short: str) -> TeamPageResult:
    """Parse one display_team_stats.pl page into batter rows, pitcher rows, totals.

    Page structure (confirmed against fixture):
      - The content TD (second child of the outermost layout table's main row)
        contains alternating ``<div class="black_on_white11">`` section headings
        and ``<table>`` player-stats tables.
      - Each div announces the base section label (e.g. "Active Hitters").
      - Within each table, rows with ``class="stats_light_grey10"`` are
        in-table dividers announcing a "previously_…" sub-section.
      - Stat cells may contain two stacked values separated by ``<br/>``; the
        first (black) text is the accumulated season total, the second (red,
        inside a ``<font>`` tag) is the current-week value.  Only the
        accumulated value is captured.
      - The "OBP" header column actually holds AVG (main text) and OBP (red).
    """
    soup = BeautifulSoup(html, "lxml")
    team_name = _team_name(soup)
    result = TeamPageResult(team_name=team_name)
    if not team_name:
        return result

    # Locate the content TD: outermost layout table → first data row → second TD
    outer_tables = soup.find_all("table", recursive=False)
    if not outer_tables:
        outer_tables = soup.find_all("table")

    # Find the TD that contains both <div class="black_on_white11"> and player tables
    content_td: Tag | None = None
    for td in soup.find_all("td"):
        if td.find("div", class_="black_on_white11"):
            content_td = td
            break
    if content_td is None:
        return result

    # Walk content_td children: div announces section; next table is its data
    pending_section: str | None = None
    for child in content_td.children:
        if not isinstance(child, Tag):
            continue
        if child.name == "div" and "black_on_white11" in (child.get("class") or []):
            label = section_label_from_heading(child.get_text(strip=True))
            if label is not None:
                pending_section = label
        elif child.name == "table" and pending_section is not None:
            idx = _build_header_indices(child)
            kind = _classify_table(idx)
            if kind is not None:
                _process_table(
                    child, kind, pending_section, idx,
                    year, league_short, team_name, result,
                )
            pending_section = None  # consume; next div will set a new one

    return result


_BATTER_INT_STATS = ("ab", "g", "r", "hr", "rbi", "sb", "so", "bb")
_PITCHER_INT_STATS = ("g", "w", "l", "sv", "bb", "hr", "so")


def check_section_totals(result: TeamPageResult) -> list[str]:
    """Return warning strings for any section where summed player rows
    disagree with the captured TOTAL row.

    Only integer counting stats are checked exactly. Rate stats and IP
    derive from compound denominators that don't reconstruct cleanly from
    per-row sums; those are skipped here.
    """
    warnings: list[str] = []

    by_kind_section: dict[tuple[str, str], list[dict]] = {}
    for r in result.batter_rows:
        by_kind_section.setdefault(("batter", r["roster_section"]), []).append(r)
    for r in result.pitcher_rows:
        by_kind_section.setdefault(("pitcher", r["roster_section"]), []).append(r)

    for total in result.totals:
        kind = total["player_type"]
        section = total["section"]
        rows = by_kind_section.get((kind, section), [])
        stats = _BATTER_INT_STATS if kind == "batter" else _PITCHER_INT_STATS
        for stat in stats:
            summed = sum(r[stat] for r in rows)
            if summed != total[stat]:
                warnings.append(
                    f"{result.team_name} {kind} {section} {stat}: "
                    f"rows summed to {summed}, TOTAL row says {total[stat]}"
                )
    return warnings


def is_empty_team_page(html: str) -> bool:
    """Return True when display_team_stats.pl has no team data
    (i.e. team_idx is past the last team in the league).
    """
    result = parse_team_page(html, year=0, league_short="")
    return not result.batter_rows and not result.pitcher_rows and not result.totals


def _team_class(team_p: Tag) -> str:
    for c in team_p.get("class", []):
        if c.startswith("team_"):
            return c
    return ""


def _team_name_from_p(team_p: Tag) -> str:
    b = team_p.find("b")
    if b:
        return b.get_text(strip=True)
    return team_p.get_text(strip=True).split(",")[0].strip()


def _team_tables_for_roster(team_p: Tag, team_p_class: str) -> list[Tag]:
    """Walk forward from a team's <p> tag, collecting Active/Reserved tables
    until a <p> with a different team_NNNN class is encountered.
    """
    out: list[Tag] = []
    sib = team_p.next_sibling
    while sib is not None:
        if isinstance(sib, Tag):
            if sib.name == "p":
                cls = next(
                    (c for c in sib.get("class", []) if c.startswith("team_")), None
                )
                if cls is not None and cls != team_p_class:
                    break
            elif sib.name == "table":
                classes = " ".join(sib.get("class", []))
                if "Active_table" in classes or "Reserved_table" in classes:
                    out.append(sib)
        sib = sib.next_sibling
    return out


def _roster_eligibility_columns(table: Tag) -> tuple[int, int, int] | None:
    """Return (name_col, elig_col, max_col_seen) for a roster page table."""
    th_row = table.find("tr")
    if th_row is None:
        return None
    headers = [th.get_text(strip=True) for th in th_row.find_all("th")]
    if "Elig" not in headers:
        return None
    elig_col = headers.index("Elig")
    name_candidates = [
        h for h in headers
        if h not in {"Pos", "Team", "Sal", "Stat", "Elig",
                     "Games Played By Position",
                     "DH", "C", "1B", "2B", "3B", "SS", "OF"}
    ]
    if not name_candidates:
        return None
    name_col = headers.index(name_candidates[0])
    return (name_col, elig_col, max(name_col, elig_col))


def parse_roster_page_for_eligibility(html: str) -> dict[tuple[str, str], str]:
    """Parse display_roster.pl into a {(team, key) → eligibility} map.

    `key` is `"id:<player_id>"` when a link/id is present, else
    `"name:<player_name>"`. Both keys are emitted for each player so the
    join can fall back to name when player_id is missing on the team_stats
    side.
    """
    soup = BeautifulSoup(html, "lxml")
    out: dict[tuple[str, str], str] = {}

    seen: set[str] = set()
    team_ps: list[Tag] = []
    for p in soup.find_all("p", class_=re.compile(r"^team_\d+$")):
        cls = next((c for c in p.get("class", []) if c.startswith("team_")), None)
        if cls is None or cls in seen:
            continue
        seen.add(cls)
        team_ps.append(p)

    for team_p in team_ps:
        team_name = _team_name_from_p(team_p)
        for table in _team_tables_for_roster(team_p, _team_class(team_p)):
            cols = _roster_eligibility_columns(table)
            if cols is None:
                continue
            name_col, elig_col, max_col = cols
            for row in table.find_all("tr"):
                cells = row.find_all("td")
                if len(cells) < max_col + 1:
                    continue
                name, pid = parse_player_name_and_id(cells[name_col])
                if not name:
                    continue
                elig = cells[elig_col].get_text(strip=True)
                if pid:
                    out[(team_name, f"id:{pid}")] = elig
                out[(team_name, f"name:{name}")] = elig
    return out


def lookup_eligibility(
    elig_map: dict[tuple[str, str], str],
    team: str,
    player_id: str,
    player_name: str,
) -> str:
    """Look up eligibility, preferring player_id over player_name."""
    if player_id:
        v = elig_map.get((team, f"id:{player_id}"))
        if v is not None:
            return v
    v = elig_map.get((team, f"name:{player_name}"))
    return v if v is not None else ""


def audit_player_sections(
    rows: list[dict],
) -> tuple[list[dict], list[str], list[str]]:
    """Return (deduped_rows, info_messages, warn_messages).

    - Same-section duplicate within one team: drop subsequent rows; emit warning.
    - Cross-section appearance within one team: keep all rows; emit info line.
    """
    info: list[str] = []
    warns: list[str] = []
    seen_in_section: set[tuple[str, str, str]] = set()  # (team, key, section)
    sections_per_player: dict[tuple[str, str, str], set[str]] = {}
    out: list[dict] = []
    for r in rows:
        key = r["player_id"] or r["player_name"]
        section_key = (r["team"], key, r["roster_section"])
        sections_per_player.setdefault(
            (r["team"], key, r["player_name"]), set()
        ).add(r["roster_section"])

        if section_key in seen_in_section:
            warns.append(
                f"duplicate row dropped: team={r['team']} "
                f"player={r['player_name']!r} section={r['roster_section']}"
            )
            continue
        seen_in_section.add(section_key)
        out.append(r)

    for (team, _key, name), sections in sections_per_player.items():
        if len(sections) > 1:
            info.append(
                f"player in multiple sections: team={team} player={name!r} "
                f"sections={sorted(sections)}"
            )
    return out, info, warns


def warn_high_salaries(rows: list[dict], threshold: int = SALARY_WARN_THRESHOLD) -> list[str]:
    """Return one warning per row whose `salary` strictly exceeds `threshold`."""
    out: list[str] = []
    for r in rows:
        sal = r.get("salary", 0)
        if sal > threshold:
            out.append(
                f"high salary: year={r.get('year')} league={r.get('league')} "
                f"team={r.get('team')!r} player={r.get('player_name')!r} salary={sal}"
            )
    return out
