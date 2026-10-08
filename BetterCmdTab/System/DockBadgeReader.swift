import AppKit
import ApplicationServices
import os
import UniformTypeIdentifiers

/// What another device on the same Apple ID offers through Handoff, read off the
/// Dock's `AXHandoffDockItem`.
struct HandoffSuggestion: Equatable {
    let appName: String
    let bundleID: String
    let appURL: URL
    /// The model ("Mac Studio", "iPhone"); the Dock does not expose the device's own
    /// name. Nil for a model this Mac's macOS does not know.
    let deviceName: String?
    /// The Dock item. `AXPress` on it opens the suggestion on this Mac.
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.deviceName == rhs.deviceName && CFEqual(lhs.element, rhs.element)
    }
}

/// One Dock scan: badge labels by bundle ID and the Handoff suggestion, if any.
struct DockSnapshot: Equatable {
    var badges: [String: String] = [:]
    var handoff: HandoffSuggestion?
    /// The Handoff item's title when its app was found neither in the Dock nor among
    /// the installed apps.
    var unresolvedHandoffTitle: String?
}

/// Reads app badge labels (e.g. Mail's unread count) and the Handoff suggestion
/// straight out of the Dock's Accessibility tree. There is no public API for
/// either, so this walks the Dock process's AX elements and pulls the
/// undocumented `AXStatusLabel` attribute off each dock item. Because the
/// attribute and the Dock tree shape are undocumented they could change between
/// macOS releases, so every read is best-effort: a miss just yields nothing
/// rather than failing.
///
/// The snapshot is recomputed on demand (`snapshot(installedAppURLs:)` at reveal time,
/// throttled via `shouldRefresh()`); item views read `badge(forBundleID:)` and the
/// controller reads `handoff`.
/// Gated by the `showUnreadBadges` and `handoffPlacement` preferences.
@MainActor
final class DockBadgeReader {
    static let shared = DockBadgeReader()

    /// Bundle identifier → badge label (already non-empty).
    private var badgesByBundleID: [String: String] = [:]
    private(set) var handoff: HandoffSuggestion?
    private var unresolvedHandoffTitle: String?
    private var lastRefresh: Date?
    /// Skip rescanning the Dock tree if we did so very recently — back-to-back
    /// reveals shouldn't each hammer the AX server.
    private let throttle: TimeInterval = 1.0

    private init() {}

    func badge(forBundleID bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return badgesByBundleID[bundleID]
    }

