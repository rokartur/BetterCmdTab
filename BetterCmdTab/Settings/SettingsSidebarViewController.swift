import AppKit
import QuartzCore

@MainActor
final class SettingsSidebarViewController: NSViewController {

    var onSelect: ((SettingsTab) -> Void)?

    private enum Metrics {
        static let sidebarHorizontalPadding: CGFloat = 9
        static let tabTrailingPadding: CGFloat = 6
        static let fallbackTopInset: CGFloat = 38
        static let topInsetBelowTrafficLights: CGFloat = 12
        static let bottomInset: CGFloat = 12
        static let tabWidth: CGFloat = 195
        static let tabHeight: CGFloat = 32
        static let tabContentPadding: CGFloat = 6
        // `NSTableView` in `.sourceList` style adds implicit 16pt horizontal
        // insets to cells. Compensate so the icon ends up 9pt from the row's
        // real left edge, matching the selection rectangle.
        static let sourceListLeadingInsetCompensation: CGFloat = 16
        static let sourceListTrailingInsetCompensation: CGFloat = 16
        static let tabContentGuideLeadingOffset: CGFloat = sidebarHorizontalPadding - sourceListLeadingInsetCompensation
        static let tabContentGuideTrailingOffset: CGFloat = sourceListTrailingInsetCompensation - tabTrailingPadding
        static let tabIconLeadingInset: CGFloat = tabContentPadding
        static let tabIconContainerSize: CGFloat = 20
        static let tabIconSize: CGFloat = 16
        static let tabIconCornerRadius: CGFloat = 5
        static let titleFontSize: CGFloat = 13
    }

    private static let columnID = NSUserInterfaceItemIdentifier("settings.sidebar.column")
    private static let cellID = NSUserInterfaceItemIdentifier("settings.sidebar.cell")

    private let tableView = ReclickableTableView()
    private let scrollView = NSScrollView()
    private let items = SettingsTab.allCases

    private var windowActivityObservers: [NSObjectProtocol] = []

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        view = container

        setupTable()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installWindowActivityObservers()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        installWindowActivityObservers()
        refreshVisibleRowStyles()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeWindowActivityObservers()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateTopInsetForTrafficLights()
    }

    deinit {
        for token in windowActivityObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Push the first sidebar row below the close/min/zoom buttons so it never
    /// appears tucked under the title bar when `.fullSizeContentView` is on.
    private func updateTopInsetForTrafficLights() {
        var topInset = Metrics.fallbackTopInset

        if let window = view.window,
           let closeButton = window.standardWindowButton(.closeButton) {
            let buttonFrame = view.convert(closeButton.bounds, from: closeButton)
            let bottomOfButtons = max(0, view.bounds.maxY - buttonFrame.minY)
            topInset = bottomOfButtons + Metrics.topInsetBelowTrafficLights
            topInset = min(max(topInset, Metrics.fallbackTopInset), 120)
        }

        guard abs(scrollView.contentInsets.top - topInset) > 0.5 else { return }
        scrollView.contentInsets.top = topInset
    }

    private func setupTable() {
        let column = NSTableColumn(identifier: Self.columnID)
        column.title = ""
        column.isEditable = false
        column.width = Metrics.tabWidth
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        tableView.addTableColumn(column)

        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = Metrics.tabHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.floatsGroupRows = false
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onSelectedRowReclicked = { [weak self] _ in
            guard let self else { return }
            let row = self.tableView.selectedRow
            guard row >= 0, row < self.items.count else { return }
            self.onSelect?(self.items[row])
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: Metrics.fallbackTopInset,
            left: 0,
            bottom: Metrics.bottomInset,
            right: 0
        )

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func selectInitial() {
        let alreadyOnFirstRow = tableView.selectedRow == 0
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        if alreadyOnFirstRow, !items.isEmpty {
            onSelect?(items[0])
        }
        refreshVisibleRowStyles()
    }

    func selectTab(_ tab: SettingsTab) {
        guard let index = items.firstIndex(of: tab) else { return }
        guard tableView.selectedRow != index else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        refreshVisibleRowStyles()
    }

    // MARK: - Window focus tracking

    private func installWindowActivityObservers() {
        guard windowActivityObservers.isEmpty else { return }

        let notifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification
        ]
        windowActivityObservers = notifications.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let observedWindow = notification.object as AnyObject? else { return }
                let observedID = ObjectIdentifier(observedWindow)
                MainActor.assumeIsolated {
                    guard let self,
                          let currentWindow = self.view.window,
                          ObjectIdentifier(currentWindow) == observedID else { return }
                    self.refreshVisibleRowStyles()
                }
            }
        }
    }

    private func removeWindowActivityObservers() {
        guard !windowActivityObservers.isEmpty else { return }
        for token in windowActivityObservers {
            NotificationCenter.default.removeObserver(token)
        }
        windowActivityObservers.removeAll()
    }

    private var isSelectionEmphasized: Bool {
        view.window?.isKeyWindow == true
    }

    private func refreshVisibleRowStyles() {
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.location != NSNotFound, visibleRange.length > 0 else { return }
        let upperBound = min(NSMaxRange(visibleRange), items.count)
        guard visibleRange.location < upperBound else { return }

        let emphasized = isSelectionEmphasized
        for row in visibleRange.location..<upperBound {
            if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView {
                rowView.selectionEmphasized = emphasized
            }
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarTabCellView {
                cell.applySelectionStyle(isSelected: tableView.selectedRow == row, isEmphasized: emphasized)
            }
        }
    }
}

