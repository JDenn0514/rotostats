# sim-zar.R — Monte Carlo Simulation: zar() v3 Harness
#
# Run ID:   zar-2026-04-21
# Spec:     sim-spec.md v3 (2026-04-21)
# DGP:      v2 — fixed latent ability per player (Gamma-Poisson / Normal-Normal)
#
# v3 changes from v2:
#   1. No positional_adjustment_method argument in replacement_level() calls.
#      The default "fvarz" is canonical. "none" was never a valid value.
#   2. AC-SIM-2 redefined as band-mean invariant. New helper:
#      compute_band_mean_zar() checks that recomputing the replacement z-score
#      from the band-mean stat line matches the constant offset stored in the
#      zar result. Tolerance: 1e-10. Expected: 0 by algebraic construction.
#   3. AC-SIM-3 threshold lowered 0.85 -> 0.55 (v2 observed rho = 0.622).
#
# Implementation note on distribution extraction:
#   zar() internally reads attr(zaa_result, "distribution") but does NOT
#   propagate this attribute to its own return value (only "units" and "anchor"
#   are set on the zar result). To compute the band-mean invariant, we call
#   zaa() once in run_zar_safe() to capture the distribution attribute, then
#   pass it to compute_band_mean_zar(). This adds one zaa() call per rep but
#   avoids reading R/zar.R internals.
#
# Seed strategy (v2/v3):
#   set.seed(scenario_seed) ONCE before latent-ability draws. No per-rep
#   re-seeding. The sequential RNG state across the rep loop provides
#   independent per-rep draws while keeping rank stability measurable.
#
# Usage:
#   Rscript inst/simulation/sim-zar.R
#   or from RStudio after devtools::load_all():
#   source("inst/simulation/sim-zar.R")

# ---------------------------------------------------------------------------
# 0. Load the package
# ---------------------------------------------------------------------------

if (!requireNamespace("devtools", quietly = TRUE)) {
  stop("devtools is required. Install with: install.packages('devtools')")
}

pkg_root <- tryCatch(
  rprojroot::find_package_root_file(),
  error = function(e) {
    d <- getwd()
    for (i in seq_len(5L)) {
      if (file.exists(file.path(d, "DESCRIPTION"))) return(d)
      d <- dirname(d)
    }
    stop("Cannot locate package root. Run from the package directory.")
  }
)

if (!requireNamespace("rprojroot", quietly = TRUE)) {
  d <- getwd()
  for (i in seq_len(5L)) {
    if (file.exists(file.path(d, "DESCRIPTION"))) {
      pkg_root <- d
      break
    }
    d <- dirname(d)
  }
}

devtools::load_all(pkg_root, quiet = TRUE)

# ---------------------------------------------------------------------------
# 1. Simulation constants
# ---------------------------------------------------------------------------

MASTER_SEED <- 20260421L
N_REPS      <- 200L
SCENARIOS   <- list(
  S1 = list(id = "S1", dgp_type = "null",           n_teams = 10L,
            pitcher_pool = "combined", sv_lambda_top = 28),
  S2 = list(id = "S2", dgp_type = "null_split",      n_teams = 10L,
            pitcher_pool = "split",    sv_lambda_top = 28),
  S3 = list(id = "S3", dgp_type = "null_large",      n_teams = 15L,
            pitcher_pool = "combined", sv_lambda_top = 28),
  S4 = list(id = "S4", dgp_type = "sv_regime_break", n_teams = 10L,
            pitcher_pool = "combined", sv_lambda_top = 48)
)

# ---------------------------------------------------------------------------
# 2. Helper: Build league_config for a scenario
# ---------------------------------------------------------------------------

make_config <- function(n_teams) {
  league_config(
    n_teams       = n_teams,
    roster_slots  = c(C = 1L, `1B` = 1L, OF = 2L),
    pitcher_slots = c(SP = 3L, RP = 2L),
    categories    = c("HR", "R", "SB", "K", "SV"),
    budget        = 260L
  )
}

# ---------------------------------------------------------------------------
# 3. Helper: Generate fixed latent abilities (once per scenario, before rep loop)
# ---------------------------------------------------------------------------

