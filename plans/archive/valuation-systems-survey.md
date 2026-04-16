# Alternative Valuation Systems — Future Implementation Candidates

Survey of publicly documented rotisserie auction valuation systems that could be added to rotostats. Ordered roughly from most to least implementation-ready.

---

## LPP (Last Player Picked) — Mays Copeland

**Sources:** [Python](https://github.com/mayscopeland/priceguide) · [R port](https://github.com/couthcommander/lastplayerpicked) · [PHP/Ottoneu fork](https://github.com/ottoneu/last-player-picked) · [FanGraphs system test](https://fantasy.fangraphs.com/the-great-valuation-system-test-the-process/)

**What it is:** Z-score system with iterative pool convergence. Source code is publicly available across three implementations.

**Steps:**
1. Define pool: `n_teams × roster_slots` for hitters/pitchers separately
2. Convert rate stats to xStats: `xStat_i = numerator_i - (denominator_i × pool_avg_rate)` — volume-adjusted counting equivalents, sign-flipped for "lower is better" categories
3. Z-score all categories over the top-N pool; sum to `total`
4. Sort by `total`, identify per-position replacement level (the Nth player at that position), subtract: `adj_total = total - replacement_level[pos]`
5. **Iterate** — pool composition and SDs are mutually dependent, repeat until SDs stabilize (3–10 passes)
6. Dollar conversion: `$ = adj_total × (marginal_budget / sum_of_adj_totals) + $1`

**Key distinction from REP:** REP allocates dollars per-category; LPP sums z-scores first then converts the aggregate. Functionally similar outputs, different intermediate values.

---

## rPAA (Roto Points Above Average) — Jesse Sakstrup

**Sources:** [Outlining Fantasy Baseball Valuation Systems (THT)](https://tht.fangraphs.com/outlining-fantasy-baseball-valuation-systems/) · [Adding More Context (THT)](https://tht.fangraphs.com/fantasy-valuation-systems-adding-more-context/)

**What it is:** Converts stats to roto points using universal constants derived from 2009–2011 league data. No league-specific denominators needed.

**Constants (stats per 1 roto point):** R: 25.0, HR: 10.3, RBI: 26.3, SB: 11.3, K: 45.6, W: 3.71, SV: 13.8

**Formulas:**
```
# Hitters
raw_roto = (R/25.0) + (HR/10.3) + (RBI/26.3) + (SB/11.3)
         + ((AVG - 0.27356) / 0.02925) × (AB / 554.5)

# Pitchers
raw_roto = (K/45.6) + (W/3.71) + (SV/13.8)
         + ((3.6705 - ERA) / 0.6868) × (IP / 192.5)
         + ((1.2569 - WHIP) / 0.118) × (IP / 192.5)
```

**Positional adjustment:** Subtract the average raw_roto of the top-N players at each position → rPAA (above average, not above replacement).

**Dollar conversion:** Proportional budget allocation over positive-rPAA players + $1 floor.

**Caveat:** Constants calibrated on 2009–2011 data — the HR constant (10.3) likely too small post-2015 juiced ball era; SB constant (11.3) may be off given stolen base volatility.

---

## E.Y.E.S. — Jeff Gross (THT, 2011)

**Sources:** [Original article (defunct)](http://www.hardballtimes.com/main/fantasy/article/valuing-players-with-your-e.y.e.s/) · [Sakstrup summary with full formulas (THT)](https://tht.fangraphs.com/outlining-fantasy-baseball-valuation-systems/)

**What it is:** Z-score variant with league-size-specific standard deviations. The acronym expansion was never publicly documented (the 2011 original article is no longer accessible).

**The key differentiator:** Rather than computing σ over all MLB players, E.Y.E.S. computes σ over **your specific league's player pool** — all rostered players plus anyone with Z ≥ 1.0 in any single category (the "one-category contributor" rule). A 10-team league has wider SDs than a 15-team league.

**Steps:**
1. Build pool: `n_teams × roster_size` + any player with z ≥ 1.0 in any category
2. Compute mean and σ per category over that pool
3. Z-score counting stats: `(stat - mean) / σ`
4. Volume-weight ratio stats: multiply ratio z-score by `(AB / 554.5)` or `(IP / 192.5)`, then re-standardize
5. Sum z-scores per player
6. Subtract positional average → above-average scores
7. `$/Z_unit = (total_budget - n_roster_spots) / sum_of_positive_Z`; `$ = Z_adj × $/Z + $1`

**Correlation with rPAA:** R = 0.9735 (hitters), 0.9524 (pitchers).

---

## FPR (Fantasy Player Rater) — Mike Silver

**Sources:** [THT comparison article](https://tht.fangraphs.com/outlining-fantasy-baseball-valuation-systems/) · [Adding More Context](https://tht.fangraphs.com/fantasy-valuation-systems-adding-more-context/) · [FanGraphs Player Rater tool](https://www.fangraphs.com/fantasy-tools/player-rater)

**What it is:** Applies diminishing marginal utility to counting stats via a concave transform. The original site is defunct and **the exact formula was never published**. What is confirmed:

- A concave function (sqrt, log, or power law with α < 1) is applied to counting stats before scoring
- Ratio stats handled with volume-weighted counting equivalents (same approach as rPAA/E.Y.E.S.)
- Baseline is league average (not replacement)
- Correlates at R > 0.92 with linear systems — differences emerge mainly for stolen-base specialists and extreme category accumulators

**The best implementable approximation:**
```r
transform_stat <- function(x, method = "sqrt") {
  switch(method,
    sqrt  = x ^ 0.5,
    log   = log(x + 1),
    power = x ^ 0.6   # alpha tunable
  )
}
```

Apply this transform to each counting stat before computing any z-scores or roto points. The practical effect: a 60-SB player scores ~41% more than a 30-SB player (sqrt) instead of 100% more (linear).

---

## FVARz — Zach Sanders (FanGraphs RotoGraphs)

**Sources:** [Part 1](https://fantasy.fangraphs.com/value-above-replacement-part-one/) · [Part 2](https://fantasy.fangraphs.com/value-above-replacement-part-two/) · [Part 3](https://fantasy.fangraphs.com/value-above-replacement-part-three/) · [Revised version](https://fantasy.fangraphs.com/basebal-fantasy-value-above-replacement/)

**What it is:** Z-scores anchored to position-specific replacement level, with volume-weighted rate stats and a dollar formula guaranteed to produce $1 floors.

**Steps:**
1. Filter to ≥400 AB / ≥100 IP
2. Compute z-scores per category **within** each position group (catchers vs catchers, etc.)
3. Volume-weight rate stats: `wBA = z_AVG × AB_i`, then re-standardize: `z_BA_final = (wBA - mean(wBA)) / sd(wBA)`
4. Sum z-scores → FVAAz (above average)
5. Identify replacement player count per position via mock draft sampling (e.g., catchers: 12, SS: 16, OF: 62)
6. `FVARz = FVAAz - FVAAz_of_Nth_player_at_position` → replacement-level players = 0
7. Optional: apply 0.8× multiplier to pitchers (removed in revised version)
8. `$ = 10.3 × (FVARz / 3) + 1` (for standard 12-team $260 leagues)

**Revised version:** Pools all hitters together and all pitchers together for the initial z-score pass (prevents artificial inflation of positionally rare stats like a catcher's stolen bases), then applies positional replacement level adjustments afterward. Also drops the 0.8× pitcher multiplier.

---

## Summary: Which Baseline, Which Unit

| System | Baseline | Unit of value | Rate stat handling | League-specific? |
|---|---|---|---|---|
| SGP | Replacement | Standings points | Convert to counting via denominators | Yes |
| PVM/REP | Replacement | Dollar share of stat pool | "Extras" counting equivalents | Configurable |
| LPP | Replacement (per-position) | Z-scores | xStats (counting equivalents) | Partially (SD is pool-specific) |
| FVARz | Replacement (per-position) | Z-scores | Volume-weighted re-standardized | Partially |
| rPAA | Average | Roto points | Fixed-denominator counting equiv | No (universal constants) |
| E.Y.E.S. | Average | Z-scores | Volume-weighted | Yes (σ computed per league size) |
| FPR | Average | Roto points (nonlinear) | Volume-weighted counting equiv | No |

The actionable implementation difference: if you want replacement-level semantics (the $1 floor player is explicitly waiver-wire), use LPP, FVARz, REP, or SGP. If you want simpler math without needing to define a precise replacement boundary, rPAA or E.Y.E.S. get you 92%+ of the way there with less machinery.
