# tests/testthat/test-sgp-integration.R
#
# Independent integration tests for sgp() — written by tester from test-spec.md.
# Do NOT modify this file as part of the build pipeline.
# Tester's write surface only. Pipeline isolation: test-spec.md is the only spec read.

# ---------------------------------------------------------------------------
# Test helpers — constructed independently of builder's helpers
# ---------------------------------------------------------------------------

# Build a minimal sgp_denominators S3 object.
fake_denominators <- function(cats, values = NULL, rate_conversion = "blended_pool") {
  if (is.null(values)) {
    values <- stats::setNames(rep(10.0, length(cats)), cats)
  }
  rotostats:::new_sgp_denominators(
    denominators     = values,
    year_diagnostics = data.frame(),
    bootstrap_ci     = NULL,
    call             = quote(sgp_denominators()),
    meta             = list(
      rate_conversion = rate_conversion,
      method          = "ols",
      years_used      = 2023L,
      exclude_years   = integer(0L),
      package_version = "0.0.0.9000"
    ),
    rate_conversion = rate_conversion
  )
}

# Build a minimal duck-typed league_history list.
# Uses uppercase column names because sgp() normalizes names(ts) to uppercase.
fake_league_history <- function(
  years     = 2023L,
  n_teams   = 4L,
  era_vals  = NULL,
  whip_vals = NULL,
  avg_vals  = NULL,
  ip_vals   = NULL,
  ab_vals   = NULL
) {
  n <- n_teams * length(years)
  if (is.null(era_vals))  era_vals  <- rep(c(3.60, 4.00, 3.80, 4.20)[seq_len(n_teams)], length(years))
  if (is.null(whip_vals)) whip_vals <- rep(c(1.20, 1.30, 1.25, 1.35)[seq_len(n_teams)], length(years))
  if (is.null(avg_vals))  avg_vals  <- rep(c(0.258, 0.262, 0.255, 0.260)[seq_len(n_teams)], length(years))
  if (is.null(ip_vals))   ip_vals   <- rep(c(1380, 1350, 1400, 1360)[seq_len(n_teams)], length(years))
  if (is.null(ab_vals))   ab_vals   <- rep(c(5450, 5500, 5400, 5480)[seq_len(n_teams)], length(years))
  ts <- data.frame(
    YEAR    = rep(years, each = n_teams),
    TEAM_ID = paste0("T", seq_len(n)),
    ERA     = era_vals,
    WHIP    = whip_vals,
    AVG     = avg_vals,
    IP      = ip_vals,
    AB      = ab_vals,
    stringsAsFactors = FALSE
  )
  list(team_season = ts)
}

# Build a minimal league_config for n_teams.
# C=1, 1B=1, 2B=1, 3B=1, SS=1, OF=3, DH=1 = 9 primary hitter slots per team
# SP=5, RP=4 = 9 pitcher slots per team
fake_league_config <- function(n_teams = 12L) {
  league_config(
    n_teams       = n_teams,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L,
                      SS = 1L, OF = 3L, DH = 1L),
    pitcher_slots = c(SP = 5L, RP = 4L),
    categories    = c("HR", "R", "RBI", "SB", "AVG", "ERA", "WHIP")
  )
}

