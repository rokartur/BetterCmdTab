import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

enum ThumbnailKey: Hashable, Sendable {
    case window(CGWindowID)
    case browserTab(BrowserTabPreviewKey)

    var windowID: CGWindowID {
        switch self {
        case .window(let id): id
        case .browserTab(let key): key.windowID
        }
    }
}

/// Generation tokens for asynchronous thumbnail captures. Clearing the cache
/// invalidates every outstanding token; an old completion then cannot repopulate
/// a cache cleared for memory pressure or remove a newer request for the same wid.
struct ThumbnailRequestGate {
    private var active: [ThumbnailKey: UInt64] = [:]
    private var nextToken: UInt64 = 0

    var count: Int { active.count }

    func contains(_ key: ThumbnailKey) -> Bool { active[key] != nil }
    func contains(_ wid: CGWindowID) -> Bool { contains(.window(wid)) }

    mutating func begin(_ key: ThumbnailKey) -> UInt64? {
        guard key.windowID != 0, active[key] == nil else { return nil }
        nextToken &+= 1
        if nextToken == 0 { nextToken = 1 }
        active[key] = nextToken
        return nextToken
    }
    mutating func begin(_ wid: CGWindowID) -> UInt64? { begin(.window(wid)) }

    /// True only for the currently-active request; also consumes that request.
    mutating func finish(_ key: ThumbnailKey, token: UInt64) -> Bool {
        guard active[key] == token else { return false }
        active.removeValue(forKey: key)
        return true
    }
    mutating func finish(_ wid: CGWindowID, token: UInt64) -> Bool { finish(.window(wid), token: token) }

    mutating func reset() { active.removeAll() }
}

/// Live window-preview cache for the alt-tab–style `windowPreview` layout.
///
/// Captures a still image of a window by its `CGWindowID` and caches it keyed
/// by that id. Capture is asynchronous and off the reveal critical path: the
/// preview tile shows the app icon as a placeholder and swaps in the thumbnail
/// via `onReady` once it lands.
///
/// Storage is a deterministic LRU (`ThumbnailLRU`), not `NSCache`: NSCache
/// evicts "for reasons of its own" — memory pressure, background-app purges —
/// and this app is a permanent `.accessory`, so frames vanished between
/// reveals and tiles flashed the app icon seemingly at random (#82). Entries
/// now leave only via the count/cost limits or the real memory-pressure
/// handler wired in `init`.
///
/// Capture uses `SCScreenshotManager` on macOS 14+ (the supported path) and
/// falls back to the deprecated-but-functional `CGWindowListCreateImage` on
/// macOS 13. Either path needs the Screen Recording permission; without it the
/// capture returns nil and the tile keeps showing the app icon.
@MainActor
final class WindowThumbnailCache {
    static let shared = WindowThumbnailCache()

    /// Invoked on the main actor when a requested thumbnail finishes capturing,
    /// so the view can repaint just the matching tile. The argument is the
    /// `CGWindowID` whose image is now in the cache.
    var onReady: ((ThumbnailKey) -> Void)?

    // Preview mode rarely surfaces more than ~24 windows at once; cap at 32 so
    // the cache holds a generous working set without retaining stale captures
    // from long-past reveals that would never be reused. The cost ceiling is
    // anchored to a typical Retina preview tile (~512×288 RGBA ≈ 590KB) × the
    // count limit, with headroom for occasional wider previews, so a 4K frame
    // can't single-handedly crowd out the rest.
    private var cache = ThumbnailLRU(countLimit: 32, costLimit: 32 * 600_000)
    private var requests = ThumbnailRequestGate()
    /// Handles let a memory-pressure clear cancel capture work as well as
    /// invalidating its result token. The token prevents an old completion from
    /// removing a newer task for a reused window id.
    private var captureTasks: [ThumbnailKey: (token: UInt64, task: Task<Void, Never>)] = [:]
    /// Pace windows that cannot currently be captured (closed/minimized or a
    /// denied permission) instead of retrying them ten times per second.
    private var liveFailureAt: [ThumbnailKey: Date] = [:]
    private var activeBrowserTabByWindow: [CGWindowID: BrowserTabPreviewKey] = [:]
    private let liveFailureBackoff: TimeInterval = 2.0
    private var didRequestPermission = false
    private let memoryPressure: DispatchSourceMemoryPressure

