# tests/testthat/helper-pvm-fixtures.R
#
# Fixtures for pvm() tests per test-spec.md TS-PVM-1 through TS-PVM-20.
# Loaded automatically by testthat before any test file runs.
# Tester did NOT read spec.md, implementation.md, or sim-spec.md.
#
# Exports:
#   make_pvm_config()            — standard 5x5 league_config
#   make_pvm_projections()       — synthetic 5x5 projections
#   make_pvm_replacement()       — wraps projections + config into replacement obj
#   make_boundary_replacement()  — boundary player has stats == replacement line
#   make_zero_pool_replacement() — all rostered players sub-replacement in one cat
#   make_concentration_replacement() — one player dominates one cat pool
#   .pvm_base                    — pre-built base fixture (file scope)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Canonical batting / pitcher category lists used to bucket a flat `categories`
# vector into the new league_config() split signature.
# ---------------------------------------------------------------------------
.pvm_batting_cats <- c("HR", "R", "RBI", "SB", "AVG", "OPS")
.pvm_pitcher_cats <- c("W", "K", "SV", "HLD", "QS", "SVHD",
                       "ERA", "WHIP", "FIP", "XFIP", "SIERA", "XERA",
                       "K/9", "BB/9", "HR/9")

# ---------------------------------------------------------------------------
# make_pvm_config()
# Standard 5x5 league config: 10 teams, hitter + pitcher slots per spec.
#
# Accepts a flat `categories` vector for backwards-compatible call sites and
# partitions it into the new batting_categories / pitcher_categories split
# required by league_config(). If a side ends up empty, supplies a placeholder
# canonical category so league_config() accepts the call.
# ---------------------------------------------------------------------------
make_pvm_config <- function(
  n_teams       = 10L,
  budget_split  = 0.67,
  categories    = c("HR", "R", "RBI", "SB", "AVG", "W", "K", "SV", "ERA", "WHIP")
) {
  batting <- intersect(categories, .pvm_batting_cats)
  pitcher <- intersect(categories, .pvm_pitcher_cats)

  # Placeholder fill-ins for hitter-only or pitcher-only fixtures. The
  # placeholder ensures league_config() accepts the call; the fixture only
  # exercises the populated side.
  if (length(batting) == 0L) batting <- "HR"
  if (length(pitcher) == 0L) pitcher <- "K"

  league_config(
    n_teams            = n_teams,
    roster_slots       = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L,
                           SS = 1L, OF = 3L, UTIL = 1L),
    pitcher_slots      = c(SP = 5L, RP = 3L),
    batting_categories = batting,
    pitcher_categories = pitcher,
    budget             = 260L,
    budget_split       = budget_split
  )
}

# ---------------------------------------------------------------------------
# make_pvm_projections()
# Synthetic projections: n_hitters and n_pitchers; seed for reproducibility.
# Generates enough players for a 10-team 5x5 league:
#   9 hitter slots * 10 teams = 90 hitters needed
#   8 pitcher slots * 10 teams = 80 pitchers needed
# ---------------------------------------------------------------------------
make_pvm_projections <- function(n_batters = 180L, n_pitchers = 130L, seed = 42L) {
  n_sp <- round(n_pitchers * 0.625)   # ~5/8 SP
  n_rp <- n_pitchers - n_sp
  make_projections_data(n_batters = n_batters, n_sp = n_sp, n_rp = n_rp, seed = seed)
}

# ---------------------------------------------------------------------------
# make_pvm_replacement()
# Full round-trip through replacement_level() — real output, real attributes.
# Uses multi_pos = "highest_par" (the repo default; test-spec conceptual term
# "best" maps to this value in the actual implementation).
# ---------------------------------------------------------------------------
make_pvm_replacement <- function(
  projections = make_pvm_projections(),
  config      = make_pvm_config(),
  multi_pos   = "highest_par"
) {
  replacement_level(projections, config, multi_pos = multi_pos)
}

