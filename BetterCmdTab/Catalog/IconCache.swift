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
        if let tab = row.browserTab,
           let key = BrowserFaviconCache.key(bundleID: row.bundleIdentifier, url: tab.url),
           let favicon = BrowserFaviconCache.image(forKey: key) {
            guard Preferences.shared.showBrowserIconOnTabs else { return favicon }
            let cacheKey = key as NSString
            // Identity check against the live favicon: BrowserFaviconCache
            // reloading a fresh favicon under the same key (site changed its
            // icon, cache eviction + re-read) hands back a new object, which
            // misses here and rebuilds the composite instead of serving the
            // stale one. On a hit the browser icon is never resolved — no
            // app-icon cache lookup, no wasted flatten.
            if let hit = badgedCache.object(forKey: cacheKey), hit.source === favicon {
                return hit.image
            }
            guard let browserIcon = appIcon(for: row) else { return favicon }
            let composite = badged(favicon, browserIcon: browserIcon)
            badgedCache.setObject(
                BadgedIcon(source: favicon, image: composite),
                forKey: cacheKey, cost: badgedBytesPerImage
            )
            return composite
        }
        return appIcon(for: row)
    }

    private static func appIcon(for row: SwitcherRow) -> NSImage? {
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
        badgedCache.removeAllObjects()
    }

    /// A composited favicon plus the favicon object it was built from, so a
    /// hit can cheaply detect that `BrowserFaviconCache` swapped in a fresh
    /// favicon (pointer compare) and rebuild instead of serving a stale badge.
    private final class BadgedIcon {
        let source: NSImage
        let image: NSImage
        init(source: NSImage, image: NSImage) {
            self.source = source
            self.image = image
        }
    }

    /// Favicons with the source browser's icon composited on (#131), keyed by
    /// the same bundleID+url favicon key so each tab pays the draw once.
    /// Count and cost limits agree (128 entries ≈ 8 MB) — a cost ceiling below
    /// the count limit would evict live composites on every reveal for users
    /// with more badged tab rows than the cost allows.
    private static let badgedCache: NSCache<NSString, BadgedIcon> = {
        let c = NSCache<NSString, BadgedIcon>()
        c.countLimit = maxCapacity
        c.totalCostLimit = maxCapacity * badgedBytesPerImage
        return c
    }()

    /// Drop all composited favicons. Called when the badge pref turns off so
    /// up to ~8 MB of now-unreachable composites don't sit resident.
    static func clearBadges() {
        badgedCache.removeAllObjects()
    }

    /// Composite the source browser's app icon onto the favicon's bottom-right
    /// quadrant. `browserIcon` is the already-flattened cached app icon, so the
    /// draw is a plain bitmap blit — no Tahoe AutoLayout hazard.
    /// ponytail: synchronous draw on the reveal path (~two blits per cold tab
    /// row, paid once per favicon); chunk-prewarm like app icons if a cold
    /// reveal with 50+ tab rows ever measures slow.
    /// Badge geometry, CSS-style absolute positioning: the favicon sits
    /// centered in a `faviconSlotFraction` box, the browser icon is a
    /// `badgeFraction` square anchored to the canvas's bottom-right corner —
    /// its size is set here, not by the favicon. (Browser app icons carry
    /// their own built-in transparent padding, so the visible glyph reads
    /// ~80% of the rect.)
    private static let faviconSlotFraction: CGFloat = 0.60
    private static let badgeFraction: CGFloat = 0.58
    /// Reported point size of every badged composite. Fixed — not derived from
    /// the favicon — so all tab rows render the same size: Safari ships 64px
    /// favicons while Chromium mostly stores 32px, and favicon-relative sizing
    /// made Safari rows visibly larger than the rest.
    private static let badgedPointSize: CGFloat = 64
    /// Raster edge for badged composites: 2× the fixed 64pt display size
    /// covers Retina exactly; rendering at `renderEdge` (256) would quadruple
    /// the per-entry cost for pixels the size clamp never shows.
    private static let badgedRenderEdge = 128
    private static let badgedBytesPerImage = badgedRenderEdge * badgedRenderEdge * 4

    private static func badged(_ favicon: NSImage, browserIcon: NSImage) -> NSImage {
        let pad = paddingFractions(of: browserIcon)
        let composite = renderBitmap(edge: badgedRenderEdge) { size in
            let edge = size.width
            let slot = edge * faviconSlotFraction
            let s = favicon.size
            let scale = min(slot / max(1, s.width), slot / max(1, s.height))
            let fit = NSSize(width: s.width * scale, height: s.height * scale)
            favicon.draw(
                in: NSRect(x: (edge - fit.width) / 2,
                           y: (edge - fit.height) / 2,
                           width: fit.width, height: fit.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            let badge = edge * badgeFraction
            // Push the rect past the canvas corner by the icon's *measured*
            // transparent padding: the visible glyph sits flush in the
            // bottom-right corner without getting clipped, whatever margins
            // this particular app icon ships with.
            browserIcon.draw(
                in: NSRect(x: edge - badge + badge * pad.right,
                           y: -badge * pad.bottom,
                           width: badge, height: badge),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }
        guard let composite else { return favicon }
        // The 256px raster stays as hi-DPI backing; the grid layout clamps
        // tab-row icons to `min(tileIconSize, image.size.width)`, so the
        // fixed point size keeps tab rows compact and uniform.
        composite.size = NSSize(width: badgedPointSize, height: badgedPointSize)
        return composite
    }

    /// Measured padding per flattened browser icon, weak-keyed so an entry
    /// dies with its icon. One probe per browser instead of one per favicon —
    /// a cold reveal with 40 tabs of one browser would otherwise re-scan the
    /// same immutable icon 40 times on the main thread.
    private static let paddingMemo = NSMapTable<NSImage, NSValue>(
        keyOptions: .weakMemory, valueOptions: .strongMemory
    )

    /// Fractions of `icon`'s edge that are fully transparent padding on its
    /// right and bottom sides, measured from a 32px alpha probe — app icons
    /// ship with varying built-in margins, and the badge is offset by exactly
    /// this much so its visible glyph lands flush in the canvas corner.
    /// Runs only on a badged-cache miss; memoized per icon object.
    private static func paddingFractions(of icon: NSImage) -> (right: CGFloat, bottom: CGFloat) {
        if let hit = paddingMemo.object(forKey: icon) {
            let p = hit.pointValue
            return (p.x, p.y)
        }
        let probe = 32
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: probe,
            pixelsHigh: probe,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return (0, 0) }
        rep.size = NSSize(width: probe, height: probe)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return (0, 0) }
        NSGraphicsContext.current = ctx
        icon.draw(
            in: NSRect(x: 0, y: 0, width: probe, height: probe),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        ctx.flushGraphics()
        guard let data = rep.bitmapData else { return (0, 0) }
        let bytesPerRow = rep.bytesPerRow
        let threshold: UInt8 = 16
        var maxX = -1
        var maxRow = -1  // rep row 0 is the top, so the largest row is the visual bottom
        for y in 0..<probe {
            let row = data + y * bytesPerRow
            for x in 0..<probe where row[x * 4 + 3] > threshold {
                if x > maxX { maxX = x }
                maxRow = y
            }
        }
        let fractions: (right: CGFloat, bottom: CGFloat) = maxX >= 0
            ? (CGFloat(probe - 1 - maxX) / CGFloat(probe), CGFloat(probe - 1 - maxRow) / CGFloat(probe))
            : (0, 0)
        paddingMemo.setObject(
            NSValue(point: NSPoint(x: fractions.right, y: fractions.bottom)),
            forKey: icon
        )
        return fractions
    }

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
        // Warm every uncached catalog app (a reveal configures every row
        // eagerly, so any cold icon is a synchronous flatten on the show
        // path), clamped to the cache's own count limit so a pathological
        // catalog can't flatten icons NSCache would immediately evict. The
        // 3-per-turn chunking below keeps each main-thread slice short and
        // lets a chord landing mid-prewarm reveal first; RSS stays bounded
        // by the cache's cost limit that `sizeToCatalog` just set.
        var targets: [pid_t] = []
        targets.reserveCapacity(min(pids.count, cache.countLimit))
        for pid in pids {
            if targets.count >= cache.countLimit { break }
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
        renderBitmap(edge: renderEdge) { size in
            image.draw(
                in: NSRect(origin: .zero, size: size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }
    }

    /// Shared offscreen-render scaffolding for `flattened` and `badged`:
    /// draw once into a fixed `edge`² RGBA bitmap and wrap it in an
    /// immutable `NSImage`. `draw` runs with the bitmap context current.
    private static func renderBitmap(edge: Int, _ draw: (NSSize) -> Void) -> NSImage? {
        let size = NSSize(width: edge, height: edge)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: edge,
            pixelsHigh: edge,
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
        draw(size)
        ctx.flushGraphics()
        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }
}
