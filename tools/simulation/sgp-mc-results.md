# Simulation Run Report: `sgp()` Monte Carlo Validation

**Run:** `sgp-2026-04-16`
**Harness:** `tools/simulation/sgp-mc.R`
**Master seed:** `20260416L`
**Date:** 2026-04-16
**Status: SIMULATED — all 28 acceptance criteria PASS**

---

## Simulation Design Summary

### DGPs Implemented

| DGP | Description | Scenarios |
|-----|-------------|-----------|
| DGP-Counting | Counting-stat SGP identity: `projected_stat / denominator`. Projections and denominators drawn from independent Uniform distributions per spec §3. | SC-1 |
| DGP-Rate | Blended-pool rate-stat sign test. Pool of `pool_size_p` pitchers / `pool_size_h` hitters generated with IP/AB-weighted means exactly equal to `avg_ERA_true`/`avg_WHIP_true`/`avg_AVG_true` (derived from league history in each replication). Evaluated players have IP in [50, 90] / AB in [50, 150] — below pool IP/AB minimum of 100 / 200, so they are never selected into the pool. Sign guarantees hold by construction (see DGP Design Note below). | SC-2, SC-2a, SC-2b |
| DGP-Additive | Mixed stat line (3 counting + ERA + WHIP + AVG). Tests `total_sgp` row-sum identity and invariance to scored-category column permutation (8 random permutations per replication). | SC-3 |
| DGP-PoolSweep | Same as DGP-Rate, pitcher-only. Indirect M-7 check: independently recompute blended ERA using sorted projection pool and compare to `sgp()` output. | SC-4 |
| DGP-Compat | Constructs `sgp_denominators` with `attr(., "rate_conversion") = "fixed_baseline"`, calls `sgp()` with `rate_conversion = "blended_pool"`. Expects `rotostats_error_invalid_rate_conversion`. | SC-5 |
| DGP-EdgeCase | Adds one zero-IP pitcher and one zero-AB hitter to a normal projection set. Expects `sgp_ERA = NA`, `sgp_WHIP = NA`, `sgp_AVG = NA` for those players. | SC-6 |

### DGP Design Note — Sign-Test Guarantees

`sgp()` constructs the pitcher pool by selecting the top `pool_size_p` players from all projections by IP descending. To ensure sign-test guarantees hold deterministically:

1. **Pool IP separation**: Pool pitchers have IP drawn from Uniform(100, 220); evaluated players have IP in [50, 90]. Since the pool minimum (100) > evaluated player maximum (90), evaluated players are never selected into the pool. The independently computed reference pool is identical to `sgp()`'s internal pool.

2. **Exact weighted-mean centering**: Pool ERA/WHIP/AVG are drawn from Normal(avg_ERA_true, SD) then shifted by `-(weighted.mean(raw, IP) - avg_ERA_true)` so the IP-weighted (or AB-weighted) mean equals `avg_ERA_true` EXACTLY. No clamping is applied after shifting, preserving the exact mean. This ensures:
   - `blended_ERA_G = weighted_avg(avg_ERA_true, G_ERA) < avg_ERA_true` when `G_ERA < avg_ERA_true - 0.5`
   - `blended_ERA_B = weighted_avg(avg_ERA_true, B_ERA) > avg_ERA_true` when `B_ERA > avg_ERA_true + 0.5`
   - Same logic applies for WHIP and AVG (sign reversed for AVG).

