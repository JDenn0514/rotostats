# Builder-level unit tests for sgp()
# These tests are derived from spec.md and verify the implementation matches
# the spec. They are complementary to tester's independent validation.

# ---------------------------------------------------------------------------
# Helpers: minimal fixture constructors
# ---------------------------------------------------------------------------

# Build a minimal sgp_denominators object for the given categories and method
make_denominators <- function(cats, values = NULL, rate_conversion = "blended_pool") {
  if (is.null(values)) {
    values <- stats::setNames(seq_along(cats) * 10.0, cats)
  }
  rotostats:::new_sgp_denominators(
    denominators     = values,
    year_diagnostics = data.frame(),
    bootstrap_ci     = NULL,
    call             = quote(sgp_denominators()),
    meta             = list(
      rate_conversion = rate_conversion,
      method          = "ols",
      years_used      = 2022L,
      exclude_years   = 2020L,
      package_version = "0.0.0.9000"
    ),
    rate_conversion  = rate_conversion
  )
}

# Build a minimal league_history object for the given baseline year
# team_season must have ERA, WHIP, AVG, IP, AB columns for rate-stat baseline
make_league_history <- function(
  year       = 2023L,
  era_vals   = c(3.5, 4.0, 4.5, 3.8),
  whip_vals  = c(1.20, 1.30, 1.15, 1.25),
  avg_vals   = c(0.255, 0.265, 0.270, 0.260),
  ip_vals    = c(1400, 1350, 1380, 1420),
  ab_vals    = c(5500, 5400, 5600, 5450)
) {
  n <- length(era_vals)
  data.frame(
    team_season = I(list(
      data.frame(
        YEAR    = rep(year, n),
        TEAM_ID = paste0("T", seq_len(n)),
        ERA     = era_vals,
        WHIP    = whip_vals,
        AVG     = avg_vals,
        IP      = ip_vals,
        AB      = ab_vals,
        stringsAsFactors = FALSE
      )
    ))
  )
  list(
    team_season = data.frame(
      YEAR    = rep(year, n),
      TEAM_ID = paste0("T", seq_len(n)),
      ERA     = era_vals,
      WHIP    = whip_vals,
      AVG     = avg_vals,
      IP      = ip_vals,
      AB      = ab_vals,
      stringsAsFactors = FALSE
    )
  )
}

# Build a minimal league_config object
make_league_config <- function(n_teams = 12L) {
  league_config(
    n_teams      = n_teams,
    roster_slots = c(C = 1L, "1B" = 1L, "2B" = 1L, "3B" = 1L,
                     SS = 1L, OF = 5L, UTIL = 1L),
    pitcher_slots = c(SP = 6L, RP = 3L),
    categories    = c("HR", "R", "RBI", "SB", "AVG", "ERA", "WHIP")
  )
}

# Build a minimal projections data frame
make_projections <- function(
  n         = 10L,
  with_era  = TRUE,
  with_avg  = TRUE,
  cats      = c("HR", "R", "RBI", "SB")
) {
  set.seed(42L)
  df <- data.frame(
    HR  = sample(5:45, n, replace = TRUE),
    R   = sample(40:100, n, replace = TRUE),
    RBI = sample(40:110, n, replace = TRUE),
    SB  = sample(0:40, n, replace = TRUE),
    stringsAsFactors = FALSE
  )
  # Keep only requested counting cats
  df <- df[, intersect(cats, names(df)), drop = FALSE]
  if (with_era) {
    df$ERA  <- round(runif(n, 2.5, 5.5), 2)
    df$WHIP <- round(runif(n, 1.0, 1.5), 2)
    df$IP   <- c(200, 185, 175, 30, 60, 50, 45, 20, 15, 10)[seq_len(n)]
  }
  if (with_avg) {
    df$AVG <- round(runif(n, 0.230, 0.300), 3)
    df$AB  <- c(550, 500, 520, 480, 300, 200, 150, 100, 50, 30)[seq_len(n)]
  }
  df
}

# ---------------------------------------------------------------------------
# Section 1: Return structure
# ---------------------------------------------------------------------------

