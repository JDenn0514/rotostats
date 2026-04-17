# DGP-E: Rank Invariance (Study E)
#
# Generates a pitcher pool with a fixed focal pitcher F and a random complement
# pool. The focal pitcher has fixed projections; complement is drawn from DGP-A
# pitcher model. Two league configurations: 10-team and 15-team.
#
# Based on sim-spec.md §2.4.
#
# Usage:
#   projections <- dgp_e(seed = 12345, n_teams = 10)
#
# Returns a data frame where the focal pitcher is always the first row.
# Caller identifies focal pitcher by player_name == "FOCAL_F".
#
# Column-schema notes (replacement_level() interface):
#   - player_name  : required (NOT "name")
#   - league       : required; mixed league = 50/50 AL/NL split
#   - pos_eligibility: pipe-delimited ("|").

# Fixed focal pitcher projections.
# ERA=4.70, WHIP=1.40 are set at approximately the 10-team boundary quality
# level so that the extra complement pitchers added for a 15-team league
# (drawn from the same N(3.80, 0.45) ERA distribution) are predominantly
# better than the focal pitcher.  When ~28-30 of the 30 extra pitchers
# outrank focal, focal's absolute rank increases by approximately the
# boundary shift (30), keeping rank_vs_boundary invariant across league sizes.
# Choosing a below-average focal pitcher (ERA > pool mean 3.80) is the
# design requirement for rank-invariance; see follow-up-fix-2 in implementation.md.
.FOCAL_PITCHER <- list(
  ERA  = 4.70,
  WHIP = 1.40,
  IP   = 165,
  W    = 8L,
  K    = 130L,
  SV   = 0L
)

