# tests/testthat/test-league-config.R
#
# TDD-first test suite for league_config().
# Authored from plans/implementation/league-config-impl.md before the
# function itself exists; the first run must fail.

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

basic_roster <- c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L,
                  SS = 1L, OF = 5L, UTIL = 1L)

basic_cats <- c("R", "HR", "RBI", "SB", "AVG",
                "W", "K", "SV", "ERA", "WHIP")

make_cfg <- function(...) {
  args <- list(
    n_teams       = 12L,
    roster_slots  = basic_roster,
    pitcher_slots = c(SP = 6L, RP = 3L),
    categories    = basic_cats,
    league_type   = "mixed",
    budget        = 260L,
    budget_split  = 0.60,
    keeper        = FALSE
  )
  args <- utils::modifyList(args, list(...))
  do.call(league_config, args)
}

# ---------------------------------------------------------------------------
# Happy-path construction
# ---------------------------------------------------------------------------

test_that("league_config() returns an S3 object with resolved fields", {
  cfg <- make_cfg()
  expect_s3_class(cfg, "league_config")
  expect_true(inherits(cfg, "list"))
  expect_equal(cfg$n_teams, 12L)
  expect_equal(cfg$roster_slots, basic_roster)
  expect_equal(cfg$pitcher_slots, c(SP = 6L, RP = 3L))
  expect_equal(cfg$categories, basic_cats)
  expect_equal(cfg$league_type, "mixed")
  expect_equal(cfg$budget, 260L)
  expect_equal(cfg$budget_split, 0.60)
})

test_that("league_config() defaults match the documented signature", {
  cfg <- league_config(
    roster_slots = basic_roster,
    categories   = basic_cats
  )
  expect_equal(cfg$n_teams, 12L)
  expect_equal(cfg$pitcher_slots, 9L)
  expect_equal(cfg$league_type, "mixed")
  expect_equal(cfg$budget, 260L)
  expect_equal(cfg$budget_split, 0.60)
  expect_identical(cfg$keeper, FALSE)
})

# ---------------------------------------------------------------------------
# n_teams validation
# ---------------------------------------------------------------------------

test_that("n_teams must be a positive integer", {
  expect_error(make_cfg(n_teams = 0L),
               class = "rotostats_error_invalid_n_teams")
  expect_error(make_cfg(n_teams = -2L),
               class = "rotostats_error_invalid_n_teams")
  expect_error(make_cfg(n_teams = "12"),
               class = "rotostats_error_invalid_n_teams")
  expect_error(make_cfg(n_teams = 12.5),
               class = "rotostats_error_invalid_n_teams")
})

test_that("n_teams accepts numeric that is integer-valued", {
  cfg <- make_cfg(n_teams = 10)
  expect_equal(cfg$n_teams, 10L)
  expect_type(cfg$n_teams, "integer")
})

# ---------------------------------------------------------------------------
# roster_slots validation
# ---------------------------------------------------------------------------

test_that("roster_slots must be a named integer vector", {
  expect_error(make_cfg(roster_slots = c(1L, 1L)),
               class = "rotostats_error_invalid_roster_slots")
  expect_error(make_cfg(roster_slots = list(C = 1L)),
               class = "rotostats_error_invalid_roster_slots")
  expect_error(make_cfg(roster_slots = c(C = "1")),
               class = "rotostats_error_invalid_roster_slots")
})

test_that("roster_slots accepts integer-valued numeric and coerces", {
  cfg <- make_cfg(roster_slots = c(C = 1, "1B" = 1, "2B" = 1, "3B" = 1,
                                   SS = 1, OF = 5, UTIL = 1))
  expect_type(cfg$roster_slots, "integer")
})

# ---------------------------------------------------------------------------
# pitcher_slots
# ---------------------------------------------------------------------------

test_that("pitcher_slots accepts a single integer", {
  cfg <- make_cfg(pitcher_slots = 9L)
  expect_equal(cfg$pitcher_slots, 9L)
})

test_that("pitcher_slots accepts SP/RP named vector", {
  cfg <- make_cfg(pitcher_slots = c(SP = 6L, RP = 3L))
  expect_equal(cfg$pitcher_slots, c(SP = 6L, RP = 3L))
})

test_that("pitcher_slots rejects names other than SP/RP", {
  expect_error(make_cfg(pitcher_slots = c(SP = 6L, CP = 2L)),
               class = "rotostats_error_invalid_pitcher_slots")
  expect_error(make_cfg(pitcher_slots = c(SP = 6L, RP = 3L, LR = 1L)),
               class = "rotostats_error_invalid_pitcher_slots")
})

# ---------------------------------------------------------------------------
# league_type
# ---------------------------------------------------------------------------

test_that("league_type must be one of mixed / AL / NL", {
  expect_error(make_cfg(league_type = "NPB"),
               class = "rotostats_error_invalid_league_type")
  expect_error(make_cfg(league_type = "Mixed"),
               class = "rotostats_error_invalid_league_type")
})

