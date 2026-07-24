---
name: localize-strings
description: Keep Localizable.xcstrings in lockstep with the code. Use whenever code adds, edits, or removes any user-facing string, or when LocalizationCatalogTests fails.
---

# Localize strings

Every user-facing string ships translated in five locales. The catalog is
version-controlled JSON and `LocalizationCatalogTests` pins full coverage —
an English-only key fails the suite, it does not silently ship.

## 1. Use the localized form in code

User-facing text is `String(localized: "…")`; enum display names localize
too. A bare literal in UI code ships untranslated — wrap it.

## 2. Add the catalog entries

Edit `BetterCmdTab/Localizable.xcstrings` directly (it is JSON). For each new
key add translations for **all** of: `de`, `es`, `fr`, `pl`, `zh-Hans`. Copy
the exact JSON shape of a neighboring entry, keep keys sorted where the
surrounding file is sorted, and keep format specifiers (`%@`, `%d`, …)
identical across every locale — specifier drift is a test failure. Remove
catalog entries whose code key was deleted.

## 3. Verify

```bash
xcodebuild -scheme "BetterCmdTab Debug" -destination 'platform=macOS' test \
  -only-testing:BetterCmdTabTests/LocalizationCatalogTests
```

**Complete when:** the suite passes with the new keys present in all five
locales.
