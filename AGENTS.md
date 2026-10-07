## Project priority: performance first

This is a ⌘Tab hot-path app, so performance and minimal resource usage come first in every
change. When two designs are equally correct, ship the cheaper one.

Rules for app code (platform, hot path, logging, strings, preferences, tests, commits) live in
`CODING_STANDARDS.md`; read it before any change under `BetterCmdTab/`.

## Build / test / run

`CONTRIBUTING.md` has the build and whole-suite test commands and which suites need a live
WindowServer. To run one suite or case, address the Swift Testing function by its bare name
(`noMatch`, `appNameSubsequence`); there are no `testXxx()` methods:

```bash
xcodebuild -scheme "BetterCmdTab Debug" -destination 'platform=macOS' \
  test -only-testing:BetterCmdTabTests/FuzzyMatchTests/noMatch
```

The switcher boots only after Accessibility is granted (System Settings → Privacy & Security),
so no unit test reaches it, and a running app whose ⌘Tab does nothing is missing that grant.

## Where the rest lives

- **Architecture**: `ARCHITECTURE.md` maps the ⌘Tab hot path (tap thread, Secure Event Input,
  catalog cache) and the preferences pipeline (direct `UserDefaults` reads, export/import,
  config file). Read it before touching `Input/`, `Catalog/`, `Switcher/`, `Windows/`,
  `App/Preferences.swift` or `App/ConfigFile.swift`.
- **Site**: `web/` and `docs/` are the public site, separate from the app. Their rules
  (trailing slashes, sitemap, robots, `web/serve.ts`) live in `docs/CONTRIBUTING.md`; read it
  before touching either directory.
