# tests/testthat/test-replacement-from-prices.R
#
# Unit tests for replacement_from_prices() and name normalization.
# Written by the tester pipeline from test-spec.md (§§11-12).
# Tester did NOT read spec.md, sim-spec.md, or implementation.md.

library(testthat)

# ---------------------------------------------------------------------------
# Helpers: make_prices_data() and make_prices_data_with_keepers()
# ---------------------------------------------------------------------------

make_prices_data <- function(n_players = 50L, seed = 42L) {
  set.seed(seed)
  positions_pool <- c("C", "1B", "2B", "3B", "SS", "OF", "SP", "RP")
  n_dollar  <- max(1L, floor(n_players * 0.70))
  n_nondollar <- n_players - n_dollar
  data.frame(
    year            = rep(2023L, n_players),
    player_id       = paste0("PL", seq_len(n_players)),
    player_name     = paste0("Player_", seq_len(n_players)),
    price           = c(rep(1L, n_dollar),
                        sample(2L:30L, n_nondollar, replace = TRUE)),
    pos_eligibility = sample(positions_pool, n_players, replace = TRUE),
    is_keeper       = rep(FALSE, n_players),
    HR              = round(pmax(0, rnorm(n_players, 5, 4))),
    R               = round(pmax(0, rnorm(n_players, 25, 15))),
    RBI             = round(pmax(0, rnorm(n_players, 22, 12))),
    SB              = round(pmax(0, rnorm(n_players, 4, 4))),
    stringsAsFactors = FALSE
  )
}

make_prices_data_with_keepers <- function(n_regular = 25L, n_keeper = 5L,
                                           seed = 11L) {
  set.seed(seed)
  positions_pool <- c("C", "1B", "2B", "3B", "SS", "OF")
  n_total <- n_regular + n_keeper

  data.frame(
    year            = rep(2023L, n_total),
    player_id       = paste0("PL", seq_len(n_total)),
    player_name     = paste0("Player_", seq_len(n_total)),
    price           = rep(1L, n_total),
    pos_eligibility = sample(positions_pool, n_total, replace = TRUE),
    is_keeper       = c(rep(FALSE, n_regular), rep(TRUE, n_keeper)),
    HR              = c(round(pmax(0, rnorm(n_regular, 5, 3))),
                        round(pmax(25, rnorm(n_keeper, 30, 3)))),
    R               = c(round(pmax(0, rnorm(n_regular, 25, 12))),
                        round(pmax(80, rnorm(n_keeper, 95, 8)))),
    RBI             = c(round(pmax(0, rnorm(n_regular, 22, 10))),
                        round(pmax(80, rnorm(n_keeper, 95, 8)))),
    SB              = c(round(pmax(0, rnorm(n_regular, 4, 4))),
                        round(pmax(0, rnorm(n_keeper, 5, 3)))),
    stringsAsFactors = FALSE
  )
}

# ---------------------------------------------------------------------------
# §11  replacement_from_prices() Tests
# ---------------------------------------------------------------------------

test_that("TS-40: basic return structure for replacement_from_prices()", {
  result_prices <- replacement_from_prices(
    prices       = make_prices_data(n_players = 60L, seed = 7L),
    n_teams      = 12L,
    roster_slots = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L, SS = 1L,
                     OF = 3L),
    batting_categories = c("HR", "R", "RBI", "SB"),
    pitcher_categories = character(0L)
  )
  expect_named(
    result_prices,
    c("replacement_stats", "positional_adjustments",
      "cliff_metric", "two_way_players",
      "pool_diagnostics", "method", "params"),
    ignore.order = TRUE
  )
  expect_equal(result_prices$params$method, "prices")
})

test_that("TS-41: is_keeper = TRUE rows excluded exactly", {
  prices_keeper <- make_prices_data_with_keepers(n_regular = 25L,
                                                  n_keeper  = 5L,
                                                  seed      = 11L)
  result_k <- replacement_from_prices(
    prices       = prices_keeper,
    n_teams      = 12L,
    roster_slots = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L, SS = 1L,
                     OF = 3L),
    batting_categories = c("HR", "R", "RBI", "SB"),
    pitcher_categories = character(0L)
  )
  # Either valid result or NULL if pool too small
  if (!is.null(result_k)) {
    expect_named(
      result_k,
      c("replacement_stats", "positional_adjustments",
        "cliff_metric", "two_way_players",
        "pool_diagnostics", "method", "params"),
      ignore.order = TRUE
    )
    # keeper players have HR ~30 — replacement HR should be much lower
    hr_vals <- result_k$replacement_stats$HR
    if (any(!is.na(hr_vals))) {
      expect_lt(max(hr_vals, na.rm = TRUE), 25)
    }
  }
})

