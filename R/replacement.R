# replacement.R — exported functions replacement_level() and
# replacement_from_prices()
#
# Internal helpers live in R/replacement_internal.R.
# Constants live in R/replacement_params.R.

# Suppress R CMD check notes for package-internal symbols that are
# not imported via NAMESPACE (they live in the same package namespace).
utils::globalVariables(c("PRIMARY_HITTER_SLOTS", "pool_sizes", "sgp"))

# ---------------------------------------------------------------------------
# replacement_level()
# ---------------------------------------------------------------------------

#' Per-position replacement-level stat lines
#'
#' @description
#' Computes per-position replacement-level stat lines that serve as the
#' zero-dollar baseline for PAR (Points Above Replacement) — the direct
#' analog of WAR in rotisserie auction valuation.  A player who projects to
#' exactly replacement level at their position has \$0 value; positive PAR
#' drives auction dollar values.
#'
#' The roster boundary at each position is the player at rank
#' `n_teams × roster_slots[pos]` in the sorted projection pool.  A symmetric
#' boundary band of ±K players around the boundary smooths cliff effects from
#' individual projection outliers.  Cliff detection truncates the band at
#' genuine talent gaps.  An internal iteration loop (controlled by
#' `max_iter` and `tol`) resolves the circularity between player ranking and
#' replacement level when `sort_by = "sgp"` or `multi_pos = "highest_par"`.
#'
#' @param projections A data frame with one row per projected player.
#'   Required columns: `player_id`, `player_name`, `pos_eligibility`,
#'   `team`, `league`, plus one column per scored category in `config$categories`.
#'   Pitcher rows require `IP`; hitter rows require `AB` when `AVG`, `OBP`, or
#'   `SLG` is a scored category.  Column names are normalized to uppercase at
#'   entry (no message emitted).  `pos_eligibility` is pipe-delimited
#'   (`"C"`, `"1B|3B"`, `"SP|RP"`); the first entry is the primary position.
#'   Optional `role` column (`"SP"` / `"RP"`) overrides IP-based inference.
#' @param config A `league_config` object from `league_config()`.
#' @param sort_by Character scalar.  `"zscore"` (default) — composite z-score
#'   across projected stats; or `"sgp"` — total SGP from `sgp()`.  When
#'   `sort_by = "sgp"`, `sgp_denominators` is required.
#' @param sgp_denominators An `sgp_denominators` S3 object from
#'   `sgp_denominators()`.  Required when `sort_by = "sgp"`.  Also used
#'   when `boundary_rate_method = "sgp_pool"`.
#' @param boundary_method Character scalar.  `"head_count"` (default) —
#'   boundary at `n_teams × roster_slots[pos]`; or `"playing_time"` —
#'   boundary at the player whose cumulative PA/IP crosses the league
#'   deployment threshold.
#' @param seed_method Character scalar.  `"hierarchy"` (default) — pass-1
#'   seed uses scarcity ordering C > SS > 2B > 3B > 1B > OF; or
#'   `"historical_priors"` — seeds from `league_history` replacement-level
#'   z-scores (requires `league_history`).
#' @param positional_adjustment_method Character scalar.
#'   `"fvarz"` (default), `"sgp"`, `"dollar"`, or `"posblend"`.  Controls
#'   how scarcity premiums are computed.
#' @param pos_weight Numeric in `[0, 1]` or `NULL`.  Required when
#'   `positional_adjustment_method = "posblend"`.
#' @param boundary_rate_method Character scalar.  `"raw_ip"` (default) —
#'   IP-weighted rate-stat contributions independent of league depth; or
#'   `"sgp_pool"` — pool-marginal method (requires `sgp_denominators`
#'   calibrated with `rate_conversion = "blended_pool"`).
#' @param cliff_method Character scalar.  `"mad"` (default), `"fisher_jenks"`,
#'   or `"gap_ratio"`.  Controls cliff detection algorithm.
#' @param cliff_gap_ratio_threshold Numeric in `(0, 1)`.  Threshold for
#'   `cliff_method = "gap_ratio"` (default `0.375`).
#' @param catcher_adjustment_method Character scalar.  `"split_pool"`
#'   (default), `"positional_default"`, `"partial_offset"`, or `"none"`.
#'   Controls catcher-specific scarcity-premium override.
#' @param sp_ip_threshold Numeric.  IP cutoff for SP vs. RP inference when
#'   no `role` column is present (default `100`).
#' @param normalize_to_season Logical.  If `TRUE`, normalize counting stats
#'   to full-season baselines (hitters 600 PA / 550 AB, SP 200 IP, RP 70 IP).
#'   Default `FALSE`.
#' @param band_width Integer or `NULL`.  Band half-width K.  Overrides
#'   `replacement_params$band_width_K` when non-NULL.
#' @param cliff_threshold Numeric.  Cliff detection threshold (default `1.5`).
#'   Overrides `replacement_params$cliff_threshold`.
#' @param rate_denominators Named character vector or `NULL`.  Extends or
#'   overrides the built-in rate-stat denominator lookup (see
#'   [rate_stat_denominators()]).
#' @param league_history A `league_history` object from `league_history()`
#'   or `NULL`.  Used for \$1 calibration cross-check and IP/AB divergence
#'   validation.  Required when `seed_method = "historical_priors"`.
#' @param trim_method Character scalar.  `"iqr"` (default), `"mad"`, or
#'   `"kde"`.  Controls outlier trimming of the \$1 auction pool from
#'   `league_history$prices` when `is_keeper` column is absent.
#' @param multi_pos Character scalar.  `"highest_par"` (default), `"primary"`,
#'   `"all"`, or `"custom"`.  Controls multi-eligible position assignment.
#' @param position_assignments Named character vector (`player_id` → position)
#'   or `NULL`.  Supplied by `dollar_values()` on pass 2+; `NULL` on first
#'   call.
#' @param replacement_params Named list.  Override specific entries of
#'   `default_replacement_params` (e.g., `list(band_width_K = 2L)`).
#'   `cycle_history_window` (integer, default 5L): depth of the rolling
#'   assignment-hash history window used to detect higher-order convergence
#'   cycles (periods 2 through N) in the `multi_pos = "highest_par"` loop.
#'   Increase if you observe non-convergence in pools with many near-boundary
#'   multi-eligible players.
#' @param max_iter Positive integer.  Maximum convergence passes (default `25L`).
#' @param tol Numeric.  Convergence tolerance in SGP units (default `0.01`).
#' @param verbose Logical.  If `TRUE`, emit diagnostic messages and
#'   verbose-gated warnings.  Default `FALSE`.
#'
#' @return A named list with elements:
#'   \describe{
#'     \item{`replacement_stats`}{data.frame — one row per position (positions
#'       with `roster_slots > 0`, plus SP and RP).  Columns: `position`,
#'       one column per scored category, `IP` for pitcher rows, `AB` for hitter
#'       rows when AVG/OBP/SLG scored, `n_band_players`, `cliff_detected`.}
#'     \item{`positional_adjustments`}{Named numeric vector of scarcity
#'       premiums by position, or `NULL` on pass 1 when
#'       `positional_adjustment_method = "sgp"`.}
#'     \item{`cliff_metric`}{data.frame — one row per position with columns
#'       `position`, `cliff_detected`, `cliff_location`, `cliff_magnitude`,
#'       `swingman`, `n_band_players`.}
#'     \item{`two_way_players`}{Character vector of `player_id`s with PAR > 0
#'       in both hitter and pitcher roles.}
#'     \item{`pool_diagnostics`}{List with `position_sd_ratio`: named numeric
#'       vector of within-position SD / global SD per scored category.}
#'     \item{`method`}{`"boundary_band"`.}
#'     \item{`params`}{Named list — convergence info, band/cliff settings,
#'       iteration count, stat_units.}
#'   }
#'   Attributes: `stat_units`, `config`, `projections`, `position_assignments`,
#'   `converged`, `iterations`, `delta`.
#'
#' @seealso `replacement_from_prices()`, `default_replacement_params`,
#'   `rate_stat_denominators()`, `league_config()`, `sgp_denominators()`
#'
#' @examples
#' \dontrun{
#' cfg <- league_config(
#'   n_teams       = 2L,
#'   roster_slots  = c(C = 1L, `1B` = 1L),
#'   pitcher_slots = c(SP = 1L, RP = 1L),
#'   categories    = c("HR", "RBI"),
#'   budget        = 260L
#' )
#'
#' proj <- data.frame(
#'   player_id       = paste0("p", 1:8),
#'   player_name     = paste0("Player", 1:8),
#'   pos_eligibility = c("C", "C", "C", "1B", "1B", "1B", "SP", "RP"),
#'   team            = rep("TM", 8),
#'   league          = rep("AL", 8),
#'   HR              = c(15, 12, 9, 30, 28, 25, 10, 3),
#'   RBI             = c(50, 45, 40, 90, 88, 85, 35, 15),
#'   IP              = c(NA, NA, NA, NA, NA, NA, 180, 65),
#'   AB              = c(350, 320, 300, 500, 490, 480, NA, NA),
#'   stringsAsFactors = FALSE
#' )
#'
#' result <- replacement_level(proj, cfg)
#' result$replacement_stats
#' }
#'
#' @importFrom stats setNames sd mad density weighted.mean
#' @importFrom utils head
#' @export
replacement_level <- function(
  projections,
  config,
  sort_by                      = "zscore",
  sgp_denominators             = NULL,
  boundary_method              = "head_count",
  seed_method                  = "hierarchy",
  positional_adjustment_method = "fvarz",
  pos_weight                   = NULL,
  boundary_rate_method         = "raw_ip",
  cliff_method                 = "mad",
  cliff_gap_ratio_threshold    = 0.375,
  catcher_adjustment_method    = "split_pool",
  sp_ip_threshold              = 100,
  normalize_to_season          = FALSE,
  band_width                   = NULL,
  cliff_threshold              = 1.5,
  rate_denominators            = NULL,
  league_history               = NULL,
  trim_method                  = "iqr",
  multi_pos                    = "highest_par",
  position_assignments         = NULL,
  replacement_params           = list(),
  max_iter                     = 25L,
  tol                          = 0.01,
  verbose                      = FALSE
) {
  call_env <- rlang::caller_env()

  # -------------------------------------------------------------------------
  # §4.1  Input validation
  # -------------------------------------------------------------------------

  checkmate::assert_data_frame(projections, min.rows = 1L)
  checkmate::assert_class(config, "league_config")
  checkmate::assert_choice(sort_by, c("zscore", "sgp"))

  if (sort_by == "sgp" && is.null(sgp_denominators)) {
    cli::cli_abort(
      c(
        "{.arg sgp_denominators} is required when {.code sort_by = \"sgp\"}.",
        "i" = "Supply a {.cls sgp_denominators} object from {.fn sgp_denominators}."
      ),
      class = "rotostats_error_missing_sgp_denominators",
      call  = call_env
    )
  }

  checkmate::assert_choice(boundary_method, c("head_count", "playing_time"))
  checkmate::assert_choice(seed_method, c("hierarchy", "historical_priors"))

  if (seed_method == "historical_priors" && is.null(league_history)) {
    cli::cli_abort(
      c(
        "{.arg league_history} is required when {.code seed_method = \"historical_priors\"}.",
        "i" = "Supply a {.cls league_history} object or switch to {.code seed_method = \"hierarchy\"}."
      ),
      class = "rotostats_error_missing_league_history",
      call  = call_env
    )
  }

  checkmate::assert_choice(
    positional_adjustment_method,
    c("fvarz", "sgp", "dollar", "posblend")
  )

  if (positional_adjustment_method == "posblend" && is.null(pos_weight)) {
    cli::cli_abort(
      c(
        "{.arg pos_weight} is required when {.code positional_adjustment_method = \"posblend\"}.",
        "i" = "Provide a numeric value in [0, 1]."
      ),
      class = "rotostats_error_missing_pos_weight",
      call  = call_env
    )
  }

  if (positional_adjustment_method == "posblend" && !is.null(pos_weight)) {
    checkmate::assert_number(pos_weight, lower = 0, upper = 1)
  }

  checkmate::assert_choice(boundary_rate_method, c("raw_ip", "sgp_pool"))

  if (boundary_rate_method == "sgp_pool" && !is.null(sgp_denominators)) {
    rc_attr <- attr(sgp_denominators, "rate_conversion")
    if (identical(rc_attr, "fixed_baseline")) {
      cli::cli_abort(
        c(
          "{.arg sgp_denominators} uses {.val fixed_baseline} rate conversion, which is incompatible with {.code boundary_rate_method = \"sgp_pool\"}.",
          "i" = "The {.val sgp_pool} ranking method requires pool-blended denominator units.",
          "i" = "Fix: re-run {.fn sgp_denominators} with {.code rate_conversion = \"blended_pool\"}, or switch to {.code boundary_rate_method = \"raw_ip\"}."
        ),
        class = "rotostats_error_rate_method_mismatch",
        call  = call_env
      )
    }
  }

  checkmate::assert_choice(cliff_method, c("mad", "fisher_jenks", "gap_ratio"))

  if (cliff_method == "gap_ratio") {
    checkmate::assert_number(cliff_gap_ratio_threshold, lower = 0, upper = 1)
  }

  checkmate::assert_choice(
    catcher_adjustment_method,
    c("split_pool", "positional_default", "partial_offset", "none")
  )

  checkmate::assert_number(sp_ip_threshold, lower = 0, finite = TRUE)
  checkmate::assert_flag(normalize_to_season)

  if (!is.null(band_width)) {
    checkmate::assert_int(band_width, lower = 1L)
  }

  checkmate::assert_number(cliff_threshold, lower = 0)

  if (!is.null(rate_denominators)) {
    checkmate::assert_character(rate_denominators, names = "named")
  }

  checkmate::assert_choice(trim_method, c("iqr", "mad", "kde"))
  checkmate::assert_choice(multi_pos, c("highest_par", "primary", "all", "custom"))
  checkmate::assert_int(max_iter, lower = 1L)
  checkmate::assert_number(tol, lower = 0)
  checkmate::assert_flag(verbose)
  checkmate::assert_list(replacement_params)

  # -------------------------------------------------------------------------
  # §4.1 steps 27-32: Column validation
  # -------------------------------------------------------------------------

  # Step 27: Normalize column names to uppercase
  names(projections) <- toupper(names(projections))

  # Build merged rate denominator lookup
  rate_lookup <- RATE_STAT_DENOMINATORS
  if (!is.null(rate_denominators)) {
    names(rate_denominators) <- toupper(names(rate_denominators))
    rate_lookup <- c(rate_lookup, rate_denominators)
    # later entries override earlier (rate_denominators wins)
    rate_lookup <- rate_lookup[!duplicated(names(rate_lookup), fromLast = TRUE)]
  }

  # Determine required columns
  cats_upper <- toupper(config$categories)
  needs_ab   <- any(cats_upper %in% c("AVG", "OBP", "SLG", "OPS", "WOBA",
                                       "K%", "BB%"))
  needs_ip   <- TRUE  # always need IP for pitcher pool determination

  stats_required <- union(cats_upper,
                          c(if (needs_ip) "IP" else character(0L),
                            if (needs_ab) "AB" else character(0L)))
  id_cols_required <- c("PLAYER_ID", "PLAYER_NAME", "POS_ELIGIBILITY", "LEAGUE")

  # Step 29: Check for missing columns
  all_required <- union(id_cols_required, stats_required)
  missing_cols <- setdiff(all_required, names(projections))
  if (length(missing_cols) > 0L) {
    cli::cli_abort(
      c(
        "{.arg projections} is missing required column{?s}: {.val {missing_cols}}.",
        "i" = "Ensure the data frame includes all required columns."
      ),
      class = "rotostats_error_missing_column",
      call  = call_env
    )
  }

  # Step 30: Type check on category columns
  for (cat in cats_upper) {
    if (cat %in% names(projections) && !is.numeric(projections[[cat]])) {
      cli::cli_abort(
        c(
          "Column {.val {cat}} in {.arg projections} must be numeric, not {.cls {class(projections[[cat]])[1]}}.",
          "i" = "Convert the column to numeric before calling {.fn replacement_level}."
        ),
        class = "rotostats_error_wrong_column_type",
        call  = call_env
      )
    }
  }

  # Step 31: league values
  checkmate::assert_subset(projections$LEAGUE, c("AL", "NL"))

  # Step 32: Rate stat denominator lookup
  # Any scored category that is a known rate stat must resolve in rate_lookup.
  # Use RATE_STAT_DENOMINATORS (the canonical set) as the membership test so
  # new rate stats added to RATE_STAT_DENOMINATORS are automatically covered
  # without requiring a parallel update to a hardcoded list here.
  known_rate_stats_upper <- toupper(names(RATE_STAT_DENOMINATORS))
  for (cat in cats_upper) {
    if (cat %in% known_rate_stats_upper) {
      if (!cat %in% names(rate_lookup)) {
        cli::cli_abort(
          c(
            "Rate stat {.val {cat}} is not in the rate-stat denominator lookup.",
            "i" = "Supply the denominator via {.code rate_denominators = c({cat} = \"AB\")}.",
            "i" = "See {.fn rate_stat_denominators} for the built-in lookup."
          ),
          class = "rotostats_error_unknown_rate_stat",
          call  = call_env
        )
      }
    }
  }

  # -------------------------------------------------------------------------
  # §5.1  Parameter resolution
  # -------------------------------------------------------------------------
  params <- utils::modifyList(default_replacement_params, replacement_params)

  checkmate::assert_int(params$cycle_history_window, lower = 2L, upper = 50L,
                        .var.name = "replacement_params$cycle_history_window")

  K <- if (!is.null(band_width)) as.integer(band_width) else as.integer(params$band_width_K)
  cliff_thr <- cliff_threshold   # top-level arg always wins

  # -------------------------------------------------------------------------
  # §5.2  SP/RP role inference and swingman flagging
  # -------------------------------------------------------------------------
  role_info     <- infer_pitcher_roles(projections, sp_ip_threshold)
  role          <- role_info$role
  swingman_flag <- role_info$swingman_flag

  # -------------------------------------------------------------------------
  # §5.3  Strip projections attribute for loop
  # -------------------------------------------------------------------------
  stored_projections <- projections

  # -------------------------------------------------------------------------
  # §5.12 League history validation (upfront)
  # -------------------------------------------------------------------------
  if (!is.null(league_history)) {
    .validate_league_history_inputs(
      projections   = projections,
      league_history = league_history,
      config        = config,
      params        = params,
      trim_method   = trim_method,
      verbose       = verbose,
      call_env      = call_env
    )
  }

  # -------------------------------------------------------------------------
  # Pool size computation
  # -------------------------------------------------------------------------
  ps          <- get_pool_sizes(config)
  pool_size_h <- ps$hitters
  pool_size_p <- ps$pitchers

  # Determine positions with slots > 0
  active_hitter_pos  <- names(config$roster_slots[config$roster_slots > 0])
  active_hitter_pos  <- intersect(active_hitter_pos, PRIMARY_HITTER_SLOTS)

  # SP/RP positions
  pitcher_slots <- config$pitcher_slots
  if (is.null(names(pitcher_slots))) {
    # Scalar — infer SP/RP split from projections or use default
    n_sp <- round(as.numeric(pitcher_slots) * params$sp_rp_split_default["SP"])
    n_rp <- as.numeric(pitcher_slots) - n_sp
    pitcher_slots_named <- c(SP = as.integer(n_sp), RP = as.integer(n_rp))
  } else {
    pitcher_slots_named <- pitcher_slots
  }

  active_pitcher_pos <- names(pitcher_slots_named[pitcher_slots_named > 0])

  all_positions <- c(active_hitter_pos, active_pitcher_pos)

  # Pool too small check
  for (pos in active_hitter_pos) {
    n_rostered <- config$n_teams * config$roster_slots[pos]
    pool_players <- sum(
      grepl(paste0("(^|\\|)", pos, "(\\||$)"),
            projections$POS_ELIGIBILITY)
    )
    if (pool_players < n_rostered) {
      cli::cli_abort(
        c(
          "Position {.val {pos}} has {pool_players} eligible players but requires {n_rostered} rostered.",
          "i" = "Expand the player pool or adjust {.arg config$roster_slots}."
        ),
        class = "rotostats_error_pool_too_small",
        call  = call_env
      )
    }
  }

  # -------------------------------------------------------------------------
  # §5.4  Pass 1 seed
  # -------------------------------------------------------------------------
  scarcity_order <- c("C", "SS", "2B", "3B", "1B", "OF")

  if (is.null(position_assignments)) {
    # Seed: assign each player to primary position
    primary_pos <- vapply(
      strsplit(projections$POS_ELIGIBILITY, "\\|"),
      function(x) x[1L],
      character(1L)
    )
    current_assignments <- stats::setNames(primary_pos, projections$PLAYER_ID)
  } else {
    current_assignments <- position_assignments
  }

  # -------------------------------------------------------------------------
  # §5.5  Iteration loop
  # -------------------------------------------------------------------------
  converged                <- FALSE
  pass                     <- 1L
  old_assignments          <- NULL
  assignment_hash_history  <- character(0L)  # rolling window of assignment hashes
  cycle_window             <- params$cycle_history_window
  old_repl_stats_vec       <- NULL
  delta                    <- NA_real_
  sgp_result               <- NULL

  # Determine which stats are counted (non-rate) vs rate
  rate_cats_scored <- intersect(cats_upper, names(rate_lookup))
  count_cats_scored <- setdiff(cats_upper, rate_cats_scored)

  repeat {
    # -----------------------------------------------------------------------
    # A. Sort players into position pools using current assignments
    # -----------------------------------------------------------------------

    # Hitter z-scores for sorting (pass 1 always uses z-scores)
    hitter_rows <- which(projections$LEAGUE %in% c("AL", "NL") &
                           !grepl("(SP|RP)", projections$POS_ELIGIBILITY))
    pitcher_rows_idx <- which(grepl("(SP|RP)", projections$POS_ELIGIBILITY))

    # Compute composite z-scores for hitters and pitchers
    # Only recompute on pass 1 or when sort_by = "zscore"
    if (pass == 1L || sort_by == "zscore") {
      order_col_h <- if ("AB" %in% names(projections)) "AB" else cats_upper[1]
      order_col_p <- "IP"

      z_hitters  <- compute_pool_zscores(
        projections[hitter_rows, , drop = FALSE],
        pool_size_h, cats_upper, K, order_col_h, is_pitcher = FALSE
      )
      z_pitchers <- compute_pool_zscores(
        projections[pitcher_rows_idx, , drop = FALSE],
        pool_size_p, cats_upper, K, order_col_p, is_pitcher = TRUE
      )

      # Assign composite scores back (length = all players)
      composite_score <- rep(NA_real_, nrow(projections))
      composite_score[hitter_rows]      <- z_hitters
      composite_score[pitcher_rows_idx] <- z_pitchers
    }

    if (pass >= 2L && sort_by == "sgp") {
      # Step F: Call sgp() internally to get total_sgp
      sgp_result <- sgp(
        projections   = projections,
        denominators  = sgp_denominators,
        league_history = league_history,
        league_config  = config
      )
      composite_score <- rep(NA_real_, nrow(projections))
      composite_score[hitter_rows]      <- sgp_result$total_sgp[hitter_rows]
      composite_score[pitcher_rows_idx] <- sgp_result$total_sgp[pitcher_rows_idx]
    }

    # -----------------------------------------------------------------------
    # B. Compute replacement stat line per position
    # -----------------------------------------------------------------------
    repl_stats_list  <- vector("list", length(all_positions))
    cliff_rows_list  <- vector("list", length(all_positions))
    names(repl_stats_list) <- all_positions
    names(cliff_rows_list) <- all_positions

    for (pos in all_positions) {
      is_pitcher_pos <- pos %in% c("SP", "RP")

      # Filter pool to players assigned to this position
      if (is_pitcher_pos) {
        # Pitchers assigned to SP or RP based on role
        pos_mask <- grepl("(SP|RP)", projections$POS_ELIGIBILITY) &
                    !is.na(role) & role == pos
      } else {
        player_ids_at_pos <- names(current_assignments)[current_assignments == pos]
        pos_mask <- projections$PLAYER_ID %in% player_ids_at_pos
      }

      pos_indices    <- which(pos_mask)
      pos_composite  <- composite_score[pos_mask]

      if (length(pos_indices) == 0L) {
        # No players at this position — create empty row
        empty_stats        <- stats::setNames(rep(NA_real_, length(cats_upper)), cats_upper)
        repl_stats_list[[pos]] <- c(empty_stats, list(
          n_band_players = 0L,
          cliff_detected = FALSE
        ))
        cliff_rows_list[[pos]] <- list(
          position       = pos,
          cliff_detected = FALSE,
          cliff_location = NA_integer_,
          cliff_magnitude = NA_real_,
          swingman       = FALSE,
          n_band_players = 0L
        )
        next
      }

      # Sort by composite score (descending = best first)
      sorted_order   <- order(pos_composite, decreasing = TRUE, na.last = TRUE)
      sorted_indices <- pos_indices[sorted_order]

      n_rostered_pos <- if (is_pitcher_pos) {
        config$n_teams * pitcher_slots_named[pos]
      } else {
        config$n_teams * config$roster_slots[pos]
      }

      # Guard: pool must be at least n_rostered_pos
      if (length(sorted_indices) < n_rostered_pos) {
        cli::cli_abort(
          c(
            "Position {.val {pos}}: only {length(sorted_indices)} eligible players but {n_rostered_pos} need to be rostered.",
            "i" = "Expand the player pool or adjust league configuration."
          ),
          class = "rotostats_error_pool_too_small",
          call  = call_env
        )
      }

      # Compute band indices
      band_info  <- compute_band_indices(n_rostered_pos, length(sorted_indices), K)
      K_eff      <- band_info$K_eff
      band_upper <- sorted_indices[band_info$band_upper]
      band_lower <- sorted_indices[band_info$band_lower]
      B_all      <- c(band_upper, band_lower)

      # Check for swingman in band
      has_swingman <- any(swingman_flag[B_all])

      # Cliff detection on B_lower for a primary stat
      # Use the primary scoring stat for cliff detection
      primary_cliff_cat <- if (is_pitcher_pos && "ERA" %in% cats_upper) {
        "ERA"
      } else if (!is_pitcher_pos && "HR" %in% cats_upper) {
        "HR"
      } else {
        cats_upper[1L]
      }

      B_lower_vals <- if (primary_cliff_cat %in% names(projections) && length(band_lower) > 0L) {
        projections[[primary_cliff_cat]][band_lower]
      } else {
        numeric(0L)
      }

      B_all_vals <- if (primary_cliff_cat %in% names(projections)) {
        projections[[primary_cliff_cat]][B_all]
      } else {
        numeric(0L)
      }

      cliff_result <- detect_cliff(
        B_lower_values        = B_lower_vals,
        band_all_values       = B_all_vals,
        cliff_method          = cliff_method,
        cliff_threshold       = cliff_thr,
        cliff_gap_ratio_threshold = cliff_gap_ratio_threshold,
        cliff_min_n           = params$cliff_min_n
      )

      # If cliff detected, truncate band at j-1 in lower half
      B_final <- if (cliff_result$cliff_detected && !is.na(cliff_result$cliff_location)) {
        j <- cliff_result$cliff_location
        # Keep only band players up to b + j - 1 in the lower half
        truncated_lower <- if (j > 1L) band_lower[seq_len(j - 1L)] else integer(0L)
        c(band_upper, truncated_lower)
      } else {
        B_all
      }

      # Verbose: swingman band ERA/WHIP shift check
      if (verbose && has_swingman && is_pitcher_pos) {
        sw_in_band <- swingman_flag[B_final]
        if (any(sw_in_band) && "ERA" %in% names(projections) && "IP" %in% names(projections)) {
          with_sw    <- projections[B_final, , drop = FALSE]
          without_sw <- projections[B_final[!sw_in_band], , drop = FALSE]
          if (nrow(without_sw) > 0 && "IP" %in% names(with_sw)) {
            ip_sum_w  <- sum(with_sw$IP, na.rm = TRUE)
            ip_sum_wo <- sum(without_sw$IP, na.rm = TRUE)
            era_w  <- if (ip_sum_w  > 0) sum(with_sw$ERA  * with_sw$IP,  na.rm = TRUE) / ip_sum_w  else NA
            era_wo <- if (ip_sum_wo > 0) sum(without_sw$ERA * without_sw$IP, na.rm = TRUE) / ip_sum_wo else NA
            if (!is.na(era_w) && !is.na(era_wo) && abs(era_w - era_wo) > 0.10) {
              cli::cli_inform(
                "Swingman in {pos} band shifts mean ERA by {round(abs(era_w - era_wo), 3)}."
              )
            }
          }
        }
      }

      # Compute replacement stat line for B_final
      include_ip <- is_pitcher_pos || "IP" %in% cats_upper
      include_ab <- !is_pitcher_pos && needs_ab

      band_df   <- projections[B_final, , drop = FALSE]
      repl_line <- compute_replacement_stat_line(
        band_df     = band_df,
        scored_cats = cats_upper,
        rate_cats   = rate_cats_scored,
        include_ip  = include_ip,
        include_ab  = include_ab
      )

      n_band <- length(B_final)

      repl_stats_list[[pos]] <- c(
        as.list(repl_line),
        list(n_band_players = as.integer(n_band),
             cliff_detected  = cliff_result$cliff_detected)
      )

      cliff_rows_list[[pos]] <- list(
        position        = pos,
        cliff_detected  = cliff_result$cliff_detected,
        cliff_location  = cliff_result$cliff_location,
        cliff_magnitude = cliff_result$cliff_magnitude,
        swingman        = has_swingman,
        n_band_players  = as.integer(n_band)
      )
    }

    # Determine which aux columns exist across all position rows
    has_ip_col <- any(vapply(repl_stats_list, function(r) "IP" %in% names(r), logical(1L)))
    has_ab_col <- any(vapply(repl_stats_list, function(r) "AB" %in% names(r), logical(1L)))
    aux_cols_all <- c(
      if (has_ip_col) "IP" else character(0L),
      if (has_ab_col) "AB" else character(0L)
    )

    # Assemble replacement_stats data frame with uniform columns
    repl_stats_df <- do.call(rbind, lapply(names(repl_stats_list), function(pos) {
      row <- repl_stats_list[[pos]]
      # Build a one-row data.frame with a fixed column set
      # category stats
      vals <- lapply(cats_upper, function(cat) {
        if (cat %in% names(row)) as.numeric(row[[cat]]) else NA_real_
      })
      names(vals) <- cats_upper
      # aux cols
      for (ac in aux_cols_all) {
        vals[[ac]] <- if (ac %in% names(row)) as.numeric(row[[ac]]) else NA_real_
      }
      vals[["n_band_players"]] <- as.integer(row[["n_band_players"]])
      vals[["cliff_detected"]]  <- as.logical(row[["cliff_detected"]])
      vals[["position"]]        <- pos
      as.data.frame(vals, stringsAsFactors = FALSE)
    }))

    # Reorder columns: position first, then cats, then IP, AB, n_band, cliff
    stat_cols    <- cats_upper
    col_order    <- c("position", stat_cols, aux_cols_all, "n_band_players", "cliff_detected")
    col_order    <- intersect(col_order, names(repl_stats_df))
    repl_stats_df <- repl_stats_df[, col_order, drop = FALSE]
    rownames(repl_stats_df) <- NULL

    # Assemble cliff_metric data frame
    cliff_metric_df <- do.call(rbind, lapply(cliff_rows_list, function(r) {
      as.data.frame(r, stringsAsFactors = FALSE)
    }))
    rownames(cliff_metric_df) <- NULL

    # -----------------------------------------------------------------------
    # C/D. Compute positional adjustments
    # -----------------------------------------------------------------------
    scarcity_premium <- compute_positional_adjustments(
      replacement_stats            = repl_stats_df,
      config                       = config,
      positional_adjustment_method = positional_adjustment_method,
      catcher_adjustment_method    = catcher_adjustment_method,
      pos_weight                   = pos_weight,
      sgp_denominators             = sgp_denominators,
      pass_number                  = pass,
      verbose                      = verbose
    )

    # -----------------------------------------------------------------------
    # E. Zero-sum assertion (if adjustments computed)
    # -----------------------------------------------------------------------
    if (!is.null(scarcity_premium)) {
      active_primary_hitter_pos <- intersect(active_hitter_pos, PRIMARY_HITTER_SLOTS)
      assert_zero_sum(
        scarcity_premium           = scarcity_premium,
        config                     = config,
        catcher_adjustment_method  = catcher_adjustment_method,
        primary_hitter_slots       = active_primary_hitter_pos
      )
    }

    # -----------------------------------------------------------------------
    # G. Multi-position reassignment (multi_pos = "highest_par")
    # -----------------------------------------------------------------------
    new_assignments <- current_assignments

    if (multi_pos == "highest_par" && pass >= 2L) {
      # For each multi-eligible player, assign to position with highest PAR
      multi_eligible_mask <- grepl("\\|", projections$POS_ELIGIBILITY) &
                             !grepl("(SP|RP)", projections$POS_ELIGIBILITY)
      multi_player_ids <- projections$PLAYER_ID[multi_eligible_mask]

      for (pid in multi_player_ids) {
        player_row  <- projections[projections$PLAYER_ID == pid, , drop = FALSE]
        elig_pos    <- strsplit(player_row$POS_ELIGIBILITY, "\\|")[[1]]
        elig_hitter <- setdiff(elig_pos, c("SP", "RP", "P"))
        elig_hitter <- intersect(elig_hitter, active_hitter_pos)

        if (length(elig_hitter) <= 1L) next

        # Compute PAR at each eligible position
        par_vals <- vapply(elig_hitter, function(p) {
          repl_row <- repl_stats_df[repl_stats_df$position == p, , drop = FALSE]
          if (nrow(repl_row) == 0L) return(-Inf)
          compute_par_at_pos(player_row, repl_row, cats_upper)
        }, numeric(1L))

        best_pos <- elig_hitter[which.max(par_vals)]
        new_assignments[pid] <- best_pos
      }
    } else if (multi_pos == "primary") {
      # Always use primary position
      primary_pos <- vapply(
        strsplit(projections$POS_ELIGIBILITY, "\\|"),
        function(x) x[1L],
        character(1L)
      )
      new_assignments <- stats::setNames(primary_pos, projections$PLAYER_ID)
    } else if (multi_pos == "custom") {
      # Use caller-supplied position_assignments unchanged
      new_assignments <- if (!is.null(position_assignments)) position_assignments else current_assignments
    }

    # -----------------------------------------------------------------------
    # H. Convergence check
    # -----------------------------------------------------------------------
    # Flatten repl_stats to numeric vector for delta computation
    new_repl_stats_vec <- unlist(
      repl_stats_df[, intersect(c(cats_upper, "IP", "AB"), names(repl_stats_df)), drop = FALSE],
      use.names = FALSE
    )
    new_repl_stats_vec <- as.numeric(new_repl_stats_vec)

    assignments_converged <- !is.null(old_assignments) &&
      length(new_assignments) == length(old_assignments) &&
      all(new_assignments[names(old_assignments)] == old_assignments, na.rm = TRUE)

    stats_converged <- !is.null(old_repl_stats_vec) &&
      length(new_repl_stats_vec) == length(old_repl_stats_vec) &&
      max(abs(new_repl_stats_vec - old_repl_stats_vec), na.rm = TRUE) < tol

    if (!is.null(old_repl_stats_vec) &&
        length(new_repl_stats_vec) == length(old_repl_stats_vec)) {
      delta <- max(abs(new_repl_stats_vec - old_repl_stats_vec), na.rm = TRUE)
    }

    if (assignments_converged && stats_converged) {
      converged <- TRUE
      break
    }

    # State-hash cycle detection: compute a canonical hash of new_assignments
    # (sorted by player ID for order-invariance) and check against the rolling
    # history buffer.  Catches 2-cycles, 3-cycles, and higher-order cycles up
    # to period cycle_window.  Replaces the former 2-lag old_old_assignments
    # comparison.
    if (multi_pos == "highest_par") {
      sorted_idx <- order(names(new_assignments))
      new_hash   <- paste(
        names(new_assignments)[sorted_idx],
        new_assignments[sorted_idx],
        collapse = "|"
      )

      if (new_hash %in% assignment_hash_history) {
        converged <- TRUE
        break
      }

      # Push new_hash onto ring buffer; evict oldest entry if window exceeded
      assignment_hash_history <- c(assignment_hash_history, new_hash)
      if (length(assignment_hash_history) > cycle_window) {
        assignment_hash_history <- tail(assignment_hash_history, cycle_window)
      }
    }

    if (pass >= max_iter) break

    old_assignments     <- new_assignments
    old_repl_stats_vec  <- new_repl_stats_vec
    current_assignments <- new_assignments
    pass <- pass + 1L
  }  # end repeat

  # Convergence warning (unconditional, not gated by verbose)
  if (!converged) {
    cli::cli_warn(
      c(
        "Convergence not reached after {max_iter} iteration{?s}.",
        "i" = "Returning best-so-far result with {.code converged = FALSE}.",
        "i" = "Consider increasing {.arg max_iter} or loosening {.arg tol}."
      ),
      class = "rotostats_warning_convergence_not_reached"
    )
  }

  # -------------------------------------------------------------------------
  # normalize_to_season
  # -------------------------------------------------------------------------
  stat_units <- "raw_projected"

  if (normalize_to_season) {
    stat_units <- "full_season_normalized"
    repl_stats_df <- .normalize_repl_stats(repl_stats_df, cats_upper, active_pitcher_pos)
  }

  # -------------------------------------------------------------------------
  # Two-way player computation
  # -------------------------------------------------------------------------
  two_way_players <- .compute_two_way_players(
    projections     = projections,
    repl_stats_df   = repl_stats_df,
    current_assignments = new_assignments,
    cats_upper      = cats_upper,
    role            = role
  )

  # -------------------------------------------------------------------------
  # Pool diagnostics
  # -------------------------------------------------------------------------
  pool_diagnostics <- .compute_pool_diagnostics(
    projections   = projections,
    repl_stats_df = repl_stats_df,
    cats_upper    = cats_upper,
    active_hitter_pos = active_hitter_pos,
    active_pitcher_pos = active_pitcher_pos,
    current_assignments = new_assignments
  )

  # -------------------------------------------------------------------------
  # Construct output
  # -------------------------------------------------------------------------
  params_out <- list(
    converged                 = converged,
    iterations                = pass,
    delta                     = delta,
    n_teams                   = config$n_teams,
    roster_slots              = config$roster_slots,
    band_width                = K,
    cliff_threshold           = cliff_thr,
    sort_by                   = sort_by,
    stat_units                = stat_units,
    catcher_adjustment_method = catcher_adjustment_method,
    method                    = "boundary_band"
  )

  result <- format_replacement_output(
    replacement_stats      = repl_stats_df,
    positional_adjustments = scarcity_premium,
    cliff_metric           = cliff_metric_df,
    two_way_players        = two_way_players,
    pool_diagnostics       = pool_diagnostics,
    method                 = "boundary_band",
    params                 = params_out
  )

  # Attach output attributes
  attr(result, "stat_units")           <- stat_units
  attr(result, "config")               <- config
  attr(result, "projections")          <- stored_projections
  attr(result, "position_assignments") <- new_assignments
  attr(result, "converged")            <- converged
  attr(result, "iterations")           <- pass
  attr(result, "delta")                <- delta

  assert_replacement_output_contract(result)

  result
}

