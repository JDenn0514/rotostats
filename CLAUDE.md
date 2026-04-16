# rotostats Package Development

**Part of the surveyverse ecosystem.**

rotostats provides statistics and player valuations for rotisserie
baseball auction leagues.

------------------------------------------------------------------------

## Current Phase Status

| Phase                      | Status  | Notes            |
|----------------------------|---------|------------------|
| Phase 0 — Initial scaffold | ✅ Done | Skeleton created |
| Phase 1 — Core functions   | 🔜 Next | See `plans/`     |

**Next action:** Define core functions and begin Phase 1.

------------------------------------------------------------------------

## Key Implementation Rules

- Every non-trivial change lives on a feature branch — never commit to
  `main` or `develop` directly
- Branch naming: `feature/`, `fix/`, `test/`, `docs/`, `chore/`
- All commits use Conventional Commits format:
  `feat(scope): description`
- Run `devtools::document()` before committing any file with roxygen2
  changes
- Run `devtools::check()` before opening a PR

## Reference Documents

- `plans/error-messages.md` — canonical error/warning class names
