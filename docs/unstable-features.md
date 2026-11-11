# Unstable features

A settings section headed by the "These features are unstable" notice holds a
feature that is off by default and may still change or break. Turning one on is
safe to undo; its behavior and its setting may change in a later release.

## Exit rule (proposed, the maintainer edits it)

A section leaves the notice by one of two routes.

- **Graduate**: it has shipped in 2 stable releases, has no open bug against it,
  and the maintainer has used it as a daily setting. The notice is removed, and
  the default stays or flips by an explicit decision recorded in the row.
- **Remove**: 3 stable releases with an open correctness bug and no fix planned.
  The feature and its keys are deleted. The old key joins the `legacy` list in
  `BetterCmdTab/App/Preferences.swift` only if a migration is needed.

A row with no decision after 3 stable releases is reviewed at the next release.

## Ledger

Every notice was added by commit `5ab7653` (2026-11-02), first tagged in
`26.8-beta.10`. No stable release contains a notice yet; the count of stable
releases starts at 26.8. Open issues are as of 2026-11-11.

| Section (file under `BetterCmdTab/Settings/`) | Settings | Since | Open issues | Exit criterion | Status |
|---|---|---|---|---|---|
| Fade (`AppearanceSettingsViewController.swift`) | `Switcher.fadeInDurationMs`, `Switcher.fadeOutDurationMs` | 26.8-beta.10, 2026-11-02 | none | No report of a panel that stays visible or flickers on a fast ⌘Tab for 2 stable releases | unstable |
| Trackpad swipe (`TrackpadSettingsViewController.swift`) | `Switcher.swipeMode`, `Switcher.swipeFingerCount`, `Switcher.swipeReverseDirection`, `Switcher.swipeCommitOnRelease`, `Switcher.swipeSensitivity` | 26.8-beta.10, 2026-11-02 | none | No report of a missed swipe or a swipe taken from Mission Control on macOS 26 for 2 stable releases | unstable |
| Repeat presses (`ShortcutsSettingsViewController.swift`) | `Switcher.directActivationCyclesWindows` | 26.8-beta.10, 2026-11-02 | none | No report of a repeat press landing on the wrong window for 2 stable releases | unstable |
| Starting selection (`SwitcherPanesViewController.swift`) | `Switcher.initialSelection` | 26.8-beta.10, 2026-11-02 | none | criterion: needs maintainer | unstable |
| Window shelf (`SwitcherPanesViewController.swift`) | `Switcher.windowShelf`, `Switcher.windowShelfSingleWindow` | 26.8-beta.10, 2026-11-02 | none | No report of a shelf listing a closed window or another app's windows for 2 stable releases | unstable |
| Handoff (`SwitcherPanesViewController.swift`) | `Switcher.handoffPlacement` | 26.8-beta.10, 2026-11-02 | none | The "Handoff item unresolved" log line is absent from every log attached to a report for 2 stable releases | unstable |
| One-hand letter jump (`SwitcherPanesViewController.swift`) | `Switcher.oneHandLetterHints` | 26.8-beta.10, 2026-11-02 | #194 (letter hints) | #194 closed, then no report of a letter that selects the wrong row for 2 stable releases | unstable |
| Home row letter jump (`SwitcherPanesViewController.swift`) | `Switcher.homeRowLetterHints` | 26.8-beta.10, 2026-11-02 | #194 (letter hints) | #194 closed, then no report of a letter that selects the wrong row for 2 stable releases | unstable |
| Input language (`SwitcherPanesViewController.swift`) | `Switcher.alwaysUseEnglishKeyboard` | 26.8-beta.10, 2026-11-02 | #304 (non-English layouts) | #304 closed, and shortcuts and search work with a non-Latin input source for 2 stable releases | unstable |
| Mouse release (`SwitcherPanesViewController.swift`) | `Switcher.clickOnMouseUp` | 26.8-beta.10, 2026-11-02 | none | criterion: needs maintainer | unstable |
| Current app, per shortcut (`ShortcutOptionsFormView.swift`) | `excludeCurrentApp` in `Switcher.shortcutOverrides` | 26.8-beta.10, 2026-11-02 | none | criterion: needs maintainer | unstable |
| Window shelf, per shortcut (`ShortcutOptionsFormView.swift`) | `windowShelf` in `Switcher.shortcutOverrides` | 26.8-beta.10, 2026-11-02 | none | Same feature and criterion as the Window shelf row above | unstable |

The release checklist reviews this table before every stable release.