test_that("sgp() returns a data frame with correct column names", {
  cats    <- c("HR", "R", "RBI", "SB")
  denoms  <- make_denominators(cats, values = c(HR = 12.0, R = 15.0, RBI = 14.0, SB = 8.0))
  lh      <- make_league_history()
  lc      <- make_league_config()
  proj    <- make_projections(n = 5L, with_era = FALSE, with_avg = FALSE, cats = cats)

  # Counting-only case: no rate stats, so league_history/league_config not used
  # We still supply them to satisfy the blended_pool path validation
  result  <- sgp(proj, denoms, league_history = lh, league_config = lc)

  expect_s3_class(result, "data.frame")
  expect_named(result, c("sgp_HR", "sgp_R", "sgp_RBI", "sgp_SB", "total_sgp"))
  expect_equal(nrow(result), 5L)
})

test_that("sgp() output column order matches names(denominators)", {
  cats   <- c("SB", "HR", "R")   # non-alphabetical order
  denoms <- make_denominators(cats, values = c(SB = 8.0, HR = 12.0, R = 15.0))
  lh     <- make_league_history()
  lc     <- make_league_config()
  proj   <- data.frame(SB = 10, HR = 25, R = 75)

  result <- sgp(proj, denoms, league_history = lh, league_config = lc)

  expect_equal(names(result), c("sgp_SB", "sgp_HR", "sgp_R", "total_sgp"))
})

# ---------------------------------------------------------------------------
# Section 2: Counting-stat correctness (AC-1)
# ---------------------------------------------------------------------------

test_that("counting-stat SGP equals projected / denominator (exact)", {
  set.seed(1L)
  n      <- 20L
  cats   <- c("HR", "R", "RBI", "SB", "K", "W")
  dvals  <- c(HR = 12.0, R = 15.0, RBI = 13.5, SB = 8.0, K = 22.0, W = 2.5)
  denoms <- make_denominators(cats, values = dvals)
  lh     <- make_league_history()
  lc     <- make_league_config()

  proj <- data.frame(
    HR  = sample(5:50, n, replace = TRUE),
    R   = sample(40:110, n, replace = TRUE),
    RBI = sample(35:120, n, replace = TRUE),
    SB  = sample(0:50, n, replace = TRUE),
    K   = sample(100:250, n, replace = TRUE),
    W   = sample(5:20, n, replace = TRUE)
  )

  result <- sgp(proj, denoms, league_history = lh, league_config = lc)

  for (cat in cats) {
    expected <- proj[[cat]] / dvals[[cat]]
    col      <- paste0("sgp_", cat)
    expect_equal(result[[col]], expected,
                 tolerance = 1e-12,
                 label = paste("sgp", cat, "equals projected / denom"))
  }
})

test_that("total_sgp equals rowSums of sgp_ columns for counting stats", {
  cats   <- c("HR", "R")
  denoms <- make_denominators(cats, values = c(HR = 12.0, R = 15.0))
  lh     <- make_league_history()
  lc     <- make_league_config()
  proj   <- data.frame(HR = c(20, 30, 40), R = c(70, 80, 90))

  result <- sgp(proj, denoms, league_history = lh, league_config = lc)

  manual_total <- result$sgp_HR + result$sgp_R
  expect_equal(result$total_sgp, manual_total, tolerance = 1e-12)
})

# ---------------------------------------------------------------------------
# Section 3: Rate-stat sign convention (AC-2)
# ---------------------------------------------------------------------------

test_that("ERA SGP is positive when player ERA is below pool average", {
  # Low ERA pitcher should contribute positively (lowers team ERA)
  cats   <- c("ERA")
  denoms <- make_denominators(cats, values = c(ERA = 0.3))
  lh     <- make_league_history(era_vals  = c(4.0, 4.2, 3.8, 4.1),
                                 whip_vals = c(1.25, 1.30, 1.20, 1.28),
                                 avg_vals  = c(0.260, 0.265, 0.255, 0.268),
                                 ip_vals   = c(1400, 1350, 1380, 1420),
                                 ab_vals   = c(5500, 5400, 5600, 5450))
  lc     <- make_league_config()

  # avg_ERA ≈ 4.02 (IP-weighted). Pool ERA ≈ similar. A pitcher with ERA = 2.0
  # brings the blended ERA well below avg_ERA, so sgp_ERA > 0.
  proj <- data.frame(
    ERA  = c(2.0),   # excellent pitcher
    WHIP = c(1.00),
    IP   = c(200)
  )

  result <- sgp(proj, denoms, league_history = lh, league_config = lc)
  expect_gt(result$sgp_ERA[1L], 0,
            label = "elite pitcher ERA SGP should be positive")
})

