# league_config() — structural settings of a rotisserie league
#
# Holds only structural league settings. Algorithmic choices
# (denominator_method, rate_conversion, weights) stay as function-level
# parameters on the functions that consume them.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#' @noRd
CANONICAL_CATEGORIES <- c(
  CANONICAL_BATTING_CATEGORIES,
  CANONICAL_PITCHER_CATEGORIES
)

#' @noRd
PRIMARY_HITTER_SLOTS <- c("C", "1B", "2B", "3B", "SS", "OF", "DH")

#' @noRd
VALID_PITCHER_SLOT_NAMES <- c("SP", "RP")

#' @noRd
VALID_LEAGUE_TYPES <- c("mixed", "AL", "NL")

#' @noRd
VALID_KEEPER_METHODS <- c("pool_shrink", "salary_adjust", "none")

# ---------------------------------------------------------------------------
# Main constructor
# ---------------------------------------------------------------------------

#' League configuration for rotisserie valuation
#'
#' @description
#' Builds a validated S3 list that captures the structural settings of a
#' rotisserie league: team count, roster shape, scoring format, budget, and
#' keeper status. Passed as `config` to all downstream valuation functions
#' ([sgp_denominators()], `sgp()`, `replacement_level()`, `dollar_values()`,
#' `par()`). Construct once per league and reuse.
#'
#' Structural only — algorithmic choices (denominator method, rate conversion,
#' weights) remain as arguments on the functions that consume them.
#'
#' @param n_teams Positive integer. Number of teams in the league. Default 12.
#' @param roster_slots Named integer vector of hitter roster slots by position.
#'   Combo slots (UTIL, MI, CI) should be included — they count toward league
#'   depth for pool sizing even though they have no independent replacement
#'   pool. Positions with zero slots may be omitted.
#' @param pitcher_slots Either a single integer (total pitcher slots per team;
#'   SP/RP split inferred downstream) or a named integer vector with names
#'   from `c("SP", "RP")`. Default `9L`.
#' @param batting_categories Character vector of scored batting categories.
#'   Normalized to uppercase. Required. Validates against
#'   `CANONICAL_BATTING_CATEGORIES`; categories belonging to the canonical
#'   pitcher list emit `rotostats_warning_category_side_mismatch`.
#' @param pitcher_categories Character vector of scored pitcher categories.
#'   Normalized to uppercase. Required. Validates against
#'   `CANONICAL_PITCHER_CATEGORIES`; categories belonging to the canonical
#'   batting list emit `rotostats_warning_category_side_mismatch`.
#' @param inverse_categories Optional character vector of scoring category
#'   names where a lower value is better (lower-is-better categories, e.g.,
#'   ERA, WHIP, FIP). Normalized to uppercase at construction. Every element
#'   must appear in `categories`; unknown names abort with
#'   `rotostats_error_invalid_inverse_categories`. `NULL` (default) means no
#'   league-level override; [sgp_denominators()] and future consumers fall
#'   through to the package lookup ([inverse_categories()]). Pass
#'   `character(0)` is not valid; use `NULL` for "no override".
#' @param league_type One of `"mixed"`, `"AL"`, `"NL"`. Default `"mixed"`.
#'   Controls DH eligibility and downstream player-pool filtering: `"AL"` /
#'   `"NL"` cause [replacement_level()] to drop rows where
#'   `projections$LEAGUE` does not match before computing the replacement
#'   pool. `"NL"` additionally drops `DH` from `roster_slots` with a warning
#'   if present. `"mixed"` keeps both leagues.
#' @param budget Positive integer. Per-team auction budget in dollars.
#'   Default `260L`.
#' @param budget_split Numeric in `(0, 1)`. Fraction of the total league
#'   budget devoted to hitters. Default `0.60`. Calibrate from spending
#'   history with `calibrate_budget_split()`.
#' @param keeper Controls keeper handling. `FALSE` (default) = redraft;
#'   `TRUE` = keeper league with default settings
#'   (`method = "pool_shrink"`, `keeper_col = "is_keeper"`,
#'   `salary_col = NULL`); or an explicit named list with those fields plus
#'   `is_keeper = TRUE`.
#'
#' @return An S3 object of class `c("league_config", "list")` with the
#'   resolved and validated settings.
#'
#' @seealso [league_history()], [sgp_denominators()]
#' @export
#' @examples
#' lg <- league_config(
#'   n_teams            = 12L,
#'   roster_slots       = c(C = 1, "1B" = 1, "2B" = 1, "3B" = 1,
#'                          SS = 1, OF = 5, UTIL = 1),
#'   pitcher_slots      = c(SP = 6L, RP = 3L),
#'   batting_categories = c("R", "HR", "RBI", "SB", "AVG"),
#'   pitcher_categories = c("W", "K", "SV", "ERA", "WHIP")
#' )
#' print(lg)
league_config <- function(
  n_teams = 12L,
  roster_slots,
  pitcher_slots = 9L,
  batting_categories,
  pitcher_categories,
  inverse_categories = NULL,
  league_type = "mixed",
  budget = 260L,
  budget_split = 0.60,
  keeper = FALSE
) {
  n_teams       <- validate_n_teams(n_teams)
  league_type   <- validate_league_type(league_type)
  roster_slots  <- validate_roster_slots(roster_slots)
  pitcher_slots <- validate_pitcher_slots(pitcher_slots)
  budget        <- validate_budget(budget)
  budget_split  <- validate_budget_split(budget_split)

  # Required args: surface a classed error rather than R's generic
  # "missing, with no default" so callers can catch it like other category
  # validation failures.
  if (missing(batting_categories)) {
    cli::cli_abort(
      "{.arg batting_categories} is required.",
      class = "rotostats_error_invalid_categories"
    )
  }
  if (missing(pitcher_categories)) {
    cli::cli_abort(
      "{.arg pitcher_categories} is required.",
      class = "rotostats_error_invalid_categories"
    )
  }

  batting_categories <- validate_batting_categories(batting_categories)
  pitcher_categories <- validate_pitcher_categories(pitcher_categories)

  # Convenience union — canonical order is batting first, then pitcher.
  categories <- c(batting_categories, pitcher_categories)

  if (length(categories) == 0L) {
    cli::cli_abort(
      c(
        "At least one scored category is required.",
        i = "Supply categories via {.arg batting_categories}, {.arg pitcher_categories}, or both."
      ),
      class = "rotostats_error_invalid_categories"
    )
  }

  inverse_categories <- validate_inverse_categories(
    inverse_categories,
    categories
  )
  roster_slots <- drop_dh_for_nl(roster_slots, league_type)
  keeper       <- resolve_keeper(keeper)

  structure(
    list(
      n_teams            = n_teams,
      roster_slots       = roster_slots,
      pitcher_slots      = pitcher_slots,
      batting_categories = batting_categories,
      pitcher_categories = pitcher_categories,
      categories         = categories,
      inverse_categories = inverse_categories,
      league_type        = league_type,
      budget             = budget,
      budget_split       = budget_split,
      keeper             = keeper
    ),
    class = c("league_config", "list")
  )
}