    /// Whether enough time has elapsed since the last scan to warrant another.
    /// Back-to-back reveals shouldn't each hammer the Dock's AX server.
    func shouldRefresh() -> Bool {
        guard let lastRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) >= throttle
    }

    /// Walk the Dock's AX tree and pull badge labels and the Handoff item.
    /// Undocumented but read-only AX traffic against another process — safe off
    /// the main thread, which is where the reveal path runs it (each call is
    /// timeout-bounded). Pair with `apply` on the main actor.
    ///
    /// In-flight guarded: the panel-open poll dispatches a snapshot per tick with
    /// no awareness of a previous scan still blocked on a stalled Dock, so a tick
    /// that finds one running returns the last completed snapshot instead (a no-op
    /// downstream — `apply` is change-gated) rather than stacking another blocked
    /// worker thread.
    /// `installedAppURLs` (display name → bundle URL) resolves a Handoff app that is
    /// not in the Dock.
    nonisolated static func snapshot(installedAppURLs: [String: URL]) -> DockSnapshot {
        guard scanLatch.begin() else { return scanLatch.lastResult() }
        let result = readDock(installedAppURLs: installedAppURLs)
        scanLatch.end(result)
        return result
    }

    /// Returns whether the snapshot actually changed, so a live poll can skip a
    /// needless row repaint when nothing moved. `keepBadges` false stores no badges,
    /// for a scan made only for the Handoff item.
    @discardableResult
    func apply(_ snapshot: DockSnapshot, keepBadges: Bool) -> Bool {
        // The poll re-reads the Dock every 0.6 s, so log a title once, not per scan.
        if let title = snapshot.unresolvedHandoffTitle, title != unresolvedHandoffTitle {
            Log.switcher.info("Handoff item unresolved: '\(title, privacy: .public)'")
        }
        unresolvedHandoffTitle = snapshot.unresolvedHandoffTitle
        let badges = keepBadges ? snapshot.badges : [:]
        let changed = badges != badgesByBundleID || snapshot.handoff != handoff
        badgesByBundleID = badges
        handoff = snapshot.handoff
        lastRefresh = Date()
        return changed
    }

    /// For a reveal that wants nothing from the Dock: forget the last scan.
    func clear() {
        badgesByBundleID = [:]
        handoff = nil
        lastRefresh = nil
    }

    /// For a reveal that reads the Dock only for the Handoff item.
    func clearBadges() {
        badgesByBundleID = [:]
    }

    /// The Dock removes its Handoff item once pressed; forget it before the next scan.
    func dropHandoff() {
        handoff = nil
    }

    /// `title` is the app's display name and `deviceType` a model type such as
    /// `com.apple.macstudio`, both as the Dock's Handoff item carries them. The app
    /// is looked up first among the Dock's apps, then among the installed apps.
    nonisolated static func handoffSuggestion(
        title: String?,
        deviceType: String?,
        dockAppURLs: [String: URL],
        installedAppURLs: [String: URL],
        element: AXUIElement
    ) -> HandoffSuggestion? {
        guard let title,
              let appURL = dockAppURLs[title] ?? installedAppURLs[title],
              let bundleID = bundleID(for: appURL) else { return nil }
        let deviceName = deviceType.flatMap(deviceName(forType:))
        return HandoffSuggestion(appName: title, bundleID: bundleID, appURL: appURL, deviceName: deviceName, element: element)
    }

    nonisolated private static func deviceName(forType type: String) -> String? {
        if let cached = deviceNames.withLock({ $0[type] }) { return cached }
        let name = UTType(type)?.localizedDescription
        // `.some` stores a nil name instead of removing the key.
        deviceNames.withLock { $0[type] = .some(name) }
        return name
    }

    nonisolated private static let statusLabelAttribute = "AXStatusLabel"
    nonisolated private static let handoffSubrole = "AXHandoffDockItem"
    nonisolated private static let scanLatch = DockBadgeScanLatch()
    /// Model type → localized model name. The Dock is re-read every 0.6 s while the
    /// panel is open, so LaunchServices is asked once per type.
    nonisolated private static let deviceNames = OSAllocatedUnfairLock<[String: String?]>(initialState: [:])

    nonisolated private static func bundleID(for url: URL) -> String? {
        BundleIDURLCache.shared.lookup(url)
    }

    nonisolated private static func readDock(installedAppURLs: [String: URL]) -> DockSnapshot {
        guard let dockPid = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.pid else { return DockSnapshot() }

        let axDock = AXUIElementCreateApplication(dockPid)
        // Timeouts are per-element — one set on `axDock` does not carry to its
        // children — so bound the list and every item below too, or a stalled
        // Dock holds each call for the ~6s global default. Mirrors
        // `DockBadgeObserver.buildObserver`.
        AXUIElementSetMessagingTimeout(axDock, 0.1)

        guard let list = firstAXList(of: axDock) else { return DockSnapshot() }
        AXUIElementSetMessagingTimeout(list, 0.1)
        let items = children(of: list)

        let attributes = [
            kAXSubroleAttribute,
            kAXIsApplicationRunningAttribute,
            kAXURLAttribute,
            statusLabelAttribute,
            kAXTitleAttribute,
        ] as CFArray

        var result = DockSnapshot()
        var appURLsByTitle: [String: URL] = [:]
        var handoffItem: (element: AXUIElement, title: String?, deviceType: String?)?
        for item in items {
            AXUIElementSetMessagingTimeout(item, 0.1)
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item, attributes, AXCopyMultipleAttributeOptions(), &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 5 else { continue }

            // Order matches `attributes` above. A failed attribute comes back as
            // an AXValue error wrapper, so the casts below just yield nil.
            let subrole = values[0] as? String
            if subrole == handoffSubrole {
                // On the Handoff item `AXStatusLabel` holds the device model type.
                handoffItem = (item, values[4] as? String, values[3] as? String)
                continue
            }
            guard subrole == (kAXApplicationDockItemSubrole as String), let url = values[2] as? URL else { continue }
            if let title = values[4] as? String { appURLsByTitle[title] = url }
            guard (values[1] as? Bool) == true else { continue }
            guard let badge = values[3] as? String, !badge.isEmpty else { continue }
            guard let bid = bundleID(for: url) else { continue }
            result.badges[bid] = badge
        }
        if let handoffItem {
            result.handoff = handoffSuggestion(title: handoffItem.title, deviceType: handoffItem.deviceType,
                                               dockAppURLs: appURLsByTitle, installedAppURLs: installedAppURLs,
                                               element: handoffItem.element)
            if result.handoff == nil { result.unresolvedHandoffTitle = handoffItem.title ?? "" }
        }
        return result
    }

    /// The Dock app's children include a single `AXList` holding the dock items.
    /// Internal (not private) so `DockBadgeObserver` reuses the same tree walk.
    nonisolated static func firstAXList(of element: AXUIElement) -> AXUIElement? {
        for child in children(of: element) {
            // Timeouts are per-element; bound the role probe too.
            AXUIElementSetMessagingTimeout(child, 0.1)
            if string(child, attribute: kAXRoleAttribute as CFString) == (kAXListRole as String) {
                return child
            }
        }
        return nil
    }

    /// Internal (not private) so `DockBadgeObserver` reuses the same tree walk.
    nonisolated static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    nonisolated private static func string(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
}

/// Thread-safe in-flight latch + last-result cache behind `DockBadgeReader.snapshot(installedAppURLs:)`.
/// `begin()` returns false while a scan is running, so concurrent callers (the
/// panel-open poll ticking faster than a stalled Dock answers) reuse
/// `lastResult()` instead of piling up blocked worker threads. Internal (not
/// private) so the pure begin/end/last seam is testable.
final class DockBadgeScanLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private var last = DockSnapshot()

    /// True if the caller owns the scan; false if one is already in flight.
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlight { return false }
        inFlight = true
        return true
    }

    func end(_ result: DockSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        inFlight = false
        last = result
    }

    func lastResult() -> DockSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}

/// Thread-safe URL → bundle ID cache, separated so the underlying `NSCache`
/// (which is documented thread-safe but unmarked `Sendable`) can be captured
/// by nonisolated code without a Swift 6 complaint. Used by the dock badge
/// reader; trivially extendable to other scrapers that map a `file://` URL to
/// a bundle ID.
final class BundleIDURLCache: @unchecked Sendable {
    static let shared = BundleIDURLCache()
    private let cache: NSCache<NSURL, NSString> = {
        let c = NSCache<NSURL, NSString>()
        c.countLimit = 128
        return c
    }()
    func lookup(_ url: URL) -> String? {
        let nsURL = url as NSURL
        if let hit = cache.object(forKey: nsURL) { return hit as String }
        guard let bid = Bundle(url: url)?.bundleIdentifier else { return nil }
        cache.setObject(bid as NSString, forKey: nsURL)
        return bid
    }
}
