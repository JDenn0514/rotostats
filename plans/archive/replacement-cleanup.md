# Plan: Addressing Remaining `replacement_level()` Follow-ups

> Created: 2026-04-17
> Last updated: 2026-04-20 (R4 marked shipped via PR #17)
> Source: Follow-up tickets from run `replacement-2026-04-16` (reviewer verdict
> PASS_WITH_FOLLOWUP, merge commit `18b2c82`)
> Related: `plans/error-messages.md`, `specs/spec-replacement.md`, `ARCHITECTURE.md`

---

## Status summary

| Ticket | Slug | Type | Status |
|---|---|---|---|
| R1 | `replacement-name-match-audit` | Code (small) | ✅ Shipped — PR #6 |
| R2 | `replacement-historical-priors-spec` | Docs-only | ✅ Shipped — PR #11 |
| R3 | `replacement-sgp-pool-rate-spec` | Docs-only | ✅ Shipped — PR #12 |
| R4 | `replacement-multi-pos-all-spec` | Docs-only | ✅ Shipped — PR #17 |
| R5 | `replacement-dgp-e-calibration` | Simulation-only | ✅ Shipped — PR #16 |
| R6 | `replacement-higher-order-cycle` | Code + Simulation | ✅ Shipped — PR #20 |

Each remaining request = one statsclaw run with its own request ID, its own
feature branch (`feature/<slug>`), and its own PR into `develop`. The slug
gets baked into the run directory under
`~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/<slug>-YYYY-MM-DD/`.

R6 is the only remaining item — the one "real algorithm surgery" ticket in
the follow-up set.

---

## Pre-flight for every request

Before dispatching any request:

```bash
git -C /Users/jacobdennen/rotostats checkout develop
git -C /Users/jacobdennen/rotostats pull --ff-only origin develop
```

Do NOT pre-create the feature branch locally — each statsclaw run cuts its
own feature branch and specialist teammates work inside git worktrees. The
top-level session adopts the Leader role (see
`~/.claude/skills/run-statsclaw/SKILL.md` §Step 4) and dispatches specialist
teammates with `isolation: "worktree"`.

All prompts below MUST be pasted into a **fresh** Claude Code session (so
Leader starts with clean context).

**Branch-name hygiene.** Before dispatching, confirm the target feature
branch name is NOT already present locally (`git branch --list
feature/<slug>`). If a stale branch with the same name exists from a prior
orphaned worktree, the new run's worktree may reuse it on a wrong ancestor
— the R5 run hit this and required a mid-workflow branch repair.

---

## Open requests

### R4 — `replacement-multi-pos-all-spec`

**Objective.** Draft `specs/spec-replacement-multi-pos-all.md` — design doc
for `multi_pos = "all"` mode (player × eligible position × metric 3D output).

**Scope.**

1. Reference `specs/spec-replacement.md` as parent.
2. Cover:
   - Output shape: 3D array vs long-form tidy frame. Pick one; justify.
   - Attribute changes: `position_assignments` becomes N/A or list-valued
     for multi-eligible players.
   - Zero-sum invariant under fractional / multi-counted players. The
     current scalar assertion `abs(sum(slots × premium)) < 1e-6` needs a
     generalization; define it.
   - Downstream implications for `par()`, `zar()`, `dollar_values()`.
3. Output: the spec file only.

**Test-spec additions.** N/A.

**Simulation?** No.

**Acceptance.** Ready for a future statsclaw run.

**Effort.** ~30–45 min.

#### Dispatch prompt (paste to Leader)

```
Request ID: replacement-multi-pos-all-spec-2026-04-17

Draft specs/spec-replacement-multi-pos-all.md — design doc for the
multi_pos = "all" mode of replacement_level(), which produces a 3D
(player × eligible position × metric) output rather than the single
best-assignment result.

Read specs/spec-replacement.md as parent. Read plans/replacement-cleanup.md
§"R4 — replacement-multi-pos-all-spec" for the authoritative scope.

## What to produce

specs/spec-replacement-multi-pos-all.md covering:

1. Output shape:
   - 3D array (player_id × position × metric) vs long-form tidy frame
     (player_id, position, metric, value). Pick one; justify; document
     trade-offs.
   - Attribute changes: position_assignments becomes N/A or list-valued
     for multi-eligible players.
2. Zero-sum invariant generalization:
   - Current scalar: abs(sum(slots × premium)) < 1e-6.
   - Under "all", each multi-eligible player contributes fractional counts
     per position. Define the generalized invariant and tolerance.
3. Downstream function contracts:
   - par() — which assignment does PAR use when multi_pos = "all"?
   - zar() — same question.
   - dollar_values() — does it aggregate across positions, pick max, or
     return a vector?
4. New error/warning classes (if any); register in plans/error-messages.md.

## Acceptance criteria

- Spec is self-contained for a future Planner agent.
- Output shape decision is justified and consistent with existing
  rotostats return-contract conventions (named list with documented
  elements).
- Generalized zero-sum invariant is stated explicitly with its tolerance.
- No modifications to R/, man/, NAMESPACE, or existing tests.

## Hard constraints

- Docs-only.
- If output-shape or downstream-contract decisions require user input,
  STOP and surface via mailbox.
- Dispatch Scriber with isolation: "worktree" per the statsclaw protocol.

## Workflow

Docs-only. Scriber → Reviewer → Shipper.

## Branch

- Feature branch: feature/replacement-multi-pos-all-spec
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### R6 — `replacement-higher-order-cycle`

**Objective.** Replace the 2-lag (`old_old_assignments`) cycle detector in
`R/replacement.R`'s `highest_par` convergence loop with a state-hash
detector that catches higher-order cycles (3+-cycles). Push Study C
`convergence_rate` from 0.966 → ≥ 0.99.

**Scope.**

1. **Spec update** (`specs/spec-replacement.md` §"Multi-position convergence
   loop"): document the new cycle-detection algorithm.
2. **Builder** (`R/replacement.R`): replace the 2-lag check with a state
   history: hash each position-assignment vector (base-R `paste(names(a), a,
   collapse = "|")` or similar — prefer no new dependencies) and check the
   new assignment against a rolling window (default `N = 5`). On match,
   accept as converged. Keep `max_iter` as a hard upper bound.
3. **Builder** (`R/replacement_params.R`): add
   `cycle_history_window = 5L` to `default_replacement_params` with
   `@param` docs.
4. **Simulator** (`inst/simulations/dgp/dgp_c.R`): if DGP-C does not
   reliably generate 3-cycles, tighten it (cluster three near-boundary
   multi-eligible players so greedy reassignment rotates among them).
5. **Tester** (`tests/testthat/test-replacement.R`):
   - 2-cycle regression test (guards against regression of `21270fb`).
   - 3-cycle detection test (new).
   - Pathological-pool test (would cycle forever with no `max_iter`) —
     terminates cleanly with `converged = FALSE`.
6. **Re-run MC harness.** Study C must meet `convergence_rate ≥ 0.99` AND
   `median_iterations ≤ 5`; Studies A / B / D / E no regression from
   post-R5 baseline.

**Test-spec additions.** Three new tests as above.

**Simulation?** Yes — the whole point is to move Study C `convergence_rate`.

**Acceptance.** All existing tests pass; 3 new tests pass; Study C passes
cleanly (≥ 0.99 rate); no regression in Studies A / B / D / E; no
performance regression in 12-team typical pools.

**Effort.** ~60–90 min build + ~10 min harness re-run + tester.

#### Dispatch prompt (paste to Leader)

```
Request ID: replacement-higher-order-cycle-2026-04-17

Implement state-hash cycle detection in replacement_level()'s highest_par
convergence loop. Replaces the 2-lag (old_old_assignments) detector added
in commit 21270fb. Goal: push Study C convergence_rate from 0.966 to
≥ 0.99 by catching 3+-cycles.

Read specs/spec-replacement.md §"Multi-position convergence loop" and
plans/error-messages.md before planning. Read plans/replacement-cleanup.md
§"R6 — replacement-higher-order-cycle" for the authoritative scope.

Prior run context:
~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/replacement-2026-04-16/
  - audit.md §"Post-Fix Re-Audit v2" — Study C 96.6% convergence analysis
  - simulation.md §"Study C" — current metrics
  - review.md §"Follow-Up Tickets" item 1 — recommended approach

Post-R5 baseline for Studies A/B/D/E (no regression allowed):
~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/replacement-dgp-e-calibration-2026-04-17/
  - simulation.md §3 — Study E post-calibration (median_abs_rank_diff=2.0,
    pct_within_2=1.0). Study A/B/D metrics unchanged from replacement-2026-04-16.

## Changes required

1. Spec update:
   - specs/spec-replacement.md §"Multi-position convergence loop": document
     the state-hash detector with rolling history window N (default 5).
   - Document convergence criterion: declare converged if new assignment
     equals any of the last N assignments.

2. Builder (R/replacement.R):
   - Replace old_old_assignments 2-lag check with a state-history ring
     buffer of the last N assignment vectors.
   - Hash each assignment (base R: paste(names(a), a, collapse="|") is
     sufficient — avoid a hard dependency on digest if possible).
   - On convergence_history match, break with converged=TRUE and record
     which iteration the cycle started at.
   - Keep max_iter as a hard upper bound; if no history match, fall
     through to the existing max_iter warning.

3. Builder (R/replacement_params.R):
   - Add cycle_history_window = 5L to default_replacement_params.
   - Document via @param.

4. Simulator (inst/simulations/dgp/dgp_c.R):
   - If DGP-C does not reliably generate 3-cycles, tighten it (e.g.,
     cluster three near-boundary multi-eligible players so greedy
     reassignment rotates among them).
   - Purpose is to exercise the 3-cycle detector; not to gauge real-world
     frequency.

5. Tester (tests/testthat/test-replacement.R):
   - 2-cycle regression fixture still detected (guards commit 21270fb).
   - 3-cycle fixture detected with converged=TRUE under
     cycle_history_window = 5.
   - Pathological pool (would cycle forever without max_iter) terminates
     cleanly with converged=FALSE and the convergence warning.

## Acceptance criteria

- All existing tests pass (FAIL=0).
- Three new cycle tests pass.
- Monte Carlo harness re-run (R=500):
  - Study C: convergence_rate ≥ 0.99; median_iterations ≤ 5;
    n_max_iter_hits ≤ 5.
  - Studies A/B/D/E: no regression from post-R5 baseline (within ±0.01 of
    their published metrics; Study E must still hit median_abs_rank_diff ≤ 2
    AND pct_within_2 ≥ 0.90).
- R CMD check: 0 ERRORs, 0 WARNINGs, NOTEs unchanged.
- No new hard dependency (prefer base R hashing; add digest only if
  demonstrably needed and approved by reviewer).

## Hard constraints

- Errors/warnings via cli_abort()/cli_warn() with class= from
  plans/error-messages.md.
- Do NOT remove the max_iter hard upper bound — it's the safety net.
- Do NOT change boundary-band, zero-sum, or SP/RP logic.
- cycle_history_window must default to 5; user can override.
- No row-wise loops.
- Dispatch all writing teammates (Builder, Simulator, Tester, Scriber)
  with isolation: "worktree" per the statsclaw protocol.

## Workflow

Code + Simulation. Planner → (Builder ∥ Simulator) → Tester → Scriber →
Reviewer → Shipper. replacement_level() is a statistical estimator — Monte
Carlo validation is part of the acceptance bar.

## Branch

- Feature branch: feature/replacement-higher-order-cycle
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

## Definition of done (for each request)

- Feature branch merged to `develop` with clean `R CMD check` (0 ERRORs,
  0 WARNINGs, only pre-existing NOTEs).
- Run artifacts in
  `~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/<slug>-YYYY-MM-DD/`.
- `NEWS.md` entry for user-visible changes (R6 qualifies).
- Reviewer verdict: PASS or PASS_WITH_FOLLOWUP.
- No new follow-up items left un-triaged in `review.md`.

---

## Completed follow-ups (audit trail)

### R1 — `replacement-name-match-audit` (PR #6, 2026-04-17)

Added `rotostats_warning_name_match_failure` emit sites at the two
league_history name-matching paths in `R/replacement.R`; registered the
class and asserted it via TS-49. ASCII-normalized the cli_warn message
strings. Merge: PR #6.

Key commits: `80afe5c`, `d9b9fe8`, `272cb97`, `1d113f5`.

### R2 — `replacement-historical-priors-spec` (PR #11, 2026-04-17)

Published `specs/spec-replacement-historical-priors.md` — design doc for
`seed_method = "historical_priors"`. Reviewer nits addressed in
`0e2f1fd`. Merge: PR #11.

### R3 — `replacement-sgp-pool-rate-spec` (PR #12, 2026-04-17)

Published `specs/spec-replacement-sgp-pool-rate-method.md` — design doc
for `boundary_rate_method = "sgp_pool"` with explicit preservation of the
`"fixed_baseline"` incompatibility. Merge: PR #12.

### R5 — `replacement-dgp-e-calibration` (PR #16, 2026-04-18)

Fixed the Study E pct_within_2 waiver by introducing a module-level
`FIXED_POOL_SEED = 25260416L` in `inst/simulations/dgp/dgp_e.R` that
pre-generates a 95-pitcher complement SP pool once at source time. Both
the 10-team (first 62) and 15-team (first 92) calls subset the same fixed
pool, eliminating between-replication variance.

Post-patch Study E (R=500): `median_abs_rank_diff = 2.0` (≤ 2 ✓),
`pct_within_2 = 1.0` (≥ 0.90 ✓). Reviewer verdict PASS_WITH_NOTE — noted
that rank_diff=2 sits exactly at the acceptance boundary by the
fixed-pool design (constant across all reps). Low-priority follow-up:
sensitivity check on `FIXED_POOL_SEED` robustness.

One sidebar during the run: the feature branch name already existed on a
stale ancestor from an orphaned worktree; was repaired mid-workflow with
user approval onto a clean develop base. Documented in the run's
`shipper-repair.md`.

Key commit: `0154ca0`. Merge: PR #16 (merge commit `f046062`).

---

## What this plan intentionally leaves out

- **`dollar_values()` implementation.** Depends on `par()` / `zar()` /
  `pvm()` landing first. Track separately in `plans/valuation.md`.
- **`replacement_from_prices()` full feature build-out** beyond the
  name-match audit in R1. The current implementation is functional; future
  work (e.g., price-trend weighting) gets its own spec.
- **Study C threshold revision.** Handled inside R6 if the
  metrics-at-tighter-thresholds path fails. Not a pre-emptive item.
- **`FIXED_POOL_SEED` sensitivity study** (per R5 reviewer note) — low
  priority; file as a separate request if the boundary-calibration
  behavior becomes load-bearing.
- **`league_history()` constructor enhancements** — Phase-1 scaffolding
  work; track separately.