test_that("ERA SGP is negative when player ERA is above pool average", {
  cats   <- c("ERA")
  denoms <- make_denominators(cats, values = c(ERA = 0.3))
  lh     <- make_league_history(era_vals  = c(3.5, 3.6, 3.7, 3.4),
                                 whip_vals = c(1.20, 1.22, 1.18, 1.21),
                                 avg_vals  = c(0.260, 0.265, 0.255, 0.268),
                                 ip_vals   = c(1400, 1350, 1380, 1420),
                                 ab_vals   = c(5500, 5400, 5600, 5450))
  lc     <- make_league_config()

  # avg_ERA ≈ 3.55 (IP-weighted). A pitcher with ERA = 6.0 drags blended ERA
  # above avg, so sgp_ERA < 0.
  proj <- data.frame(
    ERA  = c(6.0),  # poor pitcher
    WHIP = c(1.70),
    IP   = c(50)
  )

  result <- sgp(proj, denoms, league_history = lh, league_config = lc)
  expect_lt(result$sgp_ERA[1L], 0,
            label = "poor pitcher ERA SGP should be negative")
})

test_that("AVG SGP is positive when player AVG is above baseline (sign flip)", {
  cats   <- c("AVG")
  denoms <- make_denominators(cats, values = c(AVG = 0.003))
  lh     <- make_league_history(era_vals  = c(4.0, 4.2, 3.8, 4.1),
                                 whip_vals = c(1.25, 1.30, 1.20, 1.28),
                                 avg_vals  = c(0.255, 0.260, 0.258, 0.262),
                                 ip_vals   = c(1400, 1350, 1380, 1420),
                                 ab_vals   = c(5500, 5400, 5600, 5450))
  lc     <- make_league_config()

  # avg_AVG ≈ 0.259. A hitter with AVG = 0.320 and many ABs raises blended AVG
  # above avg_AVG, so sgp_AVG > 0.
  proj <- data.frame(
    AVG = c(0.320),
    AB  = c(550)
  )

  result <- sgp(proj, denoms, league_history = lh, league_config = lc)
  expect_gt(result$sgp_AVG[1L], 0,
            label = "elite hitter AVG SGP should be positive")
})

test_that("AVG SGP is negative when player AVG is below baseline", {
  cats   <- c("AVG")
  denoms <- make_denominators(cats, values = c(AVG = 0.003))
  lh     <- make_league_history(era_vals  = c(4.0, 4.2, 3.8, 4.1),
                                 whip_vals = c(1.25, 1.30, 1.20, 1.28),
                                 avg_vals  = c(0.270, 0.275, 0.268, 0.272),
                                 ip_vals   = c(1400, 1350, 1380, 1420),
                                 ab_vals   = c(5500, 5400, 5600, 5450))
  lc     <- make_league_config()

  # avg_AVG ≈ 0.271. Hitter with AVG = 0.200 and many ABs drags down blended
  # AVG below avg_AVG, so sgp_AVG < 0.
  proj <- data.frame(
    AVG = c(0.200),
    AB  = c(550)
  )

  result <- sgp(proj, denoms, league_history = lh, league_config = lc)
  expect_lt(result$sgp_AVG[1L], 0,
            label = "poor hitter AVG SGP should be negative")
})

# ---------------------------------------------------------------------------
# Section 4: total_sgp additivity and NA propagation (AC-1, AC-3)
# ---------------------------------------------------------------------------

test_that("total_sgp is NA when any sgp_ column is NA (na.rm = FALSE)", {
  cats    <- c("HR", "R")
  denoms  <- make_denominators(cats, values = c(HR = 12.0, R = 15.0))
  lh      <- make_league_history()
  lc      <- make_league_config()

  # Projections missing R column → sgp_R = NA → total_sgp = NA
  proj    <- data.frame(HR = c(20, 30))

  result  <- suppressWarnings(
    sgp(proj, denoms, league_history = lh, league_config = lc)
  )

  expect_true(all(is.na(result$sgp_R)))
  expect_true(all(is.na(result$total_sgp)))
})

