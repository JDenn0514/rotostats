# tests/testthat/test-zar.R
#
# Independent validation of zar() per test-spec.md TS-ZAR-1 through TS-ZAR-12
# and §4 SV-1 through SV-5.
#
# Tester did NOT read spec.md, implementation.md, or R/zar.R.
# All assertions derive from observable behavior described in test-spec.md.
#
# Fixtures auto-loaded from:
#   helper-zaa-fixtures.R  — make_repl(), make_zaa_cfg()
#   helper-test-data.R     — make_projections_data()
#   helper-zar-fixtures.R  — make_zar_fixture(), make_zar_rate_fixture(),
#                             make_zar_sv_fixture(), make_zar_boundary_fixture()

# ---------------------------------------------------------------------------
# Pre-build fixtures once at file scope.
# ---------------------------------------------------------------------------
.fixture      <- make_zar_fixture()
.fixture_sv   <- make_zar_sv_fixture()
.fixture_bnd  <- make_zar_boundary_fixture()
.fixture_rate <- make_zar_rate_fixture()

# ===========================================================================
# TS-ZAR-1 — Attribute extraction error
# ===========================================================================
test_that("TS-ZAR-1: bare list with no attrs triggers rotostats_error_missing_replacement_attrs", {
  bad_repl_no_attrs <- list()   # plain list, zero attributes

  expect_error(
    zar(bad_repl_no_attrs),
    class = "rotostats_error_missing_replacement_attrs"
  )
})

test_that("TS-ZAR-1 (variant): list with projections attr but no config triggers missing-attrs error", {
  bad_repl_no_config <- structure(list(), class = "replacement_level")
  attr(bad_repl_no_config, "projections") <- data.frame(x = 1L)
  # config attribute intentionally absent

  expect_error(
    zar(bad_repl_no_config),
    class = "rotostats_error_missing_replacement_attrs"
  )
})

# ===========================================================================
# TS-ZAR-2 — Replacement boundary check
# ===========================================================================
test_that("TS-ZAR-2: boundary player at each position has |total_zar| < 0.5", {
  # Use the hand-crafted boundary fixture to guarantee exact boundary behaviour
  # under fvarz: with exactly 2 players per position and 2-team 1-slot-each config,
  # the boundary player (rank 2) is constructed to have total_zar = 0 exactly.
  fixture <- .fixture_bnd
  result  <- suppressWarnings(zar(fixture$replacement))

  expect_s3_class(result, "data.frame")
  expect_true("total_zar" %in% names(result))
  expect_true("player_id" %in% names(result))

  pos_assignments <- attr(fixture$replacement, "position_assignments")

  for (pos in c("C", "1B", "SP", "RP")) {
    pos_players <- which(pos_assignments[result$player_id] == pos)
    if (length(pos_players) == 0L) next

    sorted_zar   <- sort(result$total_zar[pos_players], decreasing = TRUE)
    boundary_idx <- min(2L, length(sorted_zar))

    expect_lt(
      abs(sorted_zar[boundary_idx]),
      0.5,
      label = paste0("boundary |total_zar| < 0.5 for position ", pos)
    )
  }
})

# ===========================================================================
# TS-ZAR-3 — Algebraic identity check
# ===========================================================================
test_that("TS-ZAR-3: zar_cat = zaa_cat - constant_offset, offset constant within position", {
  fixture    <- .fixture
  result_raw <- zar(fixture$replacement, include_raw = TRUE)

  zaa_cols <- grep("^zaa_", names(result_raw), value = TRUE)
  zar_cols <- grep("^zar_", names(result_raw), value = TRUE)

  expect_true(length(zaa_cols) > 0L, label = "at least one zaa_* column present")
  expect_equal(length(zaa_cols), length(zar_cols),
               label = "same number of zaa_* and zar_* columns")

  pos_assignments <- attr(fixture$replacement, "position_assignments")

  # Only check positions that are rostered in the config
  rostered_positions <- c(
    names(fixture$config$roster_slots),
    names(fixture$config$pitcher_slots)
  )

  for (col_idx in seq_along(zaa_cols)) {
    zaa_col <- zaa_cols[[col_idx]]
    zar_col <- zar_cols[[col_idx]]
    offsets <- result_raw[[zaa_col]] - result_raw[[zar_col]]

    # Check only rostered positions (non-rostered positions have NA zar_* by design)
    for (pos in rostered_positions) {
      pos_rows <- which(pos_assignments[result_raw$player_id] == pos)
      if (length(pos_rows) < 2L) next

      offs_pos <- offsets[pos_rows]
      non_na   <- offs_pos[!is.na(offs_pos)]
      if (length(non_na) < 2L) next

      expect_true(
        diff(range(non_na)) < 1e-10,
        label = paste0("constant offset for ", zaa_col, " at position ", pos)
      )
    }
  }
})

