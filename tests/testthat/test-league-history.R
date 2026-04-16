# tests/testthat/test-league-history.R
#
# TDD-first test suite for league_history().
# Authored from plans/implementation/league-history-impl.md before the
# function itself exists; the first run must fail.

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

make_team_season <- function(
  years   = 2018:2023,
  teams   = paste0("T", 1:12),
  cats    = c("HR", "R", "RBI", "SB", "AVG", "W", "K", "SV", "ERA", "WHIP"),
  seed    = 42L
) {
  set.seed(seed)
  rows <- lapply(years, function(y) {
    df <- data.frame(
      year    = as.integer(y),
      team_id = teams,
      stringsAsFactors = FALSE
    )
    for (cat in cats) df[[cat]] <- round(rnorm(length(teams), 100, 20), 2)
    df
  })
  do.call(rbind, rows)
}

make_prices <- function(n = 250L, years = 2018:2023, seed = 7L) {
  set.seed(seed)
  data.frame(
    year        = sample(years, n, replace = TRUE),
    player_name = paste0("Player", seq_len(n)),
    price       = sample(1:60, n, replace = TRUE),
    stringsAsFactors = FALSE
  )
}

# ---------------------------------------------------------------------------
# Happy-path construction
# ---------------------------------------------------------------------------

test_that("league_history() returns an S3 object with team_season", {
  ts <- make_team_season(years = 2018:2019)
  h  <- league_history(team_season = ts)
  expect_s3_class(h, "league_history")
  expect_true(inherits(h, "list"))
  expect_true(is.data.frame(h$team_season))
  expect_null(h$prices)
})

test_that("league_history() stores supplied prices", {
  ts <- make_team_season(years = 2018:2019)
  pr <- make_prices()
  h  <- league_history(team_season = ts, prices = pr)
  expect_true(is.data.frame(h$prices))
  expect_equal(nrow(h$prices), nrow(pr))
})

# ---------------------------------------------------------------------------
# team_season validation
# ---------------------------------------------------------------------------

test_that("team_season must be a data frame", {
  expect_error(
    league_history(team_season = list(a = 1)),
    class = "rotostats_error_invalid_team_season"
  )
  expect_error(
    league_history(team_season = matrix(1:10, nrow = 2)),
    class = "rotostats_error_invalid_team_season"
  )
})

test_that("team_season must contain year and team_id columns", {
  ts <- make_team_season(years = 2018:2019)
  no_year <- ts[, setdiff(names(ts), "year"), drop = FALSE]
  expect_error(
    league_history(team_season = no_year),
    class = "rotostats_error_missing_team_season_column"
  )
  no_team <- ts[, setdiff(names(ts), "team_id"), drop = FALSE]
  expect_error(
    league_history(team_season = no_team),
    class = "rotostats_error_missing_team_season_column"
  )
})

test_that("year must be coercible to integer", {
  ts <- make_team_season(years = 2018:2019)
  ts$year <- paste0("season-", ts$year)
  expect_error(
    league_history(team_season = ts),
    class = "rotostats_error_invalid_team_season_year"
  )
})

test_that("team_id must be character (or factor coerced to character)", {
  ts <- make_team_season(years = 2018:2019)
  ts$team_id <- as.numeric(seq_len(nrow(ts)))
  expect_error(
    league_history(team_season = ts),
    class = "rotostats_error_invalid_team_season_team_id"
  )
})

# ---------------------------------------------------------------------------
# Column-name normalization
# ---------------------------------------------------------------------------

test_that("column names are normalized to uppercase with cli_inform", {
  ts <- make_team_season(years = 2018:2019)
  expect_message(
    h <- league_history(team_season = ts),
    class = "rotostats_info_history_column_normalized"
  )
  # year/team_id stay lowercase (identifier-conventional); stat columns
  # uppercased. Accept either convention as long as the stat names match.
  expect_true(all(c("HR", "R", "RBI") %in% names(h$team_season)))
})

test_that("already-uppercase columns construct without a normalization message", {
  ts <- make_team_season(years = 2018:2019)
  names(ts) <- toupper(names(ts))
  expect_no_message(
    league_history(team_season = ts),
    class = "rotostats_info_history_column_normalized"
  )
})

# ---------------------------------------------------------------------------
# Cross-year consistency
# ---------------------------------------------------------------------------

test_that("inconsistent team count across years warns", {
  ts_12 <- make_team_season(years = 2019L, teams = paste0("T", 1:12))
  ts_10 <- make_team_season(years = 2020L, teams = paste0("T", 1:10))
  ts    <- rbind(ts_12, ts_10)
  expect_warning(
    suppressMessages(league_history(team_season = ts)),
    class = "rotostats_warning_inconsistent_team_count"
  )
})

