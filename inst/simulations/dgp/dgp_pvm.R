# dgp_pvm.R — Data Generating Process for pvm() Monte Carlo Studies
#
# Used in Studies 1, 2, 3, and 4 of sim-pvm.R.
#
# Generates a synthetic projection pool and wraps it in a replacement_level()-
# compatible object (carrying projections, config, stat_units, and
# position_assignments attributes) for direct use as pvm()'s input.
#
# Follows the DGP specification in sim-spec.md for request pvm-2026-04-23.
#
# Usage:
#   replacement <- dgp_pvm(seed, n_teams = 12L, rate_pool = "ip_weighted",
#                           baseline = NULL, fixed_pool_seed = NULL)
#   result <- pvm(replacement, rate_pool = rate_pool, ...)
#
# Player-pool structure (per sim-spec.md §1.2 / §2.2 / §3.2):
#   Hitter counting stats: HR, R, RBI, SB ~ Poisson with player-level lambda
#   Hitter rate stat: AVG ~ rescaled Beta(5,5) in [.220, .330]
#   AB ~ round(Uniform(350, 600))
#   Pitcher counting: W, K, SV ~ Poisson
#   Pitcher rate: ERA ~ Uniform(2.80, 5.80), WHIP ~ Uniform(0.95, 1.65)
#   IP ~ round(Uniform(40, 220))
#
# Scored categories: HR, R, RBI, SB, AVG (hitters); W, K, SV, ERA, WHIP (pitchers)
# n_rostered = n_teams * (roster_hitters_per_team + roster_pitchers_per_team)
# total pool = n_rostered * 1.5 players

ROSTER_HITTERS_PER_TEAM <- 9L   # 9 hitter slots per team (per sim-spec §1.2)
ROSTER_PITCHERS_PER_TEAM <- 8L  # 8 pitcher slots per team (per sim-spec §1.2)

HITTER_POSITIONS <- c("C", "1B", "2B", "3B", "SS", "OF", "UTIL")
HITTER_SLOTS_DEFAULT <- c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L,
                           SS = 1L, OF = 3L, UTIL = 1L)  # sums to 9

PITCHER_SLOTS_DEFAULT <- c(SP = 5L, RP = 3L)  # sums to 8 (per sim-spec)

SCORED_CATS_HITTER  <- c("HR", "R", "RBI", "SB", "AVG")
SCORED_CATS_PITCHER <- c("W", "K", "SV", "ERA", "WHIP")
SCORED_CATS_ALL     <- c(SCORED_CATS_HITTER, SCORED_CATS_PITCHER)

INVERSE_CATS <- c("ERA", "WHIP")   # lower-is-better

#' Build a league_config for pvm() simulation studies.
#'
#' @param n_teams Integer. Team count.
#' @return A league_config object.
#' @noRd
make_sim_config <- function(n_teams) {
  league_config(
    n_teams       = as.integer(n_teams),
    roster_slots  = HITTER_SLOTS_DEFAULT,
    pitcher_slots = PITCHER_SLOTS_DEFAULT,
    categories    = SCORED_CATS_ALL,
    league_type   = "mixed",
    budget        = 260L,
    budget_split  = 0.6667
  )
}

#' Draw per-player lambda for counting stats from a uniform distribution.
#'
#' @param n Integer. Number of players.
#' @param lo Numeric. Lower bound of uniform.
#' @param hi Numeric. Upper bound of uniform.
#' @return Numeric vector of length n.
#' @noRd
draw_lambdas <- function(n, lo, hi) {
  stats::runif(n, lo, hi)
}

