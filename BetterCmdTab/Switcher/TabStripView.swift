import AppKit

/// Horizontal strip of tab titles shown below the switcher list while the user
/// is drilled into a browser/Finder row. Cells are title-only — no icons or
/// thumbnails — sized to ~22pt tall and laid out in a horizontal scroll view so
/// long tab sets stay reachable. Selection is keyboard-driven from the
/// `SwitcherController`; this view only renders.
@MainActor
protocol TabStripDelegate: AnyObject {
    func tabStrip(_ strip: TabStripView, didSelectIndex index: Int)
    func tabStrip(_ strip: TabStripView, didHoverIndex index: Int)
}

@MainActor
final class TabStripView: NSView {
    weak var delegate: TabStripDelegate?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var cells: [TabStripCell] = []
    private var accent: NSColor = .controlAccentColor
    private var selectedIndex: Int = 0

    static let stripHeight: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.scrollerStyle = .overlay

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.heightAnchor.constraint(equalToConstant: Self.stripHeight),
        ])
        scrollView.documentView = doc

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(titles: [String], selectedIndex: Int, accent: NSColor) {
        self.accent = accent
        self.selectedIndex = selectedIndex
        while cells.count < titles.count {
            let cell = TabStripCell()
            cell.onSelect = { [weak self] cell in
                guard let self, let i = self.cells.firstIndex(where: { $0 === cell }) else { return }
                self.delegate?.tabStrip(self, didSelectIndex: i)
            }
            cell.onHover = { [weak self] cell in
                guard let self, let i = self.cells.firstIndex(where: { $0 === cell }) else { return }
                self.delegate?.tabStrip(self, didHoverIndex: i)
            }
            stack.addArrangedSubview(cell)
            cells.append(cell)
        }
        while cells.count > titles.count {
            let cell = cells.removeLast()
            stack.removeArrangedSubview(cell)
            cell.removeFromSuperview()
        }
        for (i, title) in titles.enumerated() {
            cells[i].configure(title: title.isEmpty ? String(localized: "Untitled") : title,
                               selected: i == selectedIndex,
                               accent: accent)
        }
        scrollSelectedIntoView()
    }

    func setSelectedIndex(_ index: Int) {
        guard cells.indices.contains(index) else { return }
        selectedIndex = index
        for (i, cell) in cells.enumerated() {
            cell.setSelected(i == index, accent: accent)
        }
        scrollSelectedIntoView()
    }

    private func scrollSelectedIntoView() {
        guard cells.indices.contains(selectedIndex), let doc = scrollView.documentView else { return }
        let cell = cells[selectedIndex]
        let cellFrame = cell.convert(cell.bounds, to: doc)
        doc.scrollToVisible(cellFrame.insetBy(dx: -16, dy: 0))
    }
}

@MainActor
private final class TabStripCell: NSView {
    private let label = NSTextField(labelWithString: "")
    private var isSelected = false
    private var accentColor: NSColor = .controlAccentColor
    private var trackingArea: NSTrackingArea?
    private var mouseInside = false

    var onSelect: ((TabStripCell) -> Void)?
    var onHover: ((TabStripCell) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(title: String, selected: Bool, accent: NSColor) {
        label.stringValue = title
        isSelected = selected
        accentColor = accent
        applyAppearance()
    }

    func setSelected(_ selected: Bool, accent: NSColor) {
        isSelected = selected
        accentColor = accent
        applyAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        onHover?(self)
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(self)
    }

    private func applyAppearance() {
        if isSelected {
            layer?.backgroundColor = accentColor.withAlphaComponent(0.85).cgColor
            label.textColor = .white
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            label.textColor = .labelColor
        }
    }
}
