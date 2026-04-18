# Spec: `boundary_rate_method = "sgp_pool"` in `replacement_level()`

> **Status:** Draft · 2026-04-18
> **Parent spec:** `specs/spec-replacement.md`
> **Plan reference:** `plans/replacement-cleanup.md` §"R3 — replacement-sgp-pool-rate-spec"
> **Registers new error classes:** `rotostats_error_missing_rate_conversion_attr`,
>   `rotostats_error_sgp_pool_degenerate`, `rotostats_error_sgp_pool_sort_mismatch`.
>   `rotostats_error_rate_method_mismatch` is pre-registered on `develop`
>   (introduced alongside the parent-spec reference at
>   `specs/spec-replacement.md:173`); documented here for completeness, not
>   re-registered.

---

## Purpose

This document specifies the full implementation of `boundary_rate_method = "sgp_pool"` in
`replacement_level()`. It is a companion design doc to the parent spec. A Planner agent
consuming this file, along with the parent spec, should be able to derive `spec.md`,
`test-spec.md`, and `sim-spec.md` for an implementation run without further user input.

The `"sgp_pool"` method implements Todd Zola's SGP fixed-baseline-pool approach (Smart
Fantasy Baseball). Instead of weighting a pitcher's rate-stat quality by raw IP alone, it
computes the **marginal change in the pool's combined rate stat** caused by adding that
pitcher to the N−1 other rostered players at the same position. This converts a pitcher's
ERA/WHIP quality into standings-point units that are directly comparable across league sizes,
roster configurations, and projection vintages.

---

## 1. Interaction with `attr(sgp_denominators, "rate_conversion")`

### 1.1 Guard: `"fixed_baseline"` is incompatible

**This guard is a hard requirement and must not be weakened or made conditional.**

When `boundary_rate_method = "sgp_pool"` and `sgp_denominators` are supplied,
`replacement_level()` reads `attr(sgp_denominators, "rate_conversion")` immediately after
the standard input-validation block (before any ranking computation).

If the attribute value is `"fixed_baseline"`, the function aborts:

```r
cli::cli_abort(
  c(
    "!" = paste0(
      "{.arg boundary_rate_method} = {.val sgp_pool} requires denominators ",
      "calibrated with {.val rate_conversion = \"blended_pool\"}, but the ",
      "supplied {.arg sgp_denominators} used {.val rate_conversion = \"fixed_baseline\"}."
    ),
    "i" = paste0(
      "These denominator types are incompatible: {.val fixed_baseline} denominators ",
      "are expressed in counting-equivalent ExER/ExWH/ExH units, whereas ",
      "{.val sgp_pool} ranking requires pool-blended units."
    ),
    "i" = "Remedies:",
    "*" = paste0(
      "Re-run {.fn sgp_denominators} with {.code rate_conversion = \"blended_pool\"} ",
      "(the default)."
    ),
    "*" = "Or switch to {.code boundary_rate_method = \"raw_ip\"}."
  ),
  class = "rotostats_error_rate_method_mismatch",
  call = rlang::caller_env()
)
```

**Why the incompatibility is fundamental:**

`"fixed_baseline"` denominators are calibrated against a fixed counting-stat equivalent.
They express rate-stat standings contributions as if each pitcher had delivered a reference
IP total (the `fixed_baseline`). The `"sgp_pool"` method, by contrast, computes a pitcher's
marginal contribution to the actual combined-pool ERA/WHIP, which requires pool-blended
units: the denominator must reflect how one additional IP of quality `q` shifts the pool
ERA given the pool's current aggregate IP. Applying a `"fixed_baseline"` denominator here
overstates the marginal contribution of high-IP pitchers and understates low-IP pitchers,
because the conversion assumes a reference IP total rather than the pool's actual combined IP.

### 1.2 Supported path: `"blended_pool"` denominators

When `attr(sgp_denominators, "rate_conversion") == "blended_pool"`, the `"sgp_pool"`
ranking method is valid.

**What `"blended_pool"` means (from `plans/sgp-denominators-architecture.md`):**

`"blended_pool"` denominators are calibrated such that the denominator for ERA and WHIP
reflects the expected change in standings position from shifting the combined pool ERA/WHIP
by one unit. That is, they answer the question: "if the league's combined pitcher pool ERA
drops by 1.00 (from, say, 4.00 to 3.00), how many standings places does that shift
represent?" This is precisely what the `"sgp_pool"` ranking method needs: a conversion
factor from delta-pool-ERA to SGP units.

### 1.3 Guard: missing `rate_conversion` attribute

If `sgp_denominators` is supplied but `attr(sgp_denominators, "rate_conversion")` is
`NULL` (i.e., the attribute is absent), `replacement_level()` aborts:

```r
cli::cli_abort(
  c(
    "!" = paste0(
      "The {.arg sgp_denominators} object is missing the {.code rate_conversion} ",
      "attribute required by {.arg boundary_rate_method} = {.val sgp_pool}."
    ),
    "i" = paste0(
      "Supply a denominator object built by {.fn sgp_denominators} ",
      "(which attaches {.code rate_conversion} automatically), or set the ",
      "attribute manually: ",
      "{.code attr(sgp_denominators, \"rate_conversion\") <- \"blended_pool\"}."
    )
  ),
  class = "rotostats_error_missing_rate_conversion_attr",
  call = rlang::caller_env()
)
```

This guard fires before the `"fixed_baseline"` check. The full check order
(matching Step A in §6) is:

1. Is `sgp_denominators` NULL when `boundary_rate_method = "sgp_pool"`? → existing
   `rotostats_error_missing_sgp_denominators` (registered in parent spec).
2. Is `sort_by == "zscore"` when `boundary_rate_method = "sgp_pool"`? →
   `rotostats_error_sgp_pool_sort_mismatch` (new — §5 below). See §4.4 for
   rationale.
3. Is `attr(sgp_denominators, "rate_conversion")` absent? →
   `rotostats_error_missing_rate_conversion_attr` (new — §5 below).
4. Is `attr(sgp_denominators, "rate_conversion") == "fixed_baseline"`? →
   `rotostats_error_rate_method_mismatch` (already registered on `develop`;
   see §5 below).

---

## 2. Pool Composition at the Boundary

### 2.1 Canonical definition: the N−1 rostered-player pool

For a given position `pos`, the SGP pool used in ranking is the set of the **N−1 other
rostered players at that position**, where N is the total number of rostered players at
`pos` under current position assignments:

```
N = n_teams × roster_slots[pos]
```

The pool for pitcher `i` is the remaining N−1 pitchers rostered at `pos` (all pitchers
assigned to `pos` under current `position_assignments`, excluding pitcher `i`). The
marginal rate contribution of pitcher `i` is:

```
marginal_ERA_i  = pool_ERA(N−1 others ∪ {i})  − pool_ERA(N−1 others)
marginal_WHIP_i = pool_WHIP(N−1 others ∪ {i}) − pool_WHIP(N−1 others)
```

This is the Zola formulation referenced in the parent spec at line 165:

> "The other N−1 rostered pitchers form the baseline pool; a pitcher's ERA contribution is
> the marginal change in the pool's combined ERA/WHIP from adding that pitcher."

This canonical choice is adopted without modification.

**Why N−1 rostered players, not band members or all players:**

- **Band members only:** The band (2K+1 players around the boundary) is a smoothing device
  for the replacement-level stat line, not a representation of the rostered pool. Using only
  band members produces a marginal contribution estimate that depends heavily on band width K,
  introducing a parameter sensitivity that `"sgp_pool"` is designed to eliminate. Rejected.

- **All projection-pool players:** The projection pool includes sub-replacement players who
  will not be rostered. Including them in the baseline pool understates the quality of the
  actual rostered pool and systematically inflates the marginal value of above-replacement
  pitchers. Rejected.

- **All rostered pitchers league-wide (SP + RP together):** SP and RP have incomparable rate
  stats (ERA/WHIP distributions differ substantially; relief pool ERA is structurally lower
  than starter pool ERA). Mixing them in a single pool produces an incoherent combined ERA.
  The parent spec's SP/RP separation applies here. Rejected.

- **N−1 rostered players at `pos` (Zola/canonical):** This is the self-consistent choice.
  The pool whose ERA/WHIP the ranking method seeks to shift is precisely the set of rostered
  pitchers at `pos`. Each pitcher's marginal contribution is computed against the pool they
  would actually join. Correct pool-size sensitivity: a pitcher's marginal value is smaller
  in a deeper pool (more rostered pitchers dilute the impact of any single pitcher), which
  correctly reflects the economics of a larger league or a deeper roster spot. **Adopted.**

### 2.2 Pool construction under iteration

On pass 1 (`position_assignments = NULL`), the N−1 pool is derived from the seed
assignments produced by `seed_method`. On subsequent passes, `position_assignments`
(supplied by `dollar_values()`) determines pool membership. The pool changes between passes
as multi-eligible players shuffle positions; this is handled by the existing iteration loop
in `dollar_values()` and requires no special logic inside `replacement_level()`.

### 2.3 Weighting within pool: IP-weighted for ERA/WHIP, AB-weighted for AVG

The combined pool ERA/WHIP is the IP-weighted mean of the N−1 pool members. This is not
an arbitrary choice — IP weighting is the natural consequence of the marginal-pool formula
(see §3.1). No additional weighting parameter is introduced. Uniform weighting is
incorrect because a low-IP relief appearance counts the same as a full-season starter
start under uniform weighting, dramatically overstating each reliever's marginal impact.

