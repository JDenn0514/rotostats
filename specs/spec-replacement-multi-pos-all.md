# Spec: `multi_pos = "all"` mode in `replacement_level()`

> **Status:** Draft · 2026-04-18
> **Parent spec:** `specs/spec-replacement.md`
> **Plan reference:** `plans/replacement-cleanup.md` §"R4 — replacement-multi-pos-all-spec"
> **Scope:** Design doc only. No R code, no tests, no simulation-harness changes. A future
>   Planner agent (separate statsclaw run) will consume this file to produce `spec.md`,
>   `test-spec.md`, and `sim-spec.md` for the implementation.

---

## Assumptions

> **Design assumptions declared here.** These are premises the Planner may rely on without
> further user clarification. Any one of them could be revisited in a future run.

1. The rotostats return-contract convention is a named list. `replacement_level()` always
   returns a named list regardless of `multi_pos`. The "all" mode changes the *type and shape*
   of elements inside the list, not the list wrapper.
2. The zero-sum invariant need only hold over the unique-player domain. When a player is
   eligible at multiple positions, they are allocated fractionally — counted `1/n_eligible`
   toward each eligible position's pool. The invariant is asserted on the fractional sum.
3. Downstream functions (`par()`, `zar()`, `dollar_values()`) are designed to consume the
   `"best"` output shape. They reject `"all"` output with a typed error. Adapters for `"all"`
   are deferred to a future run once the use cases for multi-position comparison are clear.
4. `"all"` mode is exploratory / diagnostic. It is not intended as the default input to the
   valuation pipeline; it is intended for analysts who want to inspect the full
   position-by-position replacement picture before committing to a single assignment.
5. `position_assignments` becomes a named list of character vectors under `"all"` mode (see
   §1.3). This is a backward-incompatible change to the attribute type; callers that inspect
   `attr(result, "position_assignments")` directly should use `multi_pos` as a dispatch key.

---

## 1. Output Shape

### 1.1 Decision

**Long-form tidy data frame.** Under `multi_pos = "all"`, `replacement_stats` is a tidy
data frame with columns:

```
player_id   | character | MLBAM player identifier
position    | character | eligible position (one row per eligible position)
[stat]      | numeric   | replacement-level stat for this (player_id, position) cell
IP          | numeric   | always present for pitcher rows (even if not a scored category)
AB          | numeric   | always present for hitter rows when AVG/OBP in categories
n_band_players | integer | players averaged into this replacement line at this position
cliff_detected | logical | whether cliff detection truncated the band for this position
```

Ineligible `(player_id, position)` pairs are excluded entirely — no NA rows. A player
eligible at `{2B, SS}` produces exactly two rows; a player eligible only at `{C}` produces
one row (same result as `multi_pos = "best"` for that player).

The wrapping return object is still a named list:

```r
list(
  replacement_stats      = <data frame: player_id × position × stat — long form>,
  positional_adjustments = <named numeric vector, or NULL>,
  cliff_metric           = <data frame: position × cliff diagnostics — unchanged>,
  two_way_players        = <character vector — unchanged>,
  pool_diagnostics       = <list — unchanged>,
  method                 = "boundary_band",
  params                 = list(multi_pos = "all", ...)   # multi_pos recorded
)
```

The return list schema is backward-compatible in all elements except `replacement_stats`,
which changes from a position-indexed data frame (one row per position, under `"best"`) to
a player-position-indexed long frame.

### 1.2 Justification

Three concrete trade-offs favor the tidy frame over a 3D array:

**Trade-off 1 — Ineligible-cell representation.**
A 3D array (`player × position × stat`) requires a value for every `(player, position)` cell,
including ineligible pairs. The choices are: fill with `NA` (creates dense missingness that
complicates downstream indexing), fill with a sentinel (misleading), or maintain a logical
eligibility mask alongside the array (extra object). A tidy frame sidesteps this entirely:
ineligible pairs simply have no row. This is consistent with how `projections$pos_eligibility`
is handled throughout the package — eligibility is pipe-delimited and sparse, not a full
position × player matrix.

