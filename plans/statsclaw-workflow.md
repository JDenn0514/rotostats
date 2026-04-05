# StatsClaw Development Workflow for rotostats

## What statsclaw is

StatsClaw is a Claude Code workflow framework — not an R package or library dependency.
There is no `library(statsclaw)`. It orchestrates a team of specialized AI agents to build,
test, document, and validate statistical software. Think of it as your development process,
not a runtime dependency.

Install instructions: https://github.com/statsclaw/statsclaw

---

## The nine agents and what they do

| Agent | Role | What it produces |
|-------|------|-----------------|
| **Leader** | Orchestrates all other agents; routes natural-language prompts | Dispatches teammates, never does their work directly |
| **Planner** | Turns requirements into two independent specs | `spec.md` (for Builder) and `test-spec.md` (for Tester) |
| **Builder** | Writes R code from `spec.md` only — never sees `test-spec.md` | `implementation.md` + committed code |
| **Tester** | Validates from `test-spec.md` only — never sees `spec.md` | `audit.md` with pass/fail results |
| **Simulator** | Runs Monte Carlo studies from `sim-spec.md` only | Finite-sample diagnostics, bias/variance estimates |
| **Reviewer** | Checks whether Builder and Tester converged | `review.md` with verdict |
| **Scriber** | Writes documentation and architecture notes | roxygen2 docs, vignettes, `ARCHITECTURE.md` |
| **Distiller** | Extracts reusable knowledge from the session | Brain contributions |
| **Shipper** | Commits, pushes, opens PRs | Clean git history |

The key design principle is **adversarial verification**: Builder cannot "teach to the test"
because it never sees `test-spec.md`. Tester cannot be biased by implementation choices
because it never sees `spec.md`. If all pipelines converge independently, confidence is high.

---

## What to hand the Planner for each rotostats function

Every non-trivial function in this package should start with a Planner run. Feed it:

1. **The Q1 conceptual spec** from `specs/spec-[metric-name].md` (produced by the
   `metric-spec-writer` skill) — this tells Planner what the function is supposed to measure
2. **The audit findings** from `plans/sgp-code-audit.md` (or a future equivalent) as
   "must-not-repeat" constraints — these become explicit acceptance criteria
3. **The rewrite checklist** from the audit as the acceptance criteria block in `request.md`

The Planner's job is to translate the conceptual spec into a formal computational spec with
explicit edge case handling, interface contracts, and numerical stability constraints.

---

## Recommended workflow per function

### Phase 1 — Before writing any code
1. Run `metric-spec-writer` (the Claude Code skill in this repo) to produce the Q1 spec
2. Run `roto-code-audit` on any existing Python/R implementation to surface flaws
3. Hand both documents to the statsclaw Planner

### Phase 2 — Implementation
1. Planner produces `spec.md` and `test-spec.md` in isolation
2. Builder implements the R function from `spec.md`
3. Tester independently validates from `test-spec.md`
4. Reviewer checks convergence and issues verdict

### Phase 3 — Simulation validation (for estimator functions)
For functions that implement statistical estimators (SGP denominators, replacement level,
dollar values), add a Simulator run after Phase 2:

- Simulator designs a Monte Carlo study from `sim-spec.md`
- Provides finite-sample properties: bias, variance, coverage of confidence intervals
- Answers questions like "does pairwise_mean converge to the true denominator?" and
  "is the OLS estimator biased in the direction the audit found?"

---

## Starting prompt templates

### Building a new function

```
Build the sgp() function for the rotostats R package.

Reference materials:
- specs/spec-sgp.md        (Q1 conceptual spec)
- plans/sgp-code-audit.md  (audit of prior Python implementation — flaws to avoid)

The function should:
- Accept league standings data and a config list of parameters
- Compute empirical SGP denominators via pairwise_mean as the primary method
- Support optional time-decay weighting and leave-one-year-out cross-validation
- Return a structured list (denominators, year-level diagnostics, bootstrap CIs)
- Be fully parameterized — no hardcoded team counts, budgets, or category lists

Acceptance criteria: [paste rewrite checklist from audit]
```

### Running a simulation study

```
Simulate the finite-sample properties of the SGP pairwise_mean estimator.

Reference: specs/spec-sgp.md (formal definition section)

Questions to answer:
1. Does pairwise_mean converge to the true denominator as n_years increases?
2. Is OLS biased upward relative to pairwise_mean (as the audit suggests)?
3. At n=6 primary years (our calibration window), how wide are the 95% CIs?
4. Does time-decay weighting reduce or increase estimator variance for categories
   with a structural break (SB, 2023)?
```

### Patrolling issues once the package is live

```
Patrol open issues in rotostats and auto-fix any that are in scope.
```

---

## Key invariants for rotostats functions

These constraints must appear in every `spec.md` handed to Builder — they encode the
lessons from the Python audit and should never be violated:

**Parameterization**
- `n_teams`, `scoring_categories`, `roster_slots`, `auction_budget` must all be
  function arguments with no hardcoded defaults from a specific league
- `league_type` (`"AL_only"`, `"NL_only"`, `"mixed"`) must be an explicit argument
  that controls player pool filtering — never implicit in the data

**Denominator computation**
- No in-sample calibration: the validation year must be excluded from calibration data
- Zero-variance categories (all teams tied) must return 0 SGP contribution, not `Inf`
- Near-zero denominator guard: use `abs(denom) < denom_floor` not `denom == 0`
- OLS slope sign must be validated for inverse categories (ERA, WHIP) before `abs()`

**Replacement level**
- Replacement stats must be derived from the projection pool at the roster boundary,
  not from discounted team-level means
- Replacement level must vary by position (C, SS vs. OF, 1B) — no single global threshold
- The replacement level formula for rate stats must match `player_stat_to_sgp()` exactly

**Dollar values**
- Pre-allocate `$1 × n_rostered` before computing `dollars_per_par`
- Use empirical hitter/pitcher spending split, not a hardcoded percentage
- Two-way players (hitter + pitcher) must be deduplicated before dollar allocation

**Data integrity**
- `NaN` in a projection stat field must log a warning — never silently become 0 SGP
- Validate that all `primary_years` exist in the standings data before calibration
- Rate stat denominators (`team_ab`, `team_ip`) must be derived at runtime, not hardcoded

**Testing**
- Every function must be testable in isolation with no file system side effects
- I/O (reading CSVs, writing outputs) must live in separate entry point functions
- `iterrows()`-style loops are not acceptable — all per-player computation must be vectorized

---

## Reference documents in this repo

| Document | Purpose |
|----------|---------|
| `specs/spec-sgp.md` | Q1 conceptual spec for SGP denominator |
| `plans/sgp-code-audit.md` | Full 6-lens audit of Python implementation (~47 findings) |
| `plans/error-messages.md` | Canonical error and warning class names |
| `plans/statsclaw-workflow.md` | This file |

---

## Brain mode

When Brain mode is enabled (`enable brain` in the session), statsclaw agents can read from
a shared community knowledge repository. The `/contribute` command at the end of a session
extracts reusable patterns from the work done and submits them for community review.

For rotostats, the most valuable brain contributions would be:
- SGP denominator estimation: known failure modes and correct implementation patterns
  (derived from `plans/sgp-code-audit.md`)
- Replacement level derivation: why team-mean discounts are wrong and how to use a
  roster-boundary lookup instead
- Rate stat proportional contribution: the mathematical derivation showing why
  `(player_avg - repl_avg) * (player_ab / team_ab) / denom` is correct
