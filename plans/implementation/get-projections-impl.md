# Implementation Reference: `get_projections()`

> **Type:** API schema reference — not a conceptual spec
> **Last updated:** 2026-04-10

---

## Function Signature

```r
get_projections(
  source      = "steamer",   # projection source (see Sources below)
  year        = NULL,        # projection year; default = current season
  player_type = "both",      # "batters", "pitchers", or "both"
  data        = NULL         # required when source = "custom"
)
```

---

## Sources

| `source` value | System | Notes |
|----------------|--------|-------|
| `"steamer"` | Steamer | Recommended default; broadest column coverage |
| `"zips"` | ZiPS | Lacks QS; otherwise comprehensive |
| `"atc"` | ATC | Averaged projection system |
| `"fangraphsdc"` | FanGraphs Depth Charts | Blended playing-time model |
| `"thebat"` | THE BAT | |
| `"thebatx"` | THE BAT X | |
| `"custom"` | User-supplied | Requires `data` argument — a data frame in the expected schema |

---

## API

Calls the FanGraphs projections endpoint directly. **Does not use baseballr** —
`baseballr::fg_batter_leaders()` and `fg_pitcher_leaders()` route only to the leaderboard
API and do not support projections.

```
GET https://www.fangraphs.com/api/projections
  ?type={source}
  &stats={bat|pit}
  &pos=all
  &team=0
  &players=0
  &lg=all
```

---

## Output Schema

Returns a single data frame with one row per player. Batter and pitcher rows are
distinguished by a `player_type` column (`"batter"` / `"pitcher"`).

### Always-present columns (all sources)

| Column | Type | Description |
|--------|------|-------------|
| `playerid` | character | FanGraphs player ID |
| `name` | character | Player name |
| `team` | character | Team abbreviation |
| `pos` | character | Primary position |
| `player_type` | character | `"batter"` or `"pitcher"` |

### Batter columns

| Column | Type | Source availability |
|--------|------|---------------------|
| `G, AB, PA` | integer | All |
| `H, 1B, 2B, 3B, HR` | integer | All |
| `R, RBI, BB, IBB, SO` | integer | All |
| `HBP, SF, SH, SB, CS` | integer | All |
| `AVG, OBP, SLG` | double | All |
| `OPS` | double | All — direct column; use as-is |
| `wOBA, wRC_plus, ISO, BABIP` | double | All |
| `WAR, wRAA, wRC, UBR, wBsR` | double | All |
| `GDP, Spd, UZR` | double | All |
| `ADP` | double | All |

### Pitcher columns

| Column | Type | Source availability |
|--------|------|---------------------|
| `W, L, GS, G, IP, TBF` | integer/double | All |
| `SV, HLD, BS` | integer | All |
| `H, R, ER, HR, SO, BB` | integer | All |
| `ERA, WHIP` | double | All |
| `K_per_9, BB_per_9, K_per_BB` | double | All |
| `FIP, WAR` | double | All |
| `QS` | integer | Steamer, ATC only — see Derived Columns |

---

## Derived Columns

### SVHD

Not present in any projection source. Always computed as:

```r
SVHD = SV + HLD
```

On the first call per session, emits:

```r
rlang::inform(
  "SVHD computed as SV + HLD. Verify this matches your league's SVHD definition.",
  .frequency = "once",
  .frequency_id = "rotostats_svhd_definition"
)
```

### QS (when absent)

ZiPS does not include QS. When `source = "zips"` and QS is a scored category:

```r
cli::cli_warn(
  "QS is not available in ZiPS projections. {.field sgp_QS} will be {.val NA}
   for all pitchers. Use a source that provides QS (Steamer, ATC) or supply
   custom projections."
)
```

---

## Custom Projections

When `source = "custom"`, the `data` argument must be a data frame containing at minimum:

- `name` or `playerid` (at least one)
- One column per scored category in the user's league

No column derivation is applied to custom projections — the data frame is used as-is.
Users are responsible for pre-computing any combo stats (SVHD, OPS, QS) before passing.

**Recommended workflow for custom projections:**

```r
library(baseballr)
proj <- fg_batter_leaders(...)   # or any other source
proj$SVHD <- proj$SV + proj$HLD  # pre-compute combo stats
sgp(get_projections("custom", data = proj), denominators)
```

---

## FanGraphs Projection System Documentation

- [Steamer Projections](https://www.fangraphs.com/projections.aspx?pos=all&stats=bat&type=steamer)
- [ZiPS Projections](https://www.fangraphs.com/projections.aspx?pos=all&stats=bat&type=zips)
- [ATC Projections](https://www.fangraphs.com/projections.aspx?pos=all&stats=bat&type=atc)
- [FanGraphs Depth Charts](https://www.fangraphs.com/projections.aspx?pos=all&stats=bat&type=rfangraphsdc)
- [THE BAT](https://www.fangraphs.com/projections.aspx?pos=all&stats=bat&type=thebat)

---

## Known Gaps by Source

| Issue | Affected sources | Handling |
|-------|-----------------|----------|
| SVHD not provided | All | Always derived as `SV + HLD`; one-time `rlang::inform()` |
| QS not provided | ZiPS | `cli_warn()` + `NA` when QS is a scored category |
| Column names may vary | All | Normalized to consistent names on return |