**Trade-off 2 — Downstream ergonomics.**
The rest of the rotostats ecosystem is built around data frames. `replacement_stats` in
`"best"` mode is already a data frame (position × stat). A long tidy frame in `"all"` mode
is a straightforward extension: adding a `player_id` column and pivoting from wide (one row
per position) to long (one row per player-position). Standard `dplyr::filter()`,
`dplyr::group_by()`, `tidyr::pivot_wider()` operations cover every consumer use case
without array-subscripting syntax. A 3D array would require `aperm()`, three-index
subscripting, and manual `dimnames` management — conventions absent elsewhere in this
codebase.

**Trade-off 3 — Memory and speed.**
Most players are eligible at one position (`n_eligible = 1`). A 3D array with dimensions
`n_players × n_positions × n_stats` is overwhelmingly sparse (most player-position pairs are
NA), wasting memory proportional to `n_players × n_positions`. For a 15-team mixed league
with 500 rostered players and 9 positions, the array would have 500 × 9 = 4500 cells while
the tidy frame has approximately 500 + 120 extra rows (the ~120 multi-eligible players
contributing one additional row each). The long frame is 3–4× smaller in this typical case.

**Rejected option (3D array):** A 3D array is natural when all cells are defined (e.g., a
panel dataset) and consumers want fast positional slicing (`arr[, "SS", ]`). Here neither
condition holds: eligibility is sparse, and the primary consumer operations are
position-group comparisons and per-player row selection — both are well-served by
`dplyr::filter(replacement_stats, position == "SS")` on a tidy frame.

### 1.3 Attribute changes

**`position_assignments` (list-valued under `"all"`):**

Under `multi_pos = "best"`, `attr(result, "position_assignments")` is a named character
vector mapping each player to their single best assignment:

```r
# "best" mode
c(player_A = "SS", player_B = "2B", player_C = "1B", ...)
```

Under `multi_pos = "all"`, each multi-eligible player has multiple valid positions. The
attribute becomes a named list of character vectors:

```r
# "all" mode
list(
  player_A = c("2B", "SS"),
  player_B = c("2B"),
  player_C = c("1B")
)
```

Single-eligible players have a length-1 character vector (not a scalar) for type
consistency: every element of the list is `character(n_eligible)`. This allows generic
dispatch on `attr(result, "position_assignments")` by checking `length(x[[player]]) > 1`
rather than the class of the whole attribute.

**Rationale for list-valued rather than dropping the attribute:**
Dropping `position_assignments` under `"all"` mode would silently break any caller that
reads the attribute without inspecting `params$multi_pos` first. An error or a structured
absence is always preferable to silent NULL. The list-valued form preserves the attribute
contract while conveying the correct semantic: each player has a set of eligible positions,
not a single assignment.

**Other attributes:**

| Attribute | `"best"` shape | `"all"` shape | Change? |
|-----------|---------------|---------------|---------|
| `stat_units` | scalar character | scalar character | None |
| `config` | `league_config` object | `league_config` object | None |
| `projections` | data frame | data frame | None |
| `converged` | scalar logical | scalar logical | None |
| `iterations` | scalar integer | scalar integer | None |
| `delta` | scalar numeric | scalar numeric | None |

`slots_per_position` (inside `params`) remains a named numeric vector indexed by position
name. It does not change shape — it describes the roster configuration, not the player
assignments.

---

## 2. Zero-Sum Invariant Generalization

### 2.1 Background: the `"best"`-mode scalar invariant

Under `multi_pos = "best"`, every player is assigned to exactly one position. The zero-sum
assertion checks that scarcity premiums net to zero across the primary hitter positions
(excluding UTIL, MI, CI combo slots, and — when `catcher_adjustment_method = "split_pool"` —
C):

```
Z_best = sum over p in zero_sum_positions of { slots[p] * scarcity_premium[p] }

assert: abs(Z_best) < 1e-6
```

where `slots[p] = n_teams * roster_slots[p]` is the total number of roster slots at
position `p` league-wide.

This invariant ensures that the total scarcity premium budget balances: positive premiums
at scarce positions (C, SS) are exactly offset by negative premiums at deep positions (OF,
1B). If it fails, the positional adjustment step has a bug.

