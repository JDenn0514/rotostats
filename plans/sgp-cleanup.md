# Plan: Addressing Remaining `sgp()` and `sgp_denominators()` Issues

> Created: 2026-04-17
> Source: Follow-up items from runs `sgp-2026-04-16` and `sgp-denominators-2026-04-16`
> Related: `plans/sgp-validation.md`, `plans/sgp-denominators-architecture.md`

---

## Sequencing principle

The nine outstanding items differ by **type** (code vs simulation vs docs) and by
**blast radius** (input validation vs new feature). Bundle by type, sequence by
risk so small cheap wins land first and the two "real feature" items only start
once the cheap ones are in.

- **Wave 1** — small, independent, parallel. Lands before touching the next
  replacement run.
- **Wave 2** — medium, one pipeline each, sequential.
- **Wave 3** — deferred; start only when there's explicit demand.

---

## Request bundling

Each request = one statsclaw run with its own request ID, its own feature branch
(`feature/<slug>`), and its own PR into `develop`. The slug gets baked into the
run directory under
`~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/<slug>-YYYY-MM-DD/`.

### Wave 1 — parallel, independent

| Request ID | Slug | Variant | Addresses | Agents involved |
|---|---|---|---|---|
| R1 | `sgp-input-hardening` | Code | `pool_baseline` unguarded · warning class split | Planner → Builder → Tester → Scriber → Reviewer → Shipper |
| R2 | `sgp-denom-dgpb-rerun` | Simulation-only | DGP-B mean-shift (Q4 + Q7 only) | Planner (DGP fix) → Simulator → Tester → Reviewer → Shipper |
| R3 | `sgp-docs-cleanup` | Docs-only | sim-spec "8 per team" typo · `denom_floor` note | Scriber → Reviewer → Shipper |

### Wave 2 — sequential after Wave 1

| Request ID | Slug | Variant | Addresses | Agents involved |
|---|---|---|---|---|
| R4 | `sgp-denom-inverse-categories-param` | Code | `INVERSE_CATEGORIES` as user parameter | Planner → Builder → Tester → Scriber → Reviewer → Shipper |

### Wave 3 — deferred (start only on demand)

| Request ID | Slug | Variant | Addresses | Agents involved |
|---|---|---|---|---|
| R5 | `sgp-fixed-baseline-impl` | Simulation + Code | `convert_rate_stats()` for `"fixed_baseline"` | Planner → Builder ∥ Simulator → Tester → Scriber → Distiller → Reviewer → Shipper |
| R6 | `sgp-denom-bca-bootstrap` | Simulation + Code | BCa bootstrap (replaces or extends percentile CI) | Planner → Builder ∥ Simulator → Tester → Scriber → Distiller → Reviewer → Shipper |

---

## Dependency graph

```
R1 ──┐
R2 ──┼── (all independent; run in parallel)
R3 ──┘
       │
       v
R4 ── (no hard dependency on Wave 1, but easier to sequence after to avoid
       simultaneous edits to sgp_denominators helpers)
       │
       v
R5, R6 ── deferred; independent of each other when they eventually run
```

**No item depends on the replacement run landing first.** R1–R4 can proceed
regardless of what replacement is doing on the parallel branch.

---

## Pre-flight for every request

Before dispatching any request:

```bash
git -C /Users/jacobdennen/rotostats checkout develop
git -C /Users/jacobdennen/rotostats pull --ff-only origin develop
git -C /Users/jacobdennen/rotostats checkout -b feature/<slug>
```

These are patch-style requests, not new-function builds from a blank spec. The
standard `/run-statsclaw <spec-file>` skill expects a spec file as its first
argument. For these runs, dispatch the Leader role directly from the top-level
session and paste the prompt below as the request TO Leader (see
`~/.claude/skills/run-statsclaw/SKILL.md` §Step 4 — the top-level thread adopts
the Leader role and then spawns specialist agents via `Agent`).

---

## Request specs and dispatch prompts

### R1 — `sgp-input-hardening`

**Objective.** Close two latent holes in `sgp()`'s public interface. Both are
input-validation improvements — no algorithmic change.

**Scope.**

