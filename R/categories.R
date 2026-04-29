# R/categories.R — Canonical category lists, partitioned by side.
#
# Single source of truth for which scored category belongs to hitters vs
# pitchers. Used by league_config validators, zaa()/zar()/par()/pvm() to
# scope per-side z-score computations, and by .classify_custom_player_type()
# in get-projections-internal.R when the user supplies a custom data frame
# without a player_type column.

#' @noRd
CANONICAL_BATTING_CATEGORIES <- c(
  "HR", "R", "RBI", "SB", "AVG", "OBP", "SLG", "OPS",
  "K%_BATTER", "BB%_BATTER", "SO%_BATTER"
)

#' @noRd
CANONICAL_PITCHER_CATEGORIES <- c(
  "W", "K", "SO", "SV", "HLD", "QS", "SVHD",
  "ERA", "WHIP", "FIP", "XFIP", "SIERA", "XERA",
  "K/9", "BB/9", "HR/9", "SO/9", "SO/BB",
  "K%_PITCHER", "BB%_PITCHER", "SO%_PITCHER"
)

#' @noRd
.classify_category_side <- function(cat) {
  cat_u <- toupper(cat)
  out <- rep(NA_character_, length(cat_u))
  out[cat_u %in% CANONICAL_BATTING_CATEGORIES] <- "batter"
  out[cat_u %in% CANONICAL_PITCHER_CATEGORIES] <- "pitcher"
  out
}