    /// How long a captured frame is reused before a reveal triggers a silent
    /// background recapture. Reopening the switcher within this window shows the
    /// last frame instantly (no app-icon flash); past it the stale frame still
    /// shows immediately while a fresh capture swaps in via `onReady`.
    private let refreshTTL: TimeInterval = 2.0

    private init() {
        // The LRU never drops entries behind the app's back, so honour real
        // memory pressure explicitly — thumbnails are the cheapest ~19MB to
        // hand back, and they self-heal via recapture on the next reveal.
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.clear() }
        }
        memoryPressure.activate()
    }

    /// Cached thumbnail for `wid`, or nil if not captured yet. Bumps the
    /// entry's recency: tiles that still ask for a frame are the working set.
    func image(for wid: CGWindowID) -> NSImage? {
        image(for: .window(wid))
    }

    func image(for key: ThumbnailKey) -> NSImage? {
        guard key.windowID != 0 else { return nil }
        return cache.image(for: key)
    }

    /// Ensure `wid` has a reasonably fresh thumbnail. Skips work when a frame
    /// captured within `refreshTTL` is already cached (so a quick reopen shows
    /// it instantly with no flash) and when a capture is already in flight.
    /// Otherwise it (re)captures in the background; the
    /// existing frame — or the caller's app-icon placeholder when there is none
    /// yet — stays on screen until the new one lands via `onReady`.
    /// `pixelHeight` is the target raster height so the capture stays crisp on
    /// Retina without over-allocating.
    func request(wid: CGWindowID, pixelHeight: CGFloat) {
        beginRequest(key: .window(wid), pixelHeight: pixelHeight, maxAge: refreshTTL, isLive: false)
    }

    func setActiveBrowserTab(_ key: BrowserTabPreviewKey?) {
        activeBrowserTabByWindow.removeAll(keepingCapacity: true)
        if let key { activeBrowserTabByWindow[key.windowID] = key }
    }

    func isActiveBrowserTab(_ key: BrowserTabPreviewKey) -> Bool {
        activeBrowserTabByWindow[key.windowID] == key
    }

    func requestBrowserTab(_ key: BrowserTabPreviewKey, pixelHeight: CGFloat, isLive: Bool = false) {
        guard isActiveBrowserTab(key) else { return }
        beginRequest(
            key: .browserTab(key),
            pixelHeight: pixelHeight,
            maxAge: isLive ? 0 : refreshTTL,
            isLive: isLive
        )
    }

    /// Request the next one-shot live frame. ScreenCaptureKit only; the legacy
    /// CG fallback captures at native resolution and downsizes on the CPU, which
    /// is acceptable once per reveal but not on a 10 Hz path.
    func requestLiveFrame(wid: CGWindowID, pixelHeight: CGFloat) {
        guard #available(macOS 14.0, *) else { return }
        beginRequest(key: .window(wid), pixelHeight: pixelHeight, maxAge: 0, isLive: true)
    }

    private func beginRequest(
        key: ThumbnailKey,
        pixelHeight: CGFloat,
        maxAge: TimeInterval,
        isLive: Bool
    ) {
        let wid = key.windowID
        guard wid != 0, !requests.contains(key) else { return }
        if isLive, let failed = liveFailureAt[key],
           Date().timeIntervalSince(failed) < liveFailureBackoff { return }
        if maxAge > 0, let ts = cache.capturedAt(for: key),
           Date().timeIntervalSince(ts) < maxAge { return }
        guard let token = requests.begin(key) else { return }
        let task = Task { [weak self] in
            let image = await Self.capture(
                wid: wid,
                pixelHeight: pixelHeight,
                allowCGFallback: !isLive
            )
            guard !Task.isCancelled else { return }
            self?.store(image, for: key, token: token, isLive: isLive)
        }
        captureTasks[key] = (token, task)
    }

    private func store(
        _ image: NSImage?,
        for key: ThumbnailKey,
        token: UInt64,
        isLive: Bool
    ) {
        if captureTasks[key]?.token == token {
            captureTasks.removeValue(forKey: key)
        }
        // A memory-pressure clear, or a newer request after that clear, makes an
        // old completion stale. Do not repopulate the cache and, critically, do
        // not clear the newer request's in-flight slot.
        guard requests.finish(key, token: token) else { return }
        if case .browserTab(let tabKey) = key,
           activeBrowserTabByWindow[tabKey.windowID] != tabKey { return }
        guard let image else {
            if isLive {
                liveFailureAt[key] = Date()
                if liveFailureAt.count > 64 {
                    let now = Date()
                    liveFailureAt = liveFailureAt.filter {
                        now.timeIntervalSince($0.value) < liveFailureBackoff
                    }
                }
            }
            return
        }
        liveFailureAt.removeValue(forKey: key)
        let cost = Int(image.size.width * image.size.height * 4)
        cache.set(image, cost: cost, capturedAt: Date(), for: key)
        onReady?(key)
    }

    /// Drop every cached thumbnail (memory-pressure handler). Not called on
    /// dismiss — frames are kept warm across reveals so reopening the switcher
    /// shows them instantly instead of flashing app icons first.
    func clear() {
        for capture in captureTasks.values { capture.task.cancel() }
        captureTasks.removeAll()
        cache.removeAll()
        requests.reset()
        liveFailureAt.removeAll()
        activeBrowserTabByWindow.removeAll()
        releaseCaptureMetadata()
    }

    /// Release ScreenCaptureKit's system-wide `SCWindow` inventory after a panel
    /// session. Thumbnails stay cached, but the broader shareable-content map is
    /// useful only while captures are actively being requested.
    func releaseCaptureMetadata() {
        if #available(macOS 14.0, *) {
            Task { await SCWindowProvider.shared.clear() }
        }
    }

    /// Prompt for Screen Recording once per launch, the first time the preview
    /// layout is shown. The capture APIs prompt on their own, but a cold first
    /// use can otherwise return nil silently before the user has granted it.
    func ensurePermission() {
        guard !didRequestPermission else { return }
        didRequestPermission = true
        DispatchQueue.global(qos: .utility).async {
            guard !CGPreflightScreenCaptureAccess() else { return }
            // Granting flips a prior "denied" enumeration into a stale 5 s
            // backoff; drop it so the next reveal captures immediately instead of
            // showing app icons until the backoff elapses.
            if CGRequestScreenCaptureAccess(), #available(macOS 14.0, *) {
                Task { await SCWindowProvider.shared.clearFailureBackoff() }
            }
        }
    }

    // MARK: - Capture

    nonisolated private static func capture(
        wid: CGWindowID,
        pixelHeight: CGFloat,
        allowCGFallback: Bool
    ) async -> NSImage? {
        if #available(macOS 14.0, *) {
            if let image = await captureSCK(wid: wid, pixelHeight: pixelHeight) {
                return image
            }
        }
        guard allowCGFallback else { return nil }
        return captureCG(wid: wid, pixelHeight: pixelHeight)
    }

    @available(macOS 14.0, *)
    nonisolated private static func captureSCK(wid: CGWindowID, pixelHeight: CGFloat) async -> NSImage? {
        guard let captured = await SCWindowProvider.shared.capture(
            wid: wid,
            pixelHeight: pixelHeight
        ) else { return nil }
        let cg = captured.image
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated private static func captureCG(wid: CGWindowID, pixelHeight: CGFloat) -> NSImage? {
        guard let cg = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            wid,
            [.boundsIgnoreFraming, .bestResolution]
        ), cg.width > 1, cg.height > 1 else { return nil }
        // `.bestResolution` returns the window at native Retina size — a large
        // window costs tens of MB, blowing the whole cache budget on one entry.
        // Downscale to the tile's pixel height so it costs one cache slot.
        return downscaled(cg, toPixelHeight: pixelHeight)
    }

    /// Returns `cg` redrawn at `pixelHeight` (aspect preserved) when it is
    /// taller than the target, or wrapped as-is when it already fits.
    nonisolated private static func downscaled(_ cg: CGImage, toPixelHeight pixelHeight: CGFloat) -> NSImage? {
        let targetH = max(1, Int(pixelHeight.rounded()))
        guard cg.height > targetH else {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        let targetW = max(1, Int((CGFloat(cg.width) * CGFloat(targetH) / CGFloat(cg.height)).rounded()))
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let scaled = ctx.makeImage() else {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return NSImage(cgImage: scaled, size: NSSize(width: scaled.width, height: scaled.height))
    }
}

/// Deterministic LRU store behind `WindowThumbnailCache`. Entries are evicted
/// only when an insert pushes past the count or total-cost limit (least
/// recently used first) or on an explicit `removeAll` — never spontaneously,
/// which is the property NSCache couldn't guarantee (#82). Reads bump recency.
///
/// Sizes are tiny (≤ 32 entries), so recency is a plain array — the O(n)
/// reshuffle on a bump is a few pointer moves, cheaper than any linked-list
/// or generation-counter scheme at this scale.
struct ThumbnailLRU {
    private struct Entry {
        let image: NSImage
        let cost: Int
        let capturedAt: Date
    }

    private var entries: [ThumbnailKey: Entry] = [:]
    /// Recency order, index 0 = least recently used.
    private var order: [ThumbnailKey] = []
    private(set) var totalCost = 0
    let countLimit: Int
    let costLimit: Int

    init(countLimit: Int, costLimit: Int) {
        self.countLimit = countLimit
        self.costLimit = costLimit
    }

    var count: Int { entries.count }

    /// Cached image for `wid`, bumping its recency on a hit.
    mutating func image(for key: ThumbnailKey) -> NSImage? {
        guard let entry = entries[key] else { return nil }
        bump(key)
        return entry.image
    }
    mutating func image(for wid: CGWindowID) -> NSImage? { image(for: .window(wid)) }

    /// Capture timestamp for `wid` without touching recency (freshness checks
    /// shouldn't keep an otherwise-unused entry alive).
    func capturedAt(for key: ThumbnailKey) -> Date? {
        entries[key]?.capturedAt
    }
    func capturedAt(for wid: CGWindowID) -> Date? { capturedAt(for: .window(wid)) }

    /// Insert or replace `wid`, then evict least-recently-used entries while
    /// over either limit. The just-inserted entry is never evicted: one
    /// oversized frame beats an empty cache.
    mutating func set(_ image: NSImage, cost: Int, capturedAt: Date, for key: ThumbnailKey) {
        if let old = entries.removeValue(forKey: key) {
            totalCost -= old.cost
            order.removeAll { $0 == key }
        }
        entries[key] = Entry(image: image, cost: cost, capturedAt: capturedAt)
        order.append(key)
        totalCost += cost
        while entries.count > 1, entries.count > countLimit || totalCost > costLimit {
            let lru = order.removeFirst()
            if let evicted = entries.removeValue(forKey: lru) {
                totalCost -= evicted.cost
            }
        }
    }
    mutating func set(_ image: NSImage, cost: Int, capturedAt: Date, for wid: CGWindowID) {
        set(image, cost: cost, capturedAt: capturedAt, for: .window(wid))
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalCost = 0
    }

    private mutating func bump(_ key: ThumbnailKey) {
        guard order.last != key, let idx = order.firstIndex(of: key) else { return }
        order.remove(at: idx)
        order.append(key)
    }
}

/// Short-lived cache of `SCShareableContent` so a single reveal enumerates the
/// window list once instead of once per captured window (the enumeration is the
/// expensive part of an `SCScreenshotManager` capture).
@available(macOS 14.0, *)
private struct CapturedCGImage: @unchecked Sendable {
    /// CGImage is immutable and safe to retain/read across queues; CoreGraphics
    /// predates Swift Sendable annotations, so contain that guarantee here.
    let image: CGImage
}

@available(macOS 14.0, *)
private actor SCWindowProvider {
    static let shared = SCWindowProvider()

    private var windowsByID: [CGWindowID: SCWindow] = [:]
    private var fetchedAt: Date = .distantPast
    private var lastFailureAt: Date = .distantPast
    private let ttl: TimeInterval = 1.5
    /// After a failed enumeration (typically Screen Recording denied — a state
    /// the app tolerates indefinitely), skip further attempts for this long so
    /// a denied permission doesn't fire XPC round trips per tile per repaint.
    private let failureBackoff: TimeInterval = 5.0

    /// A transient enumeration failure (SCK busy, a just-opened window not yet in
    /// the inventory) clears on its own in a fraction of a second, so pacing it
    /// behind the 5 s permission backoff needlessly blanks every tile until the
    /// next reveal. Only a *denied permission* — which the app tolerates
    /// indefinitely — warrants the long backoff. `performRefresh` picks the
    /// window based on whether Screen Recording is currently granted.
    private let transientFailureBackoff: TimeInterval = 0.5
    /// Whether the last failure happened while Screen Recording was granted
    /// (transient) vs denied (permission). Selects the backoff length above.
    private var lastFailureWasTransient = false

    private var refreshGeneration: UInt64 = 0
    private var inFlightRefresh: (generation: UInt64, task: Task<Void, Never>)?

    /// Reset the failure pacing so the next enumeration retries immediately.
    /// Called when Screen Recording is granted at runtime: without this, a denial
    /// recorded moments earlier would keep every tile on its app icon for up to
    /// `failureBackoff` seconds after the user already fixed the permission.
    func clearFailureBackoff() {
        lastFailureAt = .distantPast
        lastFailureWasTransient = false
    }

    /// Resolve and capture entirely inside the actor so the non-Sendable
    /// ScreenCaptureKit `SCWindow` never crosses an isolation boundary.
    func capture(wid: CGWindowID, pixelHeight: CGFloat) async -> CapturedCGImage? {
        guard let scWindow = await window(for: wid) else { return nil }
        let frame = scWindow.frame
        guard frame.height > 1, frame.width > 1 else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        // Match the window's aspect ratio, capped to the on-screen tile height.
        // `frame` is in points while `pixelHeight` is pixels; assume Retina 2x
        // for the native height (the target cap also keeps 1x displays bounded).
        let aspect = frame.width / frame.height
        let height = max(1, min(frame.height * 2, pixelHeight))
        config.height = Int(height.rounded())
        config.width = max(1, Int((height * aspect).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true

        do {
            return CapturedCGImage(image: try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            ))
        } catch {
            return nil
        }
    }

    private func window(for wid: CGWindowID) async -> SCWindow? {
        let entered = Date()
        if entered.timeIntervalSince(fetchedAt) >= ttl {
            await refresh(ifOlderThan: entered)
        }
        if let cached = windowsByID[wid] { return cached }
        // Miss on a freshly opened window — refetch once before giving up,
        // but only when the map predates this call (a refresh that already
        // completed above wouldn't find it the second time either).
        if fetchedAt < entered {
            await refresh(ifOlderThan: entered)
        }
        return windowsByID[wid]
    }

    /// Refresh the map unless another caller already refreshed it after
    /// `reference`, coalescing concurrent callers onto a single in-flight
    /// enumeration. The actor is reentrant — every caller suspended at the
    /// SCShareableContent await would otherwise pass the staleness check and
    /// fire its own full system-wide window enumeration, one per visible tile
    /// per TTL lapse when reveal and live-snapshot requests arrive together.
    private func refresh(ifOlderThan reference: Date) async {
        // Coalesce every caller that arrived during the same enumeration. The
        // successful refresh is stamped at completion, so all of those callers
        // accept the same map instead of serially starting one enumeration each.
        while let running = inFlightRefresh {
            await running.task.value
            if fetchedAt >= reference { return }
        }
        if fetchedAt >= reference { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let task = Task {
            await performRefresh(generation: generation)
            // Clear from inside the child so the handle can't linger as a
            // completed task absorbing refreshes until the creator resumes. A
            // clear/new refresh may supersede us while SCK is suspended, so only
            // clear the slot if it still belongs to this generation.
            if inFlightRefresh?.generation == generation {
                inFlightRefresh = nil
            }
        }
        inFlightRefresh = (generation, task)
        await task.value
    }

    private func performRefresh(generation: UInt64) async {
        let backoff = lastFailureWasTransient ? transientFailureBackoff : failureBackoff
        guard Date().timeIntervalSince(lastFailureAt) >= backoff else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            windowsByID = Dictionary(
                content.windows.map { ($0.windowID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // Completion time makes this refresh satisfy every caller that
            // coalesced onto it. A later lookup that misses the cached map still
            // gets the one explicit second-chance refresh in `window(for:)`.
            fetchedAt = Date()
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            // Leave the previous map (possibly empty); the CG fallback path still
            // gets a chance. Classify the failure so the pacing above can retry a
            // transient hiccup quickly while still holding back per-tile XPC when
            // the permission is genuinely denied.
            fetchedAt = .distantPast
            lastFailureAt = Date()
            lastFailureWasTransient = CGPreflightScreenCaptureAccess()
        }
    }

    /// Drop the broad shareable-content inventory and invalidate a suspended
    /// refresh. Its completion checks `refreshGeneration`, so it cannot repopulate
    /// the actor after the panel has closed or memory pressure requested a purge.
    func clear() {
        refreshGeneration &+= 1
        inFlightRefresh?.task.cancel()
        inFlightRefresh = nil
        windowsByID.removeAll()
        fetchedAt = .distantPast
        lastFailureAt = .distantPast
    }
}
