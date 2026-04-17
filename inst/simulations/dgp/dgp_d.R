# DGP-D: Thin AL-Only Pools (Study D)
#
# Two sub-DGPs for the dynamic K cap study:
#   Sub-DGP D1: 12-team AL SS (n_ss_eligible = 20)
#   Sub-DGP D2: 12-team AL C  (n_c_eligible  = 20)
#   Sub-DGP D3: 5-team SS     (exploratory; n_ss_eligible = 12)
#
# Based on sim-spec.md §2.3.
#
# Usage:
#   projections <- dgp_d(seed = 12345, sub_dgp = "D1")
#
# Returns a full projection data frame (hitters + pitchers) that can be passed
# to replacement_level(). The position under test (SS or C) is deliberately
# thin so that K_eff < K_default is possible for the 5-team case.

#' Generate DGP-D projection data frame.
#'
#' @param seed Integer seed.
#' @param sub_dgp One of \code{"D1"} (12-team AL SS), \code{"D2"} (12-team AL C),
#'   or \code{"D3"} (5-team SS).
#' @return A data frame with a thin position pool, ready for \code{replacement_level()}.
#' @noRd
dgp_d <- function(seed, sub_dgp = c("D1", "D2", "D3")) {
  sub_dgp <- match.arg(sub_dgp)
  set.seed(seed)

  # Determine configuration
  if (sub_dgp == "D1") {
    thin_pos     <- "SS"
    n_thin       <- 20L   # total SS-eligible players
    n_teams_thin <- 12L
    other_hitter_pos <- c("C", "1B", "2B", "3B", "OF", "DH", "UTIL")
  } else if (sub_dgp == "D2") {
    thin_pos     <- "C"
    n_thin       <- 20L
    n_teams_thin <- 12L
    other_hitter_pos <- c("SS", "1B", "2B", "3B", "OF", "DH", "UTIL")
  } else {  # D3: 5-team SS
    thin_pos     <- "SS"
    n_thin       <- 12L   # only 12 SS; K_eff = floor(5/4) = 1 for K=3
    n_teams_thin <- 5L
    other_hitter_pos <- c("C", "1B", "2B", "3B", "OF", "DH", "UTIL")
  }

  # -- Thin position pool -------------------------------------------------
  # Clear talent gradient with bimodal gap near boundary rank
  # For D1 (12-team SS): boundary at rank 12; create gap between rank 12 and 13
  # For D2 (12-team C): sharper drop-off after rank 10
  # For D3 (5-team SS): boundary at rank 5; K_eff = 1

  n_above <- if (sub_dgp == "D2") 10L else n_teams_thin  # boundary rank
  n_below <- n_thin - n_above

  # Above-boundary players: good talent (above average)
  mu_hr_above <- if (thin_pos == "SS") 18 else 16
  hr_above  <- sort(stats::rpois(n_above, mu_hr_above), decreasing = TRUE)
  r_above   <- sort(stats::rpois(n_above, 72),          decreasing = TRUE)
  rbi_above <- sort(stats::rpois(n_above, 64),          decreasing = TRUE)
  sb_above  <- sort(stats::rpois(n_above, 18),          decreasing = TRUE)
  ab_above  <- pmin(pmax(round(stats::rnorm(n_above, 480, 30)), 200L), 600L)
  h_above   <- stats::rbinom(n_above, size = ab_above, prob = 0.265)
  avg_above <- h_above / ab_above

  # Below-boundary players: talent gap (notably weaker)
  # D2 (C) has sharper drop; others moderate gap
  mu_hr_below <- if (sub_dgp == "D2") 9 else if (thin_pos == "SS") 11 else 12
  hr_below  <- sort(stats::rpois(n_below, mu_hr_below), decreasing = TRUE)
  r_below   <- sort(stats::rpois(n_below, 52),          decreasing = TRUE)
  rbi_below <- sort(stats::rpois(n_below, 45),          decreasing = TRUE)
  sb_below  <- sort(stats::rpois(n_below, 10),          decreasing = TRUE)
  ab_below  <- pmin(pmax(round(stats::rnorm(n_below, 380, 50)), 200L), 550L)
  h_below   <- stats::rbinom(n_below, size = ab_below, prob = 0.248)
  avg_below <- h_below / ab_below

  thin_df <- data.frame(
    player_id       = seq_len(n_thin),
    name            = paste0(thin_pos, "_", seq_len(n_thin)),
    position        = thin_pos,
    pos_eligibility = thin_pos,
    role            = NA_character_,
    HR  = c(hr_above, hr_below),
    R   = c(r_above, r_below),
    RBI = c(rbi_above, rbi_below),
    SB  = c(sb_above, sb_below),
    H   = c(h_above, h_below),
    AB  = c(ab_above, ab_below),
    AVG = c(avg_above, avg_below),
    IP = NA_real_, ERA = NA_real_, WHIP = NA_real_,
    W  = NA_real_, K   = NA_real_, SV   = NA_real_,
    stringsAsFactors = FALSE
  )

  # -- Other hitter positions ---------------------------------------------- #
  other_params <- data.frame(
    position  = other_hitter_pos,
    n_players = rep(15L, length(other_hitter_pos)),
    mu_HR     = c(14, 24, 16, 22, 20, 18, 18)[seq_along(other_hitter_pos)],
    mu_R      = c(55, 72, 72, 70, 75, 70, 65)[seq_along(other_hitter_pos)],
    mu_RBI    = c(55, 78, 62, 75, 70, 68, 65)[seq_along(other_hitter_pos)],
    mu_SB     = c(3,  5,  12, 8,  14, 10, 8) [seq_along(other_hitter_pos)],
    true_avg  = c(0.248, 0.265, 0.268, 0.262, 0.268, 0.262, 0.260)[
                 seq_along(other_hitter_pos)],
    stringsAsFactors = FALSE
  )

  pid <- n_thin
  other_rows <- vector("list", nrow(other_params))
  for (i in seq_len(nrow(other_params))) {
    p <- other_params[i, ]
    n <- p$n_players
    hr  <- sort(stats::rpois(n, p$mu_HR), decreasing = TRUE)
    r   <- sort(stats::rpois(n, p$mu_R),  decreasing = TRUE)
    rbi <- sort(stats::rpois(n, p$mu_RBI),decreasing = TRUE)
    sb  <- sort(stats::rpois(n, p$mu_SB), decreasing = TRUE)
    ab  <- pmin(pmax(round(stats::rnorm(n, 450, 40)), 200L), 600L)
    h   <- stats::rbinom(n, size = ab, prob = p$true_avg)

    other_rows[[i]] <- data.frame(
      player_id       = seq.int(pid + 1L, pid + n),
      name            = paste0(p$position, "_", seq_len(n)),
      position        = p$position,
      pos_eligibility = p$position,
      role            = NA_character_,
      HR  = hr, R = r, RBI = rbi, SB = sb,
      H   = h,  AB = ab, AVG = h / ab,
      IP = NA_real_, ERA = NA_real_, WHIP = NA_real_,
      W  = NA_real_, K   = NA_real_, SV   = NA_real_,
      stringsAsFactors = FALSE
    )
    pid <- pid + n
  }
  other_hitters <- do.call(rbind, other_rows)

  # -- Pitchers ------------------------------------------------------------ #
  n_sp <- 40L
  n_rp <- 25L

  IP_SP   <- pmin(pmax(round(stats::rnorm(n_sp, 170, 15)), 120L), 230L)
  ERA_SP  <- pmin(pmax(stats::rnorm(n_sp, 3.80, 0.45), 2.50), 6.00)
  WHIP_SP <- pmin(pmax(stats::rnorm(n_sp, 1.22, 0.10), 0.90), 1.80)
  K9_SP   <- pmin(pmax(stats::rnorm(n_sp, 8.5, 1.2), 4.0), 14.0)
  W_SP    <- stats::rpois(n_sp, lambda = IP_SP / 9 * 0.44)
  K_SP    <- round(IP_SP * K9_SP / 9)
  sp_ord  <- order(IP_SP, decreasing = TRUE)
  sp_df <- data.frame(
    player_id = seq.int(pid + 1L, pid + n_sp),
    name      = paste0("SP_", seq_len(n_sp)),
    position  = "SP", pos_eligibility = "SP", role = "SP",
    HR = NA_real_, R = NA_real_, RBI = NA_real_, SB = NA_real_,
    H  = NA_real_, AB = NA_real_, AVG = NA_real_,
    IP   = IP_SP[sp_ord],   ERA  = ERA_SP[sp_ord],
    WHIP = WHIP_SP[sp_ord], W    = W_SP[sp_ord],
    K    = K_SP[sp_ord],    SV   = rep(0L, n_sp),
    stringsAsFactors = FALSE
  )
  pid <- pid + n_sp

  IP_RP    <- pmin(pmax(round(stats::rnorm(n_rp, 62, 8)), 30L), 90L)
  ERA_RP   <- pmin(pmax(stats::rnorm(n_rp, 3.50, 0.65), 1.50), 7.00)
  WHIP_RP  <- pmin(pmax(stats::rnorm(n_rp, 1.22, 0.15), 0.80), 2.00)
  K9_RP    <- pmin(pmax(stats::rnorm(n_rp, 9.0, 1.5), 4.0), 15.0)
  W_RP     <- stats::rpois(n_rp, lambda = IP_RP / 9 * 0.30)
  K_RP     <- round(IP_RP * K9_RP / 9)
  SV_RP    <- c(stats::rpois(3L, 30), rep(0L, n_rp - 3L))
  rp_ord   <- order(IP_RP, decreasing = TRUE)
  rp_df <- data.frame(
    player_id = seq.int(pid + 1L, pid + n_rp),
    name      = paste0("RP_", seq_len(n_rp)),
    position  = "RP", pos_eligibility = "RP", role = "RP",
    HR = NA_real_, R = NA_real_, RBI = NA_real_, SB = NA_real_,
    H  = NA_real_, AB = NA_real_, AVG = NA_real_,
    IP   = IP_RP[rp_ord],   ERA  = ERA_RP[rp_ord],
    WHIP = WHIP_RP[rp_ord], W    = W_RP[rp_ord],
    K    = K_RP[rp_ord],    SV   = SV_RP[rp_ord],
    stringsAsFactors = FALSE
  )

  all_cols <- c(
    "player_id", "name", "position", "pos_eligibility", "role",
    "HR", "R", "RBI", "SB", "H", "AB", "AVG",
    "IP", "ERA", "WHIP", "W", "K", "SV"
  )
  out <- rbind(thin_df[, all_cols], other_hitters[, all_cols],
               sp_df[, all_cols],   rp_df[, all_cols])
  rownames(out) <- NULL
  out
}