For AVG, the pool is AB-weighted: pool AVG = sum(H) / sum(AB) across pool members. This
is algebraically equivalent to the `"raw_ip"` AB-weighted AVG formula and is unchanged
(see §4.3).

### 2.4 Degenerate pool guard

If a position's rostered pool has fewer than 2 players (i.e., N < 2, so the N−1 pool is
empty), the marginal formula is undefined. `replacement_level()` aborts:

```r
cli::cli_abort(
  c(
    "!" = paste0(
      "Position {.val {pos}} has fewer than 2 rostered players ",
      "({n_rostered} found); the {.val sgp_pool} marginal-rate formula ",
      "requires at least 2 players to form the N\u22121 baseline pool."
    ),
    "i" = "Check {.arg n_teams} and {.arg roster_slots}.",
    "i" = paste0(
      "If this position genuinely has only 1 roster slot (e.g., C in a ",
      "1-catcher league), use {.code boundary_rate_method = \"raw_ip\"} instead."
    )
  ),
  class = "rotostats_error_sgp_pool_degenerate",
  call = rlang::caller_env()
)
```

This guard fires per-position, so a degenerate C pool in a 1-catcher league does not
prevent computation for SP/RP/other positions. Implementation note: the check runs after
pool membership is determined from `position_assignments` (or the pass-1 seed), not from
`n_teams × roster_slots` directly, because multi-position spillover can reduce effective
pool size below the theoretical count.

---

## 3. Conversion Formula: Marginal Pool Contribution to SGP Units

### 3.1 ERA and WHIP (IP-weighted rate stats)

**Combined pool ERA with N−1 players:**

```
pool_ERA(N−1) = sum(ER_j,  j in pool) / sum(IP_j, j in pool)
             = (sum(IP_j × ERA_j, j in pool)) / sum(IP_j, j in pool)
```

where `ER_j = IP_j × ERA_j / 9` is converted to earned runs per 9 IP so the formula is
in consistent ERA units. In practice, using `IP_j × ERA_j` in the numerator and then
dividing by `sum(IP_j)` returns ERA directly:

```
pool_ERA(N−1) = sum(IP_j × ERA_j / 9, j in pool) × 9 / sum(IP_j, j in pool)
             = sum(IP_j × ERA_j, j in pool) / sum(IP_j, j in pool)
```

**Marginal ERA contribution of pitcher i:**

Let `IP_pool = sum(IP_j, j in pool)` and `WtERA_pool = sum(IP_j × ERA_j, j in pool)`.

```
pool_ERA(N−1 ∪ {i}) = (WtERA_pool + IP_i × ERA_i) / (IP_pool + IP_i)

marginal_ERA_i = pool_ERA(N−1 ∪ {i}) − pool_ERA(N−1)
              = (WtERA_pool + IP_i × ERA_i) / (IP_pool + IP_i)
                  − WtERA_pool / IP_pool
```

Simplifying:

```
marginal_ERA_i = IP_i × (ERA_i − pool_ERA(N−1)) / (IP_pool + IP_i)
```

Note that `marginal_ERA_i < 0` when `ERA_i < pool_ERA(N−1)` — the pitcher improves the
pool. This is the correct sign for an inverse category.

**Ranking contribution (ERA):**

```
ERA_contribution_i = −marginal_ERA_i × d_ERA
                   = −[IP_i × (ERA_i − pool_ERA(N−1)) / (IP_pool + IP_i)] × d_ERA
```

where `d_ERA = sgp_denominators[["ERA"]]` is the `"blended_pool"` denominator in
pool-ERA units per standings place. The negation converts the inverse category
(lower ERA is better) to a positive ranking contribution.

For higher-ERA pitchers: `marginal_ERA_i > 0` → `ERA_contribution_i < 0` (negative
ranking signal — hurts the team).

For lower-ERA pitchers: `marginal_ERA_i < 0` → `ERA_contribution_i > 0` (positive
ranking signal — helps the team).

**WHIP is fully analogous:**

```
marginal_WHIP_i = IP_i × (WHIP_i − pool_WHIP(N−1)) / (IP_pool + IP_i)

WHIP_contribution_i = −marginal_WHIP_i × d_WHIP
                    = −[IP_i × (WHIP_i − pool_WHIP(N−1)) / (IP_pool + IP_i)] × d_WHIP
```

where `pool_WHIP(N−1) = sum(IP_j × WHIP_j, j in pool) / sum(IP_j, j in pool)`.

### 3.2 Composite SGP ranking contribution

For each pitcher `i`, the `"sgp_pool"` composite ranking score is the sum of per-category
SGP contributions:

