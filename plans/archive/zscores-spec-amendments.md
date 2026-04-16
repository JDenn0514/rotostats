# Spec Amendments: `zaa()` / `zar()` API Fixes and FanGraphs-Style Z-Score Support

> **Type:** Proposed spec amendments · 2026-04-15
> **Affects:** `spec-zaa.md`, `spec-zar.md`, `spec-replacement.md`

These amendments address five API gaps identified during spec review, add
`hitter_pool` to support FanGraphs-style z-score computation, attach `projections`
and `config` to the `replacement_level()` output so downstream functions don't
require them as explicit arguments, reorder `zar()`'s signature for pipe
compatibility, and add formal inputs sections to both `zaa()` and `zar()`.

---

## Summary of Changes

| # | Change | Affects |
|---|--------|---------|
| 1 | Add `hitter_pool` parameter | `spec-zaa.md`, `spec-zar.md` |
| 2 | Expose `weight_method` and `hitter_pool`; make `replacement` first arg in `zar()` | `spec-zar.md` |
| 3 | Attach `projections` and `config` to `replacement_level()` output; update `zaa()` / `zar()` to extract them | `spec-replacement.md`, `spec-zaa.md`, `spec-zar.md` |
| 4 | Document `zaa()` distribution output attributes | `spec-zaa.md` |
| 5 | Document `stat_units` guard in `zaa()` | `spec-zaa.md` |
| 6 | Clarify `pitcher_pool = "none"` scope | `spec-zaa.md` |
| 7 | Add formal inputs sections to `zaa()` and `zar()` | `spec-zaa.md`, `spec-zar.md` |

---

## Change 1 — Add `hitter_pool` to `zaa()`

### Problem

Hitter z-scores in `zaa()` are always computed within position (per the
`replacement_level()` pool definitions). There is no way to compute z-scores
across a single unified hitter pool, which is the approach used by the FanGraphs
auction calculator. `pitcher_pool` controls pitcher grouping but has no hitter
equivalent.

### Fix

Add `hitter_pool` as a new parameter to `zaa()`:

**`hitter_pool` options:**

- `"positional"` (default): z-scores computed within each position pool (C vs C,
  1B vs 1B, SS vs SS, etc.). Per-position means and SDs are used. This is the
  FVARz/BIGz approach. Positional scarcity is encoded in two places: the
  smaller within-position SD at thin positions (C, SS) and the per-position
  replacement subtraction in `zar()`.

- `"combined"`: all hitters form a single pool regardless of position. A
  shortstop's HR z-score is computed against all rostered hitters, not just other
  SSes. Positional scarcity enters only through the per-position replacement
  subtraction in `zar()` — there is no within-position SD compression. This is
  the FanGraphs auction calculator approach (aPOS-style).

**Behavior under `hitter_pool = "combined"`:**

- Counting stat mean and SD are computed across all rostered hitters in one pool.
- AVG volume-weighting uses AB summed across all hitters in the combined pool.
- The `distribution` output attribute (see Change 4) stores one mean/SD pair per
  category rather than one per position per category.

**Conceptual note on scarcity encoding:**

Under `hitter_pool = "positional"`, a catcher's HR z-score reflects how far above
the *average catcher* they are. Under `hitter_pool = "combined"`, the same catcher's
HR z-score reflects how far above the *average hitter* they are. The replacement
subtraction in `zar()` removes the replacement catcher's combined-pool z-score —
mechanically identical to FanGraphs aPOS. The practical difference is that
`"positional"` bakes scarcity into the z-score distribution itself, while
`"combined"` defers it entirely to the replacement baseline.

**`replacement_level()` internal pool is unaffected:**

`replacement_level()` uses a unified hitter pool for its internal player ranking
(to identify boundary players). The `hitter_pool` parameter in `zaa()` controls
only the z-score output, not `replacement_level()`'s internal ranking. These are
independent computations.

### Spec text to add to `spec-zaa.md`

In Step 2, after the `pitcher_pool` options block, add:

