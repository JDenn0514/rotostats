# Stage 2: Bind all cleaned per-pick CSVs into the tout_wars_auctions package
# data object.
#
# Spec: plans/specs/2026-04-27-auction-csv-normalization-design.md

devtools::load_all()

clean_dir <- "data-raw/sources/tout-wars/auctions-clean"
clean_files <- list.files(clean_dir, pattern = "\\.csv$", full.names = TRUE)

if (length(clean_files) != 45L) {
  cli::cli_abort(
    "Expected 45 cleaned auction CSVs, found {length(clean_files)}.",
    class = "rotostats_error_auction_missing_clean_files"
  )
}

read_one <- function(path) {
  stem <- fs::path_ext_remove(fs::path_file(path))  # auction-{league}-{year}
  parts <- strsplit(stem, "-", fixed = TRUE)[[1]]
  stopifnot(length(parts) == 3L && parts[1] == "auction")
  league <- parts[2]
  year   <- as.integer(parts[3])

  readr::read_csv(path, col_types = "ccccil", progress = FALSE) |>
    tibble::add_column(year = year, league = league, .before = 1)
}

tout_wars_auctions <- purrr::map_dfr(clean_files, read_one)

# Combined row-count assertion.
expected_total <- sum(.tw_auction_row_counts)
if (nrow(tout_wars_auctions) != expected_total) {
  cli::cli_abort(
    c("Combined row count mismatch.",
      "i" = "Expected {expected_total} (sum of golden table), got {nrow(tout_wars_auctions)}."),
    class = "rotostats_error_auction_combined_row_count"
  )
}

tout_wars_auctions <- dplyr::arrange(
  tout_wars_auctions,
  year, league, team_owner, position_slot, dplyr::desc(price)
)

# Strip readr's spec/problems attributes that propagate through map_dfr.
attr(tout_wars_auctions, "spec") <- NULL
attr(tout_wars_auctions, "problems") <- NULL
class(tout_wars_auctions) <- c("tbl_df", "tbl", "data.frame")

usethis::use_data(tout_wars_auctions, overwrite = TRUE)
cli::cli_inform("Wrote tout_wars_auctions: {nrow(tout_wars_auctions)} rows.")