### 2.2 Why the invariant generalizes non-trivially under `"all"`

Under `"all"` mode, computing `scarcity_premium[p]` requires knowing the replacement-level
player at position `p`. But each multi-eligible player now contributes to multiple position
pools simultaneously. If a 2B/SS player is included in both the 2B pool and the SS pool
with full weight, the effective pool depth at each position is inflated, making both
positions appear less scarce.

The correct treatment is **fractional allocation**: a player eligible at `n_eligible`
positions contributes `1/n_eligible` of their weight to each position's pool. This is the
unique allocation that:

1. Sums to 1.0 across all positions for each player (no double-counting of a player's
   production capacity).
2. Reduces to full weight `1/1 = 1` when `n_eligible = 1` (recovers `"best"` mode).
3. Is distribution-free — requires no knowledge of which position the player "truly" belongs
   at, which is precisely the question `"all"` mode is designed to explore.

### 2.3 Generalized invariant

Define the **fractional slot count** at position `p`:

```
f_slots[p] = sum over players i of { (1 / n_eligible[i]) * I(p in eligible[i]) }
```

where `n_eligible[i]` is the number of eligible positions for player `i`, and
`I(p in eligible[i])` is the indicator that position `p` is one of player `i`'s eligible
positions. Under `multi_pos = "best"`, every player has exactly one assigned position, so
`I(p in eligible[i]) = I(assigned[i] == p)` and `n_eligible[i]` cancels to 1 — the
indicator is 1 for the assigned position and 0 for all others. Thus `f_slots[p]` reduces to
the ordinary `slots[p]` in the `"best"` case, and the invariant reduces identically to the
scalar `"best"` invariant.

The **generalized zero-sum invariant** is:

```
Z_all = sum over p in zero_sum_positions of { f_slots[p] * scarcity_premium[p] }

assert: abs(Z_all) < 1e-5
```

**Tolerance: `1e-5` (loosened from `1e-6`).**

Loosening is justified by fractional arithmetic: `1/n_eligible` introduces rational
denominators that do not represent exactly in IEEE 754 double precision. For a player
eligible at 3 positions, `1/3 = 0.33333...` with a machine epsilon contribution of
approximately `3.7e-17` per operation. Summing over 500 players with up to 3 eligible
positions each (1500 additions), accumulated floating-point error is bounded by
approximately `1500 * 3.7e-17 ≈ 5.6e-14` — negligible. However, intermediate products
(`f_slots[p] * scarcity_premium[p]`) involve multiplications of the fractional counts by
premium values that may be on the order of 1–5 SGP units, lifting the accumulated error
to the `1e-13` range. The tolerance `1e-5` provides a 100× margin above the worst-case
accumulation while being tight enough to catch genuine computation bugs. This mirrors
the `1e-5` precision routinely used in R floating-point assertions for weighted sums.

**Invariant scope — per-position or summed:**

The invariant is asserted only as a **sum** across positions (not per-position). A
per-position assertion would be meaningless: individual `f_slots[p] * scarcity_premium[p]`
terms are not constrained to be zero — only their sum must be. The sum-level assertion is
the minimum diagnostic that catches a broken positional-adjustment step.

**When `catcher_adjustment_method = "split_pool"`:**

The C position is excluded from `zero_sum_positions` regardless of `multi_pos`, following
the same rule as in `"best"` mode. Catcher-eligible multi-eligible players (e.g., a C/1B
player) contribute their `1/n_eligible` fractional weight to each of their positions'
`f_slots`, but the C component is excluded from the sum. The non-C fraction is included
normally.

**Sanity check (n_eligible == 1 for all players):**

When every player has `n_eligible[i] = 1`, `f_slots[p] = slots[p]` for all `p`. The
generalized invariant reduces exactly to:

```
Z_all = sum over p of { slots[p] * scarcity_premium[p] } = Z_best
```

This is the `"best"` scalar invariant. The tolerance loosening from `1e-6` to `1e-5` is
conservative — in the single-eligible case, fractional arithmetic does not occur and the
original `1e-6` tolerance would also pass. The `1e-5` tolerance is chosen to cover the
multi-eligible case; single-eligible inputs pass trivially.

---