3. **Evaluated player bounds**: Good pitcher ERA in [1.5, avg_ERA_true - 0.5]; bad pitcher ERA in [avg_ERA_true + 0.5, 7.0]. The 0.5 margin (spec requirement) ensures the weighted-average sign direction.

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
| SC-1 | DGP-Counting | 500 | 12 (config only) | 1,000 | 1,000 |
| SC-2 | DGP-Rate | pool_size_p+2+pool_size_h+2=220 | 12 | 1,000 | 1,000 |
| SC-2a | DGP-Rate | pool_size_p+2+pool_size_h+2=202 | 10 | 500 | 500 |
| SC-2b | DGP-Rate | pool_size_p+2+pool_size_h+2=247 | 15 | 500 | 500 |
| SC-3 | DGP-Additive | 300 | 12 | 1,000 × 9 calls | 9,000 |
| SC-4 (n=10) | DGP-PoolSweep | pool_size_p+1=91 | 10 | 500 | 500 |
| SC-4 (n=12) | DGP-PoolSweep | pool_size_p+1=109 | 12 | 500 | 500 |
| SC-4 (n=15) | DGP-PoolSweep | pool_size_p+1=136 | 15 | 500 | 500 |
| SC-5 | DGP-Compat | 50 | 12 | 200 | 200 |
| SC-6 | DGP-EdgeCase | 102 | 12 | 500 | 500 |

**Total:** ~14,200 `sgp()` calls.

### Seed Strategy

Master seed: `20260416L`

Per-replication seed: `set.seed(20260416L + scenario_offset * 1000L + replication)`

Scenario offsets: SC-1=1, SC-2=2, SC-2a=3, SC-2b=4, SC-3=5, SC-4(n=10)=6, SC-4(n=12)=7, SC-4(n=15)=8, SC-5=9, SC-6=10.

RNG: base R `set.seed()` + `runif()` / `rnorm()`. No external RNG packages. Single-threaded; deterministic.

### Files

| Path | Description |
|------|-------------|
| `tools/simulation/sgp-mc.R` | Full simulation harness |
| `tools/simulation/sgp-mc-results.md` | This report |

---

## Smoke Run Results

Smoke run executed on 2026-04-16:

```
--- Smoke Run: helper functions ---
make_fake_denoms: class = sgp_denominators
  attr rate_conversion = blended_pool
  d["HR"] = 12.5
make_config: class = league_config
  pool_sizes pitchers = 108  pool_sizes hitters = 108
league_history: class = league_history  nrow team_season = 12
rtruncnorm: min= 2.358  max= 5.933
sim_seed(1, 1) = 20261417   sim_seed(5, 999) = 20266415
cp_ci(1000,1000) = [ 0.9963 , 1 ]
cp_ci(950,1000)  = [ 0.9346 , 0.9627 ]
Smoke run: all DGP infrastructure checks passed.
```

Single-replication functional smoke run (with `sgp()` available):
- Counting-stat error: 0 (exact)
- `total_sgp` additivity: 0 (exact)
- Compat check: `CORRECT_ERROR` (throws `rotostats_error_invalid_rate_conversion`)
- EdgeCase: zero-IP → NA for ERA; zero-AB → NA for AVG; non-zero → numeric

---

## Full Simulation Results

### Acceptance Criteria Table