test_that("TS-ZAR-3: total_zar == rowSums(zar_*, na.rm = TRUE) within 1e-10", {
  fixture    <- .fixture
  result_raw <- zar(fixture$replacement, include_raw = TRUE)

  zar_cols       <- grep("^zar_", names(result_raw), value = TRUE)
  zar_matrix     <- as.matrix(result_raw[, zar_cols, drop = FALSE])
  expected_total <- unname(rowSums(zar_matrix, na.rm = TRUE))

  expect_equal(result_raw$total_zar, expected_total, tolerance = 1e-10,
               label = "total_zar == rowSums(zar_*, na.rm = TRUE)")
})

test_that("TS-ZAR-3b: cross-side NA categories do not propagate to total_zar", {
  # Hitters in a rate-stat league have NA IP, yielding NA zar_ERA. Under
  # na.rm = TRUE semantics those NAs must contribute 0, not propagate.
  fixture <- .fixture_rate
  result  <- suppressWarnings(zar(fixture$replacement))

  hitter_ids <- fixture$projections$player_id[
    !grepl("(SP|RP)", fixture$projections$pos_eligibility)
  ]
  hitter_rows <- result[result$player_id %in% hitter_ids, , drop = FALSE]

  expect_gt(nrow(hitter_rows), 0L,
            label = "fixture yields at least one hitter row for the check")
  expect_true(any(is.na(hitter_rows$zar_ERA)),
              label = "hitters still carry NA on zar_ERA (precondition)")
  expect_false(any(is.na(hitter_rows$total_zar)),
               label = "total_zar is never NA for hitters with NA zar_ERA")
})

# ===========================================================================
# TS-ZAR-4 — Rate-stat sign check
# ===========================================================================
test_that("TS-ZAR-4: good ERA pitcher (ERA=2.50 < repl) has zar_era > 0; bad (ERA=6.50 > repl) < 0", {
  fixture <- .fixture_rate

  # suppressWarnings: hitters have NA IP, which triggers a rate-stat warning
  result <- suppressWarnings(zar(fixture$replacement))

  expect_true("zar_ERA" %in% names(result), label = "zar_ERA column present")

  good_row <- result[result$player_id == fixture$sp_good_id, , drop = FALSE]
  bad_row  <- result[result$player_id == fixture$sp_bad_id,  , drop = FALSE]

  expect_gt(good_row$zar_ERA, 0,
            label = paste0("good ERA SP (ERA=2.50) has zar_ERA > 0; actual=",
                           round(good_row$zar_ERA, 4)))
  expect_lt(bad_row$zar_ERA, 0,
            label = paste0("bad ERA SP (ERA=6.50) has zar_ERA < 0; actual=",
                           round(bad_row$zar_ERA, 4)))
})

