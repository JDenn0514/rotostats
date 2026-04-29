# zar.R — Z-Scores Above Replacement
#
# Exports:
#   zar()  — per-player, per-category z-scores above the replacement level
#
# Internal helpers: none (delegates to zaa())

# ---------------------------------------------------------------------------
# Exported function: zar()
# ---------------------------------------------------------------------------

#' Z-Scores Above Replacement
#'
#' @title Z-Scores Above Replacement
#'
#' @description
#' Computes per-player, per-category z-scores above the replacement level by
#' calling [zaa()] internally and subtracting the replacement-band z-score for
#' each player's assigned position. A player at exactly the replacement level
#' for their position has \code{total_zar} approximately equal to 0 by
#' construction.
#'
#' The replacement-band z-score is derived by applying the distribution
#' parameters stored in \code{attr(zaa_result, "distribution")} (mean, sd,
#' sd_vol) directly to the band-average stat line from
#' \code{replacement$replacement_stats}. Rate stats (ERA/WHIP family and AVG)
#' use volume weighting (IP for ERA/WHIP-family; AB for AVG) identical to the
#' treatment in [zaa()]. The replacement player is never passed through
#' [zaa()] — the distribution is computed once from real rostered players.
#'
#' SP and RP always use separate replacement baselines regardless of
#' \code{pitcher_pool}. \code{pitcher_pool} controls the z-score normalization
#' pool in [zaa()]; it does NOT affect replacement player identification.
#'
#' @param replacement A \code{replacement_level} output object produced by
#'   [replacement_level()]. Must carry \code{attr(., "projections")} and
#'   \code{attr(., "config")} as non-NULL attributes. Must NOT have been
#'   produced with \code{multi_pos = "all"}.
#' @param include_raw Logical scalar. Default \code{FALSE}. When \code{TRUE},
#'   include \code{zaa_<cat>} and \code{total_zaa} columns (raw z-scores above
#'   average, before replacement subtraction) in the output. Column order is
#'   \code{zaa_*} first, then \code{zar_*}.
#' @param pitcher_pool Character scalar. One of \code{"combined"} (default),
#'   \code{"split"}, or \code{"none"}. Forwarded unchanged to the internal
#'   [zaa()] call. Controls whether SP and RP share a z-score normalization
#'   pool. Does NOT affect which replacement stat line is used for each role.
#' @param batter_pool Character scalar. One of \code{"positional"} (default)
#'   or \code{"combined"}. Forwarded unchanged to the internal [zaa()] call.
#'   Controls whether batter z-scores are computed within each position or
#'   across all batters together.
#' @param category_weight Named numeric vector or \code{NULL} (default).
#'   Forwarded unchanged to the internal [zaa()] call. Manual multipliers
#'   applied to \code{total_zaa} (and therefore \code{total_zar}) per position
#'   pool label.
#' @param weight_method Character scalar. One of \code{"none"} (default),
#'   \code{"linear"}, or \code{"sqrt"}. Forwarded unchanged to the internal
#'   [zaa()] call. Auto-computes category-count normalization. Ignored when
#'   \code{category_weight} is supplied.
#' @param ... Reserved for future use. Forwarded to the internal [zaa()] call.
#'
#' @return A plain \code{data.frame} with one row per rostered player in
#'   \code{attr(replacement, "position_assignments")}:
#'   \describe{
#'     \item{\code{player_id}}{(only when \code{player_id} is present in
#'       \code{attr(replacement, "projections")}) Player identifier, prepended
#'       as the first column.}
#'     \item{\code{zaa_<cat>}}{(only when \code{include_raw = TRUE}) Per-category
#'       within-position z-score from [zaa()], in \code{config$categories}
#'       order.}
#'     \item{\code{total_zaa}}{(only when \code{include_raw = TRUE}) Sum of
#'       \code{zaa_<cat>} across scored categories (\code{na.rm = FALSE}).}
#'     \item{\code{zar_<cat>}}{Per-category z-score above the replacement level.
#'       \code{NA} when the corresponding \code{zaa_<cat>} is \code{NA} or the
#'       player has no position assignment.}
#'     \item{\code{total_zar}}{\code{rowSums()} across all \code{zar_<cat>}
#'       columns with \code{na.rm = TRUE}. Mixed batter/pitcher pools carry
#'       \code{NA} for opposite-side categories (a batter has \code{NA} for
#'       ERA/WHIP; a pitcher has \code{NA} for AVG), and those \code{NA}s are
#'       treated as zero contribution so \code{total_zar} sums the categories
#'       each player actually participates in.}
#'   }
#'
#'   The returned data frame carries two attributes:
#'   \describe{
#'     \item{\code{attr(result, "units")}}{\code{"zscore"}}
#'     \item{\code{attr(result, "anchor")}}{\code{"replacement"}}
#'   }
#'
#' @section Sign convention:
#' ERA, WHIP, and all [inverse_categories()] are negated (inherited via
#' [zaa()]): a positive z-score means a positive standings contribution. Column
#' names do not encode direction; consumers must respect this convention.
#'
#' @section Rate-stat volume weighting:
#' Replacement-band z-scores for ERA/WHIP-family stats use the band-average
#' IP from \code{replacement$replacement_stats}. Replacement-band z-scores for
#' AVG use the band-average AB. This mirrors the volume-weighting treatment
#' applied by [zaa()] to individual players.
#'
#' @examples
#' config <- league_config(
#'   n_teams = 12L,
#'   roster_slots = c(
#'     "C" = 1,
#'     "1B" = 1,
#'     "2B" = 1,
#'     "3B" = 1,
#'     "SS" = 1,
#'     "OF" = 3,
#'     "DH" = 1
#'   ),
#'   pitcher_slots = 9,
#'   budget = 260L,
#'   budget_split = 0.67,
#'   batting_categories = c("HR", "R"),
#'   pitcher_categories = character(0L)
#' )
#' # proj   <- <data frame of projections>
#' # repl   <- replacement_level(proj, cfg)
#' # result <- zar(repl)
#' # result <- replacement_level(proj, cfg) |> zar()   # pipe-compatible
#'
#' @seealso [zaa()] for the underlying z-score computation;
#'   [replacement_level()] for producing the \code{replacement} input;
#'   [par()] for the SGP-units analog.
#'
#' @family valuation
#'
#' @export
zar <- function(
  replacement,
  include_raw = FALSE,
  pitcher_pool = "combined",
  batter_pool = "positional",
  category_weight = NULL,
  weight_method = "none",
  ...
) {
  # ---------------------------------------------------------------------------
  # Step V1 — include_raw validation (explicit-path only)
  # ---------------------------------------------------------------------------

  if (!missing(include_raw)) {
    tryCatch(
      checkmate::assert_flag(include_raw),
      error = function(e) {
        cli::cli_abort(
          c(
            "{.arg include_raw} must be a logical scalar (TRUE or FALSE).",
            "i" = "You supplied: {.cls {class(include_raw)}}"
          ),
          class = "rotostats_error_invalid_parameter",
          call = rlang::caller_env()
        )
      }
    )
  }

  # ---------------------------------------------------------------------------
  # Step V2 — Attribute extraction (replacement must carry projections + config)
  # ---------------------------------------------------------------------------

  projections <- attr(replacement, "projections")
  config <- attr(replacement, "config")

  if (is.null(projections) || is.null(config)) {
    cli::cli_abort(
      c(
        "The {.arg replacement} object is missing required attributes.",
        "i" = "Use {.fn replacement_level} to build the {.arg replacement} object."
      ),
      class = "rotostats_error_missing_replacement_attrs",
      call = rlang::caller_env()
    )
  }

  # ---------------------------------------------------------------------------
  # Step V3 — multi_pos = "all" guard
  # ---------------------------------------------------------------------------

  if (identical(replacement$params$multi_pos, "all")) {
    cli::cli_abort(
      c(
        "{.fn zar} does not support {.code multi_pos = \"all\"} replacement objects.",
        "i" = paste0(
          "Re-run {.fn replacement_level} with {.code multi_pos = \"best\"} (or ",
          "{.val highest_par}, {.val primary}, or {.val custom})."
        )
      ),
      class = "rotostats_error_multi_pos_all_unsupported",
      call = rlang::caller_env()
    )
  }

  # ---------------------------------------------------------------------------
  # Step V4 — Extract remaining attributes
  # ---------------------------------------------------------------------------

  position_assignments <- attr(replacement, "position_assignments")
  replacement_stats <- replacement$replacement_stats

  # ---------------------------------------------------------------------------
  # Step 1 — Compute within-position z-scores via zaa()
  #
  # Validation of pitcher_pool, batter_pool, weight_method, category_weight,
  # stat_units, column presence, and column types are all delegated to zaa().
  # ---------------------------------------------------------------------------

  zaa_result <- zaa(
    replacement = replacement,
    pitcher_pool = pitcher_pool,
    batter_pool = batter_pool,
    category_weight = category_weight,
    weight_method = weight_method,
    ...
  )

  # ---------------------------------------------------------------------------
  # Step 2 — Extract distribution parameters and compute replacement-band
  #           z-scores per position
  # ---------------------------------------------------------------------------

  distribution <- attr(zaa_result, "distribution")
  batting_categories <- config$batting_categories
  pitcher_categories <- config$pitcher_categories
  categories <- config$categories

  # Identify which positions are in replacement_stats
  repl_positions <- unique(replacement_stats$position)

  # Build zar_repl: named list keyed by position, each entry a named numeric
  # vector keyed by category. Cross-side categories (e.g. K for a batter
  # position) stay NA — they are never overwritten — so the per-row
  # subtraction propagates NA into the cross-side cells of zar_matrix.
  zar_repl <- vector("list", length(repl_positions))
  names(zar_repl) <- repl_positions

  for (pos in repl_positions) {
    # Determine the distribution extraction path for this position.
    # Phase 4 schema: distribution is keyed by side first (batter/pitcher),
    # then either flat (cat) for combined pools or nested (pool -> cat) for
    # positional/split pools.
    is_pitcher_pos <- pos %in% c("SP", "RP", "P")
    side_key <- if (is_pitcher_pos) "pitcher" else "batter"
    side_dist <- distribution[[side_key]]

    if (is_pitcher_pos) {
      use_nested <- identical(pitcher_pool, "split")
    } else {
      use_nested <- identical(batter_pool, "positional")
    }

    # Per-side categories: only iterate the side's own scored categories so
    # cross-side cells (e.g. zar_K for a batter row) stay NA.
    side_categories <- if (is_pitcher_pos) {
      pitcher_categories
    } else {
      batting_categories
    }

    # Get the replacement stat row for this position (use toupper for safety)
    repl_row <- replacement_stats[
      toupper(replacement_stats$position) == toupper(pos),
      ,
      drop = FALSE
    ]

    repl_z_vec <- stats::setNames(
      rep(NA_real_, length(categories)),
      categories
    )

    for (cat in side_categories) {
      cat_upper <- toupper(cat)

      # Extract distribution entry for this category / pool from the
      # side-keyed schema established by zaa() in Phase 4.
      if (use_nested) {
        dist_entry <- side_dist[[pos]][[cat]]
      } else {
        dist_entry <- side_dist[[cat]]
      }

      # Get the replacement-band stat value (use toupper for column lookup)
      repl_stat_col <- names(repl_row)[toupper(names(repl_row)) == cat_upper]
      if (length(repl_stat_col) == 0L) {
        # Category column absent from replacement_stats for this position
        # (e.g., batter-only stat for a pitcher position) — skip; leave NA
        repl_z_vec[cat] <- NA_real_
        next
      }
      repl_c <- repl_row[[repl_stat_col[1L]]]

      if (
        is.null(dist_entry) ||
          is.null(dist_entry$sd) ||
          is.na(dist_entry$sd) ||
          dist_entry$sd == 0
      ) {
        # SD = 0 or missing: pool is degenerate; replacement z-score = 0
        repl_z_vec[cat] <- 0
        next
      }

      if (cat_upper %in% INVERSE_CATEGORIES) {
        # ---- ERA/WHIP-family: negate and volume-weight by IP ----
        repl_ip_col <- names(repl_row)[toupper(names(repl_row)) == "IP"]
        if (length(repl_ip_col) == 0L) {
          # IP absent for this position row — propagate NA
          repl_z_vec[cat] <- NA_real_
          next
        }
        repl_ip <- repl_row[[repl_ip_col[1L]]]

        z_raw_repl <- -(repl_c - dist_entry$mean) / dist_entry$sd
        z_vol_repl <- z_raw_repl * repl_ip

        if (
          is.null(dist_entry$sd_vol) ||
            is.na(dist_entry$sd_vol) ||
            dist_entry$sd_vol == 0
        ) {
          repl_z_vec[cat] <- if (is.na(z_vol_repl)) NA_real_ else 0
        } else {
          repl_z_vec[cat] <- z_vol_repl / dist_entry$sd_vol
        }
      } else if (cat_upper == "AVG") {
        # ---- AVG: no negation, volume-weight by AB ----
        repl_ab_col <- names(repl_row)[toupper(names(repl_row)) == "AB"]
        if (length(repl_ab_col) == 0L) {
          repl_z_vec[cat] <- NA_real_
          next
        }
        repl_ab <- repl_row[[repl_ab_col[1L]]]

        z_raw_repl <- (repl_c - dist_entry$mean) / dist_entry$sd
        z_vol_repl <- z_raw_repl * repl_ab

        if (
          is.null(dist_entry$sd_vol) ||
            is.na(dist_entry$sd_vol) ||
            dist_entry$sd_vol == 0
        ) {
          repl_z_vec[cat] <- if (is.na(z_vol_repl)) NA_real_ else 0
        } else {
          repl_z_vec[cat] <- z_vol_repl / dist_entry$sd_vol
        }
      } else {
        # ---- Counting stat: unweighted z-score ----
        repl_z_vec[cat] <- (repl_c - dist_entry$mean) / dist_entry$sd
      }
    }

    zar_repl[[pos]] <- repl_z_vec
  }

  # ---------------------------------------------------------------------------
  # Step 3 — Identify each player's valuation position
  # ---------------------------------------------------------------------------

  # Prefer the per-row position_labels attribute emitted by zaa() — it
  # preserves positional alignment with zaa_result, so two-way players
  # (e.g. Shohei Ohtani) keep their side-specific position labels instead
  # of collapsing to whichever label comes first for that player_id in
  # position_assignments. These labels are the raw position_assignments
  # values (SP/RP/C/1B/OF/DH/…), which are the keys used in zar_repl.
  zaa_position_labels <- attr(zaa_result, "position_labels")

  if (
    !is.null(zaa_position_labels) &&
      length(zaa_position_labels) == nrow(zaa_result)
  ) {
    player_positions <- as.character(zaa_position_labels)
  } else {
    # Fallback: legacy by-name lookup against position_assignments (used when
    # zaa_result came from an older/external path without pool_labels). This
    # path collapses duplicate player_ids — acceptable for single-side pools.
    if (is.data.frame(position_assignments)) {
      pa_pools <- stats::setNames(
        as.character(position_assignments$pool_label),
        as.character(position_assignments$player_id)
      )
    } else {
      pa_pools <- stats::setNames(
        as.character(position_assignments),
        names(position_assignments)
      )
    }

    if ("player_id" %in% names(zaa_result)) {
      player_positions <- pa_pools[as.character(zaa_result$player_id)]
    } else {
      player_positions <- pa_pools[seq_len(nrow(zaa_result))]
    }
  }

  # ---------------------------------------------------------------------------
  # Step 4 — Subtract replacement-band z-score per player, per category
  #           (vectorized — no row-wise loop over players)
  # ---------------------------------------------------------------------------

  zaa_col_names <- grep("^zaa_", names(zaa_result), value = TRUE)
  n_players <- nrow(zaa_result)

  # Build a per-player replacement z-score matrix (n_players x n_cats)
  # using position_assignments to look up the replacement z-score per position.
  # The vapply below iterates over categories (small), not over players.
  repl_z_matrix <- matrix(NA_real_, nrow = n_players, ncol = length(categories))
  colnames(repl_z_matrix) <- categories

  for (ci in seq_along(categories)) {
    cat <- categories[ci]
    repl_z_matrix[, ci] <- vapply(
      player_positions,
      function(pos) {
        if (is.na(pos) || is.null(zar_repl[[pos]])) {
          return(NA_real_)
        }
        val <- zar_repl[[pos]][cat]
        if (is.null(val) || length(val) == 0L) NA_real_ else val
      },
      numeric(1L)
    )
  }

  # Subtract: zar[i, c] = zaa[i, c] - repl_z[i, c]
  zar_col_names <- sub("^zaa_", "zar_", zaa_col_names)
  zar_matrix <- as.matrix(zaa_result[, zaa_col_names, drop = FALSE]) -
    repl_z_matrix
  colnames(zar_matrix) <- zar_col_names

  # ---------------------------------------------------------------------------
  # Step 5 — Compute total_zar
  #
  # na.rm = TRUE so cross-side NAs (batter categories for pitchers and vice
  # versa) contribute 0 rather than propagating to total_zar. Matches par()'s
  # convention (see R/par.R total_par).
  # ---------------------------------------------------------------------------

  total_zar <- rowSums(zar_matrix, na.rm = TRUE)

  # ---------------------------------------------------------------------------
  # Step 6 — Assemble output data frame
  # ---------------------------------------------------------------------------

  result_list <- list()

  if ("player_id" %in% names(zaa_result)) {
    result_list[["player_id"]] <- zaa_result[["player_id"]]
  }

  # Carry per-row player_type ("batter" / "pitcher") through from zaa() so
  # downstream consumers can subset rows by side without re-deriving from
  # position labels. Aligned positionally with zar_matrix rows.
  if ("player_type" %in% names(zaa_result)) {
    result_list[["player_type"]] <- zaa_result[["player_type"]]
  }

  if (include_raw) {
    for (col in zaa_col_names) {
      result_list[[col]] <- zaa_result[[col]]
    }
    result_list[["total_zaa"]] <- zaa_result[["total_zaa"]]
  }

  for (col in zar_col_names) {
    result_list[[col]] <- unname(zar_matrix[, col])
  }
  result_list[["total_zar"]] <- unname(total_zar)

  result <- as.data.frame(
    result_list,
    row.names = seq_len(n_players),
    check.names = FALSE
  )

  # ---------------------------------------------------------------------------
  # Step 7 — Attach output attributes
  # ---------------------------------------------------------------------------

  attr(result, "units") <- "zscore"
  attr(result, "anchor") <- "replacement"

  result
}
