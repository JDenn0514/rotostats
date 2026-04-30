test_that("sgp() reads K%_BATTER from K% column via source_col", {
  proj <- data.frame(
    player_id       = c("P1", "P2", "P3"),
    player_name     = c("A", "B", "C"),
    pos_eligibility = c("OF", "1B", "3B"),
    player_type     = c("batter", "batter", "batter"),
    HR  = c(30, 25, 20),
    R   = c(80, 75, 70),
    RBI = c(85, 80, 75),
    SB  = c(5, 3, 2),
    AVG = c(0.270, 0.265, 0.260),
    "K%" = c(0.20, 0.22, 0.25),
    PA  = c(600, 580, 560),
    AB  = c(540, 525, 510),
    check.names = FALSE
  )

  cats <- c("HR", "R", "RBI", "SB", "AVG", "K%_BATTER")
  denoms <- rotostats:::new_sgp_denominators(
    denominators     = stats::setNames(rep(10.0, length(cats)), cats),
    year_diagnostics = data.frame(),
    bootstrap_ci     = NULL,
    call             = quote(sgp_denominators()),
    meta             = list(
      rate_conversion = "blended_pool",
      method          = "ols",
      years_used      = 2023L,
      exclude_years   = integer(0L),
      package_version = "0.0.0.9000"
    ),
    rate_conversion = "blended_pool"
  )

  # Minimal league_history for blended_pool rate conversion
  ts <- data.frame(
    YEAR    = rep(2023L, 4L),
    TEAM_ID = paste0("T", 1:4),
    AVG     = c(0.258, 0.262, 0.255, 0.260),
    "K%"    = c(0.215, 0.220, 0.218, 0.222),
    AB      = c(5450, 5500, 5400, 5480),
    PA      = c(6000, 6050, 5950, 6030),
    IP      = c(1380, 1350, 1400, 1360),
    check.names = FALSE
  )
  lh <- list(team_season = ts)

  lc <- league_config(
    n_teams            = 4L,
    roster_slots       = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L,
                           SS = 1L, OF = 3L, DH = 1L),
    pitcher_slots      = c(SP = 5L, RP = 4L),
    batting_categories = c("HR", "R", "RBI", "SB", "AVG", "K%_BATTER"),
    pitcher_categories = character(0L)
  )

  out <- suppressMessages(
    sgp(
      projections    = proj,
      denominators   = denoms,
      league_history = lh,
      league_config  = lc
    )
  )
  expect_true("sgp_K%_BATTER" %in% names(out))
  expect_true(all(!is.na(out[["sgp_K%_BATTER"]])))
})
