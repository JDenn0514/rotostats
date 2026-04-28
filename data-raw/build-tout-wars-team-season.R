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

# Threshold: 10% allows for ~1 isolated outlier per 12-15 team league-year
# without admitting a systematic parser bug (which would flag multiple teams).
bad_ly <- flag_rate_by_ly[flag_rate_by_ly$flag_rate > 0.10, , drop = FALSE]
if (nrow(bad_ly) > 0L) {
  cli::cli_abort(
    c(
      "Reconciliation: {nrow(bad_ly)} league-year(s) have >10% flagged team-seasons.",
      "i" = "Worst: {paste(bad_ly$year, bad_ly$league, sprintf('(%.1f%%)', 100 * bad_ly$flag_rate), collapse = ', ')}",
      "i" = "Inspect {.file data-raw/sources/cache/team-season-residuals.csv}."
    ),
    class = "rotostats_error_team_season_reconciliation"
  )
}

# ---- 8. Sanity bounds -------------------------------------------------------
# AB observed range across 2010-2025: 1558 (2020 COVID 60-game) to 7754
# (mixed-league deep rosters). IP observed range: 186 to 1712. The bounds
# below leave a small margin around those extremes; their job is to catch
# absolute parser disasters (e.g., AB = 10), not to enforce a tight model.
oob <- joined[joined$ab < 1500 | joined$ab > 8000 |
              joined$ip < 150  | joined$ip > 1800, , drop = FALSE]
if (nrow(oob) > 0L) {
  cli::cli_abort(
    c(
      "{nrow(oob)} team-season(s) have IP or AB outside sanity bounds.",
      "i" = "AB bounds [1500, 8000]; IP bounds [150, 1800].",
      "i" = "Affected: {paste(oob$year, oob$league, oob$team_id, sep = '/', collapse = ', ')}"
    ),
    class = "rotostats_error_team_season_oob"
  )
}

# Cross-check against tout_wars_auctions$team_owner is intentionally omitted.
# The auction CSV source uses a mix of last-name and full-name conventions
# across years (and has at least one known typo: "SHECHTER" vs "SCHECHTER"),
# while the team-stats scraper produces full names from Onroto. A clean
# cross-check requires first normalizing the auction-side names, which is
# out of scope for the team-season build. Until that lands, downstream code
# that wants to join the two datasets must perform fuzzy matching itself.

# ---- 9. Final shape ---------------------------------------------------------
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