1. **`pool_baseline` validation.** Add a top-of-function check: `pool_baseline`
   must be exactly `"projection_pool"`. Anything else aborts with
   `rotostats_error_invalid_pool_baseline` and a message naming the valid values.
2. **Warning class split.** Replace `rotostats_warning_missing_category_column`
   with two classes:
   - `rotostats_warning_missing_category_column` — category absent from
     `projections` entirely.
   - `rotostats_warning_zero_playing_time` — row has `IP = 0` or `AB = 0` on a
     scored rate category.

**Test-spec additions.**

- `sgp(..., pool_baseline = "foo")` throws `rotostats_error_invalid_pool_baseline`.
- The two warning classes fire on their respective conditions without bleeding
  into each other.

**Simulation?** No — neither change affects any statistical property.

**Acceptance.** All existing tests pass; three new tests pass; `R CMD check`
clean; PR targets `develop`.

**Effort.** ~15–20 min build + test.

#### Dispatch prompt (paste to Leader)

```
Request ID: sgp-input-hardening-2026-04-17

Harden input validation in sgp() — no algorithmic change.

Read specs/spec-sgp.md and plans/error-messages.md before planning.
Read plans/sgp-cleanup.md §"R1 — sgp-input-hardening" for the authoritative
scope and acceptance criteria.

## Changes required

1. Add pool_baseline input validation to sgp():
   - pool_baseline must equal "projection_pool". Anything else aborts.
   - New error class: rotostats_error_invalid_pool_baseline.
   - Add the class to plans/error-messages.md.

2. Split rotostats_warning_missing_category_column into two classes:
   - rotostats_warning_missing_category_column: category absent from projections.
   - rotostats_warning_zero_playing_time: row has IP=0 or AB=0 on a scored rate cat.
   - Update plans/error-messages.md. Update call sites in R/sgp.R.
   - Add a NEWS.md entry noting the (minor) breaking change for callers using
     withCallingHandlers on the old class.

## Acceptance criteria (must hold after this run)

- sgp(..., pool_baseline = "projection_pool") behaves as before. Any other value
  aborts with rotostats_error_invalid_pool_baseline naming the valid values.
- Calling sgp() on a projections frame missing a scored category fires
  rotostats_warning_missing_category_column AND NOT the zero-playing-time class.
- Calling sgp() on a projections frame with IP=0 on a scored rate category fires
  rotostats_warning_zero_playing_time AND NOT the missing-column class.
- R CMD check: 0 ERRORs, 0 WARNINGs, NOTEs unchanged from main.
- All existing sgp tests still pass.

## Hard constraints

- Errors and warnings via cli_abort()/cli_warn() with class= from
  plans/error-messages.md — never bare stop() or warning().
- No refactors of code unrelated to the two changes above.
- Keep vectorized operations; no row-wise loops.

## Workflow

Code-only (no simulation — the changes are input-validation, not statistical).
Planner → Builder → Tester → Scriber → Reviewer → Shipper.

## Branch

- Feature branch: feature/sgp-input-hardening
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### R2 — `sgp-denom-dgpb-rerun`

**Objective.** Resolve the two DGP-design-flagged failures from Q4 and Q7 by
re-running with a corrected DGP-B. Does **not** modify `sgp_denominators()`.

**Scope.**

1. **Planner.** Patch `sim-spec.md` DGP-B definition. Change from *mean shift
   at year 7* to *variance shift at year 7* — pre-break σ = 15, post-break σ =
   25 (planner picks exact parameters to produce a clear signal). Document the
   fix in the sim-spec changelog.
2. **Simulator.** Re-run Q4 and Q7 only. Reuse Q1, Q2, Q3, Q5, Q6 results from
   `runs/sgp-denominators-2026-04-16/` verbatim — they are not DGP-B-dependent.
3. **Tester.** Verify the new DGP produces a measurable change in the OLS
   estimand (asymptotic θ should shift pre/post); then verify Q4's "decay helps
   under break" criterion and Q7's "override improves SB" criterion either pass
   or fail with a clean diagnosis.
4. **Reviewer.** Publish a merge report that keeps Q1–Q3 and Q5–Q6 verdicts
   from the 2026-04-16 run and supersedes only Q4 and Q7.

**Possible outcomes.**

- If decay helps under proper DGP-B: default `weights = exp_decay(0.9)` is
  reconfirmed; no `spec.md` change.
- If decay still doesn't help: default should change to `"flat"`, or at minimum
  the recommendation in `?sgp_denominators` should be revised. That's a
  follow-on decision, not part of R2's scope.

**Effort.** Simulator re-run ~10 min compute + ~20 min planner/reviewer work.

#### Dispatch prompt (paste to Leader)

```
Request ID: sgp-denom-dgpb-rerun-2026-04-17

