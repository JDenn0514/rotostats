# Stage 1: build the team-season tibble from standings + per-team
# batter/pitcher CSVs, run reconciliation, write the cache RDS.
#
# Spec: plans/specs/2026-04-27-tout-wars-team-season-design.md

devtools::load_all()

standings_dir <- "data-raw/sources/tout-wars/standings"
rosters_dir   <- "data-raw/sources/tout-wars/rosters"
cache_dir     <- "data-raw/sources/cache"
fs::dir_create(cache_dir)

# ---- 1. Discover league-years from the standings directory ------------------
standings_files <- list.files(standings_dir, pattern = "\\.csv$",
                              full.names = TRUE)
parse_key <- function(path) {
  stem <- fs::path_ext_remove(fs::path_file(path))
  parts <- strsplit(stem, "-", fixed = TRUE)[[1]]
  list(year = as.integer(parts[1]), league = parts[2])
}
keys <- lapply(standings_files, parse_key)
years <- vapply(keys, `[[`, integer(1L), "year")
leagues <- vapply(keys, `[[`, character(1L), "league")

# Filter to 2010-2025 (spec scope)
in_scope <- years >= 2010L & years <= 2025L
standings_files <- standings_files[in_scope]
years <- years[in_scope]
leagues <- leagues[in_scope]

stopifnot(length(standings_files) == 45L)

# ---- 2. Read all standings --------------------------------------------------
cli::cli_inform("Reading {.val {length(standings_files)}} standings file(s).")
standings <- purrr::map_dfr(standings_files, rotostats:::.read_tw_standings)

# Canonicalize team -> team_id (reuse auction-pipeline canonicalizer)
standings$team_id <- vapply(
  standings$team, rotostats:::.canonicalize_tw_owner, character(1L)
)

# ---- 3. Read all batter / pitcher CSVs --------------------------------------
batter_files <- file.path(rosters_dir,
                          sprintf("%d-%s-batters.csv", years, leagues))
pitcher_files <- file.path(rosters_dir,
                           sprintf("%d-%s-pitchers.csv", years, leagues))
stopifnot(all(file.exists(batter_files)))
stopifnot(all(file.exists(pitcher_files)))

cli::cli_inform("Reading {.val {length(batter_files)}} batter and pitcher CSV(s).")
batters  <- purrr::map_dfr(batter_files,  rotostats:::.read_tw_batters)
pitchers <- purrr::map_dfr(pitcher_files, rotostats:::.read_tw_pitchers)

# ---- 4. Filter to active + previously_active --------------------------------
batters  <- rotostats:::.filter_active_sections(batters)
pitchers <- rotostats:::.filter_active_sections(pitchers)

# ---- 5. Aggregate to team ---------------------------------------------------
team_bat <- rotostats:::.aggregate_team_batting(batters)
team_pit <- rotostats:::.aggregate_team_pitching(pitchers)

# Canonicalize team -> team_id on both sides
team_bat$team_id <- vapply(
  team_bat$team, rotostats:::.canonicalize_tw_owner, character(1L)
)
team_pit$team_id <- vapply(
  team_pit$team, rotostats:::.canonicalize_tw_owner, character(1L)
)

# ---- 6. Join standings × batting × pitching ---------------------------------
joined <- dplyr::left_join(
  standings,
  dplyr::select(team_bat, .data$year, .data$league, .data$team_id,
                .data$ab, .data$h_bat, .data$bb_bat, .data$so_bat),
  by = c("year", "league", "team_id")
)
joined <- dplyr::left_join(
  joined,
  dplyr::select(team_pit, .data$year, .data$league, .data$team_id,
                .data$ip, .data$bb_pit, .data$er_eq, .data$h_pit_eq),
  by = c("year", "league", "team_id")
)

# Fail loudly on any team_id mismatch (a standings row with no roster join)
unmatched <- joined[is.na(joined$ab) | is.na(joined$ip), ,
                    drop = FALSE]
if (nrow(unmatched) > 0L) {
  cli::cli_abort(
    c(
      "{nrow(unmatched)} standings row(s) have no matching roster aggregation.",
      "i" = "Affected: {paste(unmatched$year, unmatched$league, unmatched$team_id, sep = '/', collapse = ', ')}"
    ),
    class = "rotostats_error_team_owner_mismatch"
  )
}

# ---- 7. Reconciliation ------------------------------------------------------
joined <- rotostats:::.compute_team_residuals(joined)

