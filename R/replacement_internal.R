# replacement_internal.R — internal helpers for replacement_level() and
# replacement_from_prices()
#
# Nothing here is exported.  Three mandated shared helpers plus additional
# helpers for band computation, cliff detection, rate-stat ranking, role
# inference, name normalisation, z-score computation, and pool-size delegation.

# ---------------------------------------------------------------------------
# §7.1  Mandated shared helpers
# ---------------------------------------------------------------------------

# format_replacement_output()
# Construct and lightly validate the output list returned by both exported
# functions.  Caller attaches attributes after this returns.
#
# Args:
#   replacement_stats        data.frame (position × stat)
#   positional_adjustments   named numeric vector or NULL
#   cliff_metric             data.frame
#   two_way_players          character vector
#   pool_diagnostics         list
#   method                   character scalar ("boundary_band" | "prices")
#   params                   named list
#
# Returns: named list

#' @noRd
format_replacement_output <- function(
  replacement_stats,
  positional_adjustments,
  cliff_metric,
  two_way_players,
  pool_diagnostics,
  method,
  params
) {
  list(
    replacement_stats      = replacement_stats,
    positional_adjustments = positional_adjustments,
    cliff_metric           = cliff_metric,
    two_way_players        = two_way_players,
    pool_diagnostics       = pool_diagnostics,
    method                 = method,
    params                 = params
  )
}

# ---------------------------------------------------------------------------

# compute_positional_adjustments()
# Compute scarcity premiums (positional adjustments) for each position.
#
# Returns a named numeric vector indexed by position name, or NULL when
# positional_adjustment_method = "sgp" and pass_number == 1L.
#
# Args:
#   replacement_stats              data.frame with column `position` and stat columns
#   config                         league_config object
#   positional_adjustment_method   character scalar
#   catcher_adjustment_method      character scalar
#   pos_weight                     numeric or NULL
#   sgp_denominators               sgp_denominators object or NULL
#   pass_number                    integer
#   verbose                        logical

