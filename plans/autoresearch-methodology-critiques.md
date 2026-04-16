# Methodology Critiques: Autoresearch Validation Framework

Sourced from comments on Podhorzer & Bulay (2015), "The Great Valuation System Test: The
Process." These critiques apply to the autoresearch benchmark design used in
`plans/autoresearch-valuation.md`.

---

## Critique 1: The $1-Player Problem (Brian)

**Claim:** Every valuation system dramatically underestimates the number of players who sell
for $1 at auction. Systems typically project only a handful of $1 players; the real number
in a mixed league auction is closer to 45. Systems that get this wrong can still correlate
well with team standings while producing useless individual player prices.

**Validity: Valid and important.**

**Implication for autoresearch:** Spearman ρ with standings is the primary optimization
target, but it does not penalize $1-pool miscalibration. After identifying the best
correlating system, run a secondary diagnostic: compute the mean projected value for players
who actually sold for $1 in historical Moonlight Graham auctions. A well-calibrated system
should produce values near $1 for these players, not large positive values.

This is already listed in `autoresearch-valuation.md §3h` as the `calibration min-N ($1
pool)` parameter sweep — it should also be reported as a diagnostic for every Phase winner,
not just as a tuning target.

---

## Critique 2: Raw Values vs. Auction-Ready Values (Brian, follow-up)

**Claim:** Valuation systems cannot be fairly compared without the strategic tweaks a
competitive analyst would apply (e.g., discounting non-closer relievers, adjusting for
category volatility). Comparing raw outputs ignores that practitioners adapt systems for
real auctions, just as projection systems require proper playing time adjustments.

**Validity: Partially valid — conflates two questions.**

**Implication for autoresearch:** The autoresearch benchmark correctly tests *inherent
value accuracy* (methodology quality in isolation) rather than *auction utility* (methodology
quality plus strategic overlay). This is the right scope. However, any system that wins on
correlation should be reviewed for whether strategic adjustments (e.g., reliever discount,
catcher adjustment §3e) change the correlation ranking materially — if they do, the raw
ranking is misleading.

---

## Critique 3: End-of-Season Values ≠ Pre-Season Applicability (Jason Bulay, co-author)

**Claim:** The test uses actual season stats to generate values, not projections. It
demonstrates which methodology is most accurate *given perfect information*, but does not
validate that the same methodology produces similarly ranked systems when applied to
pre-season projections (which have substantial error).

**Validity: Valid and acknowledged.**

**Implication for autoresearch:** The autoresearch plan correctly inherits this design
choice — using actual stats isolates methodology quality from projection accuracy, which is
the right call for calibration. But the output should always be interpreted as:

> "Best methodology assuming actual stats; projection error introduces additional noise in
> real pre-season use that this benchmark does not measure."

Do not over-interpret a winning ρ as evidence that the system will perform well in auctions
where projections are imperfect. A separate validation step using pre-season projections
correlated with the same standings would be needed to close this gap.

---

## Critique 4: Mid-Season Roster Noise (John Eric Hanson)

**Claim:** Using season-end rosters introduces noise from mid-season pickups, drops, and
trades. The roster at season end partially reflects in-season management skill rather than
pre-auction valuation quality. Opening-day rosters evaluated against full-season stats would
be cleaner.

**Validity: Valid.**

**Implication for autoresearch:** The Moonlight Graham `player_valuations_{year}.csv` files
should be checked: do they reflect opening-day rosters, or the final rosters as of season
end? If the latter, players acquired mid-season are included in the team's value sum even
though no valuation system could have predicted their presence on that roster at auction
time. This conflates valuation accuracy with in-season waiver management.

**Recommended action:** Before running experiments, verify the roster snapshot date. If
possible, use opening-day roster assignments only. If season-end rosters are unavoidable,
note this as a noise source in the interpretation of results — it affects all systems
equally, so it degrades correlation signal uniformly but does not bias relative rankings.

---

## Critique 5: Pitching Value from Waiver Wire (John Eric Hanson)

**Claim:** A disproportionate share of pitching value in a roto season comes from waiver
wire acquisitions during the year, not from opening auction decisions. Evaluating end-of-year
pitcher rosters against standings thus conflates auction valuation quality with in-season
streaming/pickup skill. This is a stronger concern for pitchers than hitters.

**Validity: Valid — and supports the hitter-only design.**

**Implication for autoresearch:** The autoresearch plan focuses on hitters for the
correlation benchmark, consistent with the Fangraphs study. If pitcher valuation is added
to the benchmark in a future phase, this critique requires using opening-day pitcher rosters
only (not season-end) to avoid conflating auction valuation with in-season pitching
management.

---

## Summary Table

| Critique | Validity | Already in Plan? | Action |
|---|---|---|---|
| $1-pool miscalibration | Valid, important | Partially (§3h tuning) | Add as a reported diagnostic for every Phase winner |
| Raw vs. auction-ready values | Partially valid | Implicitly scoped out | OK as-is; note in interpretation |
| End-of-season stats ≠ pre-season | Valid | Acknowledged by design | Add interpretive caveat to results |
| Mid-season roster noise | Valid | Not addressed | Verify roster snapshot date in data files |
| Pitcher waiver noise | Valid | Avoided (hitters only) | Keep hitter-only scope; note if extending to pitchers |
