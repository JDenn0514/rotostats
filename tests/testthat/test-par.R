# tests/testthat/test-par.R
#
# Unit and integration tests for par() per test-spec.md §1–§9.
# Written by the tester pipeline from test-spec.md.
# Tester did NOT read spec.md, implementation.md, or sim-spec.md.
#
# Fixtures are defined in helper-par-fixtures.R (auto-loaded by testthat).

library(testthat)

# ---------------------------------------------------------------------------
# §3 Core Invariant Tests
# ---------------------------------------------------------------------------

test_that("AC-2 delegation identity: par_[c] + replacement_sgp[pos, c] == sgp_[c]", {
  fx     <- make_par_counting_fixture()
  repl   <- fx$replacement
  denoms <- fx$denominators
  lh     <- fx$league_history

  result     <- par(repl, denoms, league_history = lh)
  sgp_direct <- sgp(
    projections     = attr(repl, "projections"),
    denominators    = denoms,
    league_history  = lh,
    league_config   = fx$config
  )

  repl_sgp         <- attr(result, "replacement_sgp")
  pos_assign       <- attr(repl, "position_assignments")
  proj_used        <- attr(repl, "projections")
  player_positions <- pos_assign[proj_used$PLAYER_ID]
  scored_cats      <- c("HR", "R", "SB", "K", "SV")

  for (cat in scored_cats) {
    par_col  <- paste0("par_", cat)
    sgp_col  <- paste0("sgp_", cat)
    for (i in seq_len(nrow(proj_used))) {
      pos_i <- player_positions[i]
      if (!is.null(repl_sgp[[pos_i]]) && !is.na(repl_sgp[[pos_i]][[cat]])) {
        computed <- result[[par_col]][i] + repl_sgp[[pos_i]][[cat]]
        expect_equal(
          computed, sgp_direct[[sgp_col]][i],
          tolerance = 1e-10,
          label = paste0("delegation identity player ", i, " cat ", cat)
        )
      }
    }
  }
})

test_that("Replacement player at each position has total_par approximately 0", {
  fx     <- make_par_counting_fixture()
  repl   <- fx$replacement
  denoms <- fx$denominators
  lh     <- fx$league_history

  result <- par(repl, denoms, league_history = lh)

  pos_assign       <- attr(repl, "position_assignments")
  proj_used        <- attr(repl, "projections")
  player_positions <- pos_assign[proj_used$PLAYER_ID]

  n_teams      <- repl$params$n_teams
  roster_slots <- repl$params$roster_slots

  for (pos in names(roster_slots[roster_slots > 0L])) {
    pos_players   <- which(player_positions == pos)
    boundary_rank <- n_teams * roster_slots[[pos]]
    if (boundary_rank <= length(pos_players)) {
      tp_sorted   <- sort(result$total_par[pos_players], decreasing = TRUE)
      boundary_tp <- tp_sorted[boundary_rank]
      expect_equal(
        boundary_tp, 0,
        tolerance = 0.05,
        label = paste("Boundary total_par for position", pos)
      )
    }
  }
})

test_that("AC-3 pipe equivalence: replacement_level() |> par() == par(replacement, ...)", {
  fx     <- make_par_counting_fixture()
  repl   <- fx$replacement
  denoms <- fx$denominators
  proj   <- fx$projections
  cfg    <- fx$config
  lh     <- fx$league_history

  result_direct <- par(repl, denoms, league_history = lh)
  result_pipe   <- replacement_level(proj, config = cfg) |>
                    par(denoms, league_history = lh)

  expect_equal(names(result_direct), names(result_pipe))
  expect_equal(nrow(result_direct),  nrow(result_pipe))
  expect_equal(result_direct$total_par, result_pipe$total_par, tolerance = 1e-10)
  expect_equal(attr(result_direct, "units"),  attr(result_pipe, "units"))
  expect_equal(attr(result_direct, "anchor"), attr(result_pipe, "anchor"))
  expect_equal(
    attr(result_direct, "replacement_sgp"),
    attr(result_pipe,   "replacement_sgp"),
    tolerance = 1e-10
  )
})

