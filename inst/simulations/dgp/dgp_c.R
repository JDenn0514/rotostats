# DGP-C: Multi-Eligible Pool (Study C)
#
# Generates a synthetic projection data frame stress-testing the multi-position
# reassignment loop. 60% of non-C, non-OF hitters are multi-eligible.
#
# Based on sim-spec.md §2.2.
#
# Usage:
#   projections <- dgp_c(seed = 12345)
#
# Returns a data frame in the same format as dgp_a() but with elevated
# multi-eligibility among infielders.

# DGP-C uses the DGP-A talent parameters but with elevated multi-eligibility.
# Sourcing dgp_a.R provides .HITTER_PARAMS, .MULTI_ELIG_PAIRS, .MULTI_ELIG_PROBS.

# DGP-C-specific multi-eligibility pairs (per sim-spec.md §2.2)
.DGPC_PAIRS <- list(
  c("2B", "SS"),  # 40%
  c("1B", "3B"),  # 35%
  c("2B", "3B")   # 25%
)
.DGPC_PROBS <- c(0.40, 0.35, 0.25)

#' Generate one DGP-C projection data frame.
#'
#' @param seed Integer seed for reproducibility.
#' @return A data frame suitable for passing to \code{replacement_level()} as
#'   \code{projections}.
#' @noRd
dgp_c <- function(seed) {
  set.seed(seed)

  # ---- Hitters (n = 130) ------------------------------------------------- #
  # Use a subset of DGP-A position breakdown, scaled to 130 total
  # Position breakdown (scaled): C=15, 1B=15, 2B=20, 3B=20, SS=20, OF=30, UTIL=10
  pos_params <- data.frame(
    position  = c("C",  "1B", "2B", "3B", "SS", "OF", "UTIL"),
    n_players = c(15L,  15L,  20L,  20L,  20L,  30L,  10L),
    mu_HR     = c(14,   24,   16,   22,   15,   20,   18),
    mu_R      = c(55,   72,   72,   70,   70,   75,   65),
    mu_RBI    = c(55,   78,   62,   75,   62,   70,   65),
    mu_SB     = c(3,    5,    12,   8,    16,   14,   8),
    true_avg  = c(0.248,0.265,0.268,0.262,0.265,0.268,0.260),
    stringsAsFactors = FALSE
  )

  hitter_rows <- vector("list", nrow(pos_params))
  player_counter <- 0L

  for (i in seq_len(nrow(pos_params))) {
    p  <- pos_params[i, ]
    n  <- p$n_players

    true_HR  <- sort(stats::rpois(n, p$mu_HR),  decreasing = TRUE)
    true_R   <- sort(stats::rpois(n, p$mu_R),   decreasing = TRUE)
    true_RBI <- sort(stats::rpois(n, p$mu_RBI), decreasing = TRUE)
    true_SB  <- sort(stats::rpois(n, p$mu_SB),  decreasing = TRUE)

    ab_raw <- round(stats::rnorm(n, 450, 40))
    AB     <- pmin(pmax(ab_raw, 200L), 600L)
    H      <- stats::rbinom(n, size = AB, prob = p$true_avg)
    AVG    <- H / AB

    player_counter <- player_counter + n
    ids <- seq.int(player_counter - n + 1L, player_counter)

    hitter_rows[[i]] <- data.frame(
      player_id       = ids,
      name            = paste0(p$position, "_", seq_len(n)),
      position        = p$position,
      pos_eligibility = p$position,
      HR  = true_HR,
      R   = true_R,
      RBI = true_RBI,
      SB  = true_SB,
      H   = H,
      AB  = AB,
      AVG = AVG,
      stringsAsFactors = FALSE
    )
  }

  hitters <- do.call(rbind, hitter_rows)

  # Assign secondary eligibility to 60% of 2B, 3B, SS, 1B players
  # (per sim-spec.md §2.2: "applies to 2B, 3B, SS, 1B players")
  multi_elig_pos <- c("2B", "3B", "SS", "1B")
  eligible_idx <- which(hitters$position %in% multi_elig_pos)
  n_multi <- round(length(eligible_idx) * 0.60)
  if (n_multi > 0) {
    multi_idx <- sample(eligible_idx, n_multi, replace = FALSE)
    pair_draw <- sample(
      seq_along(.DGPC_PAIRS),
      n_multi,
      replace = TRUE,
      prob = .DGPC_PROBS
    )
    for (k in seq_len(n_multi)) {
      player_pos <- hitters$position[multi_idx[k]]
      pair       <- .DGPC_PAIRS[[pair_draw[k]]]
      sec_pos    <- setdiff(pair, player_pos)
      if (length(sec_pos) == 0L) sec_pos <- pair[2L]
      hitters$pos_eligibility[multi_idx[k]] <-
        paste(player_pos, sec_pos[1L], sep = "/")
    }
  }

  # ---- Pitchers (same structure as DGP-A) -------------------------------- #
  n_sp    <- 40L
  n_swing <- 4L
  n_sp_reg <- n_sp - n_swing

  IP_SP   <- pmin(pmax(round(stats::rnorm(n_sp_reg, 170, 15)), 120L), 230L)
  ERA_SP  <- pmin(pmax(stats::rnorm(n_sp_reg, 3.80, 0.45), 2.50), 6.00)
  WHIP_SP <- pmin(pmax(stats::rnorm(n_sp_reg, 1.22, 0.10), 0.90), 1.80)
  K9_SP   <- pmin(pmax(stats::rnorm(n_sp_reg, 8.5, 1.2), 4.0), 14.0)
  W_SP    <- stats::rpois(n_sp_reg, lambda = IP_SP / 9 * 0.44)
  K_SP    <- round(IP_SP * K9_SP / 9)
  SV_SP   <- rep(0L, n_sp_reg)

  IP_sw   <- pmin(pmax(round(stats::rnorm(n_swing, 95, 8)), 80L), 120L)
  ERA_sw  <- pmin(pmax(stats::rnorm(n_swing, 3.80, 0.45), 2.50), 6.00)
  WHIP_sw <- pmin(pmax(stats::rnorm(n_swing, 1.22, 0.10), 0.90), 1.80)
  K9_sw   <- pmin(pmax(stats::rnorm(n_swing, 8.5, 1.2), 4.0), 14.0)
  W_sw    <- stats::rpois(n_swing, lambda = IP_sw / 9 * 0.44)
  K_sw    <- round(IP_sw * K9_sw / 9)
  SV_sw   <- rep(0L, n_swing)

  IP_all_sp   <- c(IP_SP, IP_sw)
  ERA_all_sp  <- c(ERA_SP, ERA_sw)
  WHIP_all_sp <- c(WHIP_SP, WHIP_sw)
  W_all_sp    <- c(W_SP, W_sw)
  K_all_sp    <- c(K_SP, K_sw)
  SV_all_sp   <- c(SV_SP, SV_sw)
  sp_ord <- order(IP_all_sp, decreasing = TRUE)
  player_counter <- player_counter + n_sp
  sp_ids <- seq.int(player_counter - n_sp + 1L, player_counter)

  sp_df <- data.frame(
    player_id       = sp_ids,
    name            = paste0("SP_", seq_len(n_sp)),
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

  n_rp     <- 25L
  n_closers <- 3L
  IP_RP   <- pmin(pmax(round(stats::rnorm(n_rp, 62, 8)), 30L), 90L)
  ERA_RP  <- pmin(pmax(stats::rnorm(n_rp, 3.50, 0.65), 1.50), 7.00)
  WHIP_RP <- pmin(pmax(stats::rnorm(n_rp, 1.22, 0.15), 0.80), 2.00)
  K9_RP   <- pmin(pmax(stats::rnorm(n_rp, 9.0, 1.5), 4.0), 15.0)
  W_RP    <- stats::rpois(n_rp, lambda = IP_RP / 9 * 0.30)
  K_RP    <- round(IP_RP * K9_RP / 9)
  SV_RP   <- c(stats::rpois(n_closers, 30), rep(0L, n_rp - n_closers))
  rp_ord  <- order(IP_RP, decreasing = TRUE)
  player_counter <- player_counter + n_rp
  rp_ids  <- seq.int(player_counter - n_rp + 1L, player_counter)

  rp_df <- data.frame(
    player_id       = rp_ids,
    name            = paste0("RP_", seq_len(n_rp)),
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

  # Merge
  hitter_cols_not_in_pitcher <- c("HR", "R", "RBI", "SB", "H", "AB", "AVG")
  pitcher_cols_not_in_hitter <- c("role", "IP", "ERA", "WHIP", "W", "K", "SV")

  for (col in hitter_cols_not_in_pitcher) {
    sp_df[[col]] <- NA_real_
    rp_df[[col]] <- NA_real_
  }
  for (col in pitcher_cols_not_in_hitter) {
    hitters[[col]] <- NA_real_
  }
  hitters$role <- NA_character_

  all_cols <- c(
    "player_id", "name", "position", "pos_eligibility", "role",
    "HR", "R", "RBI", "SB", "H", "AB", "AVG",
    "IP", "ERA", "WHIP", "W", "K", "SV"
  )
  out <- rbind(hitters[, all_cols], sp_df[, all_cols], rp_df[, all_cols])
  rownames(out) <- NULL
  out
}
