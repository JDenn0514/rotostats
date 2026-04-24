# get-projections.R — fetch projections from FanGraphs (or accept custom data)

#' Fetch projections for a rotisserie auction league
#'
#' @description
#' Retrieves projections for the current MLB season from one of six FanGraphs
#' projection systems (Steamer, ZiPS, ATC, FanGraphs Depth Charts, THE BAT,
#' THE BAT X) or accepts a user-supplied data frame of custom projections.
#' The returned data frame is in long format: one row per player, with a
#' `player_type` column (`"batter"` / `"pitcher"`) distinguishing the two
#' groups. `SVHD` is always derived as `SV + HLD` for pitcher rows.
#'
#' @param source One of `"steamer"` (default), `"zips"`, `"atc"`,
#'   `"fangraphsdc"`, `"thebat"`, `"thebatx"`, or `"custom"`.
#' @param year Projection year. Only the current MLB season is supported.
#'   `NULL` (default) resolves to the current calendar year; passing any
#'   other value aborts.
#' @param player_type One of `"batters"`, `"pitchers"`, or `"both"` (default).
#' @param data Required when `source = "custom"`; a data.frame containing at
#'   minimum one of `name` or `playerid`, plus one column per scored
#'   category. Passed through unchanged (no normalization is applied).
#'
#' @return A data.frame with one row per player. For non-custom sources, the
#'   always-present columns are `playerid`, `name`, `team`, `pos`, and
#'   `player_type`; source-specific stat columns follow.
#'
#' @seealso [`sgp()`], [`replacement_level()`]
#'
#' @examples
#' \dontrun{
#' proj <- get_projections(source = "steamer")
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