test_that("AC-5 SP and RP use separate replacement baselines", {
  fx     <- make_par_counting_fixture()
  result <- par(fx$replacement, fx$denominators, league_history = fx$league_history)

  repl_sgp <- attr(result, "replacement_sgp")
  expect_true("SP" %in% names(repl_sgp))
  expect_true("RP" %in% names(repl_sgp))
  expect_false(
    isTRUE(all.equal(repl_sgp[["SP"]][["K"]], repl_sgp[["RP"]][["K"]])),
    label = "SP and RP replacement SGP for K must differ"
  )
})

# ---------------------------------------------------------------------------
# §4 Output Column Contract Tests
# ---------------------------------------------------------------------------

test_that("include_raw = FALSE: only par_[cat] and total_par columns", {
  fx     <- make_par_counting_fixture()
  result <- par(fx$replacement, fx$denominators,
                league_history = fx$league_history, include_raw = FALSE)
  scored_cats <- c("HR", "R", "SB", "K", "SV")

  expect_equal(
    sort(names(result)),
    sort(c(paste0("par_", scored_cats), "total_par"))
  )
  expect_false(any(grepl("^sgp_", names(result))))
})

test_that("include_raw = TRUE: par_[cat] + total_par + sgp_[cat] + total_sgp", {
  fx     <- make_par_counting_fixture()
  result <- par(fx$replacement, fx$denominators,
                league_history = fx$league_history, include_raw = TRUE)
  scored_cats <- c("HR", "R", "SB", "K", "SV")

  expect_true(all(paste0("sgp_", scored_cats) %in% names(result)))
  expect_true("total_sgp" %in% names(result))
  expect_true(all(paste0("par_", scored_cats) %in% names(result)))
  expect_true("total_par" %in% names(result))
})

test_that("Output attributes are correct: units, anchor, replacement_sgp", {
  fx     <- make_par_counting_fixture()
  result <- par(fx$replacement, fx$denominators, league_history = fx$league_history)

  expect_equal(attr(result, "units"),  "sgp")
  expect_equal(attr(result, "anchor"), "replacement")

  repl_sgp <- attr(result, "replacement_sgp")
  expect_true(is.list(repl_sgp))

  all_pos     <- names(repl_sgp)
  roster_pos  <- names(fx$config$roster_slots)
  pitcher_pos <- names(fx$config$pitcher_slots)
  valid_pos   <- c(roster_pos, pitcher_pos)
  expect_true(all(all_pos %in% valid_pos))

  scored_cats <- c("HR", "R", "SB", "K", "SV")
  for (pos in all_pos) {
    expect_true(is.numeric(repl_sgp[[pos]]))
    expect_true(!is.null(names(repl_sgp[[pos]])))
    expect_true(all(names(repl_sgp[[pos]]) %in% scored_cats))
  }
})

test_that("Row count equals nrow(projections)", {
  fx     <- make_par_counting_fixture()
  result <- par(fx$replacement, fx$denominators, league_history = fx$league_history)
  expect_equal(nrow(result), nrow(attr(fx$replacement, "projections")))
})

test_that("Invariant 3: total_par equals rowSums of par_[cat] columns", {
  # Note: par() uses na.rm = TRUE for total_par (simulator bug fix #3):
  # hitters have NA for pitcher categories and vice versa.  The observable
  # invariant is therefore na.rm = TRUE, which matches the implementation.
  # A player contributes 0 (not NA) to categories where they have no stats.
  fx     <- make_par_counting_fixture()
  result <- par(fx$replacement, fx$denominators, league_history = fx$league_history)
  scored_cats   <- c("HR", "R", "SB", "K", "SV")
  par_col_names <- paste0("par_", scored_cats)
  expected_total <- rowSums(result[, par_col_names, drop = FALSE], na.rm = TRUE)
  expect_equal(result$total_par, unname(expected_total), tolerance = 1e-10)
})

test_that("Invariant 4: total_sgp equals rowSums of sgp_[cat] when include_raw = TRUE", {
  # sgp() uses na.rm = FALSE for total_sgp (NA propagates intentionally).
  # In mixed hitter/pitcher pools, total_sgp will be NA for all players
  # because every player is missing at least one stat column.
  # The invariant: total_sgp == rowSums(sgp_[cat], na.rm = FALSE) holds.
  # Both sides are NA — expect_equal handles NA equality correctly.
  fx     <- make_par_counting_fixture()
  result <- par(fx$replacement, fx$denominators,
                league_history = fx$league_history, include_raw = TRUE)
  scored_cats   <- c("HR", "R", "SB", "K", "SV")
  sgp_col_names <- paste0("sgp_", scored_cats)
  expected_total <- rowSums(result[, sgp_col_names, drop = FALSE], na.rm = FALSE)
  expect_equal(result$total_sgp, unname(expected_total), tolerance = 1e-10)
})