# ---------------------------------------------------------------------------
# Validators
# ---------------------------------------------------------------------------

#' @noRd
validate_n_teams <- function(n_teams) {
  ok <- is.numeric(n_teams) &&
    length(n_teams) == 1L &&
    !is.na(n_teams) &&
    n_teams > 0 &&
    isTRUE(all.equal(n_teams, round(n_teams)))
  if (!ok) {
    cli::cli_abort(
      "{.arg n_teams} must be a single positive integer; got {.val {n_teams}}.",
      class = "rotostats_error_invalid_n_teams"
    )
  }
  as.integer(n_teams)
}

#' @noRd
validate_roster_slots <- function(roster_slots) {
  if (
    !is.numeric(roster_slots) ||
      is.null(names(roster_slots)) ||
      any(names(roster_slots) == "") ||
      any(!is.finite(roster_slots)) ||
      any(roster_slots < 0) ||
      !all(vapply(
        roster_slots,
        function(x) isTRUE(all.equal(x, round(x))),
        logical(1L)
      ))
  ) {
    cli::cli_abort(
      "{.arg roster_slots} must be a named integer vector of non-negative slot counts.",
      class = "rotostats_error_invalid_roster_slots"
    )
  }
  out <- as.integer(roster_slots)
  names(out) <- names(roster_slots)
  out
}

