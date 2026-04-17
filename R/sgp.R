# sgp() — per-player Standings-Gain-Point converter

# ---------------------------------------------------------------------------
# sgp()
# ---------------------------------------------------------------------------

#' Convert projected stats into SGP units per player
#'
#' @description
#' Converts per-player projected statistics into SGP (Standings Gain Points)
#' units using pre-calibrated denominators from [sgp_denominators()].  Each
#' category SGP measures how many standings places that player's projected
#' contribution is worth in your league.
#'
#' @details
#' ## Counting categories
#'
#' For every non-rate scored category `c`, the conversion is a simple vectorized
#' division applied across all players at once:
#'
#' \deqn{SGP[i, c] = projected[i, c] \;/\; denominator[c]}
#'
#' No player-level loop is used; computation is fully vectorized.
#'
#' ## Rate categories (ERA, WHIP, AVG) — blended-pool method
#'
#' With `rate_conversion = "blended_pool"` and
#' `pool_baseline = "projection_pool"` (the defaults), rate-stat SGP is
#' computed via the *blended-pool* marginal contribution formula.  Pool
#' constants (`pool_ER`, `pool_IP`, `pool_WH`, `pool_H`, `pool_AB`) are
#' derived once from the top-`pool_size_p` / top-`pool_size_h` projected
#' players by playing time (IP for pitchers, AB for hitters).  Pool sizes
#' are taken from `pool_sizes(league_config)` and therefore automatically
#' reflect your league's roster structure.
#'
#' The per-player formulas are:
#'
#' \deqn{ERA\_SGP[i]  = (avg\_ERA  - (pool\_ER  + player\_ER)  \times 9 \;/\; (pool\_IP + player\_IP)) \;/\; d_{ERA}}
#' \deqn{WHIP\_SGP[i] = (avg\_WHIP - (pool\_WH  + player\_WH)  \;/\; (pool\_IP + player\_IP)) \;/\; d_{WHIP}}
#' \deqn{AVG\_SGP[i]  = ((pool\_H  + player\_H)  \;/\; (pool\_AB + player\_AB) - avg\_AVG) \;/\; d_{AVG}}
#'
#' Note the sign flip for AVG: higher batting average helps the team, whereas
#' higher ERA or WHIP hurts it, so the subtraction order is reversed.
#'
#' `avg_ERA`, `avg_WHIP`, and `avg_AVG` are derived from the most recent
#' non-excluded year in `league_history$team_season` using IP-weighted (ERA,
#' WHIP) or AB-weighted (AVG) means across all teams.  A `cli_inform()` message
#' names the year used so callers can verify the baseline.
#'
#' ## `total_sgp`
#'
#' `total_sgp` is `rowSums()` across all `sgp_<CAT>` columns with
#' `na.rm = FALSE`: any player with a missing per-category SGP also has a
#' missing `total_sgp`.  This surfaces data quality issues rather than hiding
#' them in a partial sum.
#'
#' ## Validation order
#'
#' Checks are applied in this order so that the most specific error wins:
#' 1. `rate_conversion` must be one of the five recognized values (else
#'    `rotostats_error_invalid_rate_conversion`).
#' 2. When `rate_conversion = "blended_pool"`, `attr(denominators,
#'    "rate_conversion")` must also be `"blended_pool"` — mismatched units
#'    abort with `rotostats_error_invalid_rate_conversion`.
#' 3. `"per_player"`, `"universal_constants"`, `"team_ip_normalized"` abort
#'    with `rotostats_error_not_implemented`.
#' 4. `"fixed_baseline"` delegates to [convert_rate_stats()] (stub; also aborts
#'    with `rotostats_error_not_implemented`).
#' 5. Required inputs (`league_history`, `league_config`) are validated only
#'    after the method is confirmed.
#'
#' ## SVHD handling
#'
#' If `"SVHD"` is a scored category but the column is absent from `projections`,
#' `sgp()` attempts to derive it as `SV + HLD` (also accepts `HD` as the holds
#' column name).  A one-time informational message is emitted via
#' `rlang::inform()` asking the caller to verify the definition matches their
#' league's hold rules.
#'
#' ## Upstream helper
#'
#' `sgp()` consumes the output of [sgp_denominators()].  See that function for
#' how denominators are calibrated from historical team-season standings data.
#'
#' @param projections A data frame with one row per player. Must include a
#'   column for each scored category in `names(denominators)`, plus `IP` (for
#'   ERA/WHIP pool construction) and `AB` (for AVG pool construction) when
#'   those rate stats are scored. Column names are normalized to uppercase at
#'   entry; no message is emitted for the normalization.
#' @param denominators An `sgp_denominators` S3 object produced by
#'   [sgp_denominators()]. The scored categories are `names(denominators)`.
#'   **Important:** `attr(denominators, "rate_conversion")` is read from the
#'   outer S3 object — not from `denominators$denominators` — and must match
#'   the `rate_conversion` argument when `rate_conversion = "blended_pool"`.
#' @param league_history A `league_history` S3 object (see [league_history()])
#'   or a duck-typed list with a `$team_season` data frame.  Required when
#'   `rate_conversion = "blended_pool"`.  `$team_season` must contain `IP` and
#'   `AB` columns alongside the rate-stat columns so that IP- and AB-weighted
#'   baseline means can be computed.
#' @param rate_conversion Character scalar.  One of `"blended_pool"` (default),
#'   `"fixed_baseline"`, `"per_player"`, `"universal_constants"`, or
#'   `"team_ip_normalized"`.  The last three abort with
#'   `rotostats_error_not_implemented`.  `"fixed_baseline"` delegates to
#'   [convert_rate_stats()] (stub; also aborts).  When `"blended_pool"`,
#'   `attr(denominators, "rate_conversion")` must equal `"blended_pool"` or
#'   `sgp()` aborts with `rotostats_error_invalid_rate_conversion`.
#' @param pool_baseline Character scalar.  Determines how pool constants are
#'   constructed for the blended-pool rate-stat formulas.  Currently only
#'   `"projection_pool"` (the default) is implemented.
#' @param league_config A `league_config` S3 object from [league_config()].
#'   Required when `rate_conversion = "blended_pool"` and
#'   `pool_baseline = "projection_pool"`.  Passed to `pool_sizes()` (an
#'   internal helper in `R/league-config.R`) to derive `pool_size_p` and
#'   `pool_size_h` from the league's roster structure rather than hard-coding
#'   roster depth.
#' @param baseline_era Numeric scalar or `NULL`.  Explicit ERA baseline used
#'   only when `rate_conversion = "fixed_baseline"`.  Passed through to
#'   [convert_rate_stats()]; ignored for `"blended_pool"`.
#' @param baseline_whip Numeric scalar or `NULL`.  Explicit WHIP baseline.
#'   See `baseline_era`.
#' @param baseline_avg Numeric scalar or `NULL`.  Explicit AVG baseline.
#'   See `baseline_era`.
#'
#' @return A plain `data.frame` (no attributes) with:
#'   \describe{
#'     \item{`sgp_<CAT>`}{One numeric column per scored category, named
#'       `sgp_<CAT>` where `<CAT>` is the uppercase category name
#'       (e.g., `sgp_HR`, `sgp_ERA`, `sgp_AVG`).  Column order matches
#'       `names(denominators)`.  Players missing a scored category column, or
#'       with 0 / NA projected playing time for a rate stat, receive `NA` in
#'       that column.}
#'     \item{`total_sgp`}{`rowSums()` across all `sgp_<CAT>` columns
#'       (`na.rm = FALSE`).  `NA` when any per-category SGP is `NA`.}
#'   }
#'   Row order matches `projections`.
#'
#' @section Warnings:
#'
#' `sgp()` emits `rotostats_warning_missing_category_column` (via
#' [cli::cli_warn()]) in two situations:
#' \enumerate{
#'   \item A scored category column is entirely absent from `projections` —
#'         the affected `sgp_<CAT>` column is filled with `NA`.
#'   \item A player has 0 or `NA` projected IP (when ERA or WHIP is scored) or
#'         projected AB (when AVG is scored) — that player's rate-stat SGP is
#'         set to `NA`.
#' }
#'
#' @seealso
#' \code{sgp_denominators()} for calibrating the denominators consumed by
#' this function; [league_config()] for constructing the league configuration
#' object; [league_history()] for the historical data object.
#'
#' @examples
#' # Toy example: two counting categories, three players
#' history <- list(
#'   team_season = data.frame(
#'     year    = c(2022L, 2022L, 2022L, 2023L, 2023L, 2023L),
#'     team_id = rep(c("A", "B", "C"), 2),
#'     HR      = c(150, 180, 210, 155, 185, 215),
#'     R       = c(650, 700, 740, 660, 710, 750),
#'     IP      = c(1350, 1380, 1410, 1360, 1390, 1420),
#'     AB      = c(5400, 5500, 5600, 5420, 5520, 5620),
#'     stringsAsFactors = FALSE
#'   )
#' )
#'
#' config <- league_config(
#'   n_teams       = 12L,
#'   roster_slots  = c(C = 1L, `1B` = 1L, `2B` = 1L, `3B` = 1L,
#'                     SS = 1L, OF = 3L, DH = 1L),
#'   pitcher_slots = 9L,
#'   budget        = 260L,
#'   budget_split  = 0.67,
#'   categories    = c("HR", "R")
#' )
#'
#' denoms <- sgp_denominators(
#'   history,
#'   scoring_categories = c("HR", "R"),
#'   exclude_years      = integer(0)
#' )
#'
#' projections <- data.frame(
#'   HR = c(40L, 25L, 10L),
#'   R  = c(90L, 80L, 70L),
#'   IP = c(0L,  0L,  0L),    # pitching not scored — zeroes are fine
#'   AB = c(500L, 450L, 400L)
#' )
#'
#' \dontrun{
#' # blended_pool requires league_history and league_config:
#' result <- sgp(
#'   projections   = projections,
#'   denominators  = denoms,
#'   league_history = history,
#'   league_config  = config
#' )
#' result  # data frame: sgp_HR, sgp_R, total_sgp
#' }
#'
#' @importFrom utils head
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
        .frequency    = "once",
        .frequency_id = "sgp_svhd_derivation"
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