test_that("Invariant 5: include_raw = TRUE par_[cat] == include_raw = FALSE par_[cat]", {
  fx          <- make_par_counting_fixture()
  r_false     <- par(fx$replacement, fx$denominators,
                     league_history = fx$league_history, include_raw = FALSE)
  r_true      <- par(fx$replacement, fx$denominators,
                     league_history = fx$league_history, include_raw = TRUE)
  scored_cats <- c("HR", "R", "SB", "K", "SV")

  for (cat in scored_cats) {
    col <- paste0("par_", cat)
    expect_equal(r_false[[col]], r_true[[col]], tolerance = 1e-10,
                 label = paste("par_", cat, "consistent across include_raw"))
  }
  expect_equal(r_false$total_par, r_true$total_par, tolerance = 1e-10)
})

# ---------------------------------------------------------------------------
# §5 Error-Path Tests
# ---------------------------------------------------------------------------

test_that("AC-6: Missing projections attr → rotostats_error_missing_replacement_attrs", {
  fx          <- make_par_counting_fixture()
  bad_repl    <- fx$replacement
  attr(bad_repl, "projections") <- NULL

  expect_error(
    par(bad_repl, fx$denominators, league_history = fx$league_history),
    class = "rotostats_error_missing_replacement_attrs"
  )
})

test_that("AC-6b: Missing config attr → rotostats_error_missing_replacement_attrs", {
  fx          <- make_par_counting_fixture()
  bad_repl    <- fx$replacement
  attr(bad_repl, "config") <- NULL

  expect_error(
    par(bad_repl, fx$denominators, league_history = fx$league_history),
    class = "rotostats_error_missing_replacement_attrs"
  )
})

test_that("replacement_from_prices()-like NULL projections → rotostats_error_missing_replacement_attrs", {
  fx               <- make_par_counting_fixture()
  mock_prices_repl <- fx$replacement
  attr(mock_prices_repl, "projections") <- NULL

  expect_error(
    par(mock_prices_repl, fx$denominators, league_history = fx$league_history),
    class = "rotostats_error_missing_replacement_attrs"
  )
})

test_that("Attribute check fires BEFORE other validation", {
  fx          <- make_par_counting_fixture()
  bad_repl    <- fx$replacement
  attr(bad_repl, "projections") <- NULL

  # Should fail with missing_replacement_attrs, NOT invalid_rate_conversion
  expect_error(
    par(bad_repl, fx$denominators, rate_conversion = "not_a_method",
        league_history = fx$league_history),
    class = "rotostats_error_missing_replacement_attrs"
  )
})

test_that("AC-9: Category mismatch → rotostats_error_category_mismatch", {
  fx       <- make_par_counting_fixture()
  bad_repl <- fx$replacement
  # Remove HR from replacement_stats so it no longer covers all denominators categories
  bad_repl$replacement_stats[["HR"]] <- NULL

  expect_error(
    par(bad_repl, fx$denominators, league_history = fx$league_history),
    class = "rotostats_error_category_mismatch"
  )
})

test_that("sgp() warnings propagate from par() (missing category column in projections)", {
  fx              <- make_par_counting_fixture()
  bad_replacement <- fx$replacement
  proj_attr       <- attr(bad_replacement, "projections")
  proj_attr[["HR"]] <- NULL  # remove HR from projections only; replacement_stats and denominators unchanged
  attr(bad_replacement, "projections") <- proj_attr
  # Step 1b passes: HR is still in names(replacement$replacement_stats)
  # sgp() Step 8 sees missing HR column in projections -> emits rotostats_warning_missing_category_column

  expect_warning(
    par(bad_replacement, fx$denominators, league_history = fx$league_history),
    class = "rotostats_warning_missing_category_column"
  )
})

# ---------------------------------------------------------------------------
# §6 Warning-Path Tests
# ---------------------------------------------------------------------------

test_that("Band check fires on mis-calibrated replacement level", {
  fx           <- make_par_counting_fixture()
  miscal_repl  <- make_miscalibrated_replacement(fx, shift_n = 5)

  expect_warning(
    par(miscal_repl, fx$denominators, league_history = fx$league_history,
        boundary_threshold = 1.0),
    class = "rotostats_warning_band_check"
  )
})