# Write per-team residual diagnostics first so they're available even if the
# reconciliation gate aborts below.
residuals_df <- dplyr::select(
  joined,
  .data$year, .data$league, .data$team_id,
  .data$avg_resid, .data$obp_resid,
  .data$era_resid, .data$whip_resid,
  .data$flagged
)
readr::write_csv(residuals_df, file.path(cache_dir, "team-season-residuals.csv"))

flag_rate_by_ly <- dplyr::summarise(
  dplyr::group_by(joined, .data$year, .data$league),
  n = dplyr::n(),
  n_flagged = sum(.data$flagged),
  .groups = "drop"
)
flag_rate_by_ly$flag_rate <- flag_rate_by_ly$n_flagged / flag_rate_by_ly$n

bad_ly <- flag_rate_by_ly[flag_rate_by_ly$flag_rate > 0.05, , drop = FALSE]
if (nrow(bad_ly) > 0L) {
  cli::cli_abort(
    c(
      "Reconciliation: {nrow(bad_ly)} league-year(s) have >5% flagged team-seasons.",
      "i" = "Worst: {paste(bad_ly$year, bad_ly$league, sprintf('(%.1f%%)', 100 * bad_ly$flag_rate), collapse = ', ')}",
      "i" = "Inspect {.file data-raw/sources/cache/team-season-residuals.csv}."
    ),
    class = "rotostats_error_team_season_reconciliation"
  )
}

# ---- 8. Sanity bounds -------------------------------------------------------
oob <- joined[joined$ab < 3500 | joined$ab > 6500 |
              joined$ip < 800  | joined$ip > 2000, , drop = FALSE]
if (nrow(oob) > 0L) {
  cli::cli_abort(
    c(
      "{nrow(oob)} team-season(s) have IP or AB outside sanity bounds.",
      "i" = "AB bounds [3500, 6500]; IP bounds [800, 2000].",
      "i" = "Affected: {paste(oob$year, oob$league, oob$team_id, sep = '/', collapse = ', ')}"
    ),
    class = "rotostats_error_team_season_oob"
  )
}

# ---- 9. Cross-check against tout_wars_auctions team_owner set ---------------
auction_pairs <- dplyr::distinct(
  tout_wars_auctions[, c("year", "league", "team_owner")]
)
auction_pairs$key <- paste(auction_pairs$year, auction_pairs$league,
                           auction_pairs$team_owner, sep = "/")
ts_pairs <- dplyr::distinct(
  joined[, c("year", "league", "team_id")]
)
ts_pairs$key <- paste(ts_pairs$year, ts_pairs$league, ts_pairs$team_id,
                      sep = "/")
# Auctions cover 2012-2026, team-season covers 2010-2025; intersect on
# overlapping years only.
overlap_years <- intersect(unique(auction_pairs$year), unique(ts_pairs$year))
auction_overlap <- auction_pairs[auction_pairs$year %in% overlap_years, ]
ts_overlap      <- ts_pairs[ts_pairs$year %in% overlap_years, ]
in_auction_only <- setdiff(auction_overlap$key, ts_overlap$key)
in_ts_only      <- setdiff(ts_overlap$key, auction_overlap$key)
if (length(in_auction_only) > 0L || length(in_ts_only) > 0L) {
  cli::cli_abort(
    c(
      "team_id sets differ between tout_wars_auctions and team-season.",
      "i" = "In auctions only: {.val {head(in_auction_only, 10)}}",
      "i" = "In team-season only: {.val {head(in_ts_only, 10)}}"
    ),
    class = "rotostats_error_team_owner_mismatch"
  )
}

# ---- 10. Final shape ---------------------------------------------------------
final_cols <- c(
  "year", "league", "team_id",
  "R", "HR", "RBI", "SB", "OBP", "AVG",
  "W", "SV", "SO", "ERA", "WHIP",
  "AB", "IP",
  "R_pts", "HR_pts", "RBI_pts", "SB_pts", "OBP_pts", "AVG_pts",
  "W_pts", "SV_pts", "ERA_pts", "WHIP_pts", "SO_pts", "total_pts"
)
joined$AB <- as.integer(joined$ab)
joined$IP <- joined$ip
out <- joined[, final_cols, drop = FALSE]
out <- dplyr::arrange(out, .data$year, .data$league, .data$team_id)
out <- tibble::as_tibble(out)
class(out) <- c("tbl_df", "tbl", "data.frame")

saveRDS(out, file.path(cache_dir, "tout-wars-team-season.rds"))
cli::cli_inform("Wrote cache: {nrow(out)} team-seasons.")
