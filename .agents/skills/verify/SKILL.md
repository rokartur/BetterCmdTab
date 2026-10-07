---
name: verify
description: Witness BetterCmdTab product-source changes at the live macOS surface when a diff needs end-to-end runtime evidence.
---

# Verify BetterCmdTab

A **witness** is a captured observation from the freshly built app after real
user input crosses every changed seam. Build and test results are setup; the
witness decides the verdict.

## 1. Bind the claim

Fix the scope as an explicit `BASE..TARGET` range or as the working tree.
Inventory committed, staged, unstaged, and untracked files with the matching
`git diff --name-status` commands plus
`git ls-files --others --exclude-standard`. Map every changed product file to:

1. the user action that reaches it; and
2. the observable outcome that should change or remain unchanged.

Treat tests as specifications for what to drive. A diff with no runtime surface
(docs, tests, or compile-time metadata only) is `SKIP`.

**Complete when:** the range is stated and every inventoried product file
belongs to one runtime claim or has an explicit non-runtime reason.

## 2. Build and launch a witness process

Use the Debug lane by default. Use the Release lane for Liquid Glass/macOS 26,
release-configuration, or performance claims. Signing, notarization, and
updater installation are approval-gated release work outside this skill; return
`BLOCKED` and ask before invoking release tooling. An ordinary Xcode Release
build is not evidence for them.

```bash
VERIFY_ROOT="$PWD/build/verify"
SCHEME="BetterCmdTab Debug"
CONFIGURATION="Debug"
PRODUCT="BetterCmdTab Debug"
BUNDLE_ID="pro.bettercmdtab.BetterCmdTab.debug"

# Release lane:
# SCHEME="BetterCmdTab"; CONFIGURATION="Release"; PRODUCT="BetterCmdTab"
# BUNDLE_ID="pro.bettercmdtab.BetterCmdTab"

DERIVED_DATA="$VERIFY_ROOT/DerivedData-$CONFIGURATION"
mkdir -p "$VERIFY_ROOT"
if ! xcodebuild -project BetterCmdTab.xcodeproj \
  -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" build \
  >"$VERIFY_ROOT/build.log" 2>&1; then
  tail -80 "$VERIFY_ROOT/build.log"
  exit 1
fi

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$PRODUCT.app"
EXEC="$APP/Contents/MacOS/$PRODUCT"
test -x "$EXEC"
```

Every BetterCmdTab process installs global handlers. Before launch, identify all
running BetterCmdTab processes. Gracefully clean up a recorded prior witness;
if an installed copy is running, ask before quitting it, record its executable
path and running state, and restore that exact copy afterward. A declined quit
makes runtime verification `BLOCKED`.

Launch the bundle executable directly with its own XDG config. UserDefaults cannot
be redirected: the witness reads and writes the user's real `$BUNDLE_ID` domain
(`CFFIXED_USER_HOME` does not move it). So snapshot that domain once, and restore
it in step 4. At the first launch of a verification session, an existing
`state-path` means the prior run needs [recovery](RECOVERY.md).

```bash
test ! -e "$VERIFY_ROOT/state-path" || {
  echo "Recover the prior witness first: $VERIFY_ROOT/state-path" >&2
  exit 1
}
STATE="$(mktemp -d "$VERIFY_ROOT/state.XXXXXX")"
printf '%s\n' "$STATE" >"$VERIFY_ROOT/state-path"
printf '%s\n' "$EXEC" >"$VERIFY_ROOT/executable-path"
printf '%s\n' "$BUNDLE_ID" >"$VERIFY_ROOT/bundle-id"
mkdir -p "$STATE/xdg"
defaults export "$BUNDLE_ID" "$STATE/user-defaults.plist"
```

Launch, and relaunch after an intentional restart, with the same line. Set each
setting the claim needs as a launch argument in plist syntax (`'<true/>'`,
`'<integer>1500</integer>'`, `'<string>x</string>'`); a bare `YES` arrives as a string and
every `as? Bool` read ignores it. Keep `hideFromScreenSharing` off, or the panel
is missing from every capture.

```bash
XDG_CONFIG_HOME="$STATE/xdg" \
"$EXEC" -GitHubUpdater.checkInterval manual \
  -Switcher.hideFromScreenSharing '<false/>' \
  >"$VERIFY_ROOT/app.stdout.log" 2>&1 &
echo $! >"$VERIFY_ROOT/app.pid"
```

Open Settings through the recorded process with:

```bash
osascript -e "tell application id \"$BUNDLE_ID\" to reopen"
```

The switcher becomes ready only after Accessibility trust. Panel appearance
after the real chord is the readiness check. If macOS prompts for Accessibility
or Automation, ask whether to grant it; the grant is persistent shared TCC
state and belongs in the report. Without approval, return `BLOCKED`; preserve
TCC as-is.

**Complete when:** the recorded PID resolves to `EXEC` and is the sole
BetterCmdTab process, the intended surface is drivable, the user's defaults are
snapshotted and the XDG config is isolated, and any TCC change was approved.

## 3. Drive the changed seam

Reach the behavior through its real boundary: CGEvent/Carbon input, an AppKit
control, a watched file, or an Accessibility window action. Calling an internal
Swift function is a test, not a witness.