#' @noRd
compute_positional_adjustments <- function(
  replacement_stats,
  config,
  positional_adjustment_method,
  catcher_adjustment_method,
  pos_weight       = NULL,
  sgp_denominators = NULL,
  pass_number      = 1L,
  verbose          = FALSE
) {
  # Return NULL on pass 1 when method = "sgp" (denominators not yet available)
  if (positional_adjustment_method == "sgp" && pass_number == 1L) {
    return(NULL)
  }

  # Inform if sgp_denominators supplied but method != "sgp"
  if (!is.null(sgp_denominators) && positional_adjustment_method != "sgp" && verbose) {
    cli::cli_inform(
      "{.arg sgp_denominators} supplied but {.arg positional_adjustment_method} is {.val {positional_adjustment_method}}, not {.val sgp}. Denominators unused."
    )
  }

  positions    <- replacement_stats$position
  scored_cats  <- setdiff(names(replacement_stats), c("position", "n_band_players", "cliff_detected", "IP", "AB"))
  roster_slots <- config$roster_slots

  # Identify hitter vs pitcher positions
  pitcher_pos <- intersect(positions, c("SP", "RP"))
  hitter_pos  <- setdiff(positions, pitcher_pos)

  # Primary hitter slots (from league-config.R constant)
  primary_hitter_pos <- intersect(hitter_pos, PRIMARY_HITTER_SLOTS)

  # -----------------------------------------------------------------------
  # Step 1: Global replacement level per group (hitters / pitchers)
  # -----------------------------------------------------------------------

  compute_global_repl <- function(pos_set) {
    if (length(pos_set) == 0L) return(NULL)
    weights <- vapply(pos_set, function(p) {
      if (p %in% c("SP", "RP")) {
        ps <- config$pitcher_slots
        if (!is.null(names(ps))) {
          as.numeric(ps[p])
        } else {
          as.numeric(ps) / 2
        }
      } else {
        as.numeric(roster_slots[p])
      }
    }, numeric(1L))
    names(weights) <- pos_set

    repl_mat <- as.matrix(replacement_stats[match(pos_set, replacement_stats$position), scored_cats, drop = FALSE])
    rownames(repl_mat) <- pos_set

    wt_sum <- sum(weights, na.rm = TRUE)
    if (wt_sum == 0) return(colMeans(repl_mat, na.rm = TRUE))
    colSums(repl_mat * weights / wt_sum, na.rm = TRUE)
  }

  global_hitter  <- compute_global_repl(primary_hitter_pos)
  global_pitcher <- compute_global_repl(pitcher_pos)

  # -----------------------------------------------------------------------
  # Step 2: Compute scarcity_premium per method
  # -----------------------------------------------------------------------
  scarcity_premium <- stats::setNames(rep(0.0, length(positions)), positions)

  if (positional_adjustment_method == "fvarz") {

    compute_fvarz_premium <- function(pos_set, global_repl) {
      if (length(pos_set) == 0L || is.null(global_repl)) return(NULL)
      for (pos in pos_set) {
        idx <- match(pos, replacement_stats$position)
        pos_stats <- as.numeric(replacement_stats[idx, scored_cats, drop = TRUE])
        names(pos_stats) <- scored_cats
        inverse_cats <- intersect(scored_cats, c("ERA", "WHIP"))
        normal_cats  <- setdiff(scored_cats, inverse_cats)

        premium_normal  <- if (length(normal_cats) > 0L)
          mean(global_repl[normal_cats] - pos_stats[normal_cats], na.rm = TRUE)
        else 0.0

        premium_inverse <- if (length(inverse_cats) > 0L)
          mean(pos_stats[inverse_cats] - global_repl[inverse_cats], na.rm = TRUE)
        else 0.0

        n_cats    <- length(scored_cats)
        n_normal  <- length(normal_cats)
        n_inverse <- length(inverse_cats)
        scarcity_premium[[pos]] <<- (premium_normal * n_normal + premium_inverse * n_inverse) / max(n_cats, 1L)
      }
    }

    compute_fvarz_premium(primary_hitter_pos, global_hitter)
    compute_fvarz_premium(pitcher_pos,        global_pitcher)

    # Re-center so zero-sum holds for the zero_sum_positions
    zero_sum_pos <- if (catcher_adjustment_method == "split_pool") {
      setdiff(primary_hitter_pos, "C")
    } else {
      primary_hitter_pos
    }
    zero_sum_pos <- intersect(zero_sum_pos, names(roster_slots[roster_slots > 0]))

    if (length(zero_sum_pos) > 0L) {
      ws      <- as.numeric(roster_slots[zero_sum_pos])
      cur_sum <- sum(ws * scarcity_premium[zero_sum_pos], na.rm = TRUE)
      if (sum(ws) > 0) {
        adj <- cur_sum / sum(ws)
        scarcity_premium[zero_sum_pos] <- scarcity_premium[zero_sum_pos] - adj
      }
    }

  } else if (positional_adjustment_method == "sgp") {

    denom_vals <- as.numeric(sgp_denominators)
    names(denom_vals) <- names(sgp_denominators)

    compute_sgp_premium <- function(pos_set, global_repl) {
      if (length(pos_set) == 0L || is.null(global_repl)) return(NULL)
      inverse_cats <- intersect(scored_cats, c("ERA", "WHIP"))
      for (pos in pos_set) {
        idx <- match(pos, replacement_stats$position)
        pos_stats <- as.numeric(replacement_stats[idx, scored_cats, drop = TRUE])
        names(pos_stats) <- scored_cats
        diffs <- vapply(scored_cats, function(cat) {
          d <- denom_vals[cat]
          if (is.na(d) || d == 0) return(0.0)
          if (cat %in% inverse_cats) {
            (pos_stats[cat] - global_repl[cat]) / d
          } else {
            (global_repl[cat] - pos_stats[cat]) / d
          }
        }, numeric(1L))
        scarcity_premium[[pos]] <<- mean(diffs, na.rm = TRUE)
      }
    }

    compute_sgp_premium(primary_hitter_pos, global_hitter)
    compute_sgp_premium(pitcher_pos,        global_pitcher)

    zero_sum_pos <- if (catcher_adjustment_method == "split_pool") {
      setdiff(primary_hitter_pos, "C")
    } else {
      primary_hitter_pos
    }
    zero_sum_pos <- intersect(zero_sum_pos, names(roster_slots[roster_slots > 0]))
    if (length(zero_sum_pos) > 0L) {
      ws      <- as.numeric(roster_slots[zero_sum_pos])
      cur_sum <- sum(ws * scarcity_premium[zero_sum_pos], na.rm = TRUE)
      if (sum(ws) > 0) {
        adj <- cur_sum / sum(ws)
        scarcity_premium[zero_sum_pos] <- scarcity_premium[zero_sum_pos] - adj
      }
    }

  } else if (positional_adjustment_method == "dollar") {

    budget         <- config$budget
    budget_split   <- config$budget_split
    hitter_budget  <- budget * budget_split
    pitcher_budget <- budget * (1 - budget_split)

    n_hitter_slots  <- sum(as.numeric(roster_slots[primary_hitter_pos]), na.rm = TRUE) *
                       config$n_teams
    n_pitcher_slots <- sum(as.numeric(config$pitcher_slots)) * config$n_teams

    per_hitter_dollar  <- if (n_hitter_slots  > 0) hitter_budget  / n_hitter_slots  else 0
    per_pitcher_dollar <- if (n_pitcher_slots > 0) pitcher_budget / n_pitcher_slots else 0

    for (pos in primary_hitter_pos) {
      idx          <- match(pos, replacement_stats$position)
      pos_stats    <- as.numeric(replacement_stats[idx, scored_cats, drop = TRUE])
      global_stats <- as.numeric(global_hitter[scored_cats])
      diffs        <- global_stats - pos_stats
      scarcity_premium[[pos]] <- mean(diffs, na.rm = TRUE) * per_hitter_dollar
    }
    for (pos in pitcher_pos) {
      idx          <- match(pos, replacement_stats$position)
      pos_stats    <- as.numeric(replacement_stats[idx, scored_cats, drop = TRUE])
      global_stats <- if (!is.null(global_pitcher)) as.numeric(global_pitcher[scored_cats]) else pos_stats
      diffs        <- global_stats - pos_stats
      scarcity_premium[[pos]] <- mean(diffs, na.rm = TRUE) * per_pitcher_dollar
    }

    zero_sum_pos <- if (catcher_adjustment_method == "split_pool") {
      setdiff(primary_hitter_pos, "C")
    } else {
      primary_hitter_pos
    }
    zero_sum_pos <- intersect(zero_sum_pos, names(roster_slots[roster_slots > 0]))
    if (length(zero_sum_pos) > 0L) {
      ws      <- as.numeric(roster_slots[zero_sum_pos])
      cur_sum <- sum(ws * scarcity_premium[zero_sum_pos], na.rm = TRUE)
      if (sum(ws) > 0) {
        adj <- cur_sum / sum(ws)
        scarcity_premium[zero_sum_pos] <- scarcity_premium[zero_sum_pos] - adj
      }
    }

  } else if (positional_adjustment_method == "posblend") {

    compute_posblend_premium <- function(pos_set, global_repl) {
      if (length(pos_set) == 0L || is.null(global_repl)) return(NULL)
      for (pos in pos_set) {
        idx       <- match(pos, replacement_stats$position)
        pos_stats <- as.numeric(replacement_stats[idx, scored_cats, drop = TRUE])
        names(pos_stats) <- scored_cats

        pos_avg <- colMeans(
          as.matrix(replacement_stats[replacement_stats$position %in% pos_set, scored_cats, drop = FALSE]),
          na.rm = TRUE
        )

        within_pos    <- pos_stats - pos_avg
        within_global <- pos_stats - global_repl

        blended <- pos_weight * within_pos + (1 - pos_weight) * within_global
        scarcity_premium[[pos]] <<- mean(blended, na.rm = TRUE)
      }
    }

    compute_posblend_premium(primary_hitter_pos, global_hitter)
    compute_posblend_premium(pitcher_pos,        global_pitcher)

    zero_sum_pos <- if (catcher_adjustment_method == "split_pool") {
      setdiff(primary_hitter_pos, "C")
    } else {
      primary_hitter_pos
    }
    zero_sum_pos <- intersect(zero_sum_pos, names(roster_slots[roster_slots > 0]))
    if (length(zero_sum_pos) > 0L) {
      ws      <- as.numeric(roster_slots[zero_sum_pos])
      cur_sum <- sum(ws * scarcity_premium[zero_sum_pos], na.rm = TRUE)
      if (sum(ws) > 0) {
        adj <- cur_sum / sum(ws)
        scarcity_premium[zero_sum_pos] <- scarcity_premium[zero_sum_pos] - adj
      }
    }
  }

  # -----------------------------------------------------------------------
  # Step 3: Apply catcher_adjustment_method BEFORE zero-sum assertion
  # -----------------------------------------------------------------------
  if ("C" %in% positions) {
    if (catcher_adjustment_method == "none") {
      scarcity_premium["C"] <- 0.0
    }
    # "split_pool": zero_sum_positions excludes "C" above — no change needed here
    # "positional_default": leave scarcity_premium["C"] unchanged
    # "partial_offset": leave unchanged (research use only)
  }

  scarcity_premium
}

