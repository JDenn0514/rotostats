# get-projections-internal.R — private helpers for get_projections()
#
# No exports. Each function has one job so the exported orchestrator in
# R/get-projections.R stays readable and the HTTP boundary stays isolated.

#' @noRd
.current_season_year <- function() {
  as.integer(format(Sys.Date(), "%Y"))
}

#' @noRd
VALID_PROJECTION_SOURCES <- c(
  "steamer", "zips", "atc", "fangraphsdc",
  "thebat", "thebatx", "custom"
)

#' @noRd
.validate_source <- function(source) {
  if (!is.character(source) || length(source) != 1L || is.na(source) ||
      !(source %in% VALID_PROJECTION_SOURCES)) {
    cli::cli_abort(
      c(
        "{.arg source} must be one of {.val {VALID_PROJECTION_SOURCES}}.",
        i = "Received: {.val {source}}."
      ),
      class = "rotostats_error_invalid_source"
    )
  }
  source
}

#' @noRd
VALID_PLAYER_TYPES <- c("batters", "pitchers", "both")

#' @noRd
.validate_player_type <- function(player_type) {
  if (!is.character(player_type) || length(player_type) != 1L ||
      is.na(player_type) || !(player_type %in% VALID_PLAYER_TYPES)) {
    cli::cli_abort(
      c(
        "{.arg player_type} must be one of {.val {VALID_PLAYER_TYPES}}.",
        i = "Received: {.val {player_type}}."
      ),
      class = "rotostats_error_invalid_player_type"
    )
  }
  player_type
}

#' @noRd
.validate_year <- function(year) {
  cur <- .current_season_year()
  if (is.null(year)) return(cur)
  if (!is.numeric(year) || length(year) != 1L || is.na(year) ||
      year != as.integer(year) || as.integer(year) != cur) {
    cli::cli_abort(
      c(
        "FanGraphs projections are only available for the current season.",
        i = "Current season: {.val {cur}}.",
        i = "Received {.arg year} = {.val {year}}.",
        "*" = "Omit {.arg year} to use the current season."
      ),
      class = "rotostats_error_unsupported_year"
    )
  }
  as.integer(year)
}

#' @noRd
.validate_custom_data <- function(source, data) {
  if (source != "custom") {
    if (!is.null(data)) {
      cli::cli_abort(
        c(
          "{.arg data} is only used when {.arg source = \"custom\"}.",
          i = "Received {.arg source} = {.val {source}} with non-NULL {.arg data}."
        ),
        class = "rotostats_error_data_ignored"
      )
    }
    return(NULL)
  }
  # source == "custom"
  if (is.null(data)) {
    cli::cli_abort(
      "{.arg data} is required when {.arg source = \"custom\"}.",
      class = "rotostats_error_missing_custom_data"
    )
  }
  if (!is.data.frame(data)) {
    cli::cli_abort(
      c(
        "{.arg data} must be a data.frame.",
        i = "Received class: {.cls {class(data)}}."
      ),
      class = "rotostats_error_invalid_custom_data"
    )
  }
  if (!any(c("name", "playerid") %in% names(data))) {
    cli::cli_abort(
      c(
        "{.arg data} must contain at least one of {.field name} or {.field playerid}.",
        i = "Columns present: {.val {names(data)}}."
      ),
      class = "rotostats_error_invalid_custom_data"
    )
  }
  data
}

#' @noRd
.build_projections_url <- function(source, player_type) {
  stopifnot(player_type %in% c("batters", "pitchers"))
  stats <- if (player_type == "batters") "bat" else "pit"
  httr2::url_modify(
    "https://www.fangraphs.com/api/projections",
    query = list(
      type    = source,
      stats   = stats,
      pos     = "all",
      team    = "0",
      players = "0",
      lg      = "all"
    )
  )
}