## 3. Downstream Function Contracts

### 3.1 `par()`

**Decision: `par()` rejects `"all"` input with a typed error.**

When `attr(replacement, "params")$multi_pos == "all"`, `par()` aborts immediately:

```r
cli::cli_abort(
  c(
    "!" = paste0(
      "{.fn par} requires a single-assignment replacement object ",
      "({.code multi_pos = \"best\"}, {.code \"highest_par\"}, {.code \"primary\"}, ",
      "or {.code \"custom\"}), but received {.code multi_pos = \"all\"}."
    ),
    "i" = paste0(
      "Run {.fn replacement_level} with {.code multi_pos = \"best\"} (or another ",
      "single-assignment mode) before calling {.fn par}."
    )
  ),
  class = "rotostats_error_multi_pos_all_unsupported",
  call = rlang::caller_env()
)
```

**Justification:** `par()` subtracts the replacement-level SGP for `position_of_i` from
each player's SGP (parent spec `spec-par.md` Step 3). This subtraction requires a unique
`position_of_i` for every player. Under `"all"` mode, a player eligible at 2B and SS has
two replacement SGP values — one per eligible position — and no algorithm-defined rule for
which to use without additional context. The two plausible alternatives are:

- *Aggregate using player's max-premium eligible position*: equivalent to re-deriving the
  `"best"` assignment inside `par()`. This silently changes semantics — callers passing
  an `"all"` object to `par()` intending to observe multi-position structure get a
  `"best"` result instead. Rejected: silent semantic change.
- *Return a tall frame with one PAR per (player, position)*: a `par()` result indexed by
  `(player_id, position)` is not a valuation — it is an intermediate diagnostic quantity.
  A player should have exactly one PAR for purposes of auction pricing. Rejected: wrong
  abstraction for `par()`.

The clean contract is to reject `"all"` inputs explicitly. Users who want a per-position
PAR comparison should call `par()` on the `"best"` output, then separately inspect
`replacement_stats` from the `"all"` output.

**The check is defensive, not interactive.** `par()` checks `params$multi_pos` rather
than `class(replacement_stats)` because the shape of `replacement_stats` changes under
`"all"` — a class check on the replacement object is more robust than inspecting data
frame column structure.

### 3.2 `zar()`

**Decision: `zar()` rejects `"all"` input with the same typed error as `par()`.**

`zar()` aborts with `rotostats_error_multi_pos_all_unsupported` when
`attr(replacement, "params")$multi_pos == "all"`, using an identically structured message
with `{.fn zar}` substituted for `{.fn par}`.

**Justification:** `zar()` delegates to `zaa()` and then subtracts the replacement-level
z-score at `position_of_i` (parent spec `spec-zar.md` Step 2–3). Like `par()`, the
subtraction requires exactly one valuation position per player. The same analysis applies:
aggregating by max-premium position silently changes semantics; returning per-position ZAR
is a wrong abstraction for `zar()`. The decision is symmetric with `par()` for consistency.

The `"all"` guard in `zar()` is implemented at the attribute-inspection step (before
calling `zaa()`), so `zaa()` is never called with a mal-formed replacement object.

### 3.3 `dollar_values()`

**Decision: `dollar_values()` rejects `"all"` input with a typed error, using the same
class `rotostats_error_multi_pos_all_unsupported`.**

The error message is:

```r
cli::cli_abort(
  c(
    "!" = paste0(
      "{.fn dollar_values} requires a single-assignment replacement object ",
      "({.code multi_pos = \"best\"}, {.code \"highest_par\"}, {.code \"primary\"}, ",
      "or {.code \"custom\"}), but the {.arg replacement_fn} result has ",
      "{.code multi_pos = \"all\"}."
    ),
    "i" = paste0(
      "Run the iteration loop with {.code multi_pos = \"best\"} (or another ",
      "single-assignment mode). Use {.code multi_pos = \"all\"} separately for ",
      "diagnostic inspection, not as the primary valuation path."
    )
  ),
  class = "rotostats_error_multi_pos_all_unsupported",
  call = rlang::caller_env()
)
```