> **`hitter_pool`** controls how hitter z-scores are pooled:
>
> - `"positional"` (default): z-scores are computed within each position's
>   rostered pool. The position boundaries are provided by the `replacement`
>   object when supplied; when `replacement = NULL`, `zaa()` uses the positions
>   present in `stats$pos_eligibility` (first position only). This is the
>   FVARz/BIGz approach.
>
> - `"combined"`: all hitters form a single pool. Position is not used in
>   z-score computation. The `replacement` object still defines the rostered
>   pool size (Step 1), but within that pool, all hitters are compared against a
>   single combined mean and SD per category. This is the FanGraphs auction
>   calculator approach.

---

## Change 2 — Expose `weight_method` and `hitter_pool`; make `replacement` first arg in `zar()`

### Problem

`zar()` calls `zaa()` internally but does not expose `weight_method` or (with
Change 1 added) `hitter_pool`. Users cannot apply FVARz's 0.8 SP multiplier
(`weight_method = "linear"`) or select a hitter pooling strategy through `zar()`.

Additionally, `replacement` is always required in `zar()` — there is no valid
call without it — but it is currently the second argument, preventing
`replacement_level() |> zar()` pipe usage.

### Fix

Reorder `zar()`'s signature and add the two pass-through parameters. With
Change 3 applied (projections and config attached to replacement), `stats` and
`config` are no longer explicit arguments:

```r
zar(
  replacement,                     # first arg — enables replacement_level() |> zar()
  pitcher_pool    = "combined",
  hitter_pool     = "positional",  # NEW — passed to zaa()
  category_weight = NULL,
  weight_method   = "none",        # NEW — passed to zaa()
  ...
)
```

`hitter_pool` and `weight_method` are pure pass-throughs to the internal `zaa()`
call. The warning `zaa()` emits when `weight_method != "none"` and
`pitcher_pool = "combined"` propagates naturally since `zaa()` owns the warning.

**Why `weight_method = "none"` as default:**

FVARz's 0.8 SP multiplier requires explicit opt-in. Defaulting to `"none"`
avoids silently applying positional adjustment for users who don't intend it.

**Why `replacement` is first but `stats` stays first in `zaa()`:**

`zar()` always requires a replacement object — there is no valid standalone call
without one. `zaa()` has a documented standalone use case where `replacement =
NULL` and users pass `stats` directly for scarcity analysis without a replacement
anchor. Forcing `replacement` first in `zaa()` would require `zaa(NULL, stats,
config, ...)` for standalone calls, which is worse than the current form. Users
wanting the pipe workflow should use `zar()`, which always has a replacement
object as its natural first input.

---

## Change 3 — Attach `projections` and `config` to `replacement_level()` output

### Problem

`zar()` needs `stats` (projections) and `config` to pass to `zaa()` internally.
Neither appears in `zar()`'s signature after Change 2, so both must come from
somewhere. Previously, `config` was identified as the gap; `projections` has the
same gap.

### Fix

`replacement_level()` attaches both as output attributes:

```r
attr(result, "config")       = config
attr(result, "projections")  = projections
attr(result, "stat_units")   = "raw_projected" | "full_season_normalized"
attr(result, "position_assignments") = named character vector (player_id → position)
```

`zar()` extracts both at call time:

```r
projections <- attr(replacement, "projections")
config      <- attr(replacement, "config")
if (is.null(projections) || is.null(config)) {
  cli::cli_abort("rotostats_error_missing_replacement_attrs", ...)
}
```

`zaa()` follows the same extraction pattern when `replacement` is provided: if
`replacement` carries `projections` and `config` attributes, those supersede any
explicit `stats` or `config` arguments. When `replacement = NULL`, `stats` and
`config` are required explicitly.

**Memory: extract-then-null for iterative callers**

Attaching projections to the replacement object could be expensive in functions
that iterate with the object (e.g., `dollar_values()` running a convergence
loop). The pattern for any iterative caller is to extract projections, strip the
attribute before the loop, then re-attach after convergence:

```r
# Before the loop
projections <- attr(replacement, "projections")
attr(replacement, "projections") <- NULL

# ... iterate: replacement is copied without the data on each pass ...

# After convergence
attr(replacement, "projections") <- projections
```

This is an internal implementation detail — the calling function (e.g.,
`dollar_values()`) handles it, not the user. From the user's perspective,
the replacement object always carries projections when returned from
`replacement_level()`.

