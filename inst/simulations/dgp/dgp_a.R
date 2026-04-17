# DGP-A: Projection Perturbation
# Used in Studies A and B.
#
# Generates a synthetic projection data frame with realistic talent distributions
# for 150 hitters and 135 pitchers (85 SP + 50 RP), then applies multiplicative
# noise (sigma_proj = 0.10) to simulate year-over-year projection variability.
# Pool sizing: 12-team × 6 SP = 72 rostered; 85 provides 13-player headroom.
#              12-team × 3 RP = 36 rostered; 50 provides 14-player headroom.
#
# Usage:
#   projections <- dgp_a(seed = 12345, sigma_proj = 0.10)
#
# Returns a data frame with columns:
#   player_id, player_name, position, pos_eligibility, league, role (pitchers),
#   HR, R, RBI, SB, H, AB, AVG  (hitters)
#   IP, ERA, WHIP, W, K, SV     (pitchers)
#
# Parameters are defined in sim-spec.md §2.1.
#
# Column-schema notes (replacement_level() interface):
#   - player_name  : required (NOT "name")
#   - league       : required; "AL" or "NL" only (mixed league = 50/50 split)
#   - pos_eligibility: pipe-delimited ("|"), not slash-delimited ("/").

# Position-level talent parameters for hitters
.HITTER_PARAMS <- data.frame(
  position  = c("C",   "1B",  "2B",  "3B",  "SS",  "OF",  "UTIL"),
  n_players = c(15L,   15L,   15L,   15L,   15L,   60L,   15L),
  mu_HR     = c(14,    24,    16,    22,    15,    20,    18),
  mu_R      = c(55,    72,    72,    70,    70,    75,    65),
  mu_RBI    = c(55,    78,    62,    75,    62,    70,    65),
  mu_SB     = c(3,     5,     12,    8,     16,    14,    8),
  true_avg  = c(0.248, 0.265, 0.268, 0.262, 0.265, 0.268, 0.260),
  stringsAsFactors = FALSE
)

# Multi-eligibility draw distribution (empirical NFBC AL-only)
.MULTI_ELIG_PAIRS <- list(
  c("2B", "SS"),  # 30%
  c("1B", "3B"),  # 25%
  c("OF", "1B"),  # 20%
  c("2B", "3B"),  # 15%
  c("3B", "SS")   # 10% ("other" — represented as 3B/SS here)
)
.MULTI_ELIG_PROBS <- c(0.30, 0.25, 0.20, 0.15, 0.10)