**Justification:** `dollar_values()` drives the iteration loop and ultimately assigns each
player a single auction dollar value. If a player appears in multiple `(player_id, position)`
rows of `replacement_stats`, the budget-allocation step (Step 2 in `spec-dollar-values.md`)
cannot assign `n_h` (the count of unique rostered hitters) without first resolving the
multi-position structure. Even if `n_h` were resolved correctly by deduplication, the
valuation object passed to `dollar_values()` (a `par()` or `zar()` output) would not be
produced from an `"all"` replacement object — since `par()` and `zar()` already reject it.
The `dollar_values()` guard is thus a defense-in-depth measure that catches callers who
might construct a valuation object by other means.

**Implication for auction-budget zero-sum:** If a multi-eligible player were to receive
multiple dollar values (one per eligible position), they must not be summed in team totals —
each dollar value would represent the same player's contribution from a different positional
assignment, not two independent players. This is precisely the source of confusion the guard
prevents. The single-assignment modes ensure one dollar value per player.

---

## 4. New Error / Warning Classes

### 4.1 `rotostats_error_multi_pos_all_unsupported`

| Field | Value |
|-------|-------|
| **Class** | `rotostats_error_multi_pos_all_unsupported` |
| **Thrown by** | `par()`, `zar()`, `dollar_values()` |
| **Condition** | Function receives a `replacement` object (or a `replacement_fn` result) where `attr(replacement, "params")$multi_pos == "all"` |
| **Recovery guidance** | Call `replacement_level()` with `multi_pos = "best"` (or `"highest_par"`, `"primary"`, or `"custom"`) before calling this function. Use `multi_pos = "all"` only for diagnostic inspection of per-position replacement statistics. |

**Message template (shared across callers, with `{fn}` and `{mode}` substituted):**

```r
cli::cli_abort(
  c(
    "!" = "{.fn {fn}} requires a single-assignment replacement object, but received {.code multi_pos = \"all\"}.",
    "i" = "Re-run {.fn replacement_level} with {.code multi_pos = \"best\"} before calling {.fn {fn}}."
  ),
  class = "rotostats_error_multi_pos_all_unsupported",
  call = rlang::caller_env()
)
```

This class is registered in `plans/error-messages.md` (see §4.3).

### 4.2 No additional classes

The following candidate classes were considered and rejected:

- **`rotostats_error_fractional_sum_tolerance_exceeded`** — The generalized zero-sum
  invariant reuses the existing `rotostats_error_zero_sum_violation` class (already
  registered). The tolerance is loosened to `1e-5` but the class is unchanged. Adding a
  separate class for the `"all"`-mode violation would obscure that both violations represent
  the same logical error (broken positional adjustment step). The error message for
  `"all"` mode should clarify the fractional context:

  ```r
  cli::cli_abort(
    c(
      "!" = "Zero-sum assertion failed for fractional-count positional adjustments.",
      "x" = "|Z_all| = {.val {round(abs(check), 8)}} (tolerance 1e-5).",
      "i" = "This is a computation bug in the positional adjustment step."
    ),
    class = "rotostats_error_zero_sum_violation",
    call = rlang::caller_env()
  )
  ```

- **`rotostats_error_attribute_shape_mismatch`** — The `position_assignments` attribute
  changes shape (scalar character vector → named list) under `"all"` mode. Callers that
  inspect the attribute directly may encounter unexpected structure, but this is a design
  consequence of switching `multi_pos`, not an error condition. No error class is needed;
  the change is documented in §1.3 and in `?replacement_level`.

### 4.3 Registry update

The following row must be added to `plans/error-messages.md` §Errors:

| Class | Thrown by | Condition | Recovery guidance |
|-------|-----------|-----------|-------------------|
| `rotostats_error_multi_pos_all_unsupported` | `par()`, `zar()`, `dollar_values()` | Function receives a replacement object with `params$multi_pos == "all"` | Re-run `replacement_level()` with `multi_pos = "best"` (or another single-assignment mode) before calling this function |

---

## 5. Implementation Steps for a Planner

This section is prescriptive enough to let a Planner generate `spec.md` without consulting
this document further.

### 5.1 `R/replacement.R`

