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
#' ## Rate categories — blended-pool method
#'
#' With `rate_conversion = "blended_pool"` and
#' `pool_baseline = "projection_pool"` (the defaults), rate-stat SGP is
#' computed via the *blended-pool* marginal-contribution formula. Supported
#' linear rate stats are defined by the formula registry exposed via
#' [rate_stat_formulas()]: ERA, WHIP, AVG, FIP, xFIP, SIERA, xERA, K/9,
#' BB/9, and HR/9 are built in, and users can supply a custom registry via
#' the `rate_stat_formulas` argument (see below).
#'
#' Pool constants are derived once from the top-`pool_size_p` pitchers (for
#' entries with `pool_type = "pitcher"`) or top-`pool_size_b` batters (for
#' entries with `pool_type = "batter"`) by the registry's `denominator_col`.
#' Pool sizes come from `pool_sizes(league_config)` and therefore reflect
#' the league's roster structure.
#'
#' For each scored rate stat c with registry entry f the per-player formula
#' is:
#'
#' \preformatted{
#'   player_num = f$numerator_fn(projections[[c]], projections[[f$denominator_col]])
#'   pool_num   = sum( f$numerator_fn(pool[[c]], pool[[f$denominator_col]]) )
#'   pool_denom = sum( pool[[f$denominator_col]] )
#'   blended    = (pool_num + player_num) * f$scale / (pool_denom + player_denom)
#'   SGP[i, c]  = ( baseline_c - blended ) / denominators[c]    if f$direction == "inverse"
#'             or ( blended - baseline_c ) / denominators[c]    if f$direction == "standard"
#' }
#'
#' `baseline_c` is the weighted mean of `league_history$team_season[[c]]`
#' using `team_season[[f$denominator_col]]` as weights, computed from the
#' most recent non-excluded year. A `cli_inform()` message names the year
#' used. The direction flag encodes whether higher or lower rate values
#' help the team (ERA / WHIP / FIP / xFIP / SIERA / xERA / BB/9 / HR/9 are
#' `"inverse"`; AVG and K/9 are `"standard"`).
#'
#' ## Column names for slash-containing categories
#'
#' Rate stats whose category name contains a forward slash (`K/9`, `BB/9`,
#' `HR/9`) would produce invalid R column names under the standard
#' `sgp_<CAT>` convention. `sgp()` substitutes `/` with `_per_` and
#' lowercases the result, yielding `sgp_k_per_9`, `sgp_bb_per_9`, and
#' `sgp_hr_per_9`. Non-slash categories preserve the uppercase convention
#' (`sgp_HR`, `sgp_ERA`).
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
#' 1. \code{pool_baseline} must be \code{"projection_pool"} (else
#'    \code{rotostats_error_invalid_pool_baseline}). This check fires before
#'    any other validation, regardless of \code{rate_conversion}.
#' 2. \code{rate_conversion} must be one of the five recognized values (else
#'    \code{rotostats_error_invalid_rate_conversion}).
#' 3. When \code{rate_conversion = "blended_pool"}, \code{attr(denominators,
#'    "rate_conversion")} must also be \code{"blended_pool"} — mismatched units
#'    abort with \code{rotostats_error_invalid_rate_conversion}.
#' 4. \code{"per_player"}, \code{"universal_constants"},
#'    \code{"team_ip_normalized"} abort with
#'    \code{rotostats_error_not_implemented}.
#' 5. \code{"fixed_baseline"} delegates to \code{convert_rate_stats()} (stub;
#'    also aborts with \code{rotostats_error_not_implemented}).
#' 6. Required inputs (\code{league_history}, \code{league_config}) are
#'    validated only after the method is confirmed.
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
#' @param pool_baseline Character scalar. Determines how pool constants are
#'   constructed for the blended-pool rate-stat formulas. Currently only
#'   \code{"projection_pool"} (the default) is implemented; any other value
#'   aborts with \code{rotostats_error_invalid_pool_baseline}. The other
#'   documented values (\code{"per_player"}, \code{"universal_constants"}) are
#'   not yet implemented.
#' @param league_config A `league_config` S3 object from [league_config()].
#'   Required when `rate_conversion = "blended_pool"` and
#'   `pool_baseline = "projection_pool"`.  Passed to `pool_sizes()` (an
#'   internal helper in `R/league-config.R`) to derive `pool_size_p` and
#'   `pool_size_b` from the league's roster structure rather than hard-coding
#'   roster depth.
#' @param baseline_era Numeric scalar or `NULL`.  Explicit ERA baseline used
#'   only when `rate_conversion = "fixed_baseline"`.  Passed through to
#'   [convert_rate_stats()]; ignored for `"blended_pool"`.
#' @param baseline_whip Numeric scalar or `NULL`.  Explicit WHIP baseline.
#'   See `baseline_era`.
#' @param baseline_avg Numeric scalar or `NULL`.  Explicit AVG baseline.
#'   See `baseline_era`.
#' @param rate_stat_formulas A named list of blended-pool formula descriptors
#'   in the shape returned by [rate_stat_formulas()], or `NULL` (the default)
#'   to use the package registry. When supplied, the user list **fully
#'   replaces** the package default — every rate stat the league scores must
#'   have an entry. This is symmetric with [sgp_denominators()]'s
#'   `inverse_categories` argument. A scored rate stat with no matching
#'   registry entry aborts with `rotostats_error_unknown_rate_stat_formula`;
#'   a malformed override aborts with `rotostats_error_invalid_rate_stat_formula`.
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
#' \code{sgp()} may emit one or both of the following warnings via
#' \code{\link[cli]{cli_warn}}:
#'
#' \subsection{rotostats_warning_missing_category_column}{
#'   A scored category column is entirely absent from \code{projections} —
#'   the affected \code{sgp_<CAT>} column is filled with \code{NA} for all
#'   players. Emitted once per missing category (Step 8).
#' }
#'
#' \subsection{rotostats_warning_zero_playing_time}{
#'   A player has 0 or \code{NA} projected IP (when ERA or WHIP is scored) or
#'   projected AB (when AVG is scored) — that player's rate-stat SGP is set to
#'   \code{NA}. Emitted at Steps 14a, 14c, and 14d respectively. The message
#'   names the affected player(s).
#' }
#'
#' To suppress only one class, use
#' \code{withCallingHandlers(rotostats_warning_missing_category_column = ...)}
#' or \code{withCallingHandlers(rotostats_warning_zero_playing_time = ...)}
#' independently.
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
#'     year = c(2022L, 2022L, 2022L, 2023L, 2023L, 2023L),
#'     team_id = rep(c("A", "B", "C"), 2),
#'     HR = c(150, 180, 210, 155, 185, 215),
#'     R = c(650, 700, 740, 660, 710, 750),
#'     IP = c(1350, 1380, 1410, 1360, 1390, 1420),
#'     AB = c(5400, 5500, 5600, 5420, 5520, 5620),
#'     stringsAsFactors = FALSE
#'   )
#' )
#'
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
#'   pitcher_slots = 9L,
#'   budget = 260L,
#'   budget_split = 0.67,
#'   batting_categories = c("HR", "R"),
#'   pitcher_categories = character(0L)
#' )
#'
#' denoms <- sgp_denominators(
#'   history,
#'   scoring_categories = c("HR", "R"),
#'   exclude_years = integer(0)
#' )
#'
#' projections <- data.frame(
#'   HR = c(40L, 25L, 10L),
#'   R = c(90L, 80L, 70L),
#'   IP = c(0L, 0L, 0L), # pitching not scored — zeroes are fine
#'   AB = c(500L, 450L, 400L)
#' )
#'
#' \dontrun{
#'   # blended_pool requires league_history and league_config:
#'   result <- sgp(
#'     projections   = projections,
#'     denominators  = denoms,
#'     league_history = history,
#'     league_config  = config
#'   )
#'   result  # data frame: sgp_HR, sgp_R, total_sgp
#' }
#'
#' @importFrom utils head
#' @export
sgp <- function(
  projections,
  denominators,
  league_history = NULL,
  rate_conversion = "blended_pool",
  pool_baseline = "projection_pool",
  league_config = NULL,
  baseline_era = NULL,
  baseline_whip = NULL,
  baseline_avg = NULL,
  rate_stat_formulas = NULL
) {
  # -------------------------------------------------------------------------
  # Step 1 — Normalize projections column names to uppercase (silent)
  # -------------------------------------------------------------------------
  names(projections) <- toupper(names(projections))

  # -------------------------------------------------------------------------
  # Step 1b — Validate pool_baseline
  # -------------------------------------------------------------------------
  valid_pool_baselines <- "projection_pool"
  if (!pool_baseline %in% valid_pool_baselines) {
    cli::cli_abort(
      "{.arg pool_baseline} must be {.val projection_pool}, not {.val {pool_baseline}}. \\
       Other documented values ({.val per_player}, {.val universal_constants}) are not \\
       yet implemented.",
      class = "rotostats_error_invalid_pool_baseline"
    )
  }

  # -------------------------------------------------------------------------
  # Step 2 — Validate rate_conversion (value check)
  # -------------------------------------------------------------------------
  valid_rate_conversions <- c(
    "blended_pool",
    "fixed_baseline",
    "per_player",
    "universal_constants",
    "team_ip_normalized"
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
  if (
    rate_conversion %in%
      c("per_player", "universal_constants", "team_ip_normalized")
  ) {
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
      baseline_era = baseline_era,
      baseline_whip = baseline_whip,
      baseline_avg = baseline_avg,
      projections = projections,
      league_config = league_config
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
  scored_cats <- names(denominators) # dispatches names.sgp_denominators()

  # Resolve effective rate-stat formula registry. NULL = package default;
  # a user override fully replaces the registry (symmetric with
  # sgp_denominators()'s inverse_categories override).
  effective_registry <- if (is.null(rate_stat_formulas)) {
    RATE_STAT_FORMULAS
  } else {
    .validate_rate_stat_formulas(rate_stat_formulas)
  }

  # Per-category side: "pitcher" or "batter".
  # Rate stats: read pool_type from the registry entry.
  # Counting stats: fall back to .classify_category_side() (which returns
  # "batter"/"pitcher").
  .cat_side <- function(cat) {
    entry <- effective_registry[[cat]]
    if (!is.null(entry) && !is.null(entry$pool_type)) {
      return(entry$pool_type)
    }
    .classify_category_side(cat)
  }

  # Detect rate stats as those scored categories that have a registry entry.
  # (Counting stats are the complement.) Known non-linear rate stats (OPS,
  # wOBA, etc.) that aren't in the registry fall through to the counting
  # branch and divide by their denominator directly — not ideal, but
  # outside the scope of this plan; non-linear rate-stat support is a
  # separate follow-up.
  registry_names <- names(effective_registry)
  linear_rate_set <- c(
    "ERA",
    "WHIP",
    "AVG",
    "FIP",
    "XFIP",
    "SIERA",
    "XERA",
    "K/9",
    "BB/9",
    "HR/9"
  )
  rate_cats <- intersect(scored_cats, registry_names)
  count_cats <- setdiff(scored_cats, rate_cats)

  # A scored category that *looks* like a linear rate stat (appears in the
  # canonical list above) but is missing from the effective registry means
  # the user supplied an override that dropped it. Abort so they either
  # restore the entry or remove the category.
  scored_linear_like <- intersect(scored_cats, linear_rate_set)
  unknown_rate_stats <- setdiff(scored_linear_like, rate_cats)
  if (length(unknown_rate_stats) > 0L) {
    cli::cli_abort(
      c(
        "Scored rate stat(s) {.val {unknown_rate_stats}} have no entry in the effective {.arg rate_stat_formulas} registry.",
        "i" = "Add entries for the missing rate stat(s), drop them from {.code config$categories}, or pass {.arg rate_stat_formulas = NULL} to use the package default."
      ),
      class = "rotostats_error_unknown_rate_stat_formula"
    )
  }

  # -------------------------------------------------------------------------
  # Step 8 — Detect and warn about missing scored category columns
  # -------------------------------------------------------------------------
  missing_cats <- character(0L)
  for (cat in scored_cats) {
    f_check <- effective_registry[[cat]]
    # Multi-component entries (e.g., OPS) have no single source column.
    # Their component columns are checked later in .compute_multicomponent_sgp().
    if (!is.null(f_check) && !is.null(f_check$components)) next
    src_col_for_check <- .resolve_source_col(effective_registry, cat)
    if (!src_col_for_check %in% names(projections)) {
      col_name <- .sgp_col_name(cat)
      cli::cli_warn(
        paste0(
          "Scored category {.val {cat}} requires column {.val {src_col_for_check}} ",
          "in {.arg projections}; not found. ",
          "{.code ",
          col_name,
          "} will be {.code NA} for all players."
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
    hld_col <- if ("HLD" %in% names(projections)) {
      "HLD"
    } else if ("HD" %in% names(projections)) {
      "HD"
    } else {
      NULL
    }
    if ("SV" %in% names(projections) && !is.null(hld_col)) {
      projections$SVHD <- projections$SV + projections[[hld_col]]
      rlang::inform(
        paste0(
          "SVHD derived as SV + ",
          hld_col,
          ". ",
          "Verify that this definition matches your league's hold rules."
        ),
        .frequency = "once",
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

  # Validate ts has each scored rate stat's rate column and denominator column.
  # Rate stats in missing_cats are skipped — their SGP columns are NA-filled.
  # Multi-component entries (e.g., OPS) derive their baselines from the
  # projection pool rather than league_history, so they are skipped here.
  for (cat in setdiff(rate_cats, missing_cats)) {
    f <- effective_registry[[cat]]
    if (!is.null(f$components)) next
    src_col <- .resolve_source_col(effective_registry, cat)
    needed_in_ts <- c(src_col, f$denominator_col)
    ts_missing <- setdiff(needed_in_ts, names(ts))
    if (length(ts_missing) > 0L) {
      cli::cli_abort(
        "{.code league_history$team_season} must contain {.val {needed_in_ts}} columns to derive the {.val {cat}} rate-stat baseline.",
        class = "rotostats_error_missing_required_column"
      )
    }
  }

  # 10a. Identify baseline_year (most recent non-excluded year — spec uses max)
  baseline_year <- max(ts$YEAR)

  cli::cli_inform(
    "Using {.val {baseline_year}} as the baseline year for rate-stat pool averages."
  )

  # 10b. Filter ts to baseline_year
  ts_base <- ts[ts$YEAR == baseline_year, , drop = FALSE]

  # 10c. Compute weighted means for each scored rate stat.
  # Multi-component entries (e.g., OPS) are skipped here; their component
  # baselines are derived from the projection pool in Step 11.
  baselines <- list()
  for (cat in setdiff(rate_cats, missing_cats)) {
    f <- effective_registry[[cat]]
    if (!is.null(f$components)) next
    src_col <- .resolve_source_col(effective_registry, cat)
    baselines[[cat]] <- stats::weighted.mean(
      ts_base[[src_col]],
      ts_base[[f$denominator_col]]
    )
  }

  # -------------------------------------------------------------------------
  # Step 11 — Build pool constants (blended_pool + projection_pool)
  # -------------------------------------------------------------------------

  # 11a. Get pool sizes
  ps <- pool_sizes(league_config)
  pool_size_p <- ps$pitchers
  pool_size_b <- ps$batters

  # Validate that each scored rate stat's denominator column is present in
  # projections. Skipped for rate stats whose rate column is entirely absent
  # (already handled via Step 8's missing_cats NA-fill).
  # Multi-component entries (e.g., OPS) have no single denominator_col;
  # their component columns are validated in .compute_multicomponent_sgp().
  for (cat in setdiff(rate_cats, missing_cats)) {
    f <- effective_registry[[cat]]
    if (!is.null(f$components)) next
    if (!f$denominator_col %in% names(projections)) {
      cli::cli_abort(
        "{.arg projections} must contain a {.val {f$denominator_col}} column when {.val {cat}} is a scored rate stat.",
        class = "rotostats_error_missing_rate_denominator_column"
      )
    }
  }

  # 11b. Build one pool per unique (pool_type, denominator_col) across the
  # scored rate stats, then compute the pool denominator sum and per-cat
  # pool numerator. Pools are keyed by denominator_col because in practice
  # pool_type is determined by denominator_col (IP=pitcher, AB/PA=batter).
  pool_meta <- list() # keyed by denominator_col; stores players df + denom total
  pool_num <- list() # keyed by rate-stat name; stores numerator total

  for (cat in setdiff(rate_cats, missing_cats)) {
    f <- effective_registry[[cat]]
    # Multi-component entries (e.g., OPS) are built separately below.
    if (!is.null(f$components)) next
    key <- f$denominator_col

    if (is.null(pool_meta[[key]])) {
      pool_size <- if (identical(f$pool_type, "pitcher")) {
        pool_size_p
      } else {
        pool_size_b
      }
      sort_rows <- order(projections[[key]], decreasing = TRUE)
      pool_df <- projections[head(sort_rows, pool_size), , drop = FALSE]
      denom_total <- sum(pool_df[[key]], na.rm = TRUE)
      pool_meta[[key]] <- list(players = pool_df, denom_total = denom_total)
    }

    players_df <- pool_meta[[key]]$players
    src_col <- .resolve_source_col(effective_registry, cat)
    # If the rate column is not in the pool df (shouldn't happen — caught
    # earlier by missing_cats and denominator validation — but be defensive),
    # treat numerator total as 0 so blended reduces to pool-only.
    if (src_col %in% names(players_df)) {
      pool_num[[cat]] <- sum(
        f$numerator_fn(players_df[[src_col]], players_df[[key]]),
        na.rm = TRUE
      )
    } else {
      pool_num[[cat]] <- 0
    }
  }

  # Build pool_meta and baselines for multi-component entry children.
  # Each child's baseline is pool_num / pool_denom (projection-pool average).
  # This runs after the single-component pool is built so that shared
  # denominator_cols (e.g., AB) are not double-initialised.
  for (cat in setdiff(rate_cats, missing_cats)) {
    f <- effective_registry[[cat]]
    if (is.null(f$components)) next
    pool_size <- if (identical(f$pool_type, "pitcher")) pool_size_p else pool_size_b
    for (child_name in names(f$components)) {
      child     <- f$components[[child_name]]
      denom_col <- child$denominator_col
      if (!(child_name %in% names(projections)) ||
          !(denom_col %in% names(projections))) next
      if (is.null(pool_meta[[denom_col]])) {
        sort_rows   <- order(projections[[denom_col]], decreasing = TRUE)
        pool_df     <- projections[head(sort_rows, pool_size), , drop = FALSE]
        denom_total <- sum(pool_df[[denom_col]], na.rm = TRUE)
        pool_meta[[denom_col]] <- list(players = pool_df, denom_total = denom_total)
      }
      if (is.null(baselines[[child_name]])) {
        player_rate  <- projections[[child_name]]
        player_denom <- projections[[denom_col]]
        num_total    <- sum(child$numerator_fn(player_rate, player_denom), na.rm = TRUE)
        denom_total  <- pool_meta[[denom_col]]$denom_total
        baselines[[child_name]] <- num_total * child$scale / denom_total
      }
    }
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

  # Side classification per row: "batter", "pitcher", "two_way", or NA.
  # Used to NA-fill cross-side sgp cells. Rows with NA classification (e.g.,
  # synthesized replacement rows that lack player_type / pos_eligibility) are
  # skipped by the cross-side mask so their SGP values are preserved.
  row_side <- if ("player_type" %in% names(projections)) {
    as.character(projections$player_type)
  } else if ("POS_ELIGIBILITY" %in% names(projections)) {
    elig <- projections$POS_ELIGIBILITY
    rs <- ifelse(grepl(PITCHER_ELIG_REGEX, elig), "pitcher", "batter")
    rs[is.na(elig)] <- NA_character_
    rs
  } else if ("pos_eligibility" %in% names(projections)) {
    elig <- projections$pos_eligibility
    rs <- ifelse(grepl(PITCHER_ELIG_REGEX, elig), "pitcher", "batter")
    rs[is.na(elig)] <- NA_character_
    rs
  } else {
    rep(NA_character_, n_players) # cannot classify; skip NA-fill
  }

  # Pre-allocate named list of SGP vectors keyed by sanitized column name.
  sgp_col_names <- .sgp_col_name(scored_cats)
  sgp_cols <- stats::setNames(
    vector("list", length(scored_cats)),
    sgp_col_names
  )

  # ---- Counting stats (Step 13) -------------------------------------------
  for (cat in count_cats) {
    col_sgp <- .sgp_col_name(cat)
    if (cat %in% missing_cats) {
      sgp_cols[[col_sgp]] <- rep(NA_real_, n_players)
    } else {
      sgp_cols[[col_sgp]] <- projections[[cat]] / denominators[cat]
    }
    # NA-fill rows whose side disagrees with the category's side.
    side <- .cat_side(cat)
    if (!is.na(side) && !all(is.na(row_side))) {
      cross <- !is.na(row_side) & row_side != "two_way" & row_side != side
      sgp_cols[[col_sgp]][cross] <- NA_real_
    }
  }

  # ---- Rate stats (Step 14) ------------------------------------------------
  # Iterate over scored rate stats in registry order. Emit a single
  # zero-playing-time warning per denominator column so that scoring
  # multiple rate stats that share a denominator (e.g., ERA + WHIP both
  # depending on IP) doesn't produce duplicate warnings.
  warned_denom_cols <- character(0L)

  for (cat in rate_cats) {
    col_sgp <- .sgp_col_name(cat)

    if (cat %in% missing_cats) {
      sgp_cols[[col_sgp]] <- rep(NA_real_, n_players)
      next
    }

    f <- effective_registry[[cat]]

    # Multi-component entries (e.g., OPS) are handled by a dedicated helper.
    if (!is.null(f$components)) {
      sgp_cols[[col_sgp]] <- unname(.compute_multicomponent_sgp(
        cat          = cat,
        entry        = f,
        projections  = projections,
        pool_meta    = pool_meta,
        baselines    = baselines,
        denominators = denominators,
        n_players    = n_players,
        row_side     = row_side
      ))
      next
    }

    denom_col <- f$denominator_col
    player_denom <- projections[[denom_col]]
    zero_denom <- player_denom == 0 | is.na(player_denom)

    if (any(zero_denom) && !denom_col %in% warned_denom_cols) {
      zero_names <- if ("NAME" %in% names(projections)) {
        projections$NAME[zero_denom]
      } else {
        which(zero_denom)
      }
      cli::cli_warn(
        paste0(
          "Player(s) with 0 or NA projected ",
          denom_col,
          ": ",
          paste(zero_names, collapse = ", "),
          ". Rate-stat SGP for {.val ",
          denom_col,
          "}-denominated categories set to {.code NA}."
        ),
        class = "rotostats_warning_zero_playing_time"
      )
      warned_denom_cols <- c(warned_denom_cols, denom_col)
    }

    src_col <- .resolve_source_col(effective_registry, cat)
    player_rate <- projections[[src_col]]
    player_num <- f$numerator_fn(player_rate, player_denom)
    denom_total <- pool_meta[[denom_col]]$denom_total
    num_total <- pool_num[[cat]]

    blended <- (num_total + player_num) * f$scale / (denom_total + player_denom)
    baseline <- baselines[[cat]]

    sgp_vec <- if (identical(f$direction, "standard")) {
      (blended - baseline) / denominators[cat]
    } else {
      (baseline - blended) / denominators[cat]
    }
    sgp_vec[zero_denom] <- NA_real_

    sgp_cols[[col_sgp]] <- unname(sgp_vec)

    # NA-fill rows whose side disagrees with the category's side.
    side <- .cat_side(cat)
    if (!is.na(side) && !all(is.na(row_side))) {
      cross <- !is.na(row_side) & row_side != "two_way" & row_side != side
      sgp_cols[[col_sgp]][cross] <- NA_real_
    }
  }

  # -------------------------------------------------------------------------
  # Step 15 — Assemble result data frame
  # -------------------------------------------------------------------------
  result <- as.data.frame(
    sgp_cols,
    row.names = seq_len(n_players),
    check.names = FALSE
  )

  # total_sgp: rowSums with na.rm = TRUE so cross-side NAs (and absent-stat
  # NAs) do not poison the total. Matches zaa()/zar()/par()/pvm() design.
  result$total_sgp <- rowSums(
    result[, sgp_col_names, drop = FALSE],
    na.rm = TRUE
  )

  result
}

# ---------------------------------------------------------------------------
# .compute_multicomponent_sgp() — internal helper for OPS-style rate stats
# ---------------------------------------------------------------------------

#' Compute SGP for a multi-component rate stat (e.g., OPS = OBP + SLG)
#'
#' Each component's blended-pool marginal is computed independently, then
#' summed and divided by the top-level denominator (from `denominators`).
#' Component baselines and pool totals must already be populated in
#' `baselines` and `pool_meta` before this function is called.
#'
#' @noRd
.compute_multicomponent_sgp <- function(cat, entry, projections, pool_meta,
                                        baselines, denominators, n_players,
                                        row_side) {
  marginal_total <- rep(0, n_players)

  for (child_name in names(entry$components)) {
    child     <- entry$components[[child_name]]
    denom_col <- child$denominator_col

    if (!(child_name %in% names(projections))) {
      cli::cli_warn(
        "Multi-component category {.val {cat}} requires column {.val {child_name}} in {.arg projections}; not found. SGP for {.val {cat}} set to NA.",
        class = "rotostats_warning_missing_category_column"
      )
      return(rep(NA_real_, n_players))
    }
    if (!(denom_col %in% names(projections))) {
      cli::cli_warn(
        "Multi-component category {.val {cat}} requires denominator column {.val {denom_col}} in {.arg projections}; not found. SGP for {.val {cat}} set to NA.",
        class = "rotostats_warning_missing_category_column"
      )
      return(rep(NA_real_, n_players))
    }

    player_rate  <- projections[[child_name]]
    player_denom <- projections[[denom_col]]
    player_num   <- child$numerator_fn(player_rate, player_denom)

    denom_total <- pool_meta[[denom_col]]$denom_total
    num_total   <- sum(child$numerator_fn(
      projections[[child_name]],
      projections[[denom_col]]
    ), na.rm = TRUE)

    blended  <- (num_total + player_num) * child$scale /
                  (denom_total + player_denom)
    baseline <- baselines[[child_name]]
    if (is.null(baseline)) {
      baseline <- num_total * child$scale / denom_total
    }

    marginal_total <- marginal_total + (blended - baseline)
  }

  if (identical(entry$direction, "inverse")) {
    sgp_vec <- -marginal_total / denominators[cat]
  } else {
    sgp_vec <- marginal_total / denominators[cat]
  }

  # NA rows where any component denominator is zero or NA
  for (child_name in names(entry$components)) {
    denom_col <- entry$components[[child_name]]$denominator_col
    pd <- projections[[denom_col]]
    sgp_vec[is.na(pd) | pd == 0] <- NA_real_
  }

  # NA-fill rows whose side disagrees with the entry's pool_type
  side_for_pool <- entry$pool_type  # "batter" or "pitcher"
  if (!all(is.na(row_side))) {
    cross <- !is.na(row_side) & row_side != "two_way" & row_side != side_for_pool
    sgp_vec[cross] <- NA_real_
  }

  sgp_vec
}
