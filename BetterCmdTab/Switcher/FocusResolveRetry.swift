import Foundation

/// Excel at launch fails kAXFocusedWindow; one resolve leaves its window out of the window MRU.
enum FocusResolveRetry {
    /// Wait between a failed resolve and the next re-ask, indexed by the attempt that failed.
    static let delays: [TimeInterval] = [0.4, 1.2, 3.0]

    /// A late answer for an app the user left would lift its window above the current one.
    static func delay(afterAttempt attempt: Int, resolved: Bool, isFrontmost: Bool) -> TimeInterval? {
        guard !resolved, isFrontmost, delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }

    /// A retry lands up to 0.25 s after it fires, so it bumps only while its app is still frontmost.
    static func mayBump(attempt: Int, resolved: Bool, isFrontmost: Bool) -> Bool {
        resolved && (attempt == 0 || isFrontmost)
    }
}