1. **Branch at `multi_pos = "all"`** (new branch in the existing `multi_pos` switch):

   ```r
   if (multi_pos == "all") {
     # Compute replacement stats for every (player, eligible_position) pair
     # Return long-form replacement_stats data frame
     # Set attr(result, "position_assignments") to a named list
   }
   ```

2. **Compute per-position replacement stats for each player:** For each player `i`, iterate
   over all positions in `eligible[i]` (parsed from `projections$pos_eligibility`). For each
   eligible position `p`:
   - Identify the boundary band at position `p` using `n_teams × roster_slots[p]` depth,
     with fractional allocation for multi-eligible players (see §2.3).
   - Apply cliff detection as normal.
   - Compute the band-average stat line at position `p`.
   - Append one row to `replacement_stats` with `player_id = i`, `position = p`, all
     stat columns, `n_band_players`, and `cliff_detected`.

3. **Fractional allocation for band construction:** When building the pool of players
   eligible at position `p` for the purpose of identifying the boundary rank, count each
   player eligible at multiple positions as `1/n_eligible`. Sort by composite score as
   normal; the boundary depth is `n_teams × roster_slots[p]` fractional units.

4. **Zero-sum assertion:** After computing positional adjustments, evaluate the generalized
   invariant `abs(Z_all) < 1e-5`. Abort with `rotostats_error_zero_sum_violation` on
   failure (see §4.2 for message template).

5. **Attribute assignment:**

   ```r
   attr(result, "position_assignments") <- lapply(
     split_eligibility_by_player,   # named list: player_id → character vector
     identity
   )
   ```

### 5.2 `R/par.R`

At the start of `par()`, before any computation:

```r
if (isTRUE(attr(replacement, "params")$multi_pos == "all")) {
  cli::cli_abort(
    c(
      "!" = "{.fn par} requires a single-assignment replacement object, ...",
      "i" = "Re-run {.fn replacement_level} with {.code multi_pos = \"best\"}."
    ),
    class = "rotostats_error_multi_pos_all_unsupported",
    call = rlang::caller_env()
  )
}
```

### 5.3 `R/zar.R`

Identical guard at the start of `zar()`, substituting `par` → `zar` in the message.

### 5.4 `R/dollar_values.R`

The guard in `dollar_values()` fires when the `replacement_fn` result has
`params$multi_pos == "all"`. Since `par()` and `zar()` already guard, this fires only if
the caller bypasses those functions or supplies a directly-constructed replacement object.

### 5.5 Test-spec guidance (for the Planner)

Minimum test scenarios:

| ID | Description |
|----|-------------|
| TS-all-1 | Happy path: 12-team mixed league, 3 multi-eligible players (2B/SS, 1B/3B, OF/1B) — `replacement_stats` is a long data frame with correct row count, no NA stat values, `position` column contains only eligible positions |
| TS-all-2 | Single-eligible players produce exactly one row each; multi-eligible players produce `n_eligible` rows |
| TS-all-3 | Generalized zero-sum invariant holds: `abs(Z_all) < 1e-5` |
| TS-all-4 | Sanity check: when all players have `n_eligible = 1`, `replacement_stats` from `"all"` mode matches `replacement_stats` from `"best"` mode (modulo row order and `player_id` column presence) |
| TS-all-5 | `attr(result, "position_assignments")` is a named list; single-eligible players have length-1 character vectors; multi-eligible players have `n_eligible`-length vectors |
| TS-all-6 | `par()` aborts with `rotostats_error_multi_pos_all_unsupported` when called with an `"all"` replacement object |
| TS-all-7 | `zar()` aborts with `rotostats_error_multi_pos_all_unsupported` when called with an `"all"` replacement object |
| TS-all-8 | `dollar_values()` aborts with `rotostats_error_multi_pos_all_unsupported` when called with a replacement object built from `multi_pos = "all"` |
| TS-all-9 | `rotostats_error_zero_sum_violation` fires when a synthetic fractional positional adjustment sum violates `1e-5` |
| TS-all-10 | Catcher exclusion: when `catcher_adjustment_method = "split_pool"`, C rows appear in `replacement_stats` but C is excluded from the zero-sum assertion |

