# Stage 2: load the cached team-season tibble and expose it as the package
# data object `tout_wars_team_season`.
#
# Spec: plans/specs/2026-04-27-tout-wars-team-season-design.md

devtools::load_all()

cache_path <- "data-raw/sources/cache/tout-wars-team-season.rds"
if (!file.exists(cache_path)) {
  cli::cli_abort(
    c(
      "Cache file not found: {.file {cache_path}}.",
      "i" = "Run {.file data-raw/build-tout-wars-team-season.R} first."
    )
  )
}

tout_wars_team_season <- readRDS(cache_path)

# Defensive: re-sort and re-class in case cache was edited.
tout_wars_team_season <- dplyr::arrange(
  tout_wars_team_season, .data$year, .data$league, .data$team_id
)
class(tout_wars_team_season) <- c("tbl_df", "tbl", "data.frame")

# Strip readr's spec/problems attributes that may have propagated through
# the pipeline.
attr(tout_wars_team_season, "spec") <- NULL
attr(tout_wars_team_season, "problems") <- NULL

usethis::use_data(tout_wars_team_season, overwrite = TRUE)
cli::cli_inform("Wrote tout_wars_team_season: {nrow(tout_wars_team_season)} rows.")
