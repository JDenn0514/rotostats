# pvm.R — Percentage Valuation Method
#
# Exports:
#   pvm()  — per-player, per-category proportional pool shares in budget-fraction
#             units, anchored at replacement level

# ---------------------------------------------------------------------------
# Internal constants
# ---------------------------------------------------------------------------

#' @noRd
PVM_PITCHER_CATEGORIES <- c(
  "W", "K", "SV", "HLD", "SVHD", "QS",
  "ERA", "WHIP", "FIP", "XFIP", "SIERA", "XERA",
  "K/9", "BB/9", "HR/9"
)

# ---------------------------------------------------------------------------
# Exported function: pvm()
# ---------------------------------------------------------------------------

#' Percentage Valuation Method (PVM)
#'
#' @title Percentage Valuation Method (Budget-Fraction Units)
#'
#' @description
#' Computes per-player, per-category proportional shares of above-replacement
#' production, returning a data frame in \code{units = "budget_fraction"} with
#' columns \code{pvm_[CAT]} and \code{total_pvm}. Consumes a
#' \code{replacement_level()} output (carrying \code{projections} and
#' \code{config} as attributes).
#'
#' @details
#' The pipe form \code{replacement_level(projections, config) |> pvm()} is the
#' primary usage pattern.
#'
#' @param replacement A \code{replacement_level} output object produced by
#'   \code{\link{replacement_level}}. Must carry non-NULL
#'   \code{attr(., "projections")} and \code{attr(., "config")} attributes
#'   and \code{attr(., "stat_units") == "raw_projected"}.
#'   Objects from \code{\link{replacement_from_prices}} carry
#'   \code{NULL} \code{projections} and are not compatible.
#' @param include_raw Logical scalar. Default \code{FALSE}. When \code{TRUE},
#'   include \code{contrib_[CAT]} columns (raw above-replacement contributions)
#'   in the output.
#' @param cat_pct One of \code{"auto"} (default), \code{"equal"}, or a named
#'   numeric vector. Controls the per-category weight in \code{total_pvm}.
#'   \code{"auto"} derives weights from \code{config$budget_split}:
#'   hitter categories receive equal shares of \code{budget_split}; pitcher
#'   categories receive equal shares of \code{1 - budget_split}.
#'   \code{"equal"} divides weight equally across all scored categories.
#'   A named numeric vector is used directly; names must cover all scored
#'   categories and values must sum to 1.0 within 1e-10.
#' @param rate_pool Character scalar. One of \code{"ip_weighted"} (default),
#'   \code{"pool_average"}, or \code{"fixed_baseline"}. Controls how
#'   rate-stat (ERA, WHIP, AVG) pool denominators are computed.
#' @param sub_replacement One of \code{"clip"} (default) or
#'   \code{"negative"}. Under \code{"clip"}, sub-replacement contributions
#'   are floored at 0; under \code{"negative"}, they are retained as
#'   negative values.
#' @param baseline Named numeric vector or \code{NULL} (default). Required
#'   (non-NULL) when \code{rate_pool = "fixed_baseline"}; ignored (no-op)
#'   otherwise. Names must be scored rate-stat category names; values are
#'   the fixed baseline statistics (e.g., \code{c(ERA = 4.20, WHIP = 1.30,
#'   AVG = 0.265)}).
#'
#' @return A plain \code{data.frame} with one row per rostered player (row
#'   order matches \code{attr(replacement, "projections")} restricted to
#'   rostered players):
#'   \describe{
#'     \item{\code{contrib_[CAT]}}{(only when \code{include_raw = TRUE}) Raw
#'       above-replacement contribution per category; one column per scored
#'       category.}
#'     \item{\code{pvm_[CAT]}}{Proportional pool share per category; named
#'       \code{pvm_<CAT>} (uppercase). Under \code{sub_replacement = "clip"},
#'       values are in \code{[0, 1]} and sum to 1.0 per category. Under
#'       \code{"negative"}, positive values sum to 1.0 and sub-replacement
#'       players have strictly negative shares.}
#'     \item{\code{total_pvm}}{CAT%-weighted sum of pvm columns.}
#'   }
#'   Attributes: \code{attr(result, "units") == "budget_fraction"} and
#'   \code{attr(result, "anchor") == "replacement"}.
#'
#' @section Warnings:
#'
#' \subsection{rotostats_warning_pvm_sum}{
#'   Fires when the sum invariant deviates from 1.0 by more than 1e-10 for
#'   any scored category. Under \code{"clip"} the total-sum check is used;
#'   under \code{"negative"} only positive-contributing shares are summed.
#' }
#'
#' \subsection{rotostats_warning_pvm_concentration}{
#'   Fires when any single player exceeds a 0.25 share in any scored category.
#' }
#'
#' @seealso
#' \code{\link{replacement_level}} for producing the \code{replacement} input;
#' \code{\link{par}} for the SGP-units analog;
#' \code{\link{zar}} for the z-score analog.
#'
#' @family valuation
#'
#' @examples
#' \dontrun{
#' cfg  <- league_config(
#'   n_teams = 12L,
#'   roster_slots = c(C = 1, "1B" = 1, "2B" = 1, "3B" = 1, SS = 1, OF = 3),
#'   pitcher_slots = c(SP = 5L, RP = 4L),
#'   budget = 260L,
#'   budget_split = 0.60,
#'   categories = c("HR", "R", "RBI", "SB", "AVG", "W", "K", "SV", "ERA", "WHIP")
#' )
#' repl   <- replacement_level(projections, cfg)
#' result <- pvm(repl)
#' result <- replacement_level(projections, cfg) |> pvm()
#' }
#'
#' @importFrom stats setNames
#' @export
pvm <- function(
  replacement,
  include_raw = FALSE,
  cat_pct = "auto",
  rate_pool = "ip_weighted",
  sub_replacement = "clip",
  baseline = NULL
) {
  # ---------------------------------------------------------------------------
  # Step V1 — Validate replacement attributes (MUST be first)
  # ---------------------------------------------------------------------------
  projections <- attr(replacement, "projections")
  config      <- attr(replacement, "config")

  if (is.null(projections) || is.null(config)) {
    cli::cli_abort(
      c(
        "The {.arg replacement} object is missing required attributes.",
        "i" = "{.arg replacement} must be produced by {.fn replacement_level}.",
        "i" = paste0(
          "Objects from {.fn replacement_from_prices} are not compatible with ",
          "{.fn pvm} because they carry a NULL {.code projections} attribute."
        )
      ),
      class = "rotostats_error_missing_replacement_attrs",
      call  = rlang::caller_env()
    )
  }

  # ---------------------------------------------------------------------------
  # Step V2 — Validate stat_units attribute
  # ---------------------------------------------------------------------------
  stat_units <- attr(replacement, "stat_units")

  if (!identical(stat_units, "raw_projected")) {
    cli::cli_abort(
      c(
        "{.arg replacement} has {.code stat_units = {.val {stat_units}}}, but
         {.fn pvm} requires {.val raw_projected}.",
        "i" = "Ensure {.fn replacement_level} was called with raw projections."
      ),
      class = "rotostats_error_stat_units_mismatch",
      call  = rlang::caller_env()
    )
  }

  # ---------------------------------------------------------------------------
  # Step V3 — multi_pos = "all" guard
  # ---------------------------------------------------------------------------
  if (identical(replacement$params$multi_pos, "all")) {
    cli::cli_abort(
      c(
        "{.fn pvm} does not support {.code multi_pos = \"all\"} replacement objects.",
        "i" = paste0(
          "Re-run {.fn replacement_level} with {.code multi_pos = \"best\"} (or ",
          "{.val highest_par}, {.val primary}, or {.val custom})."
        )
      ),
      class = "rotostats_error_multi_pos_all_unsupported",
      call  = rlang::caller_env()
    )
  }

  # ---------------------------------------------------------------------------
  # Step V4 — Validate parameter types and values
  # ---------------------------------------------------------------------------

  # include_raw
  tryCatch(
    checkmate::assert_flag(include_raw),
    error = function(e) {
      cli::cli_abort(
        c(
          "{.arg include_raw} must be a logical scalar ({.code TRUE} or {.code FALSE}).",
          "i" = "You supplied: {.cls {class(include_raw)}}"
        ),
        class = "rotostats_error_invalid_parameter",
        call  = rlang::caller_env()
      )
    }
  )

  # rate_pool
  valid_rate_pool <- c("ip_weighted", "pool_average", "fixed_baseline")
  if (
    !is.character(rate_pool) ||
      length(rate_pool) != 1L ||
      is.na(rate_pool) ||
      !(rate_pool %in% valid_rate_pool)
  ) {
    cli::cli_abort(
      c(
        "{.arg rate_pool} must be one of {.val {valid_rate_pool}}.",
        "i" = "You supplied: {.val {rate_pool}}"
      ),
      class = "rotostats_error_invalid_parameter",
      call  = rlang::caller_env()
    )
  }

  # sub_replacement
  valid_sub_replacement <- c("clip", "negative")
  if (
    !is.character(sub_replacement) ||
      length(sub_replacement) != 1L ||
      is.na(sub_replacement) ||
      !(sub_replacement %in% valid_sub_replacement)
  ) {
    cli::cli_abort(
      c(
        "{.arg sub_replacement} must be one of {.val {valid_sub_replacement}}.",
        "i" = "You supplied: {.val {sub_replacement}}"
      ),
      class = "rotostats_error_invalid_parameter",
      call  = rlang::caller_env()
    )
  }

  # baseline
  if (!is.null(baseline)) {
    if (!is.numeric(baseline) || is.null(names(baseline))) {
      cli::cli_abort(
        c(
          "{.arg baseline} must be a named numeric vector or {.code NULL}.",
          "i" = "You supplied: {.cls {class(baseline)}}"
        ),
        class = "rotostats_error_invalid_parameter",
        call  = rlang::caller_env()
      )
    }
  }

  # ---------------------------------------------------------------------------
  # Step 1 — Extract inputs from replacement object
  # ---------------------------------------------------------------------------
  repl_stats  <- replacement$replacement_stats
  scored_cats <- toupper(config$categories)

  # Identify rate stats from the RATE_STAT_FORMULAS registry
  rate_stat_registry <- RATE_STAT_FORMULAS
  rate_stat_names    <- toupper(names(rate_stat_registry))
  scored_rate_cats   <- intersect(scored_cats, rate_stat_names)

  # Validate baseline names against scored categories
  if (!is.null(baseline)) {
    bl_names_upper <- toupper(names(baseline))
    names(baseline) <- bl_names_upper
    bad_bl_names <- setdiff(bl_names_upper, scored_cats)
    if (length(bad_bl_names) > 0L) {
      cli::cli_abort(
        c(
          "{.arg baseline} contains name{?s} not in scored categories: {.val {bad_bl_names}}.",
          "i" = "Scored categories are: {.val {scored_cats}}"
        ),
        class = "rotostats_error_category_mismatch",
        call  = rlang::caller_env()
      )
    }
  }

  # Volume columns
  ip_cats <- character(0L)
  ab_cats <- character(0L)
  for (cat in scored_rate_cats) {
    entry <- rate_stat_registry[[cat]]
    if (!is.null(entry)) {
      if (identical(entry$denominator_col, "IP")) {
        ip_cats <- c(ip_cats, cat)
      } else if (identical(entry$denominator_col, "AB")) {
        ab_cats <- c(ab_cats, cat)
      }
    }
  }

  # Inverse categories: lower-is-better (ERA, WHIP, etc.)
  if (!is.null(config$inverse_categories) && length(config$inverse_categories) > 0L) {
    inverse_cats <- intersect(toupper(config$inverse_categories), scored_cats)
  } else {
    inverse_cats <- intersect(inverse_categories(), scored_cats)
  }

  # ---------------------------------------------------------------------------
  # Step 2 — Validate fixed_baseline completeness
  # ---------------------------------------------------------------------------
  if (identical(rate_pool, "fixed_baseline")) {
    if (length(scored_rate_cats) > 0L) {
      missing_rate_cats <- character(0L)
      for (cat in scored_rate_cats) {
        if (is.null(baseline) || !(cat %in% toupper(names(baseline)))) {
          missing_rate_cats <- c(missing_rate_cats, cat)
        }
      }
      if (length(missing_rate_cats) > 0L) {
        cli::cli_abort(
          c(
            "{.fn pvm} with {.code rate_pool = \"fixed_baseline\"} requires explicit
             {.arg baseline} constants for all scored rate stats.",
            "i" = "Missing baseline for: {.val {missing_rate_cats}}",
            "i" = paste0(
              "Supply a named numeric vector via {.arg baseline}, e.g. ",
              "{.code baseline = c(ERA = 4.20, WHIP = 1.30, AVG = 0.265)}."
            )
          ),
          class = "rotostats_error_missing_config_field",
          call  = rlang::caller_env()
        )
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Step 3 — Validate and resolve cat_pct
  # ---------------------------------------------------------------------------
  if (is.character(cat_pct) && length(cat_pct) == 1L && !is.na(cat_pct)) {
    if (cat_pct == "auto") {
      hitter_cats  <- scored_cats[!(scored_cats %in% PVM_PITCHER_CATEGORIES)]
      pitcher_cats <- scored_cats[scored_cats %in% PVM_PITCHER_CATEGORIES]
      bsplit       <- config$budget_split
      if (is.null(bsplit) || !is.numeric(bsplit) || length(bsplit) != 1L) {
        bsplit <- 0.60
      }
      cat_weights <- c(
        if (length(hitter_cats) > 0L) {
          stats::setNames(
            rep(bsplit / length(hitter_cats), length(hitter_cats)),
            hitter_cats
          )
        } else {
          numeric(0L)
        },
        if (length(pitcher_cats) > 0L) {
          stats::setNames(
            rep((1 - bsplit) / length(pitcher_cats), length(pitcher_cats)),
            pitcher_cats
          )
        } else {
          numeric(0L)
        }
      )
    } else if (cat_pct == "equal") {
      cat_weights <- stats::setNames(
        rep(1.0 / length(scored_cats), length(scored_cats)),
        scored_cats
      )
    } else {
      cli::cli_abort(
        c(
          "{.arg cat_pct} must be {.val auto}, {.val equal}, or a named numeric vector.",
          "i" = "You supplied the string {.val {cat_pct}}."
        ),
        class = "rotostats_error_invalid_parameter",
        call  = rlang::caller_env()
      )
    }
  } else if (is.numeric(cat_pct) && !is.null(names(cat_pct))) {
    # Named numeric vector path
    cat_pct_names_upper <- toupper(names(cat_pct))
    names(cat_pct) <- cat_pct_names_upper
    # Names coverage check (fires before sum check)
    missing_cats <- setdiff(scored_cats, cat_pct_names_upper)
    if (length(missing_cats) > 0L) {
      cli::cli_abort(
        c(
          "{.arg cat_pct} is missing name{?s} for scored categor{?y/ies}: {.val {missing_cats}}.",
          "i" = "All scored categories must be present in {.arg cat_pct}."
        ),
        class = "rotostats_error_category_mismatch",
        call  = rlang::caller_env()
      )
    }
    # Sum check
    cat_pct_sum <- sum(cat_pct[scored_cats])
    if (abs(cat_pct_sum - 1.0) >= 1e-10) {
      cli::cli_abort(
        c(
          "{.arg cat_pct} values sum to {.val {cat_pct_sum}}, not 1.0.",
          "i" = "Deviation from 1.0: {.val {abs(cat_pct_sum - 1.0)}}",
          "i" = "Rescale {.arg cat_pct} so values sum to 1.0."
        ),
        class = "rotostats_error_cat_pct_sum",
        call  = rlang::caller_env()
      )
    }
    cat_weights <- cat_pct[scored_cats]
  } else {
    cli::cli_abort(
      c(
        "{.arg cat_pct} must be {.val auto}, {.val equal}, or a named numeric vector.",
        "i" = "You supplied: {.cls {class(cat_pct)}}"
      ),
      class = "rotostats_error_invalid_parameter",
      call  = rlang::caller_env()
    )
  }

  # ---------------------------------------------------------------------------
  # Step 1 (continued) — Identify rostered players
  # ---------------------------------------------------------------------------
  position_assignments <- attr(replacement, "position_assignments")

  # Normalize position_assignments to a named character vector
  if (is.data.frame(position_assignments)) {
    pa_vec <- stats::setNames(
      as.character(position_assignments$pool_label),
      as.character(position_assignments$player_id)
    )
  } else {
    pa_vec <- stats::setNames(
      as.character(position_assignments),
      names(position_assignments)
    )
  }

  # Rostered players: those with non-NA position assignment
  player_ids       <- as.character(projections$PLAYER_ID)
  player_positions <- pa_vec[player_ids]
  rostered_mask    <- !is.na(player_positions)
  rostered_proj    <- projections[rostered_mask, , drop = FALSE]
  n_rostered       <- nrow(rostered_proj)

  # ---------------------------------------------------------------------------
  # Compute position-weighted replacement stat line RS[c]
  # ---------------------------------------------------------------------------
  # repl_stats has columns: position, [cats...], IP, AB (optionally)
  # Weight each position by its roster slots

  hitter_pos_names  <- intersect(names(config$roster_slots), PRIMARY_HITTER_SLOTS)
  pitcher_pos_names <- if (!is.null(names(config$pitcher_slots))) {
    names(config$pitcher_slots)
  } else {
    c("SP", "RP")
  }

  RS <- stats::setNames(numeric(length(scored_cats)), scored_cats)
  for (cat in scored_cats) {
    if (!(cat %in% names(repl_stats))) {
      RS[cat] <- NA_real_
      next
    }

    # Determine if this is a hitter or pitcher category to pick slot weights
    is_pitcher_cat <- cat %in% PVM_PITCHER_CATEGORIES
    if (is_pitcher_cat) {
      relevant_pos <- intersect(repl_stats$position, pitcher_pos_names)
      slot_weights <- vapply(relevant_pos, function(p) {
        s <- config$pitcher_slots
        if (!is.null(names(s)) && p %in% names(s)) {
          as.numeric(s[[p]])
        } else {
          # scalar pitcher_slots: split evenly
          as.numeric(sum(s)) / max(length(relevant_pos), 1L)
        }
      }, numeric(1L))
    } else {
      relevant_pos <- intersect(repl_stats$position, hitter_pos_names)
      slot_weights <- vapply(relevant_pos, function(p) {
        as.numeric(config$roster_slots[[p]])
      }, numeric(1L))
    }

    if (length(relevant_pos) == 0L) {
      # Fall back to simple mean across all positions
      RS[cat] <- mean(repl_stats[[cat]], na.rm = TRUE)
    } else {
      repl_rows   <- repl_stats[repl_stats$position %in% relevant_pos, , drop = FALSE]
      # Align slot_weights to repl_rows order
      sw <- slot_weights[match(repl_rows$position, relevant_pos)]
      total_slots <- sum(sw, na.rm = TRUE)
      if (total_slots == 0) {
        RS[cat] <- mean(repl_rows[[cat]], na.rm = TRUE)
      } else {
        RS[cat] <- sum(repl_rows[[cat]] * sw, na.rm = TRUE) / total_slots
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Step 4 — Compute above-replacement contributions (vectorized)
  # ---------------------------------------------------------------------------
  # raw_contrib[i, c]: sign-flipped for inverse cats
  raw_contrib <- matrix(NA_real_, nrow = n_rostered, ncol = length(scored_cats))
  colnames(raw_contrib) <- scored_cats

  for (cat in scored_cats) {
    player_stat <- rostered_proj[[cat]]
    if (is.null(player_stat)) player_stat <- rep(NA_real_, n_rostered)
    if (cat %in% inverse_cats) {
      # ERA, WHIP: lower is better → RS[c] - PS[i,c]
      raw_contrib[, cat] <- RS[cat] - player_stat
    } else {
      # Counting + AVG + OPS: higher is better → PS[i,c] - RS[c]
      raw_contrib[, cat] <- player_stat - RS[cat]
    }
  }

  # Apply sub_replacement handling
  if (sub_replacement == "clip") {
    contrib <- pmax(raw_contrib, 0)
  } else {
    contrib <- raw_contrib
  }

  # ---------------------------------------------------------------------------
  # Step 5 — Compute volume vectors
  # ---------------------------------------------------------------------------
  rostered_IP <- rostered_proj[["IP"]]
  rostered_AB <- rostered_proj[["AB"]]

  if (is.null(rostered_IP)) rostered_IP <- rep(NA_real_, n_rostered)
  if (is.null(rostered_AB)) rostered_AB <- rep(NA_real_, n_rostered)

  # Compute mean volume over positive-IP / positive-AB players
  ip_pos  <- rostered_IP > 0 & !is.na(rostered_IP)
  ab_pos  <- rostered_AB > 0 & !is.na(rostered_AB)
  mean_IP <- if (any(ip_pos)) mean(rostered_IP[ip_pos]) else NA_real_
  mean_AB <- if (any(ab_pos)) mean(rostered_AB[ab_pos]) else NA_real_

  # Per spec §6 stability note: if mean is 0 or NaN, treat volume weight as 1
  if (is.na(mean_IP) || mean_IP == 0) mean_IP <- 1.0
  if (is.na(mean_AB) || mean_AB == 0) mean_AB <- 1.0

  # Volume weight vectors
  w_IP        <- rostered_IP / mean_IP
  w_AB        <- rostered_AB / mean_AB
  w_IP[is.na(w_IP)] <- 0
  w_AB[is.na(w_AB)] <- 0

  # ---------------------------------------------------------------------------
  # Step 5 (continued) — Compute Pool[c] and volume-weighted contrib
  # ---------------------------------------------------------------------------

  # contrib_vol: volume-adjusted contribution (for ip_weighted numerator)
  contrib_vol <- matrix(NA_real_, nrow = n_rostered, ncol = length(scored_cats))
  colnames(contrib_vol) <- scored_cats

  # extras matrices for pool_average and fixed_baseline
  extras <- matrix(NA_real_, nrow = n_rostered, ncol = length(scored_cats))
  colnames(extras) <- scored_cats

  Pool <- stats::setNames(numeric(length(scored_cats)), scored_cats)

  if (identical(rate_pool, "ip_weighted")) {
    # ------- Option A: ip_weighted -------
    for (cat in scored_cats) {
      if (cat %in% ip_cats) {
        contrib_vol[, cat] <- contrib[, cat] * w_IP
      } else if (cat %in% ab_cats) {
        contrib_vol[, cat] <- contrib[, cat] * w_AB
      } else {
        contrib_vol[, cat] <- contrib[, cat]
      }
    }

    # Pool[c] depends on sub_replacement mode
    if (sub_replacement == "clip") {
      Pool <- colSums(contrib_vol, na.rm = TRUE)
    } else {
      # "negative": only positive-contrib players enter Pool denominator
      pos_contrib_mat <- contrib_vol * (contrib[, scored_cats, drop = FALSE] > 0)
      Pool <- colSums(pos_contrib_mat, na.rm = TRUE)
    }
  } else if (identical(rate_pool, "pool_average")) {
    # ------- Option B: pool_average -------
    for (cat in scored_cats) {
      if (cat %in% ip_cats) {
        pos_mask <- contrib[, cat] > 0 & ip_pos
        if (any(pos_mask, na.rm = TRUE)) {
          mean_pool_stat <- mean(rostered_proj[[cat]][pos_mask], na.rm = TRUE)
        } else {
          mean_pool_stat <- RS[cat]  # fallback
        }
        # ERA extras: IP * (mean_pool_ERA - player_ERA) / 9 for ERA
        # WHIP extras: IP * (mean_pool_WHIP - player_WHIP)
        entry <- rate_stat_registry[[cat]]
        if (!is.null(entry) && entry$scale != 1) {
          # scale == 9: ERA
          ex <- rostered_IP * (mean_pool_stat - rostered_proj[[cat]]) / entry$scale
        } else {
          # scale == 1: WHIP
          ex <- rostered_IP * (mean_pool_stat - rostered_proj[[cat]])
        }
        ex[is.na(ex)] <- 0
        extras[, cat] <- ex
        Pool[cat] <- sum(ex[contrib[, cat] > 0], na.rm = TRUE)
        contrib_vol[, cat] <- extras[, cat]
      } else if (cat %in% ab_cats) {
        pos_mask <- contrib[, cat] > 0 & ab_pos
        if (any(pos_mask, na.rm = TRUE)) {
          mean_pool_stat <- mean(rostered_proj[[cat]][pos_mask], na.rm = TRUE)
        } else {
          mean_pool_stat <- RS[cat]
        }
        ex <- rostered_AB * (rostered_proj[[cat]] - mean_pool_stat)
        ex[is.na(ex)] <- 0
        extras[, cat] <- ex
        Pool[cat] <- sum(ex[contrib[, cat] > 0], na.rm = TRUE)
        contrib_vol[, cat] <- extras[, cat]
      } else {
        # Counting stats: same as ip_weighted
        contrib_vol[, cat] <- contrib[, cat]
        if (sub_replacement == "clip") {
          Pool[cat] <- sum(contrib[, cat], na.rm = TRUE)
        } else {
          Pool[cat] <- sum(contrib[contrib[, cat] > 0, cat], na.rm = TRUE)
        }
      }
    }
  } else {
    # ------- Option C: fixed_baseline -------
    for (cat in scored_cats) {
      if (cat %in% ip_cats) {
        bl_cat <- baseline[[cat]]
        entry  <- rate_stat_registry[[cat]]
        if (!is.null(entry) && entry$scale != 1) {
          ex <- rostered_IP * (bl_cat - rostered_proj[[cat]]) / entry$scale
        } else {
          ex <- rostered_IP * (bl_cat - rostered_proj[[cat]])
        }
        ex[is.na(ex)] <- 0
        extras[, cat]    <- ex
        contrib_vol[, cat] <- extras[, cat]
        Pool[cat] <- sum(ex[contrib[, cat] > 0], na.rm = TRUE)
      } else if (cat %in% ab_cats) {
        bl_cat <- baseline[[cat]]
        ex <- rostered_AB * (rostered_proj[[cat]] - bl_cat)
        ex[is.na(ex)] <- 0
        extras[, cat]    <- ex
        contrib_vol[, cat] <- extras[, cat]
        Pool[cat] <- sum(ex[contrib[, cat] > 0], na.rm = TRUE)
      } else {
        contrib_vol[, cat] <- contrib[, cat]
        if (sub_replacement == "clip") {
          Pool[cat] <- sum(contrib[, cat], na.rm = TRUE)
        } else {
          Pool[cat] <- sum(contrib[contrib[, cat] > 0, cat], na.rm = TRUE)
        }
      }
    }
  }

  # Zero-pool check — must fire before division
  zero_cats <- scored_cats[!is.finite(Pool) | Pool <= 0]
  if (length(zero_cats) > 0L) {
    cli::cli_abort(
      c(
        "Pool size is zero for categor{?y/ies} {.val {zero_cats}}.",
        "i" = "All rostered players are sub-replacement in these categories.",
        "i" = "Widen the player pool, lower replacement level, or check projections."
      ),
      class = "rotostats_error_zero_pool",
      call  = rlang::caller_env()
    )
  }

  # ---------------------------------------------------------------------------
  # Step 6 — Compute per-player proportional shares pvm[i, c] (vectorized)
  # ---------------------------------------------------------------------------
  # For all rate_pool options, the numerator is contrib_vol (which equals
  # contrib for counting stats, and volume-weighted contrib / extras for
  # rate stats). Denominator is Pool[c].
  pvm_mat <- matrix(NA_real_, nrow = n_rostered, ncol = length(scored_cats))
  colnames(pvm_mat) <- scored_cats

  for (cat in scored_cats) {
    pvm_mat[, cat] <- contrib_vol[, cat] / Pool[cat]
  }

  # ---------------------------------------------------------------------------
  # Step 7 — Sum invariant check (mode-aware warning)
  # ---------------------------------------------------------------------------
  if (sub_replacement == "clip") {
    pvm_sum <- colSums(pvm_mat, na.rm = TRUE)
    dev     <- abs(pvm_sum - 1.0)
  } else {
    pos_pvm <- pvm_mat * (pvm_mat > 0)
    pvm_sum <- colSums(pos_pvm, na.rm = TRUE)
    dev     <- abs(pvm_sum - 1.0)
  }

  if (any(dev > 1e-10)) {
    bad_cats <- scored_cats[dev > 1e-10]
    cli::cli_warn(
      c(
        "PVM sum invariant violated for categor{?y/ies}: {.val {bad_cats}}.",
        "i" = "Maximum deviation from 1.0: {.val {max(dev[dev > 1e-10])}}",
        "i" = "Check inputs for floating-point accumulation errors."
      ),
      class = "rotostats_warning_pvm_sum"
    )
  }

  # ---------------------------------------------------------------------------
  # Step 8 — Concentration warning
  # ---------------------------------------------------------------------------
  high_mask <- pvm_mat > 0.25
  if (any(high_mask, na.rm = TRUE)) {
    cli::cli_warn(
      c(
        "{.fn pvm}: {sum(high_mask, na.rm = TRUE)} player-category share{?s} exceed 0.25.",
        "i" = "Maximum share: {.val {max(pvm_mat, na.rm = TRUE)}}",
        "i" = "Review category concentration; consider rebalancing the projection pool."
      ),
      class = "rotostats_warning_pvm_concentration"
    )
  }

  # ---------------------------------------------------------------------------
  # Step 9 — Compute total_pvm (vectorized matrix multiply)
  # ---------------------------------------------------------------------------
  cw_vec      <- as.numeric(cat_weights[scored_cats])
  total_pvm_vec <- as.numeric(
    pvm_mat[, scored_cats, drop = FALSE] %*% cw_vec
  )

  # ---------------------------------------------------------------------------
  # Step 10 — Assemble output data frame
  # ---------------------------------------------------------------------------
  # pvm columns: named pvm_<CAT>
  pvm_cols <- as.data.frame(
    pvm_mat,
    row.names = seq_len(n_rostered)
  )
  names(pvm_cols) <- paste0("pvm_", scored_cats)
  pvm_cols$total_pvm <- total_pvm_vec

  if (include_raw) {
    contrib_df <- as.data.frame(
      contrib[, scored_cats, drop = FALSE],
      row.names = seq_len(n_rostered)
    )
    names(contrib_df) <- paste0("contrib_", scored_cats)
    result <- cbind(contrib_df, pvm_cols)
  } else {
    result <- pvm_cols
  }

  # Preserve row identity from rostered projection rows
  rownames(result) <- rownames(rostered_proj)

  # ---------------------------------------------------------------------------
  # Step 11 — Attach output attributes
  # ---------------------------------------------------------------------------
  attr(result, "units")  <- "budget_fraction"
  attr(result, "anchor") <- "replacement"

  result
}