# ---------------------------------------------------------------------------
# TS-1: Counting-stat SGP — basic correctness (3 players, 2 categories)
# ---------------------------------------------------------------------------
test_that("TS-1: counting-stat SGP equals projected_stat / denominator (vectorized)", {
  projections <- data.frame(
    HR = c(30L, 20L, 10L),
    R  = c(90L, 80L, 70L),
    IP = c(0L,  0L,  0L),
    AB = c(0L,  0L,  0L)
  )
  denominators <- fake_denominators(
    cats            = c("HR", "R"),
    values          = c(HR = 12.0, R = 18.0),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()
  lc <- fake_league_config()

  result <- suppressMessages(
    sgp(
      projections     = projections,
      denominators    = denominators,
      league_history  = lh,
      league_config   = lc,
      rate_conversion = "blended_pool"
    )
  )

  expected_sgp_HR <- c(30/12, 20/12, 10/12)
  expected_sgp_R  <- c(90/18, 80/18, 70/18)
  expected_total  <- expected_sgp_HR + expected_sgp_R

  expect_equal(result$sgp_HR,    expected_sgp_HR, tolerance = 1e-12)
  expect_equal(result$sgp_R,     expected_sgp_R,  tolerance = 1e-12)
  expect_equal(result$total_sgp, expected_total,  tolerance = 1e-12)
  expect_equal(nrow(result), 3L)
})

# ---------------------------------------------------------------------------
# TS-2: Counting-stat SGP — single player, single category
# ---------------------------------------------------------------------------
test_that("TS-2: single player single category counting SGP", {
  projections  <- data.frame(SB = 40L, IP = 0L, AB = 0L)
  denominators <- fake_denominators(
    cats   = "SB",
    values = c(SB = 5.0),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()
  lc <- fake_league_config()

  result <- suppressMessages(
    sgp(projections, denominators,
        league_history = lh, league_config = lc, rate_conversion = "blended_pool")
  )

  expect_equal(result$sgp_SB,    40 / 5.0, tolerance = 1e-12)
  expect_equal(result$total_sgp, 8.0,      tolerance = 1e-12)
  expect_equal(nrow(result), 1L)
})

# ---------------------------------------------------------------------------
# TS-3: Column names normalized to uppercase
# ---------------------------------------------------------------------------
test_that("TS-3: lowercase projections column names normalized to uppercase", {
  projections  <- data.frame(hr = 25L, ip = 0L, ab = 0L)
  denominators <- fake_denominators(
    cats   = "HR",
    values = c(HR = 10.0),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()
  lc <- fake_league_config()

  result <- suppressMessages(
    sgp(projections, denominators,
        league_history = lh, league_config = lc, rate_conversion = "blended_pool")
  )

  expect_true("sgp_HR" %in% names(result))
  expect_equal(result$sgp_HR, 25 / 10.0, tolerance = 1e-12)
})

# ---------------------------------------------------------------------------
# TS-4: total_sgp column permutation invariance
# ---------------------------------------------------------------------------
test_that("TS-4: total_sgp is invariant to column order in projections", {
  vals <- data.frame(HR = 30L, R = 90L, RBI = 80L, IP = 0L, AB = 0L)
  denominators <- fake_denominators(
    cats   = c("HR", "R", "RBI"),
    values = c(HR = 12.0, R = 18.0, RBI = 15.0),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()
  lc <- fake_league_config()

  proj_a <- vals[, c("HR", "R", "RBI", "IP", "AB")]
  proj_b <- vals[, c("RBI", "HR", "R", "IP", "AB")]

  result_a <- suppressMessages(
    sgp(proj_a, denominators, league_history = lh, league_config = lc)
  )
  result_b <- suppressMessages(
    sgp(proj_b, denominators, league_history = lh, league_config = lc)
  )

  expect_equal(result_a$total_sgp, result_b$total_sgp, tolerance = 1e-12)
})

# ---------------------------------------------------------------------------
# TS-5: Blended-pool ERA SGP — sign correctness
# ---------------------------------------------------------------------------
test_that("TS-5: ERA SGP sign correct — negative above pool mean, positive below", {
  # Pool: 5 pitchers with IP in [150, 200]
  # Evaluated players: IP = 60, strictly below pool minimum (150)
  # → evaluated players are never selected into the pool
  pool_ip  <- c(200, 180, 175, 160, 150)
  pool_era <- c(3.50, 3.80, 4.00, 4.20, 4.50)

  pool_er_total <- sum(pool_era * pool_ip / 9)
  pool_ip_total <- sum(pool_ip)
  pool_mean_era <- pool_er_total * 9 / pool_ip_total

  # Player A: ERA well below pool mean → sgp_ERA > 0
  era_A <- 2.50
  ip_A  <- 60   # strictly below pool minimum 150
  # Player B: ERA well above pool mean → sgp_ERA < 0
  era_B <- 5.50
  ip_B  <- 60

  projections <- data.frame(
    ERA = c(pool_era, era_A, era_B),
    IP  = c(pool_ip,  ip_A,  ip_B),
    AB  = rep(0L, 7L),
    HR  = rep(0L, 7L)
  )

  # avg_ERA from league history = pool_mean_era (symmetric 2-team history)
  lh <- list(team_season = data.frame(
    YEAR    = c(2023L, 2023L),
    TEAM_ID = c("T1", "T2"),
    ERA     = c(pool_mean_era, pool_mean_era),
    IP      = c(1380L, 1380L),
    WHIP    = c(1.25, 1.25),
    AVG     = c(0.258, 0.258),
    AB      = c(5400L, 5400L),
    stringsAsFactors = FALSE
  ))

  denominators <- fake_denominators(
    cats   = c("HR", "ERA"),
    values = c(HR = 12.0, ERA = 0.25),
    rate_conversion = "blended_pool"
  )

  # pool_size_p = n_teams * pitcher_slots = 1 * 5 = 5
  lc <- league_config(
    n_teams       = 1L,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L, SS = 1L),
    pitcher_slots = 5L,
    categories    = c("HR", "ERA")
  )

  result <- suppressMessages(
    sgp(projections, denominators,
        league_history = lh, league_config = lc, rate_conversion = "blended_pool")
  )

  expect_true(result$sgp_ERA[6L] > 0,
              label = "Player A (ERA below pool mean) should have positive ERA SGP")
  expect_true(result$sgp_ERA[7L] < 0,
              label = "Player B (ERA above pool mean) should have negative ERA SGP")
})

# ---------------------------------------------------------------------------
# TS-6: Blended-pool WHIP SGP — sign correctness
# ---------------------------------------------------------------------------
test_that("TS-6: WHIP SGP sign correct — negative above pool mean, positive below", {
  pool_ip   <- c(200, 180, 175, 160, 150)
  pool_whip <- c(1.10, 1.20, 1.25, 1.30, 1.35)
  pool_wh   <- sum(pool_whip * pool_ip)
  pool_ip_t <- sum(pool_ip)
  pool_mean_whip <- pool_wh / pool_ip_t

  # Player A: WHIP = 0.90 (below pool mean) → positive
  # Player B: WHIP = 1.60 (above pool mean) → negative
  # Both have IP = 60, strictly below pool minimum (150)
  projections <- data.frame(
    WHIP = c(pool_whip, 0.90, 1.60),
    IP   = c(pool_ip, 60, 60),
    AB   = rep(0L, 7L),
    HR   = rep(0L, 7L)
  )

  lh <- list(team_season = data.frame(
    YEAR    = c(2023L, 2023L),
    TEAM_ID = c("T1", "T2"),
    ERA     = c(3.80, 3.80),
    WHIP    = c(pool_mean_whip, pool_mean_whip),
    AVG     = c(0.258, 0.258),
    IP      = c(1380L, 1380L),
    AB      = c(5400L, 5400L),
    stringsAsFactors = FALSE
  ))

  denominators <- fake_denominators(
    cats   = c("HR", "WHIP"),
    values = c(HR = 12.0, WHIP = 0.05),
    rate_conversion = "blended_pool"
  )

  # pool_size_p = 1 * 5 = 5
  lc <- league_config(
    n_teams       = 1L,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L, SS = 1L),
    pitcher_slots = 5L,
    categories    = c("HR", "WHIP")
  )

  result <- suppressMessages(
    sgp(projections, denominators,
        league_history = lh, league_config = lc, rate_conversion = "blended_pool")
  )

  expect_true(result$sgp_WHIP[6L] > 0,
              label = "Player A (WHIP=0.90, below pool mean) should have positive WHIP SGP")
  expect_true(result$sgp_WHIP[7L] < 0,
              label = "Player B (WHIP=1.60, above pool mean) should have negative WHIP SGP")
})

# ---------------------------------------------------------------------------
# TS-7: Blended-pool AVG SGP — sign correctness (sign flip vs ERA/WHIP)
# ---------------------------------------------------------------------------
test_that("TS-7: AVG SGP sign correct — positive above pool mean (sign flip vs ERA/WHIP)", {
  # Pool: 5 hitters with AB in [470, 550]
  # Evaluated players: AB = 50 / 40, strictly below pool minimum (470)
  # → evaluated players are never selected into the pool
  pool_ab  <- c(550, 530, 510, 490, 470)
  pool_avg <- c(0.270, 0.260, 0.255, 0.250, 0.245)
  pool_h   <- sum(pool_avg * pool_ab)
  pool_ab_t <- sum(pool_ab)
  pool_mean_avg <- pool_h / pool_ab_t

  # Player A: AVG = 0.320, AB = 50 (above pool mean, below pool min AB → not in pool)
  # Player B: AVG = 0.220, AB = 40 (below pool mean, below pool min AB → not in pool)
  projections <- data.frame(
    AVG = c(pool_avg, 0.320, 0.220),
    AB  = c(pool_ab, 50L, 40L),
    IP  = rep(0L, 7L),
    HR  = rep(0L, 7L)
  )

  lh <- list(team_season = data.frame(
    YEAR    = c(2023L, 2023L),
    TEAM_ID = c("T1", "T2"),
    ERA     = c(3.80, 3.80),
    WHIP    = c(1.25, 1.25),
    AVG     = c(pool_mean_avg, pool_mean_avg),
    IP      = c(1380L, 1380L),
    AB      = c(5400L, 5400L),
    stringsAsFactors = FALSE
  ))

  denominators <- fake_denominators(
    cats   = c("HR", "AVG"),
    values = c(HR = 12.0, AVG = 0.003),
    rate_conversion = "blended_pool"
  )

  # pool_size_h = n_teams * sum(primary_slots) = 1 * 5 = 5
  lc <- league_config(
    n_teams       = 1L,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L, SS = 1L),
    pitcher_slots = 1L,
    categories    = c("HR", "AVG")
  )

  result <- suppressMessages(
    sgp(projections, denominators,
        league_history = lh, league_config = lc, rate_conversion = "blended_pool")
  )

  expect_true(result$sgp_AVG[6L] > 0,
              label = "Player A (AVG=0.320, above pool mean) should have positive AVG SGP")
  expect_true(result$sgp_AVG[7L] < 0,
              label = "Player B (AVG=0.220, below pool mean) should have negative AVG SGP")
})

# ---------------------------------------------------------------------------
# TS-8: Blended-pool ERA SGP — exact formula check
# ---------------------------------------------------------------------------
test_that("TS-8: ERA SGP equals exact hand-computed formula", {
  # 2-team league, 2 pitchers per team → pool_size_p = 4
  # Pool pitchers: IP in [170, 200]
  # Evaluated player X: IP = 60, strictly below pool minimum (170)
  pool_ip  <- c(200, 190, 180, 170)
  pool_era <- c(3.00, 3.50, 4.00, 4.50)

  pool_er_total <- sum(pool_era * pool_ip / 9)
  pool_ip_total <- sum(pool_ip)  # = 740

  team_era <- c(3.80, 4.20)
  team_ip  <- c(1400, 1350)
  avg_ERA_expected <- stats::weighted.mean(team_era, team_ip)

  # Player X: ERA = 3.20, IP = 60 (strictly below pool minimum 170)
  player_era <- 3.20
  player_ip  <- 60.0
  player_er  <- player_era * player_ip / 9

  blended_era  <- (pool_er_total + player_er) * 9 / (pool_ip_total + player_ip)
  denom_era    <- 0.25
  expected_sgp <- (avg_ERA_expected - blended_era) / denom_era

  projections <- data.frame(
    ERA = c(pool_era, player_era),
    IP  = c(pool_ip,  player_ip),
    AB  = rep(0L, 5L),
    HR  = rep(0L, 5L)
  )

  lh <- list(team_season = data.frame(
    YEAR    = c(2023L, 2023L),
    TEAM_ID = c("T1", "T2"),
    ERA     = team_era,
    WHIP    = c(1.25, 1.25),
    AVG     = c(0.258, 0.258),
    IP      = team_ip,
    AB      = c(5400L, 5400L),
    stringsAsFactors = FALSE
  ))

  denominators <- fake_denominators(
    cats   = c("HR", "ERA"),
    values = c(HR = 12.0, ERA = denom_era),
    rate_conversion = "blended_pool"
  )

  # pool_size_p = n_teams * pitcher_slots = 2 * 2 = 4
  lc <- league_config(
    n_teams       = 2L,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L, SS = 1L),
    pitcher_slots = 2L,
    categories    = c("HR", "ERA")
  )

  result <- suppressMessages(
    sgp(projections, denominators,
        league_history = lh, league_config = lc, rate_conversion = "blended_pool")
  )

  # Row 5 is player X
  expect_equal(result$sgp_ERA[5L], expected_sgp, tolerance = 1e-12)
})

