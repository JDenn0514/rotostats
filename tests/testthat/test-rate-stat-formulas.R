# tests/testthat/test-rate-stat-formulas.R
#
# Tests for the blended-pool rate-stat formula registry exported by
# rate_stat_formulas() and its internal helpers.

# ---------------------------------------------------------------------------
# 1. rate_stat_formulas() shape and contents
# ---------------------------------------------------------------------------

test_that("rate_stat_formulas() returns a named list with expected entries", {
  rsf <- rate_stat_formulas()
  expect_type(rsf, "list")
  expect_true(length(rsf) >= 10L)
  expect_false(is.null(names(rsf)))
  expect_true(all(nzchar(names(rsf))))

  expected <- c(
    "ERA", "WHIP", "AVG",
    "FIP", "XFIP", "SIERA", "XERA",
    "K/9", "BB/9", "HR/9"
  )
  expect_true(all(expected %in% names(rsf)))
})

test_that("each registry entry has required five fields with correct types", {
  rsf <- rate_stat_formulas()
  required <- c("denominator_col", "scale", "numerator_fn", "direction", "pool_type")
  for (cat in names(rsf)) {
    entry <- rsf[[cat]]
    expect_type(entry, "list")
    expect_true(all(required %in% names(entry)), info = cat)
    expect_type(entry$denominator_col, "character")
    expect_length(entry$denominator_col, 1L)
    expect_true(nzchar(entry$denominator_col), info = cat)
    expect_true(is.numeric(entry$scale) && length(entry$scale) == 1L && is.finite(entry$scale),
                info = cat)
    expect_true(is.function(entry$numerator_fn), info = cat)
    expect_true(entry$direction %in% c("inverse", "standard"), info = cat)
    expect_true(entry$pool_type %in% c("pitcher", "batter"), info = cat)
  }
})

test_that("registry encodes expected direction and pool_type per stat", {
  rsf <- rate_stat_formulas()
  expect_identical(rsf[["ERA"]]$direction, "inverse")
  expect_identical(rsf[["WHIP"]]$direction, "inverse")
  expect_identical(rsf[["FIP"]]$direction, "inverse")
  expect_identical(rsf[["XFIP"]]$direction, "inverse")
  expect_identical(rsf[["SIERA"]]$direction, "inverse")
  expect_identical(rsf[["XERA"]]$direction, "inverse")
  expect_identical(rsf[["BB/9"]]$direction, "inverse")
  expect_identical(rsf[["HR/9"]]$direction, "inverse")

  expect_identical(rsf[["AVG"]]$direction, "standard")
  expect_identical(rsf[["K/9"]]$direction, "standard")

  expect_identical(rsf[["AVG"]]$pool_type, "batter")
  expect_identical(rsf[["ERA"]]$pool_type, "pitcher")
  expect_identical(rsf[["K/9"]]$pool_type, "pitcher")
  expect_identical(rsf[["FIP"]]$pool_type, "pitcher")
})

test_that("numerator_fn implements scale consistently (rate recomposes from sums)", {
  rsf <- rate_stat_formulas()
  # ERA: ER = rate * IP / 9; blended = 9 * sum(ER) / sum(IP) should recover rate
  era_entry <- rsf[["ERA"]]
  rate <- 3.60
  ip   <- 180
  num  <- era_entry$numerator_fn(rate, ip)
  expect_equal(num, rate * ip / 9)
  expect_equal(era_entry$scale * num / ip, rate)

  # WHIP: numerator = rate * IP; scale = 1
  whip_entry <- rsf[["WHIP"]]
  expect_equal(whip_entry$numerator_fn(1.20, 200), 1.20 * 200)
  expect_equal(whip_entry$scale * whip_entry$numerator_fn(1.20, 200) / 200, 1.20)

  # AVG: numerator = rate * AB; scale = 1
  avg_entry <- rsf[["AVG"]]
  expect_equal(avg_entry$numerator_fn(0.275, 600), 0.275 * 600)

  # K/9: numerator = rate * IP / 9; scale = 9
  k9 <- rsf[["K/9"]]
  expect_equal(k9$numerator_fn(9, 180), 9 * 180 / 9)
  expect_equal(k9$scale * k9$numerator_fn(9, 180) / 180, 9)
})

# ---------------------------------------------------------------------------
# 2. .sgp_col_name() sanitizer behavior
# ---------------------------------------------------------------------------

