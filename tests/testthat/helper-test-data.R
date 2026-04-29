# tests/testthat/helper-test-data.R
#
# Shared test infrastructure loaded automatically by testthat.
# Provides:
#   - make_rotostats_data()     — synthetic data generator (original)
#   - test_invariants()         — invariant checker (original)
#   - make_projections_data()   — projections generator for replacement_level() tests

#' @keywords internal
make_rotostats_data <- function(n = 100L, seed = 42L) {
  set.seed(seed)
  data.frame(
    player = paste0("Player", seq_len(n)),
    stat   = rnorm(n),
    value  = runif(n, 1, 40)
  )
}

#' @keywords internal
test_invariants <- function(obj) {
  expect_true(!is.null(obj))
}

# ---------------------------------------------------------------------------
# make_projections_data()
# Synthetic projections data for replacement_level() tests.
#
# Defaults produce enough players for a standard 12-team 5x5 league:
#   - n_batters = 120:  at least 15 per hitter position (C, 1B, 2B, 3B, SS)
#                       plus 45 OF = 90 base; excess becomes OF.
#   - n_sp      = 80:   satisfies 12-team × 6 SP slots = 72 needed
#   - n_rp      = 40:   satisfies 12-team × 3 RP slots = 36 needed
#
# Override n_sp and n_rp when testing smaller league configurations.
# ---------------------------------------------------------------------------

#' @keywords internal
make_projections_data <- function(n_batters = 120L, n_sp = 80L, n_rp = 40L,
                                   seed = 42L) {
  set.seed(seed)

  # Guarantee at least 15 players per primary hitter position
  pos_min <- 15L
  batter_positions_base <- c(
    rep("C",  pos_min),
    rep("1B", pos_min),
    rep("2B", pos_min),
    rep("3B", pos_min),
    rep("SS", pos_min),
    rep("OF", pos_min * 3L)   # 45 OF base
  )
  # Pad with OF to reach n_batters
  n_base <- length(batter_positions_base)
  if (n_base < n_batters) {
    batter_positions_base <- c(batter_positions_base,
                                rep("OF", n_batters - n_base))
  }
  n_batters_actual <- length(batter_positions_base)

  # ~15% multi-eligible
  n_multi   <- max(0L, round(n_batters_actual * 0.15))
  multi_idx <- sample(seq_len(n_batters_actual), n_multi, replace = FALSE)
  multi_alt <- sample(c("1B", "3B", "2B", "SS"), n_multi, replace = TRUE)
  for (k in seq_len(n_multi)) {
    orig <- batter_positions_base[multi_idx[k]]
    batter_positions_base[multi_idx[k]] <- paste(orig, multi_alt[k], sep = "|")
  }
  batter_positions <- batter_positions_base

  n        <- n_batters_actual + n_sp + n_rp
  player_id   <- paste0("P", seq_len(n))
  player_name <- paste0("Player_", seq_len(n))
  team_pool   <- c("NYY", "BOS", "LAD", "CHC", "HOU", "ATL", "STL", "SF",
                   "NYM", "MIN", "SEA", "SD")
  teams       <- sample(team_pool, n, replace = TRUE)
  leagues     <- ifelse(teams %in% c("NYY", "BOS", "HOU", "MIN", "SEA"),
                        "AL", "NL")

  pos_elig <- c(batter_positions, rep("SP", n_sp), rep("RP", n_rp))

  # Hitter stats
  HR  <- c(round(pmax(0, rnorm(n_batters_actual, 18, 10))),
           rep(NA_real_, n_sp + n_rp))
  R   <- c(round(pmax(0, rnorm(n_batters_actual, 70, 20))),
           rep(NA_real_, n_sp + n_rp))
  RBI <- c(round(pmax(0, rnorm(n_batters_actual, 72, 22))),
           rep(NA_real_, n_sp + n_rp))
  SB  <- c(round(pmax(0, rnorm(n_batters_actual, 10, 8))),
           rep(NA_real_, n_sp + n_rp))
  AB  <- c(round(pmax(200, rnorm(n_batters_actual, 440, 60))),
           rep(NA_real_, n_sp + n_rp))
  AVG <- c(round(pmax(0.150, pmin(0.380, rnorm(n_batters_actual, 0.265, 0.025))),
                 3),
           rep(NA_real_, n_sp + n_rp))

  # Pitcher stats
  ip_sp  <- round(pmax(140, rnorm(n_sp, 170, 15)), 1)
  ip_rp  <- round(pmax(40,  rnorm(n_rp,  60, 10)), 1)
  W   <- c(rep(NA_real_, n_batters_actual),
           round(pmax(0, rnorm(n_sp, 12, 4))),
           rep(NA_real_, n_rp))
  K   <- c(rep(NA_real_, n_batters_actual),
           round(pmax(20, rnorm(n_sp, 165, 35))),
           round(pmax(10, rnorm(n_rp,  60, 20))))
  SV  <- c(rep(NA_real_, n_batters_actual),
           rep(NA_real_, n_sp),
           round(pmax(0, rnorm(n_rp, 8, 10))))
  ERA <- c(rep(NA_real_, n_batters_actual),
           round(pmax(2.0, pmin(7.5, rnorm(n_sp, 3.90, 0.80))), 2),
           round(pmax(2.0, pmin(7.5, rnorm(n_rp, 3.80, 1.00))), 2))
  WHIP <- c(rep(NA_real_, n_batters_actual),
            round(pmax(0.90, pmin(2.00, rnorm(n_sp, 1.25, 0.15))), 3),
            round(pmax(0.90, pmin(2.00, rnorm(n_rp, 1.25, 0.20))), 3))
  IP   <- c(rep(NA_real_, n_batters_actual), ip_sp, ip_rp)
  role <- c(rep(NA_character_, n_batters_actual),
            rep("SP", n_sp), rep("RP", n_rp))

  data.frame(
    player_id       = player_id,
    player_name     = player_name,
    pos_eligibility = pos_elig,
    team            = teams,
    league          = leagues,
    HR              = HR,
    R               = R,
    RBI             = RBI,
    SB              = SB,
    AVG             = AVG,
    AB              = AB,
    W               = W,
    K               = K,
    SV              = SV,
    ERA             = ERA,
    WHIP            = WHIP,
    IP              = IP,
    role            = role,
    stringsAsFactors = FALSE
  )
}