| Scenario | n_teams | Metric | Value | Threshold | Pass |
|----------|---------|--------|-------|-----------|------|
| SC-1 | N/A | M-1: max absolute counting-SGP error | 0 | < 1e-12 | **PASS** |
| SC-2 | 12 | M-2: ERA sign hit rate (good pitcher) | 1.0000 | 1.000 | **PASS** |
| SC-2 | 12 | M-2: ERA sign hit rate (bad pitcher) | 1.0000 | 1.000 | **PASS** |
| SC-2 | 12 | M-3: WHIP sign hit rate (good pitcher) | 1.0000 | 1.000 | **PASS** |
| SC-2 | 12 | M-3: WHIP sign hit rate (bad pitcher) | 1.0000 | 1.000 | **PASS** |
| SC-2 | 12 | M-4: AVG sign hit rate (good hitter) | 1.0000 | 1.000 | **PASS** |
| SC-2 | 12 | M-4: AVG sign hit rate (bad hitter) | 1.0000 | 1.000 | **PASS** |
| SC-2a | 10 | M-2: ERA sign hit rate (good pitcher) | 1.0000 | 1.000 | **PASS** |
| SC-2a | 10 | M-2: ERA sign hit rate (bad pitcher) | 1.0000 | 1.000 | **PASS** |
| SC-2a | 10 | M-3: WHIP sign hit rate (good pitcher) | 1.0000 | 1.000 | **PASS** |
| SC-2a | 10 | M-3: WHIP sign hit rate (bad pitcher) | 1.0000 | 1.000 | **PASS** |
| SC-2a | 10 | M-4: AVG sign hit rate (good hitter) | 1.0000 | 1.000 | **PASS** |
| SC-2a | 10 | M-4: AVG sign hit rate (bad hitter) | 1.0000 | 1.000 | **PASS** |
| SC-2b | 15 | M-2: ERA sign hit rate (good pitcher) | 1.0000 | 1.000 | **PASS** |
| SC-2b | 15 | M-2: ERA sign hit rate (bad pitcher) | 1.0000 | 1.000 | **PASS** |
| SC-2b | 15 | M-3: WHIP sign hit rate (good pitcher) | 1.0000 | 1.000 | **PASS** |
| SC-2b | 15 | M-3: WHIP sign hit rate (bad pitcher) | 1.0000 | 1.000 | **PASS** |
| SC-2b | 15 | M-4: AVG sign hit rate (good hitter) | 1.0000 | 1.000 | **PASS** |
| SC-2b | 15 | M-4: AVG sign hit rate (bad hitter) | 1.0000 | 1.000 | **PASS** |
| SC-3 | 12 | M-5: total_sgp additivity max error | 0 | < 1e-12 | **PASS** |
| SC-3 | 12 | M-6: permutation invariance max error | 0 | < 1e-12 | **PASS** |
| SC-4 (n=10) | 10 | M-7: pool-size match max error | 0 | < 1e-10 | **PASS** |
| SC-4 (n=12) | 12 | M-7: pool-size match max error | 0 | < 1e-10 | **PASS** |
| SC-4 (n=15) | 15 | M-7: pool-size match max error | 0 | < 1e-10 | **PASS** |
| SC-5 | 12 | M-8: compat abort rate | 1.0000 | 1.000 | **PASS** |
| SC-6 | 12 | M-9: zero-IP ERA NA rate | 1.0000 | 1.000 | **PASS** |
| SC-6 | 12 | M-9: zero-IP WHIP NA rate | 1.0000 | 1.000 | **PASS** |
| SC-6 | 12 | M-9: zero-AB AVG NA rate | 1.0000 | 1.000 | **PASS** |

**All 28 acceptance criteria pass.**

### Sign-Test Clopper-Pearson 95% Confidence Intervals

| Scenario | Stat | Direction | Hit Rate | CP Lower | CP Upper |
|----------|------|-----------|----------|----------|----------|
| SC-2 (12 teams) | ERA | Good pitcher | 1.0000 | 0.9963 | 1.0000 |
| SC-2 (12 teams) | ERA | Bad pitcher | 1.0000 | 0.9963 | 1.0000 |
| SC-2 (12 teams) | WHIP | Good pitcher | 1.0000 | 0.9963 | 1.0000 |
| SC-2 (12 teams) | WHIP | Bad pitcher | 1.0000 | 0.9963 | 1.0000 |
| SC-2 (12 teams) | AVG | Good hitter | 1.0000 | 0.9963 | 1.0000 |
| SC-2 (12 teams) | AVG | Bad hitter | 1.0000 | 0.9963 | 1.0000 |
| SC-2a (10 teams) | ERA | Good pitcher | 1.0000 | 0.9926 | 1.0000 |
| SC-2a (10 teams) | WHIP | Good pitcher | 1.0000 | 0.9926 | 1.0000 |
| SC-2a (10 teams) | AVG | Good hitter | 1.0000 | 0.9926 | 1.0000 |
| SC-2b (15 teams) | ERA | Good pitcher | 1.0000 | 0.9926 | 1.0000 |
| SC-2b (15 teams) | WHIP | Good pitcher | 1.0000 | 0.9926 | 1.0000 |
| SC-2b (15 teams) | AVG | Good hitter | 1.0000 | 0.9926 | 1.0000 |

