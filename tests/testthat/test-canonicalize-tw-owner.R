test_that(".canonicalize_tw_owner trims whitespace", {
  expect_identical(.canonicalize_tw_owner("  PODHORZER  "), "PODHORZER")
})

test_that(".canonicalize_tw_owner uppercases simple last names", {
  expect_identical(.canonicalize_tw_owner("Podhorzer"), "PODHORZER")
})

test_that(".canonicalize_tw_owner alphabetizes partnership tokens", {
  expect_identical(.canonicalize_tw_owner("WOLF/COLTON"), "COLTON/WOLF")
  expect_identical(.canonicalize_tw_owner("COLTON/WOLF"), "COLTON/WOLF")
})

test_that(".canonicalize_tw_owner alphabetizes 3-way partnerships", {
  expect_identical(
    .canonicalize_tw_owner("WOLF/COLTON/SMITH"),
    "COLTON/SMITH/WOLF"
  )
})

test_that(".canonicalize_tw_owner applies aliases before tokenizing", {
  expect_identical(.canonicalize_tw_owner("Wolf and Colton"), "COLTON/WOLF")
  expect_identical(.canonicalize_tw_owner("Van RIPER"), "VANRIPER")
  expect_identical(.canonicalize_tw_owner("VAN RIPER"), "VANRIPER")
  expect_identical(.canonicalize_tw_owner("VanRiper"), "VANRIPER")
})

test_that(".canonicalize_tw_owner is idempotent", {
  inputs <- c("PODHORZER", "COLTON/WOLF", "VANRIPER", "WOLF/COLTON/SMITH")
  for (x in inputs) {
    expect_identical(.canonicalize_tw_owner(.canonicalize_tw_owner(x)), .canonicalize_tw_owner(x))
  }
})

test_that(".canonicalize_tw_owner errors on NA or empty", {
  expect_error(.canonicalize_tw_owner(NA_character_), class = "rotostats_error_owner_blank")
  expect_error(.canonicalize_tw_owner(""), class = "rotostats_error_owner_blank")
})
