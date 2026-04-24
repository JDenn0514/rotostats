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

test_that(".normalize_projection_cols() renames PlayerName → player_name", {
  df <- data.frame(playerid = "1", PlayerName = "A", Team = "NYY", minpos = "2B")
  out <- rotostats:::.normalize_projection_cols(df)
  expect_setequal(names(out), c("player_id", "player_name", "team", "pos"))
})

test_that(".normalize_projection_cols() normalizes slash-containing pitcher stats", {
  df <- data.frame(playerid = "1", `K/9` = 9.5, `BB/9` = 2.1, `K/BB` = 4.5,
                   check.names = FALSE)
  out <- rotostats:::.normalize_projection_cols(df)
  expect_setequal(names(out), c("player_id", "k_per_9", "bb_per_9", "k_per_bb"))
})

test_that(".normalize_projection_cols() normalizes wRC+", {
  df <- data.frame(playerid = "1", `wRC+` = 120, check.names = FALSE)
  out <- rotostats:::.normalize_projection_cols(df)
  expect_true("wrc_plus" %in% names(out))
  expect_false("wRC+" %in% names(out))
})

test_that(".normalize_projection_cols() leaves already-canonical columns alone", {
  df <- data.frame(player_id = "1", player_name = "A", team = "NYY", pos = "2B",
                   hr = 30)
  out <- rotostats:::.normalize_projection_cols(df)
  expect_setequal(names(out), c("player_id", "player_name", "team", "pos", "hr"))
})

# ---------------------------------------------------------------------------
# .derive_svhd()
# ---------------------------------------------------------------------------

test_that(".derive_svhd() adds SV + HLD", {
  df <- data.frame(player_id = c("1","2"), sv = c(30, 0), hld = c(0, 25))
  out <- rotostats:::.derive_svhd(df)
  expect_equal(out$svhd, c(30, 25))
})

test_that(".derive_svhd() handles NA SV or HLD as 0", {
  df <- data.frame(player_id = c("1","2"), sv = c(NA, 10), hld = c(5, NA))
  out <- rotostats:::.derive_svhd(df)
  expect_equal(out$svhd, c(5, 10))
})

test_that(".derive_svhd() is a no-op when SV or HLD column is absent", {
  df <- data.frame(player_id = "1", sv = 5)   # no hld
  out <- rotostats:::.derive_svhd(df)
  expect_false("svhd" %in% names(out))

  df2 <- data.frame(player_id = "1", hld = 5) # no sv
  out2 <- rotostats:::.derive_svhd(df2)
  expect_false("svhd" %in% names(out2))
})

test_that(".derive_svhd() emits a once-per-session inform message", {
  rlang::local_interactive()
  # Reset the session-once state so this test is deterministic
  rlang::reset_message_verbosity("rotostats_svhd_definition")

  df <- data.frame(player_id = "1", sv = 30, hld = 0)

  expect_message(
    rotostats:::.derive_svhd(df),
    regexp = "SVHD computed as SV \\+ HLD"
  )
  # Second call in the same session: silent
  expect_no_message(
    rotostats:::.derive_svhd(df)
  )
})

# ---------------------------------------------------------------------------
# .attach_player_type() and .combine_batter_pitcher()
# ---------------------------------------------------------------------------

test_that(".attach_player_type() sets the player_type column", {
  df <- data.frame(player_id = "1", hr = 30)
  out <- rotostats:::.attach_player_type(df, "batter")
  expect_equal(out$player_type, "batter")
})

test_that(".combine_batter_pitcher() rbinds with NA fill across non-shared cols", {
  bat <- data.frame(
    player_id = "1", player_name = "A", team = "NYY", pos = "2B",
    player_type = "batter", hr = 30, ab = 550
  )
  pit <- data.frame(
    player_id = "2", player_name = "B", team = "LAD", pos = "SP",
    player_type = "pitcher", w = 15, ip = 200
  )
  out <- rotostats:::.combine_batter_pitcher(bat, pit)
  expect_equal(nrow(out), 2L)
  # columns from both sides are present
  expect_true(all(c("hr", "ab", "w", "ip") %in% names(out)))
  # each row keeps its own non-NA side
  expect_equal(out$hr[out$player_type == "batter"], 30)
  expect_true(is.na(out$hr[out$player_type == "pitcher"]))
  expect_equal(out$w[out$player_type == "pitcher"], 15)
  expect_true(is.na(out$w[out$player_type == "batter"]))
})

