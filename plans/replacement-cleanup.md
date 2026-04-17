# Plan: Addressing Remaining `replacement_level()` Follow-ups

> Created: 2026-04-17
> Source: Follow-up tickets from run `replacement-2026-04-16` (reviewer verdict
> PASS_WITH_FOLLOWUP, merge commit `18b2c82`)
> Related: `plans/error-messages.md`, `specs/spec-replacement.md`, `ARCHITECTURE.md`

---

## Sequencing principle

The six outstanding items differ by **type** (algorithm vs simulation vs docs)
and by **blast radius** (pure spec-drafting vs convergence-loop surgery).
Bundle by type, sequence by risk so cheap design/audit work lands first and
the one "real algorithm surgery" item only starts once the cheap ones are in.

- **Wave 1** — small, independent, parallel (audit + three sub-specs).
  All are docs / LOW risk; they close open design questions and unblock
  future implementation runs.
- **Wave 2** — medium, single-pipeline (DGP-E calibration).
- **Wave 3** — larger, Code + Simulation (higher-order cycle detection).
  Sequenced last to avoid simultaneous harness edits with R5.

---

## Request bundling

Each request = one statsclaw run with its own request ID, its own feature
branch (`feature/<slug>`), and its own PR into `develop`. The slug gets baked
into the run directory under
`~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/<slug>-YYYY-MM-DD/`.

### Wave 1 — parallel, independent (all LOW)

| Request ID | Slug | Variant | Addresses | Agents involved |
|---|---|---|---|---|
| R1 | `replacement-name-match-audit` | Code-only (small) | Verify `rotostats_warning_name_match_failure` emit site in `R/` | Planner → Builder → Tester → Scriber → Reviewer → Shipper |
| R2 | `replacement-historical-priors-spec` | Docs-only | Draft spec for `seed_method = "historical_priors"` | Scriber → Reviewer → Shipper |
| R3 | `replacement-sgp-pool-rate-spec` | Docs-only | Draft spec for `boundary_rate_method = "sgp_pool"` | Scriber → Reviewer → Shipper |
| R4 | `replacement-multi-pos-all-spec` | Docs-only | Draft spec for `multi_pos = "all"` 3D output | Scriber → Reviewer → Shipper |

### Wave 2 — sequential after Wave 1 (MEDIUM)

| Request ID | Slug | Variant | Addresses | Agents involved |
|---|---|---|---|---|
| R5 | `replacement-dgp-e-calibration` | Simulation-only | DGP-E focal-pitcher tightening to meet Study E thresholds | Planner (sim-spec patch) → Simulator → Tester → Reviewer → Shipper |

### Wave 3 — sequential after Wave 2 (HIGH)

| Request ID | Slug | Variant | Addresses | Agents involved |
|---|---|---|---|---|
| R6 | `replacement-higher-order-cycle` | Code + Simulation | State-hash cycle detection in `highest_par` loop (push Study C ≥ 99%) | Planner → Builder ∥ Simulator → Tester → Scriber → Reviewer → Shipper |

---

## Dependency graph

```
R1 ──┐
R2 ──┤
R3 ──┼── (all independent; run in parallel as Wave 1)
R4 ──┘
       │
       v
R5  ── (simulator re-runs DGP-E only; safe to sequence after Wave 1
        so Planner sees the final design specs as context)
       │
       v
R6  ── (algorithm change; wants a known-good DGP-E baseline to isolate
        Study C convergence changes from Study E drift)
```

**No item has a hard blocker.** If the user wants to start R6 before Wave 1 / 2,
it runs fine — the dependency graph above is a sequencing preference, not a
correctness requirement.

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

---

## Request specs and dispatch prompts

### R1 — `replacement-name-match-audit`

**Objective.** Confirm `rotostats_warning_name_match_failure` is actually
emitted somewhere in `R/`. Reviewer grep didn't find it, but `TS-49` passes,
so one of the two is wrong.

**Scope.**

1. Grep `R/` for the exact string `rotostats_warning_name_match_failure`.
2. If absent, locate the `league_history` name-matching path in
   `R/replacement.R` (near Unicode NFD normalization) and add the
   `cli_warn()` call with the registered class.
3. If present, confirm the `class =` argument matches the registry row in
   `plans/error-messages.md` exactly.
4. If TS-49 was passing by accident (wrong class name), update the test to
   assert the correct class and document the correction.

**Test-spec additions.**

- TS-49 still passes post-audit.
- If source was patched, the warning fires on the documented trigger
  condition and not otherwise.

**Simulation?** No — diagnostic-emission change.

**Acceptance.** All existing tests pass. If a code change landed, the class
appears in both source and registry with identical spelling. `R CMD check`
clean.

**Effort.** ~15–20 min.

#### Dispatch prompt (paste to Leader)

