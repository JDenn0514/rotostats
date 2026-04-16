# StatsClaw Development Workflow for rotostats

## What statsclaw is

StatsClaw is a Claude Code **plugin** that orchestrates a team of 9 specialized AI agents
to build, test, document, and validate statistical software. There is no `library(statsclaw)`.
It is your development process, not a runtime dependency.

**Install:** `claude plugin install https://github.com/statsclaw/statsclaw`

What the plugin drops into your project:

- `CLAUDE.md` — orchestration policy (authoritative reference)
- `agents/` — 9 agent definitions
- `skills/` — shared protocol skills (credential-setup, isolation, handoff, mailbox,
  issue-patrol, profile-detection, brain-sync, privacy-scrub)
- `profiles/` — language-specific execution rules (R, Python, Julia, Stata, TypeScript,
  Go, Rust, C, C++)
- `templates/` — runtime artifact templates and repo scaffolding

Agent Teams is enabled at the project level via `.claude/settings.json`.

---

## The nine agents and what they do

| Agent | Role | What it produces |
|-------|------|-----------------|
| **Leader** | Orchestrates all agents; dispatches teammates, never does their work | Routing and coordination |
| **Planner** | Reads formulas/specs, runs deep comprehension protocol, produces dual specs | `spec.md` + `test-spec.md` + (optionally) `sim-spec.md` |
| **Builder** | Writes source code from `spec.md` only — never sees `test-spec.md` | `implementation.md` + committed code |
| **Tester** | Validates from `test-spec.md` only — never sees `spec.md` | `audit.md` with pass/fail results |
| **Simulator** | Runs Monte Carlo studies from `sim-spec.md` only — runs in parallel with Builder | `simulation.md` with finite-sample diagnostics |
| **Reviewer** | Cross-checks all pipelines, audits tolerance integrity, issues ship/no-ship verdict | `review.md` |
| **Scriber** | Writes documentation, generates architecture notes, maintains audit trail | roxygen2 docs, vignettes, `ARCHITECTURE.md` |
| **Distiller** | Extracts reusable knowledge for the shared brain *(brain mode only)* | `brain-contributions.md` |
| **Shipper** | Commits, pushes, opens PRs | Clean git history |

The key design principle is **adversarial verification**: Builder and Simulator run in
parallel from separate specs and never see each other's work. Tester validates the merged
result independently. If all pipelines converge, confidence is high.

---

## Multi-pipeline architecture

```
                      planner (bridge)
                     /    |          \
          spec.md   / test-spec.md    \  sim-spec.md
                   /      |            \
            builder ─ ─(parallel)─ ─ simulator
       (code pipeline)    |    (simulation pipeline)
                   \      |            /
      implementation.md   |   simulation.md
                    \     |          /
                     \    v         /
                       tester           <-- sequential, after merge-back
                    (test pipeline)
                         |
                      audit.md
                         |
                    scriber → distiller? → reviewer → shipper?
```

### Workflow variants

| Variant | Agent chain |
|---------|-------------|
| **Code** | leader → planner → builder → tester → scriber → [distiller] → reviewer → shipper? |
| **Docs-only** | leader → planner → scriber → reviewer → shipper? |
| **Simulation + Code** | leader → planner → [builder ∥ simulator] → tester → scriber → [distiller] → reviewer → shipper? |
| **Simulation-only** | leader → planner → simulator → tester → scriber → [distiller] → reviewer → shipper? |

### State machine

```
CREDENTIALS_VERIFIED → NEW → PLANNED → SPEC_READY → PIPELINES_COMPLETE
  → DOCUMENTED → [KNOWLEDGE_EXTRACTED]? → REVIEW_PASSED → READY_TO_SHIP → DONE
```

Signals: `HOLD` (ambiguous, ask user) · `BLOCK` (validation failed) · `STOP` (unsafe to ship)

---

## Workspace repository

Workflow logs, process records, and handoff documents are **not** stored in target repos.
They are synced to a separate **workspace repository** on GitHub. This keeps rotostats
clean (code + essential docs only) while preserving full traceability.

Per-run artifacts in the workspace repo:

```
workspace/
└── rotostats/
    ├── CHANGELOG.md       # timeline index of all runs
    ├── HANDOFF.md         # active handoff
    ├── ref/               # reference docs for future work
    └── runs/
        └── <request-id>/
            ├── request.md         # scope and acceptance criteria
            ├── comprehension.md   # planner's comprehension verification
            ├── spec.md            # code pipeline input
            ├── test-spec.md       # test pipeline input
            ├── sim-spec.md        # simulation pipeline input (if applicable)
            ├── implementation.md  # builder output
            ├── simulation.md      # simulator output (if applicable)
            ├── audit.md           # tester output
            ├── review.md          # reviewer verdict
            └── shipper.md         # ship actions
```

---

## Where rotostats currently is in the workflow

**Pre-build phase (current):** Conceptual frameworks are being written for each function
using the `metric-spec-writer` skill. These produce `specs/spec-[function].md` files.

The statsclaw Planner reads these specs and translates them into formal computational
specifications (`spec.md`, `test-spec.md`) before any code is written. The pipeline:

```
metric-spec-writer → specs/spec-[fn].md   (conceptual spec, human-readable)
                          ↓
              statsclaw Planner           (reads spec + audit findings)
                          ↓
          spec.md + test-spec.md          (formal computational specs)
                          ↓
         builder ∥ simulator → tester     (adversarial verification)
```

---

## What to hand the Planner for each rotostats function

Every non-trivial function should start with a Planner run. Feed it:

1. **The conceptual spec** from `specs/spec-[function].md` — what the function measures
2. **The audit findings** from `plans/sgp-code-audit.md` (or equivalent) as
   "must-not-repeat" constraints — these become explicit acceptance criteria
3. **The key invariants** from this document's invariants section below

---

## Recommended workflow per function

### Phase 0 — Conceptual framework (current phase)
1. Run `metric-spec-writer` skill to produce the Q1 conceptual spec in `specs/`
2. Run `roto-code-audit` on any existing Python/R implementation to surface flaws

### Phase 1 — Planner
1. Hand the conceptual spec + audit findings to statsclaw
2. Planner produces `spec.md` and `test-spec.md` in isolation (and `sim-spec.md` for
   estimator functions)

### Phase 2 — Implementation
1. Builder implements the R function from `spec.md`
2. For estimator functions: Simulator runs in parallel from `sim-spec.md`
3. Tester independently validates from `test-spec.md` after both complete
4. Reviewer checks convergence and issues ship/no-ship verdict

### Phase 3 — Simulation validation (estimator functions only)
For functions that implement statistical estimators (SGP denominators, replacement level,
dollar values), the Simulator addresses:

- Does `pairwise_mean` converge to the true denominator as `n_years` increases?
- Is OLS biased upward relative to `pairwise_mean` (as the audit found)?
- At n=6 primary years, how wide are the 95% CIs?
- Does time-decay weighting reduce or increase estimator variance for structural-break
  categories (SB, 2023)?

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
- Compute SGP denominators via OLS regression as the primary method (`denominator_method = "ols"`)
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

### Issue patrol (once package is live)

```
Patrol open issues in rotostats and auto-fix any that are in scope.
```

---

## Key invariants for rotostats functions

These constraints must appear in every `spec.md` handed to Builder — they encode the
lessons from the Python audit and must never be violated.

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
- No `iterrows()`-style loops — all per-player computation must be vectorized

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

When Brain mode is enabled at session start, statsclaw agents read from the shared
[`statsclaw/brain`](https://github.com/statsclaw/brain) repository and can access
knowledge contributed by all users.

After noteworthy workflows, the Distiller agent extracts reusable knowledge. Nothing is
shared without your explicit consent — you review and approve each contribution. The
`/contribute` command also lets you manually summarize lessons learned.

**Privacy:** All contributions are automatically scrubbed of repo names, file paths,
usernames, and proprietary code before submission.

For rotostats, the most valuable brain contributions would be:
- SGP denominator estimation: known failure modes and correct implementation patterns
- Replacement level derivation: why team-mean discounts are wrong and how to use a
  roster-boundary lookup instead
- Rate stat proportional contribution: the mathematical derivation showing why
  `(player_avg - repl_avg) * (player_ab / team_ab) / denom` is correct