# ---------------------------------------------------------------------------

# assert_replacement_output_contract()
# Validate the complete output object against the contract.
# Aborts with informative message if any required element is missing or
# mis-typed.
#
# Args:
#   result   named list produced by format_replacement_output()

#' @noRd
assert_replacement_output_contract <- function(result) {
  required_elements <- c(
    "replacement_stats", "positional_adjustments", "cliff_metric",
    "two_way_players", "pool_diagnostics", "method", "params"
  )
  missing_els <- setdiff(required_elements, names(result))
  if (length(missing_els) > 0L) {
    cli::cli_abort(
      c(
        "Output list is missing required element{?s}: {.val {missing_els}}.",
        "i" = "This is an internal bug in {.fn format_replacement_output}."
      )
    )
  }

  rs <- result$replacement_stats
  if (!is.data.frame(rs)) {
    cli::cli_abort("result$replacement_stats must be a data.frame.")
  }
  if (!"position" %in% names(rs)) {
    cli::cli_abort("result$replacement_stats must contain a 'position' column.")
  }
  if (!"n_band_players" %in% names(rs)) {
    cli::cli_abort("result$replacement_stats must contain an 'n_band_players' column.")
  }
  if (!"cliff_detected" %in% names(rs)) {
    cli::cli_abort("result$replacement_stats must contain a 'cliff_detected' column.")
  }

  cm <- result$cliff_metric
  if (!is.data.frame(cm)) {
    cli::cli_abort("result$cliff_metric must be a data.frame.")
  }
  cm_required <- c("position", "cliff_detected", "cliff_location",
                   "cliff_magnitude", "swingman", "n_band_players")
  cm_missing <- setdiff(cm_required, names(cm))
  if (length(cm_missing) > 0L) {
    cli::cli_abort(
      "result$cliff_metric is missing column{?s}: {.val {cm_missing}}."
    )
  }

  params <- result$params
  if (!is.list(params)) {
    cli::cli_abort("result$params must be a list.")
  }
  params_required <- c("converged", "iterations", "delta", "n_teams",
                       "roster_slots", "band_width", "cliff_threshold",
                       "sort_by", "stat_units", "catcher_adjustment_method",
                       "method")
  params_missing <- setdiff(params_required, names(params))
  if (length(params_missing) > 0L) {
    cli::cli_abort(
      "result$params is missing key{?s}: {.val {params_missing}}."
    )
  }

  pa <- result$positional_adjustments
  if (!is.null(pa)) {
    if (!is.numeric(pa) || is.null(names(pa))) {
      cli::cli_abort(
        "result$positional_adjustments must be a named numeric vector or NULL."
      )
    }
  }

  su <- attr(result, "stat_units")
  if (!is.null(su)) {
    valid_su <- c("raw_projected", "full_season_normalized")
    if (!su %in% valid_su) {
      cli::cli_abort(
        "attr(result, 'stat_units') must be one of {.val {valid_su}}, not {.val {su}}."
      )
    }
  }

  invisible(result)
}

