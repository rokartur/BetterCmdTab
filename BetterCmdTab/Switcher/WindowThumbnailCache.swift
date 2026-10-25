import AppKit
import CoreGraphics
import os

/// Generation tokens for asynchronous thumbnail captures. Clearing the cache
/// invalidates every outstanding token; an old completion then cannot repopulate
/// a cache cleared for memory pressure or remove a newer request for the same wid.
struct ThumbnailRequestGate {
    private var active: [CGWindowID: UInt64] = [:]
    private var nextToken: UInt64 = 0

    var count: Int { active.count }

    func contains(_ wid: CGWindowID) -> Bool { active[wid] != nil }

    mutating func begin(_ wid: CGWindowID) -> UInt64? {
        guard wid != 0, active[wid] == nil else { return nil }
        nextToken &+= 1
        if nextToken == 0 { nextToken = 1 }
        active[wid] = nextToken
        return nextToken
    }

    /// True only for the currently-active request; also consumes that request.
    mutating func finish(_ wid: CGWindowID, token: UInt64) -> Bool {
        guard active[wid] == token else { return false }
        active.removeValue(forKey: wid)
        return true
    }

    mutating func reset() { active.removeAll() }
}

/// Live window-preview cache for the alt-tab–style `windowPreview` layout.
///
/// Captures a still image of a window by its `CGWindowID` and caches it keyed
/// by that id. Capture is asynchronous and off the reveal critical path: the
/// preview tile shows the app icon as a placeholder and swaps in the thumbnail
/// via the view's ready handler once it lands.
///
/// Storage is a deterministic LRU (`ThumbnailLRU`), not `NSCache`: NSCache
/// evicts "for reasons of its own" — memory pressure, background-app purges —
/// and this app is a permanent `.accessory`, so frames vanished between
/// reveals and tiles flashed the app icon seemingly at random (#82). Entries
/// now leave only via the count/cost limits or the real memory-pressure
/// handler wired in `init`.
///
/// Capture uses the private WindowServer `CGSHWCaptureWindowList`, not ScreenCaptureKit:
/// SCK flags the session as screen-shared, which shows the menu bar sharing indicator
/// and on macOS 15 blocks Apple Watch unlock (#200). It needs the Screen Recording
/// permission; without it the capture returns nil and the tile keeps showing the app icon.
@MainActor
final class WindowThumbnailCache {
    static let shared = WindowThumbnailCache()

    /// Per-view repaint hooks (the switcher and its window shelf, #211), called on main when a thumbnail lands.
    private var readyHandlers: [ObjectIdentifier: (CGWindowID) -> Void] = [:]

    func setReadyHandler(_ handler: ((CGWindowID) -> Void)?, for owner: AnyObject) {
        readyHandlers[ObjectIdentifier(owner)] = handler
    }

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
    private var captureTasks: [CGWindowID: (token: UInt64, task: Task<Void, Never>)] = [:]
    private var staticRetryKeys: Set<CGWindowID> = []
    private var permissionRetryRequests: [CGWindowID: CGFloat] = [:]
    private var staticRetryGeneration: UInt64 = 0
    /// Pace windows that cannot currently be captured (closed/minimized or a
    /// denied permission) instead of retrying them ten times per second.
    private var liveFailureAt: [CGWindowID: Date] = [:]
    private let liveFailureBackoff: TimeInterval = 2.0
    private var didRequestPermission = false
    private let memoryPressure: DispatchSourceMemoryPressure

