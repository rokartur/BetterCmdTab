# Coding standards

Rules for any change to app code under `BetterCmdTab/`.

## Platform

- AppKit only.
- The deployment target is macOS 13.0. Gate newer APIs with `if #available` and give the older
  path a working fallback.
- The only network traffic is the opt-in GitHub Releases update check.

## Performance

Everything on the ⌘Tab path (chord, catalog, panel open, cycle, activate) is hot. Keep it off
the main thread, or measure it. Allocate and poll outside the hot path. A dependency or a
background task needs a case that twenty lines cannot cover.

## Logging

Log through `Log.*` (`BetterCmdTab/System/Log.swift`).

## Strings

Every user-facing string, enum display names included, is `String(localized:)` with a catalog
entry per locale; the `localize-strings` skill is the procedure.

## Preferences

Hot-path code reads `Switcher.*` keys by their string straight off `UserDefaults`, and the
config file exports them, so a shipped key string is a contract that outlives any rename of
its Swift property. Adding or changing a setting follows the `add-preference` skill. A fragile
or new feature ships off by default, in its own section under a "These features are unstable"
notice.

## Tests

New pure-logic behavior ships with at least one test, written in Swift Testing
(`@Suite`/`@Test`), not XCTest.

## Commits and pull requests

- `type: short summary` (`fix:`, `feat:`, `perf:`, `refactor:`, `docs:`, `chore:`), body
  wrapped at ~72 columns and explaining why.
- One logical change per PR; a refactor travels separately from the behavior change it enables.
- The change builds with no new warnings.
