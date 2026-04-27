# Code Follow-Ups

Tracker for non-blocking issues surfaced during other work. Not implementation
plans — these are flagged items to triage and either elevate to their own plan
or fix in passing.

---

## 1. `pos_eligibility` delimiter mismatch

**Surfaced:** 2026-04-27, during auction CSV cleanup brainstorm.

`replacement_from_prices()` documents pipe-delimited eligibility strings, but
the tout-wars rosters scraper emits comma-delimited.

- [R/replacement.R:1146](../R/replacement.R) — `pos_eligibility` documented as `"1B|3B"` (pipe).
- [plans/specs/2026-04-26-tout-wars-scrapers-design.md:96](specs/2026-04-26-tout-wars-scrapers-design.md) — rosters output documented as `"1B,SW,INF"` (comma).

**Why it matters:** any code path that joins rosters → prices → `replacement_from_prices()` will silently misparse eligibility (treating the whole string as one position).

**Decision needed:** pick one canonical delimiter project-wide. Pipe is more conventional for "any-of" semantics (matches regex alternation); comma is more human-readable. Once chosen, update the other site and add a one-line normalizer at the consumer boundary so future inputs that disagree are coerced rather than silently broken.

---

## 2. `player_type` vocabulary drift (`batter` vs. `hitter`)

**Surfaced:** 2026-04-27, during auction CSV cleanup brainstorm.

Three vocabularies coexist in the codebase:

| Surface | Value | Location |
|---|---|---|
| `league_history(prices=)` validate input | `"batter"` / `"pitcher"` | [R/league-history.R:243](../R/league-history.R) |
| `par()` output column | `"batter"` / `"pitcher"` | [R/par.R:467](../R/par.R) |
| `sgp()` internal (after silent normalize) | `"hitter"` / `"pitcher"` | [R/sgp.R:632-633](../R/sgp.R) |
| `.classify_category_side()` return | `"batter"` / `"pitcher"` | called from [R/sgp.R:419-422](../R/sgp.R) |
| Rate-stat registry `pool_type` | `"hitter"` / `"pitcher"` | [R/rate-stat-formulas.R](../R/rate-stat-formulas.R) |

`sgp()` papers over the mismatch with a silent `"batter" -> "hitter"` rewrite at line 632. Not a bug — but the dual vocabulary is a footgun for anyone editing internals.

**Decision needed:** pick one canonical term (`"batter"` is the public-facing default; `"hitter"` is the registry default). Either rename the registry's `pool_type` to `"batter"`, or rename the public surface to `"hitter"`. Then delete the silent normalization.

**Suggested:** keep `"batter"` (already public-facing, already in `league_history` validation, already documented in user-visible columns). Rename registry `pool_type = "hitter"` entries to `"batter"` and drop the line-632 normalization.

---

## 3. Cross-year owner-identity drift in `tout_wars_auctions`

**Surfaced:** 2026-04-27, during the final review of `feature/auction-csv-normalization`.

`tout_wars_auctions` contains both first-name-last-name and last-name-only spellings of the same owner across years. Examples:

- `"PODHORZER"` (2014–2019) vs `"MIKE PODHORZER"` (2020–2026)
- `"MELCHIOR"` (early years) vs `"AL MELCHIOR"` (later)
- COLTON/WOLF partnership: `"COLTON/WOLF"`, `"COLTON WOLF"`, `"COLTON AND THE WOLFMAN"`, `"COLTON AND WOLF"`, `"GLENN COLTON/RICK WOLF"` (5 distinct spellings)

`R/utils-tout-wars.R:9-14` (`.tw_owner_aliases`) only normalizes the COLTON/WOLF partnership patterns; it doesn't strip first names from individual owners. Multi-token names like `"Mike Podhorzer"` upcase to `"MIKE PODHORZER"` rather than canonicalizing to `"PODHORZER"`.

**Why it matters:** any year-over-year `group_by(team_owner)` summary will silently miscount owners with first-name drift. Joins against an external owner master will fragment.

**Decision needed:** pick a canonicalization strategy. Either:
- (a) Extend `.tw_owner_aliases` with explicit per-owner mappings (~30+ entries; safest but high-touch), or
- (b) Add a "last-token-of-the-string" rule in `.canonicalize_tw_owner()` (covers most cases but breaks compound surnames like `"VAN RIPER"`).

**Suggested:** option (a). Build the alias table by inspecting `unique(tout_wars_auctions$team_owner)` once; map each first-name-last-name variant to its last-name canonical form. Add tests for the new aliases. The current `.tw_owner_aliases` already has the right shape for this.

---

## Adding new follow-ups

Append to this file. Each entry: short title (H2), surfaced-during context,
file/line citations, why-it-matters, decision-needed. Resolved entries can be
deleted (git history preserves them) or struck through.