test_that("TS-ZAR-4: sign(repl_ERA - player_ERA) == sign(zar_era) for SP far from replacement", {
  # The correct behavioural invariant for rate stats: zar_era > 0 means
  # the player is better than replacement, i.e. player_ERA < replacement_ERA.
  # Near-boundary players (|ERA - repl_ERA| < 0.5) are excluded to avoid
  # floating-point ambiguity.
  fixture <- .fixture_rate

  result <- suppressWarnings(zar(fixture$replacement))
  proj   <- fixture$projections
  pa     <- attr(fixture$replacement, "position_assignments")

  sp_repl_era <- fixture$replacement$replacement_stats$ERA[
    fixture$replacement$replacement_stats$position == "SP"
  ]

  sp_ids       <- names(pa)[pa == "SP"]
  sp_in_result <- result[result$player_id %in% sp_ids, , drop = FALSE]
  sp_eras      <- proj$ERA[match(sp_in_result$player_id, proj$player_id)]
  sp_ips       <- proj$IP[match(sp_in_result$player_id, proj$player_id)]

  # Near-replacement threshold for excluding boundary cases
  near_threshold <- 0.5

  for (i in seq_len(nrow(sp_in_result))) {
    era    <- sp_eras[i]
    zar_era <- sp_in_result$zar_ERA[i]
    ip     <- sp_ips[i]

    if (is.na(era) || is.na(zar_era) || is.na(ip) || ip == 0) next
    if (abs(era - sp_repl_era) < near_threshold) next  # skip near-boundary
    if (zar_era == 0) next

    expect_equal(
      sign(sp_repl_era - era),
      sign(zar_era),
      label = paste0("ERA sign for player ", sp_in_result$player_id[i],
                     " (ERA=", era, ", repl_ERA=", round(sp_repl_era, 3),
                     ", zar_ERA=", round(zar_era, 3), ")")
    )
  }
})

# ===========================================================================
# TS-ZAR-5 — Pipe-compatibility check
# ===========================================================================
test_that("TS-ZAR-5: pipe call produces structurally identical result to nested call", {
  fixture <- .fixture

  result_nested <- zar(fixture$replacement)
  result_piped  <- replacement_level(fixture$projections, fixture$config) |> zar()

  expect_equal(names(result_nested), names(result_piped),
               label = "column names identical for piped vs nested call")
  expect_equal(nrow(result_nested), nrow(result_piped),
               label = "row count identical for piped vs nested call")
  expect_equal(result_nested$total_zar, result_piped$total_zar, tolerance = 1e-10,
               label = "total_zar values identical within 1e-10")
  expect_equal(attr(result_nested, "units"),  attr(result_piped, "units"),
               label = "units attribute identical")
  expect_equal(attr(result_nested, "anchor"), attr(result_piped, "anchor"),
               label = "anchor attribute identical")
})

# ===========================================================================
# TS-ZAR-6 — SP/RP separate replacement baselines under pitcher_pool = "combined"
# ===========================================================================
test_that("TS-ZAR-6: under pitcher_pool='combined', SP SV offset < RP SV offset", {
  # SP SV = 0 (starters don't save); RP SV > 0 (closers save).
  # Under the shared combined-pool distribution, the replacement z-score
  # subtracted for SP SV is lower than for RP SV:
  #   z_SP_repl = (0 - combined_mean_SV) / sd < (RP_repl_SV - combined_mean_SV) / sd = z_RP_repl
  fixture <- .fixture_sv

  result <- zar(fixture$replacement, include_raw = TRUE, pitcher_pool = "combined")
  pa     <- attr(fixture$replacement, "position_assignments")

  sp_rows <- which(pa[result$player_id] == "SP")
  rp_rows <- which(pa[result$player_id] == "RP")

  sp_sv_offset <- mean(result$zaa_SV[sp_rows] - result$zar_SV[sp_rows], na.rm = TRUE)
  rp_sv_offset <- mean(result$zaa_SV[rp_rows] - result$zar_SV[rp_rows], na.rm = TRUE)

  expect_lt(
    sp_sv_offset, rp_sv_offset,
    label = paste0(
      "SP SV replacement offset (", round(sp_sv_offset, 4), ") < ",
      "RP SV replacement offset (", round(rp_sv_offset, 4), ") under combined pool"
    )
  )
})

