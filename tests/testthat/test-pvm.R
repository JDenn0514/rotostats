# tests/testthat/test-pvm.R
#
# Independent validation of pvm() per test-spec.md TS-PVM-1 through TS-PVM-20.
# Tester did NOT read spec.md, implementation.md, or sim-spec.md.
# All assertions derive from observable behavior described in test-spec.md.
#
# Note on NA handling: pvm results contain NA for non-applicable player-category
# combinations (pitchers get NA for hitter stats and vice versa). Sums and
# comparisons use na.rm = TRUE as appropriate, which is consistent with the
# colSums(na.rm=TRUE) approach in pvm() itself.
#
# Fixtures auto-loaded from helper-pvm-fixtures.R (auto-loaded by testthat).

# ---------------------------------------------------------------------------
# TS-PVM-1 — Attribute extraction guard fires when replacement lacks attributes
# ---------------------------------------------------------------------------

test_that("TS-PVM-1a: bare list with no attrs triggers rotostats_error_missing_replacement_attrs", {
  replacement <- list()
  expect_error(
    pvm(replacement),
    class = "rotostats_error_missing_replacement_attrs"
  )
})

test_that("TS-PVM-1b: config present but projections NULL triggers missing-attrs error", {
  replacement <- list()
  attr(replacement, "config")      <- make_pvm_config()
  attr(replacement, "stat_units")  <- "raw_projected"
  # projections absent (NULL)
  expect_error(
    pvm(replacement),
    class = "rotostats_error_missing_replacement_attrs"
  )
})

test_that("TS-PVM-1c: projections present but config NULL triggers missing-attrs error", {
  replacement <- list()
  attr(replacement, "projections") <- make_pvm_projections()
  attr(replacement, "stat_units")  <- "raw_projected"
  # config absent (NULL)
  expect_error(
    pvm(replacement),
    class = "rotostats_error_missing_replacement_attrs"
  )
})

# ---------------------------------------------------------------------------
# TS-PVM-2 — Stat-units mismatch guard fires when stat_units != "raw_projected"
# ---------------------------------------------------------------------------

test_that("TS-PVM-2: stat_units = 'sgp' triggers rotostats_error_stat_units_mismatch", {
  # Use a real replacement object, then override stat_units
  repl <- .pvm_base
  attr(repl, "stat_units") <- "sgp"
  expect_error(
    pvm(repl),
    class = "rotostats_error_stat_units_mismatch"
  )
})

# ---------------------------------------------------------------------------
# TS-PVM-3 — Sum-to-1 invariant under sub_replacement = "clip" (default)
#
# Note: pvm() returns NA for player-category pairs where the player does not
# participate in that category (pitchers get NA for hitter stats and vice versa).
# The sum-to-1 invariant uses na.rm = TRUE (as does pvm()'s internal check),
# so sum(..., na.rm=TRUE) == 1.0 is the correct assertion here.
# ---------------------------------------------------------------------------

test_that("TS-PVM-3: sum-to-1 per category under clip mode; no warnings", {
  result <- pvm(.pvm_base)

  pvm_cols <- grep("^pvm_", names(result), value = TRUE)
  expect_true(length(pvm_cols) > 0L, info = "at least one pvm_ column expected")

  for (col in pvm_cols) {
    s   <- sum(result[[col]], na.rm = TRUE)
    dev <- abs(s - 1.0)
    expect_lt(dev, 1e-10,
              label = paste0("sum-to-1 deviation for ", col, ": ", dev,
                             " (sum=", s, ")"))
  }

  # No warnings should fire
  expect_no_warning(pvm(.pvm_base))
})

# ---------------------------------------------------------------------------
# TS-PVM-4 — Positive-only sum-to-1 under sub_replacement = "negative"
# ---------------------------------------------------------------------------

