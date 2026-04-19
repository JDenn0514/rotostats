# tests/testthat/helper-par-fixtures.R
#
# Fixtures for par() tests per test-spec.md §2b.
# Loaded automatically by testthat before any test file runs.

# ---------------------------------------------------------------------------
# make_par_counting_fixture()
# ---------------------------------------------------------------------------
# Returns a named list:
#   projections  — data.frame of player projections
#   config       — league_config (n_teams teams, counting cats only)
#   denominators — named numeric vector with attr(., "rate_conversion")
#   replacement  — replacement_level() output
#   league_history — minimal list for sgp() blended_pool validation
#
# Categories: HR, R, SB, K, SV (pure counting, no rate stats).
# roster_slots = c(C=1, 1B=1, OF=1); pitcher_slots = c(SP=1, RP=1).
# Denominators are hardcoded with attr(., "rate_conversion") = "blended_pool".
#
# Default seed = 99L (chosen so that all positions' boundary_total_par
# deviation is within 0.05 SGP with n_teams=3L, satisfying §3 Invariant 2).
# Default seed = 42L is too unstable for 1B at n_teams=3 (deviation ≈ 0.12).
# ---------------------------------------------------------------------------
make_par_counting_fixture <- function(n_teams = 3L, seed = 99L) {
  projections <- make_projections_data(seed = seed)

  config <- league_config(
    n_teams       = n_teams,
    roster_slots  = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots = c(SP = 1L, RP = 1L),
    categories    = c("HR", "R", "SB", "K", "SV"),
    league_type   = "mixed",
    budget        = 260L
  )

  denominators <- c(HR = 30, R = 50, SB = 15, K = 80, SV = 12)
  attr(denominators, "rate_conversion") <- "blended_pool"

  # Minimal league_history satisfying sgp() blended_pool validation.
  # No ERA/WHIP/AVG columns are needed since categories are counting-only.
  league_history_obj <- list(
    team_season = data.frame(IP = 1000, AB = 4000)
  )

  replacement <- replacement_level(projections, config = config)

  list(
    projections      = projections,
    config           = config,
    denominators     = denominators,
    replacement      = replacement,
    league_history   = league_history_obj
  )
}

# ---------------------------------------------------------------------------
# make_par_rate_fixture()
# ---------------------------------------------------------------------------
# Returns the same structure with categories c("HR", "R", "ERA", "WHIP", "AVG")
# and a valid league_history object.
# n_teams = 12L so ERA/WHIP replacement boundaries are well-populated.
# Includes one manually injected SP with ERA = 7.5 and IP = 200 to guarantee
# the worst-ERA pitcher has negative par_ERA (needed for §7 sign check).
# ---------------------------------------------------------------------------
make_par_rate_fixture <- function(seed = 42L) {
  projections <- make_projections_data(seed = seed)

  # Inject an extreme ERA pitcher to ensure sign test is reliable.
  # Replace the last SP row with a clearly-below-replacement pitcher.
  sp_rows <- which(projections$role == "SP")
  projections$ERA[sp_rows[length(sp_rows)]] <- 7.5
  projections$IP[sp_rows[length(sp_rows)]]  <- 200.0

  config <- league_config(
    n_teams       = 12L,
    roster_slots  = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L, SS = 1L,
                      OF = 3L, UTIL = 1L),
    pitcher_slots = c(SP = 6L, RP = 3L),
    categories    = c("HR", "R", "ERA", "WHIP", "AVG"),
    league_type   = "mixed",
    budget        = 260L
  )

  # team_season must include all scoring categories for sgp_denominators().
  set.seed(seed)
  n_t <- 12L
  ts <- data.frame(
    year    = rep(2023L, n_t),
    team_id = paste0("T", seq_len(n_t)),
    IP      = round(stats::rnorm(n_t, 1450, 50)),
    AB      = round(stats::rnorm(n_t, 5500, 200)),
    HR      = round(stats::rnorm(n_t, 200,  20)),
    R       = round(stats::rnorm(n_t, 800,  50)),
    ERA     = round(stats::rnorm(n_t, 3.9,  0.3), 2),
    WHIP    = round(stats::rnorm(n_t, 1.25, 0.08), 3),
    AVG     = round(stats::rnorm(n_t, 0.255, 0.01), 3),
    stringsAsFactors = FALSE
  )
  league_history_obj <- suppressWarnings(league_history(team_season = ts))
  denominators <- suppressWarnings(
    sgp_denominators(league_history_obj,
                     scoring_categories = c("HR", "R", "ERA", "WHIP", "AVG"))
  )

  replacement <- replacement_level(projections, config = config)

  list(
    projections    = projections,
    config         = config,
    denominators   = denominators,
    replacement    = replacement,
    league_history = league_history_obj
  )
}

# ---------------------------------------------------------------------------
# make_miscalibrated_replacement()
# ---------------------------------------------------------------------------
# Takes a *counting* fixture and returns a modified replacement object whose
# replacement_stats have been scaled down by a factor that is a function of
# shift_n.  This makes band players (near the true boundary) appear far above
# replacement, causing the band-check median to exceed boundary_threshold = 1.0.
#
# Implementation: directly scale down the counting-stat columns in
# replacement_stats for hitter positions.  This is the "direct manipulation"
# approach from test-spec.md §2b.
# ---------------------------------------------------------------------------
make_miscalibrated_replacement <- function(fixture, shift_n) {
  repl <- fixture$replacement

  # scale < 1 inflates band-player PAR; larger shift_n shrinks further.
  scale <- pmax(0.1, 1 - shift_n * 0.1)

  hitter_cats <- c("HR", "R", "SB")
  rs <- repl$replacement_stats

  for (cat in hitter_cats) {
    if (cat %in% names(rs)) {
      rs[[cat]] <- rs[[cat]] * scale
    }
  }

  repl$replacement_stats <- rs
  repl
}