# ---------------------------------------------------------------------------
# §7.2  Additional internal helpers
# ---------------------------------------------------------------------------

# infer_pitcher_roles()
# Infer SP/RP role for pitcher rows and flag swingmen BEFORE role assignment.
# Swingman = 80 <= IP <= 120 (computed before role classification per spec §5.2).
#
# Args:
#   projections      data.frame (uppercase column names)
#   sp_ip_threshold  numeric
#
# Returns: list(role = character vector, swingman_flag = logical vector)
#   Vectors are length nrow(projections); non-pitchers get role = NA and
#   swingman_flag = FALSE.

#' @noRd
infer_pitcher_roles <- function(projections, sp_ip_threshold) {
  is_pitcher <- grepl("(SP|RP)", projections$POS_ELIGIBILITY, ignore.case = FALSE)

  # Swingman flag computed BEFORE role assignment
  swingman_flag <- is_pitcher &
                   !is.na(projections$IP) &
                   projections$IP >= 80 &
                   projections$IP <= 120

  if ("ROLE" %in% names(projections)) {
    role <- projections$ROLE
  } else {
    role <- ifelse(
      is_pitcher & !is.na(projections$IP) & projections$IP >= sp_ip_threshold,
      "SP",
      ifelse(is_pitcher, "RP", NA_character_)
    )
  }

  list(role = role, swingman_flag = swingman_flag)
}