# ---------------------------------------------------------------------------
# TS-9: Blended-pool AVG SGP — exact formula check
# ---------------------------------------------------------------------------
test_that("TS-9: AVG SGP equals exact hand-computed formula (sign flip verified)", {
  # pool_size_h = 2 * 2 = 4 (n_teams=2, C=1, 1B=1 → 2 primary slots per team)
  # Pool: 4 hitters with AB in [540, 600]
  # Player Y: AB = 500, strictly below pool minimum (540) → not in pool
  pool_ab  <- c(600, 580, 560, 540)
  pool_avg <- c(0.280, 0.265, 0.255, 0.250)
  pool_h   <- sum(pool_avg * pool_ab)
  pool_ab_t <- sum(pool_ab)

  team_avg <- c(0.258, 0.265)
  team_ab  <- c(5400, 5500)
  avg_AVG_expected <- stats::weighted.mean(team_avg, team_ab)

  # Player Y: AVG = 0.300, AB = 500 (< pool min 540)
  player_avg <- 0.300
  player_ab  <- 500.0
  player_h   <- player_avg * player_ab

  blended_avg  <- (pool_h + player_h) / (pool_ab_t + player_ab)
  denom_avg    <- 0.003
  expected_sgp <- (blended_avg - avg_AVG_expected) / denom_avg

  projections <- data.frame(
    AVG = c(pool_avg, player_avg),
    AB  = c(pool_ab, player_ab),
    IP  = rep(0L, 5L),
    HR  = rep(0L, 5L)
  )

  lh <- list(team_season = data.frame(
    YEAR    = c(2023L, 2023L),
    TEAM_ID = c("T1", "T2"),
    ERA     = c(3.80, 3.80),
    WHIP    = c(1.25, 1.25),
    AVG     = team_avg,
    IP      = c(1380L, 1380L),
    AB      = team_ab,
    stringsAsFactors = FALSE
  ))

  denominators <- fake_denominators(
    cats   = c("HR", "AVG"),
    values = c(HR = 12.0, AVG = denom_avg),
    rate_conversion = "blended_pool"
  )

  # pool_size_h = 2 * 2 = 4
  lc <- league_config(
    n_teams       = 2L,
    roster_slots  = c(C = 1L, "1B" = 1L),
    pitcher_slots = 1L,
    categories    = c("HR", "AVG")
  )

  result <- suppressMessages(
    sgp(projections, denominators,
        league_history = lh, league_config = lc, rate_conversion = "blended_pool")
  )

  expect_equal(result$sgp_AVG[5L], expected_sgp, tolerance = 1e-12)
})