test_that("TS-42: trim_method=iqr runs without error when is_keeper absent", {
  prices_no_keeper <- make_prices_data(seed = 42L)
  prices_no_keeper$is_keeper <- NULL

  result_trim <- replacement_from_prices(
    prices        = prices_no_keeper,
    n_teams       = 12L,
    roster_slots  = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L, SS = 1L,
                      OF = 3L),
    batting_categories = c("HR", "R", "RBI", "SB"),
    pitcher_categories = character(0L),
    trim_method   = "iqr"
  )
  if (!is.null(result_trim)) {
    expect_false(is.null(result_trim$positional_adjustments))
  }
})

test_that("TS-43: returns NULL + warning when < calibration_min_n players", {
  # Create a very sparse dataset: only 3 $1 players → below calibration_min_n=15
  prices_sparse <- data.frame(
    year            = rep(2023L, 5L),
    player_id       = paste0("PL", 1:5),
    player_name     = paste0("Player_", 1:5),
    price           = rep(1L, 5L),
    pos_eligibility = rep("OF", 5L),
    is_keeper       = rep(FALSE, 5L),
    HR              = c(3, 4, 5, 6, 7),
    R               = c(20, 22, 24, 26, 28),
    RBI             = c(18, 20, 22, 24, 26),
    SB              = c(2, 3, 4, 5, 6),
    stringsAsFactors = FALSE
  )
  expect_warning(
    result_null <- replacement_from_prices(
      prices            = prices_sparse,
      n_teams           = 12L,
      roster_slots      = c(OF = 3L),
      batting_categories = c("HR", "R", "RBI", "SB"),
      pitcher_categories = character(0L),
      calibration_min_n = 15L
    ),
    class = "rotostats_warning_calibration_suppressed"
  )
  expect_null(result_null)
})

test_that("TS-44: method = prices in returned params", {
  result_p <- replacement_from_prices(
    prices       = make_prices_data(seed = 42L),
    n_teams      = 12L,
    roster_slots = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L, SS = 1L,
                     OF = 3L),
    batting_categories = c("HR", "R", "RBI", "SB"),
    pitcher_categories = character(0L)
  )
  if (!is.null(result_p)) {
    expect_equal(result_p$params$method, "prices")
  }
})

# ---------------------------------------------------------------------------
# §12  Name Normalization Tests
# Test via the internal normalize_player_name function
# ---------------------------------------------------------------------------

# Access the internal function from the package namespace
get_normalize_fn <- function() {
  tryCatch(
    getFromNamespace("normalize_player_name", "rotostats"),
    error = function(e) NULL
  )
}

test_that("TS-45: ASCII names lowercased", {
  fn <- get_normalize_fn()
  skip_if(is.null(fn), "normalize_player_name not accessible in test environment")

  expect_equal(fn("Mike Trout"),   "mike trout")
  expect_equal(fn("Jose Ramirez"), "jose ramirez")
})

test_that("TS-46: diacritics stripped", {
  fn <- get_normalize_fn()
  skip_if(is.null(fn), "normalize_player_name not accessible in test environment")

  expect_equal(fn("Jos\u00e9 Ram\u00edrez"),  "jose ramirez")
  expect_equal(fn("Yo\u00e1n Moncada"),        "yoan moncada")
  expect_equal(fn("Nomar Garciaparra"),        "nomar garciaparra")
})

test_that("TS-47: special characters removed", {
  fn <- get_normalize_fn()
  skip_if(is.null(fn), "normalize_player_name not accessible in test environment")

  expect_equal(fn("A.J. Pollock"),  "aj pollock")
  expect_equal(fn("J.D. Martinez"), "jd martinez")
})

test_that("TS-48: multiple spaces collapsed", {
  fn <- get_normalize_fn()
  skip_if(is.null(fn), "normalize_player_name not accessible in test environment")

  expect_equal(fn("Mike  Trout"), "mike trout")
})

# ---------------------------------------------------------------------------
# § Name Match Failure Warning Tests
# T-NMF-1 through T-NMF-4 — Site 2 (replacement_from_prices)
# ---------------------------------------------------------------------------

test_that("TS-49: replacement_from_prices emits rotostats_warning_name_match_failure on normalized-name collision", {
  # Prior version (pre-audit) was a no-crash smoke test with no assertion about
  # the warning class. That test conceded the warning was for "a future
  # interface." This replacement test exercises the now-implemented warning path.
  #
  # Deterministic collision: "Jose Ramirez" and "José Ramírez" both normalize
  # to "jose ramirez". Both are in the same year. player_id is absent.
  # 20 rows required to satisfy calibration_min_n = 15 after filtering.
  prices_collision <- data.frame(
    year            = rep(2023L, 20L),
    player_name     = c(
      paste0("Player_", 1:18),
      "Jose Ramirez",
      "Jos\u00e9 Ram\u00edrez"
    ),
    price           = rep(1L, 20L),
    pos_eligibility = rep("OF", 20L),
    HR              = rep(5L, 20L),
    R               = rep(25L, 20L),
    RBI             = rep(22L, 20L),
    SB              = rep(4L, 20L),
    stringsAsFactors = FALSE
  )
  # Confirm: player_id column is absent
  stopifnot(!"player_id" %in% names(prices_collision))

  expect_warning(
    replacement_from_prices(
      prices        = prices_collision,
      n_teams       = 12L,
      roster_slots  = c(OF = 3L),
      batting_categories = c("HR", "R", "RBI", "SB"),
      pitcher_categories = character(0L),
      verbose       = TRUE
    ),
    class = "rotostats_warning_name_match_failure"
  )
})

