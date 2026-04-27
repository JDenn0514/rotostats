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

per_file_rows <- integer(0)

for (f in raw_files) {
  stem <- fs::path_ext_remove(fs::path_file(f))
  parts <- strsplit(stem, "-", fixed = TRUE)[[1]]
  stopifnot(length(parts) == 2L)
  year   <- as.integer(parts[1])
  league <- parts[2]

  tidy <- .normalize_tw_auction(f, year = year, league = league)

  out_path <- fs::path(clean_dir, glue::glue("auction-{league}-{year}.csv"))
  readr::write_csv(tidy, out_path)

  per_file_rows[stem] <- nrow(tidy)
  cli::cli_inform("normalized {.file {basename(f)}} \u2192 {.file {basename(out_path)}} ({nrow(tidy)} rows)")
}

cli::cli_inform("--- per-file row counts (paste into .tw_auction_row_counts) ---")
print(per_file_rows)