#' Generate DGP for pvm() studies 1–3.
#'
#' Creates a full synthetic projection pool, computes replacement-stat lines at
#' the pool boundary, and wraps everything in a replacement_level()-compatible
#' object.
#'
#' @param seed Integer seed set at the START of the call (pure function).
#' @param n_teams Integer. Team count; controls pool depth.
#' @param baseline Named numeric or NULL. ERA/WHIP/AVG baseline constants for
#'   rate_pool = "fixed_baseline". Not used by the DGP itself; passed through
#'   to the returned object so pvm() can find them.
#' @return A replacement_level()-compatible list with attributes:
#'   - stat_units = "raw_projected"
#'   - projections (full player pool data.frame)
#'   - config (league_config)
#'   - position_assignments (named character vector)
#'   The list also contains replacement_stats and params per the contract.
#' @noRd
dgp_pvm <- function(seed, n_teams = 12L, baseline = NULL) {
  set.seed(seed, kind = "L'Ecuyer-CMRG")

  n_teams <- as.integer(n_teams)
  n_rostered_hitters  <- n_teams * ROSTER_HITTERS_PER_TEAM
  n_rostered_pitchers <- n_teams * ROSTER_PITCHERS_PER_TEAM
  n_rostered          <- n_rostered_hitters + n_rostered_pitchers

  # Total pool = 1.5 * rostered (rounded up), split roughly 50/50 hitter/pitcher
  n_total_hitters  <- as.integer(ceiling(n_rostered_hitters  * 1.5))
  n_total_pitchers <- as.integer(ceiling(n_rostered_pitchers * 1.5))
  n_total          <- n_total_hitters + n_total_pitchers

  # ----- HITTERS ----------------------------------------------------------

  # Distribute hitter slots proportionally across positions
  # HITTER_SLOTS_DEFAULT sums to 9; scale to n_total_hitters
  n_per_pos <- round(n_total_hitters * HITTER_SLOTS_DEFAULT /
                       sum(HITTER_SLOTS_DEFAULT))
  # Ensure total matches exactly
  delta <- n_total_hitters - sum(n_per_pos)
  n_per_pos[which.max(n_per_pos)] <- n_per_pos[which.max(n_per_pos)] + delta

  hitter_rows <- vector("list", length(HITTER_SLOTS_DEFAULT))
  player_counter <- 0L

  for (i in seq_along(HITTER_SLOTS_DEFAULT)) {
    pos_name <- names(HITTER_SLOTS_DEFAULT)[i]
    n_p      <- as.integer(n_per_pos[i])

    # Per-player lambda draws
    lambda_HR  <- draw_lambdas(n_p, 5, 40)
    lambda_R   <- draw_lambdas(n_p, 40, 110)
    lambda_RBI <- draw_lambdas(n_p, 35, 110)
    lambda_SB  <- draw_lambdas(n_p, 1, 50)

    HR  <- stats::rpois(n_p, lambda_HR)
    R   <- stats::rpois(n_p, lambda_R)
    RBI <- stats::rpois(n_p, lambda_RBI)
    SB  <- stats::rpois(n_p, lambda_SB)

    # AVG ~ Beta(5,5) rescaled to [.220, .330]
    raw_beta <- stats::rbeta(n_p, shape1 = 5, shape2 = 5)
    AVG      <- 0.220 + raw_beta * (0.330 - 0.220)

    # AB ~ round(Uniform(350, 600))
    AB <- as.integer(round(stats::runif(n_p, 350, 600)))

    player_counter <- player_counter + n_p
    ids <- seq.int(player_counter - n_p + 1L, player_counter)

    hitter_rows[[i]] <- data.frame(
      PLAYER_ID       = ids,
      player_name     = paste0(pos_name, "_H_", seq_len(n_p)),
      position        = pos_name,
      pos_eligibility = pos_name,
      league          = rep_len(c("AL", "NL"), n_p),
      role            = NA_character_,
      HR  = HR,
      R   = R,
      RBI = RBI,
      SB  = SB,
      AB  = AB,
      AVG = AVG,
      IP  = NA_real_,
      ERA = NA_real_,
      WHIP = NA_real_,
      W   = NA_integer_,
      K   = NA_integer_,
      SV  = NA_integer_,
      stringsAsFactors = FALSE
    )
  }
  hitters <- do.call(rbind, hitter_rows)

  # ----- PITCHERS ----------------------------------------------------------
  # SP: 5 slots per team, RP: 3 slots per team
  n_sp <- as.integer(ceiling(n_teams * PITCHER_SLOTS_DEFAULT["SP"] * 1.5))
  n_rp <- as.integer(ceiling(n_teams * PITCHER_SLOTS_DEFAULT["RP"] * 1.5))

  # SP draws
  IP_sp   <- as.integer(round(stats::runif(n_sp, 40, 220)))
  ERA_sp  <- stats::runif(n_sp, 2.80, 5.80)
  WHIP_sp <- stats::runif(n_sp, 0.95, 1.65)
  W_sp    <- stats::rpois(n_sp, draw_lambdas(n_sp, 3, 20))
  K_sp    <- stats::rpois(n_sp, draw_lambdas(n_sp, 40, 220))
  SV_sp   <- rep(0L, n_sp)

  player_counter <- player_counter + n_sp
  sp_ids <- seq.int(player_counter - n_sp + 1L, player_counter)
  sp_df <- data.frame(
    PLAYER_ID       = sp_ids,
    player_name     = paste0("SP_", seq_len(n_sp)),
    position        = "SP",
    pos_eligibility = "SP",
    league          = rep_len(c("AL", "NL"), n_sp),
    role            = "SP",
    HR  = NA_real_, R = NA_real_, RBI = NA_real_, SB = NA_real_,
    AB  = NA_real_, AVG = NA_real_,
    IP   = IP_sp,
    ERA  = ERA_sp,
    WHIP = WHIP_sp,
    W    = W_sp,
    K    = K_sp,
    SV   = SV_sp,
    stringsAsFactors = FALSE
  )

  # RP draws
  IP_rp   <- as.integer(round(stats::runif(n_rp, 40, 220)))
  ERA_rp  <- stats::runif(n_rp, 2.80, 5.80)
  WHIP_rp <- stats::runif(n_rp, 0.95, 1.65)
  W_rp    <- stats::rpois(n_rp, draw_lambdas(n_rp, 3, 20))
  K_rp    <- stats::rpois(n_rp, draw_lambdas(n_rp, 40, 220))
  # Some RPs have saves; top-third of RPs (by IP) are closers
  closer_n <- as.integer(round(n_rp * 0.20))
  sv_lambda <- c(draw_lambdas(closer_n, 15, 45),
                 rep(0, n_rp - closer_n))
  SV_rp <- stats::rpois(n_rp, sv_lambda)

  player_counter <- player_counter + n_rp
  rp_ids <- seq.int(player_counter - n_rp + 1L, player_counter)
  rp_df <- data.frame(
    PLAYER_ID       = rp_ids,
    player_name     = paste0("RP_", seq_len(n_rp)),
    position        = "RP",
    pos_eligibility = "RP",
    league          = rep_len(c("AL", "NL"), n_rp),
    role            = "RP",
    HR  = NA_real_, R = NA_real_, RBI = NA_real_, SB = NA_real_,
    AB  = NA_real_, AVG = NA_real_,
    IP   = IP_rp,
    ERA  = ERA_rp,
    WHIP = WHIP_rp,
    W    = W_rp,
    K    = K_rp,
    SV   = SV_rp,
    stringsAsFactors = FALSE
  )

  all_cols <- c(
    "PLAYER_ID", "player_name", "position", "pos_eligibility", "league", "role",
    "HR", "R", "RBI", "SB", "AB", "AVG",
    "IP", "ERA", "WHIP", "W", "K", "SV"
  )
  projections <- rbind(hitters[, all_cols], sp_df[, all_cols], rp_df[, all_cols])
  rownames(projections) <- NULL

  config <- make_sim_config(n_teams)

  # ----- REPLACEMENT STAT LINES -------------------------------------------
  # Per sim-spec §1.2: RS[c] = the n_rostered-th highest value (n_rostered-th
  # LOWEST for ERA/WHIP).

  # Roster the top n_rostered_hitters hitters and n_rostered_pitchers pitchers
  hitter_proj  <- projections[projections$position %in% names(HITTER_SLOTS_DEFAULT), ]
  sp_proj      <- projections[projections$position == "SP", ]
  rp_proj      <- projections[projections$position == "RP", ]

  # Sort hitters by multi-cat zscore proxy (sum of z-scores)
  # Simple proxy: rank on total counting stat sum + AVG
  hitter_score <- with(hitter_proj,
    scale_safe(HR) + scale_safe(R) + scale_safe(RBI) + scale_safe(SB) + scale_safe(AVG))
  hitter_ranked  <- hitter_proj[order(hitter_score, decreasing = TRUE), ]
  rostered_hitters <- hitter_ranked[seq_len(min(n_rostered_hitters, nrow(hitter_ranked))), ]

  # Sort pitchers: SP by IP-adjusted ERA+WHIP (lower is better), RP similarly
  sp_score <- sp_proj$ERA + sp_proj$WHIP  # lower is better composite
  sp_ranked <- sp_proj[order(sp_score), ]   # ascending = best first
  n_sp_roster <- n_teams * PITCHER_SLOTS_DEFAULT["SP"]
  rostered_sp <- sp_ranked[seq_len(min(n_sp_roster, nrow(sp_ranked))), ]

  rp_score <- rp_proj$ERA + rp_proj$WHIP
  rp_ranked <- rp_proj[order(rp_score), ]
  n_rp_roster <- n_teams * PITCHER_SLOTS_DEFAULT["RP"]
  rostered_rp <- rp_ranked[seq_len(min(n_rp_roster, nrow(rp_ranked))), ]

  rostered_pitchers <- rbind(rostered_sp, rostered_rp)
  rostered_all      <- rbind(rostered_hitters, rostered_pitchers)

  # ----- REPLACEMENT STATS DATA FRAME -------------------------------------
  # Build per-position replacement stat lines.
  # For the simulation harness we construct a simplified per-position table.
  # Replacement stat = last-rostered player's value in each category.

  # For hitters, find the boundary value in each category across rostered pool
  # (n_rostered_hitters-th value in that category across the rostered hitter pool)
  boundary_hitter_idx <- nrow(rostered_hitters)
  # Sort rostered hitters by each stat and take the boundary value
  rs_HR  <- sort(rostered_hitters$HR,  decreasing = TRUE)[boundary_hitter_idx]
  rs_R   <- sort(rostered_hitters$R,   decreasing = TRUE)[boundary_hitter_idx]
  rs_RBI <- sort(rostered_hitters$RBI, decreasing = TRUE)[boundary_hitter_idx]
  rs_SB  <- sort(rostered_hitters$SB,  decreasing = TRUE)[boundary_hitter_idx]
  rs_AVG <- sort(rostered_hitters$AVG, decreasing = TRUE)[boundary_hitter_idx]

  # For pitchers: ERA/WHIP lower is better
  n_pit_boundary <- nrow(rostered_pitchers)
  rs_ERA  <- sort(rostered_pitchers$ERA,  decreasing = FALSE)[n_pit_boundary]
  rs_WHIP <- sort(rostered_pitchers$WHIP, decreasing = FALSE)[n_pit_boundary]
  rs_W    <- sort(rostered_pitchers$W,    decreasing = TRUE)[n_pit_boundary]
  rs_K    <- sort(rostered_pitchers$K,    decreasing = TRUE)[n_pit_boundary]
  rs_SV   <- sort(rostered_pitchers$SV,   decreasing = TRUE)[n_pit_boundary]

  # Build a unified position-level replacement_stats frame
  # (one row for "HITTERS" and one for "SP" and one for "RP" is the minimal
  # structure needed for pvm() input, which works at category level, not
  # per-position level for the scoring formula).
  #
  # pvm() extracts replacement stats via the `replacement_stats` data.frame
  # and then aggregates across positions. For the simulation we provide one
  # row per position group (hitters, SP, RP).

  replacement_stats <- data.frame(
    position = c("HITTER", "SP", "RP"),
    HR   = c(rs_HR,   NA_real_, NA_real_),
    R    = c(rs_R,    NA_real_, NA_real_),
    RBI  = c(rs_RBI,  NA_real_, NA_real_),
    SB   = c(rs_SB,   NA_real_, NA_real_),
    AVG  = c(rs_AVG,  NA_real_, NA_real_),
    W    = c(NA_real_, rs_W,    rs_W),
    K    = c(NA_real_, rs_K,    rs_K),
    SV   = c(NA_real_, rs_SV,   rs_SV),
    ERA  = c(NA_real_, rs_ERA,  rs_ERA),
    WHIP = c(NA_real_, rs_WHIP, rs_WHIP),
    stringsAsFactors = FALSE
  )

  # ----- POSITION ASSIGNMENTS --------------------------------------------
  # Named character vector: PLAYER_ID (as character) -> position
  # pvm() looks up via as.character(projections$PLAYER_ID), so keys must be
  # the integer PLAYER_ID values coerced to character (e.g., "1", "2", ...).
  pos_assign <- stats::setNames(
    rostered_all$position,
    as.character(rostered_all$PLAYER_ID)
  )

  # ----- BUILD REPLACEMENT OBJECT ----------------------------------------
  result <- list(
    replacement_stats       = replacement_stats,
    positional_adjustments  = NULL,
    cliff_metric            = data.frame(position = character(0),
                                          stringsAsFactors = FALSE),
    two_way_players         = character(0),
    pool_diagnostics        = list(),
    method                  = "boundary_band",
    params                  = list(
      multi_pos = "best",
      n_teams   = n_teams
    )
  )

  attr(result, "stat_units")          <- "raw_projected"
  attr(result, "config")              <- config
  attr(result, "projections")         <- projections
  attr(result, "position_assignments") <- pos_assign
  attr(result, "rostered_hitters")    <- rostered_hitters
  attr(result, "rostered_pitchers")   <- rostered_pitchers
  attr(result, "rostered_all")        <- rostered_all

  if (!is.null(baseline)) {
    attr(result, "baseline") <- baseline
  }

  result
}