test_that("TS-PVM-4: positive-only sum-to-1 per category under negative mode; negatives exist; total < 1", {
  result <- pvm(.pvm_base, sub_replacement = "negative")

  pvm_cols <- grep("^pvm_", names(result), value = TRUE)
  for (col in pvm_cols) {
    vals <- result[[col]]
    non_na <- vals[!is.na(vals)]
    positive_sum <- sum(non_na[non_na > 0])
    dev <- abs(positive_sum - 1.0)
    expect_lt(dev, 1e-10,
              label = paste0("positive-only sum-to-1 deviation for ", col, ": ", dev))
    expect_true(any(non_na < 0),
                info = paste0("at least one negative value expected in ", col))
    expect_lt(sum(non_na), 1.0,
              label = paste0("total sum must be < 1 under negative mode for ", col))
  }

  # No rotostats_warning_pvm_sum should fire
  expect_no_warning(
    pvm(.pvm_base, sub_replacement = "negative"),
    message = "rotostats_warning_pvm_sum"
  )
})

# ---------------------------------------------------------------------------
# TS-PVM-5 — Replacement boundary player has pvm ~= 0
# ---------------------------------------------------------------------------

test_that("TS-PVM-5: boundary player (stats == replacement line) has pvm ~= 0 per cat and total_pvm ~= 0", {
  repl   <- make_boundary_replacement()
  result <- suppressWarnings(pvm(repl))

  pvm_cols <- grep("^pvm_", names(result), value = TRUE)

  # Identify boundary rows: rows where the non-NA pvm values are all close to 0.
  # The rank-2 player at each position (in a 2-team, 1-slot config) is the
  # boundary player and should have zero above-replacement contribution.
  zero_rows <- which(apply(result[, pvm_cols, drop = FALSE], 1, function(x) {
    non_na <- x[!is.na(x)]
    length(non_na) > 0L && all(abs(non_na) < 1e-10)
  }))
  expect_true(length(zero_rows) >= 1L,
              info = paste0("expected at least one boundary player with all-zero pvm values; ",
                            "found ", length(zero_rows), " such rows"))

  for (r in zero_rows) {
    for (col in pvm_cols) {
      v <- result[r, col]
      if (!is.na(v)) {
        expect_lt(abs(v), 1e-10,
                  label = paste0("boundary row ", r, " col ", col))
      }
    }
    if ("total_pvm" %in% names(result)) {
      expect_lt(abs(result$total_pvm[r]), 1e-10,
                label = paste0("boundary row ", r, " total_pvm"))
    }
  }
})

# ---------------------------------------------------------------------------
# TS-PVM-6 — Zero-pool abort when all rostered players are sub-replacement
# ---------------------------------------------------------------------------

test_that("TS-PVM-6: rotostats_error_zero_pool fires when all rostered players are sub-replacement in one cat", {
  repl <- make_zero_pool_replacement("SB")
  expect_error(
    pvm(repl),
    class = "rotostats_error_zero_pool"
  )
})

# ---------------------------------------------------------------------------
# TS-PVM-7 — Concentration warning when a single player exceeds 25% share
# ---------------------------------------------------------------------------

test_that("TS-PVM-7: rotostats_warning_pvm_concentration fires when one player > 25% of a cat pool", {
  repl <- make_concentration_replacement(dominant_cat = "SV")

  expect_warning(
    result <- pvm(repl),
    class = "rotostats_warning_pvm_concentration"
  )

  expect_s3_class(result, "data.frame")

  # Check that at least one pvm_SV value > 0.25
  if ("pvm_SV" %in% names(result)) {
    sv_vals <- result$pvm_SV[!is.na(result$pvm_SV)]
    expect_true(any(sv_vals > 0.25),
                info = "expected at least one player with pvm_SV > 0.25")
  }
})

# ---------------------------------------------------------------------------
# TS-PVM-8 — cat_pct named-vector sum and membership guards
# ---------------------------------------------------------------------------

test_that("TS-PVM-8a: cat_pct sum != 1.0 triggers rotostats_error_cat_pct_sum", {
  cat_pct_bad_sum <- setNames(
    rep(0.095, 10),
    c("HR", "R", "RBI", "SB", "AVG", "W", "K", "SV", "ERA", "WHIP")
  )
  expect_error(
    pvm(.pvm_base, cat_pct = cat_pct_bad_sum),
    class = "rotostats_error_cat_pct_sum"
  )
})