# ---------------------------------------------------------------------------
# TS-10: Missing scored category column → NA output + warning
# ---------------------------------------------------------------------------
test_that("TS-10: missing scored category column produces NA and warning", {
  projections <- data.frame(
    HR = c(25L, 15L, 35L),
    IP = rep(0L, 3L),
    AB = rep(0L, 3L)
  )
  denominators <- fake_denominators(
    cats   = c("HR", "SB"),
    values = c(HR = 12.0, SB = 5.0),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()
  lc <- fake_league_config()

  # Capture the return value and the warning separately
  result <- NULL
  expect_warning(
    suppressMessages(
      result <- sgp(projections, denominators,
                    league_history = lh, league_config = lc,
                    rate_conversion = "blended_pool")
    ),
    class = "rotostats_warning_missing_category_column"
  )

  expect_equal(result$sgp_HR, c(25/12, 15/12, 35/12), tolerance = 1e-12)
  expect_true(all(is.na(result$sgp_SB)),
              label = "sgp_SB should be NA for all players when SB column absent")
  expect_true(all(is.na(result$total_sgp)),
              label = "total_sgp should be NA when any category is NA")
})

# ---------------------------------------------------------------------------
# TS-11: Player with 0 projected IP → NA for ERA and WHIP SGP
# ---------------------------------------------------------------------------
test_that("TS-11: zero IP player gets NA for ERA and WHIP SGP, others computed normally", {
  # pool_size_p = 1 * 3 = 3; top 3 pitchers by IP = rows 1-3
  projections <- data.frame(
    ERA  = c(3.00, 3.50, 4.00, 4.50),
    WHIP = c(1.10, 1.20, 1.25, 1.30),
    IP   = c(200,  180,  170,  0),     # row 4 has IP = 0
    AB   = rep(0L, 4L),
    HR   = rep(0L, 4L)
  )
  denominators <- fake_denominators(
    cats   = c("HR", "ERA", "WHIP"),
    values = c(HR = 12.0, ERA = 0.25, WHIP = 0.05),
    rate_conversion = "blended_pool"
  )
  lh <- list(team_season = data.frame(
    YEAR    = c(2023L, 2023L),
    TEAM_ID = c("T1", "T2"),
    ERA     = c(3.80, 4.20),
    WHIP    = c(1.25, 1.30),
    AVG     = c(0.258, 0.262),
    IP      = c(1380L, 1360L),
    AB      = c(5400L, 5450L),
    stringsAsFactors = FALSE
  ))
  # pool_size_p = 1 * 3 = 3
  lc <- league_config(
    n_teams       = 1L,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L),
    pitcher_slots = 3L,
    categories    = c("HR", "ERA", "WHIP")
  )

  result <- NULL
  expect_warning(
    suppressMessages(
      result <- sgp(projections, denominators,
                    league_history = lh, league_config = lc,
                    rate_conversion = "blended_pool")
    ),
    class = "rotostats_warning_missing_category_column"
  )

  expect_true(is.na(result$sgp_ERA[4L]),
              label = "Zero-IP player should have NA sgp_ERA")
  expect_true(is.na(result$sgp_WHIP[4L]),
              label = "Zero-IP player should have NA sgp_WHIP")
  expect_true(all(is.numeric(result$sgp_ERA[1:3])),
              label = "Non-zero-IP players should have numeric sgp_ERA")
  expect_false(any(is.na(result$sgp_ERA[1:3])),
               label = "Non-zero-IP players should not have NA sgp_ERA")
})

# ---------------------------------------------------------------------------
# TS-12: Player with 0 projected AB → NA for AVG SGP
# ---------------------------------------------------------------------------
test_that("TS-12: zero AB player gets NA for AVG SGP, others computed normally", {
  projections <- data.frame(
    AVG = c(0.270, 0.255, 0.260, 0.280),
    AB  = c(550,   520,   500,   0),    # row 4 has AB = 0
    IP  = rep(0L, 4L),
    HR  = rep(0L, 4L)
  )
  denominators <- fake_denominators(
    cats   = c("HR", "AVG"),
    values = c(HR = 12.0, AVG = 0.003),
    rate_conversion = "blended_pool"
  )
  lh <- list(team_season = data.frame(
    YEAR    = c(2023L, 2023L),
    TEAM_ID = c("T1", "T2"),
    ERA     = c(3.80, 4.20),
    WHIP    = c(1.25, 1.30),
    AVG     = c(0.258, 0.265),
    IP      = c(1380L, 1360L),
    AB      = c(5400L, 5450L),
    stringsAsFactors = FALSE
  ))
  # pool_size_h = 2 * 3 = 6; only 4 rows available, head() returns all 4
  lc <- league_config(
    n_teams       = 2L,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L),
    pitcher_slots = 1L,
    categories    = c("HR", "AVG")
  )

  result <- NULL
  expect_warning(
    suppressMessages(
      result <- sgp(projections, denominators,
                    league_history = lh, league_config = lc,
                    rate_conversion = "blended_pool")
    ),
    class = "rotostats_warning_missing_category_column"
  )

  expect_true(is.na(result$sgp_AVG[4L]),
              label = "Zero-AB player should have NA sgp_AVG")
  expect_false(any(is.na(result$sgp_AVG[1:3])),
               label = "Non-zero-AB players should have numeric sgp_AVG")
})