# ---------------------------------------------------------------------------
# replacement_from_prices()
# ---------------------------------------------------------------------------

#' Replacement-level stat lines derived from historical \$1 auction prices
#'
#' @description
#' Computes replacement-level stat lines from historical \$1 auction data
#' rather than from projections.  Returns the same output schema as
#' `replacement_level()` and is interchangeable as the `replacement_fn`
#' argument to `dollar_values()`.
#'
#' The algorithm: filter prices to `price <= 1`, exclude known keepers
#' (via `is_keeper` flag when present, else statistical trimming), and
#' compute the mean end-of-season stat line for each position.  No projection
#' pool, no sorting, no band, no cliff detection, no SP/RP inference.
#'
#' Most useful as a validation layer on `replacement_level()` output or as
#' the primary method in leagues with 5+ seasons of low-keeper-density
#' auction history.
#'
#' @param prices A data frame of historical auction results.  Required columns:
#'   `year`, `player_name`, `price`, `pos_eligibility` (pipe-delimited,
#'   e.g., `"1B|3B"`).  Optional: `player_id`, `is_keeper` (logical).
#'   When `player_id` is absent, matching falls back to Unicode-normalized
#'   name matching.
#' @param n_teams Positive integer.  Number of teams in the league.
#' @param roster_slots Named integer vector.  Roster slots per position.
#' @param categories Character vector of scored categories.
#' @param trim_method Character scalar.  `"iqr"` (default) — remove above
#'   Q3 + 1.5×IQR; `"mad"` — remove above median + 3×MAD; `"kde"` — detect
#'   trough via kernel density estimation (errors if no trough found).
#'   Ignored when `is_keeper` is present in `prices`.
#' @param calibration_min_n Positive integer.  Minimum number of \$1 players
#'   remaining after trimming.  If fewer remain, emits
#'   `rotostats_warning_calibration_suppressed` and returns `NULL`.
#'   Default `15L`.
#' @param verbose Logical.  If `TRUE`, emit name-match failure warnings.
#'   Default `FALSE`.
#'
#' @return Same named list schema as `replacement_level()` with
#'   `method = "prices"` in `params`, or `NULL` when calibration is
#'   suppressed.  `attr(result, "projections")` is `NULL`.
#'
#' @seealso `replacement_level()`
#'
#' @examples
#' prices_df <- data.frame(
#'   year            = c(2023L, 2023L, 2023L, 2023L),
#'   player_name     = c("Smith J", "Jones M", "Brown K", "White R"),
#'   price           = c(1L, 1L, 1L, 1L),
#'   pos_eligibility = c("1B", "SS", "OF", "C"),
#'   HR              = c(5, 4, 6, 3),
#'   RBI             = c(22, 18, 24, 15),
#'   stringsAsFactors = FALSE
#' )
#'
#' \dontrun{
#' result <- replacement_from_prices(
#'   prices        = prices_df,
#'   n_teams       = 12L,
#'   roster_slots  = c(C = 1L, `1B` = 1L, SS = 1L, OF = 3L),
#'   categories    = c("HR", "RBI")
#' )
#' result$replacement_stats
#' }
#'
#' @importFrom stats setNames
#' @export
replacement_from_prices <- function(
  prices,
  n_teams,
  roster_slots,
  categories,
  trim_method       = "iqr",
  calibration_min_n = 15L,
  verbose           = FALSE
) {
  call_env <- rlang::caller_env()

  # -------------------------------------------------------------------------
  # §4.2  Input validation
  # -------------------------------------------------------------------------
  checkmate::assert_data_frame(prices, min.rows = 1L)
  checkmate::assert_int(n_teams, lower = 1L)
  checkmate::assert_integer(roster_slots, names = "named", lower = 0L)
  checkmate::assert_character(categories, min.len = 1L)

  required_price_cols <- c("year", "player_name", "price", "pos_eligibility")
  missing_price_cols  <- setdiff(required_price_cols, names(prices))
  if (length(missing_price_cols) > 0L) {
    cli::cli_abort(
      c(
        "{.arg prices} is missing required column{?s}: {.val {missing_price_cols}}.",
        "i" = "The {.fn replacement_from_prices} function requires: {.val {required_price_cols}}."
      ),
      class = "rotostats_error_missing_column",
      call  = call_env
    )
  }

  checkmate::assert_choice(trim_method, c("iqr", "mad", "kde"))
  checkmate::assert_int(calibration_min_n, lower = 1L)
  checkmate::assert_flag(verbose)

  # Normalize column names to uppercase
  names(prices) <- toupper(names(prices))
  cats_upper    <- toupper(categories)

  if (verbose && !("PLAYER_ID" %in% names(prices))) {
    raw_names  <- prices$PLAYER_NAME
    norm_names <- normalize_player_name(raw_names)

    # For each normalized name, count distinct raw spellings
    # Use split() to group raw spellings by normalized key (vectorized, no loop)
    raw_by_norm    <- split(raw_names, norm_names)
    n_distinct_raw <- vapply(raw_by_norm, function(raws) length(unique(raws)), integer(1L))
    collision_keys <- names(n_distinct_raw[n_distinct_raw > 1L])

    if (length(collision_keys) > 0L) {
      n_collisions <- length(collision_keys)
      sample_keys  <- head(collision_keys, 3L)

      cli::cli_warn(
        c(
          "{n_collisions} normalized player name{?s} in {.arg prices} correspond to multiple raw spellings.",
          "i" = "Sample normalized key{?s}: {.val {sample_keys}}.",
          "i" = "These entries would be merged under name-based deduplication.",
          "i" = "Supply a {.field player_id} column to use exact identity matching.",
          "i" = "This is a diagnostic warning only \u2014 the stat-line computation is unchanged."
        ),
        class = "rotostats_warning_name_match_failure"
      )
    }
  }

  # -------------------------------------------------------------------------
  # §8 Algorithm
  # -------------------------------------------------------------------------

  # Step 2: Filter to price <= 1
  dollar_pool <- prices[prices$PRICE <= 1, , drop = FALSE]

  # Step 3: Exclude keepers or apply trim_method
  if ("IS_KEEPER" %in% names(dollar_pool)) {
    # Exact exclusion
    dollar_pool <- dollar_pool[!isTRUE(dollar_pool$IS_KEEPER) &
                               !dollar_pool$IS_KEEPER %in% TRUE, , drop = FALSE]
  } else {
    # Statistical trimming on a composite score (sum of scored category values)
    score_cols <- intersect(cats_upper, names(dollar_pool))
    if (length(score_cols) > 0L) {
      composite <- rowMeans(
        as.matrix(dollar_pool[, score_cols, drop = FALSE]),
        na.rm = TRUE
      )
      if (trim_method == "iqr") {
        q3  <- stats::quantile(composite, 0.75, na.rm = TRUE)
        iqr <- stats::IQR(composite, na.rm = TRUE)
        keep <- composite <= q3 + 1.5 * iqr
      } else if (trim_method == "mad") {
        med  <- stats::median(composite, na.rm = TRUE)
        mad_ <- stats::mad(composite, constant = 1.4826, na.rm = TRUE)
        keep <- composite <= med + 3 * mad_
      } else {  # "kde"
        trough <- kde_trough(composite)
        keep   <- composite <= trough
      }
      dollar_pool <- dollar_pool[keep, , drop = FALSE]
    }
  }

  # Step 4: Calibration suppression guard
  if (nrow(dollar_pool) < calibration_min_n) {
    cli::cli_warn(
      c(
        "Calibration pool has only {nrow(dollar_pool)} player{?s} after trimming (minimum: {calibration_min_n}).",
        "i" = "Suppressing calibration.  Returning {.code NULL}.",
        "i" = "Consider lowering {.arg calibration_min_n} or supplying more historical seasons."
      ),
      class = "rotostats_warning_calibration_suppressed"
    )
    return(NULL)
  }

  # Step 5: Per-position mean stat line
  positions <- names(roster_slots[roster_slots > 0])

  repl_rows_list  <- vector("list", length(positions))
  cliff_rows_list <- vector("list", length(positions))
  names(repl_rows_list)  <- positions
  names(cliff_rows_list) <- positions

  for (pos in positions) {
    # Find players eligible at this position
    pos_pattern <- paste0("(^|\\|)", pos, "(\\||$)")
    pos_mask    <- grepl(pos_pattern, dollar_pool$POS_ELIGIBILITY)
    pos_df      <- dollar_pool[pos_mask, , drop = FALSE]

    if (nrow(pos_df) == 0L) {
      empty_stats <- stats::setNames(rep(NA_real_, length(cats_upper)), cats_upper)
      repl_rows_list[[pos]] <- c(
        list(position = pos),
        as.list(empty_stats),
        list(n_band_players = 0L, cliff_detected = FALSE)
      )
    } else {
      # Mean stat line (no IP-weighted ERA/WHIP here — prices method uses simple means)
      stat_means <- vapply(cats_upper, function(cat) {
        if (cat %in% names(pos_df)) mean(pos_df[[cat]], na.rm = TRUE) else NA_real_
      }, numeric(1L))

      repl_rows_list[[pos]] <- c(
        list(position = pos),
        as.list(stat_means),
        list(n_band_players = as.integer(nrow(pos_df)), cliff_detected = FALSE)
      )
    }

    cliff_rows_list[[pos]] <- list(
      position        = pos,
      cliff_detected  = FALSE,
      cliff_location  = NA_integer_,
      cliff_magnitude = NA_real_,
      swingman        = FALSE,
      n_band_players  = as.integer(nrow(pos_df))
    )
  }

  # Assemble data frames
  repl_stats_df <- do.call(rbind, lapply(names(repl_rows_list), function(pos) {
    row <- repl_rows_list[[pos]]
    df  <- as.data.frame(row, stringsAsFactors = FALSE)
    for (cat in cats_upper) {
      if (cat %in% names(df)) df[[cat]] <- as.numeric(df[[cat]])
    }
    df$n_band_players <- as.integer(row$n_band_players)
    df$cliff_detected <- FALSE
    df
  }))
  rownames(repl_stats_df) <- NULL

  cliff_metric_df <- do.call(rbind, lapply(cliff_rows_list, function(r) {
    as.data.frame(r, stringsAsFactors = FALSE)
  }))
  rownames(cliff_metric_df) <- NULL

  # Step 6: Compute positional adjustments (minimal config-like object)
  # Build a minimal config substitute for compute_positional_adjustments
  fake_config <- list(
    n_teams       = as.integer(n_teams),
    roster_slots  = roster_slots,
    pitcher_slots = integer(0L),
    budget        = 260L,
    budget_split  = 0.67,
    categories    = categories
  )
  class(fake_config) <- c("league_config", "list")

  scarcity_premium <- compute_positional_adjustments(
    replacement_stats            = repl_stats_df,
    config                       = fake_config,
    positional_adjustment_method = "fvarz",
    catcher_adjustment_method    = "split_pool",
    pos_weight                   = NULL,
    sgp_denominators             = NULL,
    pass_number                  = 1L,
    verbose                      = verbose
  )

  # Params
  params_out <- list(
    converged                 = TRUE,
    iterations                = 1L,
    delta                     = 0.0,
    n_teams                   = as.integer(n_teams),
    roster_slots              = roster_slots,
    band_width                = NA_integer_,
    cliff_threshold           = NA_real_,
    sort_by                   = NA_character_,
    stat_units                = "raw_projected",
    catcher_adjustment_method = "split_pool",
    method                    = "prices"
  )

  # Step 7: Construct output
  result <- format_replacement_output(
    replacement_stats      = repl_stats_df,
    positional_adjustments = scarcity_premium,
    cliff_metric           = cliff_metric_df,
    two_way_players        = character(0L),
    pool_diagnostics       = list(position_sd_ratio = NULL),
    method                 = "prices",
    params                 = params_out
  )

  # Step 9: Attach attributes
  attr(result, "stat_units")           <- "raw_projected"
  attr(result, "config")               <- fake_config
  attr(result, "projections")          <- NULL
  attr(result, "position_assignments") <- NULL
  attr(result, "converged")            <- TRUE
  attr(result, "iterations")           <- 1L
  attr(result, "delta")                <- 0.0

  # Step 8: Validate contract
  assert_replacement_output_contract(result)

  result
}