test_that("DH in roster_slots with league_type = NL warns and drops DH", {
  roster_with_dh <- c(basic_roster, DH = 1L)
  expect_warning(
    cfg <- make_cfg(league_type = "NL", roster_slots = roster_with_dh),
    class = "rotostats_warning_dh_dropped_nl"
  )
  expect_false("DH" %in% names(cfg$roster_slots))
})

test_that("DH retained for mixed and AL leagues", {
  roster_with_dh <- c(basic_roster, DH = 1L)
  for (lt in c("mixed", "AL")) {
    cfg <- make_cfg(league_type = lt, roster_slots = roster_with_dh)
    expect_true("DH" %in% names(cfg$roster_slots),
                info = paste("league_type =", lt))
  }
})

# ---------------------------------------------------------------------------
# budget
# ---------------------------------------------------------------------------

test_that("budget must be a positive integer", {
  expect_error(make_cfg(budget = 0L),
               class = "rotostats_error_invalid_budget")
  expect_error(make_cfg(budget = -10L),
               class = "rotostats_error_invalid_budget")
  expect_error(make_cfg(budget = "260"),
               class = "rotostats_error_invalid_budget")
})

# ---------------------------------------------------------------------------
# budget_split
# ---------------------------------------------------------------------------

test_that("budget_split must be strictly in (0, 1)", {
  expect_error(make_cfg(budget_split = 0),
               class = "rotostats_error_invalid_budget_split")
  expect_error(make_cfg(budget_split = 1),
               class = "rotostats_error_invalid_budget_split")
  expect_error(make_cfg(budget_split = -0.1),
               class = "rotostats_error_invalid_budget_split")
  expect_error(make_cfg(budget_split = 1.2),
               class = "rotostats_error_invalid_budget_split")
})

# ---------------------------------------------------------------------------
# categories
# ---------------------------------------------------------------------------

test_that("category names are normalized to uppercase with a cli_inform", {
  mixed_case <- c("r", "hr", "RBI", "sb", "avg",
                  "W", "K", "SV", "ERA", "WHIP")
  expect_message(
    cfg <- make_cfg(categories = mixed_case),
    class = "rotostats_info_category_normalized"
  )
  expect_equal(cfg$categories, basic_cats)
})

test_that("unrecognized categories emit a cli_warn", {
  expect_warning(
    make_cfg(categories = c(basic_cats, "BLARG")),
    class = "rotostats_warning_unknown_category"
  )
})

test_that("canonical categories construct silently", {
  expect_silent(make_cfg(categories = basic_cats))
})

# ---------------------------------------------------------------------------
# keeper
# ---------------------------------------------------------------------------

test_that("keeper = FALSE is stored as FALSE", {
  cfg <- make_cfg(keeper = FALSE)
  expect_identical(cfg$keeper, FALSE)
})

test_that("keeper = TRUE resolves to the default keeper list", {
  cfg <- make_cfg(keeper = TRUE)
  expect_true(is.list(cfg$keeper))
  expect_true(isTRUE(cfg$keeper$is_keeper))
  expect_equal(cfg$keeper$method, "pool_shrink")
  expect_equal(cfg$keeper$keeper_col, "is_keeper")
  expect_null(cfg$keeper$salary_col)
})

test_that("explicit keeper list with all fields round-trips", {
  cfg <- make_cfg(keeper = list(
    is_keeper  = TRUE,
    method     = "salary_adjust",
    keeper_col = "is_keeper",
    salary_col = "keeper_salary"
  ))
  expect_equal(cfg$keeper$method, "salary_adjust")
  expect_equal(cfg$keeper$keeper_col, "is_keeper")
  expect_equal(cfg$keeper$salary_col, "keeper_salary")
})

test_that("keeper method 'salary_adjust' without salary_col aborts", {
  expect_error(
    make_cfg(keeper = list(
      is_keeper  = TRUE,
      method     = "salary_adjust",
      keeper_col = "is_keeper"
    )),
    class = "rotostats_error_missing_keeper_salary_col"
  )
})

test_that("keeper list missing required fields aborts", {
  expect_error(
    make_cfg(keeper = list(method = "pool_shrink")),
    class = "rotostats_error_invalid_keeper_config"
  )
})

# ---------------------------------------------------------------------------
# Print method
# ---------------------------------------------------------------------------

test_that("print.league_config returns x invisibly and renders a summary", {
  cfg <- make_cfg()
  out <- capture.output(ret <- print(cfg))
  expect_identical(ret, cfg)
  expect_true(any(grepl("League configuration", out, fixed = TRUE)))
  expect_true(any(grepl("Teams", out)))
  expect_true(any(grepl("Pitchers", out)))
  expect_true(any(grepl("Categories", out)))
})

# ---------------------------------------------------------------------------
# Internal helper: pool_sizes()
# ---------------------------------------------------------------------------

test_that("pool_sizes() returns a list of pitcher and hitter pool counts", {
  cfg <- make_cfg()
  ps  <- pool_sizes(cfg)
  expect_type(ps, "list")
  expect_named(ps, c("pitchers", "hitters"), ignore.order = TRUE)
  expect_equal(ps$pitchers, 12L * 9L)
  # UTIL excluded; no DH
  expect_equal(ps$hitters, 12L * (1 + 1 + 1 + 1 + 1 + 5))
})

