test_that("sgp() computes sgp_OPS as sum of marginal OBP and SLG blends", {
  proj <- data.frame(
    player_id       = paste0("P", 1:5),
    player_name     = paste0("Player", 1:5),
    pos_eligibility = rep("OF", 5),
    player_type     = rep("batter", 5),
    HR  = c(30, 25, 20, 15, 10),
    R   = c(80, 75, 70, 65, 60),
    RBI = c(85, 80, 75, 70, 65),
    SB  = c(5, 3, 2, 4, 6),
    AVG = c(0.270, 0.265, 0.260, 0.255, 0.250),
    OBP = c(0.350, 0.345, 0.340, 0.335, 0.330),
    SLG = c(0.480, 0.460, 0.440, 0.420, 0.400),
    PA  = c(600, 580, 560, 540, 520),
    AB  = c(540, 525, 510, 495, 480),
    stringsAsFactors = FALSE
  )
  denoms <- rotostats:::new_sgp_denominators(
    denominators = c(HR = 1, R = 1, RBI = 1, SB = 1, AVG = 1, OPS = 1),
    year_diagnostics = data.frame(),
    bootstrap_ci = NULL,
    call = quote(sgp_denominators()),
    meta = list(
      rate_conversion = "blended_pool",
      method = "ols",
      years_used = 2023L,
      exclude_years = integer(0),
      package_version = "0.0.0.9000"
    ),
    rate_conversion = "blended_pool"
  )

  lh <- list(
    team_season = data.frame(
      YEAR = rep(2023L, 4),
      TEAM_ID = paste0("T", 1:4),
      AVG  = c(0.255, 0.265, 0.270, 0.260),
      OBP  = c(0.320, 0.330, 0.335, 0.325),
      SLG  = c(0.420, 0.440, 0.450, 0.430),
      AB   = c(5500, 5400, 5600, 5450),
      PA   = c(6100, 6000, 6200, 6050),
      IP   = c(1400, 1350, 1380, 1420),
      stringsAsFactors = FALSE
    )
  )

  lc <- league_config(
    n_teams = 12L,
    roster_slots = c(
      C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L, SS = 1L, OF = 5L, UTIL = 1L
    ),
    pitcher_slots      = c(SP = 6L, RP = 3L),
    batting_categories = c("HR", "R", "RBI", "SB", "AVG", "OPS"),
    pitcher_categories = character(0)
  )

  out <- sgp(projections = proj, denominators = denoms,
             league_history = lh, league_config = lc)
  expect_true("sgp_OPS" %in% names(out))
  expect_true(all(!is.na(out[["sgp_OPS"]])))

  # Higher-OPS players should get higher sgp_OPS
  ops_vals <- proj$OBP + proj$SLG
  expect_equal(order(out[["sgp_OPS"]], decreasing = TRUE),
               order(ops_vals, decreasing = TRUE))
})
