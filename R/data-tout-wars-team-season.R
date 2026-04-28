#' Tout Wars Team-Season Totals, 2010-2025
#'
#' Wide team-season totals for all three Tout Wars expert leagues
#' (American League, National League, Mixed). One row per team-year, in the
#' shape required by [league_history()] for testing
#' [sgp_denominators()], [sgp()], and [par()].
#'
#' @format A tibble with 28 columns:
#' \describe{
#'   \item{year}{Integer. Standings year (2010-2025).}
#'   \item{league}{Character. One of `"al"`, `"nl"`, `"mixed"`. Mixed
#'     present 2013+.}
#'   \item{team_id}{Character. Canonicalized team owner. Same canonicalization
#'     as `tout_wars_auctions$team_owner`.}
#'   \item{R, HR, RBI, SB}{Integer batting counting categories from
#'     standings.}
#'   \item{OBP, AVG}{Double batting rate categories. `NA` when the league
#'     did not score that category in that year.}
#'   \item{W, SV, SO}{Integer pitching counting categories from standings.}
#'   \item{ERA, WHIP}{Double pitching rate categories from standings.}
#'   \item{AB}{Integer. Sum of player AB across the team's `active` and
#'     `previously_active` roster sections.}
#'   \item{IP}{Double. Sum of player IP across the same sections.}
#'   \item{R_pts ... SO_pts}{Double. Standings points per category. `NA`
#'     when the category was not scored.}
#'   \item{total_pts}{Double. Total roto points.}
#' }
#'
#' @details
#' ## Section selection for AB / IP
#'
#' `AB` and `IP` sum stats from roster rows where
#' `roster_section %in% c("active", "previously_active")`. Players moved
#' to `reserved` or `previously_reserved` accumulated their stats outside
#' the team's contributing window and are excluded. This captures
#' injured-but-active players (whose pre-injury stats counted) without
#' overcounting season-long stashes.
#'
#' ## Reconciliation tolerances
#'
#' At build time, roster-reconstructed team rate stats are compared to the
#' standings rate values:
#' - OBP within 0.015 (degraded mode: scraper output lacks HBP/SF, so OBP
#'   is approximated as `(H + BB) / (AB + BB)`)
#' - ERA within 0.15
#' - WHIP within 0.020
#'
#' AVG residuals are not checked: every AVG-scoring league-year (pre-2017
#' AL/NL) lacks per-player H on Onroto's display page, so the team-side
#' AVG cannot be reconstructed.
#'
#' If more than 10% of team-seasons in any league-year exceed tolerance,
#' the build aborts. Per-team residuals are written to
#' `data-raw/sources/cache/team-season-residuals.csv`.
#'
#' @source Standings CSVs at
#'   `data-raw/sources/tout-wars/standings/{year}-{league}.csv`; per-team
#'   batter and pitcher CSVs at
#'   `data-raw/sources/tout-wars/rosters/{year}-{league}-{batters,pitchers}.csv`,
#'   produced by `data-raw/sources/tout-wars/scrape/team_stats.py`. Built
#'   via `data-raw/build-tout-wars-team-season.R` and
#'   `data-raw/tout-wars-team-season.R`.
"tout_wars_team_season"