```
score_i = sum over counting stats c: (stat_i[c] − repl_stat[c]) / d[c]
        + ERA_contribution_i
        + WHIP_contribution_i
```

The counting-stat terms are identical to their treatment under `"raw_ip"` and `"zscore"`
ranking — they do not change (see §4.2). Only the ERA and WHIP terms differ between
`"sgp_pool"` and `"raw_ip"`.

### 3.3 Sign convention check

After computing `ERA_contribution_i` and `WHIP_contribution_i` for each pitcher, assert:

```
sign(ERA_contribution_i) == sign(pool_ERA(N−1) − ERA_i)
```

If this assertion fails for more than 5% of pitchers in the pool, emit
`rotostats_warning_unexpected_slope_sign` (already registered for `sgp_denominators()`;
reused here since the root cause — inverted denominator sign — is identical). This is a
diagnostic guard against a denominator object that was constructed with the wrong slope
direction.

**Registry update at implementation time:** when this guard is implemented,
update the `Thrown by` column of `rotostats_warning_unexpected_slope_sign` in
`plans/error-messages.md` to also list `replacement_level()`. The registry
currently names only `sgp_denominators()` — reflecting code that exists today,
not specs that do not yet have callers. Do not pre-update the registry before
the call site lands.

### 3.4 Relationship between `"sgp_pool"` and `"raw_ip"` formulas

The `"raw_ip"` formula for ERA ranking is:

```
ERA_contribution_raw_ip_i = (repl_ERA − ERA_i) × IP_i
```

The `"sgp_pool"` formula is:

```
ERA_contribution_sgp_pool_i = −[IP_i × (ERA_i − pool_ERA(N−1)) / (IP_pool + IP_i)] × d_ERA
```

These have the same sign when `pool_ERA(N−1) ≈ repl_ERA` (which is true near convergence,
since the replacement-level pitcher is drawn from the boundary band). The key differences:

- `"raw_ip"` scales by `IP_i` only; `"sgp_pool"` scales by `IP_i / (IP_pool + IP_i)`, which
  is a shrinkage toward zero as the pool grows — a high-IP ace adds less marginal ERA
  quality in a deep 15-team league than in a shallow 10-team league.
- `"sgp_pool"` converts directly to SGP units via `d_ERA`; `"raw_ip"` produces raw
  IP × ERA units that are not directly comparable across categories without further
  z-score normalization.

---

## 4. Relationship to `"raw_ip"` Mode

### 4.1 `"sgp_pool"` replaces ERA/WHIP ranking contributions entirely

`"sgp_pool"` is not a layer on top of `"raw_ip"`. When `boundary_rate_method = "sgp_pool"`,
the ERA and WHIP ranking contributions computed by the `"raw_ip"` formula (parent spec
lines 158–161) are **not computed**. They are replaced by the marginal-pool formula in §3.1.

The implementation switch point is the ranking composition step — the point at which
per-player composite scores are assembled before sorting. At that step, the
`boundary_rate_method` switch selects one of two paths:

```
if (boundary_rate_method == "raw_ip") {
  # parent spec lines 158–161
  era_term  <- (repl_ERA  − pitcher_ERA)  * pitcher_IP
  whip_term <- (repl_WHIP − pitcher_WHIP) * pitcher_IP
} else if (boundary_rate_method == "sgp_pool") {
  # §3.1 above
  era_term  <- ERA_contribution_i   # already in SGP units
  whip_term <- WHIP_contribution_i  # already in SGP units
}
```

### 4.2 Counting stats: unchanged under `"sgp_pool"`

HR, R, RBI, SB, W, SV, K (and any other counting category) are not affected by
`boundary_rate_method`. Their ranking contributions are:

```
counting_contribution_i[c] = (stat_i[c] − repl_stat[c]) / d[c]
```

This formula is identical under both `"raw_ip"` and `"sgp_pool"`. The denominator `d[c]`
comes from `sgp_denominators`, which is required when `boundary_rate_method = "sgp_pool"`
(the `rotostats_error_missing_sgp_denominators` guard already enforces this).

Under `"raw_ip"`, counting stats use z-score-based composite ranking (no denominator needed
when `sort_by = "zscore"`). When `sort_by = "sgp"` and `boundary_rate_method = "raw_ip"`,
counting stats also use `d[c]`. The `"sgp_pool"` method always requires `sort_by = "sgp"`
as a logical precondition (see §4.4).

### 4.3 AVG: AB-weighted aggregation unchanged

The `sum(H) / sum(AB)` formula for AVG aggregation across band players (parent spec
line 39 and line 162) is unchanged under `"sgp_pool"`. This applies to the
**replacement-level stat line** (band aggregate), not to the player ranking contributions.
For ranking, AVG is a counting-equivalent stat under the `"sgp_pool"` method: the
AB-weighted marginal AVG contribution of player `i` is:

```
marginal_AVG_i = AB_i × (player_AVG_i − pool_AVG(N−1)) / (AB_pool + AB_i)
AVG_contribution_i = marginal_AVG_i × d_AVG
```

where `pool_AVG(N−1) = sum(H_j, j in pool) / sum(AB_j, j in pool)` (the N−1 pool's
aggregate batting average), and `d_AVG = sgp_denominators[["AVG"]]`.

This is fully analogous to the ERA/WHIP formulas above, applied to a normal (not inverse)
category. AVG is not a rate stat in the `RATE_STAT_DENOMINATORS` lookup for purposes of
this spec — it is handled via the same marginal-pool formula as ERA/WHIP because it is
denominator-dependent (batting average is inherently a ratio of H / AB).

**Scope of the marginal-pool formula for hitters:**

For hitters, apply the marginal-pool formula to AVG (and OBP, SLG, OPS, wOBA, and any
other rate stat in `RATE_STAT_DENOMINATORS` that the league scores as a category). Each
such stat uses its natural denominator (AB, PA, etc.) for pool weighting.

**AVG in the band aggregate (replacement-level stat line):** `sum(H) / sum(AB)` across band
players. This is not changed by `"sgp_pool"` — it is used downstream by `par()` and `zar()`
to compute above-replacement AVG, not by the ranking step.

### 4.4 Logical precondition: `"sgp_pool"` implies `sort_by = "sgp"`

`boundary_rate_method = "sgp_pool"` produces ranking contributions in SGP units. These
are only meaningful when combined with the SGP contributions of counting stats, which
requires `sort_by = "sgp"` and a valid `sgp_denominators` object.

If the caller supplies `boundary_rate_method = "sgp_pool"` with `sort_by = "zscore"`,
`replacement_level()` should emit a clear error:

```r
cli::cli_abort(
  c(
    "!" = paste0(
      "{.arg boundary_rate_method} = {.val sgp_pool} requires ",
      "{.arg sort_by} = {.val \"sgp\"}, but {.arg sort_by} = {.val {sort_by}} ",
      "was supplied."
    ),
    "i" = "Set {.code sort_by = \"sgp\"} when using {.code boundary_rate_method = \"sgp_pool\"}."
  ),
  class = "rotostats_error_sgp_pool_sort_mismatch",
  call = rlang::caller_env()
)
```

Register `rotostats_error_sgp_pool_sort_mismatch` in the error table (see §5).

---

## 5. Error and Warning Classes

### New classes introduced by this spec

The following classes must be registered in `plans/error-messages.md`:

| Class | Thrown by | Condition | Recovery guidance |
|-------|-----------|-----------|-------------------|
| `rotostats_error_missing_rate_conversion_attr` | `replacement_level()` | `boundary_rate_method = "sgp_pool"` and `attr(sgp_denominators, "rate_conversion")` is `NULL` (attribute absent) | Use an `sgp_denominators` object produced by `sgp_denominators()`, which attaches `rate_conversion` automatically; or set `attr(sgp_denominators, "rate_conversion") <- "blended_pool"` manually |
| `rotostats_error_sgp_pool_degenerate` | `replacement_level()` | A position's rostered pool (from `position_assignments`) has fewer than 2 players; the N−1 marginal-pool formula is undefined | Check `n_teams` and `roster_slots`; use `boundary_rate_method = "raw_ip"` for positions with only 1 roster slot |
| `rotostats_error_sgp_pool_sort_mismatch` | `replacement_level()` | `boundary_rate_method = "sgp_pool"` with `sort_by = "zscore"` | Set `sort_by = "sgp"` when using `boundary_rate_method = "sgp_pool"` |

### Already registered (referenced here for completeness)

The following classes appear in the parent spec and are already in `plans/error-messages.md`:

- `rotostats_error_rate_method_mismatch`: fires when `boundary_rate_method =
  "sgp_pool"` is paired with `sgp_denominators` calibrated via
  `rate_conversion = "fixed_baseline"`. Registered on `develop` (row added
  alongside the historical-priors spec work); this spec defines the semantics
  and call-site ordering (§1 and §6 Step A.e) but does not re-register.
- `rotostats_error_missing_sgp_denominators`: fires when `sort_by = "sgp"` but
  `sgp_denominators` is NULL; also covers `boundary_rate_method = "sgp_pool"` with
  `sgp_denominators = NULL` (guard fires before the `rate_conversion` checks).
- `rotostats_warning_unexpected_slope_sign`: fires when sign-check fails (§3.3);
  reused from `sgp_denominators()` since the root cause is identical. See §3.3
  for the registry-update TODO at implementation time.

---

## 6. Implementation Steps for a Planner

