# Plan: Addressing Remaining `par()` Follow-ups

> Created: 2026-04-18
> Source: Follow-up items from run `par-2026-04-18` (reviewer verdict
> PASS WITH NOTE, PR #18 against `develop`)
> Related: `plans/error-messages.md`, `specs/spec-par.md`, `ARCHITECTURE.md`

---

## Status summary

| Ticket | Slug | Type | Status |
|---|---|---|---|
| P1 | `par-roxygen-counting-example` | Docs-only | ⏳ **Open** |
| P2 | `par-sim-summary-rerun` | Simulation-only | ⏳ **Open** (optional) |
| P3 | `par-reference-config-band-check` | Spec + Code | ⏳ **Open** (future) |

Each request = one statsclaw run with its own request ID, its own feature
branch (`feature/<slug>`), and its own PR into `develop`. The slug gets
baked into the run directory under
`~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/<slug>-YYYY-MM-DD/`.

P1–P3 are independent. P1 is a tiny docs touch-up. P2 is optional (the
test assertions already use the correct tolerances; only the summary CSV
shows stale values). P3 is a real design question that should be revisited
before `dollar_values()` so downstream users have a way to detect
`n_teams` miscalibration.

---

## Pre-flight for every request

Before dispatching any request:

```bash
git -C /Users/jacobdennen/rotostats checkout develop
git -C /Users/jacobdennen/rotostats pull --ff-only origin develop
```

Do NOT pre-create the feature branch locally — each statsclaw run cuts
its own feature branch and specialist teammates work inside git worktrees.

All prompts below MUST be pasted into a **fresh** Claude Code session (so
Leader starts with clean context).

**Branch-name hygiene.** Before dispatching, confirm the target feature
branch name is NOT already present locally (`git branch --list
feature/<slug>`).

---

## Open requests

### P1 — `par-roxygen-counting-example`

**Objective.** Add an unwrapped (non-`\dontrun{}`) `@examples` block to
`R/par.R` exercising the pure-counting-stats path (no `league_history`
required). Required by `specs/spec-par.md §13`.

**Scope.**

1. Add a minimal runnable example using `make_par_counting_fixture()`
   (from `tests/testthat/helper-par-fixtures.R`) or a hand-rolled
   equivalent. Must run inside `R CMD check --as-cran` without downloads
   or external state.
2. Keep the existing wrapped `\dontrun{}` example for the blended_pool
   path.
3. Re-run `devtools::document()` to regenerate `man/par.Rd`.

**Test-spec additions.** N/A.

**Simulation?** No.

**Acceptance.**

- `devtools::check()` passes with the new example running live.
- Example output is not printed to the man page (use `invisible(head(.))`
  or a quiet assignment).

**Effort.** ~15 min.

#### Dispatch prompt (paste to Leader)

```
Request ID: par-roxygen-counting-example-YYYY-MM-DD

Add an unwrapped runnable @examples block to R/par.R demonstrating the
pure counting-stats path (HR, R, SB, K, SV — no rate_conversion =
"blended_pool" dependency, so no league_history needed).

Read specs/spec-par.md §13 for the example template requirement.
Read tests/testthat/helper-par-fixtures.R for make_par_counting_fixture().

## What to produce

- R/par.R: add a second @examples block (or extend the existing one)
  with code that runs under R CMD check --as-cran.
- man/par.Rd: regenerated via devtools::document().

## Acceptance criteria

- devtools::check() passes with the new example running (NOT wrapped in
  \dontrun{}).
- The example output is suppressed (invisible() or quiet assignment).
- No new package dependencies.

## Hard constraints

- Docs-only; do NOT modify R/par.R body logic.
- Do NOT modify R/sgp.R, R/replacement.R, or tests.
- Dispatch Builder with isolation: "worktree" per the statsclaw protocol.

## Workflow

Docs-only. Builder → Reviewer → Shipper.

## Branch

- Feature branch: feature/par-roxygen-counting-example
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### P2 — `par-sim-summary-rerun`

**Objective.** Rerun `tests/simulations/sim-par.R` so
`tests/simulations/sim-par-summary.csv` reflects the amended AC-SIM-2
tolerances (SS/2B = 0.10; others = 0.05) and the removal of AC-SIM-4.
Current CSV rows flag `ac_sim2_pass = FALSE` for S1/S3 under the
pre-amendment tolerance, which is a stale artifact — the authoritative
assertions in `tests/testthat/test-par-sim.R` pass under the revised
tolerances.

**Scope.**

1. Regenerate `sim-par-results.rds` and `sim-par-summary.csv`
   deterministically from master seed 20260418.
2. Verify the regenerated CSV has `ac_sim2_pass = TRUE` for S1/S3 under
   the revised per-position tolerances.
3. Leave `ac_sim4_pass` column as NA (column retained for backward
   compatibility per planner's amendment).

**Test-spec additions.** N/A.

**Simulation?** Yes — this IS the simulation.

**Acceptance.**

- `tests/simulations/sim-par-summary.csv` shows `ac_sim2_pass = TRUE`
  for all three calibrated scenarios under position-specific tolerances.
- `devtools::test(filter = "par-sim")` continues to pass (unchanged
  authoritative assertions).
- No changes to `R/par.R`, test files, or any non-simulation artifact.

**Effort.** ~10 min (mostly waiting for the 2-minute harness to finish).

**Optional.** Skip if comfortable with the stale CSV — the test suite
is the authoritative gate.

#### Dispatch prompt (paste to Leader)

```
Request ID: par-sim-summary-rerun-YYYY-MM-DD

Regenerate tests/simulations/sim-par-results.rds and
tests/simulations/sim-par-summary.csv so the summary CSV reflects the
amended AC-SIM-2 tolerances (SS/2B = 0.10, others = 0.05) and the
removal of AC-SIM-4.

Read runs/par-2026-04-18/sim-spec.md for the current AC definitions
(amended during run par-2026-04-18 by planner respawn 1).

## What to produce

- Regenerated tests/simulations/sim-par-results.rds (1,000 rows).
- Regenerated tests/simulations/sim-par-summary.csv with updated
  ac_sim2_pass and ac_sim4_pass columns.

## Acceptance criteria

- ac_sim2_pass = TRUE for S1, S2, S3 under position-specific tolerances.
- ac_sim4_pass = NA (column retained, planner removed the criterion).
- devtools::test(filter = "par-sim") passes (unchanged).

## Hard constraints

- Simulation-only; do NOT modify R/par.R or tests.
- Use the existing tests/simulations/sim-par.R harness unchanged.
- Dispatch Simulator with isolation: "worktree" per statsclaw protocol.

## Workflow

Simulation-only. Simulator → Reviewer → Shipper.

## Branch

- Feature branch: feature/par-sim-summary-rerun
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### P3 — `par-reference-config-band-check`

**Objective.** Design (and optionally implement) a mechanism that lets
`par()` detect `n_teams` miscalibration. Currently the band check uses
`replacement$params$n_teams` for both the PAR anchor and the band
boundary, making the check tautological — a miscalibrated `n_teams`
shifts both symmetrically. This was formally documented as a structural
limitation in `ARCHITECTURE.md` and `NEWS.md`, and motivated the removal
of AC-SIM-4.

**Scope.**

1. **Spec update** (`specs/spec-par.md` or a new
   `specs/spec-par-reference-config.md`): propose an optional
   `reference_config` parameter to `par()` that provides a second
   `league_config` (or minimal sub-structure — `n_teams`,
   `roster_slots`) for an independent band check.
2. **Design decision:** does the reference config drive the band
   boundary rank, the band values, or both? Provide worked examples of
   each and show what miscalibration signal they produce.
3. **Builder path (if chosen):** wire `reference_config` through to
   Step 11 without disturbing Steps 1–10. Maintain current default
   (NULL → use `replacement$params` as today).
4. **Simulator path:** revive AC-SIM-4 with `reference_config`
   providing the true `n_teams`. Expect fire rate ≥ 75% on S4/S5
   under this configuration.
5. **Tester:** unit test that `reference_config` with matching params
   produces the same result as `reference_config = NULL`; unit test
   that a 5-slot miscalibration fires the band warning.

**Test-spec additions.** 2 new test blocks (reference config identity,
reference config miscalibration).

**Simulation?** Yes — reinstate AC-SIM-4 with the new parameter.

**Acceptance.**

- Band check fires on `miscalibrated_5` and `miscalibrated_neg5` when
  reference_config provides the true n_teams (≥ 75% fire rate in 200
  replications).
- Default behavior (reference_config = NULL) is byte-identical to
  current implementation.
- Backward compatible: `par(replacement, denominators)` with no
  reference_config behaves identically to current.

**Effort.** ~2–3 hours (spec + code + sim + tests).

**When to schedule.** Before `dollar_values()` so downstream users have
a robust miscalibration detector. Do NOT bundle with `dollar_values()`
— separate PR, separate review cycle.

#### Dispatch prompt (paste to Leader)

```
Request ID: par-reference-config-band-check-YYYY-MM-DD

Add an optional `reference_config` parameter to par() so the band
calibration check can detect n_teams miscalibration. Currently the
band check is tautological because both the PAR anchor and the band
boundary derive from replacement$params$n_teams. AC-SIM-4 was removed
from run par-2026-04-18 for this reason.

Read:
- specs/spec-par.md for the current par() signature and §7 error handling
- ARCHITECTURE.md §PAR-Known-Limitations for the structural explanation
- plans/error-messages.md for error/warning class registry

## Acceptance criteria

- par() gains a `reference_config = NULL` parameter.
- When NULL, behavior is byte-identical to current implementation.
- When provided, Step 11 uses reference_config$n_teams for the band
  boundary rank, producing a band-median check that CAN detect
  n_teams miscalibration.
- New simulation scenario: miscalibrated DGP + reference_config with
  true n_teams → band warning fires ≥ 75% of replications (revived
  AC-SIM-4).

## Hard constraints

- Backward compatible: existing callers (no reference_config arg)
  must behave identically.
- All parameters explicit: reference_config added to the docs and
  signature.
- Errors and warnings via cli_abort()/cli_warn() with class= from
  plans/error-messages.md.
- Do not modify R/sgp.R or R/replacement.R.

## Workflow

Full Code + Simulation workflow. Builder || Simulator → Tester →
Scriber → Reviewer → Shipper.

## Branch

- Feature branch: feature/par-reference-config-band-check
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

## Closed requests

None yet.

---

## Housekeeping notes from run `par-2026-04-18`

- **Cross-surface write by simulator.** The simulator (agent `a028129f`)
  made three minimal bug fixes to `R/par.R` directly because builder's
  original implementation was unrunnable. These fixes (PLAYER_ID case,
  vapply→lapply, na.rm=TRUE on total_par rowSums) were merged without a
  builder respawn because they were correct, minimal, and necessary.
  Future: consider tightening statsclaw protocol so simulators surface a
  BLOCK to leader rather than patching builder files, or formalize
  "simulator found a builder bug" as a fast-path respawn trigger.

- **Planner respawned twice.** Once for AC-SIM-2/AC-SIM-4 spec amendments
  (legitimate design gap surfaced by simulator), once to redesign a test
  fixture that collided with builder's new Step 1b check (AC-9 fix).
  Both respawns were cheap; no protocol issue.

- **Pre-existing `HANDOFF.md`** in repo root was noted by reviewer as
  project hygiene — not introduced by this run. Separate cleanup item
  outside this plan's scope.