#' Generate DGP-E projection data frame.
#'
#' @param seed Integer seed.
#' @param n_teams Number of teams (10 or 15).
#' @return A data frame with focal pitcher F as the first row and a random
#'   complement pitcher pool. All players have \code{position = "SP"} or
#'   \code{"RP"}; hitter columns are \code{NA}.
#' @noRd
dgp_e <- function(seed, n_teams) {
  set.seed(seed)

  sp_slots   <- 6L
  rp_slots   <- 3L
  # Total SP needed = n_teams * sp_slots + K (K=3 buffer per sim-spec.md §2.4)
  n_sp_total <- n_teams * sp_slots + 3L  # +3 buffer
  n_complement_sp <- n_sp_total - 1L     # focal pitcher takes 1 slot

  # ---- Complement SP ----------------------------------------------------- #
  # Draw from DGP-A SP distribution (no swingmen for simplicity; rank study
  # doesn't depend on swingman flagging)
  IP_SP   <- pmin(pmax(round(stats::rnorm(n_complement_sp, 170, 15)), 120L), 230L)
  ERA_SP  <- pmin(pmax(stats::rnorm(n_complement_sp, 3.80, 0.45), 2.50), 6.00)
  WHIP_SP <- pmin(pmax(stats::rnorm(n_complement_sp, 1.22, 0.10), 0.90), 1.80)
  K9_SP   <- pmin(pmax(stats::rnorm(n_complement_sp, 8.5, 1.2), 4.0), 14.0)
  W_SP    <- stats::rpois(n_complement_sp, lambda = IP_SP / 9 * 0.44)
  K_SP    <- round(IP_SP * K9_SP / 9)

  # Focal pitcher row
  focal_df <- data.frame(
    player_id       = 1L,
    player_name     = "FOCAL_F",
    position        = "SP",
    pos_eligibility = "SP",
    league          = "AL",
    role            = "SP",
    HR = NA_real_, R = NA_real_, RBI = NA_real_, SB = NA_real_,
    H  = NA_real_, AB = NA_real_, AVG = NA_real_,
    IP   = .FOCAL_PITCHER$IP,
    ERA  = .FOCAL_PITCHER$ERA,
    WHIP = .FOCAL_PITCHER$WHIP,
    W    = .FOCAL_PITCHER$W,
    K    = .FOCAL_PITCHER$K,
    SV   = .FOCAL_PITCHER$SV,
    stringsAsFactors = FALSE
  )

  comp_df <- data.frame(
    player_id       = seq.int(2L, n_complement_sp + 1L),
    player_name     = paste0("SP_C_", seq_len(n_complement_sp)),
    position        = "SP",
    pos_eligibility = "SP",
    league          = rep_len(c("AL", "NL"), n_complement_sp),
    role            = "SP",
    HR = NA_real_, R = NA_real_, RBI = NA_real_, SB = NA_real_,
    H  = NA_real_, AB = NA_real_, AVG = NA_real_,
    IP   = IP_SP,
    ERA  = ERA_SP,
    WHIP = WHIP_SP,
    W    = W_SP,
    K    = K_SP,
    SV   = rep(0L, n_complement_sp),
    stringsAsFactors = FALSE
  )

  # ---- RP ---------------------------------------------------------------- #
  # Need at least n_teams * rp_slots + K_band_buffer (7 for K=3). Add 10 headroom.
  n_rp <- n_teams * rp_slots + 10L
  IP_RP   <- pmin(pmax(round(stats::rnorm(n_rp, 62, 8)), 30L), 90L)
  ERA_RP  <- pmin(pmax(stats::rnorm(n_rp, 3.50, 0.65), 1.50), 7.00)
  WHIP_RP <- pmin(pmax(stats::rnorm(n_rp, 1.22, 0.15), 0.80), 2.00)
  K9_RP   <- pmin(pmax(stats::rnorm(n_rp, 9.0, 1.5), 4.0), 15.0)
  W_RP    <- stats::rpois(n_rp, lambda = IP_RP / 9 * 0.30)
  K_RP    <- round(IP_RP * K9_RP / 9)
  n_closers <- min(3L, n_rp)
  SV_RP   <- c(stats::rpois(n_closers, 30), rep(0L, n_rp - n_closers))

  rp_df <- data.frame(
    player_id       = seq.int(n_complement_sp + 2L, n_complement_sp + 1L + n_rp),
    player_name     = paste0("RP_", seq_len(n_rp)),
    position        = "RP",
    pos_eligibility = "RP",
    league          = rep_len(c("AL", "NL"), n_rp),
    role            = "RP",
    HR = NA_real_, R = NA_real_, RBI = NA_real_, SB = NA_real_,
    H  = NA_real_, AB = NA_real_, AVG = NA_real_,
    IP   = IP_RP,  ERA  = ERA_RP,  WHIP = WHIP_RP,
    W    = W_RP,   K    = K_RP,    SV   = SV_RP,
    stringsAsFactors = FALSE
  )

  # ---- Hitters (minimal, required so replacement_level() doesn't error) -- #
  # Use scaled hitter pool based on n_teams. Minimal for Study E purposes.
  # 6 positions * n_teams players + some buffer
  n_hitter_pos <- c(C=1L, `1B`=1L, `2B`=1L, `3B`=1L, SS=1L, OF=3L, UTIL=1L)
  hitter_rows <- vector("list", length(n_hitter_pos))
  pid <- n_complement_sp + 1L + n_rp
  pos_names <- names(n_hitter_pos)

  mu_hr  <- c(C=14, `1B`=24, `2B`=16, `3B`=22, SS=15, OF=20, UTIL=18)
  mu_r   <- c(C=55, `1B`=72, `2B`=72, `3B`=70, SS=70, OF=75, UTIL=65)
  mu_rbi <- c(C=55, `1B`=78, `2B`=62, `3B`=75, SS=62, OF=70, UTIL=65)
  mu_sb  <- c(C=3,  `1B`=5,  `2B`=12, `3B`=8,  SS=16, OF=14, UTIL=8)
  t_avg  <- c(C=0.248,`1B`=0.265,`2B`=0.268,`3B`=0.262,SS=0.265,OF=0.268,UTIL=0.260)

  for (i in seq_along(pos_names)) {
    pos <- pos_names[i]
    # n_players = n_teams * slots[pos] + 10 buffer (K=3 band needs +7 minimum)
    n_p  <- n_teams * n_hitter_pos[i] + 10L
    hr_p <- sort(stats::rpois(n_p, mu_hr[pos]),  decreasing = TRUE)
    r_p  <- sort(stats::rpois(n_p, mu_r[pos]),   decreasing = TRUE)
    rbi_p<- sort(stats::rpois(n_p, mu_rbi[pos]), decreasing = TRUE)
    sb_p <- sort(stats::rpois(n_p, mu_sb[pos]),  decreasing = TRUE)
    ab_p <- pmin(pmax(round(stats::rnorm(n_p, 450, 40)), 200L), 600L)
    h_p  <- stats::rbinom(n_p, size = ab_p, prob = t_avg[pos])

    hitter_rows[[i]] <- data.frame(
      player_id = seq.int(pid + 1L, pid + n_p),
      player_name = paste0(pos, "_", seq_len(n_p)),
      position  = pos,
      pos_eligibility = pos,
      league    = rep_len(c("AL", "NL"), n_p),
      role      = NA_character_,
      HR = hr_p, R = r_p, RBI = rbi_p, SB = sb_p,
      H  = h_p,  AB = ab_p, AVG = h_p / ab_p,
      IP = NA_real_, ERA = NA_real_, WHIP = NA_real_,
      W  = NA_real_, K   = NA_real_, SV   = NA_real_,
      stringsAsFactors = FALSE
    )
    pid <- pid + n_p
  }

  hitters <- do.call(rbind, hitter_rows)

  all_cols <- c(
    "player_id", "player_name", "position", "pos_eligibility", "league", "role",
    "HR", "R", "RBI", "SB", "H", "AB", "AVG",
    "IP", "ERA", "WHIP", "W", "K", "SV"
  )
  out <- rbind(focal_df[, all_cols], comp_df[, all_cols],
               rp_df[, all_cols],    hitters[, all_cols])
  rownames(out) <- NULL
  out
}
