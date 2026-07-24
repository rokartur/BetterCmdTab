---
name: release
description: Ship a BetterCmdTab release end to end. Use when the user wants a new version or beta published on GitHub.
---

# Release runbook

One command does the heavy lifting; this skill is the order of operations and
the failure points around it.

## 1. Preflight

Working tree clean on `main`, and the unit suite green:

```bash
xcodebuild -scheme "BetterCmdTab Debug" -destination 'platform=macOS' test
```

`scripts/set_version.sh --show` prints the current version. `MAJOR` tracks
the macOS year; tags are bare (`26.4.3`, `26.0-beta.1` — no `v` prefix on new
tags).

## 2. Bump the version (stable releases)

```bash
scripts/set_version.sh <version>   # sets MARKETING_VERSION and auto-commits "chore: bump …"
```

Skip for betas — `build_release.sh --beta` derives the next `beta.N` from
existing GitHub tags itself.

## 3. Write the notes

Produce the release body with the `release-changelog` skill and save it to a
file (e.g. `notes.md` in the scratchpad). The body **is** the GitHub Release
description; its headings are parsed by `build_release.sh`, so the canonical
structure from that skill is mandatory.

## 4. Build, sign, notarize, publish

```bash
scripts/build_release.sh --auto-release --notes notes.md          # stable
scripts/build_release.sh --beta --auto-release --notes notes.md   # beta (published as prerelease)
```

Step 0 is `scripts/release_quality_gate.sh`: a Release-configuration compile
that fails on high-risk concurrency/Sendable warnings, plus (stable only) the
localization audit — fix the reported issue, don't bypass the gate; it exists
so a known-bad build never burns an archive + notarization slot. Signing
needs the `Developer ID Application: Artur Rok (N529W98U62)` certificate and
the `BetterCmdTabNotarization` notarytool profile. Without them use
`--skip-notarization` (dev build only — it refuses `--auto-release`).

Artifacts land in `build/release/`. Each build stamps a fresh
`CURRENT_PROJECT_VERSION` (app target only); `--skip-build-bump` disables
that.

## 5. If publishing manually

When not using `--auto-release`:

```bash
gh release create <tag> -R rokartur/BetterCmdTab \
  --title "BetterCmdTab <version>" --notes-file notes.md   # add --prerelease for betas
```

**Complete when:** the GitHub release exists with the notarized artifacts
attached and the notes match the release-changelog format.
