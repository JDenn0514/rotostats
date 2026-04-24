# tests/testthat/test-get-projections.R
#
# TDD-first test suite for get_projections().
# Authored from plans/implementation/get-projections-impl.md before the
# function itself exists; the first run must fail.

# ---------------------------------------------------------------------------
# .current_season_year()
# ---------------------------------------------------------------------------

test_that(".current_season_year() returns the calendar year as integer", {
  expect_identical(
    rotostats:::.current_season_year(),
    as.integer(format(Sys.Date(), "%Y"))
  )
  expect_type(rotostats:::.current_season_year(), "integer")
})

# ---------------------------------------------------------------------------
# .validate_source()
# ---------------------------------------------------------------------------

test_that(".validate_source() accepts every documented source", {
  valid <- c("steamer", "zips", "atc", "fangraphsdc", "thebat", "thebatx", "custom")
  for (s in valid) {
    expect_identical(rotostats:::.validate_source(s), s)
  }
})

test_that(".validate_source() rejects unknown sources with the right class", {
  expect_error(
    rotostats:::.validate_source("marcel"),
    class = "rotostats_error_invalid_source"
  )
})

test_that(".validate_source() rejects non-scalar / non-character input", {
  expect_error(
    rotostats:::.validate_source(c("steamer", "zips")),
    class = "rotostats_error_invalid_source"
  )
  expect_error(
    rotostats:::.validate_source(1L),
    class = "rotostats_error_invalid_source"
  )
  expect_error(
    rotostats:::.validate_source(NULL),
    class = "rotostats_error_invalid_source"
  )
})

# ---------------------------------------------------------------------------
# .validate_player_type()
# ---------------------------------------------------------------------------

test_that(".validate_player_type() accepts 'batters', 'pitchers', 'both'", {
  expect_identical(rotostats:::.validate_player_type("batters"), "batters")
  expect_identical(rotostats:::.validate_player_type("pitchers"), "pitchers")
  expect_identical(rotostats:::.validate_player_type("both"), "both")
})

test_that(".validate_player_type() rejects anything else", {
  expect_error(
    rotostats:::.validate_player_type("batter"),
    class = "rotostats_error_invalid_player_type"
  )
  expect_error(
    rotostats:::.validate_player_type(NA_character_),
    class = "rotostats_error_invalid_player_type"
  )
  expect_error(
    rotostats:::.validate_player_type(NULL),
    class = "rotostats_error_invalid_player_type"
  )
})

# ---------------------------------------------------------------------------
# .validate_year()
# ---------------------------------------------------------------------------

test_that(".validate_year(NULL) returns the current season", {
  yr <- rotostats:::.validate_year(NULL)
  expect_identical(yr, rotostats:::.current_season_year())
})

test_that(".validate_year() accepts the current season explicitly", {
  cur <- rotostats:::.current_season_year()
  expect_identical(rotostats:::.validate_year(cur), cur)
  expect_identical(rotostats:::.validate_year(as.numeric(cur)), cur)
})

test_that(".validate_year() aborts on non-current years", {
  cur <- rotostats:::.current_season_year()
  expect_error(
    rotostats:::.validate_year(cur - 1L),
    class = "rotostats_error_unsupported_year"
  )
  expect_error(
    rotostats:::.validate_year(cur + 1L),
    class = "rotostats_error_unsupported_year"
  )
})

test_that(".validate_year() aborts on non-scalar / non-integer input", {
  expect_error(
    rotostats:::.validate_year(c(2026, 2027)),
    class = "rotostats_error_unsupported_year"
  )
  expect_error(
    rotostats:::.validate_year("2026"),
    class = "rotostats_error_unsupported_year"
  )
  expect_error(
    rotostats:::.validate_year(2026.5),
    class = "rotostats_error_unsupported_year"
  )
})

# ---------------------------------------------------------------------------
# .validate_custom_data()
# ---------------------------------------------------------------------------

test_that(".validate_custom_data() returns data unchanged on valid custom input", {
  d <- data.frame(name = "A", HR = 10)
  expect_identical(rotostats:::.validate_custom_data("custom", d), d)

  d2 <- data.frame(playerid = "abc", HR = 10)
  expect_identical(rotostats:::.validate_custom_data("custom", d2), d2)
})

test_that(".validate_custom_data() returns NULL on non-custom source + NULL data", {
  expect_null(rotostats:::.validate_custom_data("steamer", NULL))
})

test_that(".validate_custom_data() aborts when data supplied with non-custom source", {
  d <- data.frame(name = "A")
  expect_error(
    rotostats:::.validate_custom_data("steamer", d),
    class = "rotostats_error_data_ignored"
  )
})

test_that(".validate_custom_data() aborts on custom + NULL", {
  expect_error(
    rotostats:::.validate_custom_data("custom", NULL),
    class = "rotostats_error_missing_custom_data"
  )
})

test_that(".validate_custom_data() aborts on non-data.frame data", {
  expect_error(
    rotostats:::.validate_custom_data("custom", list(name = "A")),
    class = "rotostats_error_invalid_custom_data"
  )
  expect_error(
    rotostats:::.validate_custom_data("custom", matrix(1:4, 2, 2)),
    class = "rotostats_error_invalid_custom_data"
  )
})

