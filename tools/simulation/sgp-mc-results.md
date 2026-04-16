# Simulation Run Report: `sgp()` Monte Carlo Validation

**Run:** `sgp-2026-04-16`
**Harness:** `tools/simulation/sgp-mc.R`
**Master seed:** `20260416L`
**Date written:** 2026-04-16

---

## Status

**AWAITING BUILDER** — `R/sgp.R` does not yet exist on `feature/sgp` at the time this
report was written. The simulation harness is complete and validated (smoke run passed —
see §Smoke Run below). Full simulation results will be populated once builder commits
`R/sgp.R`.

To run the full simulation after builder's commit:

```r
# From the repo root
devtools::load_all()
source("tools/simulation/sgp-mc.R")
```

---

## Simulation Design Summary

### DGPs Implemented

| DGP | Description | Scenarios |
|-----|-------------|-----------|
| DGP-Counting | Counting-stat SGP identity: `projected_stat / denominator`. All params drawn from independent Uniform distributions per spec §3. | SC-1 |
| DGP-Rate | Blended-pool rate-stat sign test. Pool of `pool_size_p` pitchers / `pool_size_h` hitters generated from spec-defined distributions. Good/bad players guaranteed to be on correct side of pool mean. League history generated as one-year, n_teams teams with IP/AB-weighted pool averages. | SC-2, SC-2a, SC-2b |
| DGP-Additive | Mixed stat line (3 counting + ERA + WHIP + AVG). Tests `total_sgp` row-sum identity and invariance to scored-category column permutation (8 random permutations per replication). | SC-3 |
| DGP-PoolSweep | Same as DGP-Rate but across `n_teams ∈ {10, 12, 15}` to verify pool scaling. Indirect M-7 check: independently recompute blended ERA using sorted pool and compare to `sgp()` output. | SC-4 |
| DGP-Compat | Constructs `sgp_denominators` with `attr(., "rate_conversion") = "fixed_baseline"`, calls `sgp()` with `rate_conversion = "blended_pool"`. Expects `rotostats_error_invalid_rate_conversion`. | SC-5 |
| DGP-EdgeCase | Adds one zero-IP pitcher and one zero-AB hitter to a normal projection set. Expects `sgp_ERA = NA`, `sgp_WHIP = NA`, `sgp_AVG = NA` for those players. | SC-6 |

### Estimator Interface Used

```r
sgp(
  projections     = projections_df,
  denominators    = denom_obj,
  league_history  = history_obj,
  rate_conversion = "blended_pool",
  pool_baseline   = "projection_pool",
  league_config   = config_obj
)
```

### Scenario Grid

| Scenario | DGP | n_players | n_teams | N_rep | sgp() calls |
|----------|-----|-----------|---------|-------|------------|
| SC-1 | DGP-Counting | 500 | N/A (12 for config) | 1,000 | 1,000 |
| SC-2 | DGP-Rate | pool+2 | 12 | 1,000 | 1,000 |
| SC-2a | DGP-Rate | pool+2 | 10 | 500 | 500 |
| SC-2b | DGP-Rate | pool+2 | 15 | 500 | 500 |
| SC-3 | DGP-Additive | 300 | 12 | 1,000 × 8 perms | 9,000 |
| SC-4 (n=10) | DGP-PoolSweep | pool+1 | 10 | 500 | 500 |
| SC-4 (n=12) | DGP-PoolSweep | pool+1 | 12 | 500 | 500 |
| SC-4 (n=15) | DGP-PoolSweep | pool+1 | 15 | 500 | 500 |
| SC-5 | DGP-Compat | 50 | 12 | 200 | 200 |
| SC-6 | DGP-EdgeCase | 102 | 12 | 500 | 500 |

**Total:** ~14,700 `sgp()` calls (matches sim-spec.md §4).

### Seed Strategy

Master seed: `20260416L`

Per-replication seed:
```r
set.seed(20260416L + scenario_offset * 1000L + replication)
```

Scenario offsets: SC-1=1, SC-2=2, SC-2a=3, SC-2b=4, SC-3=5, SC-4(n=10)=6,
SC-4(n=12)=7, SC-4(n=15)=8, SC-5=9, SC-6=10.

Seed is set at the top of each replication loop body via `set.seed()`. DGP draws
use base R `runif()` / `rnorm()`. Execution is single-threaded; results are
deterministic across OS and R versions given the same seed sequence.

### Files Created

| Path | Description |
|------|-------------|
| `tools/simulation/sgp-mc.R` | Full simulation harness (DGPs, harness loop, metrics, output tables) |
| `tools/simulation/sgp-mc-results.md` | This report |

---

## Smoke Run Results

Smoke run executed against package infrastructure only (no `sgp()` calls):

```
--- Smoke Run: helper functions ---
make_fake_denoms: class = sgp_denominators
  attr rate_conversion = blended_pool
  d["HR"] = 12.5
make_config: class = league_config
  pool_sizes pitchers = 108
  pool_sizes hitters  = 108
league_history: class = league_history
  nrow team_season = 12
rtruncnorm: min= 2.358  max= 5.933
sim_seed(1, 1) = 20261417
sim_seed(5, 999) = 20266415
cp_ci(1000,1000) = [ 0.9963 , 1 ]
cp_ci(950,1000)  = [ 0.9346 , 0.9627 ]

Smoke run: all DGP infrastructure checks passed.
NOTE: sgp() not yet available (builder has not committed R/sgp.R).
```

All helper functions (`make_fake_denoms`, `make_config`, `league_history`,
`rtruncnorm`, `sim_seed`, `cp_ci`) behave correctly. Synthetic `sgp_denominators`
objects are constructed with correct `attr(., "rate_conversion")` values.
`pool_sizes()` returns correct pitcher/hitter counts. Seeds are deterministic.

