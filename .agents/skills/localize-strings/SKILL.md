---
name: localize-strings
description: Keep the string catalogs (Localizable.xcstrings, InfoPlist.xcstrings) in lockstep with the code. Use whenever code adds, edits, or removes any user-facing string or Info.plist usage description, or when LocalizationCatalogTests fails.
---

# Localize strings

Every user-facing string ships translated in seven locales. The catalog is
version-controlled JSON and `LocalizationCatalogTests` pins full coverage —
an English-only key fails the suite, it does not silently ship.

## 1. Use the localized form in code

User-facing text is `String(localized: "…")`; enum display names localize
too. A bare literal in UI code ships untranslated — wrap it.

## 2. Add the catalog entries

Edit `BetterCmdTab/Localizable.xcstrings` directly (it is JSON). For each new
key add translations for **all** of: `de`, `es`, `fr`, `ja`, `pl`, `ru`, `zh-Hans`.
Copy the exact JSON shape of a neighboring entry, keep keys sorted where the
surrounding file is sorted, and keep format specifiers (`%@`, `%d`, …)
identical across every locale — specifier drift is a test failure. Remove
catalog entries whose code key was deleted.

Info.plist strings live in `BetterCmdTab/InfoPlist.xcstrings` and the same
suite covers them, with two extra rules.

Key a usage description by its **plist key name**
(`NSAppleEventsUsageDescription`), not by its English value — the value form
compiles fine and never resolves at runtime. Document-type names
(`CFBundleTypeName`, `UTTypeDescription`) are the exception: those are keyed
by value.

Every key in this catalog also needs an explicit `en` entry. A key-named one
has no other source of English: without it Xcode emits the key as its own
value and the prompt reads `NSAppleEventsUsageDescription`. For a value-keyed
one it is redundant, but the test requires it uniformly.

Keep that `en` value byte-identical to its source — the `INFOPLIST_KEY_*`
build setting in `project.pbxproj` (both configurations) for key-named
entries, `BetterCmdTab/Info.plist` for document-type names.
`en.lproj/InfoPlist.strings` overrides Info.plist, so editing only the build
setting changes nothing.

## 3. Verify

```bash
xcodebuild -scheme "BetterCmdTab Debug" -destination 'platform=macOS' test \
  -only-testing:BetterCmdTabTests/LocalizationCatalogTests
```

**Complete when:** the suite passes with the new keys present in all seven
locales.