test_that("Band check does NOT fire on well-calibrated replacement level", {
  fx <- make_par_counting_fixture()

  # Suppress the benign max(-Inf) warning from the stub league_history,
  # but re-raise any genuine band_check warning so the assertion can fail.
  withCallingHandlers(
    {
      expect_no_warning(
        par(fx$replacement, fx$denominators, league_history = fx$league_history,
            boundary_threshold = 1.0),
        class = "rotostats_warning_band_check"
      )
    },
    warning = function(w) {
      if (!inherits(w, "rotostats_warning_band_check")) {
        invokeRestart("muffleWarning")
      }
    }
  )
})

test_that("Band check warning message contains 'median' and 'boundary_threshold'", {
  fx          <- make_par_counting_fixture()
  miscal_repl <- make_miscalibrated_replacement(fx, shift_n = 5)

  captured_warning <- NULL
  withCallingHandlers(
    par(miscal_repl, fx$denominators, league_history = fx$league_history,
        boundary_threshold = 1.0),
    rotostats_warning_band_check = function(w) {
      captured_warning <<- w
      invokeRestart("muffleWarning")
    },
    warning = function(w) {
      invokeRestart("muffleWarning")
    }
  )

  expect_false(is.null(captured_warning),
               label = "A rotostats_warning_band_check must be emitted")
  expect_match(conditionMessage(captured_warning), "median", fixed = FALSE)
  expect_match(conditionMessage(captured_warning),
               "boundary_threshold|replacement", fixed = FALSE)
})

# ---------------------------------------------------------------------------
# §7 Rate Stat Tests
# ---------------------------------------------------------------------------

test_that("Rate stat sign check: ERA negation inherited from sgp()", {
  fx_rate  <- make_par_rate_fixture()
  result   <- suppressWarnings(
    par(fx_rate$replacement, fx_rate$denominators,
        league_history = fx_rate$league_history)
  )

  proj_used   <- attr(fx_rate$replacement, "projections")
  pitcher_idx <- which(!is.na(proj_used$ERA))

  best_pitcher_idx  <- which.min(proj_used$ERA[pitcher_idx])
  worst_pitcher_idx <- which.max(proj_used$ERA[pitcher_idx])

  expect_gt(result$par_ERA[pitcher_idx[best_pitcher_idx]],  0,
            label = "Best pitcher (lowest ERA) has positive par_ERA")
  expect_lt(result$par_ERA[pitcher_idx[worst_pitcher_idx]], 0,
            label = "Worst pitcher (highest ERA = 7.5) has negative par_ERA")
})

# ---------------------------------------------------------------------------
# §9 Regression Scenarios
# ---------------------------------------------------------------------------