// MARK: - DataSource / Delegate

extension SettingsSidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
}

extension SettingsSidebarViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < items.count else { return nil }
        let item = items[row]

        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? SidebarTabCellView)
            ?? makeSidebarCell()
        cell.configure(with: item)
        cell.applySelectionStyle(
            isSelected: tableView.selectedRow == row,
            isEmphasized: isSelectionEmphasized
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = SidebarRowView(
            maxContentWidth: Metrics.tabWidth,
            leadingInset: Metrics.sidebarHorizontalPadding,
            trailingInset: Metrics.tabTrailingPadding
        )
        rowView.selectionEmphasized = isSelectionEmphasized
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        onSelect?(items[row])
        refreshVisibleRowStyles()
    }

    private func makeSidebarCell() -> SidebarTabCellView {
        let cell = SidebarTabCellView()
        cell.identifier = Self.cellID

        let iconBackgroundView = SidebarIconBadgeView()
        iconBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        iconBackgroundView.wantsLayer = true
        iconBackgroundView.layer?.cornerRadius = Metrics.tabIconCornerRadius
        iconBackgroundView.layer?.cornerCurve = .continuous
        iconBackgroundView.layer?.masksToBounds = false
        cell.addSubview(iconBackgroundView)
        cell.iconBackgroundView = iconBackgroundView

        let iv = SidebarSymbolImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageAlignment = .alignCenter
        iv.imageScaling = .scaleProportionallyDown
        iconBackgroundView.addSubview(iv)
        cell.imageView = iv

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: Metrics.titleFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        cell.addSubview(titleLabel)
        cell.textField = titleLabel

        // Layout guide so the icon is positioned 9pt from the row's real left
        // edge (sidebar padding), compensating for the source list's 16pt
        // implicit cell inset.
        let contentGuide = NSLayoutGuide()
        cell.addLayoutGuide(contentGuide)
        let preferredContentWidth = contentGuide.widthAnchor.constraint(equalToConstant: Metrics.tabWidth)
        preferredContentWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            contentGuide.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Metrics.tabContentGuideLeadingOffset),
            preferredContentWidth,
            contentGuide.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: Metrics.tabContentGuideTrailingOffset),

            iconBackgroundView.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor, constant: Metrics.tabIconLeadingInset),
            iconBackgroundView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iconBackgroundView.widthAnchor.constraint(equalToConstant: Metrics.tabIconContainerSize),
            iconBackgroundView.heightAnchor.constraint(equalToConstant: Metrics.tabIconContainerSize),

            iv.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: Metrics.tabIconSize),
            iv.heightAnchor.constraint(equalToConstant: Metrics.tabIconSize),

            titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: Metrics.tabContentPadding),
            titleLabel.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor, constant: -Metrics.tabContentPadding),
            titleLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}

// MARK: - Reclickable table

private final class ReclickableTableView: NSTableView {
    var onSelectedRowReclicked: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let priorSelected = selectedRow
        let clickPoint = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: clickPoint)

        super.mouseDown(with: event)

        guard clickedRow >= 0,
              priorSelected == clickedRow,
              selectedRow == clickedRow else { return }
        onSelectedRowReclicked?(clickedRow)
    }
}

// MARK: - Sidebar row (rounded selection background)

private final class SidebarRowView: NSTableRowView {

    private let maxContentWidth: CGFloat
    private let leadingInset: CGFloat
    private let trailingInset: CGFloat
    private let cornerRadius: CGFloat = 8

    var selectionEmphasized: Bool = true {
        didSet {
            guard oldValue != selectionEmphasized else { return }
            needsDisplay = true
        }
    }

    init(maxContentWidth: CGFloat, leadingInset: CGFloat, trailingInset: CGFloat) {
        self.maxContentWidth = maxContentWidth
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        super.init(frame: .zero)
        selectionHighlightStyle = .regular
    }

    required init?(coder: NSCoder) { fatalCoderNotImplemented() }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }

        let availableWidth = max(0, bounds.width - leadingInset - trailingInset)
        let selectionWidth = min(maxContentWidth, availableWidth)
        guard selectionWidth > 0, bounds.height > 0 else { return }

        let selectionRect = NSRect(
            x: leadingInset,
            y: 0,
            width: selectionWidth,
            height: bounds.height
        )
        let path = NSBezierPath(
            roundedRect: selectionRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        let color: NSColor = selectionEmphasized
            ? .controlAccentColor
            : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        path.fill()
    }
}

