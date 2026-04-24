# tests/testthat/helper-get-projections-fixtures.R
#
# Lightweight list-of-lists builders that mirror the shape of parsed
# FanGraphs projections API responses. Kept tiny so unit tests are fast
# and failures are easy to read.

#' @keywords internal
fx_batter_json <- function(n = 3L) {
  lapply(seq_len(n), function(i) {
    list(
      playerid   = as.character(i),
      PlayerName = paste0("Batter", i),
      Team       = "NYY",
      Pos        = "2B",
      G          = 150,
      AB         = 550,
      HR         = 20 + i,
      R          = 80,
      RBI        = 75,
      SB         = 10,
      AVG        = 0.270,
      OBP        = 0.340,
      SLG        = 0.450,
      OPS        = 0.790,
      `wRC+`     = 110
    )
  })
}

#' @keywords internal
fx_pitcher_json <- function(n = 3L, include_qs = TRUE) {
  lapply(seq_len(n), function(i) {
    rec <- list(
      playerid   = as.character(100 + i),
      PlayerName = paste0("Pitcher", i),
      Team       = "LAD",
      Pos        = "SP",
      W          = 10,
      L          = 8,
      GS         = 30,
      G          = 32,
      IP         = 180,
      SV         = 0,
      HLD        = 0,
      ERA        = 3.50,
      WHIP       = 1.20,
      `K/9`      = 9.5,
      `BB/9`     = 2.5
    )
    if (include_qs) rec$QS <- 15
    rec
  })
}