# ---------------------------------------------------------------------------
# NA handling
# ---------------------------------------------------------------------------

test_that("NA in a non-identifier column warns and names affected team-years", {
  ts <- make_team_season(years = 2018:2019)
  ts$HR[2L] <- NA_real_
  w <- tryCatch(
    suppressMessages(league_history(team_season = ts)),
    warning = function(w) w
  )
  expect_s3_class(w, "rotostats_warning_na_stat_value")
})

# ---------------------------------------------------------------------------
# 2020 notice
# ---------------------------------------------------------------------------

test_that("2020 in team_season$year emits an info message", {
  ts <- make_team_season(years = c(2019L, 2020L, 2021L))
  expect_message(
    league_history(team_season = ts),
    class = "rotostats_info_2020_present"
  )
})

test_that("no 2020 present means no 2020 info message", {
  ts <- make_team_season(years = 2018:2019)
  expect_no_message(
    suppressMessages(league_history(team_season = ts)),
    class = "rotostats_info_2020_present"
  )
})

# ---------------------------------------------------------------------------
# prices validation
# ---------------------------------------------------------------------------

test_that("prices, if supplied, must be a data frame", {
  ts <- make_team_season(years = 2018:2019)
  expect_error(
    suppressMessages(league_history(team_season = ts, prices = list(a = 1))),
    class = "rotostats_error_invalid_prices"
  )
})

test_that("prices must contain year, player_name, and price columns", {
  ts <- make_team_season(years = 2018:2019)
  pr <- make_prices()

  pr_no_year <- pr[, setdiff(names(pr), "year"), drop = FALSE]
  expect_error(
    suppressMessages(league_history(team_season = ts, prices = pr_no_year)),
    class = "rotostats_error_missing_prices_column"
  )

  pr_no_player <- pr[, setdiff(names(pr), "player_name"), drop = FALSE]
  expect_error(
    suppressMessages(league_history(team_season = ts, prices = pr_no_player)),
    class = "rotostats_error_missing_prices_column"
  )

  pr_no_price <- pr[, setdiff(names(pr), "price"), drop = FALSE]
  expect_error(
    suppressMessages(league_history(team_season = ts, prices = pr_no_price)),
    class = "rotostats_error_missing_prices_column"
  )
})

test_that("negative prices warn and flag affected rows", {
  ts <- make_team_season(years = 2018:2019)
  pr <- make_prices()
  pr$price[c(2L, 5L)] <- c(-1, -5)
  expect_warning(
    suppressMessages(league_history(team_season = ts, prices = pr)),
    class = "rotostats_warning_negative_price"
  )
})

test_that("player_type case is normalized and a cli_inform is emitted", {
  ts <- make_team_season(years = 2018:2019)
  pr <- make_prices()
  pr$player_type <- sample(c("Batter", "PITCHER", "batter"),
                           nrow(pr), replace = TRUE)
  # Capture the specific info message via tryCatch so we can also keep
  # a handle on the returned object for follow-up assertions.
  captured <- NULL
  h <- withCallingHandlers(
    suppressWarnings(league_history(team_season = ts, prices = pr)),
    rotostats_info_player_type_normalized = function(m) {
      captured <<- m
      rlang::cnd_muffle(m)
    },
    message = function(m) rlang::cnd_muffle(m)
  )
  expect_s3_class(captured, "rotostats_info_player_type_normalized")
  expect_true(all(h$prices$player_type %in% c("batter", "pitcher")))
})

# ---------------------------------------------------------------------------
# Print method
# ---------------------------------------------------------------------------

test_that("print.league_history returns x invisibly and summarizes contents", {
  ts <- make_team_season(years = 2018:2019)
  h  <- suppressMessages(league_history(team_season = ts))
  out <- capture.output(ret <- print(h))
  expect_identical(ret, h)
  expect_true(any(grepl("League history", out, fixed = TRUE)))
  expect_true(any(grepl("Team seasons", out, fixed = TRUE)))
  expect_true(any(grepl("Stat columns", out, fixed = TRUE)))
})

test_that("print.league_history shows a prices line when prices are present", {
  ts <- make_team_season(years = 2018:2019)
  pr <- make_prices()
  h  <- suppressMessages(league_history(team_season = ts, prices = pr))
  out <- capture.output(print(h))
  expect_true(any(grepl("Prices", out, fixed = TRUE)))
})