Re-run Q4 and Q7 of the sgp_denominators() Monte Carlo validation with a
corrected DGP-B. NO change to sgp_denominators() source — simulation pipeline
only.

Read plans/sgp-cleanup.md §"R2 — sgp-denom-dgpb-rerun" for the authoritative
scope.

Prior run to build on:
~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/sgp-denominators-2026-04-16/
  - simulation.md §4 (Q4 finding) and §7 (Q7 finding)
  - review.md §"Concerns flagged for Tester and Reviewer" item 2

## What needs to change

Planner:
- Patch sim-spec.md DGP-B definition. Current DGP-B shifts the MEAN of team
  totals at year 7; this does not change the OLS denominator's target, which
  depends on within-year SPREAD. Change DGP-B so within-year σ shifts at the
  break (e.g., pre-break σ = 15, post-break σ = 25). Planner picks exact
  parameters to produce a clear, statistically detectable signal at
  n_years = 10, R = 2000.
- Add a sim-spec changelog note explaining the DGP-B correction.

Simulator:
- Re-run Q4 and Q7 under the corrected DGP-B with the same master seed strategy
  (2026041601 + study offset + rep).
- Q1, Q2, Q3, Q5, Q6 are NOT re-run. They do not depend on DGP-B.
- Produce a new simulation.md that references the prior run's Q1/Q2/Q3/Q5/Q6
  verdicts by path and reports fresh Q4 and Q7 tables.

Tester:
- Before evaluating Q4/Q7 acceptance criteria, verify the corrected DGP-B
  actually moves the OLS estimand (compute θ_pre vs θ_post via empirical
  calibration — should differ by more than sampling noise). If it does not,
  stop and re-route to Planner.
- Then evaluate Q4 and Q7 acceptance criteria.

Reviewer:
- Merge report: keep Q1/Q2/Q3/Q5/Q6 verdicts from 2026-04-16 unchanged. Replace
  only Q4 and Q7 sections. Produce a unified successor to the 2026-04-16
  review.md.

## Acceptance criteria

- Corrected DGP-B produces a statistically detectable pre/post shift in the OLS
  asymptotic θ (documented in simulation.md).
- Q4 criterion "under DGP-B, exp_decay(0.7) MSE ≤ flat MSE" is evaluated
  against the corrected DGP; pass or fail is reported cleanly with diagnostic
  interpretation.
- Q7 criterion "SB override improves SB MSE" is evaluated cleanly under the
  corrected DGP.
- If the decay-helps-break criterion FAILS even under the corrected DGP, the
  reviewer flags this as a candidate spec.md change (default weights) and
  files a follow-up request (DO NOT modify spec.md in this run).

## Hard constraints

- No changes to R/ source code. This is a simulation-pipeline-only run.
- No changes to spec.md, test-spec.md, or the function's public interface.
- Seed strategy must match 2026-04-16 so any shared tables remain reproducible.

## Workflow

Simulation-only. Planner (sim-spec patch) → Simulator → Tester → Reviewer →
Shipper. No Builder, no Scriber (unless the decay-default recommendation
changes; then Scriber updates ?sgp_denominators @details separately).

## Branch

- Feature branch: feature/sgp-denom-dgpb-rerun
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### R3 — `sgp-docs-cleanup`

**Objective.** Clean up the two cosmetic items that don't touch code.

**Scope.**

1. Correct `sim-spec.md` hitter-pool annotation `(8 per team)` → `(9 per team)`
   (C, 1B, 2B, 3B, SS, OF×3, DH).