**Smoke run verdict: CLEAN** (no errors; `sgp()` not tested — pending builder).

---

## Full Simulation Results

*(Populated after builder commits `R/sgp.R` and full run completes)*

### Acceptance Criteria Table

| Scenario | Metric | Value | Threshold | Pass/Fail |
|----------|--------|-------|-----------|-----------|
| SC-1 | M-1: max absolute counting-SGP error | PENDING | < 1e-12 | — |
| SC-2 | M-2: ERA sign hit rate (good pitcher) | PENDING | 1.000 | — |
| SC-2 | M-2: ERA sign hit rate (bad pitcher) | PENDING | 1.000 | — |
| SC-2 | M-3: WHIP sign hit rate (good pitcher) | PENDING | 1.000 | — |
| SC-2 | M-3: WHIP sign hit rate (bad pitcher) | PENDING | 1.000 | — |
| SC-2 | M-4: AVG sign hit rate (good hitter) | PENDING | 1.000 | — |
| SC-2 | M-4: AVG sign hit rate (bad hitter) | PENDING | 1.000 | — |
| SC-2a | M-2/M-3/M-4 (10 teams) | PENDING | 1.000 | — |
| SC-2b | M-2/M-3/M-4 (15 teams) | PENDING | 1.000 | — |
| SC-3 | M-5: total_sgp additivity max error | PENDING | < 1e-12 | — |
| SC-3 | M-6: permutation invariance max error | PENDING | < 1e-12 | — |
| SC-4 (n=10) | M-7: pool-size match max error | PENDING | < 1e-10 | — |
| SC-4 (n=12) | M-7: pool-size match max error | PENDING | < 1e-10 | — |
| SC-4 (n=15) | M-7: pool-size match max error | PENDING | < 1e-10 | — |
| SC-5 | M-8: compat abort rate | PENDING | 1.000 | — |
| SC-6 | M-9: zero-IP ERA NA rate | PENDING | 1.000 | — |
| SC-6 | M-9: zero-IP WHIP NA rate | PENDING | 1.000 | — |
| SC-6 | M-9: zero-AB AVG NA rate | PENDING | 1.000 | — |

### Sign-Test Clopper-Pearson Confidence Intervals

*(Populated after full run)*

| Scenario | Stat | Direction | Hit Rate | 95% CP Lower | 95% CP Upper |
|----------|------|-----------|----------|--------------|--------------|
| SC-2 | ERA | Good pitcher | PENDING | — | — |
| SC-2 | ERA | Bad pitcher | PENDING | — | — |
| SC-2 | WHIP | Good pitcher | PENDING | — | — |
| SC-2 | WHIP | Bad pitcher | PENDING | — | — |
| SC-2 | AVG | Good hitter | PENDING | — | — |
| SC-2 | AVG | Bad hitter | PENDING | — | — |

**Investigation trigger:** hit rate < 0.995 AND lower 95% CP CI < 0.990.

### Blended-Pool Approximation Error (Informational)

*(Populated after full run)*

| Scenario | Player type | Median approx error | Flag (>15% reliever / >25% starter) |
|----------|-------------|--------------------|------------------------------------|
| SC-2 | Reliever (bad pitcher) | PENDING | — |
| SC-2 | Starter (good pitcher) | PENDING | — |
| SC-2a | Reliever | PENDING | — |
| SC-2a | Starter | PENDING | — |
| SC-2b | Reliever | PENDING | — |
| SC-2b | Starter | PENDING | — |

---

## Failures

*(None until full run completes. If any metric fails, this section will list:)*
*(- Observed value)*
*(- Threshold)*
*(- Scenario/player/replication where failure occurred)*

No failures to report at this time (full run pending `R/sgp.R`).

---

## Diagnostic Notes

1. **Pool hitter count:** `pool_sizes(config)$hitters` returns 108 for a 12-team league
   with `c(C=1, 1B=1, 2B=1, 3B=1, SS=1, OF=3, DH=1)` roster slots = 9 primary slots
   per team × 12 teams. `sim-spec.md §3` annotation "(8 per team)" appears to be a minor
   spec error; the harness uses `pool_sizes(league_config)` dynamically so the actual
   pool size is always derived from the config, ensuring internal consistency for M-7.

2. **Hitter rows in rate-stat scenarios:** The projections data frame for SC-2/SC-4
   includes the pool pitchers, two evaluated pitchers, pool hitters, and two evaluated
   hitters. The `IP = 0` for hitter rows and `AB = 0` for pitcher rows serve as the
   "zero" sentinel that `sgp()` should handle via its edge-case NA logic. Counting-only
   categories (HR, R, SB) are provided for all rows to satisfy the scored-category
   requirement.

3. **`suppressMessages()` usage:** The SC-2/SC-3/SC-4/SC-6 inner loops wrap `sgp()`
   calls with `suppressMessages()` to suppress the `cli_inform()` naming the year used
   for `avg_ERA`/`avg_WHIP`/`avg_AVG`. This is intentional — the message is correct
   behavior, not a warning or error. The SC-5 compat check uses the
   `rotostats_error_invalid_rate_conversion` condition handler so the abort is caught
   before `suppressMessages()` would even apply.

4. **Seed re-use for intermediate draws:** Within each replication, the seed is set once
   at the top via `set.seed(sim_seed(offset, r))`. All subsequent calls to `runif()`,
   `rnorm()`, and `rtruncnorm()` within that replication consume from that stream in
   deterministic order. The harness does not reset the seed mid-replication.