```
Request ID: replacement-name-match-audit-2026-04-17

Audit whether rotostats_warning_name_match_failure is actually emitted
anywhere in R/. Reviewer noted it is registered in plans/error-messages.md
and TS-49 passes, but grep did not find the emit site — one of them must
be wrong.

Read specs/spec-replacement.md §"replacement_from_prices()" and
plans/error-messages.md before planning. Read plans/replacement-cleanup.md
§"R1 — replacement-name-match-audit" for the authoritative scope.

## Changes required (conditional on audit findings)

1. Grep R/ for the exact string "rotostats_warning_name_match_failure".
2a. If ABSENT: find the league_history name-matching path in R/replacement.R
    (near Unicode NFD normalization) and add a cli_warn() call with the
    registered class. Do not change the trigger condition — only emit the
    warning where the existing logic decides a name failed to match.
2b. If PRESENT: confirm the class = argument string matches the registry
    row character-for-character.
3. If TS-49 was passing because it asserts the wrong class name, update
   it to assert the correct class. Document the correction in the test
   comments.

## Acceptance criteria

- A grep of R/ for "rotostats_warning_name_match_failure" returns at
  least one hit at an actual emission site (not a comment).
- TS-49 exercises the emission path and asserts the registered class
  spelling.
- devtools::test() — FAIL=0; no new SKIPs.
- R CMD check: 0 ERRORs, 0 WARNINGs, NOTEs unchanged from develop.

## Hard constraints

- Warning via cli_warn() with class = from plans/error-messages.md — never
  bare warning().
- No refactors unrelated to this class.
- Dispatch all writing teammates (Builder, Tester, Scriber) with
  isolation: "worktree" per the statsclaw protocol.

## Workflow

Code-only. Planner → Builder → Tester → Scriber → Reviewer → Shipper.

## Branch

- Feature branch: feature/replacement-name-match-audit
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### R2 — `replacement-historical-priors-spec`

**Objective.** Draft `specs/spec-replacement-historical-priors.md` — the
design document that a future implementation run will consume. NO code.

**Scope.**

1. Reference `specs/spec-replacement.md` as the authoritative parent for
   overall `replacement_level()` semantics.
2. Cover:
   - Inputs required from `league_history` (which slots; minimum history length).
   - Interaction with `trim_method` (does the historical prior combine with
     the trimmed $1 pool, or replace it?).
   - Calibration cross-check behavior (when does the historical prior
     override projection-derived replacement? When does it confirm?).
   - Failure modes: insufficient history, league expansion/contraction,
     stat-definition drift.
   - New error/warning classes required (at minimum, one for insufficient
     history; register in `plans/error-messages.md`).
3. Output: the spec file only. A future run consumes via
   `/run-statsclaw @specs/spec-replacement-historical-priors.md`.

**Test-spec additions.** N/A (design doc).

**Simulation?** No — design phase.

**Acceptance.** Spec is complete enough that a fresh Planner agent can derive
`spec.md` + `test-spec.md` + `sim-spec.md` from it without asking the user
questions.

**Effort.** ~30–45 min.

#### Dispatch prompt (paste to Leader)

```
Request ID: replacement-historical-priors-spec-2026-04-17

Draft specs/spec-replacement-historical-priors.md — the design doc that a
future implementation run will consume for the seed_method =
"historical_priors" feature of replacement_level().

Read specs/spec-replacement.md in full as the authoritative parent spec.
Read plans/replacement-cleanup.md §"R2 — replacement-historical-priors-spec"
for the authoritative scope.

## What to produce

specs/spec-replacement-historical-priors.md covering:

1. Inputs required from league_history — which slots on team_season / prices
   are load-bearing; what is the minimum useful history length.
2. Interaction with trim_method — does the historical prior combine with
   the trimmed $1 pool (weighted average), or replace it entirely when
   history is available?
3. Calibration cross-check behavior — when does the historical prior
   override projection-derived replacement? When does it merely confirm?
4. Failure modes and their error/warning classes:
   - insufficient history (e.g., < 3 seasons available)
   - league expansion/contraction detected in team_season
   - stat-definition drift (e.g., AVG present historically but OBP
     requested currently)
5. New error/warning classes — register each in plans/error-messages.md
   following the existing row format.

## Acceptance criteria

- Spec is self-contained: a fresh Planner agent can derive spec.md,
  test-spec.md, and sim-spec.md from it without needing user clarification.
- At least one error class registered in plans/error-messages.md
  (insufficient-history is the likely candidate).
- No modifications to R/, man/, NAMESPACE, or existing tests.
- Spec identifies explicit follow-up work items that belong in the future
  implementation run (not in this docs run).

## Hard constraints

- Docs-only. No R code. No tests. No simulation-harness edits.
- If the scope genuinely needs a design decision the user must make (e.g.,
  combine-vs-replace for trim_method interaction), STOP and surface the
  question to the user via mailbox — do NOT pick silently.