test_that("total_sgp is invariant to column permutation of projections", {
  cats   <- c("HR", "R", "RBI")
  dvals  <- c(HR = 12.0, R = 15.0, RBI = 13.5)
  denoms <- make_denominators(cats, values = dvals)
  lh     <- make_league_history()
  lc     <- make_league_config()

  proj_abc <- data.frame(HR = c(20, 30), R = c(75, 85), RBI = c(60, 80))
  proj_cba <- proj_abc[, c("RBI", "R", "HR")]  # permuted columns

  r1 <- sgp(proj_abc, denoms, league_history = lh, league_config = lc)
  r2 <- sgp(proj_cba, denoms, league_history = lh, league_config = lc)

  expect_equal(r1$total_sgp, r2$total_sgp, tolerance = 1e-12,
               label = "total_sgp invariant to column permutation")
})

# ---------------------------------------------------------------------------
# Section 5: Input validation order (spec.md §5)
# ---------------------------------------------------------------------------

test_that("unrecognized rate_conversion aborts with rotostats_error_invalid_rate_conversion", {
  cats   <- c("HR")
  denoms <- make_denominators(cats)
  proj   <- data.frame(HR = 20L)

  expect_error(
    sgp(proj, denoms, rate_conversion = "garbage"),
    class = "rotostats_error_invalid_rate_conversion"
  )
})

test_that("denominator/rate_conversion mismatch aborts with rotostats_error_invalid_rate_conversion", {
  cats   <- c("HR")
  # Denominators calibrated as fixed_baseline, but caller requests blended_pool
  denoms <- make_denominators(cats, rate_conversion = "fixed_baseline")
  proj   <- data.frame(HR = 20L)
  lh     <- make_league_history()
  lc     <- make_league_config()

  expect_error(
    sgp(proj, denoms,
        rate_conversion = "blended_pool",
        league_history  = lh,
        league_config   = lc),
    class = "rotostats_error_invalid_rate_conversion"
  )
})

test_that("per_player rate_conversion aborts with rotostats_error_not_implemented", {
  cats   <- c("HR")
  denoms <- make_denominators(cats)
  proj   <- data.frame(HR = 20L)

  expect_error(
    sgp(proj, denoms, rate_conversion = "per_player"),
    class = "rotostats_error_not_implemented"
  )
})

test_that("universal_constants rate_conversion aborts with rotostats_error_not_implemented", {
  cats   <- c("HR")
  denoms <- make_denominators(cats)
  proj   <- data.frame(HR = 20L)

  expect_error(
    sgp(proj, denoms, rate_conversion = "universal_constants"),
    class = "rotostats_error_not_implemented"
  )
})

test_that("team_ip_normalized rate_conversion aborts with rotostats_error_not_implemented", {
  cats   <- c("HR")
  denoms <- make_denominators(cats)
  proj   <- data.frame(HR = 20L)

  expect_error(
    sgp(proj, denoms, rate_conversion = "team_ip_normalized"),
    class = "rotostats_error_not_implemented"
  )
})

test_that("fixed_baseline delegates to convert_rate_stats (aborts rotostats_error_not_implemented)", {
  cats   <- c("HR")
  denoms <- make_denominators(cats, rate_conversion = "fixed_baseline")
  proj   <- data.frame(HR = 20L)
  lh     <- make_league_history()

  expect_error(
    sgp(proj, denoms,
        rate_conversion = "fixed_baseline",
        league_history  = lh),
    class = "rotostats_error_not_implemented"
  )
})

test_that("validation order: invalid rate_conversion fires before not-implemented check", {
  # "garbage" should fire rotostats_error_invalid_rate_conversion, not not_implemented
  cats   <- c("HR")
  denoms <- make_denominators(cats)
  proj   <- data.frame(HR = 20L)

  err <- tryCatch(
    sgp(proj, denoms, rate_conversion = "garbage"),
    error = function(e) e
  )
  expect_true(inherits(err, "rotostats_error_invalid_rate_conversion"))
})

test_that("missing league_history aborts with rotostats_error_missing_config_field", {
  cats   <- c("ERA")
  denoms <- make_denominators(cats, values = c(ERA = 0.3))
  proj   <- data.frame(ERA = 3.5, WHIP = 1.2, IP = 200)
  lc     <- make_league_config()

  expect_error(
    sgp(proj, denoms,
        rate_conversion = "blended_pool",
        league_history  = NULL,
        league_config   = lc),
    class = "rotostats_error_missing_config_field"
  )
})

