import AppKit

/// Sheet that lets the user pick a set of apps (by bundle identifier) via
/// checkboxes — used for both the exclusion list and the pin list. Ported from
/// the "Manage apps" pattern: a plain `NSWindowController` wrapping an
/// `NSViewController`, presented with `beginSheet`. The app list combines a
/// scan of the Applications folders with the currently-running apps.
@MainActor
final class AppsPickerSheetWindowController: NSWindowController {
    private let content: AppsPickerSheetViewController
    private var hasDismissed = false

    /// Called once after the sheet is dismissed (Save or Cancel) so the owner
    /// can drop its reference.
    var onDidDismiss: (() -> Void)?

    init(title: String, prompt: String, selectedBundleIDs: Set<String>, singleSelection: Bool = false, onDone: @escaping (Set<String>) -> Void) {
        content = AppsPickerSheetViewController(prompt: prompt, selectedBundleIDs: selectedBundleIDs, singleSelection: singleSelection, onDone: onDone)
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 440, height: 540))
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
    /// When true, only one app can be chosen (radio behavior) and the search /
    /// filter row is hidden — used by the direct-activation slot picker.
    private let singleSelection: Bool
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
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let cancelButton = NSButton()
    private let saveButton = NSButton()
    private let spinner = NSProgressIndicator()

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("AppsPickerCell")

    init(prompt: String, selectedBundleIDs: Set<String>, singleSelection: Bool = false, onDone: @escaping (Set<String>) -> Void) {
        self.prompt = prompt
        self.selected = selectedBundleIDs
        self.singleSelection = singleSelection
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 540))

        promptLabel.stringValue = prompt
        promptLabel.font = .systemFont(ofSize: 12)
        promptLabel.textColor = .secondaryLabelColor
        promptLabel.maximumNumberOfLines = 0
        promptLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search apps…"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        filterPopup.translatesAutoresizingMaskIntoConstraints = false
        filterPopup.setContentHuggingPriority(.required, for: .horizontal)
        filterPopup.removeAllItems()
        filterPopup.addItems(withTitles: ["All", "Checked", "Unchecked"])
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

        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Esc
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(handleSave)
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [spinner, NSView(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(promptLabel)
        root.addSubview(topRow)
        root.addSubview(scrollView)
        root.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            promptLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            promptLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            promptLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            topRow.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 12),
            topRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            topRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
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
                self.allApps = apps
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

    @objc private func handleSave() {
        onDone(selected)
        onClose?()
    }

    @objc private func filterChanged() {
        selectionFilter = SelectionFilter(rawValue: filterPopup.indexOfSelectedItem) ?? .all
        applyFilter()
    }

    private func toggle(bundleID: String, on: Bool) {
        if singleSelection {
            // Radio: enabling one clears the others; disabling clears all.
            selected = on ? [bundleID] : []
            tableView.reloadData()
            return
        }
        if on { selected.insert(bundleID) } else { selected.remove(bundleID) }
        // In a filtered view, re-apply after a short delay so a just-toggled row
        // slides out of "Checked"/"Unchecked" instead of vanishing under the
        // user's cursor mid-tap.
        guard selectionFilter != .all else { return }
        pendingFilterTask?.cancel()
        pendingFilterTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.applyFilter()
        }
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
            bundleID: app.bundleID,
            isOn: selected.contains(app.bundleID)
        ) { [weak self] bid, on in
            self?.toggle(bundleID: bid, on: on)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

@MainActor
final class AppsPickerCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    private var bundleID = ""
    private var onToggle: ((String, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setup() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [iconView, nameLabel, spacer, toggle])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(icon: NSImage, name: String, bundleID: String, isOn: Bool, onToggle: @escaping (String, Bool) -> Void) {
        iconView.image = icon
        nameLabel.stringValue = name
        self.bundleID = bundleID
        self.onToggle = onToggle
        toggle.state = isOn ? .on : .off
    }

    @objc private func toggled() {
        onToggle?(bundleID, toggle.state == .on)
    }
}
