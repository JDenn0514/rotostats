# tests/testthat/test-par-sim.R
#
# Simulation validation assertions per test-spec.md §10.
# Reads tests/simulations/sim-par-results.rds and asserts against the
# revised acceptance criterion thresholds from the 2026-04-18 planner respawn.
#
# SV-1: Position-specific tolerances (amended 2026-04-18).
# SV-2: Calibrated band-check fire rate < 5%.
# SV-3: REMOVED — structurally unverifiable (see §10 SV-3 in test-spec.md).
# SV-4: Delegation identity within 1e-10 for all 1,000 iterations.

library(testthat)

# ---------------------------------------------------------------------------
# Load simulation results
# ---------------------------------------------------------------------------

sim_path <- testthat::test_path("..", "simulations", "sim-par-results.rds")

if (!file.exists(sim_path)) {
  skip(paste("sim-par-results.rds not found at", sim_path))
}

sim_results   <- readRDS(sim_path)
sim_calibrated <- sim_results[sim_results$dgp_type == "calibrated", ]

# ---------------------------------------------------------------------------
# SV-1: Replacement boundary invariance (amended position-specific tolerances)
# ---------------------------------------------------------------------------

test_that("SV-1: Boundary total_par ≈ 0 for tight-tolerance positions (0.05)", {
  tight_tol_pos <- c("C", "1B", "3B", "OF", "SP", "RP")

  for (pos in tight_tol_pos) {
    col <- paste0("boundary_total_par_", pos)
    if (!col %in% names(sim_calibrated)) next

    mean_val <- mean(sim_calibrated[[col]], na.rm = TRUE)
    expect_equal(
      mean_val, 0,
      tolerance = 0.05,
      label = paste0("SV-1 boundary invariance (tight tol 0.05): ", pos)
    )
  }
})

test_that("SV-1: Boundary total_par ≈ 0 for wide-tolerance positions (0.10, fvarz-adjusted)", {
  wide_tol_pos <- c("SS", "2B")

  for (pos in wide_tol_pos) {
    col <- paste0("boundary_total_par_", pos)
    if (!col %in% names(sim_calibrated)) next

    mean_val <- mean(sim_calibrated[[col]], na.rm = TRUE)
    expect_equal(
      mean_val, 0,
      tolerance = 0.10,
      label = paste0("SV-1 boundary invariance (wide tol 0.10, fvarz-adjusted): ", pos)
    )
  }
})

# ---------------------------------------------------------------------------
# SV-2: Band-median check (calibrated DGP should fire < 5% of iterations)
# ---------------------------------------------------------------------------

test_that("SV-2: Band check fires in < 5% of calibrated-DGP iterations", {
  pct_no_warning <- mean(!sim_calibrated$band_check_fired, na.rm = TRUE)
  expect_gte(pct_no_warning, 0.95,
             label = "SV-2: >= 95% of calibrated iterations have no band_check warning")
})

# ---------------------------------------------------------------------------
# SV-3: REMOVED
# The assertion that band_check fires >= 75% under 5-slot n_teams miscalibration
# is structurally unverifiable with the current par() implementation.
# par() uses replacement$params$n_teams for both the PAR anchor (Step 9) and
# the band-check boundary rank (Step 11). When n_teams is miscalibrated, both
# shift identically, so band players remain at total_par ≈ 0 by construction.
# See test-spec.md §10 SV-3 and sim-spec.md §Decision-AC4 for rationale.
# ---------------------------------------------------------------------------

# (No test block for SV-3 per planner amendment 2026-04-18.)

# ---------------------------------------------------------------------------
# SV-4: Delegation identity (all 1,000 iterations within 1e-10)
# ---------------------------------------------------------------------------

test_that("SV-4: Delegation identity max error within 1e-10 across all iterations", {
  expect_equal(
    max(abs(sim_results$delegation_max_error), na.rm = TRUE),
    0,
    tolerance = 1e-10,
    label = "SV-4: par_[c] + replacement_sgp[pos, c] == sgp_[c] within 1e-10"
  )
})