test_that("missing league_config aborts with rotostats_error_missing_config_field", {
  cats   <- c("ERA")
  denoms <- make_denominators(cats, values = c(ERA = 0.3))
  proj   <- data.frame(ERA = 3.5, WHIP = 1.2, IP = 200)
  lh     <- make_league_history()

  expect_error(
    sgp(proj, denoms,
        rate_conversion = "blended_pool",
        league_history  = lh,
        league_config   = NULL),
    class = "rotostats_error_missing_config_field"
  )
})

test_that("projections missing IP column (ERA scored) aborts with rotostats_error_missing_required_column", {
  cats   <- c("ERA")
  denoms <- make_denominators(cats, values = c(ERA = 0.3))
  # No IP column
  proj   <- data.frame(ERA = c(3.5, 4.0))
  lh     <- make_league_history()
  lc     <- make_league_config()

  expect_error(
    sgp(proj, denoms, league_history = lh, league_config = lc),
    class = "rotostats_error_missing_required_column"
  )
})

test_that("projections missing AB column (AVG scored) aborts with rotostats_error_missing_required_column", {
  cats   <- c("AVG")
  denoms <- make_denominators(cats, values = c(AVG = 0.003))
  # No AB column
  proj   <- data.frame(AVG = c(0.260, 0.275))
  lh     <- make_league_history()
  lc     <- make_league_config()

  expect_error(
    sgp(proj, denoms, league_history = lh, league_config = lc),
    class = "rotostats_error_missing_required_column"
  )
})

# ---------------------------------------------------------------------------
# Section 6: Warning conditions (AC-3)
# ---------------------------------------------------------------------------

test_that("missing scored category column emits rotostats_warning_missing_category_column", {
  cats   <- c("HR", "R")
  denoms <- make_denominators(cats, values = c(HR = 12.0, R = 15.0))
  lh     <- make_league_history()
  lc     <- make_league_config()
  # Projections missing R
  proj   <- data.frame(HR = c(20, 30))

  expect_warning(
    sgp(proj, denoms, league_history = lh, league_config = lc),
    class = "rotostats_warning_missing_category_column"
  )
})

test_that("zero IP player emits rotostats_warning_zero_playing_time for ERA", {
  cats   <- c("ERA")
  denoms <- make_denominators(cats, values = c(ERA = 0.3))
  lh     <- make_league_history()
  lc     <- make_league_config()
  # One player with IP = 0
  proj   <- data.frame(ERA = c(3.5, 0.0), WHIP = c(1.2, 0.0), IP = c(200, 0))

  expect_warning(
    sgp(proj, denoms, league_history = lh, league_config = lc),
    class = "rotostats_warning_zero_playing_time"
  )
})

test_that("zero IP player gets NA for sgp_ERA", {
  cats   <- c("ERA")
  denoms <- make_denominators(cats, values = c(ERA = 0.3))
  lh     <- make_league_history()
  lc     <- make_league_config()
  proj   <- data.frame(ERA = c(3.5, 4.0), WHIP = c(1.2, 1.3), IP = c(200, 0))

  result <- suppressWarnings(
    sgp(proj, denoms, league_history = lh, league_config = lc)
  )

  expect_false(is.na(result$sgp_ERA[1L]))
  expect_true(is.na(result$sgp_ERA[2L]))
})

test_that("zero AB player emits rotostats_warning_zero_playing_time and gets NA for sgp_AVG", {
  cats   <- c("AVG")
  denoms <- make_denominators(cats, values = c(AVG = 0.003))
  lh     <- make_league_history()
  lc     <- make_league_config()
  proj   <- data.frame(AVG = c(0.270, 0.250), AB = c(550, 0))

  expect_warning(
    sgp(proj, denoms, league_history = lh, league_config = lc),
    class = "rotostats_warning_zero_playing_time"
  )

  result <- suppressWarnings(
    sgp(proj, denoms, league_history = lh, league_config = lc)
  )
  expect_false(is.na(result$sgp_AVG[1L]))
  expect_true(is.na(result$sgp_AVG[2L]))
})

# ---------------------------------------------------------------------------
# Section 7: Column name normalization
# ---------------------------------------------------------------------------

test_that("sgp() normalizes lowercase projections column names silently", {
  cats   <- c("HR", "R")
  denoms <- make_denominators(cats, values = c(HR = 12.0, R = 15.0))
  lh     <- make_league_history()
  lc     <- make_league_config()
  # lowercase column names
  proj   <- data.frame(hr = c(20, 30), r = c(75, 85))

  result <- expect_no_warning(
    sgp(proj, denoms, league_history = lh, league_config = lc)
  )
  expect_named(result, c("sgp_HR", "sgp_R", "total_sgp"))
})