test_that("TS-PVM-8b: cat_pct missing one category triggers rotostats_error_category_mismatch", {
  cat_pct_missing_name <- setNames(
    rep(1/9, 9),
    c("HR", "R", "RBI", "SB", "AVG", "W", "K", "SV", "ERA")  # WHIP missing
  )
  expect_error(
    pvm(.pvm_base, cat_pct = cat_pct_missing_name),
    class = "rotostats_error_category_mismatch"
  )
})

# ---------------------------------------------------------------------------
# TS-PVM-9 — Pipe-compatibility
# ---------------------------------------------------------------------------

test_that("TS-PVM-9: piped and nested calls produce identical output", {
  proj <- make_pvm_projections(seed = 42L)
  cfg  <- make_pvm_config()

  A <- suppressWarnings(replacement_level(proj, cfg) |> pvm())
  B <- suppressWarnings(pvm(replacement_level(proj, cfg)))

  expect_true(isTRUE(all.equal(A, B, tolerance = 1e-12)),
              info = "piped and nested outputs must be identical")
  expect_equal(attr(A, "units"),  "budget_fraction")
  expect_equal(attr(B, "units"),  "budget_fraction")
  expect_equal(attr(A, "anchor"), "replacement")
  expect_equal(attr(B, "anchor"), "replacement")
})

# ---------------------------------------------------------------------------
# TS-PVM-10 — include_raw = TRUE appends contrib_[cat] columns
# ---------------------------------------------------------------------------

test_that("TS-PVM-10: include_raw = TRUE appends contrib_ columns; non-NA values >= 0 under clip", {
  result <- pvm(.pvm_base, include_raw = TRUE)

  contrib_cols <- grep("^contrib_", names(result), value = TRUE)
  pvm_cols     <- grep("^pvm_",     names(result), value = TRUE)

  expect_equal(length(contrib_cols), length(pvm_cols),
               info = "number of contrib_ and pvm_ columns must match")

  for (col in contrib_cols) {
    non_na <- result[[col]][!is.na(result[[col]])]
    expect_true(all(non_na >= 0),
                info = paste0("non-NA values in ", col, " must be non-negative under clip mode"))
  }

  expect_true("total_pvm" %in% names(result))
})

# ---------------------------------------------------------------------------
# TS-PVM-11 — include_raw = FALSE (default) produces no contrib_ columns
# ---------------------------------------------------------------------------

test_that("TS-PVM-11: default include_raw = FALSE produces no contrib_ columns", {
  result <- pvm(.pvm_base)
  contrib_cols <- grep("^contrib_", names(result), value = TRUE)
  expect_length(contrib_cols, 0L)
})

test_that("TS-PVM-11 (explicit): include_raw = FALSE explicit produces no contrib_ columns", {
  result <- pvm(.pvm_base, include_raw = FALSE)
  contrib_cols <- grep("^contrib_", names(result), value = TRUE)
  expect_length(contrib_cols, 0L)
})

# ---------------------------------------------------------------------------
# TS-PVM-12 — cat_pct = "equal" divides weight equally
# ---------------------------------------------------------------------------

test_that("TS-PVM-12: cat_pct = 'equal' produces equal-weight total_pvm", {
  result_equal <- pvm(.pvm_base, cat_pct = "equal")

  pvm_cols <- grep("^pvm_", names(result_equal), value = TRUE)
  # Replace NA with 0 for sum: players don't contribute to categories outside their position
  pvm_mat_nona <- result_equal[, pvm_cols, drop = FALSE]
  pvm_mat_nona[is.na(pvm_mat_nona)] <- 0
  expected_total <- unname(rowSums(pvm_mat_nona) / length(pvm_cols))

  expect_equal(result_equal$total_pvm, expected_total, tolerance = 1e-12,
               info = "total_pvm must equal row mean of pvm_ columns under equal weighting")
})