A future implementation run should execute the following steps inside `R/replacement.R`.
This section is prescriptive enough to generate `spec.md` without revisiting this document.

### Step A: Input validation (pre-ranking)

After the existing `checkmate` validation block and before any ranking computation:

1. If `boundary_rate_method == "sgp_pool"`:
   a. Assert `!is.null(sgp_denominators)` → `rotostats_error_missing_sgp_denominators`.
   b. Assert `sort_by == "sgp"` → `rotostats_error_sgp_pool_sort_mismatch`.
   c. Read `rc <- attr(sgp_denominators, "rate_conversion")`.
   d. If `is.null(rc)` → `rotostats_error_missing_rate_conversion_attr`.
   e. If `rc == "fixed_baseline"` → `rotostats_error_rate_method_mismatch`.

### Step B: Pool construction (per position, per pass)

For each position `pos`:

1. Identify the N−1 rostered-player set from `position_assignments` (or seed on pass 1).
2. If `N < 2` (equivalently, the N−1 pool has 0 members) →
   `rotostats_error_sgp_pool_degenerate`. See §2.4.
3. Compute:
   - `IP_pool <- sum(pool$IP)`
   - `WtERA_pool <- sum(pool$IP * pool$ERA)`
   - `WtWHIP_pool <- sum(pool$IP * pool$WHIP)`
   - `AB_pool <- sum(pool$AB)` (hitters)
   - `H_pool <- sum(pool$H)` (hitters)
   - `pool_ERA_N1 <- WtERA_pool / IP_pool`
   - `pool_WHIP_N1 <- WtWHIP_pool / IP_pool`
   - `pool_AVG_N1 <- H_pool / AB_pool`

### Step C: Per-player marginal contributions

For each player `i` at position `pos`:

```r
marginal_ERA_i  <- pitcher_IP_i * (pitcher_ERA_i  - pool_ERA_N1)  / (IP_pool + pitcher_IP_i)
marginal_WHIP_i <- pitcher_IP_i * (pitcher_WHIP_i - pool_WHIP_N1) / (IP_pool + pitcher_IP_i)

ERA_contribution_i  <- -marginal_ERA_i  * sgp_denominators[["ERA"]]
WHIP_contribution_i <- -marginal_WHIP_i * sgp_denominators[["WHIP"]]
```

For hitter AVG (normal category — no negation):

```r
marginal_AVG_i  <- hitter_AB_i * (hitter_AVG_i - pool_AVG_N1) / (AB_pool + hitter_AB_i)
AVG_contribution_i <- marginal_AVG_i * sgp_denominators[["AVG"]]
```

For all other rate stats (OBP, SLG, OPS, wOBA, K/9, BB/9, HR/9, xFIP, SIERA, FIP):
apply the same marginal-pool formula using the appropriate denominator column from
`RATE_STAT_DENOMINATORS` and the appropriate denominator value from `sgp_denominators`.
For inverse rate categories (ERA, WHIP — and any additional ones listed in
`INVERSE_CATEGORIES` in `R/sgp-denominators-helpers.R`), negate; for normal rate
categories, do not negate.

### Step D: Composite score assembly

```r
# Counting-stat contributions (unchanged from existing sgp ranking logic)
counting_score_i <- sum(
  (stat_i[counting_cats] - repl_stat[counting_cats]) / sgp_denominators[counting_cats]
)

# Rate-stat contributions (sgp_pool path replaces raw_ip path)
rate_score_i <- ERA_contribution_i + WHIP_contribution_i + AVG_contribution_i + ...

# Total score
score_i <- counting_score_i + rate_score_i
```

Sort players descending by `score_i` to determine the boundary player.

### Step E: Sign-check diagnostic

After computing all contributions:

```r
# ERA sign check
expected_sign <- sign(pool_ERA_N1 - pitcher_ERA)
actual_sign   <- sign(ERA_contribution_i)
pct_wrong     <- mean(actual_sign != expected_sign, na.rm = TRUE)
if (pct_wrong > 0.05) {
  cli::cli_warn(
    "Unexpected ERA contribution sign for {round(pct_wrong * 100)}% of pitchers.",
    class = "rotostats_warning_unexpected_slope_sign"
  )
}
```

### Step F: Existing band aggregation is unchanged

The boundary band (`±K` players around the boundary) and the replacement-level stat line
aggregation (IP-weighted ERA/WHIP means, `sum(H)/sum(AB)` for AVG, arithmetic means for
counting stats) are unchanged. `"sgp_pool"` affects only the **ranking** step that
determines where the boundary is. After the boundary is located, the band aggregate uses
the same formulas as `"raw_ip"`.

---

## 7. Relationship to Convergence Loop