# ---------------------------------------------------------------------------
# Section 8: Blended-pool formula exactness
# ---------------------------------------------------------------------------

test_that("ERA SGP formula matches manual blended-pool calculation", {
  # Use a simple 1-player, known setup and verify exact formula
  cats   <- c("ERA")
  era_d  <- 0.25
  denoms <- make_denominators(cats, values = c(ERA = era_d))

  # 4 teams with known ERA/WHIP/AVG/IP/AB
  ip_teams   <- c(1400, 1400, 1400, 1400)
  era_teams  <- c(4.00, 4.00, 4.00, 4.00)  # all equal → avg_ERA = 4.00
  lh <- list(
    team_season = data.frame(
      YEAR    = rep(2023L, 4L),
      TEAM_ID = paste0("T", 1:4),
      ERA     = era_teams,
      WHIP    = rep(1.25, 4L),
      AVG     = rep(0.260, 4L),
      IP      = ip_teams,
      AB      = rep(5500L, 4L),
      stringsAsFactors = FALSE
    )
  )

  lc <- make_league_config()   # 12 teams, SP=6, RP=3 → pool_size_p = 12*9 = 108

  # Build projections: pool_size_p = 108 pitchers sorted by IP descending
  # Create 200 pitchers; top 108 will form the pool
  set.seed(123L)
  n_total   <- 200L
  ip_proj   <- c(rep(200, 10), rep(150, 98), rep(50, 92))  # top 108 will be the first 108
  era_proj  <- rep(4.00, n_total)   # everyone has ERA = 4.00

  proj <- data.frame(ERA = era_proj, WHIP = rep(1.25, n_total), IP = ip_proj)

  # avg_ERA = 4.00; every player has ERA = 4.00
  # pool_ER = sum(ERA * IP / 9) for top 108 pitchers
  # blended_era for player i = (pool_ER + player_ERA * player_IP / 9) * 9 / (pool_IP + player_IP)
  # When all ERAs are equal (4.00), blended_era = 4.00 for everyone
  # → sgp_ERA = (4.00 - 4.00) / 0.25 = 0

  result <- suppressMessages(sgp(proj, denoms, league_history = lh, league_config = lc))

  # All players should have sgp_ERA ≈ 0 when everyone has ERA = avg_ERA
  expect_equal(result$sgp_ERA, rep(0, n_total), tolerance = 1e-10)
})

test_that("AVG SGP formula matches manual blended-pool calculation", {
  cats   <- c("AVG")
  avg_d  <- 0.003
  denoms <- make_denominators(cats, values = c(AVG = avg_d))

  # 4 teams with known AVG/AB
  ab_teams  <- c(5500, 5500, 5500, 5500)
  avg_teams <- c(0.260, 0.260, 0.260, 0.260)  # all equal → avg_AVG = 0.260
  lh <- list(
    team_season = data.frame(
      YEAR    = rep(2023L, 4L),
      TEAM_ID = paste0("T", 1:4),
      ERA     = rep(4.00, 4L),
      WHIP    = rep(1.25, 4L),
      AVG     = avg_teams,
      IP      = rep(1400L, 4L),
      AB      = ab_teams,
      stringsAsFactors = FALSE
    )
  )

  lc <- make_league_config()  # pool_size_h = 12 * (1+1+1+1+1+5+1) = 12 * 11 = 132

  # All hitters with AVG = 0.260; when blended with pool of same, result = 0.260
  n_total <- 300L
  ab_proj <- c(rep(550, 132), rep(100, 168))   # top 132 by AB form the pool
  avg_proj <- rep(0.260, n_total)

  proj <- data.frame(AVG = avg_proj, AB = ab_proj)

  result <- suppressMessages(sgp(proj, denoms, league_history = lh, league_config = lc))

  # All players should have sgp_AVG ≈ 0 when everyone has AVG = avg_AVG
  expect_equal(result$sgp_AVG, rep(0, n_total), tolerance = 1e-10)
})

# ---------------------------------------------------------------------------
# Section 9: league_history$team_season validation
# ---------------------------------------------------------------------------

