test_that(".read_tw_batters reads a per-team batter CSV with expected columns", {
  path <- "../../data-raw/sources/tout-wars/rosters/2024-al-batters.csv"
  skip_if_not(file.exists(path), "raw batter CSV not present")

  out <- rotostats:::.read_tw_batters(path)

  required <- c("year", "league", "team", "player_name", "player_id",
                "mlb_team", "position", "salary", "status", "roster_section",
                "eligibility", "ab", "h", "g", "r", "hr", "rbi", "sb", "so",
                "bb", "obp", "slg")
  expect_true(all(required %in% names(out)))
  expect_type(out$year, "integer")
  expect_type(out$league, "character")
  expect_type(out$team, "character")
  expect_type(out$ab, "integer")
  expect_type(out$h, "integer")
  expect_type(out$obp, "double")
  expect_type(out$roster_section, "character")
  expect_true(nrow(out) > 0)
  expect_true(all(out$year == 2024L))
  expect_true(all(out$league == "al"))
})

test_that(".read_tw_pitchers reads a per-team pitcher CSV with expected columns", {
  path <- "../../data-raw/sources/tout-wars/rosters/2024-al-pitchers.csv"
  skip_if_not(file.exists(path), "raw pitcher CSV not present")

  out <- rotostats:::.read_tw_pitchers(path)

  required <- c("year", "league", "team", "player_name", "player_id",
                "mlb_team", "position", "salary", "status", "roster_section",
                "eligibility", "g", "w", "l", "sv", "ip", "bb", "hr",
                "so", "era", "whip")
  expect_true(all(required %in% names(out)))
  expect_type(out$ip, "double")
  expect_type(out$w, "integer")
  expect_type(out$era, "double")
  expect_type(out$whip, "double")
  expect_true(nrow(out) > 0)
})

test_that(".read_tw_batters errors if a required column is missing", {
  tmp <- withr::local_tempfile(fileext = ".csv")
  writeLines("year,league,team\n2024,al,X", tmp)
  expect_error(
    rotostats:::.read_tw_batters(tmp),
    class = "rotostats_error_team_season_missing_column"
  )
})

test_that(".filter_active_sections keeps active and previously_active only", {
  df <- tibble::tibble(
    roster_section = c("active", "reserved", "previously_active",
                       "previously_reserved", "active"),
    val = 1:5
  )
  out <- rotostats:::.filter_active_sections(df)
  expect_equal(out$val, c(1L, 3L, 5L))
})

test_that(".filter_active_sections errors on unknown section value", {
  df <- tibble::tibble(roster_section = c("active", "weird"))
  expect_error(
    rotostats:::.filter_active_sections(df),
    class = "rotostats_error_team_season_unknown_section"
  )
})

test_that(".aggregate_team_batting sums AB, H, BB, SO per team", {
  bat <- tibble::tibble(
    year = 2024L, league = "al", team = "Owner1",
    roster_section = "active",
    ab = c(500L, 400L, 300L),
    h  = c(150L, 100L,  60L),
    bb = c( 50L,  40L,  20L),
    so = c(120L,  90L,  60L)
  )
  out <- rotostats:::.aggregate_team_batting(bat)
  expect_equal(out$year, 2024L)
  expect_equal(out$league, "al")
  expect_equal(out$team, "Owner1")
  expect_equal(out$ab, 1200L)
  expect_equal(out$h_bat, 310L)
  expect_equal(out$bb_bat, 110L)
  expect_equal(out$so_bat, 270L)
})

test_that(".aggregate_team_batting groups by (year, league, team)", {
  bat <- tibble::tibble(
    year = c(2024L, 2024L, 2024L),
    league = c("al", "al", "al"),
    team = c("A", "A", "B"),
    roster_section = "active",
    ab = c(500L, 400L, 100L),
    h  = c(150L, 100L,  30L),
    bb = 0L, so = 0L
  )
  out <- rotostats:::.aggregate_team_batting(bat)
  expect_equal(nrow(out), 2L)
  expect_setequal(out$team, c("A", "B"))
  ab_a <- out$ab[out$team == "A"]
  ab_b <- out$ab[out$team == "B"]
  expect_equal(ab_a, 900L)
  expect_equal(ab_b, 100L)
})

test_that(".aggregate_team_pitching sums IP and reconstructs ER/H/BB", {
  pit <- tibble::tibble(
    year = 2024L, league = "al", team = "Owner1",
    roster_section = "active",
    ip   = c(200.0, 150.0, 60.0),
    bb   = c( 50L,   40L,  20L),
    era  = c(3.60, 4.20, 5.00),
    whip = c(1.20, 1.30, 1.40)
  )
  out <- rotostats:::.aggregate_team_pitching(pit)
  expect_equal(out$ip, 410.0)
  expect_equal(out$bb_pit, 110L)
  # ER_eq = round(200*3.60/9) + round(150*4.20/9) + round(60*5.00/9)
  #       = 80 + 70 + 33 = 183
  expect_equal(out$er_eq, 183L)
  # h_pit_eq per row = round(ip*whip) - bb
  # rows: round(240) - 50 = 190, round(195) - 40 = 155, round(84) - 20 = 64
  # sum = 190 + 155 + 64 = 409
  expect_equal(out$h_pit_eq, 409L)
})