test_that("TS-ZAR-6: SP and RP SV offsets differ under pitcher_pool='split'", {
  # Under split pool each position has its own distribution, so the two z-scale
  # reference frames differ. The key property is that SP and RP use DISTINCT
  # replacement baselines (offsets are not equal).
  fixture <- .fixture_sv

  result <- zar(fixture$replacement, include_raw = TRUE, pitcher_pool = "split")
  pa     <- attr(fixture$replacement, "position_assignments")

  sp_rows <- which(pa[result$player_id] == "SP")
  rp_rows <- which(pa[result$player_id] == "RP")

  sp_sv_offset <- mean(result$zaa_SV[sp_rows] - result$zar_SV[sp_rows], na.rm = TRUE)
  rp_sv_offset <- mean(result$zaa_SV[rp_rows] - result$zar_SV[rp_rows], na.rm = TRUE)

  # Offsets must differ (separate baselines used for SP vs RP)
  expect_false(
    isTRUE(all.equal(sp_sv_offset, rp_sv_offset, tolerance = 1e-10)),
    label = paste0(
      "SP SV offset (", round(sp_sv_offset, 4), ") != ",
      "RP SV offset (", round(rp_sv_offset, 4), ") under split pool"
    )
  )
})

# ===========================================================================
# TS-ZAR-7 — include_raw = TRUE column shape and ordering
# ===========================================================================
test_that("TS-ZAR-7: include_raw=TRUE returns all zaa_* and zar_* columns", {
  fixture    <- .fixture
  result_raw <- zar(fixture$replacement, include_raw = TRUE)

  expected_zaa_cols <- paste0("zaa_", c("HR", "R", "SB", "K", "SV"))
  expected_zar_cols <- paste0("zar_", c("HR", "R", "SB", "K", "SV"))

  expect_true(all(expected_zaa_cols %in% names(result_raw)),
              label = "all zaa_<cat> columns present with include_raw=TRUE")
  expect_true(all(expected_zar_cols %in% names(result_raw)),
              label = "all zar_<cat> columns present with include_raw=TRUE")
  expect_true("total_zaa" %in% names(result_raw),
              label = "total_zaa column present with include_raw=TRUE")
  expect_true("total_zar" %in% names(result_raw),
              label = "total_zar column present with include_raw=TRUE")
})

test_that("TS-ZAR-7: all zaa_*/total_zaa columns appear BEFORE all zar_*/total_zar columns", {
  fixture    <- .fixture
  result_raw <- zar(fixture$replacement, include_raw = TRUE)

  zaa_idx <- which(grepl("^zaa_|^total_zaa$", names(result_raw)))
  zar_idx <- which(grepl("^zar_|^total_zar$", names(result_raw)))

  expect_true(
    max(zaa_idx) < min(zar_idx),
    label = paste0(
      "all zaa_*/total_zaa columns (positions ", paste(zaa_idx, collapse = ","),
      ") must come before all zar_*/total_zar columns (positions ",
      paste(zar_idx, collapse = ","), ")"
    )
  )
})

test_that("TS-ZAR-7: include_raw=FALSE contains no zaa_* or total_zaa columns", {
  fixture        <- .fixture
  result_default <- zar(fixture$replacement, include_raw = FALSE)

  expect_false(any(grepl("^zaa_|^total_zaa$", names(result_default))),
               label = "no zaa_* or total_zaa columns when include_raw=FALSE")
  expect_true("total_zar" %in% names(result_default),
              label = "total_zar column present when include_raw=FALSE")
})

test_that("TS-ZAR-7: row count identical between include_raw=TRUE and include_raw=FALSE", {
  fixture        <- .fixture
  result_raw     <- zar(fixture$replacement, include_raw = TRUE)
  result_default <- zar(fixture$replacement, include_raw = FALSE)

  expect_equal(nrow(result_raw), nrow(result_default),
               label = "same number of rows regardless of include_raw")
})

# ===========================================================================
# TS-ZAR-8 — multi_pos = "all" abort path
# ===========================================================================
test_that("TS-ZAR-8: replacement with params$multi_pos='all' triggers rotostats_error_multi_pos_all_unsupported", {
  fixture  <- .fixture
  bad_repl <- make_repl(
    projections = fixture$projections,
    config      = fixture$config
  )
  bad_repl$params <- list(multi_pos = "all")

  expect_error(
    zar(bad_repl),
    class = "rotostats_error_multi_pos_all_unsupported"
  )
})

