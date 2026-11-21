import Foundation

/// Re-ask schedule for a focused-window resolve that came back empty.
///
/// An app that is busy (launching, opening a document, activating) can fail
/// the `kAXFocusedWindow` query. A focus change resolves once, so without a
/// re-ask that window never enters the window MRU and sorts behind every known
/// window under `.mruWindows`. Seen with Microsoft Excel at launch.
enum FocusResolveRetry {
    /// Wait before each re-ask, indexed by the attempt that just failed.
    static let delays: [TimeInterval] = [0.4, 1.2, 3.0]

    /// The wait before asking again, or nil when no re-ask is due: the resolve
    /// found a window, the schedule is spent, or the app is no longer
    /// frontmost. A late answer for an app the user has left would lift its
    /// window above the one they are in now.
    static func delay(afterAttempt attempt: Int, resolved: Bool, isFrontmost: Bool) -> TimeInterval? {
        guard !resolved, isFrontmost, delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }
}
