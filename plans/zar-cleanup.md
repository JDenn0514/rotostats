# Plan: Addressing Remaining `zar()` Follow-ups

> Created: 2026-04-21
> Source: Follow-up items from run `zar-2026-04-21` (reviewer verdict
> READY_TO_SHIP, PR [#25](https://github.com/JDenn0514/rotostats/pull/25)
> merged to `develop` as `de502c1`)
> Related: `specs/spec-zar.md`, `plans/error-messages.md`, `ARCHITECTURE.md`,
> `plans/archive/zaa-cleanup.md`

---

## Status summary

| Ticket | Slug | Type | Status |
|---|---|---|---|
| ZC1 | `zar-test-combined-hitter-pool` | Test-only | Open |
| ZC2 | `zar-fixture-helper-padj-passthrough` | Test-helper | Open |
| ZC3 | `zar-sim-rate-stat-coverage` | Simulation-only | Open |
| ZC4 | `zar-sim-multi-scenario-rho` | Simulation-only | Open |
| ZC5 | `replacement-positional-adjustment-none` | Code | Deferred |
| ZC6 | `zar-total-narm-option` | Code | Deferred |
| ZC7 | `zar-test-spec-ts4-sign-reference` | Archive note | Closed — non-actionable |

Each scheduled request = one statsclaw run with its own request ID, its own
feature branch (`feature/<slug>`), and its own PR into `develop`. The slug
gets baked into the run directory under
`~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/<slug>-YYYY-MM-DD/`.

ZC1 and ZC2 are small test-surface improvements that harden the `zar()`
coverage floor. ZC3 and ZC4 extend the Monte Carlo study to exercise
paths the v3 sim deliberately excluded. ZC5 and ZC6 are feature requests
that surfaced during the run but were correctly descoped; they start
only on explicit demand. ZC7 is a documentation note against a frozen
workspace artifact; archived for traceability.

---

## Sequencing principle

- **Wave 1** — ZC1, ZC2. Test-only, independent, parallel. No code or
  source change. Lands before the sim work in Wave 2.
- **Wave 2** — ZC3, ZC4. Simulation-only extensions to
  `inst/simulation/sim-zar.R`. Sequential; ZC3 adds new DGP surface
  and ZC4 extends the existing harness — running ZC3 first keeps the
  harness churn in one pass.
- **Wave 3** — ZC5, ZC6. Deferred; start only on explicit demand or
  user report. Both cross function boundaries (`replacement_level()`
  and `zar()` respectively) and deserve dedicated planner passes rather
  than being bundled.
- **Archive** — ZC7. No run; captured here only so the TS-ZAR-4 sign
  reference prose is discoverable if someone revisits the frozen
  `test-spec.md` from the `zar-2026-04-21` run.

---

## Dependency graph

```
ZC1 ──┐
ZC2 ──┼── (independent test-surface work; run in parallel)
       │
       v
ZC3 ── (sim harness extension; exercises rate-stat band-mean invariant)
       │
       v
ZC4 ── (cheaper if it rides on ZC3's harness changes; otherwise independent)
       │
       v
ZC5, ZC6 ── deferred; independent of each other when they eventually run
```

No item blocks any downstream valuation function (`pvm()`,
`dollar_values()`) — those can proceed regardless. ZC1–ZC4 harden the
`zar()` floor without changing its public contract.

---

## Pre-flight for every request

Before dispatching any request:

```bash
git -C /Users/jacobdennen/rotostats checkout develop
git -C /Users/jacobdennen/rotostats pull --ff-only origin develop
```

Do NOT pre-create the feature branch locally — each statsclaw run cuts
its own feature branch and specialist teammates work inside git
worktrees. The top-level session adopts the Leader role (see
`~/.claude/skills/run-statsclaw/SKILL.md` §Step 4) and dispatches
specialist teammates with `isolation: "worktree"`.

**Branch-name hygiene.** Before dispatching, confirm the target feature
branch name is NOT already present locally (`git branch --list
feature/<slug>`). Stale worktree branches from the `zar-2026-04-21`
run are locked but not deleted; a new run re-using an old slug would
collide.

All prompts below MUST be pasted into a **fresh** Claude Code session
(so Leader starts with clean context).

---

## Request specs and dispatch prompts

### ZC1 — `zar-test-combined-hitter-pool`

**Objective.** Close the reviewer NOTE-2 coverage gap: `zar()`'s
`hitter_pool = "combined"` path (flat-distribution schema for hitters)
is exercised by a builder structural test and implicitly via the
algebraic identity, but no tester assertion pins its correctness.

**Why file this now.** Reviewer flagged this in `review.md` as a
future coverage gap ("Track as future test coverage gap"). Closing it
before any downstream valuation function consumes `zar()` keeps
regressions localized.

**Scope (test-only — no code, no spec change, no docs rewrite).**

1. Extend `tests/testthat/test-zar.R` with one new scenario:
   - `TS-ZAR-13`: `hitter_pool = "combined"` + `pitcher_pool = "combined"`
     + mixed hitter/pitcher pool + `include_raw = TRUE`. Assert the
     algebraic identity (`zaa_<cat> - zar_<cat>` is a per-category
     constant offset across hitters, because they now share one flat
     distribution per category; pitchers retain their combined-pool
     flat distribution separately).
2. Extend `tests/testthat/helper-zar-fixtures.R` only if the existing
   fixtures can't be reused. Prefer a single-argument toggle on
   `make_zar_fixture()` (ties into ZC2's scope but a minimal inline
   adaptation is acceptable if ZC2 hasn't landed).

**Explicitly out of scope.**

- No change to `R/zar.R` or `R/zaa.R`.
- No change to `specs/spec-zar.md` or `ARCHITECTURE.md`.
- No `NEWS.md` entry (test-only, no user-visible behavior change).

**Acceptance.**

- `devtools::test(filter = "zar")` passes with the new scenario added.
- `devtools::check()`: 0 errors, 0 warnings, notes unchanged from `develop`.
- Reviewer confirms the new scenario tests observable behavior only
  and does not reach into implementation internals.

**Effort.** ~20–30 min including dispatch overhead.

#### Dispatch prompt (paste to Leader)

```
Request ID: zar-test-combined-hitter-pool-2026-MM-DD

Test-only — add one scenario to tests/testthat/test-zar.R. No source
or spec change.

Read plans/zar-cleanup.md §"ZC1 — zar-test-combined-hitter-pool" for
the authoritative scope. Also read:
  - specs/spec-zar.md (public-facing behavior)
  - tests/testthat/test-zar.R and helper-zar-fixtures.R (existing)
  - Run review: ~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/zar-2026-04-21/review.md §NOTE-2

## Changes required

Add TS-ZAR-13: hitter_pool="combined" + pitcher_pool="combined" +
mixed hitter/pitcher pool + include_raw=TRUE.
  - Assertions: zar() returns a data frame without error; for every
    (category, position) pair, diff(range(zaa_<cat> - zar_<cat>))
    within the position is < 1e-10 (constant-offset algebraic identity);
    attr(result, "distribution") is flat for both hitters and pitchers
    (not nested by position).

## Acceptance criteria

- devtools::test(filter="zar") passes; all prior TS-ZAR-1..12 plus the
  new TS-ZAR-13 scenario.
- devtools::check(): 0 errors, 0 warnings, notes unchanged.
- No changes outside tests/testthat/.

## Hard constraints

- Do NOT read R/zar.R internals to shape assertions — treat as black
  box. Drive every assertion from the public spec.
- Reuse existing fixture helpers where possible.
- No change to R/, man/, NAMESPACE, NEWS.md, ARCHITECTURE.md, specs/,
  or plans/.

## Workflow

Test-only. Tester → Reviewer → Shipper. Skip Planner, Builder, Scriber,
Simulator.

## Branch

- Feature branch: feature/zar-test-combined-hitter-pool
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### ZC2 — `zar-fixture-helper-padj-passthrough`

**Objective.** Let `make_zar_fixture()` accept
`positional_adjustment_method` so future boundary-style tests can
construct a fixture with suppressed scarcity premium without hand-rolling
a separate `make_zar_boundary_fixture()` helper.

**Why file this now.** Tester for `zar-2026-04-21` hit the ceiling:
the default `make_zar_fixture()` (which pipes through
`replacement_level()` with default `fvarz`) produces boundary-player
`zar` values outside a tight tolerance because `fvarz` shifts the
replacement line upward. The tester had to write a parallel
`make_zar_boundary_fixture()` for TS-ZAR-2. A passthrough argument
avoids that duplication for future boundary-style tests.

**Scope (test-helper — no code outside `tests/testthat/`).**

1. Extend `make_zar_fixture()` in `tests/testthat/helper-zar-fixtures.R`
   to accept `positional_adjustment_method = "fvarz"` (default) and
   forward to the internal `replacement_level()` call.
2. Migrate `make_zar_boundary_fixture()` callers to
   `make_zar_fixture(..., positional_adjustment_method = <whatever
   `replacement_level()` ends up accepting>)` if and only if ZC5 lands
   first and adds a `"none"` option. Otherwise, leave
   `make_zar_boundary_fixture()` as-is (it's still the only path to a
   clean boundary fixture) and just document the split in a header
   comment.
3. Delete `make_zar_boundary_fixture()` only if all its call sites
   migrate successfully. If any sites remain, keep it and document the
   decision tree (default generator → passthrough arg covers most
   cases; hand-crafted fixture → use the boundary helper).

**Explicitly out of scope.**

- No change to `R/zar.R` or any other R/ source.
- No change to `replacement_level()` — see ZC5 if a `"none"` option is
  wanted.
- No new public export.

**Acceptance.**

- `devtools::test(filter = "zar")` passes unchanged.
- `devtools::check()`: 0 errors, 0 warnings, notes unchanged.
- Helper file has a short header comment documenting the passthrough
  pattern and when to use each helper.

**Effort.** ~15–20 min.

#### Dispatch prompt (paste to Leader)

```
Request ID: zar-fixture-helper-padj-passthrough-2026-MM-DD

Test-helper only. Add positional_adjustment_method passthrough to
make_zar_fixture() in tests/testthat/helper-zar-fixtures.R.

Read plans/zar-cleanup.md §"ZC2 — zar-fixture-helper-padj-passthrough"
for the authoritative scope.

## Changes required

1. Add positional_adjustment_method = "fvarz" argument to
   make_zar_fixture(). Forward to the internal replacement_level() call.
2. Migrate make_zar_boundary_fixture() callers where possible. Leave
   the helper in place if any call sites still need a hand-crafted
   boundary fixture.
3. Add a short header comment to helper-zar-fixtures.R describing the
   decision tree (default generator with passthrough vs hand-crafted
   boundary).

## Acceptance criteria

- devtools::test(filter="zar"): unchanged pass count; 0 fail.
- devtools::check(): 0 errors, 0 warnings, notes unchanged.
- No changes outside tests/testthat/.

## Hard constraints

- No change to R/, specs/, plans/, man/, or NAMESPACE.
- Default value must preserve current make_zar_fixture() behavior.
- If ZC5 (replacement_level() "none" option) has not landed, valid
  passthrough values are limited to the existing choices
  ("fvarz", "sgp", "dollar", "posblend").

## Workflow

Test-only. Tester → Reviewer → Shipper.

## Branch

- Feature branch: feature/zar-fixture-helper-padj-passthrough
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### ZC3 — `zar-sim-rate-stat-coverage`

**Objective.** Extend `inst/simulation/sim-zar.R` to exercise the
band-mean invariant (AC-SIM-2) on rate stats (ERA, WHIP) in addition
to the counting stats already covered.

**Why file this now.** The v3 sim deliberately restricted DGP to pure
counting stats (HR, R, SB, K, SV) — a pragmatic scope for the initial
run. AC-SIM-1 (algebraic identity) covers rate stats algebraically,
but AC-SIM-2 (band-mean = 0) is a tighter structural check that
catches rate-stat-specific bugs (volume-weighting errors, sign
convention, IP/AB denominator lookups). Those paths are in `R/zar.R`
but have no Monte Carlo coverage.

**Scope (simulation-only — no code, no spec change, no test change).**

1. Add a new scenario S5 (`rate_stats`) to `inst/simulation/sim-zar.R`:
   - DGP: hitter AVG (H/AB), pitcher ERA (ER/IP) and WHIP ((BB+H)/IP).
   - Use the same fixed-latent-ability pattern as v3 (Gamma on rates,
     clamped to realistic ranges).
   - AB and IP drawn i.i.d. per rep per player (keep the "volume"
     dimension noisy — that's the whole point of the volume-weighted
     z-score).
2. Update `inst/simulation/sim-zar-summary.csv` schema to include S5
   rows with the same AC columns.
3. Verify: `band_mean_max_err_max < 1e-10` and
   `band_mean_violation_rate < 1%` on S5. If either fails, STOP and
   surface as a potential builder defect in `R/zar.R` — do NOT loosen
   the threshold.

**Explicitly out of scope.**

- No change to `R/zar.R`.
- No change to `specs/spec-zar.md` (the spec already documents rate-stat
  handling; the sim is closing a coverage gap, not expanding contract).
- No new test scenarios in `tests/testthat/test-zar.R` — the existing
  TS-ZAR-4 already covers rate-stat behavior at the unit level.

**Acceptance.**

- S5 runs 200 reps with `zar_failed = FALSE` for all.
- S5 passes AC-SIM-1 at 1e-10, AC-SIM-2 at 1e-10 with 0/200 violations.
- `sim-zar-summary.csv` gains an S5 row with the same columns as
  S1–S4.
- `simulation.md` in the run directory documents S5 design and results.

**Effort.** ~30–45 min (sim harness extension is the bulk).

#### Dispatch prompt (paste to Leader)

```
Request ID: zar-sim-rate-stat-coverage-2026-MM-DD

Simulation-only. Add scenario S5 (rate stats: AVG, ERA, WHIP) to
inst/simulation/sim-zar.R. No change to R/zar.R, specs/, or tests/.

Read plans/zar-cleanup.md §"ZC3 — zar-sim-rate-stat-coverage" for the
authoritative scope. Read:
  - inst/simulation/sim-zar.R (existing harness)
  - specs/spec-zar.md §"Rate stats" (contract)
  - ~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/zar-2026-04-21/sim-spec.md (v3 DGP pattern)

## Changes required

1. Add S5 scenario (rate_stats) to the scenario grid:
   - Hitter AVG: draw latent batting-average ability per player
     (Beta(8, 22) → ~0.267 mean, plausible spread), then H_i ~
     Binomial(AB_i, avg_latent_i) per rep with AB_i ~ Gamma(shape, rate)
     per rep.
   - Pitcher ERA: latent ERA per SP/RP, then ER_i ~ Poisson(era_latent_i
     × IP_i / 9) per rep with IP_i i.i.d.
   - Pitcher WHIP: BB_i and H_i conditionally drawn given IP_i.
2. Wire S5 through run_zar_safe() and the per-rep metric collectors
   (identity_max_error, band_mean_max_err, rank_rho_hr_r_k not
   applicable for S5, top_minus_boundary_mean for a chosen rate cat).
3. Extend sim-zar-summary.csv with S5 rows; update simulation.md.

## Acceptance criteria

- S5: 200 reps, 0 failures, AC-SIM-1 PASS at 1e-10, AC-SIM-2 PASS at
  1e-10 with 0/200 violations.
- Existing S1–S4 results unchanged (re-run and confirm byte-identical
  results under the same seed).
- sim-zar-summary.csv has an S5 row with the same columns.
- simulation.md documents the S5 DGP and results.

## Hard constraints

- No change to R/zar.R, R/zaa.R, R/replacement.R, or any R/ source.
- No change to specs/, plans/, or tests/.
- If AC-SIM-2 fails on S5 at 1e-10, STOP and report as a potential
  builder defect. Do NOT loosen the threshold.
- Every replacement_level() call uses default positional_adjustment_method.

## Workflow

Simulation-only. Simulator → Tester → Reviewer → Shipper. Tester's role
is to re-run devtools::test(filter = "zar") after the sim-zar-results.rds
update to confirm SV-1..5 still pass (they load the results file).

## Branch

- Feature branch: feature/zar-sim-rate-stat-coverage
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### ZC4 — `zar-sim-multi-scenario-rho`

**Objective.** Compute `rank_rho_hr_r_k` across S2 and S3 (currently
`NA` per v3 design) so AC-SIM-3 (rank stability) has evidence from
more than one DGP. Keep S4 at `NA` — its regime-break DGP makes rho
uninformative by construction.

**Why file this now.** The v3 sim populated `rank_rho_hr_r_k` only for
S1 (null DGP, combined pitcher pool). The `NA` pattern for S2 (split
pool) and S3 (larger null DGP) is a design artifact of the initial
sim run, not a principled restriction. Extending to S2/S3 gives AC-SIM-3
broader evidence under realistic latent-ability DGPs.

**Scope (simulation-only).**

1. Update `compute_rank_stability()` in `inst/simulation/sim-zar.R` to
   populate `rank_rho_hr_r_k` for S2 and S3.
2. Update `sim-zar-summary.csv` to show the new values. The per-scenario
   `ac_sim3_pass` column becomes populated for S2/S3 (was `NA`).
3. Update `§4 SV-3` in the run's `test-spec.md` (a workspace artifact;
   if the convention forbids editing frozen run artifacts per Z3 in
   `plans/archive/zaa-cleanup.md`, then update `tests/testthat/test-zar.R`'s
   SV-3 assertion to iterate over S1/S2/S3 and require all three to
   exceed 0.55).

**Expected results.** Under the fixed-latent-ability DGP, rho should
be similar across S1/S2/S3 (the pool-configuration differences affect
which distributions `zaa()` uses internally, not the within-player
rank stability across reps). ≈ 0.60–0.65 in each.

**Explicitly out of scope.**

- No change to R/zar.R.
- No threshold revision (0.55 stays).
- No new scenarios.

**Acceptance.**

- S2 and S3 have populated `rank_rho_hr_r_k` values in
  `sim-zar-summary.csv`.
- All three scenarios pass rho > 0.55; if S2 or S3 fails, diagnose
  whether the DGP-config difference (split pool, larger pool) is the
  source and STOP for spec revision rather than loosen the threshold.
- `tests/testthat/test-zar.R` §SV-3 asserts all three scenarios pass
  the threshold.

**Effort.** ~15–25 min (harness change is small; most effort is
verifying the new values).

#### Dispatch prompt (paste to Leader)

```
Request ID: zar-sim-multi-scenario-rho-2026-MM-DD

Simulation-only. Extend rank_rho_hr_r_k computation to S2 and S3 in
inst/simulation/sim-zar.R. Keep S4 at NA (regime-break DGP makes rho
uninformative).

Read plans/zar-cleanup.md §"ZC4 — zar-sim-multi-scenario-rho" for the
authoritative scope.

## Changes required

1. Update compute_rank_stability() in sim-zar.R: include S2 (split pool)
   and S3 (large null) in the consecutive-rep Spearman rho calculation.
   Continue excluding S4 with an inline comment explaining why.
2. Rerun the full 800-rep harness; confirm S2/S3 rho values are
   populated in sim-zar-results.rds and sim-zar-summary.csv.
3. Update tests/testthat/test-zar.R §SV-3: iterate rho > 0.55 check
   across S1, S2, S3 (not just S1).

## Acceptance criteria

- S2 and S3 rho values populated; both > 0.55.
- S4 rho remains NA with an inline comment.
- SV-3 in test-zar.R asserts all three populated scenarios pass.
- All prior SV-1, SV-2, SV-4, SV-5 assertions unchanged.
- devtools::test(filter="zar"): 0 failures.
- devtools::check(): 0 errors, 0 warnings, notes unchanged.

## Hard constraints

- No change to R/zar.R, R/zaa.R, or any R/ source.
- No threshold revision (rho > 0.55 stays).
- No new scenarios beyond S1–S4.
- If S2 or S3 rho < 0.55, STOP and report for spec revision. Do NOT
  loosen the threshold.

## Workflow

Simulation-only. Simulator → Tester → Reviewer → Shipper.

## Branch

- Feature branch: feature/zar-sim-multi-scenario-rho
- Base branch: develop
- PR base: develop

## Workspace repo

JDenn0514/workspace
```

---

### ZC5 — `replacement-positional-adjustment-none` (deferred)

**Objective.** Add `"none"` as a valid value for
`positional_adjustment_method` in `replacement_level()`. Under `"none"`,
the replacement-band stat line is the raw head-count boundary player
(no scarcity premium).

**Why deferred.** No one is currently blocked. The v3 sim sidestepped
the missing value cleanly (falls back to `fvarz`), and the band-mean
invariant as redefined in Planner Revision 3 is correct regardless of
which premium method is used. A user would need to explicitly ask for
a "raw boundary replacement" mode before this is worth the spec-level
decision.

**Precondition before filing.** Open a GitHub issue describing the
intended use case. If no use case surfaces in the next 1–2 months,
consider closing this ticket permanently — `fvarz`, `sgp`, `dollar`,
and `posblend` cover the documented rotisserie use cases.

**Scope (if triggered).**

1. Spec update in `specs/spec-replacement.md` documenting `"none"`.
2. Builder: add `"none"` to the `assert_choice` allowlist in
   `R/replacement.R:224-227`; add a new branch in
   `R/replacement_internal.R` that returns the raw head-count boundary
   stat line unchanged (no premium math).
3. Tester: add a scenario asserting
   `replacement_level(..., positional_adjustment_method = "none")`'s
   `replacement_stats` equals the raw boundary player's stat line.
4. Planner: update `plans/error-messages.md` only if a new class is
   needed (likely not — the existing invalid-value path already uses
   `assert_choice`'s generic error).

**Trigger to start.** A user report or downstream valuation function
requesting raw-boundary replacement semantics.

**Prompt.** Not drafted — compose when triggered. The prompt should
include a Monte Carlo study of the `"none"` path's behavior vs
`"fvarz"` on a synthetic hitter-only DGP where scarcity premium should
be ~0 by symmetry.

---

### ZC6 — `zar-total-narm-option` (deferred)

**Objective.** Add an `na.rm` argument to `zar()` controlling whether
`total_zar` uses `sum(..., na.rm = TRUE)` for the rowSum aggregation.

**Why deferred.** The v1 implementation uses `na.rm = FALSE` to match
`total_zaa`'s convention (planner adopted this as a default; see
`~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/zar-2026-04-21/mailbox.md`
§Notes/Flags bullet 1). This means pitchers in a league that scores
AVG get `total_zar = NA` (no `AB` → NA z-score → NA rowSum), and
hitters in a league that scores ERA get `total_zar = NA` symmetrically.

For leagues with mixed hitter/pitcher scoring where the user wants
hitters and pitchers to share a single `total_zar` column, `na.rm = TRUE`
would let each player aggregate only the categories they actually have
data for.

**Why deferred.** No user has hit this. The current behavior is
correct given the documented `na.rm = FALSE` convention, and the NA
propagation is a loud signal that helps users catch mis-specified
leagues.

**Precondition before filing.** A user report OR a demonstrated
`dollar_values()` use case that requires per-player `total_zar`
values across mixed categories.

**Scope (if triggered).**

1. Spec update in `specs/spec-zar.md` documenting the `na.rm` argument,
   default `FALSE` (preserves v1 behavior), and the invariant change.
2. Builder: thread `na.rm` through `R/zar.R`'s final rowSum call.
3. Tester: add scenarios confirming (a) default preserves v1 NA
   propagation, (b) `na.rm = TRUE` produces finite `total_zar` for
   mixed-pool players with partial category coverage.
4. Scriber: update `?zar` `@param`; NEWS entry.
5. Propagate the same argument to `zaa()` iff `total_zaa` needs the
   same knob (separate decision; not automatic).

**Trigger to start.** User feedback OR `dollar_values()` spec work
that requires this.

**Prompt.** Not drafted — compose when triggered.

---

### ZC7 — `zar-test-spec-ts4-sign-reference` (archive note)

**Status.** Non-actionable as a repo change.

**What it is.** The reviewer observed in `review.md` that `test-spec.md`
§TS-ZAR-4 (the frozen planner-era copy in the workspace run directory
`~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/zar-2026-04-21/test-spec.md`)
expresses the rate-stat sign check as
`sign(mean_ERA - player_ERA)`. The behaviorally correct reference is
`sign(repl_ERA - player_ERA)` — `zar()` is anchored at the replacement
line, not the population mean; a player's ERA below the population
mean but above the replacement line should have negative `zar_ERA`,
which the original formula gets wrong.

The shipped `test-zar.R` asserts the correct direction (using
`repl_ERA` as the sign reference); the implementation is correct; the
only artifact with the inverted prose is the frozen planner-era spec
copy in the workspace run dir.

**Why no repo change is planned.** The workspace `test-spec.md` is a
historical artifact for the `zar-2026-04-21` run; it is not a
target-repo file and is not read by any future consumer (future runs
read their own fresh `test-spec.md`). Editing a frozen run artifact
after the fact is out of process. Same precedent as Z3 in
`plans/archive/zaa-cleanup.md`.

**If someone wants to surface this.** Open a GitHub issue referencing
[PR #25](https://github.com/JDenn0514/rotostats/pull/25) and link the
paragraph in `review.md`. That's the right place for a corrections log
visible to future readers.

---

## Definition of done (for each scheduled request)

- Feature branch merged to `develop` with clean `R CMD check`
  (0 errors, 0 warnings, only pre-existing notes).
- Run artifacts in
  `~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/runs/<slug>-YYYY-MM-DD/`.
- `NEWS.md` entry for user-visible changes (ZC5, ZC6 qualify; ZC1–ZC4
  are test/sim only, no user-visible behavior change).
- Reviewer verdict: READY_TO_SHIP.
- No new follow-up items left un-triaged in `review.md`.

---

## What this plan intentionally leaves out

- **`pvm()` and `dollar_values()`.** Downstream valuation-family
  functions that consume `zar()`. Track under
  `plans/autoresearch-valuation.md` — not a `zar()` follow-up.
- **`value_plus()`.** Same — downstream consumer, separate scope.
- **Spec-level revisions to `zar()`'s defaults.** If the Wave 2 sim
  work (ZC3/ZC4) surfaces a case where a `zar()` default is
  misleading, file a separate request rather than bundling a default
  change into a cleanup run.
- **`replacement_level()` band-averaging redesign.** The v3 sim
  redefinition of AC-SIM-2 as a band-mean invariant is the correct
  invariant for the existing estimator; it does not imply the
  estimator should change. Any "band-average vs raw boundary"
  redesign lives in `plans/archive/replacement-cleanup.md` territory
  or a dedicated spec run.
- **Latent-ability DGP tuning for AC-SIM-3.** The threshold (0.55)
  was calibrated against realistic MLB year-over-year correlations;
  further tuning to push rho toward 0.85 would require a DGP farther
  from realistic and is not worth pursuing without a methodological
  driver.