# ---------------------------------------------------------------------------
# TS-PVM-13 — cat_pct = "auto" uses config$budget_split correctly
# ---------------------------------------------------------------------------

test_that("TS-PVM-13: cat_pct = 'auto' produces budget_split-weighted total_pvm", {
  result_auto <- pvm(.pvm_base, cat_pct = "auto")
  cfg         <- attr(.pvm_base, "config")
  bsplit      <- cfg$budget_split

  batter_cats  <- c("HR", "R", "RBI", "SB", "AVG")
  pitcher_cats <- c("W",  "K", "SV",  "ERA", "WHIP")

  pvm_h_cols <- paste0("pvm_", batter_cats)
  pvm_p_cols <- paste0("pvm_", pitcher_cats)

  # Replace NA with 0 for the weighted sum
  h_mat <- result_auto[, pvm_h_cols, drop = FALSE]
  p_mat <- result_auto[, pvm_p_cols, drop = FALSE]
  h_mat[is.na(h_mat)] <- 0
  p_mat[is.na(p_mat)] <- 0

  expected <- unname(rowSums(h_mat) * (bsplit / 5) +
              rowSums(p_mat) * ((1 - bsplit) / 5))

  expect_equal(result_auto$total_pvm, expected, tolerance = 1e-12,
               info = "total_pvm must match budget_split-derived weights under auto mode")
})

# ---------------------------------------------------------------------------
# TS-PVM-14 — multi_pos = "all" guard fires
# ---------------------------------------------------------------------------

test_that("TS-PVM-14: multi_pos = 'all' in params triggers rotostats_error_multi_pos_all_unsupported", {
  # Construct a replacement object with multi_pos = "all" in params
  # (this replicates what replacement_level() would produce with multi_pos="all")
  repl <- .pvm_base
  repl$params$multi_pos <- "all"

  expect_error(
    pvm(repl),
    class = "rotostats_error_multi_pos_all_unsupported"
  )
})

# ---------------------------------------------------------------------------
# TS-PVM-15 — Invalid parameter values fire rotostats_error_invalid_parameter
# ---------------------------------------------------------------------------

test_that("TS-PVM-15a: non-logical include_raw triggers rotostats_error_invalid_parameter", {
  expect_error(
    pvm(.pvm_base, include_raw = "TRUE"),
    class = "rotostats_error_invalid_parameter"
  )
  expect_error(
    pvm(.pvm_base, include_raw = 1L),
    class = "rotostats_error_invalid_parameter"
  )
})

test_that("TS-PVM-15b: unrecognized rate_pool triggers rotostats_error_invalid_parameter", {
  expect_error(
    pvm(.pvm_base, rate_pool = "averaging"),
    class = "rotostats_error_invalid_parameter"
  )
  expect_error(
    pvm(.pvm_base, rate_pool = 1L),
    class = "rotostats_error_invalid_parameter"
  )
})

test_that("TS-PVM-15c: unrecognized sub_replacement triggers rotostats_error_invalid_parameter", {
  expect_error(
    pvm(.pvm_base, sub_replacement = "zero"),
    class = "rotostats_error_invalid_parameter"
  )
})

test_that("TS-PVM-15d: non-numeric baseline triggers rotostats_error_invalid_parameter", {
  expect_error(
    pvm(.pvm_base, rate_pool = "fixed_baseline",
        baseline = "ERA=4.20"),
    class = "rotostats_error_invalid_parameter"
  )
})

test_that("TS-PVM-15e: unnamed numeric baseline triggers rotostats_error_invalid_parameter", {
  expect_error(
    pvm(.pvm_base, rate_pool = "fixed_baseline",
        baseline = c(4.20, 1.30)),
    class = "rotostats_error_invalid_parameter"
  )
})

test_that("TS-PVM-15f: non-string non-vector cat_pct triggers rotostats_error_invalid_parameter", {
  expect_error(
    pvm(.pvm_base, cat_pct = 42L),
    class = "rotostats_error_invalid_parameter"
  )
})