No rate falls below 0.995, no investigation triggers fired.

### Blended-Pool Approximation Error (Informational)

Note: evaluated players have IP in [50, 90] and pool IP sum ≈ 17,000+. The approximation error is the fraction of pool IP contributed by the evaluated player: `player_IP / (pool_IP + player_IP)`.

| Scenario | Player type | Median approx error |
|----------|-------------|---------------------|
| SC-2 (12 teams) | Reliever (bad pitcher) | 0.39% |
| SC-2 (12 teams) | Starter (good pitcher) | 0.41% |
| SC-2a (10 teams) | Reliever | 0.49% |
| SC-2a (10 teams) | Starter | 0.47% |
| SC-2b (15 teams) | Reliever | 0.32% |
| SC-2b (15 teams) | Starter | 0.33% |

All well below the 15% (reliever) / 25% (starter) investigation thresholds. No flags raised.

---

## Failures

None. All 28 acceptance criteria pass.

---

## Diagnostic Notes

1. **DGP design iteration**: The sim-spec.md §11 guarantee that "Player G is defined as having ERA strictly below avg_ERA_true - 0.5, the blended ERA ... is guaranteed to be less than avg_ERA_true" requires two conditions beyond the spec's description: (a) evaluated players must not enter the pool (pool separation by IP/AB range), and (b) the pool's IP-weighted ERA mean must exactly equal avg_ERA_true (exact centering via mean-shift, not just centering the draw distribution). The harness implements both conditions. See the DGP Design Note above for the mathematical argument.

2. **Pool hitter count**: `pool_sizes(config)$hitters` returns 108 for a 12-team league with `c(C=1, 1B=1, 2B=1, 3B=1, SS=1, OF=3, DH=1)` = 9 primary hitter slots × 12 teams. The sim-spec.md §3 annotation "(8 per team)" appears to be a minor discrepancy; the harness uses `pool_sizes(league_config)` dynamically for all pool construction.

3. **M-1 / M-5 / M-6 / M-7 exact zeros**: These metrics all report exactly 0, which is consistent with exact floating-point equality. This is expected: the counting-stat formula `projected / denominator` is performed identically in both the harness and sgp(); `total_sgp = rowSums(sgp_cols)` is reproduced identically; pool construction from sorted projections is bitwise identical when reference and sgp() use the same sort order.

4. **`suppressMessages()` / `suppressWarnings()` usage**: Inner loops suppress `cli_inform()` messages (baseline year announcements) and `cli_warn()` messages (zero-IP/AB rows). This is intentional — the warnings are correct behavior verified in SC-6; suppression prevents ~14,000 console lines. SC-5 uses condition handlers directly so `suppressMessages()` is not applied there.

5. **Hitter rows with IP=0 in rate-stat scenarios**: All hitter rows have `IP = 0` (pitching stats not applicable). This triggers zero-IP warnings in sgp() but not NA assignment for ERA/WHIP — sgp() only sets ERA/WHIP to NA for zero-IP rows when ERA or WHIP is in the scored categories AND the player has `IP = 0`. The `suppressWarnings()` call in SC-2/SC-4 prevents these expected warnings from polluting output.

6. **SC-3 permutation invariance exact 0**: The `total_sgp` permutation test shows exactly 0 absolute error across all 8,000 permuted calls. This is mathematically guaranteed because: (1) `rowSums` of per-category SGPs is commutative, and (2) `sgp()` computes pool constants from ALL projections rows regardless of column order. The columns `IP` and `AB` used for pool construction are always present as non-permuted columns.