# ---------------------------------------------------------------------------
# Private helpers used only by replacement_level()
# ---------------------------------------------------------------------------

#' @noRd
.validate_league_history_inputs <- function(
  projections, league_history, config, params, trim_method, verbose, call_env
) {
  # $1 calibration check and IP/AB divergence
  if (!is.null(league_history$prices)) {
    prices_df <- league_history$prices
    names(prices_df) <- toupper(names(prices_df))

    # Missing required columns
    req_cols <- c("YEAR", "PLAYER_NAME", "PRICE")
    miss_cols <- setdiff(req_cols, names(prices_df))
    if (length(miss_cols) > 0L) {
      cli::cli_abort(
        "league_history$prices is missing column{?s}: {.val {miss_cols}}.",
        class = "rotostats_error_missing_column",
        call  = call_env
      )
    }

    if (verbose) {
      norm_prices_names <- normalize_player_name(prices_df$PLAYER_NAME)
      norm_proj_names   <- normalize_player_name(projections$PLAYER_NAME)
      unmatched_names   <- setdiff(norm_prices_names, norm_proj_names)

      if (length(unmatched_names) > 0L) {
        n_unmatched  <- length(unmatched_names)
        sample_names <- head(unmatched_names, 3L)

        cli::cli_warn(
          c(
            "{n_unmatched} player name{?s} in {.arg league_history$prices} could not be matched to {.arg projections} after name normalization.",
            "i" = "Sample: {.val {sample_names}}.",
            "i" = "Check for spelling differences between your prices history and projections source.",
            "i" = "This is a diagnostic warning only \u2014 calibration output is unchanged."
          ),
          class = "rotostats_warning_name_match_failure"
        )
      }
    }
  }

  # IP/AB divergence check
  if (!is.null(league_history$team_season)) {
    ts <- league_history$team_season
    names(ts) <- toupper(names(ts))

    if ("IP" %in% names(ts) && "IP" %in% names(projections)) {
      proj_team_ip <- sum(projections$IP, na.rm = TRUE) / config$n_teams
      hist_team_ip <- mean(ts$IP, na.rm = TRUE)
      if (!is.na(hist_team_ip) && hist_team_ip > 0) {
        if (abs(proj_team_ip - hist_team_ip) / hist_team_ip > params$ip_ab_divergence_tol) {
          if (verbose) {
            cli::cli_warn(
              c(
                "Projected team IP ({round(proj_team_ip, 1)}) diverges from historical mean ({round(hist_team_ip, 1)}) by more than {params$ip_ab_divergence_tol * 100}%.",
                "i" = "This may indicate a stale projection vintage or unusual league history."
              ),
              class = "rotostats_warning_team_total_divergence"
            )
          }
        }
      }
    }

    if ("AB" %in% names(ts) && "AB" %in% names(projections)) {
      proj_team_ab <- sum(projections$AB, na.rm = TRUE) / config$n_teams
      hist_team_ab <- mean(ts$AB, na.rm = TRUE)
      if (!is.na(hist_team_ab) && hist_team_ab > 0) {
        if (abs(proj_team_ab - hist_team_ab) / hist_team_ab > params$ip_ab_divergence_tol) {
          if (verbose) {
            cli::cli_warn(
              c(
                "Projected team AB ({round(proj_team_ab, 1)}) diverges from historical mean ({round(hist_team_ab, 1)}) by more than {params$ip_ab_divergence_tol * 100}%.",
                "i" = "This may indicate a stale projection vintage or unusual league history."
              ),
              class = "rotostats_warning_team_total_divergence"
            )
          }
        }
      }
    }
  }

  invisible(NULL)
}