- Dispatch Scriber with isolation: "worktree" per the statsclaw protocol.

## Workflow

Docs-only. Scriber → Reviewer → Shipper. Skip Planner, Builder, Tester,
Simulator (Scriber is authoring the spec, not consuming one).

## Branch

- Feature branch: feature/replacement-historical-priors-spec
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### R3 — `replacement-sgp-pool-rate-spec`

**Objective.** Draft `specs/spec-replacement-sgp-pool-rate-method.md` —
design doc for the `boundary_rate_method = "sgp_pool"` full implementation.

**Scope.**

1. Reference `specs/spec-replacement.md` as parent.
2. Cover:
   - Interaction with `attr(sgp_denominators, "rate_conversion")`. The
     `"fixed_baseline"` incompatibility is already handled with a
     registered error class; document how `"blended_pool"` converts.
   - How the pool-weighted rate is computed at the boundary: which players
     enter the pool, how the weights combine, how this differs from
     `"raw_ip"`.
   - Interaction with AB-weighted AVG and IP-weighted ERA/WHIP — does
     `sgp_pool` replace these or layer on top?
3. Output: the spec file only.

**Test-spec additions.** N/A.

**Simulation?** No.

**Acceptance.** Ready for a future statsclaw run.

**Effort.** ~30–45 min.

#### Dispatch prompt (paste to Leader)

```
Request ID: replacement-sgp-pool-rate-spec-2026-04-17

Draft specs/spec-replacement-sgp-pool-rate-method.md — design doc for the
boundary_rate_method = "sgp_pool" full implementation in replacement_level().

Read specs/spec-replacement.md as parent. Read plans/replacement-cleanup.md
§"R3 — replacement-sgp-pool-rate-spec" for the authoritative scope.

## What to produce

specs/spec-replacement-sgp-pool-rate-method.md covering:

1. Interaction with attr(sgp_denominators, "rate_conversion"):
   - "fixed_baseline" is already incompatible (error class
     rotostats_error_rate_method_mismatch is registered). Document this.
   - "blended_pool" is the supported path. Define the conversion formula.
2. Pool composition at the boundary:
   - Which players enter the SGP pool (band members only, all rostered,
     or some other cut)?
   - Weighting function — uniform, IP-weighted, SGP-contribution-weighted?
3. Relationship to the existing AB-weighted AVG and IP-weighted ERA/WHIP
   used in "raw_ip" mode. Does sgp_pool replace these, layer on top, or
   override only for certain categories?
4. New error/warning classes required (if any); register in
   plans/error-messages.md.

## Acceptance criteria

- Spec is self-contained: Planner can derive spec.md / test-spec.md /
  sim-spec.md from it cold.
- The "fixed_baseline" guard is explicitly preserved (no silent relaxing).
- No modifications to R/, man/, NAMESPACE, or existing tests.
- Any new error/warning classes registered in plans/error-messages.md.

## Hard constraints

- Docs-only. No R code, no tests, no sim-harness edits.
- If a design decision requires user input, STOP and surface via mailbox.
- Dispatch Scriber with isolation: "worktree" per the statsclaw protocol.

## Workflow

Docs-only. Scriber → Reviewer → Shipper.

## Branch

- Feature branch: feature/replacement-sgp-pool-rate-spec
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

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

### R5 — `replacement-dgp-e-calibration`

**Objective.** Tighten `inst/simulations/dgp/dgp_e.R` focal pitcher so
Study E's 500-rep harness meets `median_abs_rank_diff ≤ 2` AND
`pct_within_2 ≥ 0.90`. NO change to `R/replacement.R` — simulation pipeline
only.

**Scope.**

1. **Planner.** Patch the `sim-spec.md` DGP-E definition. Current focal
   (from commit `21270fb`) is boundary-quality (ERA=4.70, WHIP=1.40,
   IP=165, W=8, K=130) — improved rank_diff from 19 → 3, but still gates.
   Residual gap is pool-composition variance. Planner picks new focal-pitcher
   parameters (e.g., further below pool mean, or reduce pool stat-level
   noise) to minimize pool-composition sensitivity while remaining "fixed
   quality".
2. **Simulator.** Re-run Study E only under the corrected DGP-E. Reuse
   Study A / B / C / D results verbatim from `runs/replacement-2026-04-16/`.
3. **Tester.** Verify the corrected DGP produces a stable rank shift at
   boundary; then verify Study E acceptance criteria pass.
4. **Reviewer.** Publish a merge report that keeps Study A / B / C / D
   verdicts from `runs/replacement-2026-04-16/` and supersedes only Study E.

**Possible outcomes.**

- If tightening succeeds: Study E passes cleanly; waiver item resolved.
- If Study E still fails under any reasonable DGP: reviewer flags as a
  candidate for threshold revision (e.g., `median ≤ 5` /
  `pct_within_2 ≥ 0.80`) via a follow-up request. Do NOT relax silently.

**Effort.** ~2 min compute + ~20 min planner/reviewer.

#### Dispatch prompt (paste to Leader)

```
Request ID: replacement-dgp-e-calibration-2026-04-17