# ---------------------------------------------------------------------------
# get_projections() — custom source
# ---------------------------------------------------------------------------

test_that("get_projections(source = 'custom') returns user data unchanged", {
  d <- data.frame(name = "Test", HR = 30, player_type = "batter")
  out <- get_projections(source = "custom", data = d)
  expect_identical(out, tibble::as_tibble(d))
})

# ---------------------------------------------------------------------------
# get_projections() — FanGraphs sources (HTTP stubbed)
# ---------------------------------------------------------------------------

test_that("get_projections('steamer', player_type = 'batters') returns a normalized batter frame", {
  testthat::local_mocked_bindings(
    .fetch_projections_api = function(url) fx_batter_json(3L),
    .package = "rotostats"
  )
  out <- get_projections(source = "steamer", player_type = "batters")

  expect_s3_class(out, "data.frame")
  expect_equal(nrow(out), 3L)
  expect_true(all(c("player_id", "player_name", "team", "pos_eligibility", "player_type") %in% names(out)))
  expect_true(all(out$player_type == "batter"))
  expect_true("wrc_plus" %in% names(out))
  expect_false("wRC+" %in% names(out))
})

test_that("get_projections(..., player_type = 'pitchers') returns a pitcher frame with SVHD", {
  testthat::local_mocked_bindings(
    .fetch_projections_api = function(url) fx_pitcher_json(3L, include_qs = TRUE),
    .package = "rotostats"
  )
  rlang::reset_message_verbosity("rotostats_svhd_definition")
  expect_message(
    out <- get_projections(source = "steamer", player_type = "pitchers"),
    regexp = "SVHD computed as SV \\+ HLD"
  )
  expect_equal(nrow(out), 3L)
  expect_true("svhd" %in% names(out))
  expect_true(all(out$player_type == "pitcher"))
  expect_true("qs" %in% names(out))
  expect_true("k" %in% names(out))
  expect_equal(
    out$k[out$player_type == "pitcher"],
    out$k_per_9[out$player_type == "pitcher"] *
      out$ip[out$player_type == "pitcher"] / 9
  )
})

test_that("get_projections(..., player_type = 'both') rbinds with NA fill", {
  # The mock needs to return different payloads depending on the URL's
  # stats= parameter. Inspect the URL to decide.
  testthat::local_mocked_bindings(
    .fetch_projections_api = function(url) {
      if (grepl("stats=bat", url)) fx_batter_json(2L) else fx_pitcher_json(2L)
    },
    .package = "rotostats"
  )
  rlang::reset_message_verbosity("rotostats_svhd_definition")
  out <- suppressMessages(
    get_projections(source = "steamer", player_type = "both")
  )
  expect_equal(nrow(out), 4L)
  expect_setequal(unique(out$player_type), c("batter", "pitcher"))
  # Non-shared columns are NA-filled
  expect_true(all(is.na(out$ip[out$player_type == "batter"])))
  expect_true(all(is.na(out$ab[out$player_type == "pitcher"])))
})

# ---------------------------------------------------------------------------
# get_projections() — top-level error surfaces
# ---------------------------------------------------------------------------

test_that("get_projections() surfaces source validation", {
  expect_error(
    get_projections(source = "marcel"),
    class = "rotostats_error_invalid_source"
  )
})

test_that("get_projections() surfaces player_type validation", {
  expect_error(
    get_projections(source = "steamer", player_type = "batter"),
    class = "rotostats_error_invalid_player_type"
  )
})

test_that("get_projections() surfaces year validation", {
  cur <- rotostats:::.current_season_year()
  expect_error(
    get_projections(source = "steamer", year = cur - 1L),
    class = "rotostats_error_unsupported_year"
  )
})

test_that("get_projections() rejects data supplied with non-custom source", {
  d <- data.frame(name = "A", HR = 10)
  expect_error(
    get_projections(source = "steamer", data = d),
    class = "rotostats_error_data_ignored"
  )
})