#' @noRd
.normalize_repl_stats <- function(repl_stats_df, cats_upper, active_pitcher_pos) {
  # Normalize counting stats to full-season baselines
  # Hitters: 600 PA (550 AB when PA unavailable); SP: 200 IP; RP: 70 IP
  for (i in seq_len(nrow(repl_stats_df))) {
    pos <- repl_stats_df$position[i]
    is_sp <- pos %in% intersect(active_pitcher_pos, "SP")
    is_rp <- pos %in% intersect(active_pitcher_pos, "RP")

    if (is_sp && "IP" %in% names(repl_stats_df) && !is.na(repl_stats_df$IP[i]) && repl_stats_df$IP[i] > 0) {
      scale <- 200 / repl_stats_df$IP[i]
      for (cat in intersect(cats_upper, names(repl_stats_df))) {
        # Don't scale rate stats
        if (!cat %in% c("ERA", "WHIP", "AVG", "OBP", "SLG", "OPS")) {
          repl_stats_df[[cat]][i] <- repl_stats_df[[cat]][i] * scale
        }
      }
    } else if (is_rp && "IP" %in% names(repl_stats_df) && !is.na(repl_stats_df$IP[i]) && repl_stats_df$IP[i] > 0) {
      scale <- 70 / repl_stats_df$IP[i]
      for (cat in intersect(cats_upper, names(repl_stats_df))) {
        if (!cat %in% c("ERA", "WHIP", "AVG", "OBP", "SLG", "OPS")) {
          repl_stats_df[[cat]][i] <- repl_stats_df[[cat]][i] * scale
        }
      }
    } else if (!is_sp && !is_rp) {
      # Hitter: scale to 550 AB if AB available, else use PA-based scaling
      if ("AB" %in% names(repl_stats_df) && !is.na(repl_stats_df$AB[i]) && repl_stats_df$AB[i] > 0) {
        scale <- 550 / repl_stats_df$AB[i]
        for (cat in intersect(cats_upper, names(repl_stats_df))) {
          if (!cat %in% c("ERA", "WHIP", "AVG", "OBP", "SLG", "OPS")) {
            repl_stats_df[[cat]][i] <- repl_stats_df[[cat]][i] * scale
          }
        }
      }
    }
  }
  repl_stats_df
}

