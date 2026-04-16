# tests/testthat/helper-test-data.R
#
# Shared test infrastructure loaded automatically by testthat.
# Provides:
#   - make_rotostats_data()   — synthetic data generator
#   - test_invariants()       — invariant checker

#' @keywords internal
make_rotostats_data <- function(n = 100L, seed = 42L) {
  set.seed(seed)
  data.frame(
    player = paste0("Player", seq_len(n)),
    stat   = rnorm(n),
    value  = runif(n, 1, 40)
  )
}

#' @keywords internal
test_invariants <- function(obj) {
  expect_true(!is.null(obj))
}
