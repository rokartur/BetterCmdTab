import AppKit

/// Sheet that lets the user pick one or more apps (by bundle identifier). Used
/// to add an app to the rules list (single selection) and to choose pinned apps
/// (multiple). Styled to match the rest of the app: a rounded card list with
/// accent checkmarks and hover highlighting, rather than a bezeled table of
/// switches. The app list combines a scan of the Applications folders with the
/// currently-running apps.
@MainActor
final class AppsPickerSheetWindowController: NSWindowController {
    private let content: AppsPickerSheetViewController
    private var hasDismissed = false

    /// Called once after the sheet is dismissed (confirm or cancel) so the owner
    /// can drop its reference.
    var onDidDismiss: (() -> Void)?

    init(
        title: String,
        prompt: String,
        selectedBundleIDs: Set<String>,
        singleSelection: Bool = false,
        confirmTitle: String = "Done",
        onDone: @escaping (Set<String>) -> Void
    ) {
        content = AppsPickerSheetViewController(
            prompt: prompt,
            selectedBundleIDs: selectedBundleIDs,
            singleSelection: singleSelection,
            confirmTitle: confirmTitle,
            onDone: onDone
        )
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 560))
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

@MainActor
final class AppsPickerSheetViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    struct InstalledApp: Sendable {
        let bundleID: String
        let name: String
        let url: URL?
    }

    private var selected: Set<String>
    private let prompt: String
    /// When true, only one app can be chosen (radio behavior) and the
    /// All/Checked/Unchecked filter is hidden.
    private let singleSelection: Bool
    private let confirmTitle: String
    private let onDone: (Set<String>) -> Void
    var onClose: (() -> Void)?

    private enum SelectionFilter: Int { case all = 0, checked = 1, unchecked = 2 }
    private var selectionFilter: SelectionFilter = .all
    private var pendingFilterTask: Task<Void, Never>?

    private var allApps: [InstalledApp] = []
    private var filtered: [InstalledApp] = []

    private let promptLabel = NSTextField(wrappingLabelWithString: "")
    private let searchField = NSSearchField()
    private let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let listContainer = PickerCardView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let cancelButton = NSButton()
    private let confirmButton = NSButton()
    private let clearButton = NSButton()
    private let spinner = NSProgressIndicator()

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("AppsPickerCell")

    init(prompt: String, selectedBundleIDs: Set<String>, singleSelection: Bool = false, confirmTitle: String = "Done", onDone: @escaping (Set<String>) -> Void) {
        self.prompt = prompt
        self.selected = selectedBundleIDs
        self.singleSelection = singleSelection
        self.confirmTitle = confirmTitle
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        pendingFilterTask?.cancel()
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 560))

        promptLabel.stringValue = prompt
        promptLabel.font = .systemFont(ofSize: 12)
        promptLabel.textColor = .secondaryLabelColor
        promptLabel.maximumNumberOfLines = 0
        promptLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = String(localized: "Search apps…")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        filterPopup.controlSize = .small
        filterPopup.translatesAutoresizingMaskIntoConstraints = false
        filterPopup.setContentHuggingPriority(.required, for: .horizontal)
        filterPopup.removeAllItems()
        filterPopup.addItems(withTitles: [String(localized: "All"), String(localized: "Checked"), String(localized: "Unchecked")])
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)

        // Single-selection mode keeps the search field but drops the
        // All/Checked/Unchecked filter (there's only ever one checked app).
        let topRowViews: [NSView] = singleSelection ? [searchField] : [searchField, filterPopup]
        let topRow = NSStackView(views: topRowViews)
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.alignment = .centerY
        topRow.translatesAutoresizingMaskIntoConstraints = false

        // Rounded card holding the list, matching the settings section chrome.
        listContainer.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 36
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.style = .inset
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
        ])

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.title = String(localized: "Cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Esc
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        confirmButton.title = confirmTitle
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"
        confirmButton.target = self
        confirmButton.action = #selector(handleConfirm)
        confirmButton.translatesAutoresizingMaskIntoConstraints = false

        clearButton.title = String(localized: "Clear")
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(handleClear)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        // Single selection commits on click, so there's no separate confirm
        // button; offer Clear only when editing an existing choice (e.g. a
        // Direct-activation slot that already has an app).
        confirmButton.isHidden = singleSelection
        clearButton.isHidden = !(singleSelection && !selected.isEmpty)

        let buttonRow = NSStackView(views: [spinner, clearButton, NSView(), cancelButton, confirmButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(promptLabel)
        root.addSubview(topRow)
        root.addSubview(listContainer)
        root.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            promptLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            promptLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            promptLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            topRow.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 12),
            topRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            topRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            listContainer.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 10),
            listContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            listContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadApps()
    }

    // MARK: - App discovery

    private func loadApps() {
        spinner.startAnimation(nil)
        // Capture main-actor state (running apps + current selection) up front,
        // then do the blocking filesystem scan off-main. Only regular apps are
        // added as a fallback — `runningApplications` also lists background
        // agents / XPC services / Finder extensions (.accessory/.prohibited)
        // that aren't in the Applications folders and shouldn't appear here.
        var extra = selected
        extra.formUnion(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleIdentifier }
        )
        let snapshot = extra
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = Self.discover(extra: snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.allApps = self.resolvingDisplay(apps)
                self.spinner.stopAnimation(nil)
                self.applyFilter()
            }
        }
    }

    /// Filesystem-only discovery (safe off the main actor). Scans the standard
    /// Applications folders, deduplicates by lowercased bundle ID, and ensures
    /// every `extra` bundle ID (selected + running) is represented even if not
    /// found on disk.
    nonisolated private static func discover(extra: Set<String>) -> [InstalledApp] {
        let fm = FileManager.default
        let selfBundle = Bundle.main.bundleIdentifier
        var byKey: [String: InstalledApp] = [:]

        let dirs = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true),
        ]
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else { continue }
                if bid == selfBundle { continue }
                let key = bid.lowercased()
                if byKey[key] != nil { continue }
                let name = url.deletingPathExtension().lastPathComponent
                byKey[key] = InstalledApp(bundleID: bid, name: name, url: url)
            }
        }

        for bid in extra where bid != selfBundle {
            let key = bid.lowercased()
            if byKey[key] != nil { continue }
            byKey[key] = InstalledApp(bundleID: bid, name: bid, url: nil)
        }

        return byKey.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Fill in name + icon for apps `discover` couldn't find in the scanned
    /// Applications folders (e.g. Finder, which lives in CoreServices) by asking
    /// LaunchServices on the main actor, then re-sort by the resolved names.
    private func resolvingDisplay(_ apps: [InstalledApp]) -> [InstalledApp] {
        let resolved = apps.map { app -> InstalledApp in
            guard app.url == nil,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
            else { return app }
            return InstalledApp(bundleID: app.bundleID, name: url.deletingPathExtension().lastPathComponent, url: url)
        }
        return resolved.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = allApps.filter { app in
            let passesSearch = query.isEmpty
                || app.name.localizedCaseInsensitiveContains(query)
                || app.bundleID.localizedCaseInsensitiveContains(query)
            let isChecked = selected.contains(app.bundleID)
            let passesSelection: Bool
            switch selectionFilter {
            case .all: passesSelection = true
            case .checked: passesSelection = isChecked
            case .unchecked: passesSelection = !isChecked
            }
            return passesSearch && passesSelection
        }
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func handleCancel() {
        onClose?()
    }

    @objc private func handleConfirm() {
        onDone(selected)
        onClose?()
    }

    @objc private func handleClear() {
        selected = []
        handleConfirm()
    }

    @objc private func filterChanged() {
        selectionFilter = SelectionFilter(rawValue: filterPopup.indexOfSelectedItem) ?? .all
        applyFilter()
    }

    /// Single click: in single-selection, choose the app and close immediately
    /// (like picking from a menu); in multi-selection, toggle membership.
    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard filtered.indices.contains(row) else { return }
        let app = filtered[row]
        if singleSelection {
            selected = [app.bundleID]
            handleConfirm()
            return
        }
        toggle(bundleID: app.bundleID, on: !selected.contains(app.bundleID))
    }

    /// Double click confirms in multi-selection (a quick way to pick one and
    /// close); single-selection already commits on the first click.
    @objc private func rowDoubleClicked() {
        guard !singleSelection else { return }
        let row = tableView.clickedRow
        guard filtered.indices.contains(row) else { return }
        if !selected.contains(filtered[row].bundleID) {
            selected.insert(filtered[row].bundleID)
        }
        handleConfirm()
    }

    private func toggle(bundleID: String, on: Bool) {
        if singleSelection {
            // Radio: enabling one clears the others; clicking the chosen one again clears it.
            selected = on ? [bundleID] : []
            tableView.reloadData()
            return
        }
        if on { selected.insert(bundleID) } else { selected.remove(bundleID) }
        // In a filtered view, re-apply after a short delay so a just-toggled row
        // slides out of "Checked"/"Unchecked" instead of vanishing under the
        // user's cursor mid-tap.
        if selectionFilter == .all {
            tableView.reloadData(forRowIndexes: rowIndexes(for: bundleID), columnIndexes: IndexSet(integer: 0))
            return
        }
        tableView.reloadData(forRowIndexes: rowIndexes(for: bundleID), columnIndexes: IndexSet(integer: 0))
        pendingFilterTask?.cancel()
        pendingFilterTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.applyFilter()
        }
    }

    private func rowIndexes(for bundleID: String) -> IndexSet {
        guard let row = filtered.firstIndex(where: { $0.bundleID == bundleID }) else { return IndexSet() }
        return IndexSet(integer: row)
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let app = filtered[row]
        let cell: AppsPickerCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? AppsPickerCellView {
            cell = reused
        } else {
            cell = AppsPickerCellView(frame: .zero)
            cell.identifier = Self.cellIdentifier
        }
        let icon: NSImage
        if let url = app.url {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cell.configure(
            icon: icon,
            name: app.name,
            isChecked: selected.contains(app.bundleID)
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// Rounded, hairline-bordered container for the app list — the same chrome as a
/// settings section card, restyled live on light/dark changes.
@MainActor
final class PickerCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = AppKitSectionChrome.cornerRadius
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        guard let layer else { return }
        layer.backgroundColor = AppKitSectionChrome.fillColor(for: effectiveAppearance).cgColor
        layer.borderWidth = AppKitSectionChrome.borderWidth
        layer.borderColor = AppKitSectionChrome.borderColor(for: effectiveAppearance).cgColor
    }
}

/// One app row in the picker: icon, name, and a trailing accent checkmark when
/// chosen. The whole row highlights on hover and clicks toggle membership
/// (handled by the table's action). No switches — selection is by clicking the
/// app, matching the rest of the app's list styling.
@MainActor
final class AppsPickerCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private var isChecked = false
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Membership shown by a trailing accent checkmark only (like macOS
        // "choose apps" lists) — no full-row tint.
        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: String(localized: "Selected"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        checkmark.contentTintColor = .controlAccentColor
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.setContentHuggingPriority(.required, for: .horizontal)
        checkmark.alphaValue = 0

        let stack = NSStackView(views: [iconView, nameLabel, NSView(), checkmark])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            checkmark.widthAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(icon: NSImage, name: String, isChecked: Bool) {
        iconView.image = icon
        nameLabel.stringValue = name
        self.isChecked = isChecked
        checkmark.alphaValue = isChecked ? 1 : 0
        // Reused cells inherit stale hover state — recompute from the actual
        // pointer position so a row scrolled under the cursor highlights and the
        // old occupant doesn't stay lit.
        recomputeHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        // Scrolling moves rows under a stationary pointer; AppKit re-runs this
        // but may not fire enter/exit, so sync hover to the real location here.
        recomputeHover()
    }

    /// Set `isHovering` from the current pointer location rather than trusting
    /// enter/exit events, which go stale across scrolling and cell reuse.
    private func recomputeHover() {
        let nowHovering: Bool
        if let window {
            let pointInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            nowHovering = bounds.contains(pointInView)
        } else {
            nowHovering = false
        }
        guard nowHovering != isHovering else { return }
        isHovering = nowHovering
        updateBackground()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        updateBackground()
    }

    private func updateBackground() {
        // Faint gray highlight on hover only — membership reads from the
        // checkmark, matching native macOS list styling.
        let color: NSColor = isHovering ? NSColor.labelColor.withAlphaComponent(0.08) : .clear
        layer?.backgroundColor = color.cgColor
    }
}