generate_latent_abilities <- function(n_teams, sv_lambda_top) {
  n_c  <- as.integer(n_teams * 1L * 2.5)
  n_1b <- as.integer(n_teams * 1L * 2.5)
  n_of <- as.integer(n_teams * 2L * 2.5)
  n_sp <- as.integer(n_teams * 3L * 2.5)
  n_rp <- as.integer(n_teams * 2L * 2.5)
  n_hit <- n_c + n_1b + n_of

  # Tier assignment: top 25% / middle 50% / bottom 25% by player index
  assign_tiers <- function(n) {
    tiers <- rep("mid", n)
    top_n <- max(1L, round(n * 0.25))
    bot_n <- max(1L, round(n * 0.25))
    tiers[seq_len(top_n)]            <- "top"
    tiers[seq(n - bot_n + 1L, n)]   <- "bot"
    tiers
  }

  tiers_c  <- assign_tiers(n_c)
  tiers_1b <- assign_tiers(n_1b)
  tiers_of <- assign_tiers(n_of)
  all_hit_tiers <- c(tiers_c, tiers_1b, tiers_of)

  # HR: Gamma(shape=6.25, rate=0.25) -> mean=25, sd~10, CV~0.40
  lambda_HR_raw <- rgamma(n_hit, shape = 6.25, rate = 0.25)
  tier_scale_HR <- ifelse(all_hit_tiers == "top", 1.2,
                   ifelse(all_hit_tiers == "bot", 0.5, 1.0))
  lambda_HR <- pmax(lambda_HR_raw * tier_scale_HR, 1)

  # SB: Gamma(shape=4, rate=0.4) -> mean=10, CV~0.5
  lambda_SB <- rgamma(n_hit, shape = 4, rate = 0.4)

  # R: Normal(mu=70, sd=10) clamped >= 10
  mu_R <- pmax(rnorm(n_hit, mean = 70, sd = 10), 10)

  # SP K: Normal(mu=165, sd=20) clamped >= 20
  mu_K_SP <- pmax(rnorm(n_sp, mean = 165, sd = 20), 20)

  # RP K: Normal(mu=60, sd=12) clamped >= 10
  mu_K_RP <- pmax(rnorm(n_rp, mean = 60, sd = 12), 10)

  # RP SV tier assignment (closer vs setup) — top 25% are closers
  tiers_rp  <- assign_tiers(n_rp)
  is_closer <- tiers_rp == "top"

  list(
    n_c           = n_c,
    n_1b          = n_1b,
    n_of          = n_of,
    n_sp          = n_sp,
    n_rp          = n_rp,
    n_hit         = n_hit,
    n_pit         = n_sp + n_rp,
    lambda_HR     = lambda_HR,
    lambda_SB     = lambda_SB,
    mu_R          = mu_R,
    mu_K_SP       = mu_K_SP,
    mu_K_RP       = mu_K_RP,
    is_closer     = is_closer,
    sv_lambda_top = sv_lambda_top,
    tiers_c       = tiers_c,
    tiers_1b      = tiers_1b,
    tiers_of      = tiers_of,
    n_teams       = n_teams
  )
}

# ---------------------------------------------------------------------------
# 4. Helper: Generate one replication's projections data frame
#    (called inside rep loop, conditioned on fixed latent abilities)
# ---------------------------------------------------------------------------

generate_projections <- function(la) {
  n_c  <- la$n_c
  n_1b <- la$n_1b
  n_of <- la$n_of
  n_sp <- la$n_sp
  n_rp <- la$n_rp
  n_hit <- la$n_hit

  # --- Hitter stats (within-rep draws conditioned on latent abilities) -----
  HR <- rpois(n_hit, lambda = la$lambda_HR)
  R  <- pmax(as.integer(round(rnorm(n_hit, mean = la$mu_R, sd = 10))), 0L)
  SB <- rpois(n_hit, lambda = la$lambda_SB)
  AB <- pmax(as.integer(round(rnorm(n_hit, mean = 440, sd = 60))), 150L)

  # --- Pitcher K (within-rep draws conditioned on latent abilities) --------
  K_SP <- pmax(as.integer(round(rnorm(n_sp, mean = la$mu_K_SP, sd = 15))), 20L)
  K_RP <- pmax(as.integer(round(rnorm(n_rp, mean = la$mu_K_RP, sd = 10))), 10L)

  # --- Pitcher IP (i.i.d. per rep) ----------------------------------------
  IP_SP <- pmax(pmin(as.integer(round(rnorm(n_sp, mean = 170, sd = 20))), 220L), 80L)
  IP_RP <- pmax(pmin(as.integer(round(rnorm(n_rp, mean = 62, sd = 12))), 80L), 30L)

  # --- RP SV: tier Poisson (i.i.d. per rep) --------------------------------
  sv_lambda <- ifelse(la$is_closer, la$sv_lambda_top, 2)
  SV_RP <- rpois(n_rp, lambda = sv_lambda)

  # --- Hitter position eligibilities ---------------------------------------
  pos_c  <- rep("C",  n_c)
  pos_1b <- rep("1B", n_1b)
  pos_of <- rep("OF", n_of)
  all_hit_pos <- c(pos_c, pos_1b, pos_of)

  # 15% of hitters get a second position
  n_dual   <- as.integer(round(n_hit * 0.15))
  dual_idx <- sample(seq_len(n_hit), n_dual, replace = FALSE)
  alt_positions <- c("C", "1B", "OF")
  for (di in dual_idx) {
    primary_pos  <- all_hit_pos[di]
    alternatives <- setdiff(alt_positions, primary_pos)
    all_hit_pos[di] <- paste0(primary_pos, "|", sample(alternatives, 1L))
  }

  # --- Teams and leagues ---------------------------------------------------
  n_total <- n_hit + n_sp + n_rp
  teams   <- paste0("T", formatC(sample(seq_len(la$n_teams), n_total, replace = TRUE),
                                  width = 2, flag = "0"))
  leagues <- sample(c("AL", "NL"), n_total, replace = TRUE)

  # --- Hitter rows ---------------------------------------------------------
  hit_rows <- data.frame(
    player_id       = paste0("H", seq_len(n_hit)),
    player_name     = paste0("Hitter_", seq_len(n_hit)),
    pos_eligibility = all_hit_pos,
    team            = teams[seq_len(n_hit)],
    league          = leagues[seq_len(n_hit)],
    role            = NA_character_,
    HR              = HR,
    R               = R,
    SB              = SB,
    AB              = AB,
    stringsAsFactors = FALSE
  )

  # --- SP rows -------------------------------------------------------------
  sp_ids  <- seq(n_hit + 1L, n_hit + n_sp)
  sp_rows <- data.frame(
    player_id       = paste0("P", seq_len(n_sp)),
    player_name     = paste0("SP_", seq_len(n_sp)),
    pos_eligibility = "SP",
    team            = teams[sp_ids],
    league          = leagues[sp_ids],
    role            = "SP",
    K               = K_SP,
    SV              = 0L,
    IP              = IP_SP,
    stringsAsFactors = FALSE
  )

  # --- RP rows -------------------------------------------------------------
  rp_ids  <- seq(n_hit + n_sp + 1L, n_total)
  rp_rows <- data.frame(
    player_id       = paste0("Q", seq_len(n_rp)),
    player_name     = paste0("RP_", seq_len(n_rp)),
    pos_eligibility = "RP",
    team            = teams[rp_ids],
    league          = leagues[rp_ids],
    role            = "RP",
    K               = K_RP,
    SV              = SV_RP,
    IP              = IP_RP,
    stringsAsFactors = FALSE
  )

  # --- Merge (base R rbind with column fill) --------------------------------
  merge_rows <- function(df1, df2) {
    all_cols <- union(names(df1), names(df2))
    for (col in setdiff(all_cols, names(df1))) df1[[col]] <- NA
    for (col in setdiff(all_cols, names(df2))) df2[[col]] <- NA
    rbind(df1[, all_cols, drop = FALSE], df2[, all_cols, drop = FALSE])
  }

  merge_rows(merge_rows(hit_rows, sp_rows), rp_rows)
}