test_that("get_projections(source = 'custom') requires data", {
  expect_error(
    get_projections(source = "custom"),
    class = "rotostats_error_missing_custom_data"
  )
})

# ---------------------------------------------------------------------------
# Recorded-fixture integration tests
# ---------------------------------------------------------------------------

load_fixture <- function(name) {
  path <- testthat::test_path("fixtures", name)
  jsonlite::read_json(path)
}

test_that("get_projections('steamer', 'batters') parses the recorded fixture cleanly", {
  testthat::skip_if_not_installed("jsonlite")
  testthat::local_mocked_bindings(
    .fetch_projections_api = function(url) load_fixture("projections-steamer-bat.json"),
    .package = "rotostats"
  )
  out <- get_projections(source = "steamer", player_type = "batters")
  expect_s3_class(out, "data.frame")
  expect_gt(nrow(out), 0L)
  expect_true(all(c("player_id", "player_name", "team", "pos_eligibility", "player_type") %in% names(out)))
  expect_true(all(out$player_type == "batter"))
  expect_type(out$pos_eligibility, "character")
  expect_true(all(nchar(out$pos_eligibility) <= 6, na.rm = TRUE))
  # Pipe-delimited now — no slashes should remain
  expect_false(any(grepl("/", out$pos_eligibility, fixed = TRUE), na.rm = TRUE))
})

test_that("get_projections('steamer', 'pitchers') derives SVHD from the recorded fixture", {
  testthat::skip_if_not_installed("jsonlite")
  testthat::local_mocked_bindings(
    .fetch_projections_api = function(url) load_fixture("projections-steamer-pit.json"),
    .package = "rotostats"
  )
  rlang::reset_message_verbosity("rotostats_svhd_definition")
  out <- suppressMessages(
    get_projections(source = "steamer", player_type = "pitchers")
  )
  expect_true("svhd" %in% names(out))
  expect_true(all(out$svhd == out$sv + out$hld |
                  is.na(out$sv) | is.na(out$hld) | out$svhd >= 0))
  expect_true("pos_eligibility" %in% names(out))
  expect_true(all(out$pos_eligibility[out$player_type == "pitcher"] == "P"))
})

test_that("ZiPS pitcher fixture parses even without QS", {
  testthat::skip_if_not_installed("jsonlite")
  testthat::local_mocked_bindings(
    .fetch_projections_api = function(url) load_fixture("projections-zips-pit.json"),
    .package = "rotostats"
  )
  rlang::reset_message_verbosity("rotostats_svhd_definition")
  out <- suppressMessages(
    get_projections(source = "zips", player_type = "pitchers")
  )
  expect_s3_class(out, "data.frame")
  # QS may or may not be present — this is documented in the spec. Either way,
  # no error is thrown and the rest of the pipeline works.
  expect_gt(nrow(out), 0L)
})

# ---------------------------------------------------------------------------
# .normalize_pos_eligibility()
# ---------------------------------------------------------------------------

test_that(".normalize_pos_eligibility() renames pos to pos_eligibility", {
  df <- data.frame(pos = c("2B", "SS/OF"), stringsAsFactors = FALSE)
  out <- rotostats:::.normalize_pos_eligibility(df)
  expect_true("pos_eligibility" %in% names(out))
  expect_false("pos" %in% names(out))
})

test_that(".normalize_pos_eligibility() converts / separators to |", {
  df <- data.frame(pos = c("2B", "SS/OF", "1B/3B/OF"), stringsAsFactors = FALSE)
  out <- rotostats:::.normalize_pos_eligibility(df)
  expect_equal(out$pos_eligibility, c("2B", "SS|OF", "1B|3B|OF"))
})

test_that(".normalize_pos_eligibility() leaves single positions alone", {
  df <- data.frame(pos = c("P", "C", "DH"), stringsAsFactors = FALSE)
  out <- rotostats:::.normalize_pos_eligibility(df)
  expect_equal(out$pos_eligibility, c("P", "C", "DH"))
})

test_that(".normalize_pos_eligibility() is a no-op when pos is absent", {
  df <- data.frame(player_name = "X", stringsAsFactors = FALSE)
  out <- rotostats:::.normalize_pos_eligibility(df)
  expect_identical(out, df)
  expect_false("pos_eligibility" %in% names(out))
})