#' @noRd
.compute_two_way_players <- function(
  projections, repl_stats_df, current_assignments, cats_upper, role
) {
  # Two-way players: those with PAR > 0 in both hitter and pitcher roles
  has_hitter_elig  <- !is.na(current_assignments)
  has_pitcher_elig <- !is.na(role) & role %in% c("SP", "RP")

  # A two-way player must have both hitter and pitcher eligibility
  two_way_ids <- character(0L)

  for (i in seq_len(nrow(projections))) {
    pid <- projections$PLAYER_ID[i]
    pos_elig <- projections$POS_ELIGIBILITY[i]
    pos_parts <- strsplit(pos_elig, "\\|")[[1]]

    has_hit <- any(!pos_parts %in% c("SP", "RP", "P"))
    has_pit <- any(pos_parts %in% c("SP", "RP"))

    if (!has_hit || !has_pit) next

    # Compute PAR as hitter
    assigned_pos <- current_assignments[pid]
    if (is.null(assigned_pos) || is.na(assigned_pos)) next

    repl_row_hit <- repl_stats_df[repl_stats_df$position == assigned_pos, , drop = FALSE]
    if (nrow(repl_row_hit) == 0L) next

    par_hit <- compute_par_at_pos(projections[i, , drop = FALSE], repl_row_hit, cats_upper)

    # Compute PAR as pitcher
    pitcher_role <- role[i]
    if (is.na(pitcher_role)) next

    repl_row_pit <- repl_stats_df[repl_stats_df$position == pitcher_role, , drop = FALSE]
    if (nrow(repl_row_pit) == 0L) next

    par_pit <- compute_par_at_pos(projections[i, , drop = FALSE], repl_row_pit, cats_upper)

    if (par_hit > 0 && par_pit > 0) {
      two_way_ids <- c(two_way_ids, pid)
    }
  }

  two_way_ids
}

