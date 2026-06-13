import AppKit

@MainActor
enum IconCache {
    /// Floor on cached entries per cache. Halved from 64 → 32 once
    /// `prewarm` was dropped: cache fills on demand, not all at launch, so
    /// the working set in steady state is closer to "apps the user actually
    /// invokes" than "every running process". The running-app cache grows
    /// past this with the live catalog (see `sizeToCatalog`) so a panel
    /// listing >32 apps doesn't evict its own working set every reveal.
    private static let capacity = 32
    /// Ceiling when sizing to the live catalog — bounds the cost limit
    /// (~33 MB at 128 × 262 KB) for pathological app counts; NSCache still
    /// evicts under memory pressure below this.
    private static let maxCapacity = 128
    /// Edge length (px) of the flattened raster we cache. Sized just above the
    /// largest *typical* on-screen tile: the default "Medium" panel scale
    /// renders icons at ~77pt → 154px on a 2x Mac, and "Large" pushes the
    /// tile to ~190px. 256 keeps the largest case crisp while shaving 36%
    /// off the per-entry RAM (320² → 256²).
    private static let renderEdge = 256
    /// Byte cost of one flattened entry (used as the NSCache cost). A 256²
    /// RGBA bitmap is ~262 KB, so the cap doubles as a real memory ceiling
    /// (~8 MB per cache, ~16 MB across both — down from ~52 MB).
    private static let bytesPerImage = renderEdge * renderEdge * 4

