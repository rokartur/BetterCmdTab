import AppKit

/// Per-shortcut override editor (#74). Opened from the Shortcuts pane's
/// "Customize…" button for one panel-opening shortcut (Switch apps / Switch
/// windows / a scoped slot). Every option is tri-state: a popup whose first item
/// is "Use global default" (or, for sliders, an "Override" checkbox) leaves the
/// field unset so the shortcut inherits the global preference. The sheet edits a
/// local `ShortcutOverride` draft and only writes it back on Done — global panes
/// are never touched.
@MainActor
final class ShortcutOptionsSheetWindowController: NSWindowController {
    private let content: ShortcutOptionsViewController
    private var hasDismissed = false

    /// Called once after the sheet is dismissed (Done or Cancel).
    var onDidDismiss: (() -> Void)?

    init(title: String, target: SwitchTarget, includeSpaceScope: Bool, onDone: @escaping (ShortcutOverride) -> Void) {
        content = ShortcutOptionsViewController(target: target, includeSpaceScope: includeSpaceScope, onDone: onDone)
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 600))
        super.init(window: window)
        content.onClose = { [weak self] in self?.dismissSheet() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func present(asSheetFor parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
    }

    private func dismissSheet() {
        guard !hasDismissed, let window else { return }
        hasDismissed = true
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
        onDidDismiss?()
    }
}

/// Small `@objc` target wrapper so controls can fire a Swift closure without a
/// dedicated selector per option. Kept alive by the view controller.
@MainActor
private final class ClosureActionTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

@MainActor
final class ShortcutOptionsViewController: NSViewController {
    private let target: SwitchTarget
    private let includeSpaceScope: Bool
    private let onDone: (ShortcutOverride) -> Void
    var onClose: (() -> Void)?

    /// The working copy. Mutated by the controls; persisted only on Done.
    private var draft: ShortcutOverride
    private let prefs = Preferences.shared
    private let grid = NSGridView()
    /// Retains the closure targets wired to the controls.
    private var actionTargets: [ClosureActionTarget] = []

    private static let useGlobal = String(localized: "Use global default")