**Spec text to add to `spec-replacement.md`** — in the Output section:

> **Output attributes:**
>
> ```
> attr(result, "stat_units")         = "raw_projected" | "full_season_normalized"
> attr(result, "config")             = the league_config object passed at call time
> attr(result, "projections")        = the projections data frame passed at call time
> attr(result, "position_assignments") = named character vector (player_id → position)
> ```
>
> `config` and `projections` allow downstream functions (`zar()`, `zaa()`) to
> extract both without requiring users to supply them again. Functions that
> iterate with the replacement object should strip `projections` before the loop
> and re-attach after convergence to avoid per-iteration copying.

**Spec text to add to `spec-zar.md`** — in the Formal Definition, before Step 1:

> **Attribute extraction:** `zar()` extracts `projections` and `config` from
> `attr(replacement, "projections")` and `attr(replacement, "config")` at call
> time. If either attribute is absent, `zar()` aborts with
> `rotostats_error_missing_replacement_attrs`. The `replacement` object must be
> produced by `replacement_level()`.

**Spec text to add to `spec-zaa.md`** — in Step 1:

> **Attribute extraction:** When `replacement` is provided and carries
> `projections` and `config` attributes, those values supersede any explicit
> `stats` or `config` arguments. When `replacement = NULL`, both `stats` and
> `config` are required.

---

## Change 4 — Document `zaa()` distribution output attributes

### Problem

`spec-zar.md` Step 2 says the replacement band-average z-score is computed by
applying "per-category mean and SD returned by `zaa()` as output attributes."
`spec-zaa.md`'s output section only documents `units` and `anchor`. The
per-category distribution parameters are not specified anywhere.

### Fix

**Spec text to replace `spec-zaa.md`'s Output structure block:**

> **Output structure:**
>
> Returns a data frame: one row per player, one `zaa_[cat]` column per scored
> category, plus `total_zaa`.
>
> ```
> attr(result, "units")        = "zscore"
> attr(result, "anchor")       = "average"
> attr(result, "distribution") = named list of per-category distribution parameters
> ```
>
> **`attr(result, "distribution")` schema:**
>
> When `hitter_pool = "positional"`: a nested list keyed first by position, then
> by category:
>
> ```
> distribution$C$HR    = list(mean = ..., sd = ..., sd_vol = ...)
> distribution$SP$ERA  = list(mean = ..., sd = ..., sd_vol = ...)
> ```
>
> When `hitter_pool = "combined"` or for pitchers under `pitcher_pool = "combined"`:
> a flat list keyed by category:
>
> ```
> distribution$HR  = list(mean = ..., sd = ...)
> distribution$ERA = list(mean = ..., sd = ..., sd_vol = ...)
> ```
>
> `sd_vol` is the population SD of the volume-weighted z-scores (Step 2b
> denominator). Present for rate stats only. Used by `zar()` to score the
> replacement band-average stat line against the stored distribution without
> re-running `zaa()`.

---

## Change 5 — Document `stat_units` guard in `zaa()`

### Problem

`spec-zar.md` attributes the `stat_units` guard to `zaa()`, but `spec-zaa.md`
does not document it. Neither spec is authoritative on its own.

### Fix

**Spec text to add to `spec-zaa.md`** — in Step 1, after attribute extraction:

> **`stat_units` guard:** When `replacement` is provided, `zaa()` checks
> `attr(replacement, "stat_units")` and aborts with
> `rotostats_error_stat_units_mismatch` if the value is `"full_season_normalized"`.
> Using normalized inputs causes double-application of IP/AB weighting in Step 2b
> and produces z-scores on the wrong scale. This guard is inherited by `zar()` by
> delegation — `zar()` does not check the attribute directly.

**Update `spec-zar.md`:**

> **`stat_units` guard:** Enforced in `zaa()` — see `spec-zaa.md`. Inherited
> by `zar()` by delegation.

---

## Change 6 — Clarify `pitcher_pool = "none"` scope

### Problem

`spec-zaa.md` describes `pitcher_pool = "none"` as placing "all players in one
pool with no positional grouping," which is ambiguous about whether hitters are
included.

### Fix

