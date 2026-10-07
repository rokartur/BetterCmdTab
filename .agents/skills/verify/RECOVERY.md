# Recover an interrupted witness

Use this branch when `build/verify/state-path` exists, AppKit quit failed, or a
witness exited abnormally. Native ⌘Tab may remain disabled until the same
isolated state is launched again, so complete recovery before deleting state or
starting another BetterCmdTab process.

## 1. Reclaim the recorded run

Read the metadata; each path must remain under `build/verify/`:

```bash
VERIFY_ROOT="$PWD/build/verify"
STATE="$(cat "$VERIFY_ROOT/state-path")"
EXEC="$(cat "$VERIFY_ROOT/executable-path")"
BUNDLE_ID="$(cat "$VERIFY_ROOT/bundle-id")"
PID="$(cat "$VERIFY_ROOT/app.pid" 2>/dev/null || true)"
test -d "$STATE" && test -x "$EXEC"

REPO_REAL="$(realpath "$PWD")"
ROOT_REAL="$(realpath "$VERIFY_ROOT")"
STATE="$(realpath "$STATE")"
EXEC="$(realpath "$EXEC")"
test "$ROOT_REAL" = "$REPO_REAL/build/verify"
test "$(dirname "$STATE")" = "$ROOT_REAL"
case "$(basename "$STATE")" in state.*) ;; *) exit 1 ;; esac
case "$EXEC" in "$ROOT_REAL"/*) ;; *) exit 1 ;; esac
```

Make the recorded witness the only BetterCmdTab process. Ask before stopping an
installed copy and remember its executable path and original running state. If
the old witness still exists, first request AppKit termination by its exact PID
using the command in `SKILL.md`. A PID/bundle mismatch belongs to another
process and is never signalled. A forced stop is safe only after identity was
revalidated and when immediately followed by the same-state recovery launch.

**Complete when:** no BetterCmdTab process is running and the recorded state and
executable are intact.

## 2. Run startup self-heal

Disable both switcher triggers for this launch so startup restores the native
symbolic hotkeys without re-disabling them after Accessibility becomes ready.

```bash
XDG_CONFIG_HOME="$STATE/xdg" \
"$EXEC" \
  -GitHubUpdater.checkInterval manual \
  -BetterShortcuts_switchApps false \
  -BetterShortcuts_switchWindows false \
  >"$VERIFY_ROOT/recovery.stdout.log" 2>&1 &
RECOVERY_PID=$!
printf '%s\n' "$RECOVERY_PID" >"$VERIFY_ROOT/app.pid"

swift -e 'import AppKit
import Darwin
import Foundation
let pid = pid_t(CommandLine.arguments[1])!
let deadline = Date().addingTimeInterval(10)
while Date() < deadline {
  if NSRunningApplication(processIdentifier: pid)?.isFinishedLaunching == true {
    exit(0)
  }
  Thread.sleep(forTimeInterval: 0.1)
}
exit(1)
' "$RECOVERY_PID"
```

`applicationDidFinishLaunching` runs the self-heal before the
Accessibility-gated controller. A new Accessibility prompt needs no grant for
recovery.

**Complete when:** the recovery process finished launching and native macOS
⌘Tab appears when driven once with the recovery process still running.

## 3. Quit and clear recovery state

Request AppKit termination for `RECOVERY_PID` with the exact-PID command in
`SKILL.md` and wait for it to disappear. Then put back the user's defaults
(`defaults import` merges, so delete the domain first) and remove only the
validated generated state:

```bash
if test -f "$STATE/user-defaults.plist"; then
  defaults delete "$BUNDLE_ID"
  defaults import "$BUNDLE_ID" "$STATE/user-defaults.plist"
fi
rm -rf "$STATE"
rm -f \
  "$VERIFY_ROOT/state-path" \
  "$VERIFY_ROOT/executable-path" \
  "$VERIFY_ROOT/bundle-id" \
  "$VERIFY_ROOT/app.pid"
```

Restore the exact installed app only when it was running before recovery.

**Complete when:** native ⌘Tab worked before restoration, the user's defaults
match the snapshot, the recovery process and metadata are gone, and the
installed app has its original running/stopped state.
