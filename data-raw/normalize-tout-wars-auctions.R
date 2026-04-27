# Stage 1: Normalize raw Tout Wars auction CSVs into per-pick long-tidy CSVs.
# Reads from data-raw/sources/tout-wars/auctions/{year}-{league}.csv
# Writes to data-raw/sources/tout-wars/auctions-clean/auction-{league}-{year}.csv
#
# Spec: plans/specs/2026-04-27-auction-csv-normalization-design.md

devtools::load_all()

raw_dir   <- "data-raw/sources/tout-wars/auctions"
clean_dir <- "data-raw/sources/tout-wars/auctions-clean"
fs::dir_create(clean_dir)

raw_files <- list.files(raw_dir, pattern = "\\.csv$", full.names = TRUE)
stopifnot(length(raw_files) == 45L)

for (f in raw_files) {
  stem <- fs::path_ext_remove(fs::path_file(f))
  parts <- strsplit(stem, "-", fixed = TRUE)[[1]]
  year   <- as.integer(parts[1])
  league <- parts[2]

  tidy <- .normalize_tw_auction(f, year = year, league = league)

  expected_rows <- .tw_auction_row_counts[[stem]]
  if (nrow(tidy) != expected_rows) {
    cli::cli_abort(
      c("Row count drift in {.file {basename(f)}}.",
        "i" = "Expected {expected_rows}, got {nrow(tidy)}.",
        "i" = "If intentional, update .tw_auction_row_counts in R/utils-tout-wars.R."),
      class = "rotostats_error_auction_row_count_drift"
    )
  }

  team_totals <- aggregate(price ~ team_owner, data = tidy, FUN = sum)
  if (any(team_totals$price < 0) || any(team_totals$price > 400)) {
    bad <- team_totals[team_totals$price < 0 | team_totals$price > 400, ]
    cli::cli_abort(
      c("Per-team total price out of sanity bounds [0, 400] in {.file {basename(f)}}.",
        "i" = "Offending: {paste(bad$team_owner, bad$price, sep = '=', collapse = ', ')}."),
      class = "rotostats_error_auction_team_total_oob"
    )
  }
  file_total <- sum(tidy$price)
  if (file_total < 2000 || file_total > 5000) {
    cli::cli_abort(
      c("League-year total price out of sanity bounds [2000, 5000] in {.file {basename(f)}}.",
        "i" = "Got {file_total}."),
      class = "rotostats_error_auction_file_total_oob"
    )
  }

  out_path <- fs::path(clean_dir, glue::glue("auction-{league}-{year}.csv"))
  readr::write_csv(tidy, out_path)
  cli::cli_inform("normalized {.file {basename(f)}} \u2192 {.file {basename(out_path)}} ({nrow(tidy)} rows)")
}