    /// How long a captured frame is reused before a reveal triggers a silent
    /// background recapture. Reopening the switcher within this window shows the
    /// last frame instantly (no app-icon flash); past it the stale frame still
    /// shows immediately while a fresh capture swaps in via the ready handlers.
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
        guard wid != 0 else { return nil }
        return cache.image(for: wid)
    }

    /// Ensure `wid` has a reasonably fresh thumbnail. Skips work when a frame
    /// captured within `refreshTTL` is already cached (so a quick reopen shows
    /// it instantly with no flash) and when a capture is already in flight.
    /// Otherwise it (re)captures in the background; the
    /// existing frame — or the caller's app-icon placeholder when there is none
    /// yet — stays on screen until the new one lands via the ready handlers.
    /// `pixelHeight` is the target raster height so the capture stays crisp on
    /// Retina without over-allocating.
    func request(wid: CGWindowID, pixelHeight: CGFloat) {
        beginRequest(wid: wid, pixelHeight: pixelHeight, maxAge: refreshTTL, isLive: false)
    }

    /// `request` without the `refreshTTL` reuse: captures unless one is already in flight.
    func refresh(wid: CGWindowID, pixelHeight: CGFloat) {
        beginRequest(wid: wid, pixelHeight: pixelHeight, maxAge: 0, isLive: false)
    }

    /// Request the next one-shot live frame: a point-size WindowServer capture downscaled
    /// on the CPU (about 2 ms of CPU per window on an M1 Max).
    func requestLiveFrame(wid: CGWindowID, pixelHeight: CGFloat) {
        beginRequest(wid: wid, pixelHeight: pixelHeight, maxAge: 0, isLive: true)
    }

    @discardableResult
    private func beginRequest(
        wid: CGWindowID,
        pixelHeight: CGFloat,
        maxAge: TimeInterval,
        isLive: Bool,
        isRetry: Bool = false
    ) -> Bool {
        guard wid != 0, !requests.contains(wid) else { return false }
        if isLive, let failed = liveFailureAt[wid],
           Date().timeIntervalSince(failed) < liveFailureBackoff { return false }
        if maxAge > 0, let ts = cache.capturedAt(for: wid),
           Date().timeIntervalSince(ts) < maxAge { return false }
        guard let token = requests.begin(wid) else { return false }
        let task = Task { [weak self] in
            let image = await Self.capture(wid: wid, pixelHeight: pixelHeight)
            guard !Task.isCancelled else { return }
            self?.store(
                image, for: wid, token: token, pixelHeight: pixelHeight,
                isLive: isLive, isRetry: isRetry)
        }
        captureTasks[wid] = (token, task)
        return true
    }

    private func store(
        _ image: NSImage?,
        for wid: CGWindowID,
        token: UInt64,
        pixelHeight: CGFloat,
        isLive: Bool,
        isRetry: Bool
    ) {
        if captureTasks[wid]?.token == token {
            captureTasks.removeValue(forKey: wid)
        }
        // A memory-pressure clear, or a newer request after that clear, makes an
        // old completion stale. Do not repopulate the cache and, critically, do
        // not clear the newer request's in-flight slot.
        guard requests.finish(wid, token: token) else { return }
        if isRetry { staticRetryKeys.remove(wid) }
        guard let image else {
            if isLive {
                liveFailureAt[wid] = Date()
                if liveFailureAt.count > 64 {
                    let now = Date()
                    liveFailureAt = liveFailureAt.filter {
                        now.timeIntervalSince($0.value) < liveFailureBackoff
                    }
                }
                return
            }
            guard !readyHandlers.isEmpty else { return }
            let hasAccess = CGPreflightScreenCaptureAccess()
            if !hasAccess {
                permissionRetryRequests[wid] = pixelHeight
                return
            }
            permissionRetryRequests.removeValue(forKey: wid)
            guard Self.shouldRetryStaticCapture(
                isLive: false, hasScreenRecordingAccess: hasAccess, isRetry: isRetry
            ), staticRetryKeys.insert(wid).inserted else { return }
            let generation = staticRetryGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard let self, self.staticRetryGeneration == generation,
                      self.staticRetryKeys.contains(wid) else { return }
                guard !self.readyHandlers.isEmpty else {
                    self.staticRetryKeys.remove(wid)
                    return
                }
                if !self.beginRequest(
                    wid: wid, pixelHeight: pixelHeight, maxAge: 0,
                    isLive: false, isRetry: true
                ) {
                    self.staticRetryKeys.remove(wid)
                }
            }
            return
        }
        staticRetryKeys.remove(wid)
        permissionRetryRequests.removeValue(forKey: wid)
        liveFailureAt.removeValue(forKey: wid)
        let cost = Int(image.size.width * image.size.height * 4)
        cache.set(image, cost: cost, capturedAt: Date(), for: wid)
        for handler in readyHandlers.values { handler(wid) }
    }

    /// Drop every cached thumbnail (memory-pressure handler). Not called on
    /// dismiss — frames are kept warm across reveals so reopening the switcher
    /// shows them instantly instead of flashing app icons first.
    func clear() {
        for capture in captureTasks.values { capture.task.cancel() }
        captureTasks.removeAll()
        cache.removeAll()
        requests.reset()
        staticRetryKeys.removeAll()
        permissionRetryRequests.removeAll()
        liveFailureAt.removeAll()
        cancelPendingRetries()
    }

    /// Drop the retries queued for a panel session that has ended. Thumbnails stay cached.
    func cancelPendingRetries() {
        staticRetryGeneration &+= 1
        staticRetryKeys.removeAll()
        permissionRetryRequests.removeAll()
    }

    /// Prompt for Screen Recording once per launch, the first time the preview
    /// layout is shown. The capture APIs prompt on their own, but a cold first
    /// use can otherwise return nil silently before the user has granted it.
    func ensurePermission() {
        guard !didRequestPermission else { return }
        didRequestPermission = true
        DispatchQueue.global(qos: .utility).async {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { return }
            Task { @MainActor in
                WindowThumbnailCache.shared.retryPermissionFailures()
            }
        }
    }

    private func retryPermissionFailures() {
        guard !readyHandlers.isEmpty else {
            permissionRetryRequests.removeAll()
            return
        }
        let pending = permissionRetryRequests
        permissionRetryRequests.removeAll()
        for (wid, pixelHeight) in pending {
            request(wid: wid, pixelHeight: pixelHeight)
        }
    }

    nonisolated static func shouldRetryStaticCapture(
        isLive: Bool,
        hasScreenRecordingAccess: Bool,
        isRetry: Bool
    ) -> Bool {
        !isLive && hasScreenRecordingAccess && !isRetry
    }

    // MARK: - Capture

    nonisolated private static let windowServerQueue = DispatchQueue(label: "WindowThumbnailCache.windowServer", qos: .userInitiated)

    nonisolated private static func capture(wid: CGWindowID, pixelHeight: CGFloat) async -> NSImage? {
        // A preview panel left open (stayOpenOnRelease) must not capture behind the lock screen (#200).
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true { return nil }
        // The capture is synchronous and `capture` inherits the main actor under
        // NonisolatedNonsendingByDefault, so hop to a serial queue: the WindowServer
        // serves captures one at a time anyway, so a second queue would not speed it up.
        let captured = await withCheckedContinuation { continuation in
            windowServerQueue.async {
                let window = captureCGS(wid: wid, pixelHeight: pixelHeight)
                // Downscale off the serial queue so the next window's capture starts now.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: window.map { CapturedCGImage(image: downscaled($0, toPixelHeight: pixelHeight)) })
                }
            }
        }
        guard let cg = captured?.image else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated private static func captureCGS(wid: CGWindowID, pixelHeight: CGFloat) -> CGImage? {
        // Without the grant the WindowServer can hand back a blank frame instead of nil.
        guard CGPreflightScreenCaptureAccess(),
              let nominal = PrivateAPI.captureWindowImage(wid, nominalResolution: true),
              nominal.width > 1, nominal.height > 1 else { return nil }
        // A point-size capture has a quarter of the Retina pixels, so the downscale
        // to the tile costs about 2 ms of CPU instead of 5 with no visible difference.
        // Only a window shorter than the tile needs the backing-resolution capture.
        guard CGFloat(nominal.height) < pixelHeight.rounded() else { return nominal }
        return PrivateAPI.captureWindowImage(wid, nominalResolution: false) ?? nominal
    }

    /// Returns `cg` redrawn at `pixelHeight` (aspect preserved) when it is
    /// taller than the target, or as-is when it already fits.
    nonisolated private static func downscaled(_ cg: CGImage, toPixelHeight pixelHeight: CGFloat) -> CGImage {
        let targetH = max(1, Int(pixelHeight.rounded()))
        guard cg.height > targetH else { return cg }
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
        ) else { return cg }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return ctx.makeImage() ?? cg
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

    private var entries: [CGWindowID: Entry] = [:]
    /// Recency order, index 0 = least recently used.
    private var order: [CGWindowID] = []
    private(set) var totalCost = 0
    let countLimit: Int
    let costLimit: Int

    init(countLimit: Int, costLimit: Int) {
        self.countLimit = countLimit
        self.costLimit = costLimit
    }

    var count: Int { entries.count }

    /// Cached image for `wid`, bumping its recency on a hit.
    mutating func image(for wid: CGWindowID) -> NSImage? {
        guard let entry = entries[wid] else { return nil }
        bump(wid)
        return entry.image
    }

    /// Capture timestamp for `wid` without touching recency (freshness checks
    /// shouldn't keep an otherwise-unused entry alive).
    func capturedAt(for wid: CGWindowID) -> Date? {
        entries[wid]?.capturedAt
    }

    /// Insert or replace `wid`, then evict least-recently-used entries while
    /// over either limit. The just-inserted entry is never evicted: one
    /// oversized frame beats an empty cache.
    mutating func set(_ image: NSImage, cost: Int, capturedAt: Date, for wid: CGWindowID) {
        if let old = entries.removeValue(forKey: wid) {
            totalCost -= old.cost
            order.removeAll { $0 == wid }
        }
        entries[wid] = Entry(image: image, cost: cost, capturedAt: capturedAt)
        order.append(wid)
        totalCost += cost
        while entries.count > 1, entries.count > countLimit || totalCost > costLimit {
            let lru = order.removeFirst()
            if let evicted = entries.removeValue(forKey: lru) {
                totalCost -= evicted.cost
            }
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalCost = 0
    }

    private mutating func bump(_ wid: CGWindowID) {
        guard order.last != wid, let idx = order.firstIndex(of: wid) else { return }
        order.remove(at: idx)
        order.append(wid)
    }
}

private struct CapturedCGImage: @unchecked Sendable {
    /// CGImage is immutable and safe to retain/read across queues; CoreGraphics
    /// predates Swift Sendable annotations, so contain that guarantee here.
    let image: CGImage
}
