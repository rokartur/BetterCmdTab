import AppKit

/// A small floating row of macOS "traffic light"–style circular buttons (close /
/// minimize / maximize / hide / quit) shown over a switcher row while the mouse
/// hovers it. Which buttons appear is driven by the `Preferences.hoverShow*`
/// toggles; the whole bar is shown/hidden by the host item view based on hover
/// state.
///
/// Clicks and per-dot hover are NOT handled by the dots themselves: the switcher
/// content lives inside an `NSGlassEffectView` whose hosted subtree doesn't
/// deliver mouse events to deep subviews, so `SwitcherView` does manual hit
/// testing (like its tile hit testing) and calls `action(atWindowPoint:)` /
/// `setHotAction(_:)` here.
@MainActor
final class HoverActionBar: NSView {
    /// Base dot diameter at scale 1.0; the live diameter scales with the
    /// switcher's current size so the buttons read at the same relative
    /// weight on every panel size.
    nonisolated static let baseDotSize: CGFloat = 14
    nonisolated private static let baseSpacing: CGFloat = 5

    /// Live scale factor; set by the host item view from `metrics.scale`.
    private var scaleFactor: CGFloat = 1.0
    var dotSize: CGFloat { round(Self.baseDotSize * scaleFactor) }
    private var spacing: CGFloat { round(Self.baseSpacing * scaleFactor) }

    private var dotsByAction: [RowAction: TrafficLightDot] = [:]
    private var orderedDots: [TrafficLightDot] = []

    /// The dot currently highlighted (mouse hovering it), if any.
    private(set) var hotAction: RowAction?

    private struct Spec {
        let action: RowAction
        let symbol: String
        let color: NSColor
        let tooltip: String
    }

    // Window controls borrow the real traffic-light colors (red / yellow /
    // green); app controls use neutral grays to read as a different group.
    private static let specs: [Spec] = [
        Spec(action: .close, symbol: "xmark", color: .systemRed, tooltip: String(localized: "Close window")),
        Spec(action: .minimize, symbol: "minus", color: .systemYellow, tooltip: String(localized: "Minimize window")),
        Spec(action: .maximize, symbol: "plus", color: .systemGreen, tooltip: String(localized: "Zoom window")),
        Spec(action: .hide, symbol: "eye.slash.fill", color: .systemGray, tooltip: String(localized: "Hide app")),
        Spec(action: .quit, symbol: "power", color: .systemGray, tooltip: String(localized: "Quit app")),
        Spec(action: .forceQuit, symbol: "xmark.octagon.fill", color: .systemRed, tooltip: String(localized: "Force quit app")),
    ]