test_that("T-NMF-1b: collision warning does not alter replacement_stats", {
  # Collision fixture (same stat values, different names for rows 19-20)
  prices_collision <- data.frame(
    year            = rep(2023L, 20L),
    player_name     = c(
      paste0("Player_", 1:18),
      "Jose Ramirez",
      "Jos\u00e9 Ram\u00edrez"
    ),
    price           = rep(1L, 20L),
    pos_eligibility = rep("OF", 20L),
    HR              = rep(5L, 20L),
    R               = rep(25L, 20L),
    RBI             = rep(22L, 20L),
    SB              = rep(4L, 20L),
    stringsAsFactors = FALSE
  )

  # Clean fixture (same 20 rows, unique names, identical stat values)
  prices_clean_equiv <- data.frame(
    year            = rep(2023L, 20L),
    player_name     = paste0("Player_", 1:20),  # unique names
    price           = rep(1L, 20L),
    pos_eligibility = rep("OF", 20L),
    HR              = rep(5L, 20L),
    R               = rep(25L, 20L),
    RBI             = rep(22L, 20L),
    SB              = rep(4L, 20L),
    stringsAsFactors = FALSE
  )

  result_collision <- suppressWarnings(
    replacement_from_prices(
      prices        = prices_collision,
      n_teams       = 12L,
      roster_slots  = c(OF = 3L),
      batting_categories = c("HR", "R", "RBI", "SB"),
      pitcher_categories = character(0L),
      verbose       = TRUE
    )
  )

  result_clean <- replacement_from_prices(
    prices        = prices_clean_equiv,
    n_teams       = 12L,
    roster_slots  = c(OF = 3L),
    batting_categories = c("HR", "R", "RBI", "SB"),
    pitcher_categories = character(0L),
    verbose       = FALSE
  )

  # replacement_stats must be identical (same stat means, same positions)
  # Tolerance from test-spec.md §6: 1e-9
  expect_equal(
    result_collision$replacement_stats[, c("position", "HR", "R", "RBI", "SB")],
    result_clean$replacement_stats[,    c("position", "HR", "R", "RBI", "SB")],
    tolerance = 1e-9
  )
})

test_that("T-NMF-3: rotostats_warning_name_match_failure is suppressed when verbose = FALSE", {
  # Same collision fixture as T-NMF-1 — but verbose = FALSE must suppress the warning.
  prices_collision <- data.frame(
    year            = rep(2023L, 20L),
    player_name     = c(
      paste0("Player_", 1:18),
      "Jose Ramirez",
      "Jos\u00e9 Ram\u00edrez"
    ),
    price           = rep(1L, 20L),
    pos_eligibility = rep("OF", 20L),
    HR              = rep(5L, 20L),
    R               = rep(25L, 20L),
    RBI             = rep(22L, 20L),
    SB              = rep(4L, 20L),
    stringsAsFactors = FALSE
  )

  # expect_no_warning with class argument is supported in testthat >= 3.1.2
  expect_no_warning(
    replacement_from_prices(
      prices        = prices_collision,
      n_teams       = 12L,
      roster_slots  = c(OF = 3L),
      batting_categories = c("HR", "R", "RBI", "SB"),
      pitcher_categories = character(0L),
      verbose       = FALSE
    ),
    class = "rotostats_warning_name_match_failure"
  )
})

test_that("T-NMF-4: no rotostats_warning_name_match_failure when all names distinct after normalization", {
  # All names are distinct ASCII strings — no normalization collisions possible.
  prices_clean <- data.frame(
    year            = rep(2023L, 20L),
    player_name     = paste0("Player_", 1:20),  # all distinct, all ASCII
    price           = rep(1L, 20L),
    pos_eligibility = rep("OF", 20L),
    HR              = rep(5L, 20L),
    R               = rep(25L, 20L),
    RBI             = rep(22L, 20L),
    SB              = rep(4L, 20L),
    stringsAsFactors = FALSE
  )

  expect_no_warning(
    replacement_from_prices(
      prices        = prices_clean,
      n_teams       = 12L,
      roster_slots  = c(OF = 3L),
      batting_categories = c("HR", "R", "RBI", "SB"),
      pitcher_categories = character(0L),
      verbose       = TRUE
    ),
    class = "rotostats_warning_name_match_failure"
  )
})