# ---------------------------------------------------------------------------

# compute_band_indices()
# Compute effective K and band indices for a sorted pool.
#
# Args:
#   n_rostered_pos   integer — total players rostered at this position
#   pool_size        integer — actual number of players in the pool
#   K                integer — requested band half-width
#
# Returns: list(K_eff, b, band_upper, band_lower, B_all)
#   b          = n_rostered_pos (boundary index)
#   band_upper = indices from max(1, b - K_eff) to b (clamped)
#   band_lower = indices from (b + 1) to min(pool_size, b + K_eff) (clamped)
#   B_all      = c(band_upper, band_lower)

#' @noRd
compute_band_indices <- function(n_rostered_pos, pool_size, K) {
  K_eff <- min(K, floor(n_rostered_pos / 4L))
  b     <- n_rostered_pos

  upper_start <- max(1L, b - K_eff)
  upper_end   <- min(b, pool_size)
  band_upper  <- if (upper_start <= upper_end) seq(upper_start, upper_end) else integer(0L)

  lower_start <- b + 1L
  lower_end   <- min(pool_size, b + K_eff)
  band_lower  <- if (lower_start <= lower_end) seq(lower_start, lower_end) else integer(0L)

  list(
    K_eff      = K_eff,
    b          = b,
    band_upper = band_upper,
    band_lower = band_lower,
    B_all      = c(band_upper, band_lower)
  )
}

# ---------------------------------------------------------------------------

# detect_cliff()
# Apply cliff detection to the lower half of the band for a single stat.
#
# Args:
#   B_lower_values            numeric vector — stat values for lower-half band players
#   band_all_values           numeric vector — stat values for entire band (for MAD)
#   cliff_method              character scalar
#   cliff_threshold           numeric — MAD threshold multiplier
#   cliff_gap_ratio_threshold numeric — gap_ratio threshold
#   cliff_min_n               integer — minimum players to run detection
#
# Returns: list(cliff_detected, cliff_location, cliff_magnitude)

