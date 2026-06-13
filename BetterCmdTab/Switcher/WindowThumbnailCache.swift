import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Live window-preview cache for the alt-tab–style `windowPreview` layout.
///
/// Captures a still image of a window by its `CGWindowID` and caches it keyed
/// by that id. Capture is asynchronous and off the reveal critical path: the
/// preview tile shows the app icon as a placeholder and swaps in the thumbnail
/// via `onReady` once it lands.
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
    var onReady: ((CGWindowID) -> Void)?

    private let cache = NSCache<NSNumber, NSImage>()
    private var inFlight = Set<CGWindowID>()
    private var capturedAt: [CGWindowID: Date] = [:]
    private var didRequestPermission = false

    /// How long a captured frame is reused before a reveal triggers a silent
    /// background recapture. Reopening the switcher within this window shows the
    /// last frame instantly (no app-icon flash); past it the stale frame still
    /// shows immediately while a fresh capture swaps in via `onReady`.
    private let refreshTTL: TimeInterval = 2.0

    private init() {
        // Preview mode rarely surfaces more than ~24 windows at once (one row
        // per visible window of the front app); cap at 32 so the cache holds
        // a generous working set without retaining stale captures from
        // long-past reveals that would never be reused.
        cache.countLimit = 32
        // Cost-side ceiling so a 4K thumbnail can't single-handedly evict the
        // rest of the cache by counting as 32MB on its own. Anchored to a
        // typical Retina preview tile (~512×288 RGBA ≈ 590KB) × the count
        // limit, with headroom for occasional wider previews.
        cache.totalCostLimit = 32 * 600_000
    }

    /// Cached thumbnail for `wid`, or nil if not captured yet.
    func image(for wid: CGWindowID) -> NSImage? {
        guard wid != 0 else { return nil }
        return cache.object(forKey: NSNumber(value: wid))
    }

    /// Ensure `wid` has a reasonably fresh thumbnail. Skips work when a frame
    /// captured within `refreshTTL` is already cached (so a quick reopen shows it
    /// instantly with no flash) and when a capture is already in flight.
    /// Otherwise it (re)captures in the background; the existing frame — or the
    /// caller's app-icon placeholder when there is none yet — stays on screen
    /// until the new one lands via `onReady`. `pixelHeight` is the target raster
    /// height so the capture stays crisp on Retina without over-allocating.
    func request(wid: CGWindowID, pixelHeight: CGFloat) {
        guard wid != 0, !inFlight.contains(wid) else { return }
        if cache.object(forKey: NSNumber(value: wid)) != nil,
           let ts = capturedAt[wid], Date().timeIntervalSince(ts) < refreshTTL {
            return
        }
        inFlight.insert(wid)
        Task { [weak self] in
            let image = await Self.capture(wid: wid, pixelHeight: pixelHeight)
            self?.store(image, for: wid)
        }
    }

    private func store(_ image: NSImage?, for wid: CGWindowID) {
        inFlight.remove(wid)
        guard let image else { return }
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: NSNumber(value: wid), cost: cost)
        capturedAt[wid] = Date()
        // `capturedAt` isn't evicted by NSCache; cap it so it can't grow without
        // bound over a long session (forces a one-off recapture round at most).
        if capturedAt.count > 256 { capturedAt.removeAll(keepingCapacity: true) }
        onReady?(wid)
    }

    /// Drop every cached thumbnail (e.g. under memory pressure). Not called on
    /// dismiss — frames are kept warm across reveals so reopening the switcher
    /// shows them instantly instead of flashing app icons first.
    func clear() {
        cache.removeAllObjects()
        capturedAt.removeAll()
        inFlight.removeAll()
    }

    /// Prompt for Screen Recording once per launch, the first time the preview
    /// layout is shown. The capture APIs prompt on their own, but a cold first
    /// use can otherwise return nil silently before the user has granted it.
    func ensurePermission() {
        guard !didRequestPermission else { return }
        didRequestPermission = true
        DispatchQueue.global(qos: .utility).async {
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
        }
    }

    // MARK: - Capture

    nonisolated private static func capture(wid: CGWindowID, pixelHeight: CGFloat) async -> NSImage? {
        if #available(macOS 14.0, *) {
            if let image = await captureSCK(wid: wid, pixelHeight: pixelHeight) {
                return image
            }
        }
        return captureCG(wid: wid, pixelHeight: pixelHeight)
    }

    @available(macOS 14.0, *)
    nonisolated private static func captureSCK(wid: CGWindowID, pixelHeight: CGFloat) async -> NSImage? {
        guard let scWindow = await SCWindowProvider.shared.window(for: wid) else { return nil }
        let frame = scWindow.frame
        guard frame.height > 1, frame.width > 1 else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        // Match the window's aspect ratio, capped to the on-screen tile height.
        // `frame` is in points while `pixelHeight` is pixels; assume Retina 2x
        // for the window's native pixel height (the min() with `pixelHeight`
        // keeps the capture from over-allocating on 1x displays anyway).
        let aspect = frame.width / frame.height
        let h = max(1, min(frame.height * 2, pixelHeight))
        config.height = Int(h.rounded())
        config.width = max(1, Int((h * aspect).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true

        do {
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } catch {
            return nil
        }
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

/// Short-lived cache of `SCShareableContent` so a single reveal enumerates the
/// window list once instead of once per captured window (the enumeration is the
/// expensive part of an `SCScreenshotManager` capture).
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

    func window(for wid: CGWindowID) async -> SCWindow? {
        let entered = Date()
        if entered.timeIntervalSince(fetchedAt) >= ttl {
            await refresh()
        }
        if let cached = windowsByID[wid] { return cached }
        // Miss on a freshly opened window — refetch once before giving up,
        // but only when the map predates this call (a refresh that already
        // completed above wouldn't find it the second time either).
        if fetchedAt < entered {
            await refresh()
        }
        return windowsByID[wid]
    }

    private func refresh() async {
        guard Date().timeIntervalSince(lastFailureAt) >= failureBackoff else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            windowsByID = Dictionary(
                content.windows.map { ($0.windowID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            fetchedAt = Date()
        } catch {
            // Permission missing or transient failure — leave the previous map
            // (possibly empty); the CG fallback path still gets a chance.
            fetchedAt = .distantPast
            lastFailureAt = Date()
        }
    }
}