#' @noRd
validate_pitcher_slots <- function(pitcher_slots) {
  base_msg <- paste0(
    "{.arg pitcher_slots} must be a single positive integer or a named ",
    "integer vector with names from {.val SP} / {.val RP}."
  )

  if (
    !is.numeric(pitcher_slots) ||
      any(!is.finite(pitcher_slots)) ||
      any(pitcher_slots < 0) ||
      !all(vapply(
        pitcher_slots,
        function(x) isTRUE(all.equal(x, round(x))),
        logical(1L)
      ))
  ) {
    cli::cli_abort(base_msg, class = "rotostats_error_invalid_pitcher_slots")
  }

  nms <- names(pitcher_slots)
  if (is.null(nms)) {
    if (length(pitcher_slots) != 1L) {
      cli::cli_abort(base_msg, class = "rotostats_error_invalid_pitcher_slots")
    }
    return(as.integer(pitcher_slots))
  }

  bad <- setdiff(nms, VALID_PITCHER_SLOT_NAMES)
  if (length(bad) > 0L) {
    cli::cli_abort(
      c(base_msg, "i" = "Unrecognized name{?s}: {.val {bad}}."),
      class = "rotostats_error_invalid_pitcher_slots"
    )
  }
  out <- as.integer(pitcher_slots)
  names(out) <- nms
  out
}

#' @noRd
validate_league_type <- function(league_type) {
  if (
    !is.character(league_type) ||
      length(league_type) != 1L ||
      !(league_type %in% VALID_LEAGUE_TYPES)
  ) {
    cli::cli_abort(
      "{.arg league_type} must be one of {.val {VALID_LEAGUE_TYPES}}; got {.val {league_type}}.",
      class = "rotostats_error_invalid_league_type"
    )
  }
  league_type
}

#' @noRd
validate_budget <- function(budget) {
  ok <- is.numeric(budget) &&
    length(budget) == 1L &&
    !is.na(budget) &&
    budget > 0 &&
    isTRUE(all.equal(budget, round(budget)))
  if (!ok) {
    cli::cli_abort(
      "{.arg budget} must be a single positive integer; got {.val {budget}}.",
      class = "rotostats_error_invalid_budget"
    )
  }
  as.integer(budget)
}

#' @noRd
validate_budget_split <- function(budget_split) {
  ok <- is.numeric(budget_split) &&
    length(budget_split) == 1L &&
    !is.na(budget_split) &&
    budget_split > 0 &&
    budget_split < 1
  if (!ok) {
    cli::cli_abort(
      "{.arg budget_split} must be a single numeric value strictly in (0, 1); got {.val {budget_split}}.",
      class = "rotostats_error_invalid_budget_split"
    )
  }
  as.numeric(budget_split)
}

