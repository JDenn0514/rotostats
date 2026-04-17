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
#   - n_hitters = 120:  at least 15 per hitter position (C, 1B, 2B, 3B, SS)
#                       plus 45 OF = 90 base; excess becomes OF.
#   - n_sp      = 80:   satisfies 12-team × 6 SP slots = 72 needed
#   - n_rp      = 40:   satisfies 12-team × 3 RP slots = 36 needed
#
# Override n_sp and n_rp when testing smaller league configurations.
# ---------------------------------------------------------------------------

#' @keywords internal
make_projections_data <- function(n_hitters = 120L, n_sp = 80L, n_rp = 40L,
                                   seed = 42L) {
  set.seed(seed)

  # Guarantee at least 15 players per primary hitter position
  pos_min <- 15L
  hitter_positions_base <- c(
    rep("C",  pos_min),
    rep("1B", pos_min),
    rep("2B", pos_min),
    rep("3B", pos_min),
    rep("SS", pos_min),
    rep("OF", pos_min * 3L)   # 45 OF base
  )
  # Pad with OF to reach n_hitters
  n_base <- length(hitter_positions_base)
  if (n_base < n_hitters) {
    hitter_positions_base <- c(hitter_positions_base,
                                rep("OF", n_hitters - n_base))
  }
  n_hitters_actual <- length(hitter_positions_base)

  # ~15% multi-eligible
  n_multi   <- max(0L, round(n_hitters_actual * 0.15))
  multi_idx <- sample(seq_len(n_hitters_actual), n_multi, replace = FALSE)
  multi_alt <- sample(c("1B", "3B", "2B", "SS"), n_multi, replace = TRUE)
  for (k in seq_len(n_multi)) {
    orig <- hitter_positions_base[multi_idx[k]]
    hitter_positions_base[multi_idx[k]] <- paste(orig, multi_alt[k], sep = "|")
  }
  hitter_positions <- hitter_positions_base

  n        <- n_hitters_actual + n_sp + n_rp
  player_id   <- paste0("P", seq_len(n))
  player_name <- paste0("Player_", seq_len(n))
  team_pool   <- c("NYY", "BOS", "LAD", "CHC", "HOU", "ATL", "STL", "SF",
                   "NYM", "MIN", "SEA", "SD")
  teams       <- sample(team_pool, n, replace = TRUE)
  leagues     <- ifelse(teams %in% c("NYY", "BOS", "HOU", "MIN", "SEA"),
                        "AL", "NL")

  pos_elig <- c(hitter_positions, rep("SP", n_sp), rep("RP", n_rp))

  # Hitter stats
  HR  <- c(round(pmax(0, rnorm(n_hitters_actual, 18, 10))),
           rep(NA_real_, n_sp + n_rp))
  R   <- c(round(pmax(0, rnorm(n_hitters_actual, 70, 20))),
           rep(NA_real_, n_sp + n_rp))
  RBI <- c(round(pmax(0, rnorm(n_hitters_actual, 72, 22))),
           rep(NA_real_, n_sp + n_rp))
  SB  <- c(round(pmax(0, rnorm(n_hitters_actual, 10, 8))),
           rep(NA_real_, n_sp + n_rp))
  AB  <- c(round(pmax(200, rnorm(n_hitters_actual, 440, 60))),
           rep(NA_real_, n_sp + n_rp))
  AVG <- c(round(pmax(0.150, pmin(0.380, rnorm(n_hitters_actual, 0.265, 0.025))),
                 3),
           rep(NA_real_, n_sp + n_rp))

  # Pitcher stats
  ip_sp  <- round(pmax(140, rnorm(n_sp, 170, 15)), 1)
  ip_rp  <- round(pmax(40,  rnorm(n_rp,  60, 10)), 1)
  W   <- c(rep(NA_real_, n_hitters_actual),
           round(pmax(0, rnorm(n_sp, 12, 4))),
           rep(NA_real_, n_rp))
  K   <- c(rep(NA_real_, n_hitters_actual),
           round(pmax(20, rnorm(n_sp, 165, 35))),
           round(pmax(10, rnorm(n_rp,  60, 20))))
  SV  <- c(rep(NA_real_, n_hitters_actual),
           rep(NA_real_, n_sp),
           round(pmax(0, rnorm(n_rp, 8, 10))))
  ERA <- c(rep(NA_real_, n_hitters_actual),
           round(pmax(2.0, pmin(7.5, rnorm(n_sp, 3.90, 0.80))), 2),
           round(pmax(2.0, pmin(7.5, rnorm(n_rp, 3.80, 1.00))), 2))
  WHIP <- c(rep(NA_real_, n_hitters_actual),
            round(pmax(0.90, pmin(2.00, rnorm(n_sp, 1.25, 0.15))), 3),
            round(pmax(0.90, pmin(2.00, rnorm(n_rp, 1.25, 0.20))), 3))
  IP   <- c(rep(NA_real_, n_hitters_actual), ip_sp, ip_rp)
  role <- c(rep(NA_character_, n_hitters_actual),
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