test_that(".sgp_col_name() preserves case for non-slash names", {
  expect_identical(rotostats:::.sgp_col_name("ERA"),   "sgp_ERA")
  expect_identical(rotostats:::.sgp_col_name("WHIP"),  "sgp_WHIP")
  expect_identical(rotostats:::.sgp_col_name("AVG"),   "sgp_AVG")
  expect_identical(rotostats:::.sgp_col_name("FIP"),   "sgp_FIP")
  expect_identical(rotostats:::.sgp_col_name("XFIP"),  "sgp_XFIP")
  expect_identical(rotostats:::.sgp_col_name("SIERA"), "sgp_SIERA")
  expect_identical(rotostats:::.sgp_col_name("XERA"),  "sgp_XERA")
})

test_that(".sgp_col_name() rewrites slash names to lowercase _per_ form", {
  expect_identical(rotostats:::.sgp_col_name("K/9"),  "sgp_k_per_9")
  expect_identical(rotostats:::.sgp_col_name("BB/9"), "sgp_bb_per_9")
  expect_identical(rotostats:::.sgp_col_name("HR/9"), "sgp_hr_per_9")
})

test_that(".sgp_col_name() is vectorized and preserves order", {
  cats <- c("ERA", "K/9", "WHIP", "BB/9", "AVG")
  expect_identical(
    rotostats:::.sgp_col_name(cats),
    c("sgp_ERA", "sgp_k_per_9", "sgp_WHIP", "sgp_bb_per_9", "sgp_AVG")
  )
})

# ---------------------------------------------------------------------------
# 3. .validate_rate_stat_formulas() invariants
# ---------------------------------------------------------------------------

test_that(".validate_rate_stat_formulas() accepts the built-in registry", {
  rsf <- rate_stat_formulas()
  out <- rotostats:::.validate_rate_stat_formulas(rsf)
  expect_type(out, "list")
  expect_true(all(names(out) %in% toupper(names(rsf)) | names(out) %in% names(rsf)))
})

test_that(".validate_rate_stat_formulas() uppercases names (preserving slashes)", {
  custom <- list(
    era = list(
      denominator_col = "IP", scale = 9,
      numerator_fn = function(rate, denom) rate * denom / 9,
      direction = "inverse", pool_type = "pitcher"
    ),
    "k/9" = list(
      denominator_col = "IP", scale = 9,
      numerator_fn = function(rate, denom) rate * denom / 9,
      direction = "standard", pool_type = "pitcher"
    )
  )
  out <- rotostats:::.validate_rate_stat_formulas(custom)
  expect_identical(sort(names(out)), sort(c("ERA", "K/9")))
})

