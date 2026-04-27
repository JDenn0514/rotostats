# Internal helpers for the tout_wars_auctions dataset.
# See plans/specs/2026-04-27-auction-csv-normalization-design.md.

# Aliases applied BEFORE tokenization. Map raw input -> canonical output.
.tw_owner_aliases <- c(
  "Wolf and Colton" = "COLTON/WOLF",
  "Van RIPER"       = "VANRIPER",
  "VAN RIPER"       = "VANRIPER",
  "VanRiper"        = "VANRIPER"
)

#' Canonicalize a Tout Wars team-owner string.
#'
#' Trim whitespace, apply aliases, then split on `/`, uppercase tokens,
#' alphabetize, rejoin. Deterministic - `WOLF/COLTON` and `COLTON/WOLF` both
#' collapse to `COLTON/WOLF`.
#'
#' @param x A length-1 character vector.
#' @return Length-1 canonicalized character vector.
#' @keywords internal
#' @noRd
.canonicalize_tw_owner <- function(x) {
  if (is.na(x) || !nzchar(trimws(x))) {
    cli::cli_abort(
      "Owner string is blank or NA.",
      class = "rotostats_error_owner_blank"
    )
  }
  x <- trimws(x)
  if (x %in% names(.tw_owner_aliases)) {
    return(unname(.tw_owner_aliases[x]))
  }
  tokens <- strsplit(x, "/", fixed = TRUE)[[1]]
  tokens <- toupper(trimws(tokens))
  paste(sort(tokens), collapse = "/")
}
