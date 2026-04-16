# sgp_denominators() — main exported function
# convert_rate_stats() — stub

# ---------------------------------------------------------------------------
# convert_rate_stats() stub
# ---------------------------------------------------------------------------

#' Convert rate statistics to counting-stat equivalents (stub)
#'
#' @description
#' This function is not yet implemented. It will convert rate statistics
#' (ERA, WHIP, AVG, etc.) to counting-stat equivalents using a fixed baseline
#' approach. For now, use `rate_conversion = "blended_pool"` (the default) in
#' [sgp_denominators()].
#'
#' @param league_history A `league_history` S3 object or duck-typed list.
#' @param baseline_era Numeric. Fixed baseline ERA (not yet used).
#' @param baseline_whip Numeric. Fixed baseline WHIP (not yet used).
#' @param baseline_avg Numeric. Fixed baseline AVG (not yet used).
#' @param projections Data frame of player projections (not yet used).
#' @param league_config League configuration object (not yet used).
#' @return Does not return; always aborts.
#' @export
convert_rate_stats <- function(
  league_history,
  baseline_era  = NULL,
  baseline_whip = NULL,
  baseline_avg  = NULL,
  projections   = NULL,
  league_config = NULL
) {
  cli::cli_abort(
    paste0(
      "{.fn convert_rate_stats} is not yet implemented. ",
      "Use {.code rate_conversion = \"blended_pool\"} (default) for now. ",
      "See the {.arg rate_conversion} parameter in {.fn sgp_denominators} for alternatives."
    ),
    class = "rotostats_error_not_implemented"
  )
}

# ---------------------------------------------------------------------------
# sgp_denominators()
# ---------------------------------------------------------------------------