test_that("pool_sizes() excludes UTIL, MI, CI combo slots", {
  cfg <- make_cfg(roster_slots = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L,
                                   SS = 1L, OF = 5L,
                                   UTIL = 1L, MI = 1L, CI = 1L))
  ps <- pool_sizes(cfg)
  expect_equal(ps$hitters, 12L * (1 + 1 + 1 + 1 + 1 + 5))
})

test_that("pool_sizes() includes DH for AL leagues", {
  roster_with_dh <- c(basic_roster, DH = 1L)
  cfg <- make_cfg(league_type = "AL", roster_slots = roster_with_dh)
  ps  <- pool_sizes(cfg)
  expect_equal(ps$hitters, 12L * (1 + 1 + 1 + 1 + 1 + 5 + 1))
})

test_that("pool_sizes() excludes DH for NL (dropped at construction)", {
  roster_with_dh <- c(basic_roster, DH = 1L)
  cfg <- suppressWarnings(
    make_cfg(league_type = "NL", roster_slots = roster_with_dh)
  )
  ps <- pool_sizes(cfg)
  expect_equal(ps$hitters, 12L * (1 + 1 + 1 + 1 + 1 + 5))
})

test_that("pool_sizes() handles single-integer pitcher_slots", {
  cfg <- make_cfg(pitcher_slots = 9L)
  ps  <- pool_sizes(cfg)
  expect_equal(ps$pitchers, 12L * 9L)
})

# ===========================================================================
# inverse_categories — TC-LC-INV-1 through TC-LC-INV-7
# Added by Tester pipeline, inverse-categories-2026-04-21
# ===========================================================================

# ---------------------------------------------------------------------------
# Fixture helper (self-contained; does not depend on fixtures above)
# ---------------------------------------------------------------------------

# Minimal valid config for inverse_categories tests.
.minimal_config_args <- function(...) {
  defaults <- list(
    n_teams       = 12L,
    roster_slots  = c(C = 1L, "1B" = 1L, OF = 3L),
    categories    = c("HR", "R", "RBI", "ERA", "WHIP", "FIP")
  )
  args <- modifyList(defaults, list(...))
  do.call(league_config, args)
}

# ---------------------------------------------------------------------------
# TC-LC-INV-1: NULL default — field stored as NULL
# ---------------------------------------------------------------------------

test_that("league_config stores NULL when inverse_categories omitted", {
  lg <- .minimal_config_args()
  expect_null(lg$inverse_categories)
})

# ---------------------------------------------------------------------------
# TC-LC-INV-2: Valid vector — stored and uppercased
# ---------------------------------------------------------------------------

test_that("league_config stores and uppercases a valid inverse_categories vector", {
  lg <- .minimal_config_args(inverse_categories = c("era", "WHIP", "fip"))
  expect_equal(lg$inverse_categories, c("ERA", "WHIP", "FIP"))
})

# ---------------------------------------------------------------------------
# TC-LC-INV-3: Invalid element (not in categories) aborts with correct class
# ---------------------------------------------------------------------------

test_that("league_config aborts when inverse_categories element not in categories", {
  expect_error(
    .minimal_config_args(inverse_categories = c("ERA", "FOO")),
    class = "rotostats_error_invalid_inverse_categories"
  )
})

# ---------------------------------------------------------------------------
# TC-LC-INV-4: Non-character (non-NULL) aborts with correct class
# ---------------------------------------------------------------------------

test_that("league_config aborts when inverse_categories is non-character non-NULL", {
  expect_error(
    .minimal_config_args(inverse_categories = 1:3),
    class = "rotostats_error_invalid_inverse_categories"
  )
})

# ---------------------------------------------------------------------------
# TC-LC-INV-5: print output shows "(none declared)" when NULL
# ---------------------------------------------------------------------------

test_that("print.league_config shows (none declared) when inverse_categories is NULL", {
  lg <- .minimal_config_args()
  out <- capture.output(print(lg))
  expect_true(any(grepl("\\(none declared\\)", out)))
})

# ---------------------------------------------------------------------------
# TC-LC-INV-6: print output shows the effective list when non-NULL
# ---------------------------------------------------------------------------

test_that("print.league_config shows effective inverse list when non-NULL", {
  lg <- .minimal_config_args(inverse_categories = c("ERA", "WHIP"))
  out <- capture.output(print(lg))
  expect_true(any(grepl("ERA", out)))
  expect_true(any(grepl("WHIP", out)))
  expect_false(any(grepl("\\(none declared\\)", out)))
})

# ---------------------------------------------------------------------------
# TC-LC-INV-7: Field accessible on returned S3 object
# ---------------------------------------------------------------------------

test_that("lg$inverse_categories is readable on the returned S3 object", {
  lg <- .minimal_config_args(inverse_categories = c("fip", "ERA"))
  expect_true(is.character(lg$inverse_categories))
  expect_setequal(lg$inverse_categories, c("FIP", "ERA"))
})