Re-run Study E of the replacement_level() Monte Carlo validation with a
corrected DGP-E. NO change to R/replacement.R — simulation pipeline only.

Read plans/replacement-cleanup.md §"R5 — replacement-dgp-e-calibration"
for the authoritative scope.

Prior run to build on:
~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/replacement-2026-04-16/
  - simulation.md §"Study E" (median_abs_rank_diff=3, pct_within_2=0.46)
  - review.md §"Waiver Assessment" (Study E analysis)
  - audit.md §"Post-Fix Re-Audit v2" (DGP-E history)

## What needs to change

Planner:
- Patch inst/simulations/dgp/dgp_e.R and the sim-spec.md DGP-E section.
  Current focal (commit 21270fb): ERA=4.70, WHIP=1.40, IP=165, W=8, K=130
  (boundary quality, pool mean ERA ≈ 4.40). Produces rank_diff=3,
  pct_within_2=0.46 under R=500.
- Tighten the DGP so 500-rep Study E meets median_abs_rank_diff ≤ 2 AND
  pct_within_2 ≥ 0.90. Options the planner chooses from:
  1. Further below pool mean (reduce focal-to-pool gap in rate stats).
  2. Reduce pool stat-level noise (lower σ in DGP-E player generation).
  3. Use a fixed pool (no between-rep variance in non-focal players).
- Document the fix in the sim-spec changelog.

Simulator:
- Re-run Study E only under the corrected DGP-E with the same master seed
  strategy (20260416 + study_offset + rep).
- Studies A/B/C/D are NOT re-run. They do not depend on DGP-E.
- Produce a new simulation.md that references the prior run's A/B/C/D
  verdicts by path and reports fresh Study E tables.

Tester:
- Verify the corrected DGP-E produces a deterministic rank shift at the
  boundary before evaluating acceptance (compute expected rank_diff under
  the theoretical boundary — should be tight around the target).
- Then evaluate Study E acceptance criteria: median_abs_rank_diff ≤ 2 AND
  pct_within_2 ≥ 0.90.
- If Study E still fails, flag as a threshold-revision candidate for a
  follow-up request (do NOT silently relax thresholds here).

Reviewer:
- Merge report: keep Study A/B/C/D verdicts from replacement-2026-04-16
  unchanged. Replace only Study E. Produce a unified successor review.md.

## Acceptance criteria

- Corrected DGP-E produces Study E: median_abs_rank_diff ≤ 2 AND
  pct_within_2 ≥ 0.90 on R=500 reps.
- All other Monte Carlo criteria from replacement-2026-04-16 (13/16 already
  passing) still pass.
- Test suite unchanged: FAIL=0.
- R CMD check: 0 ERRORs, 0 WARNINGs, NOTEs unchanged.

## Hard constraints

- No changes to R/ source code. This is a simulation-pipeline-only run.
- No changes to specs/spec-replacement.md or function public interfaces.
- Seed strategy must match replacement-2026-04-16 so unchanged tables
  remain reproducible.
- Dispatch Planner, Simulator, Tester with isolation: "worktree" per the
  statsclaw protocol.

## Workflow

Simulation-only. Planner (sim-spec patch) → Simulator → Tester → Reviewer
→ Shipper. No Builder, no Scriber (unless thresholds change — defer that
to a follow-up).

## Branch

- Feature branch: feature/replacement-dgp-e-calibration
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
   `median_iterations ≤ 5`; Studies A / B / D / E no regression.

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
  - Studies A/B/D/E: no regression from replacement-2026-04-16 v2 values
    (within ±0.01 of their published metrics).
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
- `NEWS.md` entry for user-visible changes (R1 if source changed; R6).
- Reviewer verdict: PASS or PASS_WITH_FOLLOWUP.
- No new follow-up items left un-triaged in `review.md`.

---

## What this plan intentionally leaves out

- **`dollar_values()` implementation.** Depends on `par()` / `zar()` /
  `pvm()` landing first. Track separately in `plans/valuation.md`.
- **`replacement_from_prices()` full feature build-out** beyond the
  name-match audit in R1. The current implementation is functional; future
  work (e.g., price-trend weighting) gets its own spec.
- **Study C / E threshold revision.** Handled inside R5 / R6 if the
  metrics-at-tighter-thresholds path fails. Not a pre-emptive item.
- **`league_history()` constructor enhancements** — Phase-1 scaffolding
  work; track separately.