test_that("NULL team_season aborts with rotostats_error_missing_team_season", {
  cats   <- c("ERA")
  denoms <- make_denominators(cats, values = c(ERA = 0.3))
  proj   <- data.frame(ERA = 3.5, WHIP = 1.2, IP = 200)
  lh     <- list(team_season = NULL)
  lc     <- make_league_config()

  expect_error(
    sgp(proj, denoms, league_history = lh, league_config = lc),
    class = "rotostats_error_missing_team_season"
  )
})

test_that("team_season without IP/AB columns aborts with rotostats_error_missing_required_column", {
  cats   <- c("ERA")
  denoms <- make_denominators(cats, values = c(ERA = 0.3))
  proj   <- data.frame(ERA = 3.5, WHIP = 1.2, IP = 200)
  lh     <- list(
    team_season = data.frame(
      YEAR    = 2023L,
      TEAM_ID = "T1",
      ERA     = 4.0,
      # No IP, no AB
      stringsAsFactors = FALSE
    )
  )
  lc     <- make_league_config()

  expect_error(
    sgp(proj, denoms, league_history = lh, league_config = lc),
    class = "rotostats_error_missing_required_column"
  )
})

# ---------------------------------------------------------------------------
# Section 10: Vectorization — no row-wise loops
# ---------------------------------------------------------------------------

test_that("sgp() handles n = 1 player without error", {
  cats   <- c("HR")
  denoms <- make_denominators(cats, values = c(HR = 12.0))
  lh     <- make_league_history()
  lc     <- make_league_config()
  proj   <- data.frame(HR = 25L)

  result <- sgp(proj, denoms, league_history = lh, league_config = lc)

  expect_equal(nrow(result), 1L)
  expect_equal(result$sgp_HR, 25 / 12.0, tolerance = 1e-12)
})

test_that("sgp() handles n = 500 players without error (vectorization smoke test)", {
  set.seed(99L)
  cats   <- c("HR", "R", "RBI", "SB", "ERA", "WHIP", "AVG")
  dvals  <- c(HR = 12, R = 15, RBI = 13, SB = 8, ERA = 0.28, WHIP = 0.07, AVG = 0.003)
  denoms <- make_denominators(cats, values = dvals)
  lh     <- make_league_history()
  lc     <- make_league_config()

  n <- 500L
  proj <- data.frame(
    HR   = sample(0:50, n, replace = TRUE),
    R    = sample(20:120, n, replace = TRUE),
    RBI  = sample(20:130, n, replace = TRUE),
    SB   = sample(0:60, n, replace = TRUE),
    ERA  = round(runif(n, 1.5, 8.0), 2),
    WHIP = round(runif(n, 0.8, 2.0), 2),
    AVG  = round(runif(n, 0.180, 0.340), 3),
    IP   = c(rep(200, 150), rep(50, 150), rep(10, 200)),
    AB   = c(rep(0, 200), rep(550, 200), rep(200, 100))
  )

  result <- suppressWarnings(suppressMessages(
    sgp(proj, denoms, league_history = lh, league_config = lc)
  ))

  expect_equal(nrow(result), n)
  expect_true(all(c("sgp_HR", "sgp_ERA", "sgp_AVG", "total_sgp") %in% names(result)))
})

# ---------------------------------------------------------------------------
# Section 11: Baseline year inform message
# ---------------------------------------------------------------------------

test_that("sgp() emits cli_inform naming the baseline year", {
  cats   <- c("ERA")
  denoms <- make_denominators(cats, values = c(ERA = 0.3))
  lh     <- make_league_history(year = 2024L)
  lc     <- make_league_config()
  proj   <- data.frame(ERA = c(3.5, 4.0), WHIP = c(1.2, 1.3), IP = c(200, 150))

  msgs <- testthat::capture_messages(
    sgp(proj, denoms, league_history = lh, league_config = lc)
  )

  expect_true(any(grepl("2024", msgs)), label = "Inform message should mention year 2024")
})

# ---------------------------------------------------------------------------
# Section 12: pool_baseline validation — new tests (test-spec.md §3)
# ---------------------------------------------------------------------------

test_that("invalid pool_baseline aborts with rotostats_error_invalid_pool_baseline", {
  cats   <- c("HR")
  denoms <- make_denominators(cats, values = c(HR = 12.0))
  lh     <- make_league_history()
  lc     <- make_league_config()
  proj   <- data.frame(HR = c(20, 30))

  expect_error(
    sgp(proj, denoms, league_history = lh, league_config = lc,
        pool_baseline = "foo"),
    class = "rotostats_error_invalid_pool_baseline"
  )
})