test_that("R-1: Manual calculation verification with 3-player toy fixture", {
  # 3 players, 1-team, 1B only, HR denominator = 30.
  # IP = NA required by replacement_level().
  # With n_teams=1, K=3, K_eff = min(3, floor(3/4)) = 0: band size = 1
  # (boundary_rank = 1, band extends [1,1]).
  # Replacement HR = HR of rank-1 player (by band average of 1 player).
  # The delegation identity par_HR + repl_sgp[1B, HR] == sgp_HR must hold.

  toy_proj <- data.frame(
    player_id       = c("P1", "P2", "P3"),
    player_name     = c("Alice", "Bob", "Carol"),
    pos_eligibility = rep("1B", 3),
    team            = rep("NYY", 3),
    league          = rep("AL", 3),
    HR              = c(40, 25, 10),
    IP              = rep(NA_real_, 3),
    stringsAsFactors = FALSE
  )

  toy_cfg <- league_config(
    n_teams            = 1L,
    roster_slots       = c(`1B` = 1L),
    pitcher_slots      = c(SP = 0L, RP = 0L),
    batting_categories = c("HR"),
    # pitcher_categories supplied as a placeholder; this fixture only exercises
    # hitter HR. The placeholder ensures league_config() accepts the call.
    pitcher_categories = c("K"),
    league_type        = "AL"
  )

  toy_denoms <- c(HR = 30)
  attr(toy_denoms, "rate_conversion") <- "blended_pool"

  toy_lh <- list(team_season = data.frame(IP = 1000, AB = 4000))

  toy_repl <- replacement_level(toy_proj, config = toy_cfg)
  result   <- suppressWarnings(par(toy_repl, toy_denoms, league_history = toy_lh))

  # Delegation identity
  repl_sgp   <- attr(result, "replacement_sgp")
  raw_sgp    <- suppressWarnings(sgp(
    projections    = attr(toy_repl, "projections"),
    denominators   = toy_denoms,
    league_history = toy_lh,
    league_config  = toy_cfg
  ))
  pos_assign <- attr(toy_repl, "position_assignments")
  proj_used  <- attr(toy_repl, "projections")
  player_pos <- pos_assign[proj_used$PLAYER_ID]

  for (i in seq_len(nrow(proj_used))) {
    pos_i <- player_pos[i]
    if (!is.null(repl_sgp[[pos_i]]) && !is.na(repl_sgp[[pos_i]][["HR"]])) {
      computed <- result$par_HR[i] + repl_sgp[[pos_i]][["HR"]]
      expect_equal(computed, raw_sgp$sgp_HR[i], tolerance = 1e-6,
                   label = paste("toy R-1 delegation identity player", i))
    }
  }

  # total_par == par_HR (single category)
  expect_equal(result$total_par, result$par_HR, tolerance = 1e-6)

  # Verify raw sgp_HR values are exact (HR / 30)
  hr_vals <- attr(toy_repl, "projections")$HR
  expect_equal(raw_sgp$sgp_HR[1], hr_vals[1] / 30, tolerance = 1e-6)
  expect_equal(raw_sgp$sgp_HR[2], hr_vals[2] / 30, tolerance = 1e-6)
  expect_equal(raw_sgp$sgp_HR[3], hr_vals[3] / 30, tolerance = 1e-6)
})

test_that("R-1b: Delegation identity holds for 10-player toy fixture", {
  # 10 players, 1-team, 1B only, HR denominator = 30.
  n <- 10
  hr_vals <- c(100, 50, 40, 30, 20, 15, 10, 8, 5, 2)

  toy10_proj <- data.frame(
    player_id       = paste0("P", seq_len(n)),
    player_name     = paste0("Player", seq_len(n)),
    pos_eligibility = rep("1B", n),
    team            = rep("NYY", n),
    league          = rep("AL", n),
    HR              = hr_vals,
    IP              = rep(NA_real_, n),
    stringsAsFactors = FALSE
  )

  toy10_cfg <- league_config(
    n_teams            = 1L,
    roster_slots       = c(`1B` = 1L),
    pitcher_slots      = c(SP = 0L, RP = 0L),
    batting_categories = "HR",
    # pitcher_categories supplied as a placeholder; this fixture only exercises
    # hitter HR. The placeholder ensures league_config() accepts the call.
    pitcher_categories = "K",
    league_type        = "AL"
  )

  toy10_denoms <- c(HR = 30)
  attr(toy10_denoms, "rate_conversion") <- "blended_pool"
  toy10_lh <- list(team_season = data.frame(IP = 1000, AB = 4000))

  toy10_repl <- replacement_level(toy10_proj, config = toy10_cfg)
  result10   <- suppressWarnings(par(toy10_repl, toy10_denoms,
                                     league_history = toy10_lh))

  # Delegation identity for all 10 players
  repl_sgp   <- attr(result10, "replacement_sgp")
  raw_sgp    <- suppressWarnings(sgp(
    projections    = attr(toy10_repl, "projections"),
    denominators   = toy10_denoms,
    league_history = toy10_lh,
    league_config  = toy10_cfg
  ))
  pos_assign <- attr(toy10_repl, "position_assignments")
  proj_used  <- attr(toy10_repl, "projections")
  player_pos <- pos_assign[proj_used$PLAYER_ID]

  for (i in seq_len(nrow(proj_used))) {
    pos_i <- player_pos[i]
    if (!is.null(repl_sgp[[pos_i]]) && !is.na(repl_sgp[[pos_i]][["HR"]])) {
      computed <- result10$par_HR[i] + repl_sgp[[pos_i]][["HR"]]
      expect_equal(computed, raw_sgp$sgp_HR[i], tolerance = 1e-6,
                   label = paste("R-1b delegation identity player", i))
    }
  }

  # total_par == par_HR
  expect_equal(result10$total_par, result10$par_HR, tolerance = 1e-6)
})