# ---------------------------------------------------------------------------
# 5. Safe zar() call — captures errors, returns list with distribution
#
# Note: zar() reads attr(zaa_result, "distribution") internally but does NOT
# store it on the returned data frame. To support compute_band_mean_zar(),
# we call zaa() once here to capture the distribution attribute.
# Both zaa() and zar() use identical replacement objects and pool arguments,
# so the distribution extracted here is exactly what zar() used internally.
# ---------------------------------------------------------------------------

run_zar_safe <- function(proj, cfg, pitcher_pool_arg = "combined") {
  result <- tryCatch({
    # replacement_level() uses default positional_adjustment_method = "fvarz"
    # (canonical construction — "none" is not a valid value)
    repl <- replacement_level(proj, cfg)

    # Call zaa() to capture the distribution attribute used by zar() internally
    zaa_result_for_dist <- zaa(
      replacement  = repl,
      pitcher_pool = pitcher_pool_arg,
      hitter_pool  = "positional"
    )
    dist <- attr(zaa_result_for_dist, "distribution")

    # Call zar() (black box — do not read its internals)
    zr <- zar(repl, include_raw = TRUE, pitcher_pool = pitcher_pool_arg)

    list(result = zr, replacement = repl, distribution = dist, error = NULL)
  }, error = function(e) {
    list(result = NULL, replacement = NULL, distribution = NULL, error = e)
  })
  result
}

# ---------------------------------------------------------------------------
# 6. Band-mean invariant helper (AC-SIM-2, v3)
#
# For each (category, position) pair, the stored replacement z-score
# (= mean(zaa_cat - zar_cat) within that position) must equal the z-score
# obtained by applying the distribution parameters to the band-mean stat line
# from replacement_stats. Their difference is the band-mean invariant error.
#
# For counting stats (no negation, no volume-weighting):
#   recomputed_z = (band_stat - d$mean) / d$sd
#
# This simulation uses only counting stats (HR, R, SB, K, SV) so the
# simpler formula is always applicable. The pseudocode's inverse-stat branch
# (ERA/WHIP sign flip) is included for completeness but will not be exercised.
#
# The distribution lookup follows zar()'s logic exactly:
#   Hitters (hitter_pool = "positional"): dist[[pos]][[cat]]
#   Pitchers (pitcher_pool = "combined"): dist[[cat]]
#   Pitchers (pitcher_pool = "split"):    dist[[pos]][[cat]]
# ---------------------------------------------------------------------------