#' Helper: safe scale (returns zeros if sd == 0).
#' @noRd
scale_safe <- function(x) {
  x[is.na(x)] <- 0
  s <- stats::sd(x, na.rm = TRUE)
  if (is.na(s) || s == 0) return(rep(0, length(x)))
  (x - mean(x, na.rm = TRUE)) / s
}


# ---------------------------------------------------------------------------
# DGP for Study 4: Concentration Warning Threshold
# ---------------------------------------------------------------------------

#' Generate DGP for Study 4 — concentration warning threshold calibration.
#'
#' Constructs a replacement object where the dominant player's SV share equals
#' approximately `target_share` of Pool[SV]. The dominant player is the first
#' entry of the rostered pitcher pool.
#'
#' @param seed Integer. Set at call start.
#' @param n_teams Integer. Team count.
#' @param target_share Numeric in (0, 1). Desired dominant player share of
#'   pool SV.
#' @return A replacement_level()-compatible object (same structure as dgp_pvm()).
#' @noRd
dgp_pvm_study4 <- function(seed, n_teams = 12L, target_share = 0.30) {
  set.seed(seed, kind = "L'Ecuyer-CMRG")

  n_teams <- as.integer(n_teams)
  n_rp_roster <- n_teams * PITCHER_SLOTS_DEFAULT["RP"]
  n_sp_roster <- n_teams * PITCHER_SLOTS_DEFAULT["SP"]

  # Build base projections using dgp_pvm() with same seed; then override SV
  base <- dgp_pvm(seed, n_teams = n_teams)
  projections  <- attr(base, "projections")
  rostered_all <- attr(base, "rostered_all")

  # Identify rostered RPs (the pool that has saves)
  # For SV concentration, focus on the RP pool
  rostered_rp <- rostered_all[rostered_all$position == "RP", ]

  if (nrow(rostered_rp) < 2L) {
    # Fallback: just return base if no RPs (should not happen for n_teams >= 8)
    return(base)
  }

  # Compute "other players' SV pool" under target_share
  # target_share = dominant_SV / (dominant_SV + others_SV)
  # => dominant_SV = target_share * others_SV / (1 - target_share)
  # => if others_SV = S_other, dominant_SV = target_share * S_other / (1 - target_share)

  # Assign equal SV to non-dominant rostered RPs
  n_others     <- nrow(rostered_rp) - 1L
  # Use a fixed per-player others SV of 5 (easily dominated by the target)
  per_other_sv <- 5L
  S_other      <- n_others * per_other_sv
  dominant_sv  <- round(target_share * S_other / (1 - target_share))
  dominant_sv  <- max(dominant_sv, 1L)   # ensure non-negative

  # Assign: first RP in rostered_rp gets dominant_sv, rest get per_other_sv
  # Key by PLAYER_ID (integer) — consistent with pvm() lookup convention.
  dominant_id  <- rostered_rp$PLAYER_ID[1L]
  other_ids    <- rostered_rp$PLAYER_ID[-1L]

  # Update projections SV for these players
  projections$SV[projections$PLAYER_ID == dominant_id]  <- dominant_sv
  projections$SV[projections$PLAYER_ID %in% other_ids]  <- per_other_sv
  # Non-rostered pitchers get SV = 0 to avoid contaminating the pool
  non_rostered_pitchers <- projections$position %in% c("SP", "RP") &
    !(projections$PLAYER_ID %in% rostered_all$PLAYER_ID)
  projections$SV[non_rostered_pitchers] <- 0L

  # Also update rostered_all to reflect the new SV values.
  # The rostered_all snapshot from base still has original SV values;
  # we must propagate the override so pvm() sees the correct distribution.
  rostered_all$SV[rostered_all$PLAYER_ID == dominant_id]  <- dominant_sv
  rostered_all$SV[rostered_all$PLAYER_ID %in% other_ids]  <- per_other_sv

  # Also update rostered_pitchers (SP and RP subset)
  rostered_pitchers <- attr(base, "rostered_pitchers")
  rostered_pitchers$SV[rostered_pitchers$PLAYER_ID == dominant_id]  <- dominant_sv
  rostered_pitchers$SV[rostered_pitchers$PLAYER_ID %in% other_ids]  <- per_other_sv

  # Recompute replacement stat for SV from updated rostered pool
  n_pit_boundary <- nrow(rostered_pitchers)
  rs_SV_new <- sort(rostered_pitchers$SV, decreasing = TRUE)[n_pit_boundary]
  rs_new <- base$replacement_stats
  rs_new$SV[rs_new$position %in% c("SP", "RP")] <- rs_SV_new

  # Rebuild base with updated attributes
  result <- base
  attr(result, "projections")        <- projections
  attr(result, "rostered_all")       <- rostered_all
  attr(result, "rostered_pitchers")  <- rostered_pitchers
  result$replacement_stats           <- rs_new

  # Annotate dominant player info for diagnostics
  attr(result, "study4_dominant_id")   <- dominant_id
  attr(result, "study4_target_share")  <- target_share
  attr(result, "study4_dominant_sv")   <- dominant_sv
  attr(result, "study4_S_other")       <- S_other

  result
}