# ---------------------------------------------------------------------------
# load_projections_fixture()
#
# Returns a tibble of recorded steamer projections (25 batters + 25 pitchers)
# captured from a real `get_projections(source = "steamer", "both")` call.
# Use in integration tests that want realistic two-sided data — including
# the FanGraphs cross-side column collision (pitcher rows have non-NA `hr`
# = HR-allowed, `r` = R-allowed, `avg` = BAA), which is the canonical shape
# `zaa()` / `replacement_level()` see in production.
# ---------------------------------------------------------------------------

#' @keywords internal
load_projections_fixture <- function() {
  readRDS(testthat::test_path("fixtures", "projections-steamer-both.rds"))
}

# ---------------------------------------------------------------------------
# pad_cross_side_columns()
#
# Decorates a one-sided test fixture (hitter-only or pitcher-only rows) with
# NA columns for the absent-side categories. This matches the realistic
# shape produced by `get_projections()` after `bind_rows()` of batter +
# pitcher fetches: every union column is present on every row; cells that
# do not apply to a row's side are NA.
#
# Tests after the split-categories-by-side refactor pass this realistic
# shape so `zaa()` / `replacement_level()` validators see the union of
# scored-category columns even when only one side has rows.
#
# Adds (uppercased): the canonical batting categories + AB if any are
# missing, and the canonical pitcher categories + IP if any are missing.
# Existing columns are left untouched.
# ---------------------------------------------------------------------------

#' @keywords internal
pad_cross_side_columns <- function(df) {
  stopifnot(is.data.frame(df))
  needed <- c(
    rotostats:::CANONICAL_BATTING_CATEGORIES, "AB",
    rotostats:::CANONICAL_PITCHER_CATEGORIES, "IP"
  )
  have <- toupper(names(df))
  for (col in needed) {
    if (!(toupper(col) %in% have)) {
      df[[col]] <- NA_real_
    }
  }
  df
}