**Update the `"none"` option in `spec-zaa.md`:**

> - `"none"`: all *pitchers* form a single pool with no SP/RP split. Hitter
>   pooling is unaffected — it continues to follow `hitter_pool`. Not recommended
>   for standard rotisserie formats. For FanGraphs-style combined hitter z-scores,
>   use `hitter_pool = "combined"` instead.

---

## Change 7 — Add formal inputs sections to `spec-zaa.md` and `spec-zar.md`

### Problem

Neither `spec-zaa.md` nor `spec-zar.md` has a formal interface section. Readers
must infer the full parameter list from the prose. `spec-replacement.md` has a
detailed inputs section with type, required status, and notes per argument; the
same standard should apply here.

### Fix

**Add the following inputs section to `spec-zaa.md`:**

```r
zaa(
  stats           = NULL,
  config          = NULL,
  replacement     = NULL,
  pitcher_pool    = "combined",
  hitter_pool     = "positional",
  category_weight = NULL,
  weight_method   = "none",
  ...
)
```

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `stats` | data frame | conditional | Player projections. Required when `replacement = NULL` or lacks `projections` attribute. Superseded by `attr(replacement, "projections")` when present. Same column requirements as `replacement_level()` — must include `IP` and `AB` as full-season totals when ERA, WHIP, or AVG are scored. |
| `config` | league_config | conditional | League configuration object. Required when `replacement = NULL` or lacks `config` attribute. Superseded by `attr(replacement, "config")` when present. |
| `replacement` | replacement_level output | no | When provided, restricts the player pool to rostered players (Step 1) and supplies `stats` and `config` via attributes. When `NULL`, all rows in `stats` are used and `zaa()` emits `cli_inform()` noting the pool is unrestricted. |
| `pitcher_pool` | character | no | `"combined"` (default) \| `"split"` \| `"none"`. Controls pitcher z-score pool grouping. See Step 2. |
| `hitter_pool` | character | no | `"positional"` (default) \| `"combined"`. Controls hitter z-score pool grouping. See Step 2. |
| `category_weight` | named numeric | no | Manual per-position multipliers applied to `total_zaa` (e.g., `c(SP = 0.8, RP = 0.8)`). Overrides `weight_method` when provided. |
| `weight_method` | character | no | `"none"` (default) \| `"linear"` \| `"sqrt"`. Auto-computes category-count normalization for `total_zaa`. Ignored when `category_weight` is supplied. |

**Add the following inputs section to `spec-zar.md`:**

```r
zar(
  replacement,
  pitcher_pool    = "combined",
  hitter_pool     = "positional",
  category_weight = NULL,
  weight_method   = "none",
  ...
)
```

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `replacement` | replacement_level output | yes | Must carry `projections` and `config` as attributes. Produced by `replacement_level()`. Passing any other list aborts with `rotostats_error_missing_replacement_attrs`. |
| `pitcher_pool` | character | no | `"combined"` (default) \| `"split"`. Passed to the internal `zaa()` call. Controls whether SP and RP share a z-score distribution for counting stats. Does not affect replacement player identification, which is always per-role. |
| `hitter_pool` | character | no | `"positional"` (default) \| `"combined"`. Passed to the internal `zaa()` call. `"positional"` = FVARz; `"combined"` = FanGraphs aPOS-style. |
| `category_weight` | named numeric | no | Manual per-position multipliers (e.g., `c(SP = 0.8)`). Passed to the internal `zaa()` call. Overrides `weight_method`. |
| `weight_method` | character | no | `"none"` (default) \| `"linear"` \| `"sqrt"`. Passed to the internal `zaa()` call. Use `"linear"` to replicate FVARz's 0.8 SP multiplier in a standard 5-hitting / 4-pitching format. |

---

## FanGraphs vs. FVARz Call Sequences

After these amendments, the three canonical method configurations are:

**FVARz/BIGz:**
```r
repl <- replacement_level(projections, config, ...)
result <- zar(repl, pitcher_pool = "split", weight_method = "linear")

# or with pipe:
result <- replacement_level(projections, config, ...) |>
  zar(pitcher_pool = "split", weight_method = "linear")
```