#' @noRd
validate_side_categories <- function(
  cats,
  arg_name,
  canonical_for_side,
  canonical_for_other_side
) {
  if (!is.character(cats) || any(is.na(cats))) {
    cli::cli_abort(
      c(
        "{.arg {arg_name}} must be a character vector (may be empty).",
        i = "Received: {.val {cats}}."
      ),
      class = "rotostats_error_invalid_categories"
    )
  }
  cats_upper <- toupper(cats)

  # Side-mismatch warning: a category present here that the canonical lists
  # assign to the other side. Doesn't block — leagues can score odd combos —
  # but loudly surfaces typos like batting_categories = c("HR", "ERA").
  misplaced <- intersect(cats_upper, canonical_for_other_side)
  if (length(misplaced)) {
    cli::cli_warn(
      c(
        "{.val {misplaced}} {?is/are} normally scored on the other side; \\
         appearing in {.arg {arg_name}}.",
        i = "If this is intentional, ignore this warning."
      ),
      class = "rotostats_warning_category_side_mismatch"
    )
  }

  # Unknown-category warning: not in either canonical list.
  unknown <- setdiff(
    cats_upper,
    union(canonical_for_side, canonical_for_other_side)
  )
  if (length(unknown)) {
    cli::cli_warn(
      c(
        "Unrecognized {.arg {arg_name}}: {.val {unknown}}.",
        i = "Accepted but unvalidated against canonical lists."
      ),
      class = "rotostats_warning_unknown_category"
    )
  }

  cats_upper
}

#' @noRd
validate_batting_categories <- function(cats) {
  validate_side_categories(
    cats,
    arg_name                 = "batting_categories",
    canonical_for_side       = CANONICAL_BATTING_CATEGORIES,
    canonical_for_other_side = CANONICAL_PITCHER_CATEGORIES
  )
}

#' @noRd
validate_pitcher_categories <- function(cats) {
  validate_side_categories(
    cats,
    arg_name                 = "pitcher_categories",
    canonical_for_side       = CANONICAL_PITCHER_CATEGORIES,
    canonical_for_other_side = CANONICAL_BATTING_CATEGORIES
  )
}

#' @noRd
validate_inverse_categories <- function(x, categories) {
  # NULL is valid: user is declaring no override; downstream falls through
  # to package lookup.
  if (is.null(x)) {
    return(NULL)
  }

  # Must be a character vector.
  if (!is.character(x) || length(x) == 0L) {
    cli::cli_abort(
      paste0(
        "{.arg inverse_categories} must be a non-empty character vector or ",
        "{.code NULL}; got {.cls {class(x)}}."
      ),
      class = "rotostats_error_invalid_inverse_categories"
    )
  }

  # Normalize to uppercase.
  x_upper <- toupper(x)

  # Membership check: every element must appear in config$categories.
  bad <- setdiff(x_upper, categories)
  if (length(bad) > 0L) {
    n_bad <- length(bad)
    cli::cli_abort(
      c(
        "{n_bad} element{?s} of {.arg inverse_categories} not in {.arg categories}.",
        "x" = "Invalid: {.val {bad}}",
        "i" = "Valid categories: {.val {categories}}"
      ),
      class = "rotostats_error_invalid_inverse_categories"
    )
  }

  unique(x_upper)
}

#' @noRd
drop_dh_for_nl <- function(roster_slots, league_type) {
  if (league_type == "NL" && "DH" %in% names(roster_slots)) {
    cli::cli_warn(
      c(
        "{.val DH} slot is not valid for {.val NL} leagues; dropping.",
        "i" = "Use {.code league_type = \"mixed\"} or {.val \"AL\"} for DH-eligible rosters."
      ),
      class = "rotostats_warning_dh_dropped_nl"
    )
    roster_slots <- roster_slots[names(roster_slots) != "DH"]
  }
  roster_slots
}