### 5.6 Sim-spec guidance (for the Planner)

A sim-spec is optional for this feature but recommended:

- **Study A-all**: Sanity check — in a league where all players have `n_eligible = 1`,
  `replacement_stats` under `"all"` matches `replacement_stats` under `"best"` to within
  `1e-10` across all stat columns. Monte Carlo `R = 200` simulated projection draws; verify
  zero mismatches.
- **Study B-all**: Fractional-count zero-sum — in a league where 20% of players are
  multi-eligible (uniform 2-position eligibility), `abs(Z_all) < 1e-5` holds across
  `R = 500` draws. MC SE on pass rate should be < 0.5%.
- **Study C-all**: `position_assignments` list-structure is complete — every `player_id` in
  `projections` appears as a key in `attr(result, "position_assignments")`, across `R = 200`
  draws with varying eligibility profiles.

---

## 6. Known Validity Threats

**1. Fractional allocation inflates pool depth at popular positions.**
A 2B/SS player counted at `0.5` for 2B and `0.5` for SS reduces apparent scarcity at both
positions relative to a player assigned to one. In a league where many players have 2B/SS
eligibility, fractional counting makes both positions look moderately deeper than they are.
The `"best"` mode avoids this by committing to a single assignment; the `"all"` mode
acknowledges the ambiguity explicitly. Users should treat `"all"` output as a diagnostic
(what would replacement level be at each position if this player could fill that slot?) not
as a joint model (this player simultaneously contributes to two positions' pools).

**2. Cliff detection may behave differently under fractional allocation.**
The band is assembled from fractionally-counted players, which means the effective band at
position `p` may include partial contributions from multi-eligible players whose "full"
ranking contribution is spread across positions. The `n_band_players` column in
`replacement_stats` reflects the integer count of players physically in the band, not the
fractional sum. This distinction is noted in output but not corrected — the integer count is
more interpretable to users.

**3. The `"all"` output cannot be fed to the iteration loop in `dollar_values()`.**
The iteration loop converges by comparing `position_assignments` across passes. A list-valued
`position_assignments` is incompatible with the scalar comparison logic
(`all(new_assignment == old_assignment)`) in the parent spec §"Convergence criterion".
The `dollar_values()` guard enforces this. If a future run adds iteration support for
`"all"` mode, it must define a new convergence criterion (e.g., element-wise list comparison).

**4. `stat_units` attribute semantics are unchanged.**
The `stat_units` attribute is still `"raw_projected"` or `"full_season_normalized"` — it
applies to all rows of the long `replacement_stats` frame equally. No per-row `stat_units`
is tracked.

---

## 7. Interface Snapshot

The `replacement_level()` signature is unchanged. No new top-level arguments are added by
this mode. The `multi_pos = "all"` branch is controlled entirely by the existing `multi_pos`
parameter.

For reference, the `multi_pos = "all"` enumeration already appears in the parent spec:

```r
# multi_pos = "all": Compute separate replacement-level comparisons for every
# eligible position. replacement_stats output shape changes to player × position × stat.
```

This spec refines that single sentence into the full design above.

**`params` list under `"all"` mode:**

The `params` element of the return list records `multi_pos = "all"` so all downstream
guards can check `params$multi_pos` without inspecting the structure of `replacement_stats`:

```r
params = list(
  multi_pos      = "all",    # NEW — always recorded (was previously not in params)
  converged      = TRUE,
  iterations     = <integer>,
  delta          = <numeric>,
  n_teams        = <integer>,
  roster_slots   = <named integer vector>,
  band_width     = <integer>,
  cliff_threshold = <numeric>,
  sort_by        = <character>,
  stat_units     = <character>,
  ...
)
```

**Note for the Planner:** `multi_pos` must be recorded in `params` for ALL modes (not just
`"all"`), so that `par()`, `zar()`, and `dollar_values()` can reliably check
`params$multi_pos` regardless of which mode was used. If `multi_pos` is not currently in
`params` (it is not listed in the parent spec §Outputs), the builder must add it. This is a
backward-compatible addition — no existing code reads `params$multi_pos` today.

---

*Written by Scriber — replacement-multi-pos-all-spec-2026-04-18*
