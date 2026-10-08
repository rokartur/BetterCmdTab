import AppKit

/// Panel content: the switcher, with the window shelf (#211) as its own glass block under it.
@MainActor
final class SwitcherStackView: NSView {
    private let switcher: SwitcherView
    private let shelf: SwitcherView
    private static let gap: CGFloat = 10

    /// What the shelf adds below the switcher; the panel keeps the switcher where
    /// it would sit alone and lets this hang under it.
    var shelfExtent: CGFloat { shelf.isHidden ? 0 : Self.gap + shelf.intrinsicContentSize.height }

    init(switcher: SwitcherView, shelf: SwitcherView) {
        self.switcher = switcher
        self.shelf = shelf
        super.init(frame: .zero)
        shelf.isHidden = true
        addSubview(switcher)
        addSubview(shelf)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var fittingSize: NSSize {
        let switcherSize = switcher.intrinsicContentSize
        guard !shelf.isHidden else { return switcherSize }
        return NSSize(width: max(switcherSize.width, shelf.intrinsicContentSize.width),
                      height: switcherSize.height + shelfExtent)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !shelf.isHidden else {
            switcher.frame = bounds
            return
        }
        let switcherSize = switcher.intrinsicContentSize
        let shelfSize = shelf.intrinsicContentSize
        // Pinned to opposite edges, so a resize glide never squeezes either block.
        let switcherWidth = min(switcherSize.width, bounds.width)
        let switcherHeight = min(switcherSize.height, bounds.height)
        switcher.frame = NSRect(x: ((bounds.width - switcherWidth) / 2).rounded(), y: bounds.height - switcherHeight,
                                width: switcherWidth, height: switcherHeight)
        let shelfWidth = min(shelfSize.width, bounds.width)
        shelf.frame = NSRect(x: ((bounds.width - shelfWidth) / 2).rounded(), y: 0,
                             width: shelfWidth, height: shelfSize.height)
    }
}