#' @noRd
.compute_pool_diagnostics <- function(
  projections, repl_stats_df, cats_upper, active_hitter_pos,
  active_pitcher_pos, current_assignments
) {
  # position_sd_ratio: per-category ratio of within-position SD to global SD
  positions <- c(active_hitter_pos, active_pitcher_pos)

  sd_ratios <- vector("list", length(positions))
  names(sd_ratios) <- positions

  for (pos in positions) {
    is_pitcher_pos <- pos %in% c("SP", "RP")
    if (is_pitcher_pos) {
      pos_mask <- grepl("(SP|RP)", projections$POS_ELIGIBILITY)
    } else {
      player_ids_at_pos <- names(current_assignments)[current_assignments == pos]
      pos_mask <- projections$PLAYER_ID %in% player_ids_at_pos
    }

    pos_df <- projections[pos_mask, , drop = FALSE]

    ratios <- vapply(cats_upper, function(cat) {
      if (!cat %in% names(projections)) return(NA_real_)
      global_vals <- projections[[cat]]
      pos_vals    <- pos_df[[cat]]
      global_sd   <- stats::sd(global_vals, na.rm = TRUE)
      pos_sd      <- stats::sd(pos_vals,    na.rm = TRUE)
      if (is.na(global_sd) || global_sd == 0) return(NA_real_)
      if (is.na(pos_sd)) return(NA_real_)
      pos_sd / global_sd
    }, numeric(1L))

    sd_ratios[[pos]] <- ratios
  }

  list(position_sd_ratio = sd_ratios)
}
