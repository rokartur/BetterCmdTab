import Darwin
import Foundation
import os

/// Best-effort restoration of the WindowServer symbolic hotkeys (⌘Tab, ⌘⇧Tab,
/// ⌘`) that we disable at runtime via `PrivateAPI.setSymbolicHotKey`.
///
/// That disable **persists after the process dies** (see `PrivateAPI`), so if we
/// crash or are signalled before `SwitcherController.shutdown()` runs, the user's
/// native ⌘Tab stays dead system-wide until reboot or our next launch. This
/// installs signal + `atexit` handlers that re-enable whatever we last disabled.
///
/// SIGKILL and a hard power loss cannot be caught — those are covered by the
/// unconditional startup self-heal in `SwitcherController.start()`, which clears
/// any stale disable on the next launch.
///
/// Restore contract by context:
/// - **Clean exit** (`exit`/return from `main`): the `atexit` hook runs in a
///   normal thread context and performs the WindowServer IPC to re-enable the
///   keys synchronously — ⌘Tab is live again immediately.
/// - **In-session signal** (SIGTERM/SIGINT/SIGHUP, e.g. `kill -TERM`): the
///   handler does **not** call back into the WindowServer. That IPC
///   (`CGSSetSymbolicHotKeyEnabled` → synchronous mach/XPC to the WindowServer)
///   is not async-signal-safe: if the signal interrupts a thread holding a CGS
///   lock or mid-allocation, the in-handler IPC can deadlock the quit path. So
///   the handler only re-raises with the default disposition (`SA_RESETHAND`)
///   to let termination proceed. The disabled set was already persisted to
///   UserDefaults on every change (`persistDisabledSymbolicKeys`), so native
///   ⌘Tab is re-enabled by the unconditional `healStaleSymbolicHotkeyDisable()`
///   on the next launch — not in the handler.
/// - **Crash** (SIGSEGV/SIGBUS/...) and **SIGKILL**/power loss: not caught at
///   all; healed by the same next-launch self-heal.
///
/// Because this is a launch-at-login menu-bar app, "next launch" is normally
/// imminent. The trade-off is that a `kill -TERM` (or any in-session signal)
/// leaves native ⌘Tab disabled until that next launch rather than restoring it
/// in the handler.
enum SymbolicHotkeyGuard {
    /// Max managed keys: ⌘Tab, ⌘⇧Tab, ⌘`.
    private static let capacity = 3

    private struct State {
        var disabled: [Int32] = []
        var installed = false
    }

    /// Neither the signal handler nor any async-signal context touches this
    /// state. Normal controller/atexit paths may run on different threads,
    /// however, so keep the install flag and disabled-key snapshot synchronized.
    /// This also replaces the old manually allocated, never-freed slot buffer.
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Record the raw symbolic-hotkey ids currently disabled so the normal
    /// `atexit` path knows what to restore. Call on every change to the disabled
    /// set (disable *and* the empty set on clean re-enable).
    static func setDisabled(_ rawIds: [Int32]) {
        state.withLock { value in
            value.disabled = Array(rawIds.prefix(capacity))
        }
    }

    /// Re-enable every recorded slot via the WindowServer IPC. **Normal context
    /// only** — this is the `atexit` path. It is *not* async-signal-safe (the IPC
    /// can block on a CGS lock) and must never be called from a signal handler;
    /// signal-context restoration is delegated to the next-launch self-heal.
    private static func restore() {
        let disabled = state.withLock { $0.disabled }
        for raw in disabled {
            guard let key = PrivateAPI.SymbolicHotKey(rawValue: raw) else { continue }
            _ = PrivateAPI.setSymbolicHotKey(key, enabled: true)
        }
    }

    /// Install the signal + `atexit` handlers once. Idempotent. Call early in
    /// app startup, before any symbolic hotkey gets disabled.
    static func install() {
        let shouldInstall = state.withLock { value -> Bool in
            guard !value.installed else { return false }
            value.installed = true
            return true
        }
        guard shouldInstall else { return }

        atexit { SymbolicHotkeyGuard.restore() }

        // Graceful terminations only. SA_RESETHAND restores the default
        // disposition before the handler runs, so the trailing `raise` performs
        // the normal action (terminate) — without it the signal would be
        // swallowed and the process would keep running.
        // The handler does the minimum async-signal-safe work: re-raise so the
        // (now-default, thanks to SA_RESETHAND) disposition terminates the
        // process. It deliberately does NOT call `restore()` — that IPC is not
        // async-signal-safe; in-session signal cases rely on the next-launch
        // `healStaleSymbolicHotkeyDisable()` instead.
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { sig in
            raise(sig)
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESETHAND
        for s in [SIGTERM, SIGINT, SIGHUP] {
            sigaction(s, &action, nil)
        }
    }
}