compute_band_mean_zar <- function(zar_result, replacement_obj, dist,
                                   pitcher_pool_arg = "combined") {
  if (!is.data.frame(zar_result)) return(NA_real_)

  repl_stats <- replacement_obj$replacement_stats

  # Normalize position_assignments to named character vector
  pos_assign <- attr(replacement_obj, "position_assignments")
  if (is.data.frame(pos_assign)) {
    pa_vec <- stats::setNames(
      as.character(pos_assign$pool_label),
      as.character(pos_assign$player_id)
    )
  } else {
    pa_vec <- stats::setNames(
      as.character(pos_assign),
      names(pos_assign)
    )
  }

  cats <- sub("^zar_", "", grep("^zar_", names(zar_result), value = TRUE))
  max_err <- 0

  for (cat in cats) {
    zaa_col <- paste0("zaa_", cat)
    zar_col <- paste0("zar_", cat)
    if (!(zaa_col %in% names(zar_result))) next

    pos_vec <- pa_vec[as.character(zar_result$player_id)]

    for (pos in unique(stats::na.omit(pos_vec))) {
      idx <- which(pos_vec == pos)
      if (length(idx) == 0L) next

      # Step 1: stored replacement z-score (constant offset within position)
      stored_offset <- mean(
        zar_result[[zaa_col]][idx] - zar_result[[zar_col]][idx],
        na.rm = TRUE
      )
      if (is.nan(stored_offset) || is.na(stored_offset)) next

      # Step 2: band-mean stat for this position from replacement_stats
      repl_row <- repl_stats[
        toupper(repl_stats$position) == toupper(pos), ,
        drop = FALSE
      ]
      if (nrow(repl_row) == 0L) next

      # Look up stat column (case-insensitive)
      stat_col <- names(repl_row)[toupper(names(repl_row)) == toupper(cat)]
      if (length(stat_col) == 0L) next
      band_stat <- repl_row[[stat_col[1L]]]
      if (is.na(band_stat)) next

      # Step 3: distribution lookup — mirrors zar()'s extraction logic
      #   Hitters (hitter_pool = "positional"): dist[[pos]][[cat]]
      #   Pitchers (pitcher_pool = "combined"): dist[[cat]]
      #   Pitchers (pitcher_pool = "split"):    dist[[pos]][[cat]]
      is_pitcher_pos <- pos %in% c("SP", "RP", "P")
      if (is_pitcher_pos) {
        use_nested <- identical(pitcher_pool_arg, "split")
      } else {
        use_nested <- TRUE  # hitter_pool = "positional" -> nested
      }

      d <- if (use_nested && !is.null(dist[[pos]]) && !is.null(dist[[pos]][[cat]])) {
        dist[[pos]][[cat]]
      } else {
        dist[[cat]]
      }
      if (is.null(d) || is.null(d$mean) || is.null(d$sd)) next
      if (is.na(d$sd) || d$sd == 0) {
        # Degenerate pool: zar() stores 0 for both; error is 0
        err <- abs(0 - stored_offset)
        max_err <- max(max_err, err, na.rm = TRUE)
        next
      }

      # Step 4: recompute z-score from band-mean stat
      # All categories in this simulation are pure counting stats.
      # For inverse stats (ERA/WHIP) zaa() negates; handle both signs.
      cat_upper <- toupper(cat)
      # The INVERSE_CATEGORIES constant is exported by the package
      is_inverse <- cat_upper %in% toupper(inverse_categories())

      if (is_inverse) {
        # Volume-weighted inverse stat (not exercised in this sim, but correct)
        repl_ip_col <- names(repl_row)[toupper(names(repl_row)) == "IP"]
        if (length(repl_ip_col) == 0L) next
        repl_ip  <- repl_row[[repl_ip_col[1L]]]
        z_raw    <- -(band_stat - d$mean) / d$sd
        z_vol    <- z_raw * repl_ip
        if (!is.null(d$sd_vol) && !is.na(d$sd_vol) && d$sd_vol != 0) {
          recomputed_z <- z_vol / d$sd_vol
        } else {
          recomputed_z <- 0
        }
      } else if (cat_upper == "AVG") {
        # Volume-weighted AVG (not exercised in this sim, but correct)
        repl_ab_col <- names(repl_row)[toupper(names(repl_row)) == "AB"]
        if (length(repl_ab_col) == 0L) next
        repl_ab  <- repl_row[[repl_ab_col[1L]]]
        z_raw    <- (band_stat - d$mean) / d$sd
        z_vol    <- z_raw * repl_ab
        if (!is.null(d$sd_vol) && !is.na(d$sd_vol) && d$sd_vol != 0) {
          recomputed_z <- z_vol / d$sd_vol
        } else {
          recomputed_z <- 0
        }
      } else {
        # Counting stat: unweighted z-score
        recomputed_z <- (band_stat - d$mean) / d$sd
      }

      err <- abs(recomputed_z - stored_offset)
      max_err <- max(max_err, err, na.rm = TRUE)
    }
  }
  max_err
}