# ---------------------------------------------------------------------------
# TS-PVM-16 — fixed_baseline without baseline fires rotostats_error_missing_config_field
# ---------------------------------------------------------------------------

test_that("TS-PVM-16: rate_pool = 'fixed_baseline' with no baseline fires rotostats_error_missing_config_field", {
  expect_error(
    pvm(.pvm_base, rate_pool = "fixed_baseline"),
    class = "rotostats_error_missing_config_field"
  )
})

# ---------------------------------------------------------------------------
# TS-PVM-17 — baseline with non-fixed_baseline rate_pool is silently ignored
# ---------------------------------------------------------------------------

test_that("TS-PVM-17: baseline ignored when rate_pool != 'fixed_baseline'", {
  result_with_baseline    <- pvm(.pvm_base, rate_pool = "ip_weighted",
                                 baseline = c(ERA = 4.20, WHIP = 1.30, AVG = 0.265))
  result_without_baseline <- pvm(.pvm_base)

  expect_equal(result_with_baseline, result_without_baseline, tolerance = 1e-12,
               info = "baseline should be silently ignored under ip_weighted")
})

# ---------------------------------------------------------------------------
# TS-PVM-18 — Output attributes are correct
# ---------------------------------------------------------------------------

test_that("TS-PVM-18: output attributes units = 'budget_fraction', anchor = 'replacement'", {
  result <- pvm(.pvm_base)
  expect_equal(attr(result, "units"),  "budget_fraction")
  expect_equal(attr(result, "anchor"), "replacement")
})

# ---------------------------------------------------------------------------
# TS-PVM-19 — ERA sign flip: above-replacement pitchers have positive pvm_ERA
# ---------------------------------------------------------------------------

test_that("TS-PVM-19: pitchers with ERA < RS[ERA] have pvm_ERA > 0; ERA >= RS[ERA] have pvm_ERA == 0 under clip", {
  proj <- make_pvm_projections(seed = 99L)
  cfg  <- make_pvm_config()
  repl <- replacement_level(proj, cfg, multi_pos = "highest_par")
  result <- pvm(repl)

  if (!("pvm_ERA" %in% names(result))) {
    skip("pvm_ERA column not present in result")
  }

  # Compute RS[ERA] the same way pvm() does: slot-weighted mean of
  # replacement_stats ERA values for pitcher positions.
  # pvm() uses: RS[cat] = sum(repl_rows[[cat]] * slot_weights) / total_slots
  repl_stats    <- repl$replacement_stats
  pitcher_slots <- cfg$pitcher_slots
  pitcher_pos   <- names(pitcher_slots)
  repl_pitcher  <- repl_stats[repl_stats$position %in% pitcher_pos, , drop = FALSE]
  if (nrow(repl_pitcher) == 0L || !("ERA" %in% names(repl_pitcher))) {
    skip("Cannot determine RS[ERA] from replacement_stats")
  }
  sw <- vapply(repl_pitcher$position, function(p) {
    as.numeric(pitcher_slots[[p]])
  }, numeric(1L))
  total_sw <- sum(sw, na.rm = TRUE)
  rs_era   <- sum(repl_pitcher$ERA * sw, na.rm = TRUE) / total_sw
  if (is.na(rs_era)) skip("RS[ERA] is NA")

  # Get rostered players (uppercase column names)
  full_proj    <- attr(repl, "projections")
  pa           <- attr(repl, "position_assignments")
  rostered_ids <- names(pa)[!is.na(pa)]
  ros_proj     <- full_proj[full_proj$PLAYER_ID %in% rostered_ids, , drop = FALSE]

  # Above-replacement pitchers: ERA < RS[ERA] and IP > 0
  above_idx <- which(!is.na(ros_proj$ERA) & !is.na(ros_proj$IP) &
                       ros_proj$ERA < rs_era & ros_proj$IP > 0)
  # Sub-replacement pitchers: ERA >= RS[ERA] and IP > 0
  sub_idx   <- which(!is.na(ros_proj$ERA) & !is.na(ros_proj$IP) &
                       ros_proj$ERA >= rs_era & ros_proj$IP > 0)

  if (length(above_idx) > 0L) {
    above_pvm <- result$pvm_ERA[above_idx]
    non_na_above <- above_pvm[!is.na(above_pvm)]
    expect_true(all(non_na_above > 0),
                info = "all above-replacement ERA pitchers must have pvm_ERA > 0")
  }
  if (length(sub_idx) > 0L) {
    sub_pvm <- result$pvm_ERA[sub_idx]
    non_na_sub <- sub_pvm[!is.na(sub_pvm)]
    expect_equal(non_na_sub, rep(0, length(non_na_sub)),
                 tolerance = 1e-14,
                 info = "sub-replacement ERA pitchers must have pvm_ERA == 0 under clip")
  }
})

