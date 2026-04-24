# tests/testthat/helper-zar-fixtures.R
#
# Fixtures for zar() tests per test-spec.md TS-ZAR-1 through TS-ZAR-12.
# Loaded automatically by testthat before any test file runs.
# Tester did NOT read spec.md, implementation.md, or R/zar.R.
#
# Reuses make_repl(), make_zaa_cfg(), make_projections_data() from
# helper-zaa-fixtures.R and helper-test-data.R (also auto-loaded).

# ---------------------------------------------------------------------------
# make_zar_fixture()
# ---------------------------------------------------------------------------
# Builds a real replacement_level() round-trip for success-path tests.
#   - projections: standard make_projections_data() output (n_hitters=120,
#     n_sp=80, n_rp=40, seed=99) — enough players for well-defined SDs.
#   - categories: HR, R, SB, K, SV (pure counting — avoids rate-stat complexity)
#   - n_teams = 2L so replacement boundary is low (easy to identify)
#   - roster_slots  = c(C=1, 1B=1, OF=1)
#   - pitcher_slots = c(SP=1, RP=1)
# Returns: list(projections, config, replacement)
make_zar_fixture <- function(n_teams = 2L, seed = 99L) {
  projections <- make_projections_data(seed = seed)

  config <- league_config(
    n_teams            = n_teams,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 1L, RP = 1L),
    batting_categories = c("HR", "R", "SB"),
    pitcher_categories = c("K", "SV"),
    league_type        = "mixed"
  )

  replacement <- replacement_level(projections, config)

  list(projections = projections, config = config, replacement = replacement)
}

# ---------------------------------------------------------------------------
# make_zar_rate_fixture()
# ---------------------------------------------------------------------------
# Builds a replacement_level() round-trip with ERA as a scored category.
#   - categories: HR, R, ERA
#   - n_teams = 4L, pitcher_slots = c(SP=3, RP=2)
#   - Two SP have controlled ERA values:
#       sp_good_id: ERA = 2.50 (below position mean ~4.1 => should get zar_era > 0)
#       sp_bad_id:  ERA = 6.50 (above position mean ~4.1 => should get zar_era < 0)
# Returns: list(projections, config, replacement, sp_good_id, sp_bad_id)
make_zar_rate_fixture <- function(seed = 42L) {
  projections <- make_projections_data(n_hitters = 60L, n_sp = 20L, n_rp = 10L,
                                       seed = seed)

  sp_idx <- which(projections$pos_eligibility == "SP")
  # Inject controlled ERA values (both already have non-NA IP from make_projections_data)
  projections$ERA[sp_idx[1L]] <- 2.50   # good SP — well below mean
  projections$ERA[sp_idx[2L]] <- 6.50   # bad  SP — well above mean

  sp_good_id <- projections$player_id[sp_idx[1L]]
  sp_bad_id  <- projections$player_id[sp_idx[2L]]

  config <- league_config(
    n_teams            = 4L,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 3L, RP = 2L),
    batting_categories = c("HR", "R"),
    pitcher_categories = c("ERA"),
    league_type        = "mixed"
  )

  replacement <- replacement_level(projections, config)

  list(
    projections = projections,
    config      = config,
    replacement = replacement,
    sp_good_id  = sp_good_id,
    sp_bad_id   = sp_bad_id
  )
}

# ---------------------------------------------------------------------------
# make_zar_sv_fixture()
# ---------------------------------------------------------------------------
# Builds a fixture specifically for TS-ZAR-6 (SP/RP separate SV baselines).
# SP players have SV = 0 explicitly (starters don't save); RP players have
# realistic SV drawn from make_projections_data (mean ~9.6, sd ~7.6).
# Uses n_hitters=120, n_sp=80, n_rp=40 for a non-degenerate combined pool.
# Returns: list(projections, config, replacement)
make_zar_sv_fixture <- function(seed = 42L) {
  projections <- make_projections_data(n_hitters = 120L, n_sp = 80L, n_rp = 40L,
                                       seed = seed)

  # Set SP SV to 0 (not NA) so combined pool distribution is non-degenerate
  projections$SV[projections$pos_eligibility == "SP"] <- 0L

  config <- league_config(
    n_teams            = 12L,
    roster_slots       = c(C = 1L, `1B` = 1L, OF = 1L),
    pitcher_slots      = c(SP = 3L, RP = 3L),
    batting_categories = c("HR", "R", "SB"),
    pitcher_categories = c("K", "SV"),
    league_type        = "mixed"
  )

  replacement <- replacement_level(projections, config)

  list(projections = projections, config = config, replacement = replacement)
}

# ---------------------------------------------------------------------------
# make_zar_boundary_fixture()
# ---------------------------------------------------------------------------
# Minimal hand-crafted fixture for TS-ZAR-9 (exact boundary check).
# Exactly 2 C, 2 1B, 2 SP, 2 RP. n_teams = 2L with 1 slot each position.
# C1 is clearly better; C2 is the boundary player (rank 2 among C).
# Returns: list(projections, config, replacement)
make_zar_boundary_fixture <- function() {
  proj <- data.frame(
    player_id       = c("C1", "C2", "B1", "B2", "S1", "S2", "R1", "R2"),
    player_name     = paste0("Player", 1:8),
    pos_eligibility = c("C", "C", "1B", "1B", "SP", "SP", "RP", "RP"),
    team            = rep("NYY", 8L),
    league          = rep("AL",  8L),
    HR  = c(30L, 5L, 25L, 15L, NA_real_, NA_real_, NA_real_, NA_real_),
    R   = c(80L, 30L, 75L, 55L, NA_real_, NA_real_, NA_real_, NA_real_),
    RBI = c(85L, 35L, 80L, 60L, NA_real_, NA_real_, NA_real_, NA_real_),
    SB  = c(10L, 2L, 12L, 8L,  NA_real_, NA_real_, NA_real_, NA_real_),
    AB  = c(450L, 350L, 450L, 430L, NA_real_, NA_real_, NA_real_, NA_real_),
    AVG = c(0.285, 0.220, 0.280, 0.255, NA_real_, NA_real_, NA_real_, NA_real_),
    W   = c(NA_real_, NA_real_, NA_real_, NA_real_, 14L, 10L, NA_real_, NA_real_),
    K   = c(NA_real_, NA_real_, NA_real_, NA_real_, 180L, 150L, 60L, 40L),
    SV  = c(NA_real_, NA_real_, NA_real_, NA_real_, NA_real_, NA_real_, 25L, 15L),
    ERA = c(NA_real_, NA_real_, NA_real_, NA_real_, 3.20, 3.80, 3.50, 4.00),
    WHIP = c(NA_real_, NA_real_, NA_real_, NA_real_, 1.15, 1.25, 1.20, 1.30),
    IP  = c(NA_real_, NA_real_, NA_real_, NA_real_, 175.0, 165.0, 65.0, 60.0),
    role = c(rep(NA_character_, 4L), "SP", "SP", "RP", "RP"),
    stringsAsFactors = FALSE
  )

  cfg <- league_config(
    n_teams            = 2L,
    roster_slots       = c(C = 1L, `1B` = 1L),
    pitcher_slots      = c(SP = 1L, RP = 1L),
    batting_categories = c("HR", "R", "SB"),
    pitcher_categories = c("K", "SV"),
    league_type        = "mixed"
  )

  repl <- replacement_level(proj, cfg)

  list(projections = proj, config = cfg, replacement = repl)
}
