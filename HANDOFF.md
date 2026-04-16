# Handoff Summary

**Date:** 2026-04-10
**Branch:** `develop`
**Working directory:** `/Users/jacobdennen/rotostats`

---

## Goal

Work through the 9 open Q1 (conceptual) questions in `specs/spec-sgp.md`, closing each one with a firm decision grounded in the published SGP literature, knowledge base research, and direct API investigation. We made it through Q1-SGP-9 down to Q1-SGP-3, leaving 3 questions open (Q1-SGP-3, Q1-SGP-7, Q1-SGP-8).

---

## Decisions Made

- **Q1-SGP-9 (thin history threshold):** Minimum is **3 complete seasons** (not `n_teams × 3` years — that was a unit error in the original spec). Basis: Tanner Bell (Smart Fantasy Baseball, 2016) explicitly named 3 seasons as the floor below which single-league data is too noisy. Warning fires at `< 3 seasons`.

- **Q1-SGP-6 (combo stat handling):** **Direct projection column first; component fallback second** (reversed from original spec). Rationale: projection sources are authoritative. Per-stat: OPS is always a direct column; SVHD is never in projection columns — always computed as `SV + HLD` with `rlang::inform(.frequency = "once")`; QS is direct in Steamer/ATC, absent in ZiPS (`cli_warn()` + `NA`).

- **Q1-SGP-5 (`total_sgp` aggregation):** `total_sgp` is the **direct sum of all categories including rate stats**. Rate stat SGP is in standings-point units by the time it's returned — no deferral to `par()`. `total_sgp` is directly comparable across hitters and pitchers; the hitter/pitcher budget split is a `dollar_values()` concern only.

- **Q1-SGP-4 (rate stat SGP method):** Dropped `"raw_ip"` (was architecturally wrong — stopped one step before producing standings-point units). Replaced with two valid methods: `"blended_pool"` (default — Smart Fantasy Baseball / FanGraphs standard; player blended into average team pool) and `"fixed_baseline"` (Zola/Benson/Mosey counting-equivalent; roster-agnostic). Both tested in autoresearch §2e.

- **`get_projections()` function design:** New companion function for `sgp()`. Calls `https://www.fangraphs.com/api/projections` directly (baseballr has no projection endpoint). Accepts `source` string (`"steamer"`, `"zips"`, `"atc"`, `"fangraphsdc"`, `"thebat"`, `"thebatx"`, `"custom"`). When `"custom"`, requires `data` argument. `sgp()` always takes a data frame — no string shortcut inside `sgp()` itself.

- **2023 structural break:** Added as autoresearch §2f — tests whether pre-2023 seasons should be truncated not just for SB but also R and RBI (shift ban + larger bases affected the broader run environment).

---

## Changes Made

**Specs:**
- `specs/spec-sgp.md` — closed Q1-SGP-9, Q1-SGP-6, Q1-SGP-5, Q1-SGP-4; updated formal definition of `sgp()` rate stat methods; updated `total_sgp` description; fixed stale assumption row

**Plans:**
- `plans/autoresearch-valuation.md` — added §2e (rate stat SGP method comparison: blended pool vs. fixed baseline), added §2f (2023 structural break scope — replaces old §2e), updated Phase 2 protocol to include both
- `plans/get-projections-impl.md` — **new file** — API schema reference for `get_projections()`: function signature, supported sources, FanGraphs API endpoint, output schema, derived column definitions (SVHD, QS), custom projection workflow, links to source documentation

---

## Current State

All changes are **unstaged/uncommitted** — nothing has been committed since the session started. No R code has been written yet; all work is in spec and plan documents. `devtools::check()` has not been run.

---

## Still To Do

- [ ] **Q1-SGP-3** (2023 SB structural break strategy): Three options — truncate SB window to post-2022, use exponential decay, or per-category window overrides. Option A (truncate) was preferred in original spec. This is the next question to resolve.
- [ ] **Q1-SGP-7** (`league_history` schema): Minimum required columns not yet specified. Needs wide vs. long format decision, column naming conventions, validation behavior.
- [ ] **Q1-SGP-8** (public fallback denominator source): No specific bundleable source identified yet. Candidates: Smart Fantasy Baseball, BaseballHQ, NFBC.
- [ ] **Q1-SGP-1 & Q1-SGP-2** (calibration window and year weighting): Blocked on LOYO CV run — empirical resolution via autoresearch plan §2b/§2c.
- [ ] Update `specs/spec-sgp.md` status header — Q1 open questions count should drop from 9 to 5 (4 closed this session: SGP-9, 6, 5, 4).
- [ ] Commit all spec/plan changes on a `docs/` branch and open a PR.
- [ ] Begin Phase 1 implementation (`R/sgp.R`, `R/get_projections.R`).

---

## Key Context for Next Session

- **`"raw_ip"` is gone** — any references to it in `R/sgp.R` (if that file exists) need to be updated to `"blended_pool"` / `"fixed_baseline"`.
- **baseballr cannot fetch projections** — `fg_batter_leaders(stats='proj')` silently fails. Must call `https://www.fangraphs.com/api/projections` directly with `httr`.
- **SVHD is never in projection columns** — always derived as `SV + HLD`. Not a fallback; always the primary path.
- **Q1-SGP-3 is the next decision** and was previously discussed: Option A (truncate SB to post-2022 only) was the preferred approach in the original spec. The user should weigh in before anything is written.
- **All untracked files are new** — nothing in `specs/` or the modified `plans/` files has ever been committed. A `docs/sgp-spec-q1-decisions` branch and PR would be a natural next step.
- Read `specs/spec-sgp.md` and `plans/autoresearch-valuation.md` first — they are the primary artifacts of this session.
