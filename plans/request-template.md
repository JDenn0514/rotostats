# Request template: <function-name>

> Canonical dispatch-prompt template for statsclaw pipeline runs.
> Created: 2026-04-20
> Source: retrospective of the first 12 statsclaw runs (2026-04-16 through
> 2026-04-19) — see run artifacts under
> `~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/`.
>
> **When to use.** Copy this file and instantiate it for every new function
> build, and for every non-trivial follow-up that needs more than a one-line
> patch. The three cleanup plans in this directory
> (`par-cleanup.md`, `sgp-cleanup.md`, `replacement-cleanup.md`) pre-date this
> template and remain valid as compatible legacy documents; do not retrofit
> them. New plans should start from this template and replace all angle-bracket
> and square-bracket placeholders before dispatch.

---

## Metadata

- **Request ID.** `<slug>-YYYY-MM-DD` (slug is kebab-case; the date is the
  dispatch date, not the merge date).
- **Feature branch.** `feature/<slug>` (must match the Request ID slug
  character-for-character).
- **Base branch.** `develop`.
- **PR base.** `develop` (never `main` — see `CLAUDE.md` §"Branching Model").
- **Workspace repo.** `JDenn0514/workspace`.
- **Run directory.** `~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/<slug>-YYYY-MM-DD/`.

---

## Objective

<One paragraph. What does the function do, and why is this run being
dispatched? Name the spec being consumed, the prior run being extended,
or the follow-up ticket this run discharges. Keep to 3–5 sentences; anything
longer belongs in `spec.md`, not the dispatch prompt.>

---

## Reading

List the files the planner should read FIRST, in priority order. Typical
entries:

- `specs/spec-<function-name>.md` — authoritative spec for the function.
- `plans/error-messages.md` — error/warning class registry (see `CLAUDE.md`
  §"Reference Documents").
- `plans/statsclaw-workflow.md` — nine-agent pipeline and state machine.
- `ARCHITECTURE.md` — package-level design notes and known limitations.
- `<prior-run-path>/simulation.md` and `<prior-run-path>/review.md` — if this
  run supersedes or extends a previous pipeline run.
- `plans/<parent-cleanup-file>.md` §"<ticket>" — if this run is a ticket out
  of a cleanup plan.

<Add/remove bullets as appropriate. Every entry must be an actual path the
reader can open.>

---

## Pre-flight (all steps mandatory)

1. `git -C /Users/jacobdennen/rotostats checkout develop`
2. `git -C /Users/jacobdennen/rotostats pull --ff-only origin develop`
3. **Branch-existence gate (HARD).** Run
   `git -C /Users/jacobdennen/rotostats branch --list feature/<slug>`.
   If the command returns any output, STOP. A stale local branch exists from
   a prior orphaned worktree. The user must delete it by hand (`git branch -D
   feature/<slug>`) before re-dispatching. Do NOT auto-delete — it may hold
   uncommitted follow-up work.
4. Do NOT pre-create the feature branch locally — each teammate's worktree
   cuts its own branch from the clean `develop` tip.

---

## Changes required

1. <First concrete change. Name the file, the function, and the intended
   edit. Reference spec section numbers where possible — e.g. "per
   `specs/spec-<fn>.md` §7".>
2. <Second change.>
3. <Third change — add as many numbered bullets as needed. Keep each one to
   a single unit of work the builder/simulator/scriber can point at.>

<If the run has distinct phases (planner amends sim-spec, then simulator
runs, then tester gates), break this section into per-agent subsections —
see `replacement-cleanup.md` §R5 and §R6 for worked examples.>

---

## Acceptance criteria

- `R CMD check`: 0 ERRORs, 0 WARNINGs, NOTEs unchanged from `develop`.
- `devtools::test()`: FAIL=0; no new SKIPs beyond those present on `develop`.
- <Function-specific criterion 1. E.g., "sgp(..., pool_baseline = 'foo')
  throws `rotostats_error_invalid_pool_baseline` naming the valid values.">
- <Function-specific criterion 2.>
- <For simulation runs, include Monte Carlo acceptance thresholds with
  explicit `R` (replication count) and master seed.>
- <For docs runs, include "devtools::document() produces a clean diff to
  man/<fn>.Rd".>

---

## Hard constraints

- Errors and warnings via `cli_abort()` / `cli_warn()` with `class =` drawn
  from `plans/error-messages.md` — never bare `stop()` or `warning()`. New
  classes must be registered in `plans/error-messages.md` before first use.
- Vectorized operations preferred; no row-wise loops unless the spec
  explicitly calls for one.
- No refactors outside the scope named in `## Changes required`. If the
  builder sees an obvious adjacent cleanup, file a follow-up ticket rather
  than bundling.
- Dispatch all writing teammates (Builder, Simulator, Tester, Scriber) with
  `isolation: "worktree"` per the statsclaw protocol — see
  `plans/statsclaw-workflow.md`.

**Cross-pipeline escalation protocol.** If the simulator encounters a bug in
`R/` code during its run, the simulator MUST write a `BLOCK` entry to
`mailbox.md` and STOP — it must not modify any file under `R/`. Leader
fast-path-respawns builder to fix. If the builder encounters a DGP bug in
`inst/simulations/` during its run, the builder MUST write a `BLOCK` entry
and STOP — it must not modify any file under `inst/simulations/`. Leader
fast-path-respawns simulator. Pipeline-surface violations (even when the
fix is "correct") require reviewer STOP, not waiver.

---

## Workflow

Pick exactly one variant and name the full agent chain:

- **Code.** Planner → Builder → Tester → Scriber → Reviewer → Shipper.
- **Docs-only.** Scriber → Reviewer → Shipper. Skip Planner, Builder,
  Tester, Simulator.
- **Simulation + Code.** Planner → (Builder ∥ Simulator) → Tester → Scriber
  → Reviewer → Shipper. Used when the function is a statistical estimator
  and Monte Carlo validation is part of the acceptance bar.
- **Simulation-only.** Planner (sim-spec patch) → Simulator → Tester →
  Reviewer → Shipper. No Builder, no Scriber (unless a doc recommendation
  shifts — in that case file a follow-up docs run).

<State which variant this run uses and why. One sentence suffices.>

---

## Scriber responsibilities

- **Roxygen reconciliation.** Before committing `R/<fn>.R` or `man/<fn>.Rd`,
  scriber MUST diff every `@param` default, every `@details` numeric constant,
  every `na.rm`, every default argument, and every return-shape description
  against the final `R/<fn>.R` at HEAD (post all respawns). Any drift must be
  fixed in the roxygen block before the docs commit, not deferred. Record the
  diff check in `docs.md` § "Roxygen reconciliation" (even if empty).
- Regenerate `man/*.Rd` via `devtools::document()` before committing; commit
  the regenerated Rd alongside the source change, never as a follow-up.
- Add a `NEWS.md` entry for every user-visible change (new argument, new
  error/warning class, behavior change, default change). Docs-only runs that
  do not change behavior do not need a `NEWS.md` entry — see
  `sgp-cleanup.md` §R7 for precedent.
- Update `ARCHITECTURE.md` when the run changes a public function's
  interface, adds a known limitation, or introduces a new cross-function
  dependency.
- `@examples` coverage: every runtime code path named in the spec must be
  exercised by at least one unwrapped (non-`\dontrun{}`) example that runs
  under `R CMD check --as-cran` without downloads or external state.
  Long-running or data-dependent examples may be wrapped; the minimal path
  must not.

---

## Branch

- Feature branch: `feature/<slug>`
- Base branch: `develop`
- PR base: `develop`

---

## Workspace repo

`JDenn0514/workspace`
