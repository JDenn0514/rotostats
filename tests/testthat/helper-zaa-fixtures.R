# tests/testthat/helper-zaa-fixtures.R
#
# Fixtures for zaa() tests per test-spec.md TS-ZAA-1 through TS-ZAA-18.
# Loaded automatically by testthat before any test file runs.
# Tester did NOT read spec.md, implementation.md, or R/zaa.R.

# ---------------------------------------------------------------------------
# pop_sd() — population SD helper used in expected-value pinning
# ---------------------------------------------------------------------------
pop_sd <- function(x) sqrt(mean((x - mean(x))^2))

# ---------------------------------------------------------------------------
# make_repl() — construct a minimal mock replacement_level object
#
# attrs:
#   projections       — data frame
#   config            — league_config
#   stat_units        — "raw_projected" (or caller-supplied for error tests)
#   position_assignments — named character vector: player_id -> position
# ---------------------------------------------------------------------------
make_repl <- function(projections, config,
                      stat_units = "raw_projected",
                      position_assignments = NULL) {
  repl <- structure(list(), class = "replacement_level")
  attr(repl, "projections")  <- projections
  attr(repl, "config")       <- config
  attr(repl, "stat_units")   <- stat_units
  if (!is.null(position_assignments)) {
    attr(repl, "position_assignments") <- position_assignments
  }
  repl
}

# ---------------------------------------------------------------------------
# Canonical batting / pitcher category lists used to bucket a flat `categories`
# vector into the new league_config() split signature.
# ---------------------------------------------------------------------------
.zaa_batting_cats <- c("HR", "R", "RBI", "SB", "AVG", "OPS")
.zaa_pitcher_cats <- c("W", "K", "SV", "HLD", "QS", "SVHD",
                       "ERA", "WHIP", "FIP", "XFIP", "SIERA", "XERA",
                       "K/9", "BB/9", "HR/9")

# ---------------------------------------------------------------------------
# make_zaa_cfg() — thin wrapper around league_config()
#
# Accepts a flat `categories` vector for backwards-compatible call sites and
# partitions it into the new batting_categories / pitcher_categories split
# required by league_config(). If a side ends up empty, supplies a placeholder
# canonical category so league_config() accepts the call (the fixture only
# exercises the populated side).
# ---------------------------------------------------------------------------
make_zaa_cfg <- function(categories,
                          n_teams       = 12L,
                          roster_slots  = c(C = 2L, "1B" = 2L, OF = 3L),
                          pitcher_slots = c(SP = 3L, RP = 2L),
                          league_type   = "mixed") {
  batting <- intersect(categories, .zaa_batting_cats)
  pitcher <- intersect(categories, .zaa_pitcher_cats)

  # Placeholder fill-ins for hitter-only or pitcher-only fixtures. The
  # placeholder ensures league_config() accepts the call; the fixture only
  # exercises the populated side.
  if (length(batting) == 0L) batting <- "HR"
  if (length(pitcher) == 0L) pitcher <- "K"

  league_config(
    n_teams            = n_teams,
    roster_slots       = roster_slots,
    pitcher_slots      = pitcher_slots,
    batting_categories = batting,
    pitcher_categories = pitcher,
    league_type        = league_type
  )
}

# ---------------------------------------------------------------------------
# make_pure_pitcher_df() / make_pure_batter_df()
# For TS-ZAA-5 fixture hygiene: no cross-position NA contamination.
# ---------------------------------------------------------------------------

# n pitchers with W, K, ERA, WHIP, IP; no hitter stat columns.
make_pure_pitcher_df <- function(n_sp = 3L, n_rp = 3L, seed = 7L) {
  set.seed(seed)
  n <- n_sp + n_rp
  data.frame(
    player_id       = paste0("P", seq_len(n)),
    player_name     = paste0("Pitcher", seq_len(n)),
    pos_eligibility = c(rep("SP", n_sp), rep("RP", n_rp)),
    team            = rep("NYY", n),
    league          = rep("AL",  n),
    W               = c(round(runif(n_sp, 8, 15)), rep(NA_real_, n_rp)),
    K               = c(round(runif(n_sp, 120, 200)),
                        round(runif(n_rp,  50, 90))),
    ERA             = round(runif(n, 3.0, 5.0), 2),
    WHIP            = round(runif(n, 1.0, 1.4), 3),
    IP              = c(round(runif(n_sp, 150, 210)),
                        round(runif(n_rp,  55, 80))),
    SV              = c(rep(NA_real_, n_sp),
                        round(pmax(0, runif(n_rp, 0, 30)))),
    stringsAsFactors = FALSE
  )
}

# n hitters with HR, R, RBI, SB, AVG, AB; no pitcher stat columns.
make_pure_batter_df <- function(n = 5L, positions = NULL, seed = 11L) {
  set.seed(seed)
  if (is.null(positions)) positions <- rep("OF", n)
  data.frame(
    player_id       = paste0("H", seq_len(n)),
    player_name     = paste0("Hitter", seq_len(n)),
    pos_eligibility = positions,
    team            = rep("BOS", n),
    league          = rep("AL",  n),
    HR              = round(runif(n, 10, 40)),
    R               = round(runif(n, 50, 100)),
    RBI             = round(runif(n, 50, 110)),
    SB              = round(runif(n, 0,  30)),
    AVG             = round(runif(n, 0.230, 0.320), 3),
    AB              = round(runif(n, 300, 550)),
    stringsAsFactors = FALSE
  )
}