    init(target: SwitchTarget, includeSpaceScope: Bool, onDone: @escaping (ShortcutOverride) -> Void) {
        self.target = target
        self.includeSpaceScope = includeSpaceScope
        self.onDone = onDone
        self.draft = Preferences.shared.override(for: target)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 600))

        let intro = NSTextField(wrappingLabelWithString: String(localized: "Override the switcher and appearance options for this shortcut. Anything left on “Use global default” follows your global settings."))
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.translatesAutoresizingMaskIntoConstraints = false

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        buildRows()
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        grid.column(at: 1).leadingPadding = 0

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let clip = FlippedClipDocumentView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: clip.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 4),
            grid.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -4),
            grid.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -4),
        ])
        scroll.documentView = clip

        let resetButton = NSButton(title: String(localized: "Reset"), target: self, action: #selector(handleReset))
        resetButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(handleCancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let doneButton = NSButton(title: String(localized: "Done"), target: self, action: #selector(handleDone))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [resetButton, NSView(), cancelButton, doneButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(intro)
        root.addSubview(scroll)
        root.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            intro.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        view = root
    }

    // MARK: - Form

    private func buildRows() {
        addSectionHeader(String(localized: "Behavior"))
        if includeSpaceScope {
            addSpaceScopeRow()
        }
        addBoolRow(String(localized: "Show minimized windows"), global: prefs.showMinimizedWindows,
                   current: draft.showMinimized) { [weak self] in self?.draft.showMinimized = $0 }
        addBoolRow(String(localized: "Show hidden apps"), global: prefs.showHiddenApps,
                   current: draft.showHidden) { [weak self] in self?.draft.showHidden = $0 }
        addBoolRow(String(localized: "Show apps without windows"), global: prefs.showWindowlessApps,
                   current: draft.showWindowless) { [weak self] in self?.draft.showWindowless = $0 }
        addEnumRow(String(localized: "Sort order"), options: SwitcherSortOrder.allCases, display: \.displayName,
                   current: draft.sortOrder) { [weak self] in self?.draft.sortOrder = $0 }
        addBoolRow(String(localized: "Applications only"), global: prefs.applicationsOnly,
                   current: draft.applicationsOnly) { [weak self] in self?.draft.applicationsOnly = $0 }
        addBoolRow(String(localized: "Expand browser tabs as windows"), global: prefs.expandBrowserTabsAsWindows,
                   current: draft.expandBrowserTabsAsWindows) { [weak self] in self?.draft.expandBrowserTabsAsWindows = $0 }

        addSectionHeader(String(localized: "Appearance"))
        addEnumRow(String(localized: "Layout"), options: SwitcherLayoutMode.allCases, display: \.displayName,
                   current: draft.layoutMode) { [weak self] in self?.draft.layoutMode = $0 }
        addEnumRow(String(localized: "Panel size"), options: PanelSize.allCases, display: \.displayName,
                   current: draft.panelSize) { [weak self] in self?.draft.panelSize = $0 }
        // Accent: the fixed choices + System (per-shortcut custom hex stays a
        // global-only nicety — set it in Appearance and reference it there).
        addEnumRow(String(localized: "Accent color"), options: SwitcherAccent.allCases.filter { $0 != .custom },
                   display: \.displayName, current: draft.accentChoice) { [weak self] in self?.draft.accentChoice = $0 }
        addEnumRow(String(localized: "Backdrop material"), options: BackdropMaterial.allCases, display: \.displayName,
                   current: draft.backdropMaterial) { [weak self] in self?.draft.backdropMaterial = $0 }
        addEnumRow(String(localized: "Window title alignment"), options: PreviewTitleAlignment.allCases, display: \.displayName,
                   current: draft.previewTitleAlignment) { [weak self] in self?.draft.previewTitleAlignment = $0 }
        addSliderRow(String(localized: "Grid columns"), range: Preferences.gridMaxColumnsRange,
                     global: prefs.gridMaxColumns, current: draft.gridMaxColumns,
                     format: { $0 == 0 ? String(localized: "Auto") : String($0) }) { [weak self] in self?.draft.gridMaxColumns = $0 }
        addSliderRow(String(localized: "Opacity"), range: Preferences.panelOpacityRange,
                     global: prefs.panelOpacity, current: draft.panelOpacity,
                     format: { "\($0)%" }) { [weak self] in self?.draft.panelOpacity = $0 }
        addSliderRow(String(localized: "Corner radius"), range: Preferences.panelCornerRadiusRange,
                     global: prefs.panelCornerRadius, current: draft.panelCornerRadius,
                     format: { $0 == 0 ? String(localized: "Auto") : "\($0)" }) { [weak self] in self?.draft.panelCornerRadius = $0 }
        addBoolRow(String(localized: "Show window title"), global: prefs.showWindowTitleLabel,
                   current: draft.showWindowTitleLabel) { [weak self] in self?.draft.showWindowTitleLabel = $0 }
        addBoolRow(String(localized: "Show application names"), global: prefs.showApplicationNames,
                   current: draft.showApplicationNames) { [weak self] in self?.draft.showApplicationNames = $0 }
        addBoolRow(String(localized: "Bold the selected label"), global: prefs.boldSelectedLabel,
                   current: draft.boldSelectedLabel) { [weak self] in self?.draft.boldSelectedLabel = $0 }
        addBoolRow(String(localized: "Show unread badges"), global: prefs.showUnreadBadges,
                   current: draft.showUnreadBadges) { [weak self] in self?.draft.showUnreadBadges = $0 }
        addBoolRow(String(localized: "Show quick-jump letters"), global: prefs.letterHintsEnabled,
                   current: draft.letterHintsEnabled) { [weak self] in self?.draft.letterHintsEnabled = $0 }
    }

    private func addSectionHeader(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let row = grid.addRow(with: [label, NSGridCell.emptyContentView])
        row.topPadding = 6
    }

    private func titleLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        return label
    }

    /// A bool option as a 3-item popup: Use global default / On / Off.
    private func addBoolRow(_ title: String, global: Bool, current: Bool?, set: @escaping (Bool?) -> Void) {
        let popup = makePopup()
        popup.addItem(withTitle: Self.useGlobal)
        popup.addItem(withTitle: String(localized: "On"))
        popup.addItem(withTitle: String(localized: "Off"))
        popup.selectItem(at: current == nil ? 0 : (current! ? 1 : 2))
        wire(popup) {
            switch popup.indexOfSelectedItem {
            case 1: set(true)
            case 2: set(false)
            default: set(nil)
            }
        }
        grid.addRow(with: [titleLabel(title), popup])
    }

    /// An enum option as a popup with "Use global default" prepended.
    private func addEnumRow<T: Equatable>(_ title: String, options: [T], display: (T) -> String, current: T?, set: @escaping (T?) -> Void) {
        let popup = makePopup()
        popup.addItem(withTitle: Self.useGlobal)
        for option in options { popup.addItem(withTitle: display(option)) }
        if let current, let i = options.firstIndex(of: current) {
            popup.selectItem(at: i + 1)
        } else {
            popup.selectItem(at: 0)
        }
        wire(popup) {
            let i = popup.indexOfSelectedItem
            set(i == 0 ? nil : options[i - 1])
        }
        grid.addRow(with: [titleLabel(title), popup])
    }

    /// The tri-state Space scope (its own `.inherit` case is the "use global").
    private func addSpaceScopeRow() {
        let popup = makePopup()
        for option in SpaceScopeOverride.allCases { popup.addItem(withTitle: option.displayName) }
        popup.selectItem(at: SpaceScopeOverride.allCases.firstIndex(of: draft.spaceScope) ?? 0)
        wire(popup) { [weak self] in
            let i = popup.indexOfSelectedItem
            self?.draft.spaceScope = SpaceScopeOverride.allCases[safe: i] ?? .inherit
        }
        grid.addRow(with: [titleLabel(String(localized: "Spaces")), popup])
    }

    /// An Int option as an "Override" checkbox + slider + value label.
    private func addSliderRow(_ title: String, range: ClosedRange<Int>, global: Int, current: Int?, format: @escaping (Int) -> String, set: @escaping (Int?) -> Void) {
        let check = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        check.font = .systemFont(ofSize: 13)
        let slider = NSSlider(value: Double(current ?? global), minValue: Double(range.lowerBound), maxValue: Double(range.upperBound), target: nil, action: nil)
        slider.controlSize = .small
        slider.numberOfTickMarks = range.upperBound - range.lowerBound + 1
        slider.allowsTickMarkValuesOnly = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let valueLabel = NSTextField(labelWithString: format(current ?? global))
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let enabled = current != nil
        check.state = enabled ? .on : .off
        slider.isEnabled = enabled

        wire(slider) {
            let v = Int(slider.doubleValue.rounded())
            valueLabel.stringValue = format(v)
            if check.state == .on { set(v) }
        }
        wire(check) {
            let on = check.state == .on
            slider.isEnabled = on
            set(on ? Int(slider.doubleValue.rounded()) : nil)
        }

        let trailing = NSStackView(views: [valueLabel, slider])
        trailing.orientation = .horizontal
        trailing.spacing = 8
        trailing.alignment = .centerY
        grid.addRow(with: [check, trailing])
    }

    private func makePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setContentHuggingPriority(.required, for: .horizontal)
        return popup
    }

    private func wire(_ control: NSControl, _ handler: @escaping () -> Void) {
        let target = ClosureActionTarget(handler)
        control.target = target
        control.action = #selector(ClosureActionTarget.fire)
        actionTargets.append(target)
    }

    // MARK: - Actions

    @objc private func handleReset() {
        draft = ShortcutOverride()
        // Rebuild the form to reflect the cleared draft.
        for view in grid.subviews { view.removeFromSuperview() }
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        actionTargets.removeAll()
        buildRows()
    }

    @objc private func handleCancel() {
        onClose?()
    }

    @objc private func handleDone() {
        onDone(draft)
        onClose?()
    }
}

/// Flipped container so the grid lays out from the top of the scroll view.
@MainActor
private final class FlippedClipDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