**FanGraphs auction calculator (aPOS-style):**
```r
result <- replacement_level(projections, config, ...) |>
  zar(hitter_pool = "combined")
```

**LPP / FanGraphs basic (combined pitchers, positional hitters — the defaults):**
```r
result <- replacement_level(projections, config, ...) |> zar()
```

All three differ only in the parameters passed to `zar()`. `projections` is
passed once to `replacement_level()` and carried through to `zar()` automatically.

---

## Validation Additions

**Add to `spec-zaa.md` Validation Approach:**

> **`hitter_pool` attribute structure check:** When `hitter_pool = "combined"`,
> `attr(result, "distribution")` must be a flat category-keyed list. When
> `hitter_pool = "positional"`, it must be a position-keyed nested list.
> Automatable as a unit test on the attribute structure.
>
> **`hitter_pool` effect on z-scores:** Under `hitter_pool = "combined"`, a
> catcher with elite HR production will have a lower `zaa_hr` than under
> `hitter_pool = "positional"` (the combined SD is wider, so the same HR total
> is worth fewer standard deviations). Verify directionally with a synthetic
> two-player test: same HR total, one at C, one at 1B. The combined-pool C
> z-score must be smaller in magnitude than the positional-pool C z-score.
>
> **Attribute extraction precedence:** When both explicit `stats` and
> `attr(replacement, "projections")` are supplied, the replacement attribute
> wins. Automatable: call `zaa(stats = different_df, replacement = repl)` and
> assert output reflects `repl`'s projections, not `different_df`.

**Add to `spec-zar.md` Validation Approach:**

> **Attribute extraction error:** `zar()` must abort with
> `rotostats_error_missing_replacement_attrs` when passed a plain list lacking
> `projections` or `config` attributes. Automatable as a unit test.
>
> **Method equivalence check:** `total_zar` under `hitter_pool = "combined"`
> should rank hitters similarly to the FanGraphs auction calculator output for
> non-SB, non-SV categories. Spearman ρ > 0.90 among hitters is a reasonable
> threshold. Divergence at catcher (scarcity encoding differs between methods)
> is expected and is not a failure signal.
>
> **Pipe-compatibility check:** `replacement_level(projections, config) |> zar()`
> must produce identical output to `zar(replacement_level(projections, config))`.
> Automatable as a structural equality test.

---

## Implementation Guide

Apply changes to each file in the order listed. Within a file, work top to
bottom. For each change: locate the anchor text (a short unique quote from the
existing file), then perform the stated action. The full spec text to insert is
either quoted inline below or referenced back to the relevant Change section
above.

---

### `spec-zaa.md`

**1. Update formal definition signature** _(Changes 1, 3)_

Locate this exact line:
```
`zaa(stats, config, replacement = NULL, pitcher_pool = "combined", category_weight = NULL, weight_method = c("none", "linear", "sqrt"), ...)`
```
Replace with:
```
`zaa(stats = NULL, config = NULL, replacement = NULL, pitcher_pool = "combined", hitter_pool = "positional", category_weight = NULL, weight_method = "none", ...)`
```

---

**2. Add attribute extraction to Step 1** _(Change 3)_

Locate: `**Step 1 — Define the player pool:**`

Insert the following as a new paragraph immediately after that heading, before
the existing first sentence of Step 1:

> **Attribute extraction:** When `replacement` is provided and carries
> `projections` and `config` attributes, those values supersede any explicit
> `stats` or `config` arguments. When `replacement = NULL`, both `stats` and
> `config` are required.

---

**3. Add `stat_units` guard to Step 1** _(Change 5)_

Locate: `Users who want a tighter distribution should supply a \`replacement_level()\` object.`

Insert the following as a new paragraph immediately after that sentence:

> **`stat_units` guard:** When `replacement` is provided, `zaa()` checks
> `attr(replacement, "stat_units")` and aborts with
> `rotostats_error_stat_units_mismatch` if the value is `"full_season_normalized"`.
> Using normalized inputs causes double-application of IP/AB weighting in Step 2b
> and produces z-scores on the wrong scale. This guard is inherited by `zar()` by
> delegation — `zar()` does not check the attribute directly.

---

**4. Add `hitter_pool` block after pitcher_pool options** _(Change 1)_