// MARK: - Sidebar tab cell (gradient icon + title)

private final class SidebarTabCellView: NSTableCellView {

    var iconBackgroundView: SidebarIconBadgeView?
    private var baseTitleColor: NSColor = .labelColor

    private var titleLabel: NSTextField {
        textField ?? NSTextField(labelWithString: "")
    }

    func configure(with tab: SettingsTab) {
        titleLabel.stringValue = tab.title

        let palette = tab.iconPalette
        iconBackgroundView?.setGradient(
            startColor: palette.start,
            endColor: palette.end,
            opacity: 1.0
        )

        let config = NSImage.SymbolConfiguration(pointSize: palette.symbolPointSize, weight: palette.symbolWeight)
        let image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)?
            .withSymbolConfiguration(config)
        if let symbolView = imageView as? SidebarSymbolImageView {
            symbolView.image = image
            symbolView.lockedTintColor = palette.symbolColor
        } else {
            imageView?.image = image
            imageView?.contentTintColor = palette.symbolColor
        }
        baseTitleColor = .labelColor
    }

    func applySelectionStyle(isSelected: Bool, isEmphasized: Bool) {
        if isSelected && isEmphasized {
            titleLabel.textColor = .alternateSelectedControlTextColor
        } else if isSelected {
            titleLabel.textColor = baseTitleColor.applyingInactiveSelectedFactor()
        } else {
            titleLabel.textColor = baseTitleColor
        }
        iconBackgroundView?.setOpacityFactor(isEmphasized ? 1.0 : 0.7)
        imageView?.alphaValue = isEmphasized ? 1.0 : 0.9
    }
}

// MARK: - Gradient badge

private final class SidebarIconBadgeView: NSView {

    override var allowsVibrancy: Bool { false }

    private let gradientLayer = CAGradientLayer()
    private var currentStart: NSColor?
    private var currentEnd: NSColor?
    private var currentOpacity: CGFloat = 1.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        layer?.addSublayer(gradientLayer)
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 2.0
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.shadowOpacity = 0.35
    }

    required init?(coder: NSCoder) { fatalCoderNotImplemented() }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        gradientLayer.cornerRadius = layer?.cornerRadius ?? 0
        gradientLayer.cornerCurve = .continuous
        gradientLayer.masksToBounds = true
        if let cornerRadius = layer?.cornerRadius {
            layer?.shadowPath = CGPath(
                roundedRect: bounds,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        }
    }

    func setGradient(startColor: NSColor?, endColor: NSColor?, opacity: CGFloat) {
        currentStart = startColor
        currentEnd = endColor
        currentOpacity = max(0, min(opacity, 1))
        applyGradient()
    }

    func setOpacityFactor(_ factor: CGFloat) {
        currentOpacity = max(0, min(factor, 1))
        applyGradient()
    }

    private func applyGradient() {
        guard let start = currentStart, let end = currentEnd else {
            gradientLayer.colors = nil
            gradientLayer.isHidden = true
            layer?.borderWidth = 0
            layer?.borderColor = nil
            layer?.shadowOpacity = 0
            return
        }

        let opacity = currentOpacity
        let renderedStart = start.withAlphaComponent(start.alphaComponent * opacity)
        let renderedEnd = end.withAlphaComponent(end.alphaComponent * opacity)
        gradientLayer.isHidden = false
        gradientLayer.colors = [renderedStart.cgColor, renderedEnd.cgColor]
        layer?.borderWidth = 0.6
        layer?.borderColor = NSColor.white.withAlphaComponent(0.24 * opacity).cgColor
        layer?.shadowOpacity = Float(0.35 * opacity)
    }
}

// MARK: - Symbol image view with locked tint

private final class SidebarSymbolImageView: NSImageView {
    override var allowsVibrancy: Bool { false }

    var lockedTintColor: NSColor? {
        didSet { applyLockedTint() }
    }

    override var image: NSImage? {
        didSet {
            image?.isTemplate = true
            applyLockedTint()
        }
    }

    override var contentTintColor: NSColor? {
        get { super.contentTintColor }
        set {
            if let lockedTintColor {
                super.contentTintColor = lockedTintColor
            } else {
                super.contentTintColor = newValue
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowOpacity = 0
    }

    required init?(coder: NSCoder) { fatalCoderNotImplemented() }

    private func applyLockedTint() {
        guard image != nil else {
            contentTintColor = nil
            return
        }
        contentTintColor = lockedTintColor
    }
}

// MARK: - Inactive selection helpers

private extension NSColor {
    static let inactiveSelectedBrightnessFactor: CGFloat = 163.0 / 255.0

    func applyingInactiveSelectedFactor() -> NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        let factor = NSColor.inactiveSelectedBrightnessFactor
        return NSColor(
            calibratedRed: rgb.redComponent * factor,
            green: rgb.greenComponent * factor,
            blue: rgb.blueComponent * factor,
            alpha: rgb.alphaComponent
        )
    }
}
