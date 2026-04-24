# get-projections.R — fetch projections from FanGraphs (or accept custom data)

#' Fetch projections for a rotisserie auction league
#'
#' @description
#' Retrieves projections for the current MLB season from one of six FanGraphs
#' projection systems (Steamer, ZiPS, ATC, FanGraphs Depth Charts, THE BAT,
#' THE BAT X) or accepts a user-supplied data frame of custom projections.
#' The returned tibble is in long format: one row per player, with a
#' `player_type` column (`"batter"` / `"pitcher"`) distinguishing the two
#' groups. `svhd` is derived as `sv + hld` and `k` as `k_per_9 * ip / 9`
#' for pitchers.
#'
#' @param source One of `"steamer"` (default), `"zips"`, `"atc"`,
#'   `"fangraphsdc"`, `"thebat"`, `"thebatx"`, or `"custom"`.
#' @param year Projection year. Only the current MLB season is supported.
#'   `NULL` (default) resolves to the current calendar year; passing any
#'   other value aborts.
#' @param player_type One of `"batters"`, `"pitchers"`, or `"both"` (default).
#' @param data Required when `source = "custom"`; a data.frame containing at
#'   minimum one of `name` or `playerid`, plus one column per scored
#'   category. Passed through unchanged (no normalization is applied),
#'   coerced to a tibble on return.
#' @param mlb_only Logical, default `TRUE`. When `TRUE`, rows whose `league`
#'   value is not `"AL"` or `"NL"` (including `NA`) are dropped after fetch.
#'   Ignored on the `source = "custom"` path. Set to `FALSE` to retain minor
#'   league and free-agent rows.
#'
#' @return A tibble with one row per player. For non-custom sources, the
#'   always-present columns are `player_id`, `player_name`, `team`, `league`,
#'   `pos_eligibility`, and `player_type`. Position strings use `|` as the
#'   multi-position separator (e.g. `"SS|OF"`). Pitcher rows additionally
#'   include derived `svhd` and `k`. Other stat columns are passed through
#'   from FanGraphs with column names lowercased. The output plugs into
#'   [`replacement_level()`] and [`sgp()`] without further reshaping.
#'
#' @seealso [`sgp()`], [`replacement_level()`]
#'
#' @examples
#' \dontrun{
#' # Full current-season projections, AL/NL only
#' proj <- get_projections(source = "steamer")
#'
#' # Keep minor-league rows too
#' proj_all <- get_projections(source = "steamer", mlb_only = FALSE)
#'
#' # Pitchers only
#' pit <- get_projections(source = "thebat", player_type = "pitchers")
#' }
#'
#' @export
get_projections <- function(source      = "steamer",
                            year        = NULL,
                            player_type = "both",
                            data        = NULL,
                            mlb_only    = TRUE) {
  source      <- .validate_source(source)
  player_type <- .validate_player_type(player_type)
  year        <- .validate_year(year)
  data        <- .validate_custom_data(source, data)
  mlb_only    <- .validate_mlb_only(mlb_only)

  if (source == "custom") return(tibble::as_tibble(data))

  tibble::as_tibble(
    .fetch_and_assemble_projections(source, player_type, mlb_only)
  )
}