# ---------------------------------------------------------------------------
# TS-13: cli_inform emitted naming baseline year
# ---------------------------------------------------------------------------
test_that("TS-13: cli_inform emitted naming the baseline year used", {
  projections  <- data.frame(HR = c(30L, 20L), IP = rep(0L, 2), AB = rep(0L, 2))
  denominators <- fake_denominators(
    cats   = "HR",
    values = c(HR = 12.0),
    rate_conversion = "blended_pool"
  )
  # History with years 2021, 2022, 2023 — baseline should be 2023
  lh <- list(team_season = data.frame(
    YEAR    = c(2021L, 2021L, 2022L, 2022L, 2023L, 2023L),
    TEAM_ID = rep(c("T1", "T2"), 3L),
    ERA     = rep(3.80, 6L),
    WHIP    = rep(1.25, 6L),
    AVG     = rep(0.260, 6L),
    IP      = rep(1380L, 6L),
    AB      = rep(5400L, 6L),
    stringsAsFactors = FALSE
  ))
  lc <- fake_league_config()

  expect_message(
    sgp(projections, denominators,
        league_history = lh, league_config = lc, rate_conversion = "blended_pool"),
    regexp = "2023"
  )
})

# ---------------------------------------------------------------------------
# TS-14: total_sgp is the direct row sum across all scored categories
# ---------------------------------------------------------------------------
test_that("TS-14: total_sgp equals rowSums of sgp_ columns for all players", {
  # 6 pool pitchers (IP in [150, 200]) + 3 evaluated players (IP = 40-50)
  pool_ip   <- c(200, 190, 180, 170, 160, 150)
  pool_era  <- c(3.00, 3.20, 3.50, 3.80, 4.10, 4.40)
  pool_whip <- c(1.10, 1.15, 1.20, 1.25, 1.30, 1.35)

  proj_eval <- data.frame(
    HR   = c(30L, 20L, 15L),
    RBI  = c(90L, 75L, 60L),
    ERA  = c(3.10, 3.90, 4.50),
    WHIP = c(1.12, 1.28, 1.40),
    IP   = c(50,   45,   40),      # below pool min (150)
    AB   = rep(0L, 3)
  )
  projections <- rbind(
    data.frame(HR = rep(0L, 6), RBI = rep(0L, 6),
               ERA = pool_era, WHIP = pool_whip,
               IP = pool_ip, AB = rep(0L, 6)),
    proj_eval
  )

  denominators <- fake_denominators(
    cats   = c("HR", "RBI", "ERA", "WHIP"),
    values = c(HR = 12.0, RBI = 15.0, ERA = 0.25, WHIP = 0.05),
    rate_conversion = "blended_pool"
  )
  lh <- list(team_season = data.frame(
    YEAR    = c(2023L, 2023L),
    TEAM_ID = c("T1", "T2"),
    ERA     = c(3.80, 4.20),
    WHIP    = c(1.25, 1.30),
    AVG     = c(0.258, 0.262),
    IP      = c(1380L, 1360L),
    AB      = c(5400L, 5450L),
    stringsAsFactors = FALSE
  ))
  # pool_size_p = 2 * 3 = 6
  lc <- league_config(
    n_teams       = 2L,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L),
    pitcher_slots = 3L,
    categories    = c("HR", "RBI", "ERA", "WHIP")
  )

  result <- suppressMessages(
    sgp(projections, denominators, league_history = lh, league_config = lc)
  )

  sgp_cols     <- grep("^sgp_", names(result), value = TRUE)
  manual_total <- unname(rowSums(result[, sgp_cols, drop = FALSE], na.rm = FALSE))

  expect_equal(result$total_sgp, manual_total, tolerance = 1e-12)
})