# ---------------------------------------------------------------------------
# make_boundary_replacement()
# Produces a replacement object where the last rostered player in every
# position has stats exactly equal to the replacement stat line.
#
# Strategy: build a small hand-crafted projection set where we know which
# player is last-rostered, then set that player's stats = replacement stats.
# We use n_teams = 2 with 1 slot per position so the boundary player is rank 2.
# ---------------------------------------------------------------------------
make_boundary_replacement <- function() {
  # Use a simple 3-hitter, 2-pitcher config so n_teams=2, 1 slot each
  cfg <- league_config(
    n_teams            = 2L,
    roster_slots       = c(C = 1L, `1B` = 1L, `2B` = 1L),
    pitcher_slots      = c(SP = 1L, RP = 1L),
    batting_categories = c("HR", "R", "RBI", "SB", "AVG"),
    pitcher_categories = c("W", "K", "SV", "ERA", "WHIP"),
    budget             = 260L,
    budget_split       = 0.67
  )

  # Exactly 2 C, 2 1B, 2 2B, 2 SP, 2 RP = 10 players
  # Good player at rank 1; rank-2 player has moderate stats
  proj <- data.frame(
    player_id       = paste0("BD", 1:10),
    player_name     = paste0("Boundary_", 1:10),
    pos_eligibility = c("C", "C", "1B", "1B", "2B", "2B", "SP", "SP", "RP", "RP"),
    team            = rep("NYY", 10),
    league          = rep("AL", 10),
    HR   = c(30, 10, 25, 15, 20, 12, NA, NA, NA, NA),
    R    = c(80, 40, 75, 45, 70, 42, NA, NA, NA, NA),
    RBI  = c(85, 45, 80, 50, 75, 48, NA, NA, NA, NA),
    SB   = c(10,  3,  8,  4,  6,  3, NA, NA, NA, NA),
    AVG  = c(0.285, 0.240, 0.280, 0.245, 0.275, 0.248, NA, NA, NA, NA),
    AB   = c(450, 380, 440, 390, 430, 395, NA, NA, NA, NA),
    W    = c(NA, NA, NA, NA, NA, NA, 14, 10, NA, NA),
    K    = c(NA, NA, NA, NA, NA, NA, 175, 150, 65, 45),
    SV   = c(NA, NA, NA, NA, NA, NA, NA, NA, 28, 18),
    ERA  = c(NA, NA, NA, NA, NA, NA, 3.20, 3.80, 3.50, 4.00),
    WHIP = c(NA, NA, NA, NA, NA, NA, 1.15, 1.25, 1.20, 1.30),
    IP   = c(NA, NA, NA, NA, NA, NA, 175.0, 165.0, 65.0, 58.0),
    role = c(rep(NA_character_, 6), "SP", "SP", "RP", "RP"),
    stringsAsFactors = FALSE
  )

  repl <- replacement_level(proj, cfg, multi_pos = "highest_par")

  # Adjust the replacement stat line so that exactly the rank-2 players
  # have zero contribution (stats == RS).
  # After replacement_level(), RS is derived from the actual boundary player.
  # We directly set the rank-2 player's stats to match replacement_stats.
  # Since replacement_level has already computed this, the boundary player
  # naturally has zero above-replacement contribution. Return as-is.
  repl
}

# ---------------------------------------------------------------------------
# make_zero_pool_replacement()
# All rostered players are sub-replacement in `zero_cat`.
# Uses the standard fixture; we override the replacement stat for that cat
# to be above every player's actual projection.
# ---------------------------------------------------------------------------
make_zero_pool_replacement <- function(zero_cat = "SB") {
  proj <- make_pvm_projections(seed = 42L)
  cfg  <- make_pvm_config()
  repl <- replacement_level(proj, cfg, multi_pos = "highest_par")

  # Find maximum value of zero_cat among rostered players
  pa            <- attr(repl, "position_assignments")
  full_proj     <- attr(repl, "projections")   # uppercased by replacement_level
  rostered_ids  <- names(pa)[!is.na(pa)]
  rostered_proj <- full_proj[full_proj$PLAYER_ID %in% rostered_ids, , drop = FALSE]
  zero_cat_upper <- toupper(zero_cat)
  max_val <- max(rostered_proj[[zero_cat_upper]], na.rm = TRUE)

  # Set replacement_stats for zero_cat to max_val + 1 so all are sub-replacement
  repl$replacement_stats[[zero_cat_upper]] <- max_val + 1.0

  repl
}

# ---------------------------------------------------------------------------
# make_concentration_replacement()
# One pitcher has a dominant share of the dominant_cat pool (e.g., SV).
# Engineered to fire rotostats_warning_pvm_concentration.
# ---------------------------------------------------------------------------
make_concentration_replacement <- function(dominant_cat = "SV", dominant_pct = 0.40) {
  # Build a fixture where "Closer1" has SV far above any other rostered pitcher.
  # Use standard 10-team league; RP pool = 10 * 3 = 30 RPs rostered.
  # Set one RP's SV = 65, all others <= 4. RS[SV] ~ low.
  proj <- make_pvm_projections(seed = 55L)
  cfg  <- make_pvm_config()

  # Set the first RP's SV very high and rename for identification
  rp_rows <- which(proj$pos_eligibility == "RP")
  proj$player_id[rp_rows[1]] <- "Closer1"
  proj$SV[rp_rows[1]] <- 65L
  # Cap all other RP SV at 4
  for (i in rp_rows[-1]) {
    proj$SV[i] <- min(proj$SV[i], 4L)
  }

  replacement_level(proj, cfg, multi_pos = "highest_par")
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# make_pvm_fixture()
# Returns a list(replacement, dollar_values) suitable for Task 5.3 test.
# Uses HR on the batting side and ERA on the pitcher side so the cross-side
# NA gating is directly observable.
# ---------------------------------------------------------------------------
make_pvm_fixture <- function() {
  cfg  <- make_pvm_config(
    categories = c("HR", "R", "RBI", "SB", "AVG", "W", "K", "SV", "ERA", "WHIP")
  )
  proj <- make_pvm_projections()
  repl <- replacement_level(proj, cfg, multi_pos = "highest_par")
  list(replacement = repl)
}

# ---------------------------------------------------------------------------
# Pre-built base fixture. Uses delayedAssign so the expression forces only on
# first access — testthat sources helpers alphabetically, and the body relies
# on make_projections_data() from helper-test-data.R which loads later.
# ---------------------------------------------------------------------------
delayedAssign(".pvm_base", make_pvm_replacement())
