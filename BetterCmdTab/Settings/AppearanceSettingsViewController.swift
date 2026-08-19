import AppKit
import BetterSettings
import Combine

/// Appearance pane — where the panel opens and how it looks: layout, label
/// text, and the panel chrome. What it *lists* lives under Switcher.
@MainActor
final class AppearanceSettingsViewController: SettingsTabViewController {

    private let displayMonitorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayModes: [SwitcherDisplayMode] = SwitcherDisplayMode.allCases
    private let selectionColors: [SwitcherSelectionColor] = SwitcherSelectionColor.allCases
    private var layoutRadio: SettingsRadioGroupView!
    private var appearanceRadio: SettingsRadioGroupView!
    private var titleAlignmentRadio: SettingsRadioGroupView!
    private var truncationRadio: SettingsRadioGroupView!
    private let gridPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let selectionColorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let listWidthSlider = NSSlider()
    private let listWidthValueField = NSTextField()
    private let scaleSlider = NSSlider()
    private let scaleValueField = NSTextField()
    private let fontSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontFacePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gridSingleRowSwitch = PreferenceSwitch(bind: \.gridSingleRow)
    private let livePreviewSwitch = PreferenceSwitch(bind: \.livePreviews)
    private let windowTitleSwitch = PreferenceSwitch(bind: \.showWindowTitleLabel)
    private let appNamesSwitch = PreferenceSwitch(bind: \.showApplicationNames)
    private let statusIconsSwitch = PreferenceSwitch(bind: \.showWindowStatusIcons)
    private let boldSelectedSwitch = PreferenceSwitch(bind: \.boldSelectedLabel)
    private let opacitySlider = NSSlider()
    private let opacityValueField = NSTextField()
    private let radiusSlider = NSSlider()
    private let radiusValueLabel = NSTextField(labelWithString: "")
    private let animationsSwitch = PreferenceSwitch(bind: \.animationsEnabled)
    private let previewButton = NSButton()

    private var cancellables = Set<AnyCancellable>()
    private var previewRefreshScheduled = false
    private var previewPanel: SwitcherPanel?
    private var previewView: SwitcherView?
    private var previewRows: [SwitcherRow] = []

    // Ordered option models backing the popups (index ↔ value).
    private let layoutModes: [SwitcherLayoutMode] = [.gridView, .list, .windowPreview]
    private let titleAlignments: [PreviewTitleAlignment] = [.leading, .center, .trailing]
    private let truncationModes: [TitleTruncationMode] = [.head, .middle, .tail]
    private let fontScales: [SwitcherFontScale] = SwitcherFontScale.allCases
    private let fontFaces: [SwitcherFontFace] = SwitcherFontFace.allCases
    private let panelAppearances: [PanelAppearance] = PanelAppearance.allCases
    private let gridValues: [Int] = [0, 2, 3, 4, 5, 6] // 0 = automatic