#' Compute SGP denominators for rotisserie scoring categories
#'
#' @description
#' Estimates the SGP (Standings Gain Points) denominator for each scoring
#' category by fitting OLS (or an alternative method) to historical team-season
#' standings data. The denominator for category *c* is the number of additional
#' category units required to move up one place in the standings, on average.
#'
#' `league_history` may be a formal `league_history` S3 object (see
#' `league_history()`) or any list with a `$team_season` data.frame containing
#' `year`, `team_id`, and category columns.
#'
#' @param league_history A `league_history` S3 object or duck-typed list with a
#'   `$team_season` data.frame containing `year`, `team_id`, and category columns.
#' @param scoring_categories Character vector of category column names, or `NULL`
#'   to infer from `league_history$team_season`.
#' @param n_teams Positive integer or `NULL`. If `NULL`, team counts are inferred
#'   per year. If supplied, all years must have exactly `n_teams` rows.
#' @param years `"all"`, an integer vector of specific years, or a year-window
#'   helper: [after()], [before()], [between()], [last()]. Global calibration window.
#' @param weights Weight specification. One of:
#'   - A weight constructor result: [flat()], [linear_decay()], [exp_decay()].
#'   - `"flat"` (character shorthand for [flat()]).
#'   - `"linear"` (character shorthand for [linear_decay()]).
#' @param method Character. Denominator estimation method. One of `"ols"`,
#'   `"gap"`, `"trimmed_gap"`, `"sd"`. Default: `"ols"`.
#' @param category_spec A [cal_spec()] object for per-category overrides of
#'   `years` and `weights`, or `NULL`.
#' @param outlier_filter Logical. If `TRUE`, exclude team-season rows where any
#'   category value is beyond 1.5 × IQR from the league median for that
#'   category-year combination. Default: `FALSE`.
#' @param exclude_years Integer vector of years to exclude from all calibration
#'   windows. Default: `2020L` (COVID-shortened season).
#' @param rate_conversion Character. One of `"blended_pool"` (default) or
#'   `"fixed_baseline"`. `"fixed_baseline"` requires a pre-converted
#'   `league_history` of class `"sgp_history_transformed"` (or calls the not-yet-
#'   implemented [convert_rate_stats()] stub and aborts).
#' @param roto_pts_col Character. Column name for total roto points; used only
#'   for optional standings validation. Default: `"roto_pts"`.
#' @param n_bootstrap Non-negative integer. Number of year-level bootstrap
#'   replicates for CI estimation. `0L` disables bootstrapping. Default: `0L`.
#' @param denom_floor Positive numeric. Near-zero slope guard: if
#'   `abs(slope) < denom_floor`, denominator is set to `Inf`. Default: `1e-9`.
#' @param ci_level Numeric in (0, 1). Bootstrap CI nominal level (used only
#'   when `n_bootstrap > 0`). Default: `0.95`.
#'
#' @return An S3 object of class `c("sgp_denominators", "list")` with slots:
#'   - `$denominators` — named numeric vector, one entry per category.
#'   - `$year_diagnostics` — data.frame with one row per (year × category).
#'   - `$bootstrap_ci` — data.frame or `NULL` (when `n_bootstrap = 0`).
#'   - `$call` — the matched call.
#'   - `$meta` — named list: `rate_conversion`, `method`, `years_used`,
#'     `exclude_years`, `package_version`.
#'   - `attr(result, "rate_conversion")` — character, for backward compatibility.
#'
#' @details
#' ## Backward compatibility
#' Code written against the old named-numeric-vector API continues to work:
#' ```r
#' denoms <- sgp_denominators(history, ...)
#' attr(denoms, "rate_conversion")  # character
#' as.numeric(denoms)               # named numeric vector
#' denoms["HR"]                     # numeric scalar
#' names(denoms)                    # character vector
#' length(denoms)                   # integer
#' ```
#'
#' ## Dependency note
#' The `league_history()` constructor is not yet implemented as of this run.
#' `sgp_denominators()` accepts a plain list with a `$team_season` component as
#' a duck-type fallback.
#'
#' `convert_rate_stats()` is a stub only. The `rate_conversion = "fixed_baseline"`
#' path will abort with `rotostats_error_not_implemented`.
#'
#' @export
sgp_denominators <- function(
  league_history,
  scoring_categories = NULL,
  n_teams            = NULL,
  years              = "all",
  weights            = exp_decay(0.9),
  method             = "ols",
  category_spec      = NULL,
  outlier_filter     = FALSE,
  exclude_years      = 2020L,
  rate_conversion    = "blended_pool",
  roto_pts_col       = "roto_pts",
  n_bootstrap        = 0L,
  denom_floor        = 1e-9,
  ci_level           = 0.95
) {
  the_call <- match.call()

  # ----- 5.1 Input Acquisition and Validation --------------------------------

  # Step 1. Extract team_season.
  ts <- league_history[["team_season"]]
  if (is.null(ts) || !is.data.frame(ts)) {
    cli::cli_abort(
      "{.code league_history$team_season} must be a non-NULL data.frame.",
      class = "rotostats_error_missing_team_season"
    )
  }

  # Step 2. Normalize column names to uppercase; emit cli_inform() if any changed.
  orig_names <- names(ts)
  upper_names <- toupper(orig_names)
  changed <- orig_names[orig_names != upper_names]
  if (length(changed) > 0L) {
    pairs <- paste(changed, toupper(changed), sep = " -> ")
    cli::cli_inform(
      "Normalizing column names to uppercase: {paste(pairs, collapse = ', ')}."
    )
  }
  names(ts) <- upper_names

  # Coerce YEAR to integer so downstream vapply(..., integer(1L)) calls never
  # see a type mismatch when callers pass bare numeric literals (e.g. 2024).
  # Guard against missing YEAR — column-presence validation follows below.
  if ("YEAR" %in% names(ts)) {
    ts$YEAR <- as.integer(ts$YEAR)
  }

  # Normalize roto_pts_col to uppercase too.
  roto_pts_col_upper <- toupper(roto_pts_col)

  # Step 3. Validate required columns.
  missing_req <- setdiff(c("YEAR", "TEAM_ID"), names(ts))
  if (length(missing_req) > 0L) {
    cli::cli_abort(
      "Required column(s) missing from {.code league_history$team_season}: {.val {missing_req}}.",
      class = "rotostats_error_missing_required_column"
    )
  }

  # Step 4. Validate rate_conversion.
  valid_rate_conversions <- c("blended_pool", "fixed_baseline")
  if (!rate_conversion %in% valid_rate_conversions) {
    cli::cli_abort(
      "{.arg rate_conversion} must be one of {.val {valid_rate_conversions}}, not {.val {rate_conversion}}.",
      class = "rotostats_error_invalid_rate_conversion"
    )
  }

  # Step 5. Handle rate_conversion = "fixed_baseline".
  if (rate_conversion == "fixed_baseline") {
    if (!inherits(league_history, "sgp_history_transformed")) {
      convert_rate_stats(league_history)  # always aborts via stub
    }
  }

  # Step 6. Validate method.
  valid_methods <- c("ols", "gap", "trimmed_gap", "sd")
  if (!method %in% valid_methods) {
    cli::cli_abort(
      "{.arg method} must be one of {.val {valid_methods}}, not {.val {method}}.",
      class = "rotostats_error_invalid_method"
    )
  }

  # Step 7. Validate category_spec.
  if (!is.null(category_spec) && !inherits(category_spec, "cal_spec")) {
    cli::cli_abort(
      "{.arg category_spec} must be a {.cls cal_spec} object built with {.fn cal_spec}, or {.code NULL}.",
      class = "rotostats_error_invalid_category_spec"
    )
  }

  # Step 8. Validate n_bootstrap.
  if (
    !is.numeric(n_bootstrap) && !is.integer(n_bootstrap) ||
    length(n_bootstrap) != 1L ||
    is.na(n_bootstrap) ||
    n_bootstrap < 0 ||
    n_bootstrap != floor(n_bootstrap)
  ) {
    cli::cli_abort(
      "{.arg n_bootstrap} must be a non-negative integer scalar.",
      class = "rotostats_error_invalid_parameter"
    )
  }
  n_bootstrap <- as.integer(n_bootstrap)

  # ----- 5.3 Identify Unrecognized Columns -----------------------------------

  pts_pattern <- "_PTS$"
  known_cols <- c(
    METADATA_COLS,
    roto_pts_col_upper,
    grep(pts_pattern, names(ts), value = TRUE)
  )
  # We'll update known_cols again after scoring_categories is determined; for
  # now just warn about any columns that are non-numeric.
  # (Full warning emitted after category inference below.)

  # ----- 5.4 Category Inference ----------------------------------------------

  if (is.null(scoring_categories)) {
    # Candidate columns: numeric, not in METADATA_COLS, not roto_pts_col, not _PTS
    pts_cols <- grep(pts_pattern, names(ts), value = TRUE)
    exclude_from_inference <- c(METADATA_COLS, roto_pts_col_upper, pts_cols)
    candidate_cols <- names(ts)[
      vapply(ts, is.numeric, logical(1L)) &
      !names(ts) %in% exclude_from_inference
    ]
    cli::cli_inform(c(
      "Inferring scoring categories from {.code league_history$team_season} columns:",
      " " = paste(candidate_cols, collapse = " "),
      "i" = "Provide {.arg scoring_categories} explicitly to suppress this message."
    ))
    scoring_categories <- candidate_cols
  } else {
    # Normalize to uppercase and validate.
    scoring_categories <- toupper(scoring_categories)
    missing_cats <- setdiff(scoring_categories, names(ts))
    if (length(missing_cats) > 0L) {
      cli::cli_abort(
        "Scoring category column(s) missing from {.code league_history$team_season}: {.val {missing_cats}}.",
        class = "rotostats_error_missing_category_column"
      )
    }
  }

  # Now emit the unrecognized-column warning with full knowledge of categories.
  pts_cols_all <- grep(pts_pattern, names(ts), value = TRUE)
  known_cols_full <- c(METADATA_COLS, roto_pts_col_upper, pts_cols_all, scoring_categories)
  unrecognized <- setdiff(names(ts), known_cols_full)
  if (length(unrecognized) > 0L) {
    cli::cli_warn(
      "Unrecognized column(s) in {.code league_history$team_season}: {.val {unrecognized}}.",
      class = "rotostats_warning_unrecognized_column"
    )
  }

  # Inform if roto_pts_col absent (standings validation will be skipped).
  if (!roto_pts_col_upper %in% names(ts)) {
    cli::cli_inform(
      "{.arg roto_pts_col} ({.val {roto_pts_col_upper}}) not found in {.code team_season}. Standings validation skipped."
    )
  }

  # ----- 5.5 n_teams Validation ----------------------------------------------

  all_ts_years <- sort(unique(ts$YEAR))
  year_nrow <- vapply(all_ts_years, function(y) nrow(ts[ts$YEAR == y, ]), integer(1L))
  names(year_nrow) <- as.character(all_ts_years)

  if (is.null(n_teams)) {
    if (length(unique(year_nrow)) > 1L) {
      affected <- paste(
        names(year_nrow)[year_nrow != year_nrow[[1L]]],
        year_nrow[year_nrow != year_nrow[[1L]]],
        sep = "="
      )
      cli::cli_warn(
        "Uneven team counts across years: {paste(affected, collapse = ', ')}.",
        class = "rotostats_warning_uneven_team_counts"
      )
    }
    n_teams_per_year <- year_nrow
  } else {
    if (
      !is.numeric(n_teams) && !is.integer(n_teams) ||
      length(n_teams) != 1L ||
      n_teams != floor(n_teams) ||
      n_teams < 1L
    ) {
      cli::cli_abort(
        "{.arg n_teams} must be a positive integer scalar or {.code NULL}.",
        class = "rotostats_error_invalid_parameter"
      )
    }
    n_teams <- as.integer(n_teams)
    mismatch_years <- all_ts_years[year_nrow != n_teams]
    if (length(mismatch_years) > 0L) {
      y <- mismatch_years[[1L]]
      cli::cli_abort(
        "Year {.val {y}} has {year_nrow[[as.character(y)]]} rows but {.arg n_teams} = {n_teams}.",
        class = "rotostats_error_n_teams_mismatch"
      )
    }
    n_teams_per_year <- stats::setNames(
      rep(n_teams, length(all_ts_years)),
      as.character(all_ts_years)
    )
  }

  # ----- 5.6 Build Effective Year Sets ---------------------------------------

  global_years <- apply_year_window(all_ts_years, years)
  global_years <- sort(setdiff(global_years, exclude_years))

  # Per-category year sets.
  cat_years <- stats::setNames(
    lapply(scoring_categories, function(cat) {
      if (!is.null(category_spec) && !is.null(category_spec[[cat]])) {
        cat_win <- category_spec[[cat]]$years
        if (!is.null(cat_win)) {
          ys <- apply_year_window(all_ts_years, cat_win)
          return(sort(setdiff(ys, exclude_years)))
        }
      }
      global_years
    }),
    scoring_categories
  )

  # Warn for thin windows.
  for (cat in scoring_categories) {
    if (length(cat_years[[cat]]) < 3L) {
      cli::cli_warn(
        "Category {.val {cat}} has only {length(cat_years[[cat]])} season(s) in its calibration window (< 3).",
        class = "rotostats_warning_thin_calibration_window"
      )
    }
  }

  # ----- 5.7 Build Effective Weight Functions --------------------------------

  # Resolve global weights.
  global_weight_fn <- resolve_weight(weights)

  # Per-category weight functions.
  cat_weight_fns <- stats::setNames(
    lapply(scoring_categories, function(cat) {
      if (!is.null(category_spec) && !is.null(category_spec[[cat]])) {
        cat_wt <- category_spec[[cat]]$weights
        if (!is.null(cat_wt)) {
          return(resolve_weight(cat_wt))
        }
      }
      global_weight_fn
    }),
    scoring_categories
  )

  # ----- 5.8 SB Structural Break Warning -------------------------------------

  for (cat in scoring_categories) {
    eff_years <- cat_years[[cat]]
    eff_wfn   <- cat_weight_fns[[cat]]
    spans_break <- any(eff_years <= 2022) && any(eff_years >= 2023)
    if (spans_break && inherits(eff_wfn, "flat_weight")) {
      cli::cli_warn(
        paste0(
          "Category {.val {cat}} calibration window spans pre- and post-2023 seasons ",
          "with flat weighting. The 2023 rule changes (shift ban, larger bases) increased ",
          "SB substantially. Consider ",
          "{.code category_spec = cal_spec({cat} = cal(years = after(2022)))}."
        ),
        class = "rotostats_warning_structural_break_flat_weights"
      )
    }
  }

  # ----- 5.9 NA Handling -----------------------------------------------------

  # For each category, identify and warn about NA/NaN rows; exclude them.
  # Build per-category mask of valid rows (non-NA for that category column).
  cat_valid_rows <- stats::setNames(
    lapply(scoring_categories, function(cat) {
      vals <- ts[[cat]]
      bad  <- which(is.na(vals) | is.nan(vals))
      if (length(bad) > 0L) {
        pairs <- paste(ts$YEAR[bad], ts$TEAM_ID[bad], sep = ":")
        cli::cli_warn(
          "NA/NaN values in category {.val {cat}} for team-year pair(s): {paste(pairs, collapse = ', ')}. Those rows excluded.",
          class = "rotostats_warning_na_category_value"
        )
      }
      setdiff(seq_len(nrow(ts)), bad)
    }),
    scoring_categories
  )

  # ----- 5.10 Outlier Filter (applied per category per year) -----------------
  # Stored as per-category per-year exclusion sets for use in Step 5.11.

  # Build the per-category valid row sets (intersecting outlier exclusions).
  cat_valid_rows <- if (outlier_filter) {
    stats::setNames(
      lapply(scoring_categories, function(cat) {
        valid_base <- cat_valid_rows[[cat]]
        ts_valid   <- ts[valid_base, , drop = FALSE]
        exclude_local <- integer(0L)
        for (y in unique(ts_valid$YEAR)) {
          idx_in_valid <- which(ts_valid$YEAR == y)
          vals <- ts_valid[[cat]][idx_in_valid]
          q1   <- stats::quantile(vals, 0.25, names = FALSE)
          q3   <- stats::quantile(vals, 0.75, names = FALSE)
          iqr  <- q3 - q1
          lo   <- q1 - 1.5 * iqr
          hi   <- q3 + 1.5 * iqr
          out  <- idx_in_valid[vals < lo | vals > hi]
          exclude_local <- c(exclude_local, valid_base[out])
        }
        setdiff(valid_base, exclude_local)
      }),
      scoring_categories
    )
  } else {
    cat_valid_rows
  }

  # ----- 5.11 Denominator Computation ----------------------------------------

  # We compute per-category denominators and collect year_diagnostics rows.
  all_diag_rows <- list()

  denominators <- vapply(scoring_categories, function(cat) {

    eff_years  <- cat_years[[cat]]
    weight_fn  <- cat_weight_fns[[cat]]
    valid_rows <- cat_valid_rows[[cat]]
    ts_cat     <- ts[valid_rows, , drop = FALSE]

    # Per-year estimates.
    n_eff_years <- length(eff_years)
    max_year    <- if (n_eff_years > 0L) max(eff_years) else NA_real_

    per_year <- lapply(eff_years, function(y) {
      ts_y  <- ts_cat[ts_cat$YEAR == y, , drop = FALSE]
      n_y   <- nrow(ts_y)
      n_y_i <- as.integer(n_y)

      # Determine standings position source.
      pts_col <- paste0(cat, "_PTS")
      if (pts_col %in% names(ts_y)) {
        standings_pos        <- ts_y[[pts_col]]
        sp_source            <- "category_pts"
      } else {
        # Direction-aware rank: rank 1 = worst, rank n_y = best.
        # For normal categories, raw rank() already satisfies this (lowest value = rank 1).
        # For inverse categories (ERA, WHIP), lower values are better (best team has lowest
        # ERA), so we flip: standings_pos = n_y + 1 - rank(). This makes the best team
        # (lowest ERA) receive rank n_y and produces a negative OLS slope (rank decreases
        # as total increases), consistent with rank-1=worst / rank-n=best convention.
        raw_rank <- rank(ts_y[[cat]], ties.method = "average")
        standings_pos <- if (cat %in% INVERSE_CATEGORIES) {
          n_y + 1L - raw_rank
        } else {
          raw_rank
        }
        sp_source <- "rank"
      }
      totals <- ts_y[[cat]]

      # Compute the per-year estimate for the selected method.
      years_ago <- max_year - y
      raw_w     <- compute_weight(weight_fn, years_ago, n_eff_years)

      if (method == "ols") {
        # Zero-variance guard.
        if (stats::var(totals) < denom_floor) {
          cli::cli_warn(
            "Zero variance in category {.val {cat}} for year {.val {y}}. OLS slope set to NA.",
            class = "rotostats_warning_zero_variance_category"
          )
          return(list(
            year = y, category = cat, n_teams = n_y_i,
            slope = NA_real_, r_squared = NA_real_,
            raw_weight = 0,
            gap = NA_real_,
            standings_pos_source = sp_source
          ))
        }
        fit    <- stats::lm(standings_pos ~ totals)
        beta_y <- stats::coef(fit)[["totals"]]
        r2_y   <- summary(fit)$r.squared
        if (!is.na(r2_y) && r2_y < 0.80) {
          cli::cli_warn(
            "OLS R\u00b2 = {round(r2_y, 3)} (< 0.80) for category {.val {cat}}, year {.val {y}}.",
            class = "rotostats_warning_low_r_squared"
          )
        }
        list(
          year = y, category = cat, n_teams = n_y_i,
          slope = beta_y, r_squared = r2_y,
          raw_weight = raw_w,
          gap = NA_real_,
          standings_pos_source = sp_source
        )
      } else if (method == "gap") {
        tot_sorted <- sort(totals)
        gaps       <- diff(tot_sorted)
        gap_y      <- mean(gaps)
        list(
          year = y, category = cat, n_teams = n_y_i,
          slope = NA_real_, r_squared = NA_real_,
          raw_weight = raw_w, gap = gap_y,
          standings_pos_source = sp_source
        )
      } else if (method == "trimmed_gap") {
        tot_sorted <- sort(totals)
        gaps       <- diff(tot_sorted)
        k          <- floor(0.1 * length(gaps))
        gaps_tr    <- if (k > 0L) gaps[(k + 1L):(length(gaps) - k)] else gaps
        gap_y      <- mean(gaps_tr)
        list(
          year = y, category = cat, n_teams = n_y_i,
          slope = NA_real_, r_squared = NA_real_,
          raw_weight = raw_w, gap = gap_y,
          standings_pos_source = sp_source
        )
      } else {  # method == "sd"
        sd_y     <- stats::sd(totals)
        e_rn     <- expected_range_normal(n_y)
        gap_y    <- sd_y * (n_y - 1) / e_rn
        list(
          year = y, category = cat, n_teams = n_y_i,
          slope = NA_real_, r_squared = NA_real_,
          raw_weight = raw_w, gap = gap_y,
          standings_pos_source = sp_source
        )
      }
    })

    # --- Compute weighted estimate across years ---

    if (method == "ols") {
      valid_mask <- !vapply(per_year, function(r) is.na(r$slope), logical(1L))
      valid_ys   <- per_year[valid_mask]
      if (length(valid_ys) == 0L) {
        cli::cli_warn(
          "No valid years remain for category {.val {cat}}. Denominator set to NA.",
          class = "rotostats_warning_no_valid_years"
        )
        # Normalize weights to NA for diagnostics.
        diag_rows <- lapply(per_year, function(r) {
          r$raw_weight <- NA_real_
          r
        })
        all_diag_rows[[cat]] <<- diag_rows
        return(NA_real_)
      }
      raw_weights_valid <- vapply(valid_ys, `[[`, numeric(1L), "raw_weight")
      w_sum             <- sum(raw_weights_valid)
      norm_weights      <- raw_weights_valid / w_sum
      slopes_valid      <- vapply(valid_ys, `[[`, numeric(1L), "slope")
      beta_c            <- sum(norm_weights * slopes_valid)

      # Two-sided sign check (spec §5.11 Step 6).
      # After the direction-aware rank-flip in Step 2:
      #   Normal categories: higher totals -> higher rank -> positive slope expected.
      #   Inverse categories: higher totals -> lower standings pos -> negative slope expected.
      if (cat %in% INVERSE_CATEGORIES && beta_c > 0) {
        cli::cli_warn(
          paste0(
            "Unexpected positive OLS slope for inverse category {.val {cat}} ",
            "(\u03b2\u0302 = {round(beta_c, 4)}). ",
            "Expected negative slope after rank-flip (n+1 - rank). Check data quality."
          ),
          class = "rotostats_warning_unexpected_slope_sign"
        )
      } else if (!(cat %in% INVERSE_CATEGORIES) && beta_c < 0) {
        cli::cli_warn(
          paste0(
            "Unexpected negative OLS slope for normal category {.val {cat}} ",
            "(\u03b2\u0302 = {round(beta_c, 4)}). ",
            "Check that data is not an inverse category mislabeled as normal."
          ),
          class = "rotostats_warning_unexpected_slope_sign"
        )
      }

      # Near-zero guard.
      d_c <- if (abs(beta_c) < denom_floor) {
        cli::cli_warn(
          "Near-zero OLS slope ({.val {beta_c}}) for category {.val {cat}}. Denominator set to Inf.",
          class = "rotostats_warning_near_zero_slope"
        )
        Inf
      } else {
        1 / abs(beta_c)
      }

      # CV check: compute per-year denominator estimates and their CV.
      per_year_denoms <- 1 / abs(slopes_valid)
      if (length(per_year_denoms) > 1L) {
        cv_val <- stats::sd(per_year_denoms) / mean(per_year_denoms)
        if (!is.na(cv_val) && cv_val > 0.20) {
          cli::cli_warn(
            "High year-over-year denominator CV ({round(cv_val, 3)}) for category {.val {cat}}.",
            class = "rotostats_warning_high_denominator_cv"
          )
        }
      }

      # Build normalized diagnostics for all years (invalid years get weight=0).
      diag_rows <- lapply(per_year, function(r) {
        if (is.na(r$slope)) {
          r$norm_weight <- 0
        } else {
          idx <- which(vapply(valid_ys, function(v) v$year == r$year, logical(1L)))
          r$norm_weight <- if (length(idx) > 0L) norm_weights[[idx]] else 0
        }
        r
      })
      all_diag_rows[[cat]] <<- diag_rows
      return(d_c)

    } else {
      # gap / trimmed_gap / sd: weighted mean of gap_y.
      valid_mask <- !vapply(per_year, function(r) is.na(r$gap), logical(1L))
      valid_ys   <- per_year[valid_mask]
      if (length(valid_ys) == 0L) {
        cli::cli_warn(
          "No valid years remain for category {.val {cat}}. Denominator set to NA.",
          class = "rotostats_warning_no_valid_years"
        )
        all_diag_rows[[cat]] <<- per_year
        return(NA_real_)
      }
      raw_weights_valid <- vapply(valid_ys, `[[`, numeric(1L), "raw_weight")
      w_sum             <- sum(raw_weights_valid)
      norm_weights      <- raw_weights_valid / w_sum
      gaps_valid        <- vapply(valid_ys, `[[`, numeric(1L), "gap")
      d_c               <- sum(norm_weights * gaps_valid)

      # CV check.
      if (length(gaps_valid) > 1L) {
        cv_val <- stats::sd(gaps_valid) / mean(gaps_valid)
        if (!is.na(cv_val) && cv_val > 0.20) {
          cli::cli_warn(
            "High year-over-year denominator CV ({round(cv_val, 3)}) for category {.val {cat}}.",
            class = "rotostats_warning_high_denominator_cv"
          )
        }
      }

      # Build diagnostics.
      diag_rows <- lapply(per_year, function(r) {
        if (is.na(r$gap)) {
          r$norm_weight <- 0
        } else {
          idx <- which(vapply(valid_ys, function(v) v$year == r$year, logical(1L)))
          r$norm_weight <- if (length(idx) > 0L) norm_weights[[idx]] else 0
        }
        r
      })
      all_diag_rows[[cat]] <<- diag_rows
      return(d_c)
    }
  }, numeric(1L))

  names(denominators) <- scoring_categories

  # ----- Build year_diagnostics data.frame -----------------------------------

  diag_list <- unlist(all_diag_rows, recursive = FALSE)

  year_diagnostics <- data.frame(
    year     = vapply(diag_list, `[[`, integer(1L),  "year"),
    category = vapply(diag_list, `[[`, character(1L), "category"),
    n_teams  = vapply(diag_list, `[[`, integer(1L),  "n_teams"),
    slope    = vapply(diag_list, `[[`, numeric(1L),  "slope"),
    r_squared = vapply(diag_list, `[[`, numeric(1L), "r_squared"),
    weight   = vapply(diag_list, function(r) {
      if (is.null(r$norm_weight)) NA_real_ else r$norm_weight
    }, numeric(1L)),
    standings_pos_source = factor(
      vapply(diag_list, `[[`, character(1L), "standings_pos_source"),
      levels = c("category_pts", "rank")
    ),
    stringsAsFactors = FALSE
  )

  # ----- 5.12 Bootstrap CI ---------------------------------------------------

  bootstrap_ci <- if (n_bootstrap > 0L) {
    boot_denoms <- matrix(NA_real_, nrow = n_bootstrap, ncol = length(scoring_categories))
    colnames(boot_denoms) <- scoring_categories

    for (b in seq_len(n_bootstrap)) {
      for (cat in scoring_categories) {
        eff_years  <- cat_years[[cat]]
        weight_fn  <- cat_weight_fns[[cat]]
        valid_rows <- cat_valid_rows[[cat]]
        ts_cat     <- ts[valid_rows, , drop = FALSE]
        n_eff      <- length(eff_years)
        max_year   <- if (n_eff > 0L) max(eff_years) else NA_real_

        if (n_eff == 0L) next

        sample_years <- sample(eff_years, size = n_eff, replace = TRUE)

        # Compute per-sampled-year estimates.
        slopes_b <- vapply(sample_years, function(y) {
          ts_y    <- ts_cat[ts_cat$YEAR == y, , drop = FALSE]
          totals  <- ts_y[[cat]]
          if (length(totals) < 2L || stats::var(totals) < denom_floor) {
            return(NA_real_)
          }
          if (method == "ols") {
            pts_col <- paste0(cat, "_PTS")
            if (pts_col %in% names(ts_y)) {
              sp <- ts_y[[pts_col]]
            } else {
              # Direction-aware rank (mirrors main computation path).
              n_y_b <- length(totals)
              raw_rank_b <- rank(totals, ties.method = "average")
              sp <- if (cat %in% INVERSE_CATEGORIES) {
                n_y_b + 1L - raw_rank_b
              } else {
                raw_rank_b
              }
            }
            fit <- stats::lm(sp ~ totals)
            stats::coef(fit)[["totals"]]
          } else if (method == "gap") {
            mean(diff(sort(totals)))
          } else if (method == "trimmed_gap") {
            gaps <- diff(sort(totals))
            k    <- floor(0.1 * length(gaps))
            if (k > 0L) mean(gaps[(k + 1L):(length(gaps) - k)]) else mean(gaps)
          } else {  # sd
            n_y  <- length(totals)
            sd_y <- stats::sd(totals)
            e_rn <- expected_range_normal(n_y)
            sd_y * (n_y - 1) / e_rn
          }
        }, numeric(1L))

        years_ago_b <- max_year - sample_years
        raw_w_b     <- vapply(
          seq_along(sample_years),
          function(i) compute_weight(weight_fn, years_ago_b[[i]], n_eff),
          numeric(1L)
        )

        valid_b <- !is.na(slopes_b)
        if (!any(valid_b)) next

        raw_w_v  <- raw_w_b[valid_b]
        slopes_v <- slopes_b[valid_b]
        w_sum_b  <- sum(raw_w_v)

        if (method == "ols") {
          beta_b  <- sum(raw_w_v * slopes_v) / w_sum_b
          d_b     <- if (abs(beta_b) < denom_floor) Inf else 1 / abs(beta_b)
        } else {
          d_b <- sum(raw_w_v * slopes_v) / w_sum_b
        }

        boot_denoms[b, cat] <- d_b
      }
    }

    alpha <- 1 - ci_level
    ci_lower <- vapply(scoring_categories, function(cat) {
      stats::quantile(boot_denoms[, cat], alpha / 2, names = FALSE, na.rm = TRUE)
    }, numeric(1L))
    ci_upper <- vapply(scoring_categories, function(cat) {
      stats::quantile(boot_denoms[, cat], 1 - alpha / 2, names = FALSE, na.rm = TRUE)
    }, numeric(1L))

    data.frame(
      category    = scoring_categories,
      ci_lower    = ci_lower,
      ci_upper    = ci_upper,
      ci_level    = ci_level,
      n_bootstrap = n_bootstrap,
      stringsAsFactors = FALSE
    )
  } else {
    NULL
  }

  # ----- 5.13 Construct Return Object ----------------------------------------

  years_used <- sort(unique(unlist(cat_years)))

  meta <- list(
    rate_conversion = rate_conversion,
    method          = method,
    years_used      = years_used,
    exclude_years   = exclude_years,
    package_version = utils::packageVersion("rotostats")
  )

  new_sgp_denominators(
    denominators     = denominators,
    year_diagnostics = year_diagnostics,
    bootstrap_ci     = bootstrap_ci,
    call             = the_call,
    meta             = meta,
    rate_conversion  = rate_conversion
  )
}

# ---------------------------------------------------------------------------
# resolve_weight() — internal helper for the weights argument
# ---------------------------------------------------------------------------

#' @noRd
resolve_weight <- function(w) {
  if (identical(w, "flat")) {
    return(flat())
  }
  if (identical(w, "linear")) {
    return(linear_decay())
  }
  if (is.function(w) || inherits(w, "linear_decay_weight")) {
    return(w)
  }
  cli::cli_abort(
    paste0(
      "{.arg weights} must be a weight constructor result ({.fn flat}, {.fn linear_decay}, {.fn exp_decay}), ",
      "or the character shorthand {.val \"flat\"} or {.val \"linear\"}."
    ),
    class = "rotostats_error_invalid_weights"
  )
}
