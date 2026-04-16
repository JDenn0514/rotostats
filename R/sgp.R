# sgp() — per-player Standings-Gain-Point converter

# ---------------------------------------------------------------------------
# sgp()
# ---------------------------------------------------------------------------

#' Convert player projections to SGP units
#'
#' @description
#' Converts projected per-player statistics into SGP (Standings Gain Points)
#' units using pre-calibrated denominators from [sgp_denominators()]. The
#' primary method is `"blended_pool"` with `pool_baseline = "projection_pool"`,
#' which derives blended-pool rate-stat baselines from the top-N projected
#' starters by playing time.
#'
#' @param projections A data frame with one row per player. Must include a
#'   column for each scored category in `names(denominators)`, plus `IP` (for
#'   ERA/WHIP pool construction) and `AB` (for AVG pool construction) when
#'   those rate stats are scored. Column names are normalized to uppercase at
#'   entry.
#' @param denominators An `sgp_denominators` S3 object from
#'   [sgp_denominators()]. The scored categories are `names(denominators)`.
#'   The attribute `attr(denominators, "rate_conversion")` is read from the
#'   outer S3 object (not from `denominators$denominators`).
#' @param league_history A `league_history` S3 object or duck-typed list with
#'   a `$team_season` data frame. Required when
#'   `rate_conversion = "blended_pool"`. Must contain `IP` and `AB` columns
#'   alongside rate-stat columns in `$team_season`.
#' @param rate_conversion Character. One of `"blended_pool"` (default),
#'   `"fixed_baseline"`, `"per_player"`, `"universal_constants"`, or
#'   `"team_ip_normalized"`. The last three abort with
#'   `rotostats_error_not_implemented`. `"fixed_baseline"` delegates to
#'   [convert_rate_stats()]. Must match `attr(denominators, "rate_conversion")`
#'   when `"blended_pool"`.
#' @param pool_baseline Character. Currently only `"projection_pool"` is
#'   implemented.
#' @param league_config A `league_config` S3 object from [league_config()].
#'   Required when `rate_conversion = "blended_pool"` and
#'   `pool_baseline = "projection_pool"`. Passed to [pool_sizes()] to derive
#'   `pool_size_p` and `pool_size_h`.
#' @param baseline_era Numeric scalar. Explicit ERA baseline for
#'   `rate_conversion = "fixed_baseline"`. Ignored for `"blended_pool"`.
#' @param baseline_whip Numeric scalar. Explicit WHIP baseline. Ignored for
#'   `"blended_pool"`.
#' @param baseline_avg Numeric scalar. Explicit AVG baseline. Ignored for
#'   `"blended_pool"`.
#'
#' @return A data frame with one row per player (same order as `projections`),
#'   one column `sgp_<CAT>` per scored category (e.g., `sgp_HR`, `sgp_ERA`),
#'   and a final column `total_sgp` equal to `rowSums()` across all
#'   `sgp_<CAT>` columns. `total_sgp` is `NA` for any player whose
#'   per-category SGP is `NA` (propagation via `na.rm = FALSE`).
#'
#' @seealso [sgp_denominators()], [league_config()], [league_history()]
#' @export
sgp <- function(
  projections,
  denominators,
  league_history  = NULL,
  rate_conversion = "blended_pool",
  pool_baseline   = "projection_pool",
  league_config   = NULL,
  baseline_era    = NULL,
  baseline_whip   = NULL,
  baseline_avg    = NULL
) {

  # -------------------------------------------------------------------------
  # Step 1 — Normalize projections column names to uppercase (silent)
  # -------------------------------------------------------------------------
  names(projections) <- toupper(names(projections))

  # -------------------------------------------------------------------------
  # Step 2 — Validate rate_conversion (value check)
  # -------------------------------------------------------------------------
  valid_rate_conversions <- c(
    "blended_pool", "fixed_baseline",
    "per_player", "universal_constants", "team_ip_normalized"
  )
  if (!rate_conversion %in% valid_rate_conversions) {
    cli::cli_abort(
      "{.arg rate_conversion} must be one of {.val {valid_rate_conversions}}, not {.val {rate_conversion}}.",
      class = "rotostats_error_invalid_rate_conversion"
    )
  }

  # -------------------------------------------------------------------------
  # Step 3 — Validate denominator compatibility (blended_pool only)
  # -------------------------------------------------------------------------
  if (rate_conversion == "blended_pool") {
    denom_rc <- attr(denominators, "rate_conversion")
    if (!identical(denom_rc, "blended_pool")) {
      cli::cli_abort(
        paste0(
          "{.arg denominators} was calibrated under {.val {denom_rc}} but ",
          "{.arg rate_conversion} = {.val \"blended_pool\"}. ",
          "Re-run {.fn sgp_denominators} with {.code rate_conversion = \"blended_pool\"} ",
          "or change {.arg rate_conversion} to match."
        ),
        class = "rotostats_error_invalid_rate_conversion"
      )
    }
  }

  # -------------------------------------------------------------------------
  # Step 4 — Abort for not-implemented methods
  # -------------------------------------------------------------------------
  if (rate_conversion %in% c("per_player", "universal_constants", "team_ip_normalized")) {
    cli::cli_abort(
      paste0(
        "{.code rate_conversion = \"{rate_conversion}\"} is not yet implemented. ",
        "Use {.code rate_conversion = \"blended_pool\"} (default) or ",
        "{.code \"fixed_baseline\"}."
      ),
      class = "rotostats_error_not_implemented"
    )
  }

  # -------------------------------------------------------------------------
  # Step 5 — Delegate for rate_conversion = "fixed_baseline"
  # -------------------------------------------------------------------------
  if (rate_conversion == "fixed_baseline") {
    convert_rate_stats(
      league_history = league_history,
      baseline_era   = baseline_era,
      baseline_whip  = baseline_whip,
      baseline_avg   = baseline_avg,
      projections    = projections,
      league_config  = league_config
    )
    # convert_rate_stats() always aborts — this line is never reached.
  }

  # -------------------------------------------------------------------------
  # Step 6 — Validate required inputs for blended_pool
  # (Only reached when rate_conversion == "blended_pool")
  # -------------------------------------------------------------------------

  # 6a. league_history required
  if (is.null(league_history)) {
    cli::cli_abort(
      "{.arg league_history} is required when {.code rate_conversion = \"blended_pool\"}.",
      class = "rotostats_error_missing_config_field"
    )
  }

  # 6b. league_config required for projection_pool
  if (is.null(league_config)) {
    cli::cli_abort(
      "{.arg league_config} is required when {.code pool_baseline = \"projection_pool\"}.",
      class = "rotostats_error_missing_config_field"
    )
  }

  # 6c. Validate league_history$team_season
  ts <- league_history[["team_season"]]
  if (is.null(ts) || !is.data.frame(ts)) {
    cli::cli_abort(
      "{.code league_history$team_season} must be a non-NULL data.frame.",
      class = "rotostats_error_missing_team_season"
    )
  }

  # 6d. Normalize ts column names to uppercase
  names(ts) <- toupper(names(ts))

  # 6e. Validate ts contains IP and AB
  ts_missing_cols <- setdiff(c("IP", "AB"), names(ts))
  if (length(ts_missing_cols) > 0L) {
    cli::cli_abort(
      "{.code league_history$team_season} must contain {.val IP} and {.val AB} columns to derive rate-stat baselines.",
      class = "rotostats_error_missing_required_column"
    )
  }

  # -------------------------------------------------------------------------
  # Step 7 — Derive scored_cats, rate_cats, count_cats
  # -------------------------------------------------------------------------
  scored_cats <- names(denominators)   # dispatches names.sgp_denominators()
  rate_cats   <- intersect(scored_cats, c("ERA", "WHIP", "AVG"))
  count_cats  <- setdiff(scored_cats, rate_cats)

  # -------------------------------------------------------------------------
  # Step 8 — Detect and warn about missing scored category columns
  # -------------------------------------------------------------------------
  missing_cats <- character(0L)
  for (cat in scored_cats) {
    if (!cat %in% names(projections)) {
      cli::cli_warn(
        paste0(
          "Scored category {.val {cat}} is absent from {.arg projections}. ",
          "{.code sgp_{tolower(cat)}} will be {.code NA} for all players."
        ),
        class = "rotostats_warning_missing_category_column"
      )
      missing_cats <- c(missing_cats, cat)
    }
  }

  # -------------------------------------------------------------------------
  # Step 9 — Handle SVHD
  # -------------------------------------------------------------------------
  if ("SVHD" %in% scored_cats && !"SVHD" %in% missing_cats) {
    # Already present — no action needed.
    NULL
  } else if ("SVHD" %in% scored_cats && "SVHD" %in% missing_cats) {
    # Try to derive from SV + HLD (or HD)
    hld_col <- if ("HLD" %in% names(projections)) "HLD" else if ("HD" %in% names(projections)) "HD" else NULL
    if ("SV" %in% names(projections) && !is.null(hld_col)) {
      projections$SVHD <- projections$SV + projections[[hld_col]]
      rlang::inform(
        paste0(
          "SVHD derived as SV + ", hld_col, ". ",
          "Verify that this definition matches your league's hold rules."
        ),
        .frequency = "once"
      )
      # Remove SVHD from missing_cats since we just derived it
      missing_cats <- setdiff(missing_cats, "SVHD")
    }
    # If still missing after derivation attempt, missing_cats retains "SVHD"
    # and the NA fill in later steps applies.
  }

  # -------------------------------------------------------------------------
  # Step 10 — Compute baseline year and pool-weighted averages
  # -------------------------------------------------------------------------

  # Validate ts has the required rate-stat columns (only for scored rate stats)
  if ("ERA" %in% rate_cats || "WHIP" %in% rate_cats) {
    ts_era_whip_cols <- setdiff(
      intersect(c("ERA", "WHIP", "IP"), rate_cats),
      c("ERA", "WHIP")   # we specifically need IP + the rate cols
    )
    # Check ERA/WHIP presence in ts if they are scored
    needed_in_ts <- c(
      if ("ERA" %in% rate_cats) c("ERA", "IP") else character(0L),
      if ("WHIP" %in% rate_cats) c("WHIP", "IP") else character(0L)
    )
    needed_in_ts <- unique(needed_in_ts)
    ts_missing <- setdiff(needed_in_ts, names(ts))
    if (length(ts_missing) > 0L) {
      cli::cli_abort(
        "{.code league_history$team_season} must contain {.val IP} and {.val AB} columns to derive rate-stat baselines.",
        class = "rotostats_error_missing_required_column"
      )
    }
  }
  if ("AVG" %in% rate_cats) {
    needed_in_ts <- c("AVG", "AB")
    ts_missing <- setdiff(needed_in_ts, names(ts))
    if (length(ts_missing) > 0L) {
      cli::cli_abort(
        "{.code league_history$team_season} must contain {.val IP} and {.val AB} columns to derive rate-stat baselines.",
        class = "rotostats_error_missing_required_column"
      )
    }
  }

  # 10a. Identify baseline_year (most recent non-excluded year — spec uses max)
  baseline_year <- max(ts$YEAR)

  cli::cli_inform(
    "Using {.val {baseline_year}} as the baseline year for {.code avg_ERA} / {.code avg_WHIP} / {.code avg_AVG}."
  )

  # 10b. Filter ts to baseline_year
  ts_base <- ts[ts$YEAR == baseline_year, , drop = FALSE]

  # 10c. Compute weighted means for the scored rate stats
  avg_ERA  <- if ("ERA" %in% rate_cats && "ERA" %in% names(ts_base)) {
    stats::weighted.mean(ts_base$ERA, ts_base$IP)
  } else {
    NULL
  }

  avg_WHIP <- if ("WHIP" %in% rate_cats && "WHIP" %in% names(ts_base)) {
    stats::weighted.mean(ts_base$WHIP, ts_base$IP)
  } else {
    NULL
  }

  avg_AVG  <- if ("AVG" %in% rate_cats && "AVG" %in% names(ts_base)) {
    stats::weighted.mean(ts_base$AVG, ts_base$AB)
  } else {
    NULL
  }

  # -------------------------------------------------------------------------
  # Step 11 — Build pool constants (blended_pool + projection_pool)
  # -------------------------------------------------------------------------

  # 11a. Get pool sizes
  ps          <- pool_sizes(league_config)
  pool_size_p <- ps$pitchers
  pool_size_h <- ps$hitters

  # Validate that IP is in projections if ERA or WHIP is scored
  if (length(intersect(c("ERA", "WHIP"), rate_cats)) > 0L && !"IP" %in% names(projections)) {
    cli::cli_abort(
      "{.arg projections} must contain an {.val IP} column when {.val ERA} or {.val WHIP} is a scored category.",
      class = "rotostats_error_missing_required_column"
    )
  }

  # Validate that AB is in projections if AVG is scored
  if ("AVG" %in% rate_cats && !"AB" %in% names(projections)) {
    cli::cli_abort(
      "{.arg projections} must contain an {.val AB} column when {.val AVG} is a scored category.",
      class = "rotostats_error_missing_required_column"
    )
  }

  # 11b-11c. Pitcher pool (needed if ERA or WHIP scored)
  pool_IP <- NULL
  pool_ER <- NULL
  pool_WH <- NULL
  if (length(intersect(c("ERA", "WHIP"), rate_cats)) > 0L) {
    pitcher_rows  <- order(projections$IP, decreasing = TRUE)
    pool_pitchers <- projections[head(pitcher_rows, pool_size_p), , drop = FALSE]
    pool_IP <- sum(pool_pitchers$IP,                          na.rm = TRUE)
    if ("ERA" %in% rate_cats) {
      pool_ER <- sum(pool_pitchers$ERA * pool_pitchers$IP / 9, na.rm = TRUE)
    }
    if ("WHIP" %in% rate_cats) {
      pool_WH <- sum(pool_pitchers$WHIP * pool_pitchers$IP,    na.rm = TRUE)
    }
  }

  # 11d-11e. Hitter pool (needed if AVG scored)
  pool_AB <- NULL
  pool_H  <- NULL
  if ("AVG" %in% rate_cats) {
    hitter_rows  <- order(projections$AB, decreasing = TRUE)
    pool_hitters <- projections[head(hitter_rows, pool_size_h), , drop = FALSE]
    pool_AB <- sum(pool_hitters$AB,                           na.rm = TRUE)
    pool_H  <- sum(pool_hitters$AVG * pool_hitters$AB,        na.rm = TRUE)
  }

  # -------------------------------------------------------------------------
  # Step 12 — Detect zero IP/AB for individual players (rate stats)
  # Warnings emitted in Step 14 where computations occur.
  # -------------------------------------------------------------------------

  # -------------------------------------------------------------------------
  # Steps 13-14 — Compute per-category SGP columns
  # Collect into a list, then assemble the data frame in Step 15.
  # -------------------------------------------------------------------------

  n_players <- nrow(projections)

  # Pre-allocate named list of SGP vectors
  sgp_cols <- stats::setNames(
    vector("list", length(scored_cats)),
    paste0("sgp_", scored_cats)
  )

  # ---- Counting stats (Step 13) -------------------------------------------
  for (cat in count_cats) {
    col_sgp <- paste0("sgp_", cat)
    if (cat %in% missing_cats) {
      sgp_cols[[col_sgp]] <- rep(NA_real_, n_players)
    } else {
      sgp_cols[[col_sgp]] <- projections[[cat]] / denominators[cat]
    }
  }

  # ---- Rate stats (Step 14) ------------------------------------------------

  # ERA
  if ("ERA" %in% rate_cats) {
    col_sgp <- "sgp_ERA"
    if ("ERA" %in% missing_cats) {
      sgp_cols[[col_sgp]] <- rep(NA_real_, n_players)
    } else {
      # 14a. Detect zero-IP players
      zero_ip <- projections$IP == 0 | is.na(projections$IP)
      if (any(zero_ip)) {
        zero_ip_names <- if ("NAME" %in% names(projections)) {
          projections$NAME[zero_ip]
        } else {
          which(zero_ip)
        }
        cli::cli_warn(
          paste0(
            "Player(s) with 0 or NA projected IP: ",
            paste(zero_ip_names, collapse = ", "),
            ". {.code sgp_ERA} and {.code sgp_WHIP} set to {.code NA}."
          ),
          class = "rotostats_warning_missing_category_column"
        )
      }
      # 14b. Compute ERA SGP vectorized
      player_ER   <- projections$ERA * projections$IP / 9
      blended_era <- (pool_ER + player_ER) * 9 / (pool_IP + projections$IP)
      era_sgp_vec <- (avg_ERA - blended_era) / denominators["ERA"]
      era_sgp_vec[zero_ip] <- NA_real_
      sgp_cols[[col_sgp]] <- era_sgp_vec
    }
  }

  # WHIP
  if ("WHIP" %in% rate_cats) {
    col_sgp <- "sgp_WHIP"
    if ("WHIP" %in% missing_cats) {
      sgp_cols[[col_sgp]] <- rep(NA_real_, n_players)
    } else {
      # 14c. Reuse or re-derive zero_ip
      zero_ip <- projections$IP == 0 | is.na(projections$IP)
      # (warn already emitted if ERA was also scored — avoid double warning)
      if (any(zero_ip) && !"ERA" %in% rate_cats) {
        zero_ip_names <- if ("NAME" %in% names(projections)) {
          projections$NAME[zero_ip]
        } else {
          which(zero_ip)
        }
        cli::cli_warn(
          paste0(
            "Player(s) with 0 or NA projected IP: ",
            paste(zero_ip_names, collapse = ", "),
            ". {.code sgp_WHIP} set to {.code NA}."
          ),
          class = "rotostats_warning_missing_category_column"
        )
      }
      player_WH    <- projections$WHIP * projections$IP
      blended_whip <- (pool_WH + player_WH) / (pool_IP + projections$IP)
      whip_sgp_vec <- (avg_WHIP - blended_whip) / denominators["WHIP"]
      whip_sgp_vec[zero_ip] <- NA_real_
      sgp_cols[[col_sgp]] <- whip_sgp_vec
    }
  }

  # AVG
  if ("AVG" %in% rate_cats) {
    col_sgp <- "sgp_AVG"
    if ("AVG" %in% missing_cats) {
      sgp_cols[[col_sgp]] <- rep(NA_real_, n_players)
    } else {
      # 14d. Detect zero-AB players
      zero_ab <- projections$AB == 0 | is.na(projections$AB)
      if (any(zero_ab)) {
        zero_ab_names <- if ("NAME" %in% names(projections)) {
          projections$NAME[zero_ab]
        } else {
          which(zero_ab)
        }
        cli::cli_warn(
          paste0(
            "Player(s) with 0 or NA projected AB: ",
            paste(zero_ab_names, collapse = ", "),
            ". {.code sgp_AVG} set to {.code NA}."
          ),
          class = "rotostats_warning_missing_category_column"
        )
      }
      # 14e. Compute AVG SGP vectorized (sign flip: blended - avg, not avg - blended)
      player_H    <- projections$AVG * projections$AB
      blended_avg <- (pool_H + player_H) / (pool_AB + projections$AB)
      avg_sgp_vec <- (blended_avg - avg_AVG) / denominators["AVG"]
      avg_sgp_vec[zero_ab] <- NA_real_
      sgp_cols[[col_sgp]] <- avg_sgp_vec
    }
  }

  # -------------------------------------------------------------------------
  # Step 15 — Assemble result data frame
  # -------------------------------------------------------------------------
  result <- as.data.frame(sgp_cols, row.names = seq_len(n_players))

  # total_sgp: rowSums with na.rm = FALSE so NA propagates
  sgp_col_names <- paste0("sgp_", scored_cats)
  result$total_sgp <- rowSums(result[, sgp_col_names, drop = FALSE], na.rm = FALSE)

  result
}