`replacement_level()` is stateless and deterministic (parent spec §"Sort Key and
Circularity"). The `"sgp_pool"` method introduces no new state — the N−1 pool is
recomputed on each call from `position_assignments` as supplied by `dollar_values()`.

The convergence loop managed by `dollar_values()` (parent spec lines 576–580) applies
without modification:

1. `replacement_level(sort_by = "zscore")` → initial replacement stats (pass 1 uses seed;
   `boundary_rate_method` is irrelevant on this pass if `sort_by = "zscore"`).
2. `sgp(replacement_stats = ...)` → SGP denominators with `rate_conversion = "blended_pool"`.
3. `replacement_level(sort_by = "sgp", sgp_denominators = ..., boundary_rate_method = "sgp_pool")`
   → updated replacement stats and ranking.
4. Repeat steps 2–3 until convergence.

The `"sgp_pool"` ranking formula depends on `pool_ERA(N−1)`, which itself depends on which
N−1 players are in the pool, which depends on position assignments, which depend on PAR,
which depend on replacement stats. This is the same circular dependency that the existing
`sort_by = "sgp"` loop already handles. No additional iteration structure is needed.

**Convergence note:** The `"sgp_pool"` formula introduces a mild additional feedback path
(pool ERA shifts as position assignments change), but the contraction mapping property is
preserved because the pool is large (N−1 players) and any single player's reassignment
shifts pool ERA by at most `O(1/N)`. The existing convergence criterion (`max_iter = 25`,
`tol = 0.01` SGP units) is sufficient. No new convergence parameter is required.

---

## 8. Output Changes

`"sgp_pool"` mode adds no new output fields. All existing return-list keys, attributes,
and invariants specified in the parent spec are preserved:

- `replacement_stats`: unchanged (band aggregate, not ranking scores).
- `positional_adjustments`: unchanged.
- `cliff_metric`: unchanged (cliff detection uses the same stat-line values regardless
  of ranking method).
- `params`: the `boundary_rate_method` key already exists in the `params` list (per parent
  spec output spec); its value will be `"sgp_pool"`. No new key needed.
- `attr(result, "stat_units")`: unchanged.
- Zero-sum assertion: unchanged.

The `pool_diagnostics` return element (parent spec §"Outputs") should include, when
`boundary_rate_method = "sgp_pool"`:

```
pool_diagnostics$sgp_pool <- list(
  pool_ERA_by_pos  = <named numeric vector: position → pool_ERA(N−1)>,
  pool_WHIP_by_pos = <named numeric vector: position → pool_WHIP(N−1)>,
  pool_IP_by_pos   = <named numeric vector: position → IP_pool>
)
```

This diagnostic is informational only — it helps users verify that the pool composition
is as expected and that the marginal contributions are being computed against a reasonable
baseline.

---

## 9. Test-Spec Guidance

A Tester or test-spec writer should cover at least the following cases:

### Unit tests (deterministic, no randomness)

- **TS-sgp1**: `"fixed_baseline"` guard fires — supply `sgp_denominators` with
  `attr(, "rate_conversion") = "fixed_baseline"` and `boundary_rate_method = "sgp_pool"`;
  expect `rotostats_error_rate_method_mismatch`.
- **TS-sgp2**: Missing attribute guard fires — supply `sgp_denominators` with no
  `rate_conversion` attribute; expect `rotostats_error_missing_rate_conversion_attr`.
- **TS-sgp3**: Sort mismatch guard fires — supply `boundary_rate_method = "sgp_pool"` with
  `sort_by = "zscore"`; expect `rotostats_error_sgp_pool_sort_mismatch`.
- **TS-sgp4**: Degenerate pool guard fires — configure a 1-team league with 1 SP slot
  (N = 1, pool is empty); expect `rotostats_error_sgp_pool_degenerate`.
- **TS-sgp5**: Marginal formula correctness — with a known 5-pitcher pool (fixed ERA, IP),
  compute `pool_ERA(N−1 ∪ {i})` manually and verify `replacement_level()` returns
  `ERA_contribution_i` matching the hand-computed value within floating-point tolerance.
- **TS-sgp6**: High-ERA pitcher ranks below low-ERA pitcher — with all else equal,
  `ERA_contribution` is lower for the high-ERA pitcher; verify sort order is correct.
- **TS-sgp7**: Pool depth sensitivity — a pitcher of fixed ERA ranks lower in a 15-team
  pool than in a 10-team pool (because the denominator `IP_pool + IP_i` is larger);
  verify the score ratio is consistent with the formula.
- **TS-sgp8**: AVG marginal formula — hitter above pool AVG gets positive AVG contribution;
  hitter below pool AVG gets negative; boundary case (exactly pool AVG) gets zero.
- **TS-sgp9**: Counting stats unchanged — a pitcher's HR/R/W/K contributions are identical
  under `"raw_ip"` and `"sgp_pool"` (holding denominators fixed).
- **TS-sgp10**: `pool_diagnostics$sgp_pool` populated — non-NULL, contains numeric vectors
  for each pitched position.

### Integration tests

- **TS-sgp11**: End-to-end with 12-team mixed league fixture — `"sgp_pool"` produces a
  valid `replacement_stats` data frame (correct schema, no NAs, zero-sum assertion passes).
- **TS-sgp12**: Iteration convergence — `"sgp_pool"` converges within `max_iter` for a
  standard 12-team mixed league; `converged = TRUE` in output.
- **TS-sgp13**: Rank-correlation between `"raw_ip"` and `"sgp_pool"` — Spearman ρ > 0.90
  on the same projection set with the same league config (methods should agree on the large
  majority of pitcher rankings; large divergence indicates a formula error).

---

## 10. Assumptions

| Assumption | Testable? | How to Test / Basis |
|---|---|---|
| N−1 rostered-player pool is the correct conceptual baseline for marginal ERA contribution | Theoretical | Zola / Smart Fantasy Baseball formulation; industry standard for SGP rate-stat ranking |
| IP weighting within the N−1 pool is the natural consequence of the marginal-pool formula | Formal | Algebraic derivation in §3.1 — no alternative weighting is consistent with the combined-pool ERA definition |
| `"blended_pool"` denominators are the correct conversion factor from delta-pool-ERA to standings places | Theoretical | `sgp_denominators` architecture notes §3 and the definition of `"blended_pool"` in `plans/sgp-denominators-architecture.md` |
| Convergence of the existing iteration loop is not materially degraded by the `"sgp_pool"` feedback | Partially testable | TS-sgp12; theoretical: O(1/N) per-player pool impact bounds the feedback |
| `"sgp_pool"` and `"raw_ip"` produce highly correlated pitcher rankings | Yes | TS-sgp13 (Spearman ρ > 0.90 acceptance criterion) |
| The marginal-pool formula correctly handles the boundary case (pitcher exactly at pool mean) | Yes | TS-sgp8 (AVG boundary case); analogous test for ERA |

---

## 11. Known Limitations and Deferred Items

### 11.1 `convert_rate_stats()` is a stub

As of `plans/sgp-denominators-architecture.md`, `convert_rate_stats()` is a stub that
aborts with `rotostats_error_not_implemented`. The `"sgp_pool"` method does not call
`convert_rate_stats()` — it uses `sgp_denominators[["ERA"]]` directly. No dependency on
the stub. Deferred: if `convert_rate_stats()` is implemented in a future run, verify
that it is consistent with the `"blended_pool"` units assumed here.

### 11.2 Rate categories beyond ERA/WHIP/AVG

The spec covers ERA, WHIP, and AVG explicitly. For other rate stats that may appear as
scored categories (OBP, SLG, OPS, wOBA, K/9, BB/9, HR/9, xFIP, SIERA, FIP), the same
marginal-pool formula applies using the appropriate denominator from `RATE_STAT_DENOMINATORS`
and the denominator value from `sgp_denominators`. The implementation must iterate over
all rate categories in the league's scoring configuration, not only ERA/WHIP/AVG. The
formula is the same in all cases; the Planner should handle this generically via the
`RATE_STAT_DENOMINATORS` lookup rather than case-by-case.

### 11.3 Swingmen and pool composition

Swingmen (pitchers with IP between 80 and 120) are included in the SP or RP pool
according to their `sp_ip_threshold` classification, exactly as under `"raw_ip"`. No
special handling. The `swingman` flag in `cliff_metric` is populated regardless of
`boundary_rate_method`.

### 11.4 Simulation spec (future)

A `sim-spec.md` for `"sgp_pool"` should include:

- **Study P1** (pool-depth sensitivity): verify that a fixed-quality pitcher's composite
  score scales as predicted by the formula (proportional to `IP_i / (IP_pool + IP_i)`)
  as league size varies from 10 to 15 teams.
- **Study P2** (convergence under `"sgp_pool"`): verify `convergence_rate ≥ 0.99` and
  `median_iterations ≤ 6` across 500 simulated league configurations, analogous to Study C
  for the `"raw_ip"` method.
- **Study P3** (rank correlation with `"raw_ip"`): Spearman ρ > 0.90 across the SP and RP
  ranking orders for a diverse set of projection vintages. Large departures should be
  explained by cases where league depth differs substantially between `"raw_ip"` and
  `"sgp_pool"` (i.e., `"sgp_pool"` should produce relatively higher rankings for pitchers
  who benefit from a shallow pool and vice versa).

---

*Written by Scriber — replacement-sgp-pool-rate-spec-2026-04-18*