#' @noRd
.fetch_projections_api <- function(url) {
  result <- tryCatch(
    {
      req  <- httr2::request(url)
      resp <- httr2::req_perform(req)
      if (httr2::resp_is_error(resp)) {
        cli::cli_abort(
          c(
            "FanGraphs projections request failed.",
            i = "URL: {.url {url}}.",
            i = "HTTP status: {.val {httr2::resp_status(resp)}}."
          ),
          class = "rotostats_error_projection_fetch_failed"
        )
      }
      httr2::resp_body_json(resp)
    },
    error = function(e) {
      if (inherits(e, "rotostats_error_projection_fetch_failed")) stop(e)
      cli::cli_abort(
        c(
          "FanGraphs projections request failed.",
          i = "URL: {.url {url}}.",
          i = "Cause: {conditionMessage(e)}."
        ),
        class = "rotostats_error_projection_fetch_failed",
        parent = e
      )
    }
  )
  result
}

#' @noRd
.parse_projections_json <- function(raw) {
  if (!is.list(raw) || length(raw) == 0L) {
    cli::cli_abort(
      "FanGraphs returned zero projection rows.",
      class = "rotostats_error_empty_projection_response"
    )
  }
  all_keys <- unique(unlist(lapply(raw, names), use.names = FALSE))
  rows <- lapply(raw, function(rec) {
    missing <- setdiff(all_keys, names(rec))
    rec[missing] <- NA
    rec[all_keys]
  })
  # jsonlite::rbind_pages handles mixed types cleanly; fallback to do.call(rbind, ...)
  df <- as.data.frame(
    do.call(rbind, lapply(rows, function(r) lapply(r, function(x) if (is.null(x)) NA else x))),
    stringsAsFactors = FALSE
  )
  # flatten list columns to atomic where possible
  for (nm in names(df)) {
    col <- df[[nm]]
    if (is.list(col) && all(lengths(col) <= 1L)) {
      df[[nm]] <- unlist(
        lapply(col, function(x) if (length(x) == 0L) NA else x[[1L]])
      )
    }
  }
  df
}

#' @noRd
PROJECTION_COLUMN_RENAME <- c(
  PlayerName = "name",
  Team       = "team",
  Pos        = "pos",
  playerId   = "playerid",
  ShortName  = "playerid",
  `wRC+`     = "wRC_plus",
  `K/9`      = "K_per_9",
  `BB/9`     = "BB_per_9",
  `HR/9`     = "HR_per_9",
  `K/BB`     = "K_per_BB",
  `K%`       = "K_pct",
  `BB%`      = "BB_pct"
)

#' @noRd
.normalize_projection_cols <- function(df) {
  nm <- names(df)
  for (raw in names(PROJECTION_COLUMN_RENAME)) {
    target <- PROJECTION_COLUMN_RENAME[[raw]]
    hits <- which(nm == raw)
    if (length(hits) == 1L && !(target %in% nm)) {
      nm[hits] <- target
    }
  }
  names(df) <- nm
  df
}

#' @noRd
.derive_svhd <- function(df) {
  if (!all(c("SV", "HLD") %in% names(df))) return(df)
  sv  <- ifelse(is.na(df$SV),  0, df$SV)
  hld <- ifelse(is.na(df$HLD), 0, df$HLD)
  df$SVHD <- sv + hld
  rlang::inform(
    "SVHD computed as SV + HLD. Verify this matches your league's SVHD definition.",
    .frequency = "once",
    .frequency_id = "rotostats_svhd_definition"
  )
  df
}

#' @noRd
.attach_player_type <- function(df, type) {
  stopifnot(type %in% c("batter", "pitcher"))
  df$player_type <- type
  df
}

#' @noRd
.combine_batter_pitcher <- function(bat, pit) {
  if (is.null(bat)) return(pit)
  if (is.null(pit)) return(bat)
  all_cols <- union(names(bat), names(pit))
  fill_missing <- function(df, cols) {
    for (c in setdiff(cols, names(df))) df[[c]] <- NA
    df[cols]
  }
  rbind(fill_missing(bat, all_cols), fill_missing(pit, all_cols))
}

#' @noRd
.fetch_and_assemble_projections <- function(source, player_type) {
  # Stub for now — implemented in Task 14
  cli::cli_abort("not yet implemented")
}