Locate: `For hitters, positional grouping follows \`replacement_level()\` pool definitions`

Insert the spec text from the **"Spec text to add to `spec-zaa.md`"** block
in Change 1 above as a new paragraph immediately before that line.

---

**5. Replace `pitcher_pool = "none"` bullet** _(Change 6)_

Locate:
```
- `"none"`: all players in one pool with no positional grouping. Not recommended for
  standard rotisserie formats.
```
Replace with:
```
- `"none"`: all *pitchers* form a single pool with no SP/RP split. Hitter
  pooling is unaffected — it continues to follow `hitter_pool`. Not recommended
  for standard rotisserie formats. For FanGraphs-style combined hitter z-scores,
  use `hitter_pool = "combined"` instead.
```

---

**6. Replace output structure block** _(Change 4)_

Locate the block that begins with `**Output structure:**` and ends with:
```
attr(result, "anchor") = "average"
```
(including the surrounding code fence). Replace the entire block — from
`**Output structure:**` through the closing triple-backtick — with:

> **Output structure:**
>
> Returns a data frame: one row per player, one `zaa_[cat]` column per scored
> category, plus `total_zaa`.
>
> ```
> attr(result, "units")        = "zscore"
> attr(result, "anchor")       = "average"
> attr(result, "distribution") = named list of per-category distribution parameters
> ```
>
> **`attr(result, "distribution")` schema:**
>
> When `hitter_pool = "positional"`: a nested list keyed first by position, then
> by category:
>
> ```
> distribution$C$HR    = list(mean = ..., sd = ..., sd_vol = ...)
> distribution$SP$ERA  = list(mean = ..., sd = ..., sd_vol = ...)
> ```
>
> When `hitter_pool = "combined"` or for pitchers under `pitcher_pool = "combined"`:
> a flat list keyed by category:
>
> ```
> distribution$HR  = list(mean = ..., sd = ...)
> distribution$ERA = list(mean = ..., sd = ..., sd_vol = ...)
> ```
>
> `sd_vol` is the population SD of the volume-weighted z-scores (Step 2b
> denominator). Present for rate stats only. Used by `zar()` to score the
> replacement band-average stat line against the stored distribution without
> re-running `zaa()`.

---

**7. Add Interface section** _(Change 7)_

Locate: `## Decision This Informs`

Insert the following immediately before that heading:

```
## Interface

zaa(
  stats           = NULL,
  config          = NULL,
  replacement     = NULL,
  pitcher_pool    = "combined",
  hitter_pool     = "positional",
  category_weight = NULL,
  weight_method   = "none",
  ...
)
```

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `stats` | data frame | conditional | Player projections. Required when `replacement = NULL` or lacks `projections` attribute. Superseded by `attr(replacement, "projections")` when present. Same column requirements as `replacement_level()` — must include `IP` and `AB` as full-season totals when ERA, WHIP, or AVG are scored. |
| `config` | league_config | conditional | League configuration object. Required when `replacement = NULL` or lacks `config` attribute. Superseded by `attr(replacement, "config")` when present. |
| `replacement` | replacement_level output | no | When provided, restricts the player pool to rostered players (Step 1) and supplies `stats` and `config` via attributes. When `NULL`, all rows in `stats` are used and `zaa()` emits `cli_inform()` noting the pool is unrestricted. |
| `pitcher_pool` | character | no | `"combined"` (default) \| `"split"` \| `"none"`. Controls pitcher z-score pool grouping. See Step 2. |
| `hitter_pool` | character | no | `"positional"` (default) \| `"combined"`. Controls hitter z-score pool grouping. See Step 2. |
| `category_weight` | named numeric | no | Manual per-position multipliers applied to `total_zaa` (e.g., `c(SP = 0.8, RP = 0.8)`). Overrides `weight_method` when provided. |
| `weight_method` | character | no | `"none"` (default) \| `"linear"` \| `"sqrt"`. Auto-computes category-count normalization for `total_zaa`. Ignored when `category_weight` is supplied. |

---

**8. Append validation notes** _(Validation Additions)_