test_that("pool_baseline = 'per_player' aborts with rotostats_error_invalid_pool_baseline", {
  cats   <- c("HR")
  denoms <- make_denominators(cats, values = c(HR = 12.0))
  lh     <- make_league_history()
  lc     <- make_league_config()
  proj   <- data.frame(HR = c(20, 30))

  expect_error(
    sgp(proj, denoms, league_history = lh, league_config = lc,
        pool_baseline = "per_player"),
    class = "rotostats_error_invalid_pool_baseline"
  )
})

test_that("pool_baseline = 'universal_constants' aborts with rotostats_error_invalid_pool_baseline", {
  cats   <- c("HR")
  denoms <- make_denominators(cats, values = c(HR = 12.0))
  lh     <- make_league_history()
  lc     <- make_league_config()
  proj   <- data.frame(HR = c(20, 30))

  expect_error(
    sgp(proj, denoms, league_history = lh, league_config = lc,
        pool_baseline = "universal_constants"),
    class = "rotostats_error_invalid_pool_baseline"
  )
})

test_that("missing category column fires rotostats_warning_missing_category_column not zero_playing_time", {
  cats   <- c("HR", "R")
  denoms <- make_denominators(cats, values = c(HR = 12.0, R = 15.0))
  lh     <- make_league_history()
  lc     <- make_league_config()
  # Projections missing R — condition (a): column absent
  proj   <- data.frame(HR = c(20, 30))

  # Must fire missing_category_column
  expect_warning(
    sgp(proj, denoms, league_history = lh, league_config = lc),
    class = "rotostats_warning_missing_category_column"
  )

  # Must NOT fire zero_playing_time
  w <- tryCatch(
    withCallingHandlers(
      sgp(proj, denoms, league_history = lh, league_config = lc),
      warning = function(cond) {
        if (inherits(cond, "rotostats_warning_zero_playing_time")) {
          stop("rotostats_warning_zero_playing_time should NOT fire for missing column")
        }
        invokeRestart("muffleWarning")
      }
    ),
    error = function(e) fail(conditionMessage(e))
  )
  # If we reach here without failure, zero_playing_time did not fire — test passes
  expect_true(TRUE)
})

test_that("zero IP fires rotostats_warning_zero_playing_time not missing_category_column", {
  cats   <- c("ERA")
  denoms <- make_denominators(cats, values = c(ERA = 0.3))
  lh     <- make_league_history()
  lc     <- make_league_config()
  # ERA column IS present — condition (b): playing time missing
  proj   <- data.frame(ERA = c(3.5, 0.0), WHIP = c(1.2, 0.0), IP = c(200, 0))

  # Must fire zero_playing_time
  expect_warning(
    sgp(proj, denoms, league_history = lh, league_config = lc),
    class = "rotostats_warning_zero_playing_time"
  )

  # Must NOT fire missing_category_column
  w <- tryCatch(
    withCallingHandlers(
      sgp(proj, denoms, league_history = lh, league_config = lc),
      warning = function(cond) {
        if (inherits(cond, "rotostats_warning_missing_category_column")) {
          stop("rotostats_warning_missing_category_column should NOT fire for zero IP")
        }
        invokeRestart("muffleWarning")
      }
    ),
    error = function(e) fail(conditionMessage(e))
  )
  expect_true(TRUE)
})

# ---------------------------------------------------------------------------
# Section 13: pool_baseline validation order (test-spec.md §6 invariant)
# invalid pool_baseline fires BEFORE rate_conversion is checked
# ---------------------------------------------------------------------------

test_that("invalid pool_baseline fires before rate_conversion check", {
  cats   <- c("HR")
  denoms <- make_denominators(cats, values = c(HR = 12.0))
  proj   <- data.frame(HR = c(20, 30))

  err <- tryCatch(
    sgp(proj, denoms, pool_baseline = "foo", rate_conversion = "invalid_value"),
    error = function(e) e
  )
  expect_true(inherits(err, "rotostats_error_invalid_pool_baseline"),
              label = "pool_baseline check should fire before rate_conversion check")
  expect_false(inherits(err, "rotostats_error_invalid_rate_conversion"),
               label = "Should NOT raise rotostats_error_invalid_rate_conversion here")
})