#' @noRd
detect_cliff <- function(
  B_lower_values,
  band_all_values,
  cliff_method,
  cliff_threshold,
  cliff_gap_ratio_threshold,
  cliff_min_n
) {
  n_lower <- length(B_lower_values)

  if (n_lower < cliff_min_n) {
    return(list(cliff_detected = FALSE, cliff_location = NA_integer_,
                cliff_magnitude = NA_real_))
  }

  if (cliff_method == "mad") {
    mad_val       <- stats::mad(band_all_values, constant = 1.4826)
    sorted_l      <- sort(B_lower_values)
    gaps          <- diff(sorted_l)
    threshold_gap <- cliff_threshold * mad_val * 1.4826
    cliff_pos     <- which(gaps >= threshold_gap)

    if (length(cliff_pos) > 0L) {
      j               <- min(cliff_pos)
      cliff_magnitude <- gaps[j]
      return(list(cliff_detected   = TRUE,
                  cliff_location   = j,
                  cliff_magnitude  = cliff_magnitude))
    } else {
      return(list(cliff_detected = FALSE, cliff_location = NA_integer_,
                  cliff_magnitude = NA_real_))
    }

  } else if (cliff_method == "fisher_jenks") {
    if (!requireNamespace("classInt", quietly = TRUE)) {
      cli::cli_abort(
        c(
          "{.pkg classInt} is required for {.code cliff_method = \"fisher_jenks\"}.",
          "i" = "Install it with {.code install.packages(\"classInt\")}."
        )
      )
    }
    breaks      <- classInt::classIntervals(band_all_values, n = 2, style = "fisher")$brks
    split_point <- breaks[2]
    # boundary player is the last element of band_upper (index length(band_all_values) - n_lower)
    boundary_idx <- length(band_all_values) - n_lower
    b_val        <- if (boundary_idx > 0L) band_all_values[boundary_idx] else band_all_values[1L]
    cliff_detected <- split_point <= b_val
    sorted_l       <- sort(B_lower_values)
    return(list(cliff_detected   = cliff_detected,
                cliff_location   = if (cliff_detected) as.integer(which.min(abs(sorted_l - split_point))) else NA_integer_,
                cliff_magnitude  = if (cliff_detected) as.numeric(split_point) else NA_real_))

  } else {  # "gap_ratio"
    sorted_l   <- sort(B_lower_values)
    gaps       <- abs(diff(sorted_l))
    range_val  <- diff(range(B_lower_values))
    if (range_val == 0) {
      return(list(cliff_detected = FALSE, cliff_location = NA_integer_,
                  cliff_magnitude = NA_real_))
    }
    gap_ratios <- gaps / range_val
    cliff_pos  <- which(gap_ratios >= cliff_gap_ratio_threshold)
    if (length(cliff_pos) > 0L) {
      j <- min(cliff_pos)
      return(list(cliff_detected  = TRUE,
                  cliff_location  = j,
                  cliff_magnitude = gaps[j]))
    } else {
      return(list(cliff_detected = FALSE, cliff_location = NA_integer_,
                  cliff_magnitude = NA_real_))
    }
  }
}

# ---------------------------------------------------------------------------

# compute_replacement_stat_line()
# Compute the replacement stat line for band players at a single position.
# Counting stats: simple mean.  ERA/WHIP: IP-weighted.  AVG: AB-weighted.
#
# Args:
#   band_df      data.frame — rows for band players (projections subset)
#   scored_cats  character vector — category names
#   rate_cats    character vector — names of rate stats
#   include_ip   logical — always include IP for pitchers
#   include_ab   logical — include AB for hitters when AVG/OBP in cats
#
# Returns: named numeric vector of replacement stats

