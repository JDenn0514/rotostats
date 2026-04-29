# par() — per-player Points Above Replacement in SGP units

# ---------------------------------------------------------------------------
# par()
# ---------------------------------------------------------------------------

#' Compute Points Above Replacement (PAR) in SGP units
#'
#' @title Points Above Replacement (SGP Units)
#'
#' @description
#' Converts per-player projected statistics into Points Above Replacement (PAR)
#' in SGP (Standings Gain Point) units by calling [sgp()] internally and
#' subtracting the replacement-level SGP line derived from a
#' [replacement_level()] output.  A player at exactly the replacement level
#' for their position has \code{total_par} approximately equal to 0 by construction.
#'
#' @details
#' ## Algorithm
#'
#' \code{par()} runs a strict linear 13-step algorithm:
#'
#' 1. Validate that \code{replacement} carries non-NULL \code{projections} and
#'    \code{config} attributes (abort otherwise).
#' 2. Extract remaining attributes: \code{position_assignments},
#'    \code{replacement$replacement_stats}, and band parameters.
#' 3. Unpack the \code{baseline} list into named overrides for ERA, WHIP, AVG.
#' 4. Call \code{sgp()} on the full player projection pool to produce
#'    \code{sgp_[CAT]} for every player.
#' 5. Build a combined projection frame (players + replacement rows), call
#'    \code{sgp()} on it, and extract the replacement-row SGP values.
#' 6. Validate that player SGP categories match replacement SGP categories.
#' 7. Construct a position x category replacement SGP lookup data frame.
#' 8. Map each player to their replacement SGP row via
#'    \code{match(player_positions, repl_sgp_mat$position)}.
#' 9. Subtract replacement SGP from player SGP (fully vectorized).
#' 10. Compute \code{total_par = rowSums(par_[CAT], na.rm = TRUE)} so mixed
#'     batter/pitcher pools (where batters have NA for pitcher-only categories
#'     and vice versa) sum correctly rather than producing NA.
#' 11. Band calibration check: median \code{total_par} of the +/-K band around
#'     the roster boundary must be within \code{boundary_threshold} of 0.
#' 12. Assemble the output data frame (optionally prepend raw SGP columns).
#' 13. Attach output attributes.
#'
#' ## Relationship to sgp()
#'
#' \code{par()} is a thin anchoring layer on top of [sgp()].  All rate-stat
#' conversion logic (ERA/WHIP blended-pool formulas, AVG sign flip, IP/AB
#' weighting) lives entirely inside \code{sgp()}.  \code{par()} does not
#' duplicate any of that logic: it calls \code{sgp()} twice -- once on the
#' full player pool and once on a combined frame (players + replacement rows)
#' so the pool constants are shared -- and then subtracts position-specific
#' replacement SGP from each player's SGP.
#'
#' ## Replacement band check
#'
#' After computing \code{total_par}, \code{par()} checks that the median
#' \code{total_par} of the +/-K players around the roster boundary (where K is
#' \code{replacement$params$band_width}) is within \code{boundary_threshold}
#' SGP points of zero.  A non-zero median indicates that the replacement level
#' is mis-calibrated: positive means replacement players look above-average
#' (threshold too conservative), negative means they look below-average
#' (threshold too aggressive).  The warning emits the observed median and
#' direction.  Do not adjust \code{boundary_threshold} to silence this warning;
#' instead, fix the upstream \code{\link{replacement_level}} call.
#'
#' @param replacement A \code{replacement_level} output object produced by
#'   \code{\link{replacement_level}}.  Must carry \code{attr(., "projections")}
#'   and \code{attr(., "config")} as non-NULL attributes.  Objects from
#'   \code{\link{replacement_from_prices}} are incompatible (their
#'   \code{projections} attribute is \code{NULL}) and will abort with
#'   \code{rotostats_error_missing_replacement_attrs}.
#' @param denominators A named numeric vector of SGP denominators produced by
#'   \code{\link{sgp_denominators}}.  Names must match scored categories.
#'   Must carry \code{attr(., "rate_conversion")}.
#' @param include_raw Logical scalar.  Default \code{FALSE}.  When \code{TRUE},
#'   include \code{sgp_[CAT]} and \code{total_sgp} columns (raw SGP before
#'   replacement subtraction) in the output.
#' @param boundary_threshold Numeric scalar.  Default \code{1.0}.  Emit
#'   \code{rotostats_warning_band_check} when the median \code{total_par} of
#'   the +/-K replacement band exceeds this value (in SGP units, i.e.,
#'   standings places).  Do not adjust to silence the warning.
#' @param rate_conversion Character scalar.  Passed to the internal
#'   \code{\link{sgp}} call.  One of \code{"blended_pool"} (default) or
#'   \code{"fixed_baseline"}.  \code{"fixed_baseline"} currently aborts with
#'   \code{rotostats_error_not_implemented} inside \code{sgp()}.
#' @param pool_baseline Character scalar.  Passed to the internal
#'   \code{\link{sgp}} call.  Currently only \code{"projection_pool"} is
#'   implemented.
#' @param baseline Named numeric vector or \code{NULL} (default).  Per-category
#'   baseline overrides for rate stat conversion.  Entry names must be from
#'   \code{c("era", "whip", "avg")}.  Entries are unpacked by name and forwarded
#'   to \code{\link{sgp}} as \code{baseline_era}, \code{baseline_whip}, and
#'   \code{baseline_avg}.
#' @param league_history A \code{league_history} S3 object (see
#'   \code{\link{league_history}}) or a duck-typed list with a
#'   \code{$team_season} data frame.  Required when
#'   \code{rate_conversion = "blended_pool"} (the default); \code{sgp()} aborts
#'   with \code{rotostats_error_missing_config_field} when this is \code{NULL}
#'   and \code{rate_conversion = "blended_pool"}.
#'
#' @return A plain \code{data.frame} with one row per player (row order matches
#'   \code{attr(replacement, "projections")}):
#'   \describe{
#'     \item{\code{par_[CAT]}}{One numeric column per scored category named
#'       \code{par_<CAT>} (uppercase, matching \code{sgp()} convention).  Value
#'       is the player's SGP minus the replacement-level SGP for their
#'       assigned position.  \code{NA} when any input SGP is \code{NA} or the
#'       player has no position assignment.}
#'     \item{\code{total_par}}{\code{rowSums()} across all \code{par_[CAT]}
#'       columns with \code{na.rm = TRUE}.  Mixed batter/pitcher pools carry
#'       \code{NA} for opposite-side categories (a batter has \code{NA} for
#'       K/SV; a pitcher has \code{NA} for HR/R/SB), so \code{na.rm = TRUE}
#'       is required for the sum to reflect each player's contribution.}
#'     \item{\code{sgp_[CAT]}}{(only when \code{include_raw = TRUE}) Raw SGP
#'       per category from the first internal \code{sgp()} call, before
#'       replacement subtraction.}
#'     \item{\code{total_sgp}}{(only when \code{include_raw = TRUE})
#'       \code{rowSums()} across \code{sgp_[CAT]} columns,
#'       \code{na.rm = FALSE}.}
#'   }
#'
#'   The returned data frame carries three attributes:
#'   \describe{
#'     \item{\code{replacement_sgp}}{Named list.  Keys are position names
#'       (e.g., \code{"SP"}, \code{"RP"}, \code{"C"}, \code{"1B"}).  Values
#'       are named numeric vectors whose names are scored category names and
#'       whose values are the replacement-level SGP for that position and
#'       category.}
#'     \item{\code{units}}{\code{"sgp"}}
#'     \item{\code{anchor}}{\code{"replacement"}}
#'   }
#'
#' @section Warnings:
#'
#' \subsection{rotostats_warning_band_check}{
#'   The median \code{total_par} of the +/-K players around the roster boundary
#'   exceeds \code{boundary_threshold} in absolute value.  The warning message
#'   reports the observed median and the direction of the mis-calibration.  Fix
#'   the upstream \code{\link{replacement_level}} call by tuning \code{n_teams}
#'   and roster slot counts in \code{\link{league_config}}; do not adjust
#'   \code{boundary_threshold} to silence this warning.
#' }
#'
#' \code{par()} also propagates any warnings emitted by the internal
#' \code{\link{sgp}} calls (e.g.,
#' \code{rotostats_warning_missing_category_column},
#' \code{rotostats_warning_zero_playing_time}).
#'
#' @seealso
#' \code{\link{sgp}} for the underlying SGP conversion;
#' \code{\link{replacement_level}} for producing the \code{replacement} input;
#' \code{\link{sgp_denominators}} for calibrating the \code{denominators} input.
#'
#' @family valuation
#'
#' @examples
#' \dontrun{
#' # Full blended_pool pipeline (requires sgp_denominators, replacement_level,
#' # and league_history):
#' repl   <- replacement_level(projections, cfg)
#' denoms <- sgp_denominators(league_hist, scoring_categories = cfg$categories)
#' result <- par(repl, denoms, league_history = league_hist)
#' head(result)
#' }
#'
#' @importFrom stats median setNames
#' @export
par <- function(
  replacement,
  denominators,
  include_raw = FALSE,
  boundary_threshold = 1.0,
  rate_conversion = "blended_pool",
  pool_baseline = "projection_pool",
  baseline = NULL,
  league_history = NULL
) {
  # ---------------------------------------------------------------------------
  # Step 1 — Validate replacement attributes (MUST be first)
  # ---------------------------------------------------------------------------
  projections <- attr(replacement, "projections")
  config <- attr(replacement, "config")

  if (is.null(projections) || is.null(config)) {
    cli::cli_abort(
      c(
        "The {.arg replacement} object is missing required attributes.",
        "i" = "{.arg replacement} must be produced by {.fn replacement_level}.",
        "i" = paste0(
          "Objects from {.fn replacement_from_prices} are not compatible with ",
          "{.fn par} because they carry a NULL {.code projections} attribute."
        )
      ),
      class = "rotostats_error_missing_replacement_attrs"
    )
  }

  # ---------------------------------------------------------------------------
  # Step 2 — Extract remaining attributes
  # ---------------------------------------------------------------------------
  position_assignments <- attr(replacement, "position_assignments")
  repl_stats <- replacement$replacement_stats
  K <- replacement$params$band_width

  # ---------------------------------------------------------------------------
  # Step 1b — Validate replacement_stats covers all scored categories
  # (must be before Step 5 so NA-fill does not silently mask missing columns)
  # ---------------------------------------------------------------------------
  scored_cat_names <- names(denominators)
  repl_stat_cols <- names(repl_stats)
  missing_in_repl <- setdiff(toupper(scored_cat_names), toupper(repl_stat_cols))

  if (length(missing_in_repl) > 0L) {
    n_missing <- length(missing_in_repl)
    cli::cli_abort(
      c(
        "{n_missing} scored categor{?y/ies} {?is/are} missing from \\
        {.code replacement$replacement_stats}.",
        "i" = "Missing from {.code replacement$replacement_stats}: \\
               {.val {missing_in_repl}}",
        "i" = "Scored categories in {.arg denominators}: \\
               {.val {scored_cat_names}}",
        "i" = "Ensure {.arg replacement} was produced with the same scored \\
               categories as {.arg denominators}."
      ),
      class = "rotostats_error_category_mismatch"
    )
  }

  # ---------------------------------------------------------------------------
  # Step 3 — Unpack baseline
  # ---------------------------------------------------------------------------
  baseline_era <- baseline[["era"]]
  baseline_whip <- baseline[["whip"]]
  baseline_avg <- baseline[["avg"]]

  # ---------------------------------------------------------------------------
  # Step 4 — Call sgp() on full player projections
  # ---------------------------------------------------------------------------
  sgp_out <- sgp(
    projections = projections,
    denominators = denominators,
    league_history = league_history,
    rate_conversion = rate_conversion,
    pool_baseline = pool_baseline,
    league_config = config,
    baseline_era = baseline_era,
    baseline_whip = baseline_whip,
    baseline_avg = baseline_avg
  )

  # ---------------------------------------------------------------------------
  # Step 5 — Build combined frame for replacement SGP construction
  # ---------------------------------------------------------------------------

  # 5a. Mark projections and replacement rows
  projections_marked <- projections
  projections_marked$.is_replacement <- FALSE

  repl_marked <- repl_stats
  repl_marked$.is_replacement <- TRUE

  # 5b-5c. Align columns: drop extra repl columns, fill missing ones with NA
  extra_cols <- setdiff(
    names(repl_marked),
    c(names(projections_marked), ".is_replacement")
  )
  repl_marked <- repl_marked[,
    setdiff(names(repl_marked), extra_cols),
    drop = FALSE
  ]

  for (col in setdiff(names(projections_marked), names(repl_marked))) {
    repl_marked[[col]] <- NA
  }
  repl_marked <- repl_marked[, names(projections_marked)]

  combined <- rbind(projections_marked, repl_marked)

  # 5d. Call sgp() on the combined frame (drop the marker column)
  combined_sgp <- sgp(
    projections = combined[,
      setdiff(names(combined), ".is_replacement"),
      drop = FALSE
    ],
    denominators = denominators,
    league_history = league_history,
    rate_conversion = rate_conversion,
    pool_baseline = pool_baseline,
    league_config = config,
    baseline_era = baseline_era,
    baseline_whip = baseline_whip,
    baseline_avg = baseline_avg
  )

  # 5e. Extract replacement rows and attach position labels
  repl_row_idx <- which(combined$.is_replacement)
  repl_sgp_df <- combined_sgp[repl_row_idx, , drop = FALSE]
  repl_sgp_df$position <- repl_stats$position

  # ---------------------------------------------------------------------------
  # Step 6 — Validate category name consistency
  # ---------------------------------------------------------------------------
  sgp_cats <- grep("^sgp_", names(sgp_out), value = TRUE)
  repl_sgp_cats <- grep("^sgp_", names(repl_sgp_df), value = TRUE)

  if (!setequal(sgp_cats, repl_sgp_cats)) {
    cli::cli_abort(
      c(
        "Category name mismatch between player SGP and replacement SGP.",
        "i" = "Player SGP categories: {.val {sgp_cats}}",
        "i" = "Replacement SGP categories: {.val {repl_sgp_cats}}",
        "i" = "Ensure {.arg denominators} covers all scored categories in {.code config}."
      ),
      class = "rotostats_error_category_mismatch"
    )
  }

  # ---------------------------------------------------------------------------
  # Step 7 — Construct replacement SGP lookup (position x category)
  # ---------------------------------------------------------------------------
  repl_sgp_mat <- repl_sgp_df[, c("position", sgp_cats), drop = FALSE]

  # ---------------------------------------------------------------------------
  # Step 8 — Map each player to their replacement position row
  # ---------------------------------------------------------------------------
  player_positions <- position_assignments[projections$PLAYER_ID]

  # ---------------------------------------------------------------------------
  # Step 9 — Subtract replacement SGP per player (vectorized, no row loop)
  # ---------------------------------------------------------------------------
  scored_cats <- gsub("^sgp_", "", sgp_cats)

  # O(n) position lookup via match()
  pos_idx <- match(player_positions, repl_sgp_mat$position)

  # Per-row side classification (used to gate cross-side category cells to NA
  # so a batter never receives a non-NA par_K and a pitcher never receives a
  # non-NA par_HR even if upstream sgp() would return finite values for the
  # opposite side). Derives side from the assigned valuation position when
  # available, falling back to POS_ELIGIBILITY parsing.
  is_pitcher_row <- player_positions %in% c("SP", "RP", "P")
  if (any(is.na(player_positions))) {
    pos_elig_col <- names(projections)[
      toupper(names(projections)) == "POS_ELIGIBILITY"
    ]
    if (length(pos_elig_col) >= 1L) {
      na_idx <- which(is.na(player_positions))
      is_pitcher_row[na_idx] <- grepl(
        PITCHER_ELIG_REGEX,
        projections[[pos_elig_col[1L]]][na_idx]
      )
    }
  }
  is_batter_row <- !is_pitcher_row

  # Side-scoped category lists for cross-side gating below.
  batting_categories <- toupper(config$batting_categories)
  pitcher_categories <- toupper(config$pitcher_categories)

  par_cols <- lapply(scored_cats, function(cat) {
    col <- paste0("sgp_", cat)
    vals <- sgp_out[[col]] - repl_sgp_mat[[col]][pos_idx]
    cat_upper <- toupper(cat)
    # Defense-in-depth: explicitly NA cross-side cells. In practice these
    # are already NA because per-side stats are NA in projections (e.g. K
    # is NA for batters, HR is NA for pitchers), but explicit gating keeps
    # par() correct if upstream sgp() ever propagates a non-NA value into
    # the opposite side.
    if (cat_upper %in% batting_categories) {
      vals[is_pitcher_row] <- NA_real_
    }
    if (cat_upper %in% pitcher_categories) {
      vals[is_batter_row] <- NA_real_
    }
    vals
  })
  names(par_cols) <- paste0("par_", scored_cats)

  # ---------------------------------------------------------------------------
  # Step 10 — Compute total_par
  # ---------------------------------------------------------------------------
  par_df <- as.data.frame(par_cols, row.names = seq_len(nrow(projections)))
  par_col_names <- paste0("par_", scored_cats)
  par_df$total_par <- rowSums(
    par_df[, par_col_names, drop = FALSE],
    na.rm = TRUE
  )

  # ---------------------------------------------------------------------------
  # Step 11 — Band calibration check
  # ---------------------------------------------------------------------------
  n_teams <- replacement$params$n_teams
  roster_slots <- replacement$params$roster_slots

  band_total_par_list <- lapply(
    names(roster_slots[roster_slots > 0L]),
    function(pos) {
      pos_players <- which(player_positions == pos)
      if (length(pos_players) == 0L) {
        return(numeric(0L))
      }

      boundary_rank <- n_teams * roster_slots[[pos]]
      K_eff <- min(K, floor(length(pos_players) / 4L))
      band_lo <- max(1L, boundary_rank - K_eff)
      band_hi <- min(length(pos_players), boundary_rank + K_eff)

      tp_pos <- par_df$total_par[pos_players]
      ord <- order(tp_pos, decreasing = TRUE)
      band_idx <- ord[seq(band_lo, band_hi)]
      tp_pos[band_idx]
    }
  )
  band_total_par <- unlist(band_total_par_list)

  if (length(band_total_par) > 0L) {
    band_median <- stats::median(band_total_par, na.rm = TRUE)
    if (!is.na(band_median) && abs(band_median) > boundary_threshold) {
      direction <- if (band_median > 0) "above" else "below"
      cli::cli_warn(
        c(
          paste0(
            "Replacement band check failed: median {.code total_par} of the ",
            "+/-{.val {K}} band around the roster boundary is ",
            "{.val {round(band_median, 3)}}, which exceeds ",
            "{.code boundary_threshold} = {.val {boundary_threshold}}."
          ),
          "i" = paste0(
            "The replacement level is too ",
            if (direction == "above") "conservative" else "aggressive",
            ": all PAR values are ",
            if (direction == "above") "inflated" else "deflated",
            "."
          ),
          "i" = "Check {.code n_teams} and roster slot counts in {.fn league_config}.",
          "i" = paste0(
            "Do not adjust {.arg boundary_threshold} to silence this warning ",
            "-- fix the upstream {.fn replacement_level} call instead."
          )
        ),
        class = "rotostats_warning_band_check"
      )
    }
  }

  # ---------------------------------------------------------------------------
  # Step 12 — Assemble output data frame
  # ---------------------------------------------------------------------------
  result <- par_df

  if (include_raw) {
    sgp_part <- sgp_out[,
      c(paste0("sgp_", scored_cats), "total_sgp"),
      drop = FALSE
    ]
    result <- cbind(sgp_part, result)
  }

  # Per-row side classification ("batter" / "pitcher"), aligned positionally
  # with the par_<cat> rows. Carried through so downstream consumers can
  # subset by side without re-deriving from POS_ELIGIBILITY. Mirrors the
  # convention used by zaa() / zar().
  result <- cbind(
    data.frame(
      player_type = ifelse(is_pitcher_row, "pitcher", "batter"),
      stringsAsFactors = FALSE
    ),
    result
  )

  # ---------------------------------------------------------------------------
  # Step 13 — Attach output attributes
  # ---------------------------------------------------------------------------
  repl_sgp_list <- lapply(
    split(repl_sgp_mat, repl_sgp_mat$position),
    function(df) {
      v <- as.numeric(df[, paste0("sgp_", scored_cats)])
      stats::setNames(v, scored_cats)
    }
  )

  attr(result, "replacement_sgp") <- repl_sgp_list
  attr(result, "units") <- "sgp"
  attr(result, "anchor") <- "replacement"

  result
}