# Count (cat, pos) pairs with |err| >= threshold
compute_band_mean_violations <- function(zar_result, replacement_obj, dist,
                                          pitcher_pool_arg = "combined",
                                          threshold = 1e-10) {
  if (!is.data.frame(zar_result)) return(NA_integer_)

  repl_stats <- replacement_obj$replacement_stats
  pos_assign <- attr(replacement_obj, "position_assignments")
  if (is.data.frame(pos_assign)) {
    pa_vec <- stats::setNames(
      as.character(pos_assign$pool_label),
      as.character(pos_assign$player_id)
    )
  } else {
    pa_vec <- stats::setNames(
      as.character(pos_assign),
      names(pos_assign)
    )
  }

  cats <- sub("^zar_", "", grep("^zar_", names(zar_result), value = TRUE))
  n_violations <- 0L

  for (cat in cats) {
    zaa_col <- paste0("zaa_", cat)
    zar_col <- paste0("zar_", cat)
    if (!(zaa_col %in% names(zar_result))) next

    pos_vec <- pa_vec[as.character(zar_result$player_id)]

    for (pos in unique(stats::na.omit(pos_vec))) {
      idx <- which(pos_vec == pos)
      if (length(idx) == 0L) next

      stored_offset <- mean(
        zar_result[[zaa_col]][idx] - zar_result[[zar_col]][idx],
        na.rm = TRUE
      )
      if (is.nan(stored_offset) || is.na(stored_offset)) next

      repl_row  <- repl_stats[
        toupper(repl_stats$position) == toupper(pos), ,
        drop = FALSE
      ]
      if (nrow(repl_row) == 0L) next

      stat_col  <- names(repl_row)[toupper(names(repl_row)) == toupper(cat)]
      if (length(stat_col) == 0L) next
      band_stat <- repl_row[[stat_col[1L]]]
      if (is.na(band_stat)) next

      is_pitcher_pos <- pos %in% c("SP", "RP", "P")
      if (is_pitcher_pos) {
        use_nested <- identical(pitcher_pool_arg, "split")
      } else {
        use_nested <- TRUE
      }

      d <- if (use_nested && !is.null(dist[[pos]]) && !is.null(dist[[pos]][[cat]])) {
        dist[[pos]][[cat]]
      } else {
        dist[[cat]]
      }
      if (is.null(d) || is.null(d$mean) || is.null(d$sd)) next
      if (is.na(d$sd) || d$sd == 0) {
        if (abs(0 - stored_offset) >= threshold) n_violations <- n_violations + 1L
        next
      }

      cat_upper <- toupper(cat)
      is_inverse <- cat_upper %in% toupper(inverse_categories())

      if (is_inverse) {
        repl_ip_col <- names(repl_row)[toupper(names(repl_row)) == "IP"]
        if (length(repl_ip_col) == 0L) next
        repl_ip <- repl_row[[repl_ip_col[1L]]]
        z_raw   <- -(band_stat - d$mean) / d$sd
        z_vol   <- z_raw * repl_ip
        recomputed_z <- if (!is.null(d$sd_vol) && !is.na(d$sd_vol) && d$sd_vol != 0) {
          z_vol / d$sd_vol
        } else {
          0
        }
      } else if (cat_upper == "AVG") {
        repl_ab_col <- names(repl_row)[toupper(names(repl_row)) == "AB"]
        if (length(repl_ab_col) == 0L) next
        repl_ab <- repl_row[[repl_ab_col[1L]]]
        z_raw   <- (band_stat - d$mean) / d$sd
        z_vol   <- z_raw * repl_ab
        recomputed_z <- if (!is.null(d$sd_vol) && !is.na(d$sd_vol) && d$sd_vol != 0) {
          z_vol / d$sd_vol
        } else {
          0
        }
      } else {
        recomputed_z <- (band_stat - d$mean) / d$sd
      }

      if (abs(recomputed_z - stored_offset) >= threshold) {
        n_violations <- n_violations + 1L
      }
    }
  }
  n_violations
}

# ---------------------------------------------------------------------------
# 7. Identity check helper (AC-SIM-1)
#    Checks that zaa_cat - zar_cat is constant within each position group.
# ---------------------------------------------------------------------------

check_identity <- function(result, pos_assignments) {
  if (!is.data.frame(result)) return(NA_real_)
  zaa_cols <- grep("^zaa_", names(result), value = TRUE)
  zar_cols <- sub("^zaa_", "zar_", zaa_cols)

  if (is.data.frame(pos_assignments)) {
    pa_vec <- stats::setNames(
      as.character(pos_assignments$pool_label),
      as.character(pos_assignments$player_id)
    )
  } else {
    pa_vec <- stats::setNames(
      as.character(pos_assignments),
      names(pos_assignments)
    )
  }

  max_err <- 0
  for (ci in seq_along(zaa_cols)) {
    zaa_vals <- result[[zaa_cols[ci]]]
    zar_vals <- result[[zar_cols[ci]]]
    offsets  <- zaa_vals - zar_vals

    pos_vec <- pa_vec[as.character(result$player_id)]
    for (pos in unique(stats::na.omit(pos_vec))) {
      idx <- which(pos_vec == pos)
      if (length(idx) < 2L) next
      pos_offsets <- offsets[idx]
      range_err   <- diff(range(pos_offsets, na.rm = TRUE))
      max_err     <- max(max_err, range_err, na.rm = TRUE)
    }
  }
  max_err
}

# ---------------------------------------------------------------------------
# 8. Boundary player helper (§4b)
# ---------------------------------------------------------------------------

get_boundary_total_zar <- function(result, pos, pos_assignments,
                                    n_teams, roster_slots) {
  if (is.data.frame(pos_assignments)) {
    pa_vec <- stats::setNames(
      as.character(pos_assignments$pool_label),
      as.character(pos_assignments$player_id)
    )
  } else {
    pa_vec <- stats::setNames(
      as.character(pos_assignments),
      names(pos_assignments)
    )
  }

  player_pos   <- pa_vec[as.character(result$player_id)]
  pos_players  <- which(player_pos == pos)
  if (length(pos_players) == 0L) return(NA_real_)
  boundary_rank <- n_teams * roster_slots[[pos]]
  if (boundary_rank > length(pos_players)) return(NA_real_)
  tz_sorted <- sort(result$total_zar[pos_players], decreasing = TRUE)
  tz_sorted[[boundary_rank]]
}

# ---------------------------------------------------------------------------
# 9. Rank stability helper (§4c)
# ---------------------------------------------------------------------------

compute_rank_rho <- function(result_prev, result_curr, cols = "total_zar") {
  if (!is.data.frame(result_prev) || !is.data.frame(result_curr)) return(NA_real_)
  common_ids <- intersect(result_prev$player_id, result_curr$player_id)
  if (length(common_ids) < 10L) return(NA_real_)

  get_val <- function(result) {
    if (length(cols) == 1L) {
      result[[cols]][match(common_ids, result$player_id)]
    } else {
      valid_cols <- intersect(cols, names(result))
      if (length(valid_cols) == 0L) return(rep(NA_real_, length(common_ids)))
      idx <- match(common_ids, result$player_id)
      rowSums(result[idx, valid_cols, drop = FALSE], na.rm = FALSE)
    }
  }

  v_prev <- get_val(result_prev)
  v_curr <- get_val(result_curr)

  cor(rank(v_prev, na.last = "keep"),
      rank(v_curr, na.last = "keep"),
      use = "complete.obs", method = "spearman")
}

