# zaa.R — Z-Scores Above Average
#
# Exports:
#   zaa()    — per-player, per-category z-scores within the rostered pool
#
# Internal helpers (not exported):
#   .pop_sd()          — population SD (denominator n)
#   .zaa_col_name()    — column name sanitizer (zaa_HR, zaa_bb_per_9, etc.)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

#' @noRd
.pop_sd <- function(x) {
  sqrt(mean((x - mean(x))^2))
}

#' @noRd
.zaa_col_name <- function(cats) {
  has_slash <- grepl("/", cats, fixed = TRUE)
  out <- cats
  out[has_slash] <- tolower(gsub("/", "_per_", out[has_slash], fixed = TRUE))
  paste0("zaa_", out)
}

# ---------------------------------------------------------------------------
# Exported function: zaa()
# ---------------------------------------------------------------------------

#' Z-Scores Above Average
#'
#' @description
#' Computes per-player, per-category z-scores above the within-position average
#' for rotisserie baseball projection data. The anchor is the position mean:
#' a player at the position mean gets `total_zaa = 0`.
#'
#' Rate stats (ERA, WHIP, and all `INVERSE_CATEGORIES`, plus AVG) receive a
#' two-step volume-weighted treatment: a raw z-score is computed from the
#' unweighted mean and SD, then multiplied by the player's volume statistic
#' (IP for ERA/WHIP-family; AB for AVG) and re-standardized using the
#' population SD of those volume-weighted values within the pool. ERA and
#' WHIP z-scores are negated so that positive z = positive standings
#' contribution.
#'
#' Counting stats (HR, R, RBI, SB, K, W, SV, HLD, QS, SVHD, etc.) use the
#' unweighted population mean and SD directly.
#'
#' @param stats A data frame of full-season projected or actual statistics.
#'   Must include all `config$categories` columns and, when ERA, WHIP, or AVG
#'   are scored, `IP` and `AB` as full-season totals. Superseded by
#'   `attr(replacement, "projections")` when `replacement` is supplied.
#' @param config A `league_config` object from [league_config()]. Superseded by
#'   `attr(replacement, "config")` when `replacement` is supplied.
#' @param replacement Optional. A `replacement_level()` output object. When
#'   supplied, restricts the player pool to the rostered pool it defines and
#'   provides `stats` and `config` via attributes. When `NULL`, all rows in
#'   `stats` are used and a notice is emitted.
#' @param pitcher_pool Character. One of `"combined"` (default), `"split"`, or
#'   `"none"`. Controls whether SP and RP share a z-score pool.
#'   `"combined"`: all pitchers in one pool (LPP/FanGraphs approach).
#'   `"split"`: SP and RP form separate pools (FVARz/BIGz approach).
#'   `"none"`: all pitchers in one pool, no SP/RP distinction.
#' @param hitter_pool Character. One of `"positional"` (default) or
#'   `"combined"`. Controls whether hitter z-scores are computed within each
#'   position (`"positional"`) or across all hitters together (`"combined"`).
#' @param category_weight Named numeric vector mapping position pool labels
#'   (e.g., `c(SP = 0.8, RP = 0.8)`) to manual multipliers applied to
#'   `total_zaa`. Overrides `weight_method` when supplied.
#' @param weight_method Character. One of `"none"` (default), `"linear"`, or
#'   `"sqrt"`. Auto-computes category-count normalization for `total_zaa`.
#'   Ignored when `category_weight` is supplied.
#' @param ... Reserved for future use.
#'
#' @return A data frame with one row per player in the selected pool, columns
#'   `zaa_<CAT>` for each scored category in `config$categories` order, and
#'   `total_zaa`. If `player_id` is present in the working stats, it is
#'   prepended as the first column. Three attributes are set:
#'   \describe{
#'     \item{`attr(result, "units")`}{`"zscore"`}
#'     \item{`attr(result, "anchor")`}{`"average"`}
#'     \item{`attr(result, "distribution")`}{Nested or flat list of per-pool,
#'       per-category distribution parameters. For counting stats: `list(mean,
#'       sd)`. For rate stats: `list(mean, sd, sd_vol)` where `sd_vol` is the
#'       population SD of the volume-weighted z-scores (Step 2b denominator),
#'       used by `zar()` to score replacement lines without re-running `zaa()`.
#'       Schema: nested (position-keyed -> category-keyed) when
#'       `hitter_pool = "positional"`; flat (category-keyed) when
#'       `hitter_pool = "combined"`. Pitchers: nested when
#'       `pitcher_pool = "split"`, flat otherwise.}
#'   }
#'
#' @section Sign convention:
#' ERA, WHIP, and all [inverse_categories()] are negated: a positive z-score
#' means a positive contribution to standings. AVG and all counting stats are
#' NOT negated. Column names do not encode direction; consumers must respect this
#' convention.
#'
#' @section Pool definition:
#' When `replacement` is supplied, only players in
#' `attr(replacement, "position_assignments")` are scored; fringe players below
#' the replacement boundary are excluded. When `replacement = NULL`, all rows in
#' `stats` are used and within-position SD may be inflated by marginal players.
#'
#' @examples
#' # Minimal example with explicit stats and config
#' cfg <- league_config(
#'   n_teams = 12,
#'   roster_slots = c(C = 1, `1B` = 1, `2B` = 1, `3B` = 1, SS = 1, OF = 3, UTIL = 1),
#'   pitcher_slots = c(SP = 5, RP = 3),
#'   categories = c("HR", "R", "RBI", "SB", "AVG", "W", "K", "SV", "ERA", "WHIP"),
#'   budget = 260
#' )
#' # proj <- <data frame of projections>
#' # result <- zaa(stats = proj, config = cfg)
#'
#' @seealso [par()], [sgp()], [replacement_level()], [league_config()],
#'   [inverse_categories()]
#'
#' @export
zaa <- function(
  stats           = NULL,
  config          = NULL,
  replacement     = NULL,
  pitcher_pool    = "combined",
  hitter_pool     = "positional",
  category_weight = NULL,
  weight_method   = "none",
  ...
) {

  # ---------------------------------------------------------------------------
  # Step V1 — Parameter membership (user-supplied non-default values only)
  # ---------------------------------------------------------------------------

  if (!missing(pitcher_pool)) {
    tryCatch(
      checkmate::assert_choice(pitcher_pool, c("combined", "split", "none")),
      error = function(e) {
        cli::cli_abort(
          c(
            "{.arg pitcher_pool} must be one of {.val combined}, {.val split}, or {.val none}.",
            "i" = "You supplied: {.val {pitcher_pool}}"
          ),
          class = "rotostats_error_invalid_parameter",
          call  = rlang::caller_env()
        )
      }
    )
  }

  if (!missing(hitter_pool)) {
    tryCatch(
      checkmate::assert_choice(hitter_pool, c("positional", "combined")),
      error = function(e) {
        cli::cli_abort(
          c(
            "{.arg hitter_pool} must be one of {.val positional} or {.val combined}.",
            "i" = "You supplied: {.val {hitter_pool}}"
          ),
          class = "rotostats_error_invalid_parameter",
          call  = rlang::caller_env()
        )
      }
    )
  }

  if (!missing(weight_method)) {
    tryCatch(
      checkmate::assert_choice(weight_method, c("none", "linear", "sqrt")),
      error = function(e) {
        cli::cli_abort(
          c(
            "{.arg weight_method} must be one of {.val none}, {.val linear}, or {.val sqrt}.",
            "i" = "You supplied: {.val {weight_method}}"
          ),
          class = "rotostats_error_invalid_parameter",
          call  = rlang::caller_env()
        )
      }
    )
  }

  # ---------------------------------------------------------------------------
  # Step V2 — Replacement attribute extraction (when replacement is non-NULL)
  # ---------------------------------------------------------------------------

  if (!is.null(replacement)) {
    projections_from_repl <- attr(replacement, "projections")
    config_from_repl      <- attr(replacement, "config")

    if (is.null(projections_from_repl) || is.null(config_from_repl)) {
      cli::cli_abort(
        c(
          "The {.arg replacement} object is missing required attributes.",
          "i" = "Use {.fn replacement_level} to build the {.arg replacement} object."
        ),
        class = "rotostats_error_missing_replacement_attrs",
        call  = rlang::caller_env()
      )
    }

    stat_units <- attr(replacement, "stat_units")
    if (!identical(stat_units, "raw_projected")) {
      cli::cli_abort(
        c(
          "The {.arg replacement} object has {.code stat_units = \"{stat_units}\"}, not {.val raw_projected}.",
          "i" = "Ensure the replacement level is built from raw projected statistics."
        ),
        class = "rotostats_error_stat_units_mismatch",
        call  = rlang::caller_env()
      )
    }
  }

  # ---------------------------------------------------------------------------
  # Step V3 — Argument superseding and required-arg check
  # ---------------------------------------------------------------------------

  if (!is.null(replacement)) {
    working_stats  <- projections_from_repl
    working_config <- config_from_repl
  } else {
    if (is.null(stats)) {
      cli::cli_abort(
        c(
          "Required argument missing: supply {.arg stats} (or {.arg replacement} with a {.code projections} attribute)."
        ),
        class = "rotostats_error_invalid_parameter",
        call  = rlang::caller_env()
      )
    }
    if (is.null(config)) {
      cli::cli_abort(
        c(
          "Required argument missing: supply {.arg config} (or {.arg replacement} with a {.code config} attribute)."
        ),
        class = "rotostats_error_invalid_parameter",
        call  = rlang::caller_env()
      )
    }
    working_stats  <- stats
    working_config <- config

    # Step V6a — Unrestricted-pool inform
    cli::cli_inform(
      c(
        "i" = "No {.arg replacement} object supplied; using all rows in {.arg stats} as the player pool.",
        " " = "Within-position SD may be inflated by marginal players.",
        " " = "For tighter distributions, supply a {.cls replacement_level} object from {.fn replacement_level}."
      )
    )
  }

  # ---------------------------------------------------------------------------
  # Step V4 — working_stats shape checks
  # ---------------------------------------------------------------------------

  if (!is.data.frame(working_stats)) {
    cli::cli_abort(
      c("{.arg stats} must be a data frame.", "i" = "Got: {.cls {class(working_stats)}}"),
      class = "rotostats_error_not_data_frame",
      call  = rlang::caller_env()
    )
  }

  categories    <- working_config$categories
  stats_cols    <- toupper(names(working_stats))
  cat_upper     <- toupper(categories)
  missing_cats  <- categories[!cat_upper %in% stats_cols]

  if (length(missing_cats) > 0) {
    cli::cli_abort(
      c(
        "The following scored categories are missing from {.arg stats}: {.val {missing_cats}}.",
        "i" = "All elements of {.code config$categories} must be columns in {.arg stats}."
      ),
      class = "rotostats_error_missing_column",
      call  = rlang::caller_env()
    )
  }

  # Rate-stat denominator columns: IP for INVERSE_CATEGORIES, AB for AVG
  has_inv <- any(cat_upper %in% INVERSE_CATEGORIES)
  has_avg <- "AVG" %in% cat_upper

  if (has_inv && !"IP" %in% toupper(names(working_stats))) {
    cli::cli_abort(
      c(
        "Column {.code IP} is required for rate-stat scoring but is absent from {.arg stats}.",
        "i" = "Add full-season projected IP to {.arg stats}."
      ),
      class = "rotostats_error_missing_column",
      call  = rlang::caller_env()
    )
  }

  if (has_avg && !"AB" %in% toupper(names(working_stats))) {
    cli::cli_abort(
      c(
        "Column {.code AB} is required for AVG scoring but is absent from {.arg stats}.",
        "i" = "Add full-season projected AB to {.arg stats}."
      ),
      class = "rotostats_error_missing_column",
      call  = rlang::caller_env()
    )
  }

  # Numeric type check for scored categories
  # Resolve actual column names (case-insensitive match)
  col_map <- stats::setNames(names(working_stats), toupper(names(working_stats)))
  for (cat in categories) {
    actual_col <- col_map[toupper(cat)]
    if (!is.numeric(working_stats[[actual_col]])) {
      cli::cli_abort(
        c(
          "Column {.code {actual_col}} must be numeric.",
          "i" = "Got: {.cls {class(working_stats[[actual_col]])}}"
        ),
        class = "rotostats_error_wrong_column_type",
        call  = rlang::caller_env()
      )
    }
  }

  # ---------------------------------------------------------------------------
  # Step V5 — category_weight shape (only when non-NULL)
  # ---------------------------------------------------------------------------

  if (!is.null(category_weight)) {
    tryCatch(
      checkmate::assert_numeric(category_weight, names = "named"),
      error = function(e) {
        cli::cli_abort(
          c(
            "{.arg category_weight} must be a named numeric vector.",
            "i" = "Example: {.code c(SP = 0.8, RP = 0.8, C = 1.0)}"
          ),
          class = "rotostats_error_invalid_parameter",
          call  = rlang::caller_env()
        )
      }
    )
  }

  # ---------------------------------------------------------------------------
  # Step V6b — Pool construction
  # ---------------------------------------------------------------------------

  # Build a column-name lookup (uppercase key -> actual column name in working_stats)
  upper_col_map <- stats::setNames(names(working_stats), toupper(names(working_stats)))

  # Determine position_assignments
  if (!is.null(replacement)) {
    position_assignments <- attr(replacement, "position_assignments")
    # position_assignments: named character vector (player_id -> pool label)
    # or data frame with player_id and pool_label columns
    # Restrict working_stats to players in position_assignments
    if (is.data.frame(position_assignments)) {
      pa_ids   <- position_assignments$player_id
      pa_pools <- stats::setNames(
        as.character(position_assignments$pool_label),
        as.character(position_assignments$player_id)
      )
    } else {
      # Named character vector: names = player_id, values = pool label
      pa_ids   <- names(position_assignments)
      pa_pools <- stats::setNames(as.character(position_assignments), names(position_assignments))
    }

    # Restrict to rostered players
    if ("PLAYER_ID" %in% toupper(names(working_stats))) {
      pid_col <- upper_col_map["PLAYER_ID"]
      keep    <- working_stats[[pid_col]] %in% pa_ids
      working_stats <- working_stats[keep, , drop = FALSE]
      # Re-compute column map after row restriction (columns unchanged)
      upper_col_map <- stats::setNames(names(working_stats), toupper(names(working_stats)))
      # Pool labels per row
      row_pools <- pa_pools[as.character(working_stats[[pid_col]])]
    } else {
      # No player_id column — use row position matching (best-effort)
      row_pools <- pa_pools[seq_len(min(nrow(working_stats), length(pa_pools)))]
    }
  } else {
    # No replacement: use pos_eligibility (first position only)
    pos_col <- if ("pos_eligibility" %in% tolower(names(working_stats))) {
      names(working_stats)[tolower(names(working_stats)) == "pos_eligibility"][1]
    } else {
      NULL
    }

    if (!is.null(pos_col)) {
      first_pos <- vapply(
        strsplit(as.character(working_stats[[pos_col]]), "/", fixed = TRUE),
        function(x) trimws(x[1]),
        character(1)
      )
    } else {
      # Fall back: all players unlabeled — treated as combined pool
      first_pos <- rep("ALL", nrow(working_stats))
    }
    row_pools <- first_pos
  }

  n_players <- nrow(working_stats)
  if (n_players == 0L) {
    # Return empty data frame with correct structure
    zaa_cols_empty <- .zaa_col_name(categories)
    out_cols <- c(
      if ("PLAYER_ID" %in% toupper(names(working_stats))) upper_col_map["PLAYER_ID"],
      zaa_cols_empty,
      "total_zaa"
    )
    result <- as.data.frame(
      matrix(numeric(0), nrow = 0, ncol = length(out_cols)),
      col.names = out_cols
    )
    attr(result, "units")        <- "zscore"
    attr(result, "anchor")       <- "average"
    attr(result, "distribution") <- list()
    return(result)
  }

  # Classify each player row as hitter or pitcher
  # SP / RP are pitcher slots; all others are hitters
  is_pitcher <- row_pools %in% c("SP", "RP", "P", "ALL_PITCHERS")
  is_hitter  <- !is_pitcher

  # Finalize pool labels given pitcher_pool and hitter_pool settings
  pool_labels <- character(n_players)

  # Hitters
  if (hitter_pool == "combined") {
    pool_labels[is_hitter] <- "ALL_HITTERS"
  } else {
    # positional — use row_pools directly for hitters
    pool_labels[is_hitter] <- row_pools[is_hitter]
  }

  # Pitchers
  if (pitcher_pool == "split") {
    # Use SP / RP labels directly from row_pools
    pool_labels[is_pitcher] <- row_pools[is_pitcher]
    # If row_pools for pitchers didn't give SP/RP (e.g., already "ALL_PITCHERS"),
    # keep them as-is so they still get processed
    is_empty <- is_pitcher & (is.na(pool_labels) | pool_labels == "")
    if (any(is_empty)) {
      pool_labels[is_empty] <- "ALL_PITCHERS"
    }
  } else {
    # combined or none: all pitchers in one pool
    pool_labels[is_pitcher] <- "ALL_PITCHERS"
  }

  # Fill any remaining blanks or NAs (players whose row_pools didn't classify above)
  blank_labels <- is.na(pool_labels) | pool_labels == ""
  if (any(blank_labels)) {
    pool_labels[blank_labels] <- row_pools[blank_labels]
  }

  # ---------------------------------------------------------------------------
  # Step V7 — Warning: weight_method x pitcher_pool = "combined" interaction
  # ---------------------------------------------------------------------------

  if (weight_method != "none" && pitcher_pool == "combined" && is.null(category_weight)) {
    pitcher_row_idx <- which(is_pitcher)
    if (length(pitcher_row_idx) > 0L) {
      n_pitcher_cats <- sum(
        vapply(categories, function(cat) {
          col <- upper_col_map[toupper(cat)]
          any(!is.na(working_stats[[col]][pitcher_row_idx]) &
                working_stats[[col]][pitcher_row_idx] != 0)
        }, logical(1))
      )
    } else {
      n_pitcher_cats <- 0L
    }
    cli::cli_warn(
      c(
        "!" = paste0(
          "Auto-computed {.arg weight_method} weights treat all pitchers as having ",
          n_pitcher_cats, " non-zero categories."
        ),
        " " = "SPs contribute ~0 to saves/holds; RPs contribute ~0 to wins.",
        " " = "The normalization factor may overstate for both groups.",
        "i" = paste0(
          "Use {.code pitcher_pool = \"split\"} for per-group normalization, ",
          "or supply {.arg category_weight} for precise control."
        )
      ),
      class = "rotostats_warning_auto_weight_combined_pool",
      call  = rlang::caller_env()
    )
  }

  # ---------------------------------------------------------------------------
  # Step 2 — Within-pool z-scores
  # ---------------------------------------------------------------------------

  # Initialize z-score matrix (players x categories)
  zaa_col_names <- .zaa_col_name(categories)
  zaa_matrix    <- matrix(
    NA_real_,
    nrow     = n_players,
    ncol     = length(categories),
    dimnames = list(NULL, zaa_col_names)
  )

  # Distribution attribute storage
  distribution <- list()

  # Identify rate stats: INVERSE_CATEGORIES or AVG
  is_rate_cat <- toupper(categories) %in% c(INVERSE_CATEGORIES, "AVG")
  rate_warned_denom <- character(0)  # track warned denominator columns

  # Get unique pool labels
  unique_pools <- unique(pool_labels)

  for (pool_lbl in unique_pools) {
    pool_rows <- which(pool_labels == pool_lbl)
    pool_data <- working_stats[pool_rows, , drop = FALSE]
    n_pool    <- length(pool_rows)

    if (n_pool == 0L) next

    for (ci in seq_along(categories)) {
      cat        <- categories[ci]
      cat_upper_i <- toupper(cat)
      col_name   <- upper_col_map[cat_upper_i]
      zaa_col    <- zaa_col_names[ci]
      cat_values <- pool_data[[col_name]]

      if (is_rate_cat[ci]) {
        # ------------------------------------------------------------------
        # Step 2a — Rate stat: raw z-score (unweighted)
        # ------------------------------------------------------------------
        mean_c <- mean(cat_values)
        sd_c   <- .pop_sd(cat_values)

        # Guard: SD = 0, NA — all players identical; set z-scores to 0
        if (isTRUE(sd_c == 0) || is.na(sd_c)) {
          z_raw <- rep(0, n_pool)
        } else {
          if (cat_upper_i %in% INVERSE_CATEGORIES) {
            # Lower is better: negate so positive z = positive standings
            z_raw <- -(cat_values - mean_c) / sd_c
          } else {
            # AVG: higher is better, no negation
            z_raw <- (cat_values - mean_c) / sd_c
          }
        }

        # ------------------------------------------------------------------
        # Step 2b — Volume-weight and re-standardize
        # ------------------------------------------------------------------
        denom_col_upper <- if (cat_upper_i == "AVG") "AB" else "IP"
        denom_col       <- upper_col_map[denom_col_upper]
        denom_values    <- pool_data[[denom_col]]

        # Zero/NA volume check — warn once per denominator column
        zero_vol <- is.na(denom_values) | denom_values == 0
        if (any(zero_vol) && !denom_col_upper %in% rate_warned_denom) {
          affected_ids <- if ("PLAYER_ID" %in% toupper(names(pool_data))) {
            pool_data[[upper_col_map["PLAYER_ID"]]][zero_vol]
          } else {
            pool_rows[zero_vol]
          }
          cli::cli_warn(
            paste0(
              "Player(s) with 0 or NA projected ", denom_col_upper,
              " in category {.val {cat}}: ",
              paste(affected_ids, collapse = ", "),
              ". Rate-stat z-score set to {.code NA}."
            ),
            class = "rotostats_warning_zero_playing_time",
            call  = rlang::caller_env()
          )
          rate_warned_denom <- c(rate_warned_denom, denom_col_upper)
        }

        # Set z_raw to NA for zero-volume players (NA propagates through z_vol)
        z_raw[zero_vol] <- NA_real_

        # Volume-weight
        z_vol <- z_raw * denom_values

        # Re-standardize: population SD of non-NA volume-weighted z-scores
        z_vol_valid <- z_vol[!is.na(z_vol)]
        if (length(z_vol_valid) < 2L) {
          sd_vol_c <- if (length(z_vol_valid) == 1L) 0 else NA_real_
        } else {
          sd_vol_c <- .pop_sd(z_vol_valid)
        }

        if (is.na(sd_vol_c) || isTRUE(sd_vol_c == 0)) {
          # Cannot re-standardize: 0 for non-NA entries, NA preserved
          final_z <- ifelse(is.na(z_vol), NA_real_, 0)
        } else {
          final_z <- z_vol / sd_vol_c
        }

        zaa_matrix[pool_rows, zaa_col] <- final_z

        # Distribution entry includes sd_vol (present for rate stats only)
        dist_entry <- list(mean = mean_c, sd = sd_c, sd_vol = sd_vol_c)

      } else {
        # ------------------------------------------------------------------
        # Step 2 — Counting stat: unweighted z-score
        # ------------------------------------------------------------------
        mean_c <- mean(cat_values)
        sd_c   <- .pop_sd(cat_values)

        if (isTRUE(sd_c == 0) || is.na(sd_c)) {
          # All identical (e.g., all zeros): z-score = 0
          zaa_matrix[pool_rows, zaa_col] <- 0
        } else {
          zaa_matrix[pool_rows, zaa_col] <- (cat_values - mean_c) / sd_c
        }

        # sd_vol intentionally absent for counting stats
        dist_entry <- list(mean = mean_c, sd = sd_c)
      }

      # Store in distribution with correct schema:
      # - Nested (position-keyed -> category-keyed) when pool uses positional schema
      # - Flat (category-keyed) when pool uses combined schema
      is_pitcher_pool <- pool_lbl %in% c("ALL_PITCHERS", "SP", "RP")
      use_nested <- if (is_pitcher_pool) {
        pitcher_pool == "split"
      } else {
        hitter_pool == "positional"
      }

      if (use_nested) {
        if (is.null(distribution[[pool_lbl]])) {
          distribution[[pool_lbl]] <- list()
        }
        distribution[[pool_lbl]][[cat]] <- dist_entry
      } else {
        distribution[[cat]] <- dist_entry
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Step 3 — Sum across all scored categories (total_zaa)
  # ---------------------------------------------------------------------------

  # na.rm = FALSE: any NA per-category z-score propagates to total_zaa
  total_zaa <- rowSums(zaa_matrix, na.rm = FALSE)

  # ---------------------------------------------------------------------------
  # Step 4 — Apply weight_method or category_weight to total_zaa
  # ---------------------------------------------------------------------------

  # n_hitter_cats: count of categories scored by hitters (non-NA, non-zero)
  hitter_rows <- which(is_hitter)

  if (length(hitter_rows) > 0L) {
    n_hitter_cats <- sum(
      vapply(categories, function(cat) {
        col <- upper_col_map[toupper(cat)]
        any(!is.na(working_stats[[col]][hitter_rows]) &
              working_stats[[col]][hitter_rows] != 0)
      }, logical(1))
    )
  } else {
    # No hitters in pool: use total category count as baseline
    n_hitter_cats <- length(categories)
  }

  if (!is.null(category_weight)) {
    # Step 4b — Apply manual category_weight (overrides weight_method)
    for (pos_label in names(category_weight)) {
      pos_rows <- which(pool_labels == pos_label)
      if (length(pos_rows) == 0L) next
      total_zaa[pos_rows] <- rowSums(
        zaa_matrix[pos_rows, , drop = FALSE],
        na.rm = FALSE
      ) * category_weight[[pos_label]]
    }
    # For pool groups NOT covered by category_weight, fall back to weight_method
    covered <- pool_labels %in% names(category_weight)
    if (weight_method != "none" && any(!covered)) {
      for (pool_lbl in unique(pool_labels[!covered])) {
        pos_rows <- which(pool_labels == pool_lbl)
        if (length(pos_rows) == 0L) next
        n_pos_cats <- sum(
          vapply(categories, function(cat) {
            col <- upper_col_map[toupper(cat)]
            any(!is.na(working_stats[[col]][pos_rows]) &
                  working_stats[[col]][pos_rows] != 0)
          }, logical(1))
        )
        multiplier <- switch(weight_method,
          "none"   = 1,
          "linear" = if (n_hitter_cats > 0) n_pos_cats / n_hitter_cats else 1,
          "sqrt"   = if (n_hitter_cats > 0) sqrt(n_pos_cats / n_hitter_cats) else 1
        )
        total_zaa[pos_rows] <- rowSums(
          zaa_matrix[pos_rows, , drop = FALSE],
          na.rm = FALSE
        ) * multiplier
      }
    }
  } else if (weight_method != "none") {
    # Step 4a — Auto-computed multipliers per pool group
    for (pool_lbl in unique_pools) {
      pos_rows <- which(pool_labels == pool_lbl)
      if (length(pos_rows) == 0L) next
      n_pos_cats <- sum(
        vapply(categories, function(cat) {
          col <- upper_col_map[toupper(cat)]
          any(!is.na(working_stats[[col]][pos_rows]) &
                working_stats[[col]][pos_rows] != 0)
        }, logical(1))
      )
      multiplier <- switch(weight_method,
        "none"   = 1,
        "linear" = if (n_hitter_cats > 0) n_pos_cats / n_hitter_cats else 1,
        "sqrt"   = if (n_hitter_cats > 0) sqrt(n_pos_cats / n_hitter_cats) else 1
      )
      total_zaa[pos_rows] <- rowSums(
        zaa_matrix[pos_rows, , drop = FALSE],
        na.rm = FALSE
      ) * multiplier
    }
  }
  # weight_method == "none" and category_weight NULL: total_zaa is already rowSums

  # ---------------------------------------------------------------------------
  # Step 5 — Output construction
  # ---------------------------------------------------------------------------

  # Column order: player_id (if present), zaa_<cat> in config$categories order, total_zaa
  result_list <- list()

  if ("PLAYER_ID" %in% toupper(names(working_stats))) {
    result_list[["player_id"]] <- working_stats[[upper_col_map["PLAYER_ID"]]]
  }

  for (ci in seq_along(zaa_col_names)) {
    result_list[[zaa_col_names[ci]]] <- unname(zaa_matrix[, zaa_col_names[ci]])
  }
  result_list[["total_zaa"]] <- unname(total_zaa)

  result <- as.data.frame(result_list, row.names = seq_len(n_players),
                          check.names = FALSE)

  # Attach output attributes
  attr(result, "units")        <- "zscore"
  attr(result, "anchor")       <- "average"
  attr(result, "distribution") <- distribution

  result
}