#' @noRd
compute_replacement_stat_line <- function(
  band_df,
  scored_cats,
  rate_cats,
  include_ip,
  include_ab
) {
  out <- stats::setNames(rep(NA_real_, length(scored_cats)), scored_cats)

  for (cat in scored_cats) {
    if (!cat %in% names(band_df)) next
    if (cat == "ERA" && "IP" %in% names(band_df)) {
      ip_sum <- sum(band_df$IP, na.rm = TRUE)
      if (ip_sum > 0) {
        out["ERA"] <- sum(band_df$ERA * band_df$IP, na.rm = TRUE) / ip_sum
      }
    } else if (cat == "WHIP" && "IP" %in% names(band_df)) {
      ip_sum <- sum(band_df$IP, na.rm = TRUE)
      if (ip_sum > 0) {
        out["WHIP"] <- sum(band_df$WHIP * band_df$IP, na.rm = TRUE) / ip_sum
      }
    } else if (cat == "AVG" && "AB" %in% names(band_df)) {
      ab_sum <- sum(band_df$AB, na.rm = TRUE)
      if (ab_sum > 0) {
        out["AVG"] <- sum(band_df$AVG * band_df$AB, na.rm = TRUE) / ab_sum
      }
    } else {
      out[cat] <- mean(band_df[[cat]], na.rm = FALSE)
    }
  }

  if (include_ip && "IP" %in% names(band_df)) {
    out["IP"] <- mean(band_df$IP, na.rm = FALSE)
  }

  if (include_ab && "AB" %in% names(band_df)) {
    out["AB"] <- mean(band_df$AB, na.rm = FALSE)
  }

  out
}

# ---------------------------------------------------------------------------

# compute_pool_zscores()
# Compute z-scores within the unified hitter or pitcher pool.
#
# Pool is sized to pool_size + K players.  Z-scores are computed within the
# unified pool — not per position — to avoid SD compression at thin positions.
#
# Args:
#   projections   data.frame (uppercase column names)
#   pool_size     integer — n_teams × sum(roster_slots[pos_set])
#   scored_cats   character vector
#   K             integer — band half-width
#   order_col     character — column to order pool by initially
#   is_pitcher    logical — determines sign convention for ERA/WHIP
#
# Returns: numeric vector of composite z-scores, length = nrow(projections)

#' @noRd
compute_pool_zscores <- function(projections, pool_size, scored_cats, K,
                                 order_col, is_pitcher) {
  n            <- nrow(projections)
  extended_pool <- min(n, pool_size + K)

  order_vals <- if (order_col %in% names(projections)) projections[[order_col]] else rep(0, n)
  pool_order  <- order(order_vals, decreasing = TRUE)
  in_pool     <- pool_order[seq_len(extended_pool)]

  pool_df <- projections[in_pool, , drop = FALSE]

  z_matrix <- matrix(0.0, nrow = n, ncol = length(scored_cats))
  colnames(z_matrix) <- scored_cats

  inverse_cats <- intersect(scored_cats, c("ERA", "WHIP"))

  for (cat in scored_cats) {
    if (!cat %in% names(projections)) next
    pool_vals <- pool_df[[cat]]
    mu <- mean(pool_vals, na.rm = TRUE)
    sg <- stats::sd(pool_vals, na.rm = TRUE)
    if (is.na(sg) || sg == 0) sg <- 1.0

    all_vals <- projections[[cat]]
    z        <- (all_vals - mu) / sg

    if (cat %in% inverse_cats) z <- -z

    z_matrix[, cat] <- z
  }

  rowMeans(z_matrix, na.rm = TRUE)
}

# ---------------------------------------------------------------------------

# normalize_player_name()
# Normalize player names for fuzzy matching:
#   1. NFD decomposition
#   2. Strip combining diacriticals
#   3. Lowercase
#   4. Remove non-alphanumeric, non-space
#   5. Collapse multiple spaces
#
# Args:
#   x   character vector
#
# Returns: character vector of normalised names

#' @noRd
normalize_player_name <- function(x) {
  x <- stringi::stri_trans_nfd(x)
  x <- stringi::stri_replace_all_regex(x, "\\p{Mn}", "")
  x <- tolower(x)
  x <- gsub("[^a-z0-9 ]", "", x)
  x <- trimws(gsub("\\s+", " ", x))
  x
}

# ---------------------------------------------------------------------------

# get_pool_sizes()
# Delegate to pool_sizes() from R/league-config.R.
# Returns list(pitchers, hitters).

#' @noRd
get_pool_sizes <- function(config) {
  pool_sizes(config)
}

# ---------------------------------------------------------------------------