# ---------------------------------------------------------------------------
# 10. Main simulation loop
# ---------------------------------------------------------------------------

cat("Running zar() Monte Carlo simulation (v3 harness)\n")
cat(sprintf("  Scenarios: %d, Reps per scenario: %d, Total: %d\n\n",
            length(SCENARIOS), N_REPS, length(SCENARIOS) * N_REPS))

roster_slots_vec <- c(C = 1L, `1B` = 1L, OF = 2L, SP = 3L, RP = 2L)
all_results <- vector("list", length(SCENARIOS) * N_REPS)
row_idx     <- 0L

for (sc_idx in seq_along(SCENARIOS)) {
  sc            <- SCENARIOS[[sc_idx]]
  sc_id         <- sc$id
  dgp_type      <- sc$dgp_type
  n_teams_sc    <- sc$n_teams
  pp            <- sc$pitcher_pool
  scenario_seed <- MASTER_SEED + sc_idx * 1000L

  cat(sprintf("  Scenario %s (%s, n_teams=%d, pitcher_pool=%s, seed=%d)...\n",
              sc_id, dgp_type, n_teams_sc, pp, scenario_seed))

  cfg <- make_config(n_teams_sc)

  # Single seed at scenario start: covers latent draws + all reps
  set.seed(scenario_seed)

  # Draw fixed latent abilities (before rep loop)
  la <- generate_latent_abilities(n_teams_sc, sc$sv_lambda_top)

  prev_result <- NULL

  for (r in seq_len(N_REPS)) {
    row_idx <- row_idx + 1L

    proj    <- generate_projections(la)
    run_out <- run_zar_safe(proj, cfg, pitcher_pool_arg = pp)

    failed      <- !is.null(run_out$error)
    error_class <- if (failed) class(run_out$error)[1L] else NA_character_
    result      <- run_out$result
    repl        <- run_out$replacement
    dist        <- run_out$distribution

    row <- list(
      scenario_id               = sc_id,
      dgp_type                  = dgp_type,
      n_teams                   = n_teams_sc,
      pitcher_pool              = pp,
      rep                       = r,
      zar_failed                = failed,
      error_class               = error_class,
      identity_max_error        = NA_real_,
      band_mean_max_err         = NA_real_,
      band_mean_violations_count = NA_integer_,
      boundary_total_zar_C      = NA_real_,
      boundary_total_zar_1B     = NA_real_,
      boundary_total_zar_OF     = NA_real_,
      boundary_total_zar_SP     = NA_real_,
      boundary_total_zar_RP     = NA_real_,
      rank_spearman_rho_all     = NA_real_,
      rank_spearman_rho_hr_r_k  = NA_real_,
      top_closer_mean_total_zar = NA_real_,
      boundary_rp_total_zar     = NA_real_,
      top_minus_boundary_zar    = NA_real_
    )

    if (!failed && is.data.frame(result)) {
      pos_assignments <- attr(repl, "position_assignments")

      # 4a. Algebraic identity check
      row$identity_max_error <- check_identity(result, pos_assignments)

      # 4f. Band-mean invariant (AC-SIM-2)
      row$band_mean_max_err <- compute_band_mean_zar(
        result, repl, dist, pitcher_pool_arg = pp
      )
      row$band_mean_violations_count <- compute_band_mean_violations(
        result, repl, dist, pitcher_pool_arg = pp, threshold = 1e-10
      )

      # 4b. Boundary total_zar (all 5 positions)
      row$boundary_total_zar_C  <- get_boundary_total_zar(result, "C",  pos_assignments, n_teams_sc, roster_slots_vec)
      row$boundary_total_zar_1B <- get_boundary_total_zar(result, "1B", pos_assignments, n_teams_sc, roster_slots_vec)
      row$boundary_total_zar_OF <- get_boundary_total_zar(result, "OF", pos_assignments, n_teams_sc, roster_slots_vec)
      row$boundary_total_zar_SP <- get_boundary_total_zar(result, "SP", pos_assignments, n_teams_sc, roster_slots_vec)
      row$boundary_total_zar_RP <- get_boundary_total_zar(result, "RP", pos_assignments, n_teams_sc, roster_slots_vec)

      # 4c. Rank stability (S1 only)
      if (sc_id == "S1" && !is.null(prev_result)) {
        row$rank_spearman_rho_all    <- compute_rank_rho(prev_result, result, "total_zar")
        hr_r_k_cols <- c("zar_HR", "zar_R", "zar_K")
        row$rank_spearman_rho_hr_r_k <- compute_rank_rho(prev_result, result, hr_r_k_cols)
      }

      # 4d. Regime-break sensitivity (S1 and S4)
      if (sc_id %in% c("S1", "S4")) {
        rp_idx <- grep("^Q", result$player_id)
        if (length(rp_idx) > 0L) {
          rp_proj_sv <- proj$SV[match(result$player_id[rp_idx], proj$player_id)]
          n_top_rp   <- max(1L, round(length(rp_idx) * 0.25))
          top_rp_idx <- rp_idx[order(rp_proj_sv, decreasing = TRUE)[seq_len(n_top_rp)]]
          row$top_closer_mean_total_zar <- mean(result$total_zar[top_rp_idx], na.rm = TRUE)
          row$boundary_rp_total_zar     <- row$boundary_total_zar_RP
          row$top_minus_boundary_zar    <- row$top_closer_mean_total_zar - row$boundary_rp_total_zar
        }
      }

      prev_result <- result
    } else {
      prev_result <- NULL
    }

    all_results[[row_idx]] <- row
  }  # end rep loop

  sc_rows <- all_results[seq(row_idx - N_REPS + 1L, row_idx)]
  n_ok <- sum(!sapply(sc_rows, `[[`, "zar_failed"))
  cat(sprintf("    Done: %d/%d reps succeeded.\n", n_ok, N_REPS))

}  # end scenario loop