# ===========================================================================
# TS-ZAR-9 — total_zar ≈ 0 at the exact replacement band (hand-crafted fixture)
# ===========================================================================
test_that("TS-ZAR-9: boundary catcher (rank 2 in 2-team 1-C-slot league) has |total_zar| < 0.5", {
  fixture <- .fixture_bnd
  result  <- suppressWarnings(zar(fixture$replacement))

  c1_zar <- result$total_zar[result$player_id == "C1"]
  c2_zar <- result$total_zar[result$player_id == "C2"]

  expect_gt(c1_zar, 0,
            label = paste0("better catcher C1 has total_zar > 0; actual=", round(c1_zar, 4)))
  expect_lt(abs(c2_zar), 0.5,
            label = paste0("boundary catcher C2 has |total_zar| < 0.5; actual=", round(c2_zar, 4)))
})

# ===========================================================================
# TS-ZAR-10 — stat_units mismatch (inherited from zaa())
# ===========================================================================
test_that("TS-ZAR-10: stat_units='full_season_normalized' triggers rotostats_error_stat_units_mismatch", {
  fixture  <- .fixture
  bad_repl <- make_repl(
    projections = fixture$projections,
    config      = fixture$config,
    stat_units  = "full_season_normalized"
  )

  expect_error(
    zar(bad_repl),
    class = "rotostats_error_stat_units_mismatch"
  )
})

# ===========================================================================
# TS-ZAR-11 — Output attributes
# ===========================================================================
test_that("TS-ZAR-11: zar() result carries units='zscore' and anchor='replacement'", {
  fixture <- .fixture
  result  <- zar(fixture$replacement)

  expect_equal(attr(result, "units"),  "zscore",
               label = "attr(result, 'units') == 'zscore'")
  expect_equal(attr(result, "anchor"), "replacement",
               label = "attr(result, 'anchor') == 'replacement'")
})

# ===========================================================================
# TS-ZAR-12 — include_raw = FALSE (default) contains no zaa_* columns
# ===========================================================================
test_that("TS-ZAR-12: default call produces only zar_*, total_zar, player_id, player_type columns", {
  fixture <- .fixture
  result  <- zar(fixture$replacement)

  expect_false(
    any(grepl("^zaa_|^total_zaa", names(result))),
    label = "no zaa_* or total_zaa columns in default output"
  )
  expect_true(
    all(grepl("^zar_|^total_zar$|^player_id$|^player_type$", names(result))),
    label = "all column names are zar_*, total_zar, player_id, or player_type"
  )
})

# ===========================================================================
# §4 Simulation Validation — SV-1 through SV-5
# ===========================================================================

# Locate the simulation results RDS.  system.file() resolves correctly under
# both devtools::test() (in-development) and installed-package runs.
.sim_results_path <- system.file(
  "simulation", "sim-zar-results.rds",
  package = "rotostats"
)

test_that("SV-1: algebraic identity max_error < 1e-10 across all replications", {
  skip_if(nchar(.sim_results_path) == 0L,
          message = "sim-zar-results.rds not found via system.file()")

  sim <- readRDS(.sim_results_path)

  expect_true("identity_max_error" %in% names(sim),
              label = "identity_max_error column present in sim results")

  # Exact tolerance from test-spec.md v3 §4 SV-1: max < 1e-10
  observed_max <- max(sim$identity_max_error, na.rm = TRUE)
  expect_lt(observed_max, 1e-10,
            label = paste0("max(identity_max_error) = ", signif(observed_max, 4),
                           " must be < 1e-10 [test-spec tolerance: 1e-10]"))

  failed_identity <- sim[!is.na(sim$identity_max_error) & sim$identity_max_error >= 1e-10, ]
  expect_equal(nrow(failed_identity), 0L,
               info = paste0("Algebraic identity violated in ", nrow(failed_identity),
                             " replications"))
})