# assert_zero_sum()
# Assert that the zero-sum property holds for positional adjustments.
# Violations are internal computation bugs.
#
# Args:
#   scarcity_premium          named numeric vector
#   config                    league_config object
#   catcher_adjustment_method character scalar
#   primary_hitter_slots      character vector

#' @noRd
assert_zero_sum <- function(scarcity_premium, config, catcher_adjustment_method,
                             primary_hitter_slots) {
  zero_sum_positions <- if (catcher_adjustment_method == "split_pool") {
    setdiff(primary_hitter_slots, "C")
  } else {
    primary_hitter_slots
  }

  roster_slots <- config$roster_slots
  zero_sum_positions <- intersect(
    zero_sum_positions,
    names(roster_slots[roster_slots > 0])
  )

  if (length(zero_sum_positions) == 0L) return(invisible(NULL))

  prem_vals <- scarcity_premium[zero_sum_positions]
  slot_vals <- as.numeric(roster_slots[zero_sum_positions])

  check_val <- sum(slot_vals * prem_vals, na.rm = TRUE)

  if (abs(check_val) > 1e-6) {
    cli::cli_abort(
      c(
        "Zero-sum assertion failed for positional adjustments.",
        "i" = "sum(roster_slots * scarcity_premium) = {check_val}; must be < 1e-6.",
        "i" = "This is an internal computation bug."
      ),
      class = "rotostats_error_zero_sum_violation",
      call  = rlang::caller_env()
    )
  }

  invisible(NULL)
}

# ---------------------------------------------------------------------------

# compute_par_at_pos()
# Compute a simple composite PAR for a player at a candidate position.
#
# Args:
#   player_row    one-row data.frame (player stats, uppercase cols)
#   repl_row      one-row data.frame (replacement stats for pos)
#   scored_cats   character vector of categories
#
# Returns: numeric scalar (sum of per-category signed differences)

#' @noRd
compute_par_at_pos <- function(player_row, repl_row, scored_cats) {
  inverse_cats <- intersect(scored_cats, c("ERA", "WHIP"))
  normal_cats  <- setdiff(scored_cats, inverse_cats)

  par_normal <- if (length(normal_cats) > 0L) {
    p_vals <- as.numeric(player_row[1, normal_cats, drop = TRUE])
    r_vals <- as.numeric(repl_row[1, normal_cats, drop = TRUE])
    sum(p_vals - r_vals, na.rm = TRUE)
  } else {
    0.0
  }

  par_inverse <- if (length(inverse_cats) > 0L) {
    p_vals <- as.numeric(player_row[1, inverse_cats, drop = TRUE])
    r_vals <- as.numeric(repl_row[1, inverse_cats, drop = TRUE])
    sum(r_vals - p_vals, na.rm = TRUE)
  } else {
    0.0
  }

  par_normal + par_inverse
}

# ---------------------------------------------------------------------------

# kde_trough()
# Detect the trough between two clusters in a numeric vector via KDE.
# Aborts with rotostats_error_kde_no_trough if no trough is found.
#
# Args:
#   x   numeric vector

#' @noRd
kde_trough <- function(x) {
  dens   <- stats::density(x, adjust = 0.5)
  y      <- dens$y
  x_grid <- dens$x
  n      <- length(y)

  # A local minimum: y[i] < y[i-1] and y[i] < y[i+1]
  is_trough <- c(FALSE,
                 y[2L:(n - 1L)] < y[1L:(n - 2L)] &
                 y[2L:(n - 1L)] < y[3L:n],
                 FALSE)

  trough_x <- x_grid[is_trough]
  trough_x <- trough_x[trough_x > min(x) & trough_x < max(x)]

  if (length(trough_x) == 0L) {
    cli::cli_abort(
      c(
        "No trough detectable in the KDE of the \\$1 player pool.",
        "i" = "Use {.code trim_method = \"iqr\"} or {.code \"mad\"} instead."
      ),
      class = "rotostats_error_kde_no_trough"
    )
  }

  min(trough_x)
}