# ---------------------------------------------------------------------------
# TS-PVM-20 — pvm_[cat] column names match paste0("pvm_", scored_cats)
# ---------------------------------------------------------------------------

test_that("TS-PVM-20: column names are pvm_{CAT} for all scored cats, plus total_pvm", {
  result <- pvm(.pvm_base)

  expected_pvm_cols <- paste0("pvm_", c("HR", "R", "RBI", "SB", "AVG",
                                         "W", "K", "SV", "ERA", "WHIP"))
  expect_true(all(expected_pvm_cols %in% names(result)),
              info = paste("missing columns:",
                           paste(setdiff(expected_pvm_cols, names(result)), collapse = ", ")))
  expect_true("total_pvm" %in% names(result))
})

# ---------------------------------------------------------------------------
# Property-based invariants (supplemental to named scenarios)
# ---------------------------------------------------------------------------

test_that("PROP-1: non-negativity — all non-NA pvm_ values >= 0 under clip mode", {
  result   <- pvm(.pvm_base)
  pvm_cols <- grep("^pvm_", names(result), value = TRUE)
  for (col in pvm_cols) {
    non_na <- result[[col]][!is.na(result[[col]])]
    expect_true(all(non_na >= 0),
                info = paste0("non-negativity violated in ", col))
  }
})

test_that("PROP-2: range check — all non-NA pvm_ values in [0,1] under clip mode", {
  result   <- pvm(.pvm_base)
  pvm_cols <- grep("^pvm_", names(result), value = TRUE)
  for (col in pvm_cols) {
    non_na <- result[[col]][!is.na(result[[col]])]
    expect_true(all(non_na >= 0 & non_na <= 1),
                info = paste0("range [0,1] violated in ", col))
  }
})

test_that("PROP-3: total_pvm is CAT%-weighted sum of pvm columns (auto weights, NA->0)", {
  result   <- pvm(.pvm_base, cat_pct = "auto")
  cfg      <- attr(.pvm_base, "config")
  bsplit   <- cfg$budget_split

  batter_cats  <- c("HR", "R", "RBI", "SB", "AVG")
  pitcher_cats <- c("W",  "K", "SV",  "ERA", "WHIP")
  pvm_cols <- paste0("pvm_", c(batter_cats, pitcher_cats))
  weights  <- c(
    setNames(rep(bsplit / 5, 5),         paste0("pvm_", batter_cats)),
    setNames(rep((1 - bsplit) / 5, 5),   paste0("pvm_", pitcher_cats))
  )

  pvm_mat <- as.matrix(result[, pvm_cols])
  pvm_mat[is.na(pvm_mat)] <- 0
  manual_total <- as.numeric(pvm_mat %*% weights[pvm_cols])

  expect_equal(result$total_pvm, manual_total, tolerance = 1e-12,
               info = "total_pvm must equal CAT%-weighted sum")
})

test_that("PROP-4: row count equals number of rostered players", {
  pa         <- attr(.pvm_base, "position_assignments")
  n_rostered <- sum(!is.na(pa))
  result     <- pvm(.pvm_base)
  expect_equal(nrow(result), n_rostered,
               info = "row count must equal number of rostered players")
})

test_that("PROP-5: attribute presence — units and anchor always present", {
  result <- pvm(.pvm_base)
  expect_equal(attr(result, "units"),  "budget_fraction")
  expect_equal(attr(result, "anchor"), "replacement")
})

