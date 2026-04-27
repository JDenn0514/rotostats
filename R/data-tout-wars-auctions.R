#' Tout Wars Auction Results, 2012–2026
#'
#' Long-tidy auction results for all three Tout Wars expert leagues
#' (American League, National League, Mixed). One row per auctioned player.
#'
#' @format A tibble with 8 columns:
#' \describe{
#'   \item{year}{Integer. Auction year.}
#'   \item{league}{Character. One of `"al"`, `"nl"`, or `"mixed"`.}
#'   \item{team_owner}{Character. Canonicalized owner name. Last name uppercase;
#'     partnerships joined with `/` and alphabetized (e.g., `"COLTON/WOLF"`).}
#'   \item{position_slot}{Character. Roster slot the player occupied. Observed
#'     values: `"C"`, `"1B"`, `"2B"`, `"3B"`, `"SS"`, `"MI"`, `"CI"`, `"INF"`,
#'     `"OF"`, `"UT"`, `"P"`, `"SW"`. Not multi-position eligibility.}
#'   \item{player_type}{Character. `"batter"` or `"pitcher"`. Derived from
#'     `position_slot`: `"P"` (and historically `"SP"`, `"RP"`) maps to
#'     `"pitcher"`; everything else is `"batter"`.}
#'   \item{player_name}{Character. Player name as recorded in the source CSV,
#'     whitespace-trimmed. Not normalized to any external player-ID source.}
#'   \item{price}{Integer. Auction price in dollars. Non-negative.}
#'   \item{is_keeper}{Logical. Always `FALSE` — Tout Wars is not a keeper league.}
#' }
#'
#' @source Tout Wars auction CSVs at
#'   <https://www.toutwars.com>, normalized via
#'   `data-raw/normalize-tout-wars-auctions.R` and
#'   `data-raw/tout-wars-auctions.R`.
"tout_wars_auctions"
