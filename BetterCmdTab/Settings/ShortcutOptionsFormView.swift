import AppKit

/// Inline, live-persisting options form for one shortcut's per-shortcut override
/// (#74). Shown under the selected tab in `ShortcutsEditorView` (AltTab-style):
/// every control writes straight to `Preferences.shortcutOverrides` as the user
/// changes it — no draft / Done step. Each option is tri-state: a popup whose
/// first item is "Use global default" (or, for sliders, an "Override" checkbox)
/// leaves the field unset so the shortcut inherits the global preference.
@MainActor
final class ShortcutOptionsFormView: NSView {
    private let target: SwitchTarget
    private let includeSpaceScope: Bool
    private var override: ShortcutOverride
    private let prefs = Preferences.shared
    private let grid = NSGridView()
    private var actionTargets: [ClosureActionTarget] = []

    private static let useGlobal = String(localized: "Use global default")

    init(target: SwitchTarget, includeSpaceScope: Bool) {
        self.target = target
        self.includeSpaceScope = includeSpaceScope
        self.override = Preferences.shared.override(for: target)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setup() {
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        buildRows()
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing

        let reset = NSButton(title: String(localized: "Reset to global defaults"), target: self, action: #selector(handleReset))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.translatesAutoresizingMaskIntoConstraints = false

        addSubview(grid)
        addSubview(reset)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            reset.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            reset.leadingAnchor.constraint(equalTo: leadingAnchor),
            reset.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func persist() {
        prefs.setOverride(override, for: target)
    }

    // MARK: - Form

    private func buildRows() {
        addSectionHeader(String(localized: "Behavior"))
        if includeSpaceScope {
            addSpaceScopeRow()
        }
        addBoolRow(String(localized: "Show minimized windows"), current: override.showMinimized) { [weak self] in self?.override.showMinimized = $0; self?.persist() }
        addBoolRow(String(localized: "Show hidden apps"), current: override.showHidden) { [weak self] in self?.override.showHidden = $0; self?.persist() }
        addBoolRow(String(localized: "Show apps without windows"), current: override.showWindowless) { [weak self] in self?.override.showWindowless = $0; self?.persist() }
        addEnumRow(String(localized: "Sort order"), options: SwitcherSortOrder.allCases, display: \.displayName, current: override.sortOrder) { [weak self] in self?.override.sortOrder = $0; self?.persist() }
        addBoolRow(String(localized: "Applications only"), current: override.applicationsOnly) { [weak self] in self?.override.applicationsOnly = $0; self?.persist() }
        addBoolRow(String(localized: "Expand browser tabs as windows"), current: override.expandBrowserTabsAsWindows) { [weak self] in self?.override.expandBrowserTabsAsWindows = $0; self?.persist() }

        addSectionHeader(String(localized: "Appearance"))
        addEnumRow(String(localized: "Layout"), options: SwitcherLayoutMode.allCases, display: \.displayName, current: override.layoutMode) { [weak self] in self?.override.layoutMode = $0; self?.persist() }
        addEnumRow(String(localized: "Panel size"), options: PanelSize.allCases, display: \.displayName, current: override.panelSize) { [weak self] in self?.override.panelSize = $0; self?.persist() }
        addEnumRow(String(localized: "Accent color"), options: SwitcherAccent.allCases.filter { $0 != .custom }, display: \.displayName, current: override.accentChoice) { [weak self] in self?.override.accentChoice = $0; self?.persist() }
        addEnumRow(String(localized: "Backdrop material"), options: BackdropMaterial.allCases, display: \.displayName, current: override.backdropMaterial) { [weak self] in self?.override.backdropMaterial = $0; self?.persist() }
        addEnumRow(String(localized: "Window title alignment"), options: PreviewTitleAlignment.allCases, display: \.displayName, current: override.previewTitleAlignment) { [weak self] in self?.override.previewTitleAlignment = $0; self?.persist() }
        addSliderRow(String(localized: "Grid columns"), range: Preferences.gridMaxColumnsRange, global: prefs.gridMaxColumns, current: override.gridMaxColumns, format: { $0 == 0 ? String(localized: "Auto") : String($0) }) { [weak self] in self?.override.gridMaxColumns = $0; self?.persist() }
        addSliderRow(String(localized: "Opacity"), range: Preferences.panelOpacityRange, global: prefs.panelOpacity, current: override.panelOpacity, format: { "\($0)%" }) { [weak self] in self?.override.panelOpacity = $0; self?.persist() }
        addSliderRow(String(localized: "Corner radius"), range: Preferences.panelCornerRadiusRange, global: prefs.panelCornerRadius, current: override.panelCornerRadius, format: { $0 == 0 ? String(localized: "Auto") : "\($0)" }) { [weak self] in self?.override.panelCornerRadius = $0; self?.persist() }
        addBoolRow(String(localized: "Show window title"), current: override.showWindowTitleLabel) { [weak self] in self?.override.showWindowTitleLabel = $0; self?.persist() }
        addBoolRow(String(localized: "Show application names"), current: override.showApplicationNames) { [weak self] in self?.override.showApplicationNames = $0; self?.persist() }
        addBoolRow(String(localized: "Bold the selected label"), current: override.boldSelectedLabel) { [weak self] in self?.override.boldSelectedLabel = $0; self?.persist() }
        addBoolRow(String(localized: "Show unread badges"), current: override.showUnreadBadges) { [weak self] in self?.override.showUnreadBadges = $0; self?.persist() }
        addBoolRow(String(localized: "Show quick-jump letters"), current: override.letterHintsEnabled) { [weak self] in self?.override.letterHintsEnabled = $0; self?.persist() }
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

    private func addBoolRow(_ title: String, current: Bool?, set: @escaping (Bool?) -> Void) {
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

    private func addSpaceScopeRow() {
        let popup = makePopup()
        for option in SpaceScopeOverride.allCases { popup.addItem(withTitle: option.displayName) }
        popup.selectItem(at: SpaceScopeOverride.allCases.firstIndex(of: override.spaceScope) ?? 0)
        wire(popup) { [weak self] in
            let i = popup.indexOfSelectedItem
            self?.override.spaceScope = SpaceScopeOverride.allCases[safe: i] ?? .inherit
            self?.persist()
        }
        grid.addRow(with: [titleLabel(String(localized: "Spaces")), popup])
    }

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

    @objc private func handleReset() {
        override = ShortcutOverride()
        persist()
        // Rebuild the grid to reflect the cleared override.
        for view in grid.subviews { view.removeFromSuperview() }
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        actionTargets.removeAll()
        buildRows()
    }
}

/// Small `@objc` target wrapper so controls can fire a Swift closure without a
/// dedicated selector per option. Retained by the owning view.
@MainActor
final class ClosureActionTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