2. Add a one-line note in `?sgp_denominators`'s `@details` section: "The
   `denom_floor` guard caused zero near-zero triggers across 115,000 simulation
   runs under tested DGPs; the default is conservative, not load-bearing."

**Agents.** Scriber only (no planner needed for pure docs). Reviewer confirms.

**Effort.** ~10 min.

#### Dispatch prompt (paste to Leader)

```
Request ID: sgp-docs-cleanup-2026-04-17

Docs-only cleanup. No code, no tests, no simulation.

Read plans/sgp-cleanup.md §"R3 — sgp-docs-cleanup" for the authoritative scope.

## Changes required

1. In the hitter pool annotation inside specs/spec-sgp.md (or wherever the
   "(8 per team)" annotation for DGP-Rate's hitter primary slots appears),
   correct the count to "(9 per team)" — the standard roster is
   C, 1B, 2B, 3B, SS, OF×3, DH = 9 primary hitter slots per team.

2. In the roxygen documentation for sgp_denominators() (R/sgp-denominators.R,
   @details section), add a short sentence:

     "The `denom_floor` guard caused zero near-zero triggers across 115,000
     simulation runs under tested DGPs; the default is conservative, not
     load-bearing."

Regenerate man/sgp_denominators.Rd via devtools::document() after editing.

## Acceptance criteria

- The "8 per team" annotation no longer appears in specs/ or plans/.
- devtools::document() produces a clean diff to man/sgp_denominators.Rd
  containing the new @details sentence.
- R CMD check still clean (0 ERRORs, 0 WARNINGs, NOTEs unchanged).

## Workflow

Docs-only. Scriber → Reviewer → Shipper. Skip Planner, Builder, Tester,
Simulator.

## Branch

- Feature branch: feature/sgp-docs-cleanup
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### R4 — `sgp-denom-inverse-categories-param`

**Objective.** Replace the hard-coded `INVERSE_CATEGORIES` vector in
`R/sgp-denominators-helpers.R` with a user-controllable parameter so leagues
scoring OAVG, BB9, HR/9-allowed, etc. aren't silently treated as normal-direction
categories.

**Scope.**

1. Add argument `inverse_categories = c("ERA", "WHIP")` to `sgp_denominators()`.
   Default preserves current behavior. Validation: must be character; values
   must appear in `scored_categories`.
2. Thread the parameter through both the main year-loop and the bootstrap
   resampling loop (same two sites D3 patched in the original run).
3. Emit `cli_inform()` once per call naming which categories will be
   direction-flipped, so users see that the override took effect.

**Test-spec additions.**

- `inverse_categories = c("ERA", "WHIP", "OAVG")` on synthetic data with an
  OAVG column flips its slope as expected.
- Passing an invalid value (not in `scored_categories`) throws
  `rotostats_error_invalid_inverse_categories`.
- Default behavior unchanged when argument is omitted.

**Simulation?** No — functionally equivalent to existing code on standard
categories; no new statistical property.

**Acceptance.** Existing T-25 and related tests pass unchanged (because the
default covers them); three new tests pass.

**Effort.** ~25–35 min.

#### Dispatch prompt (paste to Leader)

```
Request ID: sgp-denom-inverse-categories-param-2026-04-17

Expose the INVERSE_CATEGORIES vector in sgp_denominators() as a user-controllable
argument.

Read specs/spec-sgp.md §"sgp_denominators()" and plans/error-messages.md before
planning. Read plans/sgp-cleanup.md §"R4 — sgp-denom-inverse-categories-param"
for the authoritative scope.

## Changes required

1. Spec update: add argument inverse_categories to sgp_denominators().
   - Type: character vector. Default: c("ERA", "WHIP").
   - Validation: every element must appear in scored_categories; otherwise abort
     with rotostats_error_invalid_inverse_categories.
   - Add the error class to plans/error-messages.md.

2. Builder: thread inverse_categories through both the main year-loop and the
   bootstrap resampling loop in R/sgp-denominators.R. The rank-flip logic
   (n_y + 1L - rank(total)) applies only to names in inverse_categories.

