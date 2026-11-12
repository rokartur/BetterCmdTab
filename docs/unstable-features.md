# Unstable features

A settings section headed by the "These features are unstable" notice holds a
feature that is off by default and may still change or break. Its behavior and
its setting may change in a later release.

## Exit rule

A section leaves the notice by one of two routes, and its row leaves this table
in the same change.

- **Graduate**: it has shipped in 2 stable releases, has no open bug labelled against it,
  and the maintainer has used it as a daily setting. The notice is removed, and
  the default stays or flips by an explicit decision recorded in that commit.
- **Remove**: 3 stable releases with an open correctness bug and no fix planned.
  The feature and its keys are deleted. The old key becomes a `legacy*` constant in
  `Keys` in `BetterCmdTab/App/Preferences.swift` only if a migration is needed.

A row with no decision after 3 stable releases is reviewed at the next release.

## Ledger

Every notice but Newly launched apps was added by commit `5ab7653` (2026-11-02), first tagged in
`26.8-beta.10`. No stable release contains a notice yet; the count of stable
releases starts at 26.8. Open issues are as of 2026-11-11.

| Section (file under `BetterCmdTab/Settings/`) | Settings | Open issues | Exit criterion |
| --- | --- | --- | --- |
| Fade (`AppearanceSettingsViewController.swift`) | `Switcher.fadeInDurationMs`, `Switcher.fadeOutDurationMs` | none | No report of a panel that stays visible or flickers on a fast ⌘Tab for 2 stable releases |
| Trackpad swipe (`TrackpadSettingsViewController.swift`) | `Switcher.experimentalSwipeTrigger`, `Switcher.swipeMode`, `Switcher.swipeFingerCount`, `Switcher.swipeReverseDirection`, `Switcher.swipeCommitOnRelease`, `Switcher.swipeSensitivity` | none | No report of a missed swipe or a swipe taken from Mission Control on macOS 26 for 2 stable releases |
| Repeat presses (`ShortcutsSettingsViewController.swift`) | `Switcher.directActivationCyclesWindows` | none | No report of a repeat press landing on the wrong window for 2 stable releases |
| Starting selection (`SwitcherPanesViewController.swift`) | `Switcher.initialSelection` | none | No report of a first ⌘Tab that selects a row other than the chosen setting for 2 stable releases |
| Newly launched apps (`SwitcherPanesViewController.swift`) | `Switcher.launchedAppsNearTop` | none | No report of a launched app listed last, or of a background helper pushing a used app down, for 2 stable releases |
| Window shelf (`SwitcherPanesViewController.swift`, per shortcut in `ShortcutOptionsFormView.swift`) | `Switcher.windowShelf`, `Switcher.windowShelfSingleWindow`, `windowShelf` in `Switcher.shortcutOverrides` | none | No report of a shelf listing a closed window or another app's windows for 2 stable releases |
| Handoff (`SwitcherPanesViewController.swift`) | `Switcher.handoffPlacement` | none | The "Handoff item unresolved" log line is absent from every log attached to a report for 2 stable releases |
| One-hand and home row letter jump (`SwitcherPanesViewController.swift`) | `Switcher.oneHandLetterHints`, `Switcher.homeRowLetterHints` | #194 (letter hints) | #194 closed, then no report of a letter that selects the wrong row for 2 stable releases |
| Input language (`SwitcherPanesViewController.swift`) | `Switcher.alwaysUseEnglishKeyboard` | #304 (non-English layouts) | #304 closed, and shortcuts and search work with a non-Latin input source for 2 stable releases |
| Mouse release (`SwitcherPanesViewController.swift`) | `Switcher.clickOnMouseUp` | none | No report of a click that activates the wrong row, or none, for 2 stable releases |
| Current app, per shortcut (`ShortcutOptionsFormView.swift`) | `excludeCurrentApp` in `Switcher.shortcutOverrides` | none | No report of the current app listed, or another app missing, under a shortcut with the option on for 2 stable releases |
| Show as one entry, per app (`AppRuleRow.swift`, notice in the info text) | `groupWindows` in `Switcher.appExceptions` | none | No report of a grouped app listed as several entries, or activating the wrong window, for 2 stable releases |

The release skill (`.agents/skills/release/SKILL.md`, step 2) reviews this table before every stable release.