    /// `NSCache` rather than a hand-rolled LRU dict so the system can evict
    /// flattened icons automatically under memory pressure (and the count/cost
    /// limits bound steady-state footprint). Keyed by pid for running apps.
    private static let cache: NSCache<NSNumber, NSImage> = {
        let c = NSCache<NSNumber, NSImage>()
        c.countLimit = capacity
        c.totalCostLimit = capacity * bytesPerImage
        return c
    }()
    /// Sibling cache for launchable + recently-closed rows that have no pid.
    /// Without this every search keystroke would re-fetch the disk icon for
    /// each of the up-to-8 launcher rows + recently-closed rows: a steady
    /// stream of `NSWorkspace.icon(forFile:)` calls on the main actor.
    private static let bundleCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = capacity
        c.totalCostLimit = capacity * bytesPerImage
        return c
    }()

    static func icon(for row: SwitcherRow) -> NSImage? {
        if let pid = row.pid {
            let key = NSNumber(value: pid)
            if let cached = cache.object(forKey: key) { return cached }
            guard let source = row.app?.icon else { return row.icon }
            let flat = flattened(source) ?? source
            cache.setObject(flat, forKey: key, cost: bytesPerImage)
            return flat
        }
        // No pid → launchable or recently-closed. Key by bundle ID so a
        // search session that lists the same apps on every keystroke reads
        // from memory instead of round-tripping `NSWorkspace`.
        guard let bundleID = row.bundleIdentifier, !bundleID.isEmpty else { return row.icon }
        let key = bundleID as NSString
        if let cached = bundleCache.object(forKey: key) { return cached }
        guard let source = row.icon else { return nil }
        let flat = flattened(source) ?? source
        bundleCache.setObject(flat, forKey: key, cost: bytesPerImage)
        return flat
    }

    static func evict(_ pid: pid_t) {
        cache.removeObject(forKey: NSNumber(value: pid))
    }

    static func clear() {
        cache.removeAllObjects()
        bundleCache.removeAllObjects()
    }

    /// Number of most-recent app icons to flatten ahead of the first reveal.
    /// Bounded well under `capacity` so prewarm can never inflate RSS toward
    /// the cache ceiling (~3 MB at 12 × 262 KB) — only the apps most likely to
    /// be on the first panel are warmed.
    private static let prewarmLimit = 12
    /// Icons flattened per run-loop turn. The flatten must stay on the main
    /// actor (it touches the AutoLayout engine under Tahoe — see `flattened`),
    /// so it is chunked across turns to keep any single main-thread slice short.
    private static let prewarmChunkSize = 3

    /// Flatten the most-recent app icons OFF the switcher show path so the first
    /// reveal doesn't pay a synchronous `flattened()` per uncached app — the
    /// dominant cause of the intermittent "switcher shows late" spike on a cold
    /// cache (first open after launch, after a layout-mode change, or after a
    /// memory-pressure eviction). Runs on the main actor — the flatten cannot go
    /// off-main without tripping the AutoLayout-engine assertion that retired
    /// the original *eager* prewarm — but in small `.common`-mode chunks, so it
    /// never stalls the run loop and RSS rises gradually instead of spiking ~12
    /// MB at once. Called from `AppCatalogCache`'s background-refresh main
    /// completion, where the freshest MRU order is known; already-cached pids
    /// are skipped, so a warm cache makes this a near-no-op.
    static func prewarm(pids: [pid_t]) {
        // `pids` is the full live catalog (MRU-first), so it doubles as the
        // working-set size signal: keep the cache large enough to hold every
        // app the panel can show, or each reveal re-flattens the overflow.
        sizeToCatalog(pids.count)
        var targets: [pid_t] = []
        targets.reserveCapacity(prewarmLimit)
        for pid in pids {
            if targets.count >= prewarmLimit { break }
            if cache.object(forKey: NSNumber(value: pid)) == nil { targets.append(pid) }
        }
        guard !targets.isEmpty else { return }
        warmChunk(targets, from: 0)
    }

    /// Resize the running-app cache to the live catalog, clamped to
    /// `capacity...maxCapacity`; the cost limit scales with it so it stays a
    /// real memory ceiling. The +8 margin absorbs apps launched between
    /// catalog refreshes without an immediate eviction.
    private static func sizeToCatalog(_ count: Int) {
        let limit = min(maxCapacity, max(capacity, count + 8))
        guard limit != cache.countLimit else { return }
        cache.countLimit = limit
        cache.totalCostLimit = limit * bytesPerImage
    }

    /// Flatten one chunk of `pids` on the main actor, then yield the run loop
    /// and schedule the next chunk in `.common` mode so a chord landing mid-
    /// prewarm runs its reveal ahead of the remaining flattens.
    private static func warmChunk(_ pids: [pid_t], from start: Int) {
        guard start < pids.count else { return }
        let end = min(start + prewarmChunkSize, pids.count)
        for i in start..<end {
            let key = NSNumber(value: pids[i])
            guard cache.object(forKey: key) == nil,
                  let source = NSRunningApplication(processIdentifier: pids[i])?.icon else { continue }
            let flat = flattened(source) ?? source
            cache.setObject(flat, forKey: key, cost: bytesPerImage)
        }
        guard end < pids.count else { return }
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { warmChunk(pids, from: end) }
        }
    }

    /// Rasterize an app icon into a fixed-size, immutable bitmap.
    ///
    /// On macOS 26 (Tahoe) the system restyles legacy app icons on the fly
    /// (rounded-rect mask + Liquid Glass material). `NSRunningApplication.icon`
    /// hands back a *live* `NSImage` whose representations IconServices fills in
    /// lazily: the view paints the raw `.icns` rep first, then AppKit swaps in
    /// the styled rendition under the same object — a visible old→new flicker.
    /// Drawing once into our own bitmap resolves the styled rendition right
    /// here and yields an image AppKit won't mutate afterwards, so the swap
    /// (and its flicker) can't happen. The styling cost is also paid once
    /// rather than on every redraw.
    ///
    /// `@MainActor` — bundle icons under Tahoe trigger AppKit view init
    /// during `image.draw`, which touches the AutoLayout engine. Running
    /// this off the main thread raised
    /// `NSInternalInconsistencyException: Modifications to the layout
    /// engine must not be performed from a background thread...`
    private static func flattened(_ image: NSImage) -> NSImage? {
        let size = NSSize(width: renderEdge, height: renderEdge)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: renderEdge,
            pixelsHigh: renderEdge,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        ctx.flushGraphics()
        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }
}
