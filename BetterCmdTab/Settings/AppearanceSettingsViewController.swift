import AppKit
import BetterSettings
import Combine

@MainActor
final class AppearanceSettingsViewController: SettingsTabViewController {

    private var layoutRadio: SettingsRadioGroupView!
    private var sizeRadio: SettingsRadioGroupView!
    private let gridPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let accentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let delaySlider = NSSlider()
    private let delayValueLabel = NSTextField(labelWithString: "")
    private let windowTitleSwitch = NSSwitch()
    private let appNamesSwitch = NSSwitch()
    private let opacitySlider = NSSlider()
    private let opacityValueLabel = NSTextField(labelWithString: "")
    private let radiusSlider = NSSlider()
    private let radiusValueLabel = NSTextField(labelWithString: "")

    private var cancellables = Set<AnyCancellable>()

    // Ordered option models backing the popups (index ↔ value).
    private let layoutModes: [SwitcherLayoutMode] = [.gridView, .list, .windowPreview]
    private let panelSizes: [PanelSize] = PanelSize.allCases
    private let gridValues: [Int] = [0, 2, 3, 4, 5, 6] // 0 = automatic
    private let accents: [SwitcherAccent] = SwitcherAccent.allCases

    override func setupContent() {
        let section = addSection(title: String(localized: "Switcher"), anchor: SettingsAnchor.appearance)

        layoutRadio = makeLayoutRadio()
        addRow(to: section, title: String(localized: "Layout"), accessory: layoutRadio, searchItemID: SearchID.layout)

        sizeRadio = makeSizeRadio()
        addRow(to: section, title: String(localized: "Size"), accessory: sizeRadio, searchItemID: SearchID.size)

        configurePopup(gridPopup, titles: gridValues.map { $0 == 0 ? String(localized: "Automatic") : "\($0)" }, action: #selector(gridChanged))
        addRow(to: section, title: String(localized: "Grid columns"),
               subtitle: String(localized: "Applies to the Grid and Previews layouts."),
               accessory: gridPopup, searchItemID: SearchID.gridColumns)

        configurePopup(accentPopup, titles: accents.map(\.displayName), action: #selector(accentChanged))
        for (i, accent) in accents.enumerated() {
            accentPopup.item(at: i)?.image = Self.swatch(for: accent)
        }
        addRow(to: section, title: String(localized: "Accent color"),
               subtitle: String(localized: "Color of the selection highlight and jump letters."),
               accessory: accentPopup, searchItemID: SearchID.accent)

        delaySlider.minValue = Double(Preferences.revealDelayRange.lowerBound)
        delaySlider.maxValue = Double(Preferences.revealDelayRange.upperBound)
        delaySlider.isContinuous = true
        delaySlider.target = self
        delaySlider.action = #selector(delayChanged(_:))
        delaySlider.translatesAutoresizingMaskIntoConstraints = false

        delayValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        delayValueLabel.textColor = .secondaryLabelColor
        delayValueLabel.alignment = .right
        delayValueLabel.translatesAutoresizingMaskIntoConstraints = false
        delayValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let sliderStack = NSStackView(views: [delaySlider, delayValueLabel])
        sliderStack.orientation = .horizontal
        sliderStack.spacing = 8
        sliderStack.alignment = .centerY
        NSLayoutConstraint.activate([
            delaySlider.widthAnchor.constraint(equalToConstant: 140),
            delayValueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        addRow(to: section, title: String(localized: "Quick-switch delay"),
               subtitle: String(localized: "Tap to switch instantly; hold longer to open the switcher."),
               accessory: sliderStack, searchItemID: SearchID.quickSwitchDelay)

        configureSwitch(windowTitleSwitch, action: #selector(toggleWindowTitle(_:)))
        addRow(to: section, title: String(localized: "Show window title"),
               subtitle: String(localized: "Show each window's title under the icon in the Grid and Previews layouts."),
               accessory: windowTitleSwitch, searchItemID: SearchID.windowTitle)

        configureSwitch(appNamesSwitch, action: #selector(toggleApplicationNames(_:)))
        addRow(to: section, title: String(localized: "Show application names"),
               subtitle: String(localized: "Hide the app name in every layout; identify apps by their icon."),
               accessory: appNamesSwitch, searchItemID: SearchID.applicationNames)

        let opacityStack = makeSliderControl(
            opacitySlider, valueLabel: opacityValueLabel,
            range: Preferences.panelOpacityRange, action: #selector(opacityChanged(_:))
        )
        addRow(to: section, title: String(localized: "Panel opacity"),
               subtitle: String(localized: "Translucency of the switcher panel."),
               accessory: opacityStack, searchItemID: SearchID.opacity)

        let radiusStack = makeSliderControl(
            radiusSlider, valueLabel: radiusValueLabel,
            range: Preferences.panelCornerRadiusRange, action: #selector(radiusChanged(_:))
        )
        addRow(to: section, title: String(localized: "Corner radius"),
               subtitle: String(localized: "Rounding of the panel's corners. Automatic follows the panel size."),
               accessory: radiusStack, searchItemID: SearchID.cornerRadius)
    }

    private func configureSwitch(_ toggle: NSSwitch, action: Selector) {
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action
    }

    /// Builds a horizontal slider + right-aligned monospaced value label, matching
    /// the quick-switch delay control. The caller wires `viewWillAppear` sync.
    private func makeSliderControl(_ slider: NSSlider, valueLabel: NSTextField, range: ClosedRange<Int>, action: Selector) -> NSView {
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = action
        slider.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [slider, valueLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        NSLayoutConstraint.activate([
            slider.widthAnchor.constraint(equalToConstant: 140),
            valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        return stack
    }

    /// Small filled-circle swatch shown beside each accent menu item. The
    /// `.system` choice is drawn with the live accent color so it always
    /// previews the user's macOS setting.
    private static func swatch(for accent: SwitcherAccent) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.isTemplate = false
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: rect)
        // The custom choice previews the stored hex so its swatch tracks the
        // user's pick instead of the system accent fallback in `resolved`.
        let fill: NSColor
        if accent == .custom {
            fill = Preferences.shared.customAccentHex.flatMap(NSColor.init(hexString:)) ?? .controlAccentColor
        } else {
            fill = accent.resolved
        }
        fill.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        path.lineWidth = 1
        path.stroke()
        image.unlockFocus()
        return image
    }

    private func makeLayoutRadio() -> SettingsRadioGroupView {
        let options = layoutModes.map { mode in
            SettingsRadioGroupView.Option(identifier: mode.rawValue, title: mode.displayName)
        }
        let group = SettingsRadioGroupView(options: options, orientation: .horizontal)
        group.onSelectionChange = { id in
            guard let mode = SwitcherLayoutMode(rawValue: id) else { return }
            Preferences.shared.switcherLayoutMode = mode
        }
        return group
    }

    private func makeSizeRadio() -> SettingsRadioGroupView {
        let options = panelSizes.map { size in
            SettingsRadioGroupView.Option(identifier: size.rawValue, title: size.displayName)
        }
        let group = SettingsRadioGroupView(options: options, orientation: .horizontal)
        group.onSelectionChange = { id in
            guard let size = PanelSize(rawValue: id) else { return }
            Preferences.shared.panelSize = size
        }
        return group
    }

    private func configurePopup(_ popup: NSPopUpButton, titles: [String], action: Selector) {
        popup.controlSize = .small
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.setContentHuggingPriority(.required, for: .horizontal)
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        syncFromPreferences()

        let prefs = Preferences.shared
        prefs.$switcherLayoutMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectLayout($0) }
            .store(in: &cancellables)
        prefs.$panelSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectSize($0) }
            .store(in: &cancellables)
        prefs.$gridMaxColumns
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectGrid($0) }
            .store(in: &cancellables)
        prefs.$revealDelayMs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyDelay($0) }
            .store(in: &cancellables)
        prefs.$accentChoice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectAccent($0) }
            .store(in: &cancellables)
        prefs.$customAccentHex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshCustomSwatch() }
            .store(in: &cancellables)
        prefs.$showWindowTitleLabel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.windowTitleSwitch.state = $0 ? .on : .off }
            .store(in: &cancellables)
        prefs.$showApplicationNames
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.appNamesSwitch.state = $0 ? .on : .off }
            .store(in: &cancellables)
        prefs.$panelOpacity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyOpacity($0) }
            .store(in: &cancellables)
        prefs.$panelCornerRadius
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyRadius($0) }
            .store(in: &cancellables)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancellables.removeAll()
        // The shared color panel keeps a non-zeroing target/action. The settings
        // window is `.releaseOnClose`, so leaving this wired would let a later
        // color change message a deallocated controller (EXC_BAD_ACCESS). Detach
        // ourselves whenever we own the panel (NSColorPanel exposes no target
        // getter, so we track ownership explicitly).
        if ownsColorPanel {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
            ownsColorPanel = false
        }
    }

    private func syncFromPreferences() {
        let prefs = Preferences.shared
        selectLayout(prefs.switcherLayoutMode)
        selectSize(prefs.panelSize)
        selectGrid(prefs.gridMaxColumns)
        applyDelay(prefs.revealDelayMs)
        selectAccent(prefs.accentChoice)
        windowTitleSwitch.state = prefs.showWindowTitleLabel ? .on : .off
        appNamesSwitch.state = prefs.showApplicationNames ? .on : .off
        applyOpacity(prefs.panelOpacity)
        applyRadius(prefs.panelCornerRadius)
        refreshCustomSwatch()
    }

    private func selectLayout(_ mode: SwitcherLayoutMode) {
        layoutRadio.select(identifier: mode.rawValue)
    }

    private func selectSize(_ size: PanelSize) {
        sizeRadio.select(identifier: size.rawValue)
    }

    private func selectGrid(_ value: Int) {
        // Drop any transient item added for an out-of-list value on a previous
        // sync so the popup matches `gridValues` again.
        while gridPopup.numberOfItems > gridValues.count {
            gridPopup.removeItem(at: gridPopup.numberOfItems - 1)
        }
        if let i = gridValues.firstIndex(of: value) {
            gridPopup.selectItem(at: i)
        } else {
            // An imported (hand-edited) cap like 7–12 is valid and actively caps
            // the grid but isn't offered here. Show it as an extra entry so the
            // popup can't mislabel it "Automatic"; re-picking it is a no-op
            // (`gridChanged` ignores out-of-list indices) and any other pick is
            // an informed overwrite.
            gridPopup.addItem(withTitle: "\(value)")
            gridPopup.selectItem(at: gridPopup.numberOfItems - 1)
        }
    }

    private func applyDelay(_ ms: Int) {
        if Int(delaySlider.intValue) != ms { delaySlider.integerValue = ms }
        delayValueLabel.stringValue = "\(ms) ms"
    }

    private func selectAccent(_ accent: SwitcherAccent) {
        if let i = accents.firstIndex(of: accent) { accentPopup.selectItem(at: i) }
    }

    @objc private func gridChanged() {
        let i = gridPopup.indexOfSelectedItem
        guard gridValues.indices.contains(i) else { return }
        Preferences.shared.gridMaxColumns = gridValues[i]
    }

    @objc private func accentChanged() {
        let i = accentPopup.indexOfSelectedItem
        guard accents.indices.contains(i) else { return }
        let choice = accents[i]
        Preferences.shared.accentChoice = choice
        if choice == .custom { presentColorPanel() }
    }

    @objc private func delayChanged(_ sender: NSSlider) {
        Preferences.shared.revealDelayMs = sender.integerValue
    }

    @objc private func toggleWindowTitle(_ sender: NSSwitch) {
        Preferences.shared.showWindowTitleLabel = (sender.state == .on)
    }

    @objc private func toggleApplicationNames(_ sender: NSSwitch) {
        Preferences.shared.showApplicationNames = (sender.state == .on)
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        Preferences.shared.panelOpacity = sender.integerValue
        opacityValueLabel.stringValue = "\(sender.integerValue)%"
    }

    @objc private func radiusChanged(_ sender: NSSlider) {
        Preferences.shared.panelCornerRadius = sender.integerValue
        radiusValueLabel.stringValue = sender.integerValue == 0 ? String(localized: "Auto") : "\(sender.integerValue) pt"
    }

    private func applyOpacity(_ value: Int) {
        if opacitySlider.integerValue != value { opacitySlider.integerValue = value }
        opacityValueLabel.stringValue = "\(value)%"
    }

    private func applyRadius(_ value: Int) {
        if radiusSlider.integerValue != value { radiusSlider.integerValue = value }
        radiusValueLabel.stringValue = value == 0 ? String(localized: "Auto") : "\(value) pt"
    }

    /// Repaints the custom accent menu item's swatch from the stored hex.
    private func refreshCustomSwatch() {
        guard let i = accents.firstIndex(of: .custom) else { return }
        accentPopup.item(at: i)?.image = Self.swatch(for: .custom)
    }

    // MARK: - Custom accent color

    /// Tracks whether we currently own the shared color panel's target/action,
    /// so `viewWillDisappear` can detach before this controller is released.
    private var ownsColorPanel = false

    private func presentColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        if let hex = Preferences.shared.customAccentHex, let color = NSColor(hexString: hex) {
            panel.color = color
        }
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        ownsColorPanel = true
        panel.orderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        Preferences.shared.customAccentHex = sender.color.hexString
        refreshCustomSwatch()
    }
}