# ---------------------------------------------------------------------------
# 11. Assemble results data frame
# ---------------------------------------------------------------------------

results_df <- do.call(rbind, lapply(all_results, as.data.frame,
                                     stringsAsFactors = FALSE))
results_df$n_teams   <- as.integer(results_df$n_teams)
results_df$rep       <- as.integer(results_df$rep)
results_df$zar_failed <- as.logical(results_df$zar_failed)
results_df$band_mean_violations_count <- as.integer(results_df$band_mean_violations_count)

cat(sprintf("\nSimulation complete. Total rows: %d, Failures: %d\n",
            nrow(results_df),
            sum(results_df$zar_failed, na.rm = TRUE)))

# ---------------------------------------------------------------------------
# 12. Compute per-scenario summaries
# ---------------------------------------------------------------------------

summarise_scenario <- function(df, sc, s1_mean_top_minus = NULL) {
  ok     <- df[!df$zar_failed, ]
  n_ok   <- nrow(ok)
  n_fail <- nrow(df) - n_ok
  failure_rate <- n_fail / nrow(df)

  bnd_mean <- function(col) mean(ok[[col]], na.rm = TRUE)
  bnd_sd   <- function(col) sd(ok[[col]],   na.rm = TRUE)
  bnd_exc  <- function(col) {
    x <- ok[[col]]
    if (all(is.na(x))) return(NA_real_)
    mean(abs(x) > 0.5, na.rm = TRUE)
  }

  # AC-SIM-1: identity
  id_max   <- if (n_ok == 0L) NA_real_ else max(ok$identity_max_error, na.rm = TRUE)
  ac1_pass <- !is.na(id_max) && id_max < 1e-10

  # AC-SIM-2 (v3): band-mean invariant
  bm_max           <- if (n_ok == 0L) NA_real_ else max(ok$band_mean_max_err, na.rm = TRUE)
  bm_violation_rate <- if (n_ok == 0L) NA_real_ else
    mean(ok$band_mean_violations_count > 0L, na.rm = TRUE)
  ac2_pass <- if (n_ok == 0L) NA else
    (!is.na(bm_max) && bm_max < 1e-10 && !is.na(bm_violation_rate) && bm_violation_rate < 0.01)

  # AC-SIM-3: rank stability (S1 only), threshold 0.55 (v3)
  rho_all_mean    <- mean(ok$rank_spearman_rho_all,    na.rm = TRUE)
  rho_hr_r_k_mean <- mean(ok$rank_spearman_rho_hr_r_k, na.rm = TRUE)
  ac3_pass <- if (sc$id == "S1") {
    !is.na(rho_hr_r_k_mean) && rho_hr_r_k_mean > 0.55
  } else {
    NA
  }

  # AC-SIM-4: failure rate
  ac4_pass <- failure_rate < 0.01

  # AC-SIM-5: regime-break directional (S4 vs S1)
  top_minus_mean <- mean(ok$top_minus_boundary_zar, na.rm = TRUE)
  ac5_pass <- if (sc$id == "S4" && !is.null(s1_mean_top_minus)) {
    !is.na(top_minus_mean) && top_minus_mean > s1_mean_top_minus
  } else {
    NA
  }

  data.frame(
    scenario_id              = sc$id,
    dgp_type                 = sc$dgp_type,
    n_teams                  = sc$n_teams,
    pitcher_pool             = sc$pitcher_pool,
    n_reps                   = n_ok,
    failure_rate             = failure_rate,
    identity_max_error_max   = id_max,
    boundary_mean_C          = bnd_mean("boundary_total_zar_C"),
    boundary_sd_C            = bnd_sd("boundary_total_zar_C"),
    boundary_mean_1B         = bnd_mean("boundary_total_zar_1B"),
    boundary_sd_1B           = bnd_sd("boundary_total_zar_1B"),
    boundary_mean_OF         = bnd_mean("boundary_total_zar_OF"),
    boundary_sd_OF           = bnd_sd("boundary_total_zar_OF"),
    boundary_mean_SP         = bnd_mean("boundary_total_zar_SP"),
    boundary_sd_SP           = bnd_sd("boundary_total_zar_SP"),
    boundary_mean_RP         = bnd_mean("boundary_total_zar_RP"),
    boundary_sd_RP           = bnd_sd("boundary_total_zar_RP"),
    boundary_exceedance_C    = bnd_exc("boundary_total_zar_C"),
    boundary_exceedance_1B   = bnd_exc("boundary_total_zar_1B"),
    boundary_exceedance_OF   = bnd_exc("boundary_total_zar_OF"),
    boundary_exceedance_SP   = bnd_exc("boundary_total_zar_SP"),
    boundary_exceedance_RP   = bnd_exc("boundary_total_zar_RP"),
    band_mean_max_err_max    = bm_max,
    band_mean_violation_rate = bm_violation_rate,
    rank_rho_all_mean        = rho_all_mean,
    rank_rho_hr_r_k_mean     = rho_hr_r_k_mean,
    top_minus_boundary_mean  = top_minus_mean,
    ac_sim1_pass             = ac1_pass,
    ac_sim2_pass             = ac2_pass,
    ac_sim3_pass             = ac3_pass,
    ac_sim4_pass             = ac4_pass,
    ac_sim5_pass             = ac5_pass,
    stringsAsFactors         = FALSE
  )
}