test_that(".normalize_pos_eligibility() preserves NA in pos", {
  df <- data.frame(pos = c("2B", NA_character_, "SS/OF"), stringsAsFactors = FALSE)
  out <- rotostats:::.normalize_pos_eligibility(df)
  expect_equal(out$pos_eligibility, c("2B", NA_character_, "SS|OF"))
})

# ---------------------------------------------------------------------------
# .derive_k()
# ---------------------------------------------------------------------------

test_that(".derive_k() computes k = k_per_9 * ip / 9", {
  df <- data.frame(ip = c(180, 90), k_per_9 = c(9.0, 10.0), stringsAsFactors = FALSE)
  out <- rotostats:::.derive_k(df)
  expect_equal(out$k, c(180, 100))
})

test_that(".derive_k() is a no-op if k_per_9 is absent", {
  df <- data.frame(ip = 180, stringsAsFactors = FALSE)
  out <- rotostats:::.derive_k(df)
  expect_identical(out, df)
  expect_false("k" %in% names(out))
})

test_that(".derive_k() is a no-op if ip is absent", {
  df <- data.frame(k_per_9 = 9.0, stringsAsFactors = FALSE)
  out <- rotostats:::.derive_k(df)
  expect_identical(out, df)
  expect_false("k" %in% names(out))
})

test_that(".derive_k() does not overwrite an existing k column", {
  df <- data.frame(ip = 180, k_per_9 = 9.0, k = 42, stringsAsFactors = FALSE)
  out <- rotostats:::.derive_k(df)
  expect_equal(out$k, 42)
})

test_that(".derive_k() propagates NA in ip or k_per_9", {
  df <- data.frame(
    ip      = c(180, NA_real_, 90),
    k_per_9 = c(9.0, 10.0,     NA_real_),
    stringsAsFactors = FALSE
  )
  out <- rotostats:::.derive_k(df)
  expect_equal(out$k, c(180, NA_real_, NA_real_))
})

# ---------------------------------------------------------------------------
# .filter_mlb()
# ---------------------------------------------------------------------------

test_that(".filter_mlb() keeps AL and NL rows", {
  df <- data.frame(
    player_name = c("A", "B", "C"),
    league      = c("AL", "NL", "AL"),
    stringsAsFactors = FALSE
  )
  out <- rotostats:::.filter_mlb(df)
  expect_equal(nrow(out), 3L)
})

test_that(".filter_mlb() drops rows with other league values", {
  df <- data.frame(
    player_name = c("A", "B", "C", "D"),
    league      = c("AL", "AAA", "NL", "FA"),
    stringsAsFactors = FALSE
  )
  out <- rotostats:::.filter_mlb(df)
  expect_equal(nrow(out), 2L)
  expect_equal(out$player_name, c("A", "C"))
})

test_that(".filter_mlb() drops rows with NA league", {
  df <- data.frame(
    player_name = c("A", "B", "C"),
    league      = c("AL", NA_character_, "NL"),
    stringsAsFactors = FALSE
  )
  out <- rotostats:::.filter_mlb(df)
  expect_equal(nrow(out), 2L)
  expect_equal(out$player_name, c("A", "C"))
})

test_that(".filter_mlb() is a no-op when league column is absent", {
  df <- data.frame(player_name = "A", stringsAsFactors = FALSE)
  out <- rotostats:::.filter_mlb(df)
  expect_identical(out, df)
})

# ---------------------------------------------------------------------------
# .validate_mlb_only()
# ---------------------------------------------------------------------------

test_that(".validate_mlb_only() accepts TRUE and FALSE", {
  expect_true(rotostats:::.validate_mlb_only(TRUE))
  expect_false(rotostats:::.validate_mlb_only(FALSE))
})

test_that(".validate_mlb_only() rejects non-logical", {
  expect_error(
    rotostats:::.validate_mlb_only("yes"),
    class = "rotostats_error_invalid_mlb_only"
  )
  expect_error(
    rotostats:::.validate_mlb_only(1),
    class = "rotostats_error_invalid_mlb_only"
  )
})