    override func setupContent() {
        // Most of this pane has a matching `ShortcutOverride` field, so it needs
        // the global-defaults note more than Switcher or Controls do.
        addGlobalDefaultNote()

        // Layout section — the panel's shape: which layout, how big, how many
        // grid columns.
        let layout = addSection(title: String(localized: "Layout"), anchor: SettingsAnchor.appearanceLayout)

        configurePopup(displayMonitorPopup, titles: displayModes.map(\.displayName), action: #selector(displayModeChanged))
        addRow(to: layout, title: String(localized: "Show switcher on"),
               subtitle: String(localized: "Choose which monitor the switcher opens on when you have more than one display."),
               accessory: displayMonitorPopup, searchItemID: SearchID.displayMonitor)

        layoutRadio = makeLayoutRadio()
        addRow(to: layout, title: String(localized: "Layout"), accessory: layoutRadio, searchItemID: SearchID.layout)

        let sizeTitle = String(localized: "Size")
        scaleSlider.minValue = Double(Preferences.panelScalePercentRange.lowerBound)
        scaleSlider.maxValue = Double(Preferences.panelScalePercentRange.upperBound)
        scaleSlider.isContinuous = true
        scaleSlider.controlSize = .small
        scaleSlider.target = self
        scaleSlider.action = #selector(scaleChanged(_:))
        scaleSlider.translatesAutoresizingMaskIntoConstraints = false
        scaleSlider.setAccessibilityLabel(sizeTitle)
        configureIntegerField(scaleValueField,
                              action: #selector(scaleValueCommitted(_:)),
                              accessibilityLabel: sizeTitle)
        let scaleStack = NSStackView(views: [scaleSlider, unitInput(for: scaleValueField, unit: "%")])
        scaleStack.orientation = .horizontal
        scaleStack.spacing = 8
        scaleStack.alignment = .centerY
        NSLayoutConstraint.activate([
            scaleSlider.widthAnchor.constraint(equalToConstant: 140),
        ])
        addRow(to: layout, title: sizeTitle,
               subtitle: String(localized: "100% matches the size of the macOS switcher, on every display."),
               accessory: scaleStack, searchItemID: SearchID.size)

        let listWidthTitle = String(localized: "Maximum list width")
        listWidthSlider.minValue = Double(Preferences.listWidthPercentRange.lowerBound)
        listWidthSlider.maxValue = Double(Preferences.listWidthPercentRange.upperBound)
        listWidthSlider.isContinuous = true
        listWidthSlider.controlSize = .small
        listWidthSlider.target = self
        listWidthSlider.action = #selector(listWidthChanged(_:))
        listWidthSlider.translatesAutoresizingMaskIntoConstraints = false
        listWidthSlider.setAccessibilityLabel(listWidthTitle)
        configureIntegerField(listWidthValueField,
                              action: #selector(listWidthValueCommitted(_:)),
                              accessibilityLabel: listWidthTitle)
        let listWidthStack = NSStackView(views: [listWidthSlider, unitInput(for: listWidthValueField, unit: "%")])
        listWidthStack.orientation = .horizontal
        listWidthStack.spacing = 8
        listWidthStack.alignment = .centerY
        NSLayoutConstraint.activate([
            listWidthSlider.widthAnchor.constraint(equalToConstant: 140),
        ])
        addRow(to: layout, title: listWidthTitle,
               subtitle: String(localized: "Width of the List layout relative to automatic — lower it to narrow the panel on large displays."),
               accessory: listWidthStack, searchItemID: SearchID.listMaxWidth)

        configurePopup(gridPopup, titles: gridValues.map { $0 == 0 ? String(localized: "Automatic") : "\($0)" }, action: #selector(gridChanged))
        addRow(to: layout, title: String(localized: "Grid columns"),
               subtitle: String(localized: "Applies to the Grid and Previews layouts."),
               accessory: gridPopup, searchItemID: SearchID.gridColumns)

        addRow(to: layout, title: String(localized: "Single row"),
               subtitle: String(localized: "Shrink the icons to keep every window on one line instead of starting a second row."),
               accessory: gridSingleRowSwitch, searchItemID: SearchID.gridSingleRow)

        // Labels section — the text on each row/tile.
        let labels = addSection(title: String(localized: "Labels"), anchor: SettingsAnchor.appearanceLabels)

        configurePopup(fontSizePopup, titles: fontScales.map(\.displayName), action: #selector(fontScaleChanged))
        addRow(to: labels, title: String(localized: "Text size"),
               subtitle: String(localized: "Size of names and titles, independent of the panel size."),
               accessory: fontSizePopup, searchItemID: SearchID.textSize)

        configurePopup(fontFacePopup, titles: fontFaces.map(\.displayName), action: #selector(fontFaceChanged))
        addRow(to: labels, title: String(localized: "Font"),
               subtitle: String(localized: "Typeface for names and titles."),
               accessory: fontFacePopup, searchItemID: SearchID.fontFace)

        addRow(to: labels, title: String(localized: "Show window title"),
               subtitle: String(localized: "Show each window's title under the icon in the Grid and Previews layouts."),
               accessory: windowTitleSwitch, searchItemID: SearchID.windowTitle)

        titleAlignmentRadio = makeTitleAlignmentRadio()
        addRow(to: labels, title: String(localized: "Title alignment"),
               subtitle: String(localized: "Position of the title under each Previews tile."),
               accessory: titleAlignmentRadio, searchItemID: SearchID.titleAlignment)

        truncationRadio = makeTruncationRadio()
        addRow(to: labels, title: String(localized: "Ellipsis position"),
               subtitle: String(localized: "Which part of a long title is shortened with an ellipsis."),
               accessory: truncationRadio, searchItemID: SearchID.titleTruncation)

        addRow(to: labels, title: String(localized: "Bold selected title"),
               subtitle: String(localized: "Make the highlighted item's title bold in the Grid and Previews layouts. Off only brightens it."),
               accessory: boldSelectedSwitch, searchItemID: SearchID.boldSelected)

        addRow(to: labels, title: String(localized: "Show application names"),
               subtitle: String(localized: "Hide the app name in every layout; identify apps by their icon."),
               accessory: appNamesSwitch, searchItemID: SearchID.applicationNames)

        addRow(to: labels, title: String(localized: "Show status icons"),
               subtitle: String(localized: "Mark hidden, minimized, full-screen and windowless entries with a small glyph. The audio, Launch and Reopen cues always show."),
               accessory: statusIconsSwitch, searchItemID: SearchID.windowStatusIcons)

        // Panel section — the chrome: selection color, translucency, rounding.
        let panel = addSection(title: String(localized: "Panel"), anchor: SettingsAnchor.appearancePanel)

        appearanceRadio = makeAppearanceRadio()
        addRow(to: panel, title: String(localized: "Appearance"),
               accessory: appearanceRadio, searchItemID: SearchID.theme)

        configurePopup(selectionColorPopup, titles: selectionColors.map(\.displayName),
                       action: #selector(selectionColorChanged))
        for (i, color) in selectionColors.enumerated() {
            selectionColorPopup.item(at: i)?.image = Self.swatch(for: color)
        }
        addRow(to: panel, title: String(localized: "Selection color"),
               subtitle: String(localized: "Color of the highlight around the selected window and of the quick-jump letters. Follows your macOS accent by default."),
               accessory: selectionColorPopup, searchItemID: SearchID.selectionColor)

        let opacityTitle = String(localized: "Panel opacity")
        opacitySlider.minValue = Double(Preferences.panelOpacityRange.lowerBound)
        opacitySlider.maxValue = Double(Preferences.panelOpacityRange.upperBound)
        opacitySlider.isContinuous = true
        opacitySlider.controlSize = .small
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.setAccessibilityLabel(opacityTitle)
        configureIntegerField(opacityValueField,
                              action: #selector(opacityValueCommitted(_:)),
                              accessibilityLabel: opacityTitle)
        let opacityStack = NSStackView(views: [opacitySlider, unitInput(for: opacityValueField, unit: "%")])
        opacityStack.orientation = .horizontal
        opacityStack.spacing = 8
        opacityStack.alignment = .centerY
        NSLayoutConstraint.activate([
            opacitySlider.widthAnchor.constraint(equalToConstant: 140),
        ])
        addRow(to: panel, title: opacityTitle,
               subtitle: String(localized: "Translucency of the switcher panel."),
               accessory: opacityStack, searchItemID: SearchID.opacity)

        let radiusStack = makeSliderControl(
            radiusSlider, valueLabel: radiusValueLabel,
            range: Preferences.panelCornerRadiusRange, action: #selector(radiusChanged(_:))
        )
        addRow(to: panel, title: String(localized: "Corner radius"),
               subtitle: String(localized: "Rounding of the panel's corners. Automatic follows the panel size; Square turns rounding off."),
               accessory: radiusStack, searchItemID: SearchID.cornerRadius)

        addRow(to: panel, title: String(localized: "Animations"),
               subtitle: String(localized: "Panel, tiles and tab strip glide between states. Off, or macOS Reduce Motion, switches instantly."),
               accessory: animationsSwitch, searchItemID: SearchID.animations)

        // Live refresh rides on the macOS 14 ScreenCaptureKit still-image API;
        // on macOS 13 the toggle would be inert, so say why it is unavailable.
        let liveAvailable = if #available(macOS 14.0, *) { true } else { false }
        addRow(to: panel, title: String(localized: "Live window previews"),
               subtitle: liveAvailable
                   ? String(localized: "In the Previews layout, thumbnails keep refreshing while the switcher is open, so they show what is happening in each window right now. Uses extra CPU and GPU while the panel is up.")
                   : String(localized: "Requires macOS 14 or later. Thumbnails are captured once each time the switcher opens."),
               accessory: livePreviewSwitch, searchItemID: SearchID.livePreviews)
        livePreviewSwitch.isEnabled = liveAvailable

        previewButton.title = String(localized: "Show Preview")
        previewButton.bezelStyle = .rounded
        previewButton.controlSize = .small
        previewButton.target = self
        previewButton.action = #selector(togglePreview)
        addRow(to: panel, title: String(localized: "Preview"),
               accessory: previewButton, searchItemID: SearchID.preview)

        // What the switcher lists and when it appears lives under the Switcher
        // tab; browser tab previews sit with the other browser-tab rows under
        // Tabs.
    }

    /// Builds a horizontal slider + right-aligned monospaced value label. The
    /// caller wires `viewWillAppear` sync.
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

    private func makeAppearanceRadio() -> SettingsRadioGroupView {
        let options = panelAppearances.map { appearance in
            SettingsRadioGroupView.Option(identifier: appearance.rawValue, title: appearance.displayName)
        }
        let group = SettingsRadioGroupView(options: options, orientation: .horizontal)
        group.onSelectionChange = { id in
            guard let appearance = PanelAppearance(rawValue: id) else { return }
            Preferences.shared.panelAppearance = appearance
        }
        return group
    }

    private func makeTitleAlignmentRadio() -> SettingsRadioGroupView {
        let options = titleAlignments.map { alignment in
            SettingsRadioGroupView.Option(identifier: alignment.rawValue, title: alignment.displayName)
        }
        let group = SettingsRadioGroupView(options: options, orientation: .horizontal)
        group.onSelectionChange = { id in
            guard let alignment = PreviewTitleAlignment(rawValue: id) else { return }
            Preferences.shared.previewTitleAlignment = alignment
        }
        return group
    }

    private func makeTruncationRadio() -> SettingsRadioGroupView {
        let options = truncationModes.map { mode in
            SettingsRadioGroupView.Option(identifier: mode.rawValue, title: mode.displayName)
        }
        let group = SettingsRadioGroupView(options: options, orientation: .horizontal)
        group.onSelectionChange = { id in
            guard let mode = TitleTruncationMode(rawValue: id) else { return }
            Preferences.shared.titleTruncationMode = mode
        }
        return group
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        syncFromPreferences()

        let prefs = Preferences.shared
        prefs.$switcherLayoutMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectLayout($0) }
            .store(in: &cancellables)
        prefs.$panelScalePercent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyScale($0) }
            .store(in: &cancellables)
        prefs.$panelAppearance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectAppearance($0) }
            .store(in: &cancellables)
        prefs.$gridMaxColumns
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectGrid($0) }
            .store(in: &cancellables)
        prefs.$listWidthPercent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyListWidth($0) }
            .store(in: &cancellables)
        prefs.$gridSingleRow
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.gridSingleRowSwitch.sync() }
            .store(in: &cancellables)
        prefs.$livePreviews
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.livePreviewSwitch.sync() }
            .store(in: &cancellables)
        prefs.$showWindowTitleLabel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.windowTitleSwitch.sync() }
            .store(in: &cancellables)
        prefs.$previewTitleAlignment
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectTitleAlignment($0) }
            .store(in: &cancellables)
        prefs.$titleTruncationMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectTruncationMode($0) }
            .store(in: &cancellables)
        prefs.$fontScale
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectFontScale($0) }
            .store(in: &cancellables)
        prefs.$fontFace
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectFontFace($0) }
            .store(in: &cancellables)
        prefs.$boldSelectedLabel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.boldSelectedSwitch.sync() }
            .store(in: &cancellables)
        prefs.$showApplicationNames
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.appNamesSwitch.sync() }
            .store(in: &cancellables)
        prefs.$showWindowStatusIcons
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.statusIconsSwitch.sync() }
            .store(in: &cancellables)
        prefs.$panelOpacity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyOpacity($0) }
            .store(in: &cancellables)
        prefs.$panelCornerRadius
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyRadius($0) }
            .store(in: &cancellables)
        prefs.$animationsEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.animationsSwitch.sync() }
            .store(in: &cancellables)
        prefs.$selectionColor
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectSelectionColor($0) }
            .store(in: &cancellables)
        prefs.$selectionColorHex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshCustomSwatch() }
            .store(in: &cancellables)
        prefs.objectWillChange
            .sink { [weak self] in self?.schedulePreviewRefresh() }
            .store(in: &cancellables)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        hidePreview()
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
        if let index = displayModes.firstIndex(of: prefs.switcherDisplayMode) {
            displayMonitorPopup.selectItem(at: index)
        }
        selectLayout(prefs.switcherLayoutMode)
        applyScale(prefs.panelScalePercent)
        selectAppearance(prefs.panelAppearance)
        selectGrid(prefs.gridMaxColumns)
        gridSingleRowSwitch.sync()
        livePreviewSwitch.sync()
        applyListWidth(prefs.listWidthPercent)
        windowTitleSwitch.sync()
        selectTitleAlignment(prefs.previewTitleAlignment)
        selectTruncationMode(prefs.titleTruncationMode)
        selectFontScale(prefs.fontScale)
        selectFontFace(prefs.fontFace)
        boldSelectedSwitch.sync()
        appNamesSwitch.sync()
        statusIconsSwitch.sync()
        animationsSwitch.sync()
        applyOpacity(prefs.panelOpacity)
        applyRadius(prefs.panelCornerRadius)
        selectSelectionColor(prefs.selectionColor)
        refreshCustomSwatch()
    }

    private func selectSelectionColor(_ color: SwitcherSelectionColor) {
        if let i = selectionColors.firstIndex(of: color) { selectionColorPopup.selectItem(at: i) }
    }

    @objc private func selectionColorChanged() {
        let i = selectionColorPopup.indexOfSelectedItem
        guard selectionColors.indices.contains(i) else { return }
        let choice = selectionColors[i]
        Preferences.shared.selectionColor = choice
        if choice == .custom { presentColorPanel() }
    }

    /// Small filled-circle swatch shown beside each selection-color menu item.
    /// `.system` is drawn with the live accent color so it always previews the
    /// user's macOS setting, and `.custom` with the stored hex so it tracks
    /// their pick rather than the accent fallback in `resolved`.
    private static func swatch(for color: SwitcherSelectionColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.isTemplate = false
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: rect)
        let fill: NSColor
        if color == .custom {
            fill = Preferences.shared.selectionColorHex.flatMap(NSColor.init(hexString:)) ?? .controlAccentColor
        } else {
            fill = color.resolved
        }
        fill.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        path.lineWidth = 1
        path.stroke()
        image.unlockFocus()
        return image
    }

    /// Repaints the custom menu item's swatch from the stored hex.
    private func refreshCustomSwatch() {
        guard let i = selectionColors.firstIndex(of: .custom) else { return }
        selectionColorPopup.item(at: i)?.image = Self.swatch(for: .custom)
    }

    // MARK: - Custom selection color

    /// Tracks whether we currently own the shared color panel's target/action,
    /// so `viewWillDisappear` can detach before this controller is released.
    private var ownsColorPanel = false

    private func presentColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        if let hex = Preferences.shared.selectionColorHex, let color = NSColor(hexString: hex) {
            panel.color = color
        }
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        ownsColorPanel = true
        panel.orderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        Preferences.shared.selectionColorHex = sender.color.hexString
        refreshCustomSwatch()
    }

    private func selectLayout(_ mode: SwitcherLayoutMode) {
        layoutRadio.select(identifier: mode.rawValue)
    }

    private func selectAppearance(_ appearance: PanelAppearance) {
        appearanceRadio.select(identifier: appearance.rawValue)
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
        // A column cap wraps the grid whatever the toggle says, so the toggle
        // only applies while the count is automatic.
        gridSingleRowSwitch.isEnabled = (value == 0)
    }

    @objc private func gridChanged() {
        let i = gridPopup.indexOfSelectedItem
        guard gridValues.indices.contains(i) else { return }
        Preferences.shared.gridMaxColumns = gridValues[i]
        gridSingleRowSwitch.isEnabled = (gridValues[i] == 0)
    }

    @objc private func listWidthChanged(_ sender: NSSlider) {
        Preferences.shared.listWidthPercent = sender.integerValue
        applyListWidth(sender.integerValue)
    }

    @objc private func listWidthValueCommitted(_ sender: NSTextField) {
        guard let value = committedInteger(from: sender) else {
            applyListWidth(Preferences.shared.listWidthPercent)
            return
        }
        let clamped = Preferences.clampListWidthPercent(value)
        Preferences.shared.listWidthPercent = clamped
        applyListWidth(clamped)
    }

    private func applyListWidth(_ value: Int) {
        if listWidthSlider.integerValue != value { listWidthSlider.integerValue = value }
        let text = String(value)
        if listWidthValueField.stringValue != text { listWidthValueField.stringValue = text }
    }

    @objc private func scaleChanged(_ sender: NSSlider) {
        Preferences.shared.panelScalePercent = sender.integerValue
        applyScale(sender.integerValue)
    }

    @objc private func scaleValueCommitted(_ sender: NSTextField) {
        guard let value = committedInteger(from: sender) else {
            applyScale(Preferences.shared.panelScalePercent)
            return
        }
        let clamped = Preferences.clampPanelScalePercent(value)
        Preferences.shared.panelScalePercent = clamped
        applyScale(clamped)
    }

    @objc private func displayModeChanged() {
        let idx = displayMonitorPopup.indexOfSelectedItem
        guard displayModes.indices.contains(idx) else { return }
        Preferences.shared.switcherDisplayMode = displayModes[idx]
    }

    private func selectTitleAlignment(_ alignment: PreviewTitleAlignment) {
        titleAlignmentRadio.select(identifier: alignment.rawValue)
    }

    private func selectTruncationMode(_ mode: TitleTruncationMode) {
        truncationRadio.select(identifier: mode.rawValue)
    }

    private func selectFontScale(_ scale: SwitcherFontScale) {
        if let i = fontScales.firstIndex(of: scale) { fontSizePopup.selectItem(at: i) }
    }

    private func selectFontFace(_ face: SwitcherFontFace) {
        if let i = fontFaces.firstIndex(of: face) { fontFacePopup.selectItem(at: i) }
    }

    @objc private func fontScaleChanged() {
        let i = fontSizePopup.indexOfSelectedItem
        guard fontScales.indices.contains(i) else { return }
        Preferences.shared.fontScale = fontScales[i]
    }

    @objc private func fontFaceChanged() {
        let i = fontFacePopup.indexOfSelectedItem
        guard fontFaces.indices.contains(i) else { return }
        Preferences.shared.fontFace = fontFaces[i]
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        Preferences.shared.panelOpacity = sender.integerValue
        applyOpacity(sender.integerValue)
    }

    @objc private func opacityValueCommitted(_ sender: NSTextField) {
        guard let value = committedInteger(from: sender) else {
            applyOpacity(Preferences.shared.panelOpacity)
            return
        }
        let clamped = Preferences.clampOpacity(value)
        Preferences.shared.panelOpacity = clamped
        applyOpacity(clamped)
    }

    @objc private func radiusChanged(_ sender: NSSlider) {
        Preferences.shared.panelCornerRadius = sender.integerValue
        radiusValueLabel.stringValue = Self.radiusDisplay(sender.integerValue)
    }

    private static func radiusDisplay(_ value: Int) -> String {
        if value < 0 { return String(localized: "Square") }
        return value == 0 ? String(localized: "Auto") : "\(value) pt"
    }

    private func applyOpacity(_ value: Int) {
        if opacitySlider.integerValue != value { opacitySlider.integerValue = value }
        let text = String(value)
        if opacityValueField.stringValue != text { opacityValueField.stringValue = text }
    }

    private func applyScale(_ value: Int) {
        if scaleSlider.integerValue != value { scaleSlider.integerValue = value }
        let text = String(value)
        if scaleValueField.stringValue != text { scaleValueField.stringValue = text }
    }

    private func applyRadius(_ value: Int) {
        if radiusSlider.integerValue != value { radiusSlider.integerValue = value }
        radiusValueLabel.stringValue = Self.radiusDisplay(value)
    }

    @objc private func togglePreview() {
        if previewPanel?.isVisible == true {
            hidePreview()
            return
        }
        if previewPanel == nil {
            let previewView = SwitcherView(frame: .zero, allowsWindowCapture: false)
            let panel = SwitcherPanel()
            panel.contentView = previewView
            panel.ignoresMouseEvents = true
            previewPanel = panel
            self.previewView = previewView
            previewRows = makePreviewRows()
        }
        renderPreview()
        previewPanel?.orderFrontRegardless()
        previewButton.title = String(localized: "Hide Preview")
    }

    private func hidePreview() {
        previewPanel?.orderOut(nil)
        previewPanel?.targetScreen = nil
        previewView?.releaseIdleResources()
        previewPanel = nil
        previewView = nil
        previewRows.removeAll(keepingCapacity: false)
        previewButton.title = String(localized: "Show Preview")
    }

    private func schedulePreviewRefresh() {
        guard previewPanel?.isVisible == true, !previewRefreshScheduled else { return }
        previewRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.previewRefreshScheduled = false
            guard self.previewPanel?.isVisible == true else { return }
            self.renderPreview()
        }
    }

    private func makePreviewRows() -> [SwitcherRow] {
        var seen = Set<String>()
        var apps: [NSRunningApplication] = []
        for app in NSWorkspace.shared.runningApplications
        where !app.isTerminated && app.activationPolicy == .regular {
            let identity = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
            guard seen.insert(identity).inserted, app.localizedName?.isEmpty == false else { continue }
            apps.append(app)
            if apps.count == 3 { break }
        }
        if apps.isEmpty { apps = [.current] }
        return apps.map {
            SwitcherRow(app: $0, window: nil, windowTitle: "", isMinimized: false, isPlaceholder: true)
        }
    }

    private func renderPreview() {
        guard let panel = previewPanel, let previewView else { return }
        let prefs = Preferences.shared
        let effective = prefs.effectiveSettings(for: ShortcutOverride())
        let screen = view.window?.screen ?? SwitcherPanel.preferredScreen()
        panel.targetScreen = screen
        let metrics = SwitcherMetrics.forScale(
            SwitcherMetrics.scale(forPercent: effective.panelScalePercent),
            layoutMode: effective.layoutMode,
            fontScale: effective.fontScale.multiplier,
            letterHints: effective.letterHintsEnabled,
            showAppNames: effective.showApplicationNames,
            showWindowTitles: effective.showWindowTitleLabel,
            hoverActionCount: prefs.enabledHoverActionCount
        )
        previewView.configure(
            rows: previewRows,
            labels: RowLabels.labels(for: previewRows),
            selectedIndex: 0,
            metrics: metrics,
            effective: effective
        )
        previewView.layoutSubtreeIfNeeded()

        let visible = screen.visibleFrame
        let fitting = previewView.fittingSize
        let size = NSSize(width: min(fitting.width, visible.width),
                          height: min(fitting.height, visible.height))
        let origin: NSPoint
        if let settings = view.window?.frame {
            let x = min(max(visible.minX, settings.midX - size.width / 2), visible.maxX - size.width)
            let below = settings.minY - 14 - size.height
            let above = settings.maxY + 14
            let y = below >= visible.minY
                ? below
                : (above + size.height <= visible.maxY ? above : visible.midY - size.height / 2)
            origin = NSPoint(x: x, y: y)
        } else {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = CGFloat(effective.panelOpacity) / 100
    }

}