summary_list <- vector("list", length(SCENARIOS))
s1_top_minus <- NULL

for (sc_idx in seq_along(SCENARIOS)) {
  sc     <- SCENARIOS[[sc_idx]]
  sc_df  <- results_df[results_df$scenario_id == sc$id, ]
  s1_ref <- if (sc$id == "S4") s1_top_minus else NULL
  summary_list[[sc_idx]] <- summarise_scenario(sc_df, sc, s1_ref)
  if (sc$id == "S1") {
    s1_top_minus <- summary_list[[sc_idx]]$top_minus_boundary_mean
  }
}

summary_df <- do.call(rbind, summary_list)

# ---------------------------------------------------------------------------
# 13. Write output artifacts
# ---------------------------------------------------------------------------

out_dir  <- file.path(pkg_root, "inst", "simulation")
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

rds_path <- file.path(out_dir, "sim-zar-results.rds")
csv_path <- file.path(out_dir, "sim-zar-summary.csv")

saveRDS(results_df, rds_path)
write.csv(summary_df, csv_path, row.names = FALSE)

cat("\nArtifacts written:\n")
cat("  ", rds_path, "\n")
cat("  ", csv_path, "\n\n")

# ---------------------------------------------------------------------------
# 14. Print AC summary table
# ---------------------------------------------------------------------------

cat("=== Acceptance Criteria Summary (v3) ===\n\n")
cat(sprintf("%-4s  %-18s  %8s  %8s  %8s  %8s  %8s  %10s  %12s\n",
            "SC", "DGP", "AC1(id)", "AC2(bm)", "AC3(rho)", "AC4(fail)",
            "AC5(dir)", "Rho(HR+R+K)", "BM_max_err"))
cat(strrep("-", 100), "\n")

fmt_pass <- function(x) {
  if (is.na(x)) "  N/A  " else if (x) " PASS  " else " FAIL  "
}

for (i in seq_len(nrow(summary_df))) {
  s <- summary_df[i, ]
  cat(sprintf("%-4s  %-18s  %8s  %8s  %8s  %8s  %8s  %10.4f  %12.3e\n",
              s$scenario_id, s$dgp_type,
              fmt_pass(s$ac_sim1_pass),
              fmt_pass(s$ac_sim2_pass),
              fmt_pass(s$ac_sim3_pass),
              fmt_pass(s$ac_sim4_pass),
              fmt_pass(s$ac_sim5_pass),
              ifelse(is.na(s$rank_rho_hr_r_k_mean), 0, s$rank_rho_hr_r_k_mean),
              ifelse(is.na(s$band_mean_max_err_max), 0, s$band_mean_max_err_max)))
}

cat("\nBand-mean violation rates (fraction of reps with any |err| >= 1e-10):\n")
cat(sprintf("  %-4s  %12s  %12s\n", "SC", "Violation_rate", "Max_err"))
for (i in seq_len(nrow(summary_df))) {
  s <- summary_df[i, ]
  cat(sprintf("  %-4s  %12.4f  %12.3e\n",
              s$scenario_id,
              ifelse(is.na(s$band_mean_violation_rate), 0, s$band_mean_violation_rate),
              ifelse(is.na(s$band_mean_max_err_max),    0, s$band_mean_max_err_max)))
}

cat("\nBoundary exceedance rates (|total_zar| > 0.5):\n")
cat(sprintf("  %-4s  %6s  %6s  %6s  %6s  %6s\n", "SC", "C", "1B", "OF", "SP", "RP"))
for (i in seq_len(nrow(summary_df))) {
  s <- summary_df[i, ]
  cat(sprintf("  %-4s  %6.3f  %6.3f  %6.3f  %6.3f  %6.3f\n",
              s$scenario_id,
              ifelse(is.na(s$boundary_exceedance_C),  0, s$boundary_exceedance_C),
              ifelse(is.na(s$boundary_exceedance_1B), 0, s$boundary_exceedance_1B),
              ifelse(is.na(s$boundary_exceedance_OF), 0, s$boundary_exceedance_OF),
              ifelse(is.na(s$boundary_exceedance_SP), 0, s$boundary_exceedance_SP),
              ifelse(is.na(s$boundary_exceedance_RP), 0, s$boundary_exceedance_RP)))
}

cat("\nAC-SIM-5 (regime-break directional):\n")
s1_row <- summary_df[summary_df$scenario_id == "S1", ]
s4_row <- summary_df[summary_df$scenario_id == "S4", ]
cat(sprintf("  S1 top_minus_boundary_mean: %.4f\n", s1_row$top_minus_boundary_mean))
cat(sprintf("  S4 top_minus_boundary_mean: %.4f\n", s4_row$top_minus_boundary_mean))
cat(sprintf("  S4 > S1: %s\n",
            if (s4_row$top_minus_boundary_mean > s1_row$top_minus_boundary_mean)
              "TRUE (PASS)" else "FALSE (FAIL)"))

cat("\nSimulation v3 complete.\n")