# ---------------------------------------------------------------------------
# TS-15: SVHD derived from SV + HLD when SVHD column absent
# Round-2 regression (BLOCK-1 fix): builder added .frequency_id = "sgp_svhd_derivation"
# to rlang::inform(). Test asserts the correct behavioral contract from test-spec.md:
# sgp_SVHD = (SV + HLD) / denominator, and inform fires with "SVHD" in the message.
# ---------------------------------------------------------------------------
test_that("TS-15: SVHD derived from SV + HLD — returns correct SGP after BLOCK-1 fix", {
  projections <- data.frame(
    SV  = c(30L, 15L, 5L),
    HLD = c(10L, 20L, 30L),
    IP  = rep(0L, 3),
    AB  = rep(0L, 3)
  )
  denominators <- fake_denominators(
    cats   = "SVHD",
    values = c(SVHD = 4.0),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()
  lc <- fake_league_config()

  # No crash — capture both the inform message and the return value.
  msgs <- character(0L)
  result <- withCallingHandlers(
    suppressWarnings(
      sgp(projections, denominators,
          league_history = lh, league_config = lc, rate_conversion = "blended_pool")
    ),
    message = function(m) {
      msgs <<- c(msgs, conditionMessage(m))
      invokeRestart("muffleMessage")
    }
  )

  # Inform fired at least once and contains "SVHD" (test-spec.md TS-15)
  expect_true(any(grepl("SVHD", msgs, fixed = TRUE)))

  # sgp_SVHD = (SV + HLD) / denominator (test-spec.md TS-15)
  expected_svhd <- (c(30, 15, 5) + c(10, 20, 30)) / 4.0
  expect_equal(result$sgp_SVHD, expected_svhd, tolerance = 1e-12)
  expect_equal(nrow(result), 3L)
})

# ---------------------------------------------------------------------------
# TS-16: SVHD with HD column alias — same fix as TS-15
# ---------------------------------------------------------------------------
test_that("TS-16: SVHD derived using HD alias — returns correct SGP after BLOCK-1 fix", {
  projections <- data.frame(
    SV = c(25L, 10L),
    HD = c(15L, 25L),
    IP = rep(0L, 2),
    AB = rep(0L, 2)
  )
  denominators <- fake_denominators(
    cats   = "SVHD",
    values = c(SVHD = 4.0),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()
  lc <- fake_league_config()

  # No crash — capture both the inform message and the return value.
  msgs <- character(0L)
  result <- withCallingHandlers(
    suppressWarnings(
      sgp(projections, denominators,
          league_history = lh, league_config = lc, rate_conversion = "blended_pool")
    ),
    message = function(m) {
      msgs <<- c(msgs, conditionMessage(m))
      invokeRestart("muffleMessage")
    }
  )

  # Inform may or may not fire depending on session state (.frequency = "once" is per-session)
  # The behavioral requirement is that the function succeeds and computes correctly.

  # sgp_SVHD = (SV + HD) / denominator (test-spec.md TS-16)
  expected_svhd <- (c(25, 10) + c(15, 25)) / 4.0
  expect_equal(result$sgp_SVHD, expected_svhd, tolerance = 1e-12)
  expect_equal(nrow(result), 2L)
})


# ---------------------------------------------------------------------------
# EC-1: rate_conversion not in recognized five values
# ---------------------------------------------------------------------------
test_that("EC-1: unrecognized rate_conversion aborts with rotostats_error_invalid_rate_conversion", {
  projections  <- data.frame(HR = 30L, IP = 0L, AB = 0L)
  denominators <- fake_denominators("HR", c(HR = 12.0), "blended_pool")

  expect_error(
    sgp(projections, denominators, rate_conversion = "bogus_method"),
    class = "rotostats_error_invalid_rate_conversion"
  )
})

# ---------------------------------------------------------------------------
# EC-2: blended_pool rate_conversion with incompatible (fixed_baseline) denominator
# ---------------------------------------------------------------------------
test_that("EC-2: blended_pool + fixed_baseline denominator aborts with rotostats_error_invalid_rate_conversion", {
  projections      <- data.frame(HR = 30L, IP = 0L, AB = 0L)
  denominators_fb  <- fake_denominators("HR", c(HR = 12.0), "fixed_baseline")

  expect_error(
    sgp(projections, denominators_fb, rate_conversion = "blended_pool"),
    class = "rotostats_error_invalid_rate_conversion"
  )
})

# ---------------------------------------------------------------------------
# EC-3: rate_conversion = "per_player", "universal_constants", "team_ip_normalized"
# ---------------------------------------------------------------------------
test_that("EC-3: per_player rate_conversion aborts with rotostats_error_not_implemented", {
  projections  <- data.frame(HR = 30L, IP = 0L, AB = 0L)
  denominators <- fake_denominators("HR", c(HR = 12.0), "blended_pool")

  expect_error(
    sgp(projections, denominators, rate_conversion = "per_player"),
    class = "rotostats_error_not_implemented"
  )
})

test_that("EC-3: universal_constants rate_conversion aborts with rotostats_error_not_implemented", {
  projections  <- data.frame(HR = 30L, IP = 0L, AB = 0L)
  denominators <- fake_denominators("HR", c(HR = 12.0), "blended_pool")

  expect_error(
    sgp(projections, denominators, rate_conversion = "universal_constants"),
    class = "rotostats_error_not_implemented"
  )
})

test_that("EC-3: team_ip_normalized rate_conversion aborts with rotostats_error_not_implemented", {
  projections  <- data.frame(HR = 30L, IP = 0L, AB = 0L)
  denominators <- fake_denominators("HR", c(HR = 12.0), "blended_pool")

  expect_error(
    sgp(projections, denominators, rate_conversion = "team_ip_normalized"),
    class = "rotostats_error_not_implemented"
  )
})

# ---------------------------------------------------------------------------
# EC-4: rate_conversion = "fixed_baseline" delegates to convert_rate_stats() stub
# ---------------------------------------------------------------------------
test_that("EC-4: fixed_baseline delegates to convert_rate_stats and aborts with rotostats_error_not_implemented", {
  projections  <- data.frame(HR = 30L, IP = 0L, AB = 0L)
  denominators <- fake_denominators("HR", c(HR = 12.0), "fixed_baseline")

  expect_error(
    sgp(projections, denominators, rate_conversion = "fixed_baseline"),
    class = "rotostats_error_not_implemented"
  )
})

# ---------------------------------------------------------------------------
# EC-5: league_history NULL with blended_pool → error
# ---------------------------------------------------------------------------
test_that("EC-5: NULL league_history with blended_pool aborts with rotostats_error_missing_config_field", {
  projections  <- data.frame(HR = 30L, ERA = 3.5, IP = 100L, AB = 0L)
  denominators <- fake_denominators(
    c("HR", "ERA"), c(HR = 12.0, ERA = 0.25), "blended_pool"
  )

  expect_error(
    sgp(projections, denominators,
        rate_conversion = "blended_pool",
        league_history  = NULL,
        league_config   = fake_league_config()),
    class = "rotostats_error_missing_config_field"
  )
})

# ---------------------------------------------------------------------------
# EC-6: league_config NULL with projection_pool → error
# ---------------------------------------------------------------------------
test_that("EC-6: NULL league_config with projection_pool aborts with rotostats_error_missing_config_field", {
  projections  <- data.frame(HR = 30L, ERA = 3.5, IP = 100L, AB = 0L)
  denominators <- fake_denominators(
    c("HR", "ERA"), c(HR = 12.0, ERA = 0.25), "blended_pool"
  )

  expect_error(
    sgp(projections, denominators,
        rate_conversion = "blended_pool",
        league_history  = fake_league_history(),
        league_config   = NULL),
    class = "rotostats_error_missing_config_field"
  )
})

# ---------------------------------------------------------------------------
# EC-7: Single player, all categories present
# ---------------------------------------------------------------------------
test_that("EC-7: single player projections returns exactly 1 row", {
  projections  <- data.frame(HR = 30L, IP = 0L, AB = 0L)
  denominators <- fake_denominators("HR", c(HR = 12.0), "blended_pool")
  lh <- fake_league_history()
  lc <- fake_league_config()

  result <- suppressMessages(
    sgp(projections, denominators, league_history = lh, league_config = lc)
  )

  expect_equal(nrow(result), 1L)
  expect_equal(result$sgp_HR, 30 / 12.0, tolerance = 1e-12)
})

# ---------------------------------------------------------------------------
# EC-8: All players have NA values in a scoring category
# ---------------------------------------------------------------------------
test_that("EC-8: all-NA scoring category produces all-NA sgp_ column and all-NA total_sgp", {
  projections <- data.frame(
    HR = c(NA_real_, NA_real_, NA_real_),
    IP = rep(0L, 3),
    AB = rep(0L, 3)
  )
  denominators <- fake_denominators("HR", c(HR = 12.0), "blended_pool")
  lh <- fake_league_history()
  lc <- fake_league_config()

  result <- suppressMessages(
    sgp(projections, denominators, league_history = lh, league_config = lc)
  )

  expect_true(all(is.na(result$sgp_HR)),
              label = "All-NA HR projections should yield all-NA sgp_HR")
  expect_true(all(is.na(result$total_sgp)),
              label = "total_sgp should be all-NA when sgp_HR is all-NA")
})

# ---------------------------------------------------------------------------
# EC-9: Empty projections (0 rows)
# ---------------------------------------------------------------------------
test_that("EC-9: zero-row projections returns 0-row data frame with correct column names", {
  projections <- data.frame(
    HR = integer(0),
    IP = integer(0),
    AB = integer(0)
  )
  denominators <- fake_denominators(
    cats   = c("HR", "SB"),
    values = c(HR = 12.0, SB = 5.0),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()
  lc <- fake_league_config()

  result <- suppressMessages(
    suppressWarnings(
      sgp(projections, denominators, league_history = lh, league_config = lc)
    )
  )

  expect_equal(nrow(result), 0L)
  expect_true("sgp_HR"    %in% names(result))
  expect_true("sgp_SB"    %in% names(result))
  expect_true("total_sgp" %in% names(result))
})

# ---------------------------------------------------------------------------
# EC-10: pool_size_p larger than available pitchers
# ---------------------------------------------------------------------------
test_that("EC-10: pool_size_p exceeding available pitchers uses all pitchers without error", {
  set.seed(101L)
  n_pitchers <- 50L
  projections <- data.frame(
    ERA  = round(runif(n_pitchers, 2.5, 5.5), 2),
    WHIP = round(runif(n_pitchers, 1.0, 1.5), 2),
    IP   = sample(50:220, n_pitchers, replace = TRUE),
    AB   = rep(0L, n_pitchers),
    HR   = rep(0L, n_pitchers)
  )
  denominators <- fake_denominators(
    cats   = c("HR", "ERA"),
    values = c(HR = 12.0, ERA = 0.25),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()

  # 20 teams × 10 pitcher slots = pool_size_p of 200, but only 50 players
  lc <- league_config(
    n_teams       = 20L,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L, SS = 1L),
    pitcher_slots = 10L,
    categories    = c("HR", "ERA")
  )

  expect_no_error(
    result <- suppressMessages(
      sgp(projections, denominators, league_history = lh, league_config = lc)
    )
  )
  expect_equal(nrow(result), n_pitchers)
})

# ---------------------------------------------------------------------------
# EC-11: Validation order — EC-2 fires before EC-3
# ---------------------------------------------------------------------------
test_that("EC-11: blended_pool + fixed_baseline denom fires rotostats_error_invalid_rate_conversion", {
  projections     <- data.frame(HR = 30L, IP = 0L, AB = 0L)
  denominators_fb <- fake_denominators("HR", c(HR = 12.0), "fixed_baseline")

  err <- tryCatch(
    sgp(projections, denominators_fb, rate_conversion = "blended_pool"),
    error = function(e) e
  )
  expect_true(inherits(err, "rotostats_error_invalid_rate_conversion"),
              label = "blended_pool + fixed_baseline denom → rotostats_error_invalid_rate_conversion")
  expect_false(inherits(err, "rotostats_error_not_implemented"),
               label = "Should NOT raise rotostats_error_not_implemented here")
})

test_that("EC-11: per_player + fixed_baseline denom fires rotostats_error_not_implemented", {
  projections     <- data.frame(HR = 30L, IP = 0L, AB = 0L)
  denominators_fb <- fake_denominators("HR", c(HR = 12.0), "fixed_baseline")

  err <- tryCatch(
    sgp(projections, denominators_fb, rate_conversion = "per_player"),
    error = function(e) e
  )
  expect_true(inherits(err, "rotostats_error_not_implemented"),
              label = "per_player → rotostats_error_not_implemented")
})

# ---------------------------------------------------------------------------
# INV-1: Counting-stat linearity
# ---------------------------------------------------------------------------
test_that("INV-1: counting SGP is linear in projections (scale invariance)", {
  set.seed(999L)
  n <- 20L
  projections <- data.frame(
    HR  = sample(5:45, n, replace = TRUE),
    RBI = sample(40:110, n, replace = TRUE),
    IP  = rep(0L, n),
    AB  = rep(0L, n)
  )
  denominators <- fake_denominators(
    cats   = c("HR", "RBI"),
    values = c(HR = 12.0, RBI = 15.0),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()
  lc <- fake_league_config()
  k  <- 2.5

  result_1 <- suppressMessages(
    sgp(projections, denominators, league_history = lh, league_config = lc)
  )
  proj_scaled <- projections
  proj_scaled$HR  <- k * projections$HR
  proj_scaled$RBI <- k * projections$RBI
  result_k <- suppressMessages(
    sgp(proj_scaled, denominators, league_history = lh, league_config = lc)
  )

  expect_equal(result_k$sgp_HR,  k * result_1$sgp_HR,  tolerance = 1e-12)
  expect_equal(result_k$sgp_RBI, k * result_1$sgp_RBI, tolerance = 1e-12)
})

# ---------------------------------------------------------------------------
# INV-2: Zero counting stats → zero counting SGP
# ---------------------------------------------------------------------------
test_that("INV-2: all-zero counting projections produce zero counting SGP", {
  projections <- data.frame(
    HR = c(0L, 0L, 0L),
    SB = c(0L, 0L, 0L),
    IP = rep(0L, 3),
    AB = rep(0L, 3)
  )
  denominators <- fake_denominators(
    cats   = c("HR", "SB"),
    values = c(HR = 12.0, SB = 5.0),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()
  lc <- fake_league_config()

  result <- suppressMessages(
    sgp(projections, denominators, league_history = lh, league_config = lc)
  )

  expect_equal(result$sgp_HR, rep(0.0, 3), tolerance = 1e-12)
  expect_equal(result$sgp_SB, rep(0.0, 3), tolerance = 1e-12)
})

# ---------------------------------------------------------------------------
# INV-3: Additive total — rowSums of sgp_ columns equals total_sgp
# ---------------------------------------------------------------------------
test_that("INV-3: total_sgp equals rowSums of sgp_ columns within 1e-12", {
  set.seed(42L)
  n <- 15L
  projections <- data.frame(
    HR  = sample(5:45,   n, replace = TRUE),
    R   = sample(40:100, n, replace = TRUE),
    RBI = sample(40:110, n, replace = TRUE),
    SB  = sample(0:40,   n, replace = TRUE),
    IP  = rep(0L, n),
    AB  = rep(0L, n)
  )
  denominators <- fake_denominators(
    cats   = c("HR", "R", "RBI", "SB"),
    values = c(HR = 12.0, R = 18.0, RBI = 15.0, SB = 5.0),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()
  lc <- fake_league_config()

  result <- suppressMessages(
    sgp(projections, denominators, league_history = lh, league_config = lc)
  )

  sgp_cols  <- grep("^sgp_", names(result), value = TRUE)
  row_total <- unname(rowSums(result[, sgp_cols, drop = FALSE], na.rm = FALSE))
  expect_equal(result$total_sgp, row_total, tolerance = 1e-12)
})

# ---------------------------------------------------------------------------
# INV-4: Column count — one sgp_ per category plus total_sgp
# ---------------------------------------------------------------------------
test_that("INV-4: result has exactly length(denominators) + 1 columns", {
  projections  <- data.frame(HR = 30L, SB = 10L, R = 80L, IP = 0L, AB = 0L)
  cats         <- c("HR", "SB", "R")
  denominators <- fake_denominators(
    cats   = cats,
    values = c(HR = 12.0, SB = 5.0, R = 18.0),
    rate_conversion = "blended_pool"
  )
  lh <- fake_league_history()
  lc <- fake_league_config()

  result <- suppressMessages(
    sgp(projections, denominators, league_history = lh, league_config = lc)
  )

  expect_equal(ncol(result), length(cats) + 1L)
})

# ---------------------------------------------------------------------------
# INV-5: Row count preservation
# ---------------------------------------------------------------------------
test_that("INV-5: nrow(result) equals nrow(projections)", {
  set.seed(77L)
  n <- 25L
  projections <- data.frame(
    HR = sample(5:45, n, replace = TRUE),
    IP = rep(0L, n),
    AB = rep(0L, n)
  )
  denominators <- fake_denominators("HR", c(HR = 12.0), "blended_pool")
  lh <- fake_league_history()
  lc <- fake_league_config()

  result <- suppressMessages(
    sgp(projections, denominators, league_history = lh, league_config = lc)
  )

  expect_equal(nrow(result), n)
})

# ---------------------------------------------------------------------------
# INV-6: ERA/WHIP/AVG zero deviation when player equals baseline
# ---------------------------------------------------------------------------
test_that("INV-6: player ERA exactly equal to avg_ERA produces sgp_ERA near 0", {
  # Large pool (100 pitchers all at ERA=3.80) so blended ERA ≈ pool ERA ≈ avg_ERA
  set.seed(12345L)
  n_pool <- 100L
  pool_ip  <- rep(180, n_pool)
  pool_era <- rep(3.80, n_pool)

  # Evaluated player: ERA = 3.80, IP = 60
  # blended_ERA = (pool_ER + player_ER) * 9 / (pool_IP + player_IP) ≈ 3.80
  # avg_ERA = 3.80 → sgp_ERA ≈ 0

  projections <- data.frame(
    ERA = c(pool_era, 3.80),
    IP  = c(pool_ip, 60),
    AB  = rep(0L, n_pool + 1L),
    HR  = rep(0L, n_pool + 1L)
  )

  lh <- list(team_season = data.frame(
    YEAR    = c(2023L, 2023L),
    TEAM_ID = c("T1", "T2"),
    ERA     = c(3.80, 3.80),
    WHIP    = c(1.25, 1.25),
    AVG     = c(0.258, 0.258),
    IP      = c(1380L, 1380L),
    AB      = c(5400L, 5400L),
    stringsAsFactors = FALSE
  ))

  denominators <- fake_denominators(
    cats   = c("HR", "ERA"),
    values = c(HR = 12.0, ERA = 0.25),
    rate_conversion = "blended_pool"
  )

  # pool_size_p = 5 * 20 = 100
  lc <- league_config(
    n_teams       = 5L,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L, SS = 1L),
    pitcher_slots = 20L,
    categories    = c("HR", "ERA")
  )

  result <- suppressMessages(
    sgp(projections, denominators, league_history = lh, league_config = lc)
  )

  expect_equal(result$sgp_ERA[n_pool + 1L], 0.0, tolerance = 1e-3)
})

# ---------------------------------------------------------------------------
# INV-7: Pool size scaling — more teams → larger pool → different SGP values
# ---------------------------------------------------------------------------
test_that("INV-7: changing n_teams changes pool size and rate-stat SGP values", {
  set.seed(555L)
  n_players <- 300L
  projections <- data.frame(
    ERA  = round(runif(n_players, 2.5, 5.5), 2),
    WHIP = round(runif(n_players, 1.0, 1.5), 2),
    IP   = round(runif(n_players, 10, 220)),
    AB   = rep(0L, n_players),
    HR   = rep(0L, n_players)
  )

  lh <- fake_league_history()
  denominators <- fake_denominators(
    cats   = c("HR", "ERA"),
    values = c(HR = 12.0, ERA = 0.25),
    rate_conversion = "blended_pool"
  )

  lc_10 <- league_config(
    n_teams       = 10L,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L, SS = 1L),
    pitcher_slots = 9L,
    categories    = c("HR", "ERA")
  )

  lc_15 <- league_config(
    n_teams       = 15L,
    roster_slots  = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L, SS = 1L),
    pitcher_slots = 9L,
    categories    = c("HR", "ERA")
  )

  result_10 <- suppressMessages(
    sgp(projections, denominators, league_history = lh, league_config = lc_10)
  )
  result_15 <- suppressMessages(
    sgp(projections, denominators, league_history = lh, league_config = lc_15)
  )

  expect_false(
    isTRUE(all.equal(result_10$sgp_ERA, result_15$sgp_ERA)),
    label = "ERA SGP should differ between 10-team and 15-team pool sizes"
  )
})
