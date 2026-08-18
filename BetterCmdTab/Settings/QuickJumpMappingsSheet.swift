import AppKit

/// Editor for persistent in-switcher app → letter mappings. These are panel
/// hints, not Direct Activation shortcuts: no global hotkey is registered.
@MainActor
final class QuickJumpMappingsSheetWindowController: NSWindowController {
    private let content = QuickJumpMappingsSheetViewController()
    private var hasDismissed = false
    var onDidDismiss: (() -> Void)?

    init() {
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Custom Quick-Jump Mappings")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 500, height: 460))
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

    private var mappings = Preferences.shared.quickJumpMappings
    private var appPicker: AppsPickerSheetWindowController?
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 460))

        let prompt = NSTextField(wrappingLabelWithString: String(localized:
            "Choose one letter per app. The first listed window for that app gets the stable letter; its other windows keep automatic labels. A custom letter takes priority over a same-key panel action only while that mapped app is visible."))
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

        emptyLabel.stringValue = String(localized: "No custom mappings yet.")
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
        emptyLabel.isHidden = !mappings.isEmpty
        for (index, mapping) in mappings.enumerated() {
            let row = QuickJumpMappingRowView(mapping: mapping)
            row.onChange = { [weak self] rawLetter in
                self?.changeLetter(for: mapping.bundleID, to: rawLetter) ?? false
            }
            row.onRemove = { [weak self] in self?.remove(bundleID: mapping.bundleID) }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if index != mappings.indices.last {
                let divider = NSBox()
                divider.boxType = .separator
                rowsStack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }
    }

    private func persist() {
        Preferences.shared.quickJumpMappings = mappings
        mappings = Preferences.shared.quickJumpMappings
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

    private func remove(bundleID: String) {
        mappings.removeAll { $0.bundleID == bundleID }
        persist()
        rebuildRows()
    }

    @objc private func addApp() {
        guard let window = view.window, appPicker == nil else { return }
        let picker = AppsPickerSheetWindowController(
            title: String(localized: "Choose an App"),
            prompt: String(localized: "Choose the app that should receive a stable quick-jump letter."),
            selectedBundleIDs: [],
            singleSelection: true,
            confirmTitle: String(localized: "Add")
        ) { [weak self] selection in
            guard let self, let bundleID = selection.first else { return }
            if self.mappings.contains(where: { $0.bundleID == bundleID }) {
                NSSound.beep()
                return
            }
            let used = Set(self.mappings.map(\.letter))
            let name = AppsSettingsViewController.appInfo(for: bundleID).name
            let candidates = name.folding(options: .diacriticInsensitive, locale: nil).lowercased()
                .filter { $0.isASCII && $0.isLetter }
            guard let letter = candidates.first(where: { !used.contains($0) })
                    ?? "abcdefghijklmnopqrstuvwxyz".first(where: { !used.contains($0) }),
                  let mapping = QuickJumpMapping(bundleID: bundleID, letter: String(letter)) else { return }
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
    var onRemove: (() -> Void)?

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let letter = NSTextField()
    private let removeButton = NSButton()
    private var acceptedLetter: String
    private let bundleID: String

    init(mapping: QuickJumpMapping) {
        bundleID = mapping.bundleID
        acceptedLetter = String(mapping.letter).uppercased()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        name.stringValue = mapping.bundleID
        name.lineBreakMode = .byTruncatingMiddle

        letter.stringValue = acceptedLetter
        letter.alignment = .center
        letter.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        letter.placeholderString = "A"
        letter.delegate = self
        letter.target = self
        letter.action = #selector(commitLetter)
        letter.toolTip = String(localized: "Enter one unused letter from A to Z.")
        letter.translatesAutoresizingMaskIntoConstraints = false

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
        addSubview(letter)
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            letter.leadingAnchor.constraint(greaterThanOrEqualTo: labels.trailingAnchor, constant: 10),
            letter.centerYAnchor.constraint(equalTo: centerYAnchor),
            letter.widthAnchor.constraint(equalToConstant: 38),
            removeButton.leadingAnchor.constraint(equalTo: letter.trailingAnchor, constant: 10),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
        ])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = AppsSettingsViewController.appInfo(for: mapping.bundleID)
            DispatchQueue.main.async {
                guard let self, self.bundleID == mapping.bundleID else { return }
                self.name.stringValue = info.name
                self.icon.image = info.icon
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func controlTextDidEndEditing(_ obj: Notification) { commitLetter() }

    @objc private func commitLetter() {
        let raw = letter.stringValue
        if onChange?(raw) == true {
            acceptedLetter = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            letter.stringValue = acceptedLetter
        } else {
            letter.stringValue = acceptedLetter
        }
    }

    @objc private func remove() { onRemove?() }
}
