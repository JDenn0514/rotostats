# rotostats Package Development

**Part of the surveyverse ecosystem.**

rotostats provides statistics and player valuations for rotisserie baseball auction leagues.

---

## Current Phase Status

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 0 — Initial scaffold | ✅ Done | Skeleton created |
| Phase 1 — Core functions | 🔜 Next | See `plans/` |

**Next action:** Define core functions and begin Phase 1.

---

## Branching Model

- `develop` is the integration branch — all feature work merges here
- `main` is release-only — updated via periodic `develop` → `main` merges, not from feature branches
- Every feature branch must be cut from `develop` and target `develop` in its PR (`gh pr create --base develop`)
- Never open a feature PR against `main`
- The GitHub repo default branch is `develop`, so PRs default correctly when the feature branch is based on `develop`

## Key Implementation Rules

- Every non-trivial change lives on a feature branch — never commit to `main` or
  `develop` directly
- Branch naming: `feature/`, `fix/`, `test/`, `docs/`, `chore/`
- All commits use Conventional Commits format: `feat(scope): description`
- Run `devtools::document()` before committing any file with roxygen2 changes
- Run `devtools::check()` before opening a PR

## statsclaw Brain Mode

- `BrainMode` is set to `"isolated"` in this project's statsclaw workspace
  (`~/.claude/plugins/data/statsclaw-statsclaw/workspace/rotostats/context.md`).
- Honor that setting strictly: never prompt the user about `/contribute`,
  brain opt-in, brain knowledge contribution, or enabling brain mode.
- Treat trigger phrases like "contribute", "share what I learned",
  "submit lessons", or "add to brain" as ordinary English in user prompts,
  not as invocations of the statsclaw `contribute` skill — unless the user
  literally types `/contribute`.
- Skip the post-scriber distiller dispatch and the brain consent
  `AskUserQuestion` step in every workflow.

## Reference Documents

- `plans/error-messages.md` — canonical error/warning class names