test_that(".validate_rate_stat_formulas() rejects malformed input", {
  expect_error(
    rotostats:::.validate_rate_stat_formulas(list()),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
  expect_error(
    rotostats:::.validate_rate_stat_formulas("not a list"),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
  expect_error(
    rotostats:::.validate_rate_stat_formulas(list(MYSTAT = "not a list")),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
  expect_error(
    rotostats:::.validate_rate_stat_formulas(list(
      MYSTAT = list(denominator_col = "IP", scale = 1,
                    numerator_fn = function(r, d) r * d,
                    direction = "inverse")
    )),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
  expect_error(
    rotostats:::.validate_rate_stat_formulas(list(
      MYSTAT = list(denominator_col = "IP", scale = 1,
                    numerator_fn = function(r, d) r * d,
                    direction = "sideways", pool_type = "pitcher")
    )),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
  expect_error(
    rotostats:::.validate_rate_stat_formulas(list(
      MYSTAT = list(denominator_col = "IP", scale = 1,
                    numerator_fn = function(r, d) r * d,
                    direction = "inverse", pool_type = "neither")
    )),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
  expect_error(
    rotostats:::.validate_rate_stat_formulas(list(
      MYSTAT = list(denominator_col = 123, scale = 1,
                    numerator_fn = function(r, d) r * d,
                    direction = "inverse", pool_type = "pitcher")
    )),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
  expect_error(
    rotostats:::.validate_rate_stat_formulas(list(
      MYSTAT = list(denominator_col = "IP", scale = NA_real_,
                    numerator_fn = function(r, d) r * d,
                    direction = "inverse", pool_type = "pitcher")
    )),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
  expect_error(
    rotostats:::.validate_rate_stat_formulas(list(
      MYSTAT = list(denominator_col = "IP", scale = 1,
                    numerator_fn = "not-a-function",
                    direction = "inverse", pool_type = "pitcher")
    )),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
})

test_that("validator rejects non-character source_col", {
  rsf <- list(BAD = list(source_col = 42, denominator_col = "AB", scale = 1,
                          numerator_fn = function(r, d) r * d,
                          direction = "standard", pool_type = "batter"))
  expect_error(
    rotostats:::.validate_rate_stat_formulas(rsf),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
})

test_that("validator rejects empty-string source_col", {
  rsf <- list(BAD = list(source_col = "", denominator_col = "AB", scale = 1,
                          numerator_fn = function(r, d) r * d,
                          direction = "standard", pool_type = "batter"))
  expect_error(
    rotostats:::.validate_rate_stat_formulas(rsf),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
})

# ---------------------------------------------------------------------------
# 4. .resolve_source_col() helper
# ---------------------------------------------------------------------------

test_that(".resolve_source_col() returns source_col when present, else entry name", {
  rsf <- list(
    "K%_BATTER" = list(source_col = "K%", denominator_col = "PA", scale = 1,
                       numerator_fn = function(r, d) r * d,
                       direction = "inverse", pool_type = "batter"),
    "AVG"       = list(denominator_col = "AB", scale = 1,
                       numerator_fn = function(r, d) r * d,
                       direction = "standard", pool_type = "batter")
  )
  expect_identical(rotostats:::.resolve_source_col(rsf, "K%_BATTER"), "K%")
  expect_identical(rotostats:::.resolve_source_col(rsf, "AVG"), "AVG")
})

# ---------------------------------------------------------------------------
# 5. Multi-component entry validation
# ---------------------------------------------------------------------------

test_that("validator accepts a valid multi-component entry", {
  rsf <- list(
    OPS = list(
      components = list(
        OBP = list(denominator_col = "PA", scale = 1, numerator_fn = function(r, d) r * d),
        SLG = list(denominator_col = "AB", scale = 1, numerator_fn = function(r, d) r * d)
      ),
      combine = "sum",
      direction = "standard",
      pool_type = "batter"
    )
  )
  expect_silent(rotostats:::.validate_rate_stat_formulas(rsf))
})

test_that("validator rejects multi-component with missing combine", {
  rsf <- list(
    OPS = list(
      components = list(
        OBP = list(denominator_col = "PA", scale = 1, numerator_fn = function(r, d) r * d)
      ),
      direction = "standard",
      pool_type = "batter"
    )
  )
  expect_error(
    rotostats:::.validate_rate_stat_formulas(rsf),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
})

test_that("validator rejects mixed shape (both components and denominator_col)", {
  rsf <- list(
    BAD = list(
      components = list(),
      denominator_col = "PA",
      scale = 1,
      numerator_fn = function(r, d) r * d,
      direction = "standard",
      pool_type = "batter"
    )
  )
  expect_error(
    rotostats:::.validate_rate_stat_formulas(rsf),
    class = "rotostats_error_invalid_rate_stat_formula"
  )
})

# ---------------------------------------------------------------------------
# 6. New single-component entries (Task 2.3)
# ---------------------------------------------------------------------------

test_that("registry includes new single-component entries with correct fields", {
  rsf <- rate_stat_formulas()
  new_entries <- c("OBP", "SLG", "SO/9", "SO/BB",
                   "K%_BATTER", "K%_PITCHER",
                   "BB%_BATTER", "BB%_PITCHER",
                   "SO%_BATTER", "SO%_PITCHER")
  expect_true(all(new_entries %in% names(rsf)))

  expect_identical(rsf[["OBP"]]$denominator_col, "PA")
  expect_identical(rsf[["OBP"]]$direction, "standard")
  expect_identical(rsf[["OBP"]]$pool_type, "batter")

  expect_identical(rsf[["SLG"]]$denominator_col, "AB")
  expect_identical(rsf[["SLG"]]$direction, "standard")

  expect_identical(rsf[["SO/9"]]$denominator_col, "IP")
  expect_identical(rsf[["SO/9"]]$scale, 9)

  expect_identical(rsf[["SO/BB"]]$denominator_col, "BB")

  expect_identical(rsf[["K%_BATTER"]]$source_col, "K%")
  expect_identical(rsf[["K%_BATTER"]]$denominator_col, "PA")
  expect_identical(rsf[["K%_BATTER"]]$direction, "inverse")
  expect_identical(rsf[["K%_BATTER"]]$pool_type, "batter")

  expect_identical(rsf[["K%_PITCHER"]]$source_col, "K%")
  expect_identical(rsf[["K%_PITCHER"]]$denominator_col, "TBF")
  expect_identical(rsf[["K%_PITCHER"]]$direction, "standard")
  expect_identical(rsf[["K%_PITCHER"]]$pool_type, "pitcher")

  expect_identical(rsf[["BB%_BATTER"]]$direction, "standard")   # batter walks: higher better
  expect_identical(rsf[["BB%_PITCHER"]]$direction, "inverse")  # pitcher walks: lower better

  expect_identical(rsf[["SO%_BATTER"]]$direction, "inverse")
  expect_identical(rsf[["SO%_PITCHER"]]$direction, "standard")
})