| Changed area | Drive | Witness |
| --- | --- | --- |
| `App/`, `System/` | Fresh launch, reopen, menu action, or relevant permission transition. Open the status menu with System Events `click menu bar item 1 of menu bar 1` of the app process, backgrounded with `&` since the click blocks until the menu closes (an `.accessory` app has no `menu bar 2`) | Window/menu/lifecycle state and filtered unified-log lines |
| `Input/`, `Switcher/` | Hold and send the actual configured chord with System Events; use a real password field for Secure Event Input and ask the user for a real trackpad gesture | Cropped panel capture plus the selected/cancelled app or window outcome |
| `Settings/`, `Preferences` | Reopen Settings, operate the control, restart with the same launch line, then exercise its downstream behavior | Restored control state and the changed live behavior |
| `Catalog/`, `Windows/` | Prepare named real apps/windows, open the switcher, then select or act on one | Visible rows and resulting frontmost app/window state |
| `ConfigFile`, import/export | Seed `$STATE/xdg/bettercmdtab/config.json` or use the real import/export UI | File contents and the live setting/behavior after reload |
| updater/About | Use the manual UI action against a safe target | UI result and relevant unified-log lines |
| hot-path performance | Use separate clean base/target worktrees and SHA-specific Release build/state roots; drive identical seeded scenarios under Instruments with `Log.reveal` | Equal sample counts and median/p95 latency, CPU, or allocation numbers |

For each independent claim, drive the claimed path and one adjacent probe:
cancel, repeat, stale state, empty input, rapid input, or the neighboring error
case. Inspect visual captures for clipping, stale/blank frames, focus, and
contrast. A changed macOS 13 fallback requires a real macOS 13 host/VM;
otherwise that claim is `BLOCKED`.

Destructive actions use a temporary target or dry run. Publishing, notarizing,
installing an update, deleting user data, or changing shared system state
requires approval before the action.

**Complete when:** every runtime claim has an observed expected outcome and its
own adjacent probe has an observed outcome at the same surface.

## 4. Preserve evidence and restore the machine

Capture the smallest useful window/region with `screencapture`; read every image
before using it as evidence. Capture nonvisual outcomes from app state or
Unified Logging filtered to the witness process. Keep the relevant output
inline; a local path alone is not evidence for a remote reader.

Request a graceful AppKit quit for the exact recorded PID, then wait for it to
disappear:

```bash
VERIFY_ROOT="$PWD/build/verify"
ROOT_REAL="$(realpath "$VERIFY_ROOT")"
test "$ROOT_REAL" = "$(realpath "$PWD")/build/verify"
PID="$(cat "$VERIFY_ROOT/app.pid")"
EXEC="$(realpath "$(cat "$VERIFY_ROOT/executable-path")")"
case "$EXEC" in "$ROOT_REAL"/*) ;; *) exit 1 ;; esac
swift -e 'import AppKit
import Darwin
import Foundation
func normalized(_ url: URL) -> String {
  url.resolvingSymlinksInPath().standardizedFileURL.path
}
let pid = pid_t(CommandLine.arguments[1])!
let executable = URL(fileURLWithPath: CommandLine.arguments[2])
let bundle = executable.deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()
guard let app = NSRunningApplication(processIdentifier: pid),
      let actualBundle = app.bundleURL,
      normalized(actualBundle) == normalized(bundle) else {
  fatalError("Recorded PID no longer belongs to the witness")
}
guard app.terminate() else { fatalError("AppKit termination request failed") }
let deadline = Date().addingTimeInterval(5)
while !app.isTerminated && Date() < deadline {
  RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
exit(app.isTerminated ? 0 : 1)
' "$PID" "$EXEC"
```

Signals bypass in-process symbolic-hotkey restoration. If AppKit quit fails or
the process vanished abnormally, follow [RECOVERY.md](RECOVERY.md) before
removing state. After a clean quit, use the validated cleanup block in recovery
step 3, then restore the approved installed app path.

**Complete when:** each reported step has reviewed evidence, the witness PID is
gone after AppKit quit or recovery, the user's defaults are restored, state
metadata is removed, native ⌘Tab works, and the installed app has its original
running/stopped state.

## 5. Report the verdict

```markdown
## Verification: <one-line claim>

**Verdict:** PASS | FAIL | BLOCKED | SKIP
**Build:** <scheme/configuration, ref, executable path>
**Claim:** <expected user-visible behavior>

### Claim 1: <expected behavior>
1. ✅ <real action> → <observation and evidence>
2. 🔍 <adjacent probe> → <observation and evidence>

<Repeat per independent claim.>

**Witness:** <attached screenshots or inline state/log excerpts>
**Findings:** <runtime surprises, friction, or “none”>
```

- `PASS`: every claim was witnessed and the probe held.
- `FAIL`: the running app contradicted a claim, regressed adjacent behavior, or
  produced ambiguous evidence.
- `BLOCKED`: the surface could not be reached; include the exact build,
  permission, automation, or environment failure.
- `SKIP`: no runtime surface exists; give the reason in one line.

**Complete when:** the verdict follows these definitions, every claim from step
1 is accounted for, and the evidence reaches the reader.