Locate the `## Validation Approach` section. Append the two new validation
checks from the **"Add to `spec-zaa.md` Validation Approach"** block in
Validation Additions above to the end of that section.

---

### `spec-zar.md`

**1. Update formal definition signature** _(Change 2)_

Locate this exact line:
```
`zar(stats, replacement, pitcher_pool = "combined", category_weight = NULL, ...)`
```
Replace with:
```
`zar(replacement, pitcher_pool = "combined", hitter_pool = "positional", category_weight = NULL, weight_method = "none", ...)`
```

---

**2. Add attribute extraction before Step 1** _(Change 3)_

Locate: `**Step 1 — Compute within-position z-scores:**`

Insert the following as a new paragraph immediately before this heading:

> **Attribute extraction:** `zar()` extracts `projections` and `config` from
> `attr(replacement, "projections")` and `attr(replacement, "config")` at call
> time. If either attribute is absent, `zar()` aborts with
> `rotostats_error_missing_replacement_attrs`. The `replacement` object must be
> produced by `replacement_level()`.

Then, within Step 1, locate:
```
Call `zaa(stats, replacement, pitcher_pool, category_weight, ...)`.
```
Replace with:
```
Call `zaa(replacement = replacement, pitcher_pool = pitcher_pool, hitter_pool = hitter_pool, category_weight = category_weight, weight_method = weight_method, ...)`.
```
(Projections and config are extracted from the `replacement` object automatically — no `stats` argument is passed.)

---

**3. Replace `stat_units` guard block** _(Change 5)_

Locate the block beginning with:
```
**`stat_units` guard:** `zaa()` checks `attr(replacement, "stat_units") == "raw_projected"`
```
Replace the entire block (through the end of that paragraph) with:

> **`stat_units` guard:** Enforced in `zaa()` — see `spec-zaa.md`. Inherited
> by `zar()` by delegation.

---

**4. Add Interface section** _(Change 7)_

Locate: `## Decision This Informs`

Insert the following immediately before that heading:

```
## Interface

zar(
  replacement,
  pitcher_pool    = "combined",
  hitter_pool     = "positional",
  category_weight = NULL,
  weight_method   = "none",
  ...
)
```

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `replacement` | replacement_level output | yes | Must carry `projections` and `config` as attributes. Produced by `replacement_level()`. Passing any other list aborts with `rotostats_error_missing_replacement_attrs`. |
| `pitcher_pool` | character | no | `"combined"` (default) \| `"split"`. Passed to the internal `zaa()` call. Controls whether SP and RP share a z-score distribution for counting stats. Does not affect replacement player identification, which is always per-role. |
| `hitter_pool` | character | no | `"positional"` (default) \| `"combined"`. Passed to the internal `zaa()` call. `"positional"` = FVARz; `"combined"` = FanGraphs aPOS-style. |
| `category_weight` | named numeric | no | Manual per-position multipliers (e.g., `c(SP = 0.8)`). Passed to the internal `zaa()` call. Overrides `weight_method`. |
| `weight_method` | character | no | `"none"` (default) \| `"linear"` \| `"sqrt"`. Passed to the internal `zaa()` call. Use `"linear"` to replicate FVARz's 0.8 SP multiplier in a standard 5-hitting / 4-pitching format. |

---

**5. Append validation notes** _(Validation Additions)_

Locate the `## Validation Approach` section. Append the three new validation
checks from the **"Add to `spec-zar.md` Validation Approach"** block in
Validation Additions above to the end of that section.

---

### `spec-replacement.md`

**1. Add output attributes block** _(Change 3)_

Locate: `This is a known runtime-only guard.`

Insert the following as a new paragraph immediately after that sentence:

> **Output attributes:**
>
> ```
> attr(result, "stat_units")           = "raw_projected" | "full_season_normalized"
> attr(result, "config")               = the league_config object passed at call time
> attr(result, "projections")          = the projections data frame passed at call time
> attr(result, "position_assignments") = named character vector (player_id → position)
> ```
>
> `config` and `projections` allow downstream functions (`zar()`, `zaa()`) to
> extract both without requiring users to supply them again. Functions that
> iterate with the replacement object should strip `attr(replacement, "projections")`
> before the loop and re-attach after convergence to avoid per-iteration copying.