test_that(".aggregate_team_pitching drops ip=0 contamination rows", {
  pit <- tibble::tibble(
    year = 2024L, league = "al", team = "Owner1",
    roster_section = "active",
    ip   = c(200.0, 150.0, 0.0),    # third row is non-pitcher contamination
    bb   = c( 50L,   40L, 42L),     # bb=42 from a position player
    era  = c(3.60, 4.20, 0.00),
    whip = c(1.20, 1.30, 0.00)
  )
  out <- rotostats:::.aggregate_team_pitching(pit)
  expect_equal(out$ip, 350.0)
  expect_equal(out$bb_pit, 90L)        # 42 BB from contamination row excluded
  # ER_eq = round(200*3.60/9) + round(150*4.20/9) = 80 + 70 = 150
  expect_equal(out$er_eq, 150L)
  # h_pit_eq = (round(200*1.20) - 50) + (round(150*1.30) - 40) = 190 + 155 = 345
  expect_equal(out$h_pit_eq, 345L)
})

test_that(".compute_team_residuals computes joined rates and tolerance flag", {
  joined <- tibble::tibble(
    year = 2024L, league = "al", team_id = "OWNER1",
    ab = 5500L, h_bat = 1500L, bb_bat = 600L,
    ip = 1450, er_eq = 600L, h_pit_eq = 1300L, bb_pit = 450L,
    AVG = 1500 / 5500,        # exact match
    OBP = (1500 + 600) / (5500 + 600),
    ERA = 600 * 9 / 1450,
    WHIP = (1300 + 450) / 1450
  )
  out <- rotostats:::.compute_team_residuals(joined)
  expect_true(abs(out$avg_resid) < 1e-9)
  expect_true(abs(out$obp_resid) < 1e-9)
  expect_true(abs(out$era_resid) < 1e-9)
  expect_true(abs(out$whip_resid) < 1e-9)
  expect_false(out$flagged)
})

test_that(".compute_team_residuals flags rows exceeding tolerance", {
  joined <- tibble::tibble(
    year = 2024L, league = "al", team_id = "OWNER1",
    ab = 5500L, h_bat = 1700L, bb_bat = 600L,  # AVG inflated
    ip = 1450, er_eq = 600L, h_pit_eq = 1300L, bb_pit = 450L,
    AVG = 0.270,
    OBP = 0.340,
    ERA = 600 * 9 / 1450,
    WHIP = (1300 + 450) / 1450
  )
  out <- rotostats:::.compute_team_residuals(joined)
  expect_true(out$flagged)
  expect_gt(abs(out$avg_resid), 0.005)
})

test_that(".compute_team_residuals NAs avg/obp when h_bat is 0 (missing source H)", {
  joined <- tibble::tibble(
    year = 2012L, league = "al", team_id = "OWNER1",
    ab = 5500L, h_bat = 0L, bb_bat = 600L,  # source page lacked H column
    ip = 1450, er_eq = 600L, h_pit_eq = 1300L, bb_pit = 450L,
    AVG = 0.260, OBP = NA_real_,
    ERA = 600 * 9 / 1450,
    WHIP = (1300 + 450) / 1450
  )
  out <- rotostats:::.compute_team_residuals(joined)
  expect_true(is.na(out$avg_resid))
  expect_true(is.na(out$obp_resid))
  expect_false(out$flagged)
})

test_that(".compute_team_residuals handles NA standings values gracefully", {
  joined <- tibble::tibble(
    year = 2024L, league = "al", team_id = "OWNER1",
    ab = 5500L, h_bat = 1500L, bb_bat = 600L,
    ip = 1450, er_eq = 600L, h_pit_eq = 1300L, bb_pit = 450L,
    AVG = NA_real_,             # league didn't score AVG that year
    OBP = (1500 + 600) / (5500 + 600),
    ERA = 600 * 9 / 1450,
    WHIP = (1300 + 450) / 1450
  )
  out <- rotostats:::.compute_team_residuals(joined)
  expect_true(is.na(out$avg_resid))
  expect_false(out$flagged)
})

test_that(".read_tw_standings reads a standings CSV with normalized columns", {
  path <- "../../data-raw/sources/tout-wars/standings/2024-al.csv"
  skip_if_not(file.exists(path), "raw standings CSV not present")

  out <- rotostats:::.read_tw_standings(path)

  expect_true(all(c("year", "league", "team",
                    "R", "HR", "RBI", "SB", "OBP", "AVG",
                    "W", "SV", "ERA", "WHIP", "SO",
                    "R_pts", "HR_pts", "total_pts") %in% names(out)))
  expect_type(out$year, "integer")
  expect_type(out$R, "integer")
  expect_type(out$AVG, "double")
  expect_type(out$OBP, "double")
  expect_type(out$ERA, "double")
  expect_true(all(out$year == 2024L))
  expect_true(all(out$league == "al"))
})
