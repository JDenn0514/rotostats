# Plan: Addressing Remaining `zaa()` Follow-ups

> Created: 2026-04-21
> Source: Follow-up items from run `zaa-2026-04-21` (reviewer verdict
> PASS WITH NOTE, PR [#23](https://github.com/JDenn0514/rotostats/pull/23)
> against `develop`)
> Related: `specs/spec-zaa.md`, `plans/error-messages.md`, `ARCHITECTURE.md`,
> `plans/autoresearch-valuation.md`

---

## Status summary

| Ticket | Slug | Type | Status |
|---|---|---|---|
| Z1 | `zaa-test-coverage-extensions` | Test-only | ✅ **Complete** (PR #24) |
| Z2 | `zar-implementation` | Code + Simulation | ✅ **Complete** (PR #25) |
| Z3 | `zaa-test-spec-ts7-prose-correction` | Archive note | ✅ **Closed** — non-actionable |

Each request = one statsclaw run with its own request ID, its own feature
branch (`feature/<slug>`), and its own PR into `develop`. The slug gets
baked into the run directory under
`~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/<slug>-YYYY-MM-DD/`.

Z1 is a small test-only bundle that fills the two coverage gaps the
reviewer flagged on PR [#23](https://github.com/JDenn0514/rotostats/pull/23).
Z2 is the real next function in the valuation family — it consumes
`zaa()` as its internal building block and unblocks the restoration of
the `[zar()]` `@seealso` link inside `R/zaa.R`. Z3 is a documentation
correction to a frozen workspace artifact; left here for traceability,
not scheduled as a run.

---

## Sequencing principle

- **Wave 1** — Z1 only. Test-only, cheap, fills coverage gaps on the
  shipped code. Lands first so Z2 starts from a fully-covered `zaa()`.
- **Wave 2** — Z2. Full statsclaw workflow (planner → builder ∥
  simulator → tester → scriber → reviewer → shipper). Uses `zaa()` as
  its internal building block; includes the `@seealso` restoration as
  part of its normal scriber work.
- **Archive** — Z3. No run; captured here only so the TS-ZAA-7 prose
  inversion is discoverable if someone revisits the 2026-04-21
  `test-spec.md` in the workspace.

---

## Dependency graph

```
Z1 ── (test-only; no blockers)
       │
       v
Z2 ── `zar()` build; restores [zar()] @seealso in R/zaa.R as part of scriber
```

Z1 does not block Z2 strictly — `zar()` could be built without the two
added test scenarios — but running Z1 first keeps the `zaa()` surface
fully covered before a downstream consumer lands, which helps any
regressions from Z2 localize cleanly.

---

## Pre-flight for every request

Before dispatching any request:

```bash
git -C /Users/jacobdennen/rotostats checkout develop
git -C /Users/jacobdennen/rotostats pull --ff-only origin develop
```

Do NOT pre-create the feature branch locally — each statsclaw run cuts
its own feature branch and specialist teammates work inside git
worktrees.

**Branch-name hygiene.** Before dispatching, confirm the target feature
branch name is NOT already present locally (`git branch --list
feature/<slug>`).

All prompts below MUST be pasted into a **fresh** Claude Code session
(so Leader starts with clean context).

---

## Request specs and dispatch prompts

### Z1 — `zaa-test-coverage-extensions`

**Objective.** Close the two test-coverage gaps the reviewer flagged in
`review.md` §"Notes for shipper" after PR [#23](https://github.com/JDenn0514/rotostats/pull/23):

1. **Positional-replacement post-fix coverage.** The `blank_labels` NA
   crash fixed in commit `1c3ef24` affected `zaa()` whenever
   `replacement` was supplied alongside `hitter_pool = "positional"`
   (the default) OR when the pool contained any pitcher rows. The
   original tester's TS-ZAA scenarios that hit this path worked around
   the bug with `hitter_pool = "combined"`. The fix shipped, but no
   end-to-end test exercises the default `hitter_pool = "positional"`
   path with `replacement` supplied and a mixed hitter/pitcher pool.
   Add one.

2. **AVG in a mixed hitter/pitcher pool with `weight_method != "none"`.**
   Under the spec's `na.rm = FALSE` rowSums rule, pitchers in a league
   that scores AVG get `zaa_AVG = NA` (no `AB` → NA volume → NA
   z-score), which propagates to `total_zaa = NA` for all pitchers.
   The original TS-ZAA-5 fixture sidestepped this with pure counting
   categories. Add a scenario (tentatively TS-ZAA-19) that asserts the
   documented behavior directly, so the propagation is pinned as
   intentional rather than accidental.

**Scope (test-only — no code, no spec change, no docs rewrite).**

1. Extend `tests/testthat/test-zaa.R` with two new scenarios:
   - `TS-ZAA-Z1a`: `hitter_pool = "positional"` (default) +
     `replacement` supplied + mixed hitter/pitcher pool → function
     completes without error; returns a data frame with the correct
     shape; attribute `distribution` is nested for the hitter side and
     flat-or-nested for the pitcher side per its pool setting.
   - `TS-ZAA-19`: scored categories include AVG + mixed pool +
     `weight_method = "linear"` → pitchers' `zaa_AVG` is NA, their
     `total_zaa` is NA (confirming the `na.rm = FALSE` convention),
     hitters' `total_zaa` is finite and scaled as specified. Include
     an inline `# DOCUMENTED BEHAVIOR` comment naming the spec
     section.
2. Extend `tests/testthat/helper-zaa-fixtures.R` only if the existing
   fixtures can't be reused directly. Prefer reusing the existing
   mixed-pool fixture with an argument toggle.

**Explicitly out of scope.**

- No change to `R/zaa.R`.
- No change to `specs/spec-zaa.md`, `test-spec.md` in the workspace
  run dir, or `ARCHITECTURE.md`.
- No `NEWS.md` entry (test-only, no user-visible behavior change).
- No changes to `plans/error-messages.md`.

**Acceptance.**

- `devtools::test(filter = "zaa")` reports ≥ 106 passes
  (104 existing + 2 new), 0 fails, 0 warns, 0 skips.
- `devtools::check()`: 0 errors, 0 warnings, notes unchanged from
  `develop`.
- Reviewer confirms the two new scenarios test observable behavior
  only and do not reach into implementation internals.

**Effort.** ~20–30 min including dispatch overhead.

#### Dispatch prompt (paste to Leader)

```
Request ID: zaa-test-coverage-extensions-2026-MM-DD

Test-only — add two scenarios to tests/testthat/test-zaa.R. No source
or spec change.

Read plans/zaa-cleanup.md §"Z1 — zaa-test-coverage-extensions" for the
authoritative scope. Also read:
  - specs/spec-zaa.md (public-facing behavior)
  - tests/testthat/test-zaa.R and helper-zaa-fixtures.R (existing)
  - The run review: ~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/zaa-2026-04-21/review.md

## Changes required

1. Add TS-ZAA-Z1a: hitter_pool="positional" (default) + replacement
   supplied + mixed hitter/pitcher pool.
   - Assertions: zaa() returns a data frame without error; nrow equals
     the rostered-set size from replacement's position_assignments;
     attr(result,"distribution") is nested on the hitter side.

2. Add TS-ZAA-19: AVG in mixed pool + weight_method="linear".
   - Assertions: zaa_AVG is NA for every pitcher row; total_zaa is NA
     for every pitcher row; hitters' total_zaa is finite; hitter ratio
     (n_hitter_cats / n_hitter_cats) == 1 is preserved; include a
     # DOCUMENTED BEHAVIOR comment citing spec-zaa.md Step 2/Step 4.

## Acceptance criteria

- devtools::test(filter="zaa"): ≥ 106 pass, 0 fail, 0 warn, 0 skip.
- devtools::check(): 0 errors, 0 warnings, notes unchanged.
- No changes outside tests/testthat/.

## Hard constraints

- Do NOT read R/zaa.R internals to shape assertions — treat as black
  box. Drive every assertion from the public spec.
- Reuse existing fixture helpers where possible.
- No change to R/, man/, NAMESPACE, NEWS.md, ARCHITECTURE.md, specs/,
  or plans/.

## Workflow

Test-only. Tester → Reviewer → Shipper. Skip Planner, Builder, Scriber,
Simulator.

## Branch

- Feature branch: feature/zaa-test-coverage-extensions
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### Z2 — `zar-implementation`

**Objective.** Implement `zar()` — z-scores above replacement — the
natural next function in the valuation family. `zar()` consumes
`zaa()`'s within-position z-score machinery and subtracts the
replacement-level player's z-score to produce the "above replacement"
metric that's directly usable for dollar-value construction.

**Why file this now.** Three converging signals:

1. `zaa()` was shipped explicitly as the internal building block for
   `zar()` (see `R/zaa.R` roxygen `@seealso` — the `[zar()]` link was
   temporarily dropped because the function doesn't exist yet).
2. `ARCHITECTURE.md`'s valuation-family call graph has a reserved
   `zar()` node; the section is live but empty.
3. `plans/autoresearch-valuation.md` and the memory file
   `memory/project_valuation_architecture.md` both call out `zar()` as
   the z-score branch's analogue to `par()` — the next piece in the
   par/zpar/pvm/value_plus family.

**Scope (Code + Simulation — full statsclaw workflow).**

1. **Spec.** `specs/spec-zar.md` — to be authored by Planner during
   dispatch. Draw the conceptual shape from `specs/spec-zaa.md` and
   `specs/spec-par.md`. Core semantics: `zar(...) = zaa(...)` minus the
   replacement-band-average z-score per category per position.
2. **Builder.** `R/zar.R` — exported. Internal building block must be
   `zaa()` (called with matched pool settings). The replacement-band
   average z-score is read from `attr(zaa_result, "distribution")`,
   which was designed for exactly this consumer path.
3. **Tester.** Invariants: `zar_<cat>` columns sum to `total_zar`;
   replacement-band player has `total_zar ≈ 0`; rate-stat sign
   convention preserved; pool semantics propagated from `zaa()`.
4. **Simulator.** `zar()` is a statistical estimator — Monte Carlo
   validation is part of the acceptance bar. DGP should exercise
   regime-stable and regime-break scenarios similar to the `par()`
   simulation study.
5. **Scriber.** Regenerate `man/zar.Rd` and `NAMESPACE`; add NEWS
   entry; extend `ARCHITECTURE.md`'s ZAR section; **restore the
   `[zar()]` `@seealso` link inside `R/zaa.R`** and regenerate
   `man/zaa.Rd` (this is the only surgical edit to shipped `zaa()`
   surface).

**Acceptance (to be refined by planner).**

- `zar_<cat>` columns + `total_zar` return in the same shape as
  `zaa()`'s `zaa_<cat>` + `total_zaa`.
- Player at the exact replacement band in every category has
  `total_zar ≈ 0` (within numeric tolerance).
- Pool settings (`hitter_pool`, `pitcher_pool`, `weight_method`,
  `category_weight`) mirror `zaa()`'s semantics exactly.
- Monte Carlo study confirms replacement-centered invariant under
  null-DGP (no ranking shift) and captures the documented sensitivity
  under regime-break DGP.
- `devtools::check()`: 0 errors, 0 warnings.
- `R/zaa.R`'s `@seealso` block lists `[zar()]` again.

**Effort.** Large — comparable to `zaa-2026-04-21` (initial build)
plus a simulation pipeline. Plan for a dedicated session.

#### Dispatch prompt (paste to Leader — compose once `specs/spec-zar.md` exists, or author it in the planner step)

```
Request ID: zar-2026-MM-DD

Build the zar() function for the rotostats R package — z-scores above
replacement.

Read specs/spec-zar.md before planning (author it during the planner
step if not already present). Read specs/spec-zaa.md and specs/spec-par.md
for sibling conventions.
Read plans/error-messages.md for the canonical error and warning class
names to use.
Read plans/zaa-cleanup.md §"Z2 — zar-implementation" for the authoritative
scope.

## Acceptance criteria

- Return shape: data frame with zar_<cat> columns + total_zar +
  player_id + pool_label, matching zaa()'s output convention.
- Replacement-band invariant: a player whose per-category z-scores
  equal the replacement-band average z-scores has total_zar ≈ 0 within
  numeric tolerance.
- Pool semantics propagated from zaa(): hitter_pool, pitcher_pool,
  weight_method, category_weight all route to the internal zaa() call
  and apply identically to the replacement-band-average subtraction.
- Rate-stat sign convention preserved (lower-is-better categories
  negated consistently through total_zar).

## Hard constraints

- zar() MUST call zaa() as its internal building block — no
  reimplementation of the z-score machinery.
- The replacement-band average z-score MUST be read from
  attr(zaa_result, "distribution") (the consumer path zaa() was
  designed for).
- All parameters explicit: stats, config, replacement, pitcher_pool,
  hitter_pool, category_weight, weight_method. No hardcoded defaults
  that shadow user input.
- No row-wise loops — vectorized per-player computation.
- Errors and warnings via cli_abort()/cli_warn() with class= from
  plans/error-messages.md — never bare stop() or warning().
- As part of scriber: restore @seealso [zar()] inside R/zaa.R and
  regenerate man/zaa.Rd. This is the ONLY edit to zaa()'s shipped
  surface that this run makes.

## Workflow

Full Code + Simulation workflow. zar() is a statistical estimator —
Monte Carlo validation is part of the acceptance bar.

## Branch

- Feature branch: feature/zar
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### Z3 — `zaa-test-spec-ts7-prose-correction` (archive note)

**Status.** Non-actionable as a repo change.

**What it is.** The reviewer found that `test-spec.md` §TS-ZAA-7 in
the workspace run directory
(`~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/zaa-2026-04-21/test-spec.md`)
states the pitcher_pool direction as "combined < split for RP1 zaa_SV"
when the mathematically correct direction for the specified fixture is
the reverse (combined > split, because SP zeros inflate the combined
pool SD more than they deflate the combined pool mean — see
`audit.md` §"Spec Ambiguities" for the full derivation). The shipped
`test-zaa.R` asserts the correct direction (combined > split); the
implementation is correct; the only artifact with the inverted prose
is the frozen planner-era spec copy in the workspace run dir.

**Why no repo change is planned.** The workspace `test-spec.md` is a
historical artifact for the `zaa-2026-04-21` run; it is not a
target-repo file and is not read by any future consumer (future runs
read their own fresh `test-spec.md`). Editing a frozen run artifact
after the fact is out of process.

**If someone wants to surface this.** Open a GitHub issue referencing
[PR #23](https://github.com/JDenn0514/rotostats/pull/23) and link the
paragraph in `review.md`. That's the right place for a corrections log
visible to future readers.

---

## Definition of done (for each scheduled request)

- Feature branch merged to `develop` with clean `R CMD check`
  (0 errors, 0 warnings, only pre-existing notes).
- Run artifacts in
  `~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/<slug>-YYYY-MM-DD/`.
- `NEWS.md` entry for user-visible changes (Z2 only; Z1 is test-only).
- Reviewer verdict: SHIP.
- No new follow-up items left un-triaged in `review.md`.

---

## What this plan intentionally leaves out

- **`pvm()` and `dollar_values()`.** Downstream valuation family
  functions that consume `zar()` (and/or `par()`). Track under
  `plans/autoresearch-valuation.md` — not a `zaa()` follow-up.
- **`value_plus()`.** Same — downstream consumer, separate scope.
- **Spec-level changes to `zaa()`'s defaults.** If `zar()`'s
  simulation study surfaces a case where `zaa()`'s default pool
  settings are misleading, file a separate request rather than
  bundling a default change into Z2.
- **The `@seealso [zar()]` restoration as its own run.** Folded into
  Z2's scriber step — splitting it into a standalone docs run would
  land `[zar()]` before the function exists, which is what PR [#23](https://github.com/JDenn0514/rotostats/pull/23)
  explicitly avoided.