#' @noRd
resolve_keeper <- function(keeper) {
  if (isFALSE(keeper)) {
    return(FALSE)
  }

  if (isTRUE(keeper)) {
    return(list(
      is_keeper = TRUE,
      method = "pool_shrink",
      keeper_col = "is_keeper",
      salary_col = NULL
    ))
  }

  if (!is.list(keeper)) {
    cli::cli_abort(
      "{.arg keeper} must be {.val FALSE}, {.val TRUE}, or a named list.",
      class = "rotostats_error_invalid_keeper_config"
    )
  }

  required <- c("is_keeper", "method", "keeper_col")
  missing <- setdiff(required, names(keeper))
  if (length(missing) > 0L) {
    cli::cli_abort(
      c(
        "{.arg keeper} list is missing required field{?s}: {.val {missing}}.",
        "i" = "Required fields: {.val {required}}."
      ),
      class = "rotostats_error_invalid_keeper_config"
    )
  }

  if (!(keeper$method %in% VALID_KEEPER_METHODS)) {
    cli::cli_abort(
      "{.arg keeper$method} must be one of {.val {VALID_KEEPER_METHODS}}; got {.val {keeper$method}}.",
      class = "rotostats_error_invalid_keeper_config"
    )
  }

  if (
    identical(keeper$method, "salary_adjust") &&
      (is.null(keeper$salary_col) || !nzchar(keeper$salary_col))
  ) {
    cli::cli_abort(
      c(
        "{.arg keeper$salary_col} is required when {.code method = \"salary_adjust\"}.",
        "i" = "Specify the projections column holding keeper contract salaries."
      ),
      class = "rotostats_error_missing_keeper_salary_col"
    )
  }

  if (is.null(keeper$salary_col)) {
    keeper["salary_col"] <- list(NULL)
  }
  keeper
}

# ---------------------------------------------------------------------------
# Internal helper: pool_sizes()
# ---------------------------------------------------------------------------

#' @noRd
pool_sizes <- function(config) {
  primary <- intersect(names(config$roster_slots), PRIMARY_HITTER_SLOTS)
  list(
    pitchers = as.integer(config$n_teams * sum(config$pitcher_slots)),
    hitters = as.integer(config$n_teams * sum(config$roster_slots[primary]))
  )
}

# ---------------------------------------------------------------------------
# Print method
# ---------------------------------------------------------------------------

#' Print method for league_config objects
#'
#' @param x A `league_config` object from [league_config()].
#' @param ... Ignored.
#'
#' @return `x`, invisibly.
#'
#' @method print league_config
#' @export
print.league_config <- function(x, ...) {
  cat("League configuration\n")
  cat(sprintf(
    "  Teams:      %d | Budget: $%d | Type: %s\n",
    x$n_teams,
    x$budget,
    x$league_type
  ))
  hitter_txt <- paste(
    sprintf("%s=%d", names(x$roster_slots), x$roster_slots),
    collapse = ", "
  )
  cat(sprintf("  Hitters:    %s (%d slots)\n", hitter_txt, sum(x$roster_slots)))
  p_total <- sum(x$pitcher_slots)
  pitcher_txt <- if (!is.null(names(x$pitcher_slots))) {
    paste(
      sprintf("%s=%d", names(x$pitcher_slots), x$pitcher_slots),
      collapse = ", "
    )
  } else {
    sprintf("total=%d", p_total)
  }
  cat(sprintf("  Pitchers:   %s (%d slots)\n", pitcher_txt, p_total))
  cat(sprintf(
    "  Batting:    %s  (%d)\n",
    paste(x$batting_categories, collapse = " "),
    length(x$batting_categories)
  ))
  cat(sprintf(
    "  Pitching:   %s  (%d)\n",
    paste(x$pitcher_categories, collapse = " "),
    length(x$pitcher_categories)
  ))
  inv_txt <- if (is.null(x$inverse_categories)) {
    "(none declared)"
  } else {
    paste(x$inverse_categories, collapse = " ")
  }
  cat(sprintf("  Inverse:    %s\n", inv_txt))
  keeper_txt <- if (isFALSE(x$keeper)) {
    "no"
  } else {
    sprintf("yes (method = %s)", x$keeper$method)
  }
  cat(sprintf("  Keeper:     %s\n", keeper_txt))
  invisible(x)
}