test_that("SV-2: band-mean invariant — all replications have band_mean_max_err < 1e-10", {
  skip_if(nchar(.sim_results_path) == 0L,
          message = "sim-zar-results.rds not found via system.file()")

  sim <- readRDS(.sim_results_path)

  expect_true("band_mean_max_err" %in% names(sim),
              label = "band_mean_max_err column present in sim results")

  # Hard assertion (test-spec.md v3 §4 SV-2): every replication band_mean_max_err < 1e-10
  failed_band <- sim[!is.na(sim$band_mean_max_err) & sim$band_mean_max_err >= 1e-10, ]
  expect_equal(
    nrow(failed_band), 0L,
    info = paste0("Band-mean invariant violated in ", nrow(failed_band),
                  " replications [test-spec tolerance: 1e-10]")
  )

  # Statistical assertion (test-spec.md v3 §4 SV-2): fraction < 1%
  violation_rate <- mean(sim$band_mean_max_err >= 1e-10, na.rm = TRUE)
  expect_lt(
    violation_rate,
    0.01,
    label = paste0(
      "band-mean violation fraction = ", round(violation_rate * 100, 2), "% ",
      "must be < 1% [test-spec tolerance: threshold=1e-10, fraction<0.01]"
    )
  )
})

test_that("SV-3: rank stability — mean Spearman rho (HR+R+K) > 0.55 in S1 null DGP", {
  skip_if(nchar(.sim_results_path) == 0L,
          message = "sim-zar-results.rds not found via system.file()")

  sim <- readRDS(.sim_results_path)

  expect_true("rank_spearman_rho_hr_r_k" %in% names(sim),
              label = "rank_spearman_rho_hr_r_k column present in sim results")

  null_s1 <- sim[sim$scenario_id == "S1" & !is.na(sim$rank_spearman_rho_hr_r_k), ]

  expect_gt(nrow(null_s1), 0L,
            label = "at least one S1 replication with non-NA rank_spearman_rho_hr_r_k")

  mean_rho <- mean(null_s1$rank_spearman_rho_hr_r_k, na.rm = TRUE)

  # Exact threshold from test-spec.md v3 §4 SV-3: > 0.55 (lowered from 0.85 in v1/v2)
  expect_gt(
    mean_rho,
    0.55,
    label = paste0("mean Spearman rho (HR+R+K, S1) = ", round(mean_rho, 4),
                   " must exceed 0.55 [test-spec v3 tolerance: 0.55]")
  )
})

test_that("SV-4: zar() failure rate < 1% across all scenarios", {
  skip_if(nchar(.sim_results_path) == 0L,
          message = "sim-zar-results.rds not found via system.file()")

  sim <- readRDS(.sim_results_path)

  expect_true("zar_failed" %in% names(sim),
              label = "zar_failed column present in sim results")

  failure_rate <- mean(sim$zar_failed, na.rm = TRUE)
  expect_lt(failure_rate, 0.01,
            label = paste0("zar() failure rate = ", round(failure_rate * 100, 2), "% ",
                           "must be < 1%"))
})

test_that("SV-5: S4 (SV regime-break) raises top_minus_boundary_zar mean relative to S1", {
  skip_if(nchar(.sim_results_path) == 0L,
          message = "sim-zar-results.rds not found via system.file()")

  sim <- readRDS(.sim_results_path)

  # Column name confirmed from sim-zar-results.rds: top_minus_boundary_zar
  expect_true("top_minus_boundary_zar" %in% names(sim),
              label = "top_minus_boundary_zar column present in sim results")

  s4_mean <- mean(sim$top_minus_boundary_zar[sim$scenario_id == "S4"], na.rm = TRUE)
  s1_mean <- mean(sim$top_minus_boundary_zar[sim$scenario_id == "S1"], na.rm = TRUE)

  # Directional assertion only (test-spec.md §4 SV-5): S4 > S1
  expect_gt(
    s4_mean, s1_mean,
    label = paste0(
      "S4 top_minus_boundary_zar mean (", round(s4_mean, 4),
      ") must exceed S1 (", round(s1_mean, 4),
      ") — regime-break directional assertion"
    )
  )
})