#' Generate one DGP-A projection data frame.
#'
#' @param seed Integer seed for reproducibility. MUST be set before each call.
#' @param sigma_proj Coefficient of variation for multiplicative noise. Default 0.10.
#' @param multi_eligible_fraction Fraction of eligible hitters assigned a second
#'   position. Default 0.20.
#' @return A data frame suitable for passing to \code{replacement_level()} as
#'   \code{projections}.
#' @noRd
dgp_a <- function(seed, sigma_proj = 0.10, multi_eligible_fraction = 0.20) {
  set.seed(seed)

  # ---- Hitters ----------------------------------------------------------- #
  hitter_rows <- vector("list", nrow(.HITTER_PARAMS))
  player_counter <- 0L

  for (i in seq_len(nrow(.HITTER_PARAMS))) {
    p   <- .HITTER_PARAMS[i, ]
    n   <- p$n_players

    # True talent draws (deterministic order for gradient)
    # Talent gradient: draw n players, sort descending so rank 1 is best
    true_HR  <- sort(stats::rpois(n, p$mu_HR),  decreasing = TRUE)
    true_R   <- sort(stats::rpois(n, p$mu_R),   decreasing = TRUE)
    true_RBI <- sort(stats::rpois(n, p$mu_RBI), decreasing = TRUE)
    true_SB  <- sort(stats::rpois(n, p$mu_SB),  decreasing = TRUE)

    # AB: Normal(450, 40^2), clamp [200, 600]
    ab_raw <- round(stats::rnorm(n, mean = 450, sd = 40))
    AB     <- pmin(pmax(ab_raw, 200L), 600L)

    # H drawn from Binomial given true_avg
    H   <- stats::rbinom(n, size = AB, prob = p$true_avg)

    # Apply projection noise
    eps_HR  <- stats::rnorm(n, 0, sigma_proj)
    eps_R   <- stats::rnorm(n, 0, sigma_proj)
    eps_RBI <- stats::rnorm(n, 0, sigma_proj)
    eps_SB  <- stats::rnorm(n, 0, sigma_proj)
    # AVG noise applied by perturbing H draw
    eps_H   <- stats::rnorm(n, 0, sigma_proj)

    HR_proj  <- pmax(0, round(true_HR  * (1 + eps_HR)))
    R_proj   <- pmax(0, round(true_R   * (1 + eps_R)))
    RBI_proj <- pmax(0, round(true_RBI * (1 + eps_RBI)))
    SB_proj  <- pmax(0, round(true_SB  * (1 + eps_SB)))
    H_proj   <- pmax(0L, round(H * (1 + eps_H)))
    H_proj   <- pmin(H_proj, AB)   # H cannot exceed AB
    AVG_proj <- H_proj / AB

    player_counter <- player_counter + n
    ids <- seq.int(player_counter - n + 1L, player_counter)

    hitter_rows[[i]] <- data.frame(
      player_id       = ids,
      player_name     = paste0(p$position, "_", seq_len(n)),
      position        = p$position,
      pos_eligibility = p$position,   # primary; secondary added below
      HR  = HR_proj,
      R   = R_proj,
      RBI = RBI_proj,
      SB  = SB_proj,
      H   = H_proj,
      AB  = AB,
      AVG = AVG_proj,
      stringsAsFactors = FALSE
    )
  }

  hitters <- do.call(rbind, hitter_rows)

  # Assign secondary eligibility to ~20% of hitters
  # Only hitters with a "partner" position get secondary eligibility
  non_c_of_idx <- which(hitters$position %in% c("2B", "3B", "SS", "1B", "UTIL"))
  n_multi <- round(length(non_c_of_idx) * multi_eligible_fraction)
  if (n_multi > 0) {
    multi_idx <- sample(non_c_of_idx, n_multi)
    pair_draw <- sample(
      seq_along(.MULTI_ELIG_PAIRS),
      n_multi,
      replace = TRUE,
      prob = .MULTI_ELIG_PROBS
    )
    for (k in seq_len(n_multi)) {
      player_pos <- hitters$position[multi_idx[k]]
      pair       <- .MULTI_ELIG_PAIRS[[pair_draw[k]]]
      # Use the OTHER position in the pair as the secondary
      sec_pos <- setdiff(pair, player_pos)
      if (length(sec_pos) == 0L) sec_pos <- pair[2L]  # fallback
      hitters$pos_eligibility[multi_idx[k]] <-
        paste(player_pos, sec_pos[1L], sep = "|")
    }
  }

  # ---- Pitchers ---------------------------------------------------------- #
  # Pool sizing: 12-team × 6 SP slots = 72 rostered + K=3 band buffer (7 players)
  # = 79 minimum. Use 85 for headroom.
  n_sp    <- 85L
  n_swing <- 4L   # swingmen (IP ~ N(95, 8^2), clamp 80-120); included in n_sp
  n_sp_reg <- n_sp - n_swing

  # Regular SP
  IP_SP   <- pmin(pmax(round(stats::rnorm(n_sp_reg, 170, 15)), 120L), 230L)
  ERA_SP  <- pmin(pmax(stats::rnorm(n_sp_reg, 3.80, 0.45), 2.50), 6.00)
  WHIP_SP <- pmin(pmax(stats::rnorm(n_sp_reg, 1.22, 0.10), 0.90), 1.80)
  K9_SP   <- pmin(pmax(stats::rnorm(n_sp_reg, 8.5, 1.2), 4.0), 14.0)
  W_SP    <- stats::rpois(n_sp_reg, lambda = IP_SP / 9 * 0.44)
  K_SP    <- round(IP_SP * K9_SP / 9)
  SV_SP   <- rep(0L, n_sp_reg)

  # Swingmen
  IP_sw   <- pmin(pmax(round(stats::rnorm(n_swing, 95, 8)), 80L), 120L)
  ERA_sw  <- pmin(pmax(stats::rnorm(n_swing, 3.80, 0.45), 2.50), 6.00)
  WHIP_sw <- pmin(pmax(stats::rnorm(n_swing, 1.22, 0.10), 0.90), 1.80)
  K9_sw   <- pmin(pmax(stats::rnorm(n_swing, 8.5, 1.2), 4.0), 14.0)
  W_sw    <- stats::rpois(n_swing, lambda = IP_sw / 9 * 0.44)
  K_sw    <- round(IP_sw * K9_sw / 9)
  SV_sw   <- rep(0L, n_swing)

  # Combine and sort by talent (IP proxy for SP quality here)
  IP_all_sp   <- c(IP_SP, IP_sw)
  ERA_all_sp  <- c(ERA_SP, ERA_sw)
  WHIP_all_sp <- c(WHIP_SP, WHIP_sw)
  W_all_sp    <- c(W_SP, W_sw)
  K_all_sp    <- c(K_SP, K_sw)
  SV_all_sp   <- c(SV_SP, SV_sw)
  # Sort descending by IP (talent proxy)
  sp_ord <- order(IP_all_sp, decreasing = TRUE)
  player_counter <- player_counter + n_sp
  sp_ids <- seq.int(player_counter - n_sp + 1L, player_counter)

  sp_df <- data.frame(
    player_id       = sp_ids,
    player_name     = paste0("SP_", seq_len(n_sp)),
    position        = "SP",
    pos_eligibility = "SP",
    role            = "SP",
    IP   = IP_all_sp[sp_ord],
    ERA  = ERA_all_sp[sp_ord],
    WHIP = WHIP_all_sp[sp_ord],
    W    = W_all_sp[sp_ord],
    K    = K_all_sp[sp_ord],
    SV   = SV_all_sp[sp_ord],
    stringsAsFactors = FALSE
  )

  # RP: 12-team × 3 RP slots = 36 rostered + K=3 band buffer (7) = 43 minimum.
  # Use 50 for headroom.
  n_rp  <- 50L
  n_closers <- 3L  # top 3 RP (closers) drawn with saves
  n_rp_reg  <- n_rp - n_closers

  IP_RP       <- pmin(pmax(round(stats::rnorm(n_rp, 62, 8)), 30L), 90L)
  ERA_RP      <- pmin(pmax(stats::rnorm(n_rp, 3.50, 0.65), 1.50), 7.00)
  WHIP_RP     <- pmin(pmax(stats::rnorm(n_rp, 1.22, 0.15), 0.80), 2.00)
  K9_RP       <- pmin(pmax(stats::rnorm(n_rp, 9.0, 1.5), 4.0), 15.0)
  W_RP        <- stats::rpois(n_rp, lambda = IP_RP / 9 * 0.30)
  K_RP        <- round(IP_RP * K9_RP / 9)
  # Top 3 get saves, others 0
  SV_RP       <- c(stats::rpois(n_closers, 30), rep(0L, n_rp - n_closers))
  # Sort by IP descending (talent proxy)
  rp_ord <- order(IP_RP, decreasing = TRUE)
  player_counter <- player_counter + n_rp
  rp_ids <- seq.int(player_counter - n_rp + 1L, player_counter)

  rp_df <- data.frame(
    player_id       = rp_ids,
    player_name     = paste0("RP_", seq_len(n_rp)),
    position        = "RP",
    pos_eligibility = "RP",
    role            = "RP",
    IP   = IP_RP[rp_ord],
    ERA  = ERA_RP[rp_ord],
    WHIP = WHIP_RP[rp_ord],
    W    = W_RP[rp_ord],
    K    = K_RP[rp_ord],
    SV   = SV_RP[rp_ord],
    stringsAsFactors = FALSE
  )

  # ---- Merge and return -------------------------------------------------- #
  # Add NA columns so rbind works across hitters/pitchers
  hitter_cols_not_in_pitcher <- c("HR", "R", "RBI", "SB", "H", "AB", "AVG")
  pitcher_cols_not_in_hitter <- c("role", "IP", "ERA", "WHIP", "W", "K", "SV")

  for (col in hitter_cols_not_in_pitcher) {
    sp_df[[col]] <- NA_real_
    rp_df[[col]] <- NA_real_
  }
  for (col in pitcher_cols_not_in_hitter) {
    hitters[[col]] <- NA_real_
  }
  # role for hitters
  hitters$role <- NA_character_

  # league column: mixed league = alternate AL/NL by row so pool is 50/50.
  # replacement_level() requires "AL" or "NL" (no "mixed" value accepted).
  assign_league_mixed <- function(n) {
    rep_len(c("AL", "NL"), n)
  }
  hitters$league <- assign_league_mixed(nrow(hitters))
  sp_df$league   <- assign_league_mixed(nrow(sp_df))
  rp_df$league   <- assign_league_mixed(nrow(rp_df))

  all_cols <- c(
    "player_id", "player_name", "position", "pos_eligibility", "league", "role",
    "HR", "R", "RBI", "SB", "H", "AB", "AVG",
    "IP", "ERA", "WHIP", "W", "K", "SV"
  )
  out <- rbind(hitters[, all_cols], sp_df[, all_cols], rp_df[, all_cols])
  rownames(out) <- NULL
  out
}