test_that(".validate_mlb_only() rejects length != 1", {
  expect_error(
    rotostats:::.validate_mlb_only(c(TRUE, FALSE)),
    class = "rotostats_error_invalid_mlb_only"
  )
  expect_error(
    rotostats:::.validate_mlb_only(logical(0)),
    class = "rotostats_error_invalid_mlb_only"
  )
})

test_that(".validate_mlb_only() rejects NA", {
  expect_error(
    rotostats:::.validate_mlb_only(NA),
    class = "rotostats_error_invalid_mlb_only"
  )
})

test_that(".fetch_and_assemble_projections() applies .filter_mlb when mlb_only is TRUE", {
  fake_df <- data.frame(
    player_id   = 1:3,
    player_name = c("A", "B", "C"),
    league      = c("AL", "AAA", "NL"),
    player_type = "batter",
    stringsAsFactors = FALSE
  )
  testthat::local_mocked_bindings(
    .fetch_one_side = function(source, player_type) fake_df,
    .package = "rotostats"
  )
  out <- rotostats:::.fetch_and_assemble_projections("steamer", "batters", mlb_only = TRUE)
  expect_equal(nrow(out), 2L)
  expect_equal(out$player_name, c("A", "C"))
})

test_that(".fetch_and_assemble_projections() preserves all rows when mlb_only is FALSE", {
  fake_df <- data.frame(
    player_id   = 1:3,
    player_name = c("A", "B", "C"),
    league      = c("AL", "AAA", "NL"),
    player_type = "batter",
    stringsAsFactors = FALSE
  )
  testthat::local_mocked_bindings(
    .fetch_one_side = function(source, player_type) fake_df,
    .package = "rotostats"
  )
  out <- rotostats:::.fetch_and_assemble_projections("steamer", "batters", mlb_only = FALSE)
  expect_equal(nrow(out), 3L)
})

# ---------------------------------------------------------------------------
# get_projections() — tibble return + mlb_only argument
# ---------------------------------------------------------------------------

test_that("get_projections() returns a tibble (API path)", {
  fake_df <- data.frame(
    player_id   = 1:2,
    player_name = c("A", "B"),
    league      = c("AL", "NL"),
    player_type = "batter",
    stringsAsFactors = FALSE
  )
  testthat::local_mocked_bindings(
    .fetch_one_side = function(source, player_type) fake_df,
    .package = "rotostats"
  )
  out <- get_projections(source = "steamer", player_type = "batters")
  expect_s3_class(out, "tbl_df")
})

test_that("get_projections() returns a tibble (custom path)", {
  custom <- data.frame(
    name = c("X", "Y"),
    HR   = c(20, 25),
    stringsAsFactors = FALSE
  )
  out <- get_projections(source = "custom", data = custom)
  expect_s3_class(out, "tbl_df")
})

test_that("get_projections() defaults mlb_only = TRUE and drops non-AL/NL rows", {
  fake_df <- data.frame(
    player_id   = 1:3,
    player_name = c("A", "B", "C"),
    league      = c("AL", "AAA", "NL"),
    player_type = "batter",
    stringsAsFactors = FALSE
  )
  testthat::local_mocked_bindings(
    .fetch_one_side = function(source, player_type) fake_df,
    .package = "rotostats"
  )
  out <- get_projections(source = "steamer", player_type = "batters")
  expect_equal(nrow(out), 2L)
})

test_that("get_projections(mlb_only = FALSE) preserves all rows", {
  fake_df <- data.frame(
    player_id   = 1:3,
    player_name = c("A", "B", "C"),
    league      = c("AL", "AAA", "NL"),
    player_type = "batter",
    stringsAsFactors = FALSE
  )
  testthat::local_mocked_bindings(
    .fetch_one_side = function(source, player_type) fake_df,
    .package = "rotostats"
  )
  out <- get_projections(
    source      = "steamer",
    player_type = "batters",
    mlb_only    = FALSE
  )
  expect_equal(nrow(out), 3L)
})

test_that("get_projections() surfaces invalid mlb_only error class", {
  expect_error(
    get_projections(source = "steamer", mlb_only = "yes"),
    class = "rotostats_error_invalid_mlb_only"
  )
})