# ===========================================================================
# TS-ZAR-13 — Two-way player duplicate player_id handling (Bug D regression)
# ===========================================================================
#
# When a projection source emits two rows for the same player_id — a hitter
# row and a pitcher row (e.g. Shohei Ohtani in thebatx) — each row must keep
# its own side-specific pool label in zar(). Name-based lookup against a
# named vector returns only the first match per name and would collapse both
# rows to whichever label comes first, producing NAs or wrong zar values on
# the other side. zaa() now exposes per-row pool labels via attr("pool_labels")
# and zar() consumes them positionally.
test_that("TS-ZAR-13: two-way player (duplicate player_id) keeps side-specific pools", {
  # Start from the standard rate fixture (has ERA/WHIP so both sides are
  # scored) and duplicate one hitter's player_id onto a pitcher row.
  fixture <- .fixture_rate
  proj <- fixture$projections

  # Pick the first OF hitter row and the first SP pitcher row, then re-id
  # the SP row to share the hitter's player_id. After replacement_level()
  # the position_assignments named vector will have two entries with the
  # same name but different pool labels ("OF" and "SP").
  of_row   <- which(proj$pos_eligibility == "OF")[1]
  sp_row   <- which(proj$pos_eligibility == "SP")[1]
  skip_if(is.na(of_row) || is.na(sp_row),
          "fixture lacks both OF and SP rows")

  two_way_id <- proj$player_id[of_row]
  proj$player_id[sp_row]   <- two_way_id
  proj$player_name[sp_row] <- proj$player_name[of_row]

  repl <- replacement_level(proj, fixture$config)
  result <- suppressWarnings(zar(repl))

  dup_rows <- which(result$player_id == two_way_id)
  expect_length(dup_rows, 2L)

  # Collect the zar category columns; identify hitter- vs pitcher-only cats
  # by which side of the (duplicated) rows has non-NA zaa values.
  zaa_cols <- grep("^zaa_", names(result), value = TRUE)

  # With the Bug D fix both rows must have at least one non-NA zar value
  # AND a finite total_zar. Before the fix the SP row inherits the OF pool
  # and its pitcher-category zaa inputs have no matching pool distribution,
  # producing all-NA zar categories (and total_zar = 0 via na.rm=TRUE but
  # with no pitcher contribution at all).
  zar_cols <- grep("^zar_", names(result), value = TRUE)
  zar_cols <- setdiff(zar_cols, "total_zar")

  row_has_nonNA <- vapply(
    dup_rows,
    function(i) any(!is.na(unlist(result[i, zar_cols]))),
    logical(1L)
  )
  expect_true(all(row_has_nonNA),
              label = "each duplicated-id row must have at least one non-NA zar_<cat>")

  # The two rows must differ in which categories are non-NA: the hitter row
  # contributes to hitter categories; the pitcher row contributes to pitcher
  # categories. If both rows shared a pool, their NA patterns would match.
  na_pattern_1 <- is.na(unlist(result[dup_rows[1], zar_cols]))
  na_pattern_2 <- is.na(unlist(result[dup_rows[2], zar_cols]))
  expect_false(identical(na_pattern_1, na_pattern_2),
               label = "two-way player rows must have distinct category NA patterns")
})

# ===========================================================================
# Per-side category scoping (Task 5.1)
# ===========================================================================
test_that("zar() output respects per-side category scoping", {
  fx <- make_zar_fixture()
  out <- zar(fx$replacement)

  pitcher_rows <- subset(out, player_type == "pitcher")
  batter_rows  <- subset(out, player_type == "batter")

  # Pitcher rows: NA for batting cats; finite (or NA-with-reason) for pitcher cats.
  expect_true(all(is.na(pitcher_rows$zar_HR)))
  expect_true(all(is.na(pitcher_rows$zar_R)))
  expect_true(all(is.na(pitcher_rows$zar_SB)))
  expect_true(all(is.na(batter_rows$zar_K)))
  expect_true(all(is.na(batter_rows$zar_SV)))

  # total_zar uses na.rm = TRUE so each side's intra-side total is well defined.
  expect_true(all(is.finite(pitcher_rows$total_zar)))
  expect_true(all(is.finite(batter_rows$total_zar)))
})
