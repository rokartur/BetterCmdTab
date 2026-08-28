import AppKit

/// Editor for per-app switcher letters: give an app a fixed jump letter, or skip
/// it so it gets no letter and reserves none (#183). These are panel hints, not
/// Direct Activation shortcuts — no global hotkey is registered. A fixed letter
/// and a skip are the two answers to the same per-app question, so they live in
/// one list; an app is in one state or the other, never both.
@MainActor
final class QuickJumpMappingsSheetWindowController: NSWindowController {
    private let content = QuickJumpMappingsSheetViewController()
    private var hasDismissed = false
    var onDidDismiss: (() -> Void)?

    init() {
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Custom App Letters")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 460))
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
private final class QuickJumpMappingsSheetViewController: NSViewController {
    var onClose: (() -> Void)?

    /// One row per app with an override, ordered mapped-first then skipped. Both
    /// stores stay separate in Preferences; this list is just their union for
    /// display.
    private enum RowModel {
        case mapped(QuickJumpMapping)
        case skipped(String) // bundleID

        var bundleID: String {
            switch self {
            case .mapped(let m): return m.bundleID
            case .skipped(let id): return id
            }
        }
    }

    private var mappings = Preferences.shared.quickJumpMappings
    private var excluded = Preferences.shared.letterHintExcludedBundleIDs
    private var appPicker: AppsPickerSheetWindowController?
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private var rowModels: [RowModel] {
        mappings.map(RowModel.mapped) + excluded.map(RowModel.skipped)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 460))

        let prompt = NSTextField(wrappingLabelWithString: String(localized:
            "Give an app a fixed letter, or tick Skip so it gets no letter and its letter frees up for another app. A fixed letter beats a same-key panel action while that app is visible."))
        prompt.font = .systemFont(ofSize: 12)
        prompt.textColor = .secondaryLabelColor
        prompt.maximumNumberOfLines = 0
        prompt.translatesAutoresizingMaskIntoConstraints = false

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        emptyLabel.stringValue = String(localized: "No apps added yet.")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: String(localized: "Add App…"), target: self, action: #selector(addApp))
        addButton.bezelStyle = .rounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading

        let doneButton = NSButton(title: String(localized: "Done"), target: self, action: #selector(done))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [addButton, NSView(), doneButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(prompt)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            prompt.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            prompt.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            prompt.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: prompt.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        rebuildRows()
    }

    private func rebuildRows() {
        for subview in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        let models = rowModels
        emptyLabel.isHidden = !models.isEmpty
        for (index, model) in models.enumerated() {
            let letter: Character?
            switch model {
            case .mapped(let m): letter = m.letter
            case .skipped: letter = nil
            }
            let row = QuickJumpMappingRowView(bundleID: model.bundleID, letter: letter)
            let bundleID = model.bundleID
            row.onChange = { [weak self] rawLetter in
                self?.changeLetter(for: bundleID, to: rawLetter) ?? false
            }
            row.onToggleSkip = { [weak self] skip in self?.setSkip(bundleID, skip) }
            row.onRemove = { [weak self] in self?.remove(bundleID: bundleID) }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if index != models.indices.last {
                let divider = NSBox()
                divider.boxType = .separator
                rowsStack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }
    }

    private func persist() {
        Preferences.shared.quickJumpMappings = mappings
        Preferences.shared.letterHintExcludedBundleIDs = excluded
        mappings = Preferences.shared.quickJumpMappings
        excluded = Preferences.shared.letterHintExcludedBundleIDs
    }

    private func changeLetter(for bundleID: String, to rawLetter: String) -> Bool {
        guard let candidate = QuickJumpMapping(bundleID: bundleID, letter: rawLetter),
              !mappings.contains(where: { $0.bundleID != bundleID && $0.letter == candidate.letter }),
              let index = mappings.firstIndex(where: { $0.bundleID == bundleID }) else {
            NSSound.beep()
            return false
        }
        mappings[index] = candidate
        persist()
        return true
    }

    /// Move an app between the "fixed letter" and "skipped" states. Skipping drops
    /// its mapping; un-skipping gives it a freshly picked unused letter, the same
    /// way a newly added app is seeded.
    private func setSkip(_ bundleID: String, _ skip: Bool) {
        if skip {
            mappings.removeAll { $0.bundleID == bundleID }
            if !excluded.contains(bundleID) { excluded.append(bundleID) }
        } else {
            excluded.removeAll { $0 == bundleID }
            if !mappings.contains(where: { $0.bundleID == bundleID }),
               let mapping = QuickJumpMapping(bundleID: bundleID, letter: String(freeLetter(for: bundleID))) {
                mappings.append(mapping)
            }
        }
        persist()
        rebuildRows()
    }

    private func remove(bundleID: String) {
        mappings.removeAll { $0.bundleID == bundleID }
        excluded.removeAll { $0 == bundleID }
        persist()
        rebuildRows()
    }

    /// An unused letter for `bundleID`: first an unused letter from its name, then
    /// any unused a–z. Falls back to "a" only if every letter is already taken.
    private func freeLetter(for bundleID: String) -> Character {
        let used = Set(mappings.map(\.letter))
        let name = AppsSettingsViewController.appInfo(for: bundleID).name
        let fromName = name.folding(options: .diacriticInsensitive, locale: nil).lowercased()
            .filter { $0.isASCII && $0.isLetter }
        return fromName.first(where: { !used.contains($0) })
            ?? "abcdefghijklmnopqrstuvwxyz".first(where: { !used.contains($0) })
            ?? "a"
    }

    @objc private func addApp() {
        guard let window = view.window, appPicker == nil else { return }
        let picker = AppsPickerSheetWindowController(
            title: String(localized: "Choose an App"),
            prompt: String(localized: "Choose an app to give a fixed letter or skip from letter hints."),
            selectedBundleIDs: [],
            singleSelection: true,
            confirmTitle: String(localized: "Add")
        ) { [weak self] selection in
            guard let self, let bundleID = selection.first else { return }
            if self.mappings.contains(where: { $0.bundleID == bundleID }) || self.excluded.contains(bundleID) {
                NSSound.beep()
                return
            }
            guard let mapping = QuickJumpMapping(bundleID: bundleID, letter: String(self.freeLetter(for: bundleID))) else { return }
            self.mappings.append(mapping)
            self.persist()
            self.rebuildRows()
        }
        picker.onDidDismiss = { [weak self] in self?.appPicker = nil }
        appPicker = picker
        picker.present(asSheetFor: window)
    }

    @objc private func done() { onClose?() }
}

@MainActor
private final class QuickJumpMappingRowView: NSView, NSTextFieldDelegate {
    var onChange: ((String) -> Bool)?
    var onToggleSkip: ((Bool) -> Void)?
    var onRemove: (() -> Void)?

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let letter = NSTextField()
    private let skipCheckbox = NSButton()
    private let removeButton = NSButton()
    private var acceptedLetter: String
    private let bundleID: String
    private let isSkipped: Bool

    init(bundleID: String, letter: Character?) {
        self.bundleID = bundleID
        self.isSkipped = (letter == nil)
        self.acceptedLetter = letter.map { String($0).uppercased() } ?? ""
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        name.stringValue = bundleID
        name.lineBreakMode = .byTruncatingMiddle

        self.letter.stringValue = acceptedLetter
        self.letter.alignment = .center
        self.letter.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        self.letter.placeholderString = isSkipped ? "—" : "A"
        self.letter.delegate = self
        self.letter.target = self
        self.letter.action = #selector(commitLetter)
        self.letter.isEnabled = !isSkipped
        self.letter.toolTip = String(localized: "Enter one unused letter from A to Z.")
        self.letter.translatesAutoresizingMaskIntoConstraints = false

        skipCheckbox.setButtonType(.switch)
        skipCheckbox.title = String(localized: "Skip")
        skipCheckbox.state = isSkipped ? .on : .off
        skipCheckbox.target = self
        skipCheckbox.action = #selector(toggleSkip)
        skipCheckbox.toolTip = String(localized: "Skip letter hints for this app so its letter frees up for another app.")
        skipCheckbox.translatesAutoresizingMaskIntoConstraints = false

        removeButton.isBordered = false
        removeButton.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: String(localized: "Remove"))
        removeButton.contentTintColor = .tertiaryLabelColor
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [name])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(labels)
        addSubview(self.letter)
        addSubview(skipCheckbox)
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.letter.leadingAnchor.constraint(greaterThanOrEqualTo: labels.trailingAnchor, constant: 10),
            self.letter.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.letter.widthAnchor.constraint(equalToConstant: 38),
            skipCheckbox.leadingAnchor.constraint(equalTo: self.letter.trailingAnchor, constant: 10),
            skipCheckbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: skipCheckbox.trailingAnchor, constant: 10),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
        ])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = AppsSettingsViewController.appInfo(for: bundleID)
            DispatchQueue.main.async {
                guard let self, self.bundleID == bundleID else { return }
                self.name.stringValue = info.name
                self.icon.image = info.icon
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func controlTextDidEndEditing(_ obj: Notification) { commitLetter() }

    @objc private func commitLetter() {
        guard !isSkipped else { return }
        let raw = letter.stringValue
        if onChange?(raw) == true {
            acceptedLetter = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            letter.stringValue = acceptedLetter
        } else {
            letter.stringValue = acceptedLetter
        }
    }

    @objc private func toggleSkip() {
        onToggleSkip?(skipCheckbox.state == .on)
    }

    @objc private func remove() { onRemove?() }
}