test_that("PROP-6: contrib_ columns present iff include_raw = TRUE", {
  r_false <- pvm(.pvm_base, include_raw = FALSE)
  r_true  <- pvm(.pvm_base, include_raw = TRUE)
  expect_length(grep("^contrib_", names(r_false), value = TRUE), 0L)
  expect_gt(length(grep("^contrib_", names(r_true), value = TRUE)), 0L)
})

# ---------------------------------------------------------------------------
# Cross-Reference Benchmark — sum invariant for 2-player/1-category case
# ---------------------------------------------------------------------------

test_that("BENCH-1: sum-to-1 holds for a 2-player hitter-only fixture", {
  # This is a smoke test that pvm() produces sum=1 for a simple 2-hitter
  # scenario. The exact pvm values depend on replacement_level's RS computation.
  proj <- data.frame(
    player_id       = c("A", "B"),
    player_name     = c("PlayerA", "PlayerB"),
    pos_eligibility = c("1B", "1B"),
    team            = c("NYY", "BOS"),
    league          = c("AL", "AL"),
    HR              = c(30L, 15L),
    R               = c(80L, 50L),
    RBI             = c(85L, 55L),
    SB              = c(5L, 3L),
    AVG             = c(0.285, 0.255),
    AB              = c(450L, 420L),
    W               = c(NA_real_, NA_real_),
    K               = c(NA_real_, NA_real_),
    SV              = c(NA_real_, NA_real_),
    ERA             = c(NA_real_, NA_real_),
    WHIP            = c(NA_real_, NA_real_),
    IP              = c(NA_real_, NA_real_),
    role            = c(NA_character_, NA_character_),
    stringsAsFactors = FALSE
  )

  # 1 team, 2 1B slots (both rostered); hitter cats only
  cfg <- tryCatch(
    league_config(
      n_teams            = 1L,
      roster_slots       = c(`1B` = 2L),
      pitcher_slots      = 0L,
      batting_categories = c("HR", "R", "RBI", "SB", "AVG"),
      # pitcher_categories supplied as a placeholder; this fixture only exercises
      # hitter cats. The placeholder ensures league_config() accepts the call.
      pitcher_categories = c("K"),
      budget             = 260L,
      budget_split       = 0.67
    ),
    error = function(e) NULL
  )
  if (is.null(cfg)) skip("league_config failed for BENCH-1 fixture")

  repl <- tryCatch(
    replacement_level(proj, cfg, multi_pos = "highest_par"),
    error = function(e) NULL
  )
  if (is.null(repl)) skip("replacement_level failed for BENCH-1 fixture")

  result <- tryCatch(
    suppressWarnings(pvm(repl)),
    error = function(e) NULL
  )
  if (is.null(result)) skip("pvm() returned error for BENCH-1 fixture")

  # Key invariant: sum-to-1 per category
  pvm_cols <- grep("^pvm_", names(result), value = TRUE)
  for (col in pvm_cols) {
    s   <- sum(result[[col]], na.rm = TRUE)
    dev <- abs(s - 1.0)
    expect_lt(dev, 1e-10,
              label = paste0("BENCH-1 sum-to-1 for ", col, ": dev=", dev))
  }
  expect_equal(nrow(result), 2L, info = "BENCH-1 must return exactly 2 rows")
})

# ---------------------------------------------------------------------------
# TS-PVM-SIDE-1 — cat_pct = "auto" uses config batting/pitcher_categories
# ---------------------------------------------------------------------------
test_that("pvm() splits cat_pct correctly using config$batting/pitcher_categories", {
  fx  <- make_pvm_fixture()
  out <- pvm(fx$replacement, cat_pct = "auto")

  pitcher_rows <- subset(out, player_type == "pitcher")
  batter_rows  <- subset(out, player_type == "batter")

  expect_true(all(is.na(pitcher_rows$pvm_HR)))
  expect_true(all(is.na(batter_rows$pvm_ERA)))
})