test_that(".validate_custom_data() aborts when neither name nor playerid is present", {
  d <- data.frame(HR = 10, RBI = 20)
  expect_error(
    rotostats:::.validate_custom_data("custom", d),
    class = "rotostats_error_invalid_custom_data"
  )
})

# ---------------------------------------------------------------------------
# .build_projections_url()
# ---------------------------------------------------------------------------

test_that(".build_projections_url() builds the documented URL shape", {
  url <- rotostats:::.build_projections_url("steamer", "batters")
  expect_match(url, "^https://www\\.fangraphs\\.com/api/projections\\?")
  expect_match(url, "type=steamer")
  expect_match(url, "stats=bat")
  expect_match(url, "pos=all")
  expect_match(url, "team=0")
  expect_match(url, "players=0")
  expect_match(url, "lg=all")
})

test_that(".build_projections_url() maps player_type to stats param", {
  expect_match(rotostats:::.build_projections_url("zips", "batters"),  "stats=bat")
  expect_match(rotostats:::.build_projections_url("zips", "pitchers"), "stats=pit")
})

# ---------------------------------------------------------------------------
# .fetch_projections_api()
# ---------------------------------------------------------------------------

test_that(".fetch_projections_api() returns parsed JSON on 2xx", {
  # Stub httr2 so we never hit the network in unit tests
  fake_resp <- structure(
    list(
      body_json = list(list(playerid = "1", PlayerName = "Test", HR = 30))
    ),
    class = "fake_response"
  )
  testthat::local_mocked_bindings(
    request       = function(url) list(url = url),
    req_perform   = function(req) fake_resp,
    resp_body_json = function(r) r$body_json,
    resp_is_error = function(r) FALSE,
    .package = "httr2"
  )
  result <- rotostats:::.fetch_projections_api("https://example.com/fake")
  expect_type(result, "list")
  expect_equal(result[[1]]$playerid, "1")
})

test_that(".fetch_projections_api() aborts on transport-level failure", {
  testthat::local_mocked_bindings(
    request     = function(url) list(url = url),
    req_perform = function(req) stop("connection refused"),
    .package = "httr2"
  )
  expect_error(
    rotostats:::.fetch_projections_api("https://example.com/fake"),
    class = "rotostats_error_projection_fetch_failed"
  )
})

test_that(".fetch_projections_api() aborts on non-2xx", {
  testthat::local_mocked_bindings(
    request       = function(url) list(url = url),
    req_perform   = function(req) list(status_code = 500L),
    resp_is_error = function(r) TRUE,
    resp_status   = function(r) 500L,
    .package = "httr2"
  )
  expect_error(
    rotostats:::.fetch_projections_api("https://example.com/fake"),
    class = "rotostats_error_projection_fetch_failed"
  )
})

# ---------------------------------------------------------------------------
# .parse_projections_json()
# ---------------------------------------------------------------------------

test_that(".parse_projections_json() rbinds uniform records", {
  raw <- list(
    list(playerid = "1", PlayerName = "A", HR = 30),
    list(playerid = "2", PlayerName = "B", HR = 25)
  )
  out <- rotostats:::.parse_projections_json(raw)
  expect_s3_class(out, "data.frame")
  expect_equal(nrow(out), 2L)
  expect_setequal(names(out), c("playerid", "PlayerName", "HR"))
  expect_equal(out$HR, c(30, 25))
})

test_that(".parse_projections_json() handles ragged records with NA fill", {
  raw <- list(
    list(playerid = "1", HR = 30, SB = 10),
    list(playerid = "2", HR = 25)         # SB missing
  )
  out <- rotostats:::.parse_projections_json(raw)
  expect_equal(nrow(out), 2L)
  expect_true("SB" %in% names(out))
  expect_true(is.na(out$SB[2]))
})

test_that(".parse_projections_json() aborts on empty input", {
  expect_error(
    rotostats:::.parse_projections_json(list()),
    class = "rotostats_error_empty_projection_response"
  )
})

# ---------------------------------------------------------------------------
# .normalize_projection_cols()
# ---------------------------------------------------------------------------

test_that(".normalize_projection_cols() renames PlayerName → name", {
  df <- data.frame(playerid = "1", PlayerName = "A", Team = "NYY", Pos = "2B")
  out <- rotostats:::.normalize_projection_cols(df)
  expect_setequal(names(out), c("playerid", "name", "team", "pos"))
})

test_that(".normalize_projection_cols() normalizes slash-containing pitcher stats", {
  df <- data.frame(playerid = "1", `K/9` = 9.5, `BB/9` = 2.1, `K/BB` = 4.5,
                   check.names = FALSE)
  out <- rotostats:::.normalize_projection_cols(df)
  expect_setequal(names(out), c("playerid", "K_per_9", "BB_per_9", "K_per_BB"))
})

test_that(".normalize_projection_cols() normalizes wRC+", {
  df <- data.frame(playerid = "1", `wRC+` = 120, check.names = FALSE)
  out <- rotostats:::.normalize_projection_cols(df)
  expect_true("wRC_plus" %in% names(out))
  expect_false("wRC+" %in% names(out))
})

test_that(".normalize_projection_cols() leaves already-canonical columns alone", {
  df <- data.frame(playerid = "1", name = "A", team = "NYY", pos = "2B",
                   HR = 30)
  out <- rotostats:::.normalize_projection_cols(df)
  expect_setequal(names(out), c("playerid", "name", "team", "pos", "HR"))
})