3. Emit a one-shot cli_inform() per call naming which categories will be
   direction-flipped. Use .frequency = "once" with an explicit .frequency_id
   (rlang ≥ 1.1.0 requires it).

4. Update @param documentation in the roxygen block.

## Acceptance criteria

- Default call sgp_denominators(history, categories = c("HR", "ERA"))
  behaves identically to the current implementation (T-25 and all existing
  tests pass unchanged).
- sgp_denominators(history, categories = c("HR", "OAVG"),
  inverse_categories = c("OAVG")) produces a negative OLS slope for OAVG and
  does NOT fire rotostats_warning_unexpected_slope_sign.
- sgp_denominators(..., inverse_categories = c("NOT_IN_CATEGORIES")) aborts
  with rotostats_error_invalid_inverse_categories.
- cli_inform() fires once per call reporting the effective inverse_categories.
- R CMD check: 0 ERRORs, 0 WARNINGs, NOTEs unchanged.

## Hard constraints

- Errors/warnings via cli_abort()/cli_warn() with class= from
  plans/error-messages.md.
- Default value of inverse_categories must be c("ERA", "WHIP") so no existing
  user code breaks.
- Keep the rank-flip logic applied in BOTH the main loop and the bootstrap
  resampling loop (the two sites D3 patched in the 2026-04-16 run).
- No row-wise loops — keep per-year computation vectorized.

## Workflow

Code-only (functionally equivalent on standard categories; no new statistical
property). Planner → Builder → Tester → Scriber → Reviewer → Shipper.

## Branch

- Feature branch: feature/sgp-denom-inverse-categories-param
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### R5 — `sgp-fixed-baseline-impl` (deferred)

**Objective.** Implement the `"fixed_baseline"` rate-conversion path that
currently errors via a stub.

**Why deferred.** No one is blocked; the current error is loud and typed.
Implementation requires a real methodological decision (what baseline source,
how to calibrate, how to interact with `pool_sizes()`), which belongs in a
dedicated Planner pass — not a patch.

**Precondition.** Open a GitHub issue describing the intended use case before
starting. If no use case surfaces in the next 1–2 months, consider removing
the parameter from the interface entirely (via a deprecation cycle) rather
than implementing it.

**Prompt:** Not drafted — depends on the methodological decisions the
precondition issue surfaces. Compose when triggered.

---

### R6 — `sgp-denom-bca-bootstrap` (deferred)

**Objective.** Replace or extend the percentile bootstrap with BCa to close
the Q3 coverage gap.

**Why deferred.**

1. Already documented in `?sgp_denominators` `@section Caveats` as a known
   limitation at `n_years ≤ 6`.
2. The recommended user mitigation (prefer `n_years ≥ 10`) works today.
3. The `validate_denominators()` function in `plans/sgp-validation.md`
   §"Proposed" is probably the right home for BCa — doing BCa now means
   potentially redoing it when `validate_denominators()` lands.

**Trigger to start.** Either (a) user feedback that short-history CIs are
misleading, or (b) `validate_denominators()` is spec'd and BCa becomes part
of that function's natural surface.

**Prompt:** Not drafted — compose when triggered. The prompt should include
a re-run of Q3 under BCa and confirm coverage lands within [0.93, 0.97].

---

## Definition of done (for each request)

- Feature branch merged to `develop` with clean `R CMD check` (0 ERRORS,
  0 WARNINGs, only pre-existing NOTEs).
- Run artifacts in
  `~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/<slug>-YYYY-MM-DD/`.
- `NEWS.md` entry for user-visible changes (R1, R4, R5, R6).
- Reviewer verdict: SHIP.
- No new follow-up items left un-triaged in `review.md`.

---

## What this plan intentionally leaves out

- **`league_history()` constructor.** Not a bug in `sgp()` or
  `sgp_denominators()` — it's a missing Phase-1 scaffolding item with its own
  scope. Track separately.
- **`replacement_level()` full run.** The pending tester dispatch for
  `replacement-2026-04-16`. Independent of everything here.
- **Autoresearch Layer-2 LOYO study.** The "which denominator method actually
  works best on real data" question. That's `plans/autoresearch-valuation.md`
  territory, not a patch-up of the current runs.