    /// Whether the six dots have been materialized yet. Deferred so the
    /// off-by-default hover-actions feature costs the pooled item views nothing:
    /// building the dots means 6 `TrafficLightDot`s, each a constraint set + an
    /// SF-Symbol render, on every newly-allocated row. With every dot empty the
    /// bar's `contentSize` is `.zero` and it is never shown (the host item view
    /// gates on `hasAnyEnabledButton`), so we only pay this once the user
    /// actually enables an action — see `buildDotsIfNeeded`.
    private var dotsBuilt = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    private func buildDotsIfNeeded() {
        guard !dotsBuilt else { return }
        dotsBuilt = true
        for spec in Self.specs {
            let dot = TrafficLightDot(action: spec.action, color: spec.color, symbol: spec.symbol, tooltip: spec.tooltip)
            dotsByAction[spec.action] = dot
            orderedDots.append(dot)
            addSubview(dot)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        layoutDots()
    }

    /// Position the visible dots left-to-right. Called from `layout()` and from
    /// `applyEnabledButtons()` so frames are correct even when the bar's size
    /// doesn't change between reveals.
    private func layoutDots() {
        let d = dotSize
        let s = spacing
        var x: CGFloat = 0
        for dot in orderedDots where !dot.isHidden {
            dot.frame = NSRect(x: x, y: 0, width: d, height: d)
            x += d + s
        }
    }

    /// Exact size of the currently-visible dots; the host item view positions the
    /// bar using this so it never clips or stretches.
    var contentSize: NSSize {
        let visible = orderedDots.filter { !$0.isHidden }.count
        guard visible > 0 else { return .zero }
        let d = dotSize
        let width = CGFloat(visible) * d + CGFloat(visible - 1) * spacing
        return NSSize(width: width, height: d)
    }

    /// Width the bar occupies for `count` visible dots at `scale`, without needing
    /// a live instance. `SwitcherMetrics` uses this to reserve a List-layout column
    /// for the bar when app names are hidden (otherwise the dots overlap the title).
    nonisolated static func contentWidth(visibleCount count: Int, scale: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let d = round(baseDotSize * scale)
        let s = round(baseSpacing * scale)
        return CGFloat(count) * d + CGFloat(count - 1) * s
    }

    /// Apply the current switcher scale to the bar so its dots match the
    /// active panel size. Triggers a relayout of the visible dots.
    func setScale(_ value: CGFloat) {
        guard value != scaleFactor else { return }
        scaleFactor = value
        layoutDots()
        invalidateIntrinsicContentSize()
    }

    /// Shrink the dots so the bar fits within `maxWidth`. Used by the grid
    /// tile, whose tile width is fixed and would otherwise be overrun by the
    /// full-size dots when every button is enabled (six dots × 14pt + spacing
    /// quickly exceeds a small grid tile, pushing the outer two past the
    /// hit-test bounds and making them unclickable).
    func fitWidth(_ maxWidth: CGFloat) {
        guard maxWidth > 0 else { return }
        let visible = orderedDots.filter { !$0.isHidden }.count
        guard visible > 0 else { return }
        let needed = contentSize.width
        if needed <= maxWidth { return }
        let downscale = maxWidth / needed
        let newScale = scaleFactor * downscale
        guard abs(newScale - scaleFactor) > 0.001 else { return }
        scaleFactor = newScale
        layoutDots()
        invalidateIntrinsicContentSize()
    }

    /// Show/hide each dot per the user's per-action preferences.
    func applyEnabledButtons() {
        // Don't materialize the dots for the off-by-default case: an unbuilt bar
        // has zero `contentSize` and is never shown. Only build once at least one
        // action is enabled.
        guard hasAnyEnabledButton else { return }
        buildDotsIfNeeded()
        let prefs = Preferences.shared
        dotsByAction[.close]?.isHidden = !prefs.hoverShowClose
        dotsByAction[.minimize]?.isHidden = !prefs.hoverShowMinimize
        dotsByAction[.maximize]?.isHidden = !prefs.hoverShowMaximize
        dotsByAction[.hide]?.isHidden = !prefs.hoverShowHide
        dotsByAction[.quit]?.isHidden = !prefs.hoverShowQuit
        dotsByAction[.forceQuit]?.isHidden = !prefs.hoverShowForceQuit
        layoutDots()
    }

    /// True when at least one action button is enabled.
    var hasAnyEnabledButton: Bool {
        let prefs = Preferences.shared
        return prefs.hoverShowClose || prefs.hoverShowMinimize || prefs.hoverShowMaximize
            || prefs.hoverShowHide || prefs.hoverShowQuit || prefs.hoverShowForceQuit
    }

    /// The action whose dot contains `windowPoint` (in window coordinates), or
    /// nil. Used by `SwitcherView`'s manual hit testing.
    func action(atWindowPoint windowPoint: NSPoint) -> RowAction? {
        for dot in orderedDots where !dot.isHidden {
            let p = dot.convert(windowPoint, from: nil)
            if dot.bounds.contains(p) { return dot.action }
        }
        return nil
    }

    /// Highlight the given dot (mouse hovering it) and un-highlight the rest.
    func setHotAction(_ action: RowAction?) {
        guard hotAction != action else { return }
        hotAction = action
        for dot in orderedDots { dot.isHot = (dot.action == action) }
    }
}

/// A single circular traffic-light dot. The circle is custom-drawn; the
/// glyph rides as a centered `NSImageView` so AppKit aligns the symbol's
/// actual cap-height optical center to the dot center (manually computing
/// `bounds.midX - gs.width/2` lands the bbox center, not the visual center
/// — SF Symbols ship with asymmetric ascender/descender padding that
/// shifted every glyph half a pixel off-center). Re-rendering the symbol on
/// each resize keeps it sharp at every switcher scale.
@MainActor
final class TrafficLightDot: NSView {
    let action: RowAction

    private let fillColor: NSColor
    private let symbolName: String
    private let glyphView = NSImageView()
    var isHot = false { didSet { if oldValue != isHot { needsDisplay = true } } }

    init(action: RowAction, color: NSColor, symbol: String, tooltip: String) {
        self.action = action
        self.fillColor = color
        self.symbolName = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: HoverActionBar.baseDotSize, height: HoverActionBar.baseDotSize))
        toolTip = tooltip

        glyphView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.imageScaling = .scaleProportionallyDown
        glyphView.imageAlignment = .alignCenter
        addSubview(glyphView)
        NSLayoutConstraint.activate([
            glyphView.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyphView.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphView.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.62),
            glyphView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.62),
        ])
        rebuildGlyph(for: bounds.height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: HoverActionBar.baseDotSize, height: HoverActionBar.baseDotSize)
    }

    override func layout() {
        super.layout()
        rebuildGlyph(for: bounds.height)
    }

    /// SF Symbol's point size is what determines stroke weight — set it from
    /// the live dot height so the glyph keeps its proportional weight at
    /// every panel scale, instead of staying glued to the base 8pt size.
    private func rebuildGlyph(for dotHeight: CGFloat) {
        let pointSize = max(6, round(dotHeight * 0.55))
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            .applying(.init(paletteColors: [NSColor.black.withAlphaComponent(0.65)]))
        glyphView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    override func draw(_ dirtyRect: NSRect) {
        let d = min(bounds.width, bounds.height)
        let circle = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: circle)
        // Brighten on hover for a clear "hot" state.
        let fill = isHot ? (fillColor.blended(withFraction: 0.28, of: .white) ?? fillColor) : fillColor
        fill.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(isHot ? 0.28 : 0.18).setStroke()
        path.lineWidth = isHot ? 0.75 : 0.5
        path.stroke()
    }
}
