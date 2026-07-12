import Foundation

/// Per-pid coalescing for focused-window resolves with no dropped trailing
/// change. A focus-change notification kicks an off-main AX resolve; more
/// notifications for the same pid arriving mid-flight used to be silently
/// dropped, so the *final* focused window could be missed entirely — e.g. an
/// app posting main-window-changed (old window) immediately before
/// focused-window-changed (new window) only ever resolved the old one (#85).
/// Instead of dropping, a mid-flight change is latched and the caller re-runs
/// one resolve once the flight lands, so a burst still costs at most two AX
/// round-trips but always converges on the latest state.
struct FocusSyncCoalescer {
    private var inFlight: Set<pid_t> = []
    private var pending: Set<pid_t> = []

    /// A focus change arrived for `pid`. Returns true when the caller should
    /// start a resolve; false when one is already in flight (the change is
    /// latched and `finish` will ask for a re-run).
    mutating func begin(_ pid: pid_t) -> Bool {
        guard !inFlight.contains(pid) else {
            pending.insert(pid)
            return false
        }
        inFlight.insert(pid)
        return true
    }

    /// The in-flight resolve for `pid` landed. Returns true when another focus
    /// change arrived mid-flight and the caller should resolve again.
    mutating func finish(_ pid: pid_t) -> Bool {
        inFlight.remove(pid)
        return pending.remove(pid) != nil
    }
}
