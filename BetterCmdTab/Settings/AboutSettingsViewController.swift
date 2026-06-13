import AppKit
import BetterSettings
import BetterUpdater
import Combine
import QuartzCore

@MainActor
final class AboutSettingsViewController: SettingsTabViewController {

    private enum Layout {
        static let iconSize: CGFloat = 128
        static let capsuleHeight: CGFloat = 30
        static let heroIconTextSpacing: CGFloat = 22
        static let tileGridSpacing: CGFloat = 10
        static let tileGridColumns: Int = 3
        static let pillTransitionDuration: TimeInterval = 0.22
    }

    private let updater = GitHubUpdater.shared
    private var cancellables = Set<AnyCancellable>()

    private var copiedVersion = false
    private var copiedVersionTask: Task<Void, Never>?
    private var upToDateResetTask: Task<Void, Never>?
    private var lastRenderedUpdatePillID: String?

    // MARK: - Views

    private let versionInfoLine = AboutVersionInfoLineView()
    private let updatePillSlot: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private weak var activeUpdatePillView: NSView?
    private var updatePillWidthConstraint: NSLayoutConstraint?

    // MARK: - Lifecycle

    override func setupContent() {
        buildHero()
        buildResources()
        buildFooter()

        bindUpdater()
        refreshVersionLine()
        refreshUpdatePill(force: true)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        copiedVersionTask?.cancel()
        upToDateResetTask?.cancel()
    }

    deinit {
        copiedVersionTask?.cancel()
        upToDateResetTask?.cancel()
    }

    // MARK: - Hero

    private func buildHero() {
        let iconView = NSImageView()
        iconView.image = appIcon(preferredSize: Layout.iconSize)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentHuggingPriority(.required, for: .vertical)
        iconView.wantsLayer = true
        iconView.shadow = makeIconShadow()
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Layout.iconSize),
        ])

        let titleLabel = NSTextField(labelWithString: AppInfo.displayName)
        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .left
        titleLabel.maximumNumberOfLines = 1

        let subtitleLabel = NSTextField(labelWithString: String(localized: "Faster window switching for macOS"))
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .left
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.preferredMaxLayoutWidth = 320

        versionInfoLine.translatesAutoresizingMaskIntoConstraints = false
        versionInfoLine.setAccessibilityLabel(String(localized: "Click to copy version info"))

        let updateWidthConstraint = updatePillSlot.widthAnchor.constraint(equalToConstant: 0)
        updateWidthConstraint.isActive = true
        updatePillWidthConstraint = updateWidthConstraint
        updatePillSlot.heightAnchor.constraint(equalToConstant: Layout.capsuleHeight).isActive = true

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.translatesAutoresizingMaskIntoConstraints = false

        textStack.addArrangedSubview(titleLabel)
        textStack.setCustomSpacing(2, after: titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
        textStack.setCustomSpacing(14, after: subtitleLabel)
        textStack.addArrangedSubview(updatePillSlot)
        textStack.setCustomSpacing(8, after: updatePillSlot)
        textStack.addArrangedSubview(versionInfoLine)

        let heroStack = NSStackView(views: [iconView, textStack])
        heroStack.orientation = .horizontal
        heroStack.alignment = .centerY
        heroStack.spacing = Layout.heroIconTextSpacing
        heroStack.translatesAutoresizingMaskIntoConstraints = false

        let heroSection = NSView()
        heroSection.translatesAutoresizingMaskIntoConstraints = false
        heroSection.addSubview(heroStack)
        NSLayoutConstraint.activate([
            heroStack.topAnchor.constraint(equalTo: heroSection.topAnchor, constant: 12),
            heroStack.leadingAnchor.constraint(equalTo: heroSection.leadingAnchor, constant: 8),
            heroStack.trailingAnchor.constraint(lessThanOrEqualTo: heroSection.trailingAnchor, constant: -8),
            heroStack.bottomAnchor.constraint(equalTo: heroSection.bottomAnchor, constant: -12),
        ])

        addArrangedSubview(heroSection)
    }

    // MARK: - Resources

    private func buildResources() {
        let sourceCode = AboutResourceTileView(
            title: String(localized: "Source Code"),
            iconName: "chevron.left.forwardslash.chevron.right",
            url: URL(string: "https://github.com/rokartur/BetterCmdTab")!
        )
        let issues = AboutResourceTileView(
            title: String(localized: "Report an Issue"),
            iconName: "exclamationmark.bubble.fill",
            url: URL(string: "https://github.com/rokartur/BetterCmdTab/issues")!
        )
        let releases = AboutResourceTileView(
            title: String(localized: "Releases"),
            iconName: "shippingbox.fill",
            url: URL(string: "https://github.com/rokartur/BetterCmdTab/releases")!
        )

        let grid = makeTileGrid(tiles: [sourceCode, issues, releases])
        grid.translatesAutoresizingMaskIntoConstraints = false

        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: section.topAnchor),
            grid.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: section.bottomAnchor),
        ])

        addArrangedSubview(section)
    }

    private func makeTileGrid(tiles: [AboutResourceTileView]) -> NSStackView {
        let columns = Layout.tileGridColumns
        var rows: [NSStackView] = []

        for rowStart in stride(from: 0, to: tiles.count, by: columns) {
            let rowEnd = min(rowStart + columns, tiles.count)
            var rowTiles: [NSView] = Array(tiles[rowStart..<rowEnd])
            while rowTiles.count < columns {
                let filler = NSView()
                filler.translatesAutoresizingMaskIntoConstraints = false
                rowTiles.append(filler)
            }
            let row = NSStackView(views: rowTiles)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = Layout.tileGridSpacing
            row.translatesAutoresizingMaskIntoConstraints = false
            rows.append(row)
        }

        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.distribution = .fill
        grid.spacing = Layout.tileGridSpacing
        grid.translatesAutoresizingMaskIntoConstraints = false

        for row in rows {
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        return grid
    }

    // MARK: - Footer

    private func buildFooter() {
        let year = Calendar.current.component(.year, from: Date())
        let label = NSTextField(labelWithString: "\u{00A9} \(year) \(AppInfo.displayName)")
        label.font = .systemFont(ofSize: 10, weight: .regular)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: section.topAnchor),
            label.centerXAnchor.constraint(equalTo: section.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: section.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: section.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: section.bottomAnchor),
        ])

        addArrangedSubview(section)
    }

    // MARK: - Version line

    private func refreshVersionLine() {
        let text = String(localized: "v\(AppInfo.appVersion)  ·  Build \(AppInfo.appBuildNumber)")
        versionInfoLine.configure(
            text: text,
            iconName: copiedVersion ? "checkmark" : "doc.on.doc",
            iconColor: copiedVersion ? .systemGreen : .tertiaryLabelColor,
            iconPinned: copiedVersion,
            action: { [weak self] in
                self?.copyVersionInfo()
            }
        )
        versionInfoLine.toolTip = text
    }

    private func copyVersionInfo() {
        let versionString = "\(AppInfo.displayName) \(AppInfo.appVersion) (\(AppInfo.appBuildNumber))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(versionString, forType: .string)

        copiedVersion = true
        refreshVersionLine()

        copiedVersionTask?.cancel()
        copiedVersionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, !Task.isCancelled else { return }
            self.copiedVersion = false
            self.refreshVersionLine()
        }
    }

    // MARK: - Update pill

    private func bindUpdater() {
        updater.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.handleUpdaterStateChange(state)
            }
            .store(in: &cancellables)
    }

    private func handleUpdaterStateChange(_ state: UpdateState) {
        if case .upToDate = state {
            scheduleUpToDateReset()
        } else {
            upToDateResetTask?.cancel()
            upToDateResetTask = nil
        }
        refreshUpdatePill()
    }

    private func scheduleUpToDateReset() {
        upToDateResetTask?.cancel()
        upToDateResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.updater.resetToIdle()
        }
    }

    private func refreshUpdatePill(force: Bool = false) {
        let state = updater.state
        let renderID = makeUpdatePillRenderID(for: state)

        if !force, renderID == lastRenderedUpdatePillID {
            return
        }
        lastRenderedUpdatePillID = renderID

        let newView: NSView

        switch state {
        case .idle:
            newView = makeActionPill(
                text: String(localized: "Check for Updates"),
                iconName: "arrow.triangle.2.circlepath",
                iconColor: .secondaryLabelColor,
                prominent: nil
            ) { [weak self] in
                guard let self else { return }
                Task { await self.updater.checkForUpdates(force: true) }
            }

        case .checking:
            newView = makeLoadingPill(text: String(localized: "Checking…"))

        case .upToDate:
            newView = makeStatusPill(
                iconName: "checkmark.circle.fill",
                iconColor: .systemGreen,
                text: String(localized: "You're up to date!")
            )

        case .available(let version, _):
            newView = makeActionPill(
                text: String(format: String(localized: "v%@ — View Update"), version),
                iconName: "arrow.down.circle.fill",
                iconColor: .controlAccentColor,
                prominent: .controlAccentColor
            ) {
                UpdateWindowPresenter.shared.show()
            }

        case .downloading(let progress):
            newView = makeProgressPill(
                progress: progress,
                text: String(format: String(localized: "Downloading %d%%"), Int(progress * 100)),
                color: .controlAccentColor
            )

        case .installing(let progress, let step):
            let text = step.isEmpty
                ? String(format: String(localized: "Installing %d%%"), Int(progress * 100))
                : step
            newView = makeProgressPill(progress: progress, text: text, color: .systemOrange)

        case .readyToInstall:
            newView = makeActionPill(
                text: String(localized: "Restart to Update"),
                iconName: "arrow.clockwise.circle.fill",
                iconColor: .systemGreen,
                prominent: .systemGreen
            ) {
                UpdateWindowPresenter.shared.show()
            }

        case .error(let message):
            newView = makeActionPill(
                text: message,
                iconName: "exclamationmark.triangle.fill",
                iconColor: .systemRed,
                prominent: nil
            ) { [weak self] in
                guard let self else { return }
                Task { await self.updater.checkForUpdates(force: true) }
            }
        }

        transitionUpdatePill(to: newView, animated: !force)
    }

    private func transitionUpdatePill(to newView: NSView, animated: Bool) {
        newView.translatesAutoresizingMaskIntoConstraints = false
        let targetWidth = max(1, ceil(newView.fittingSize.width))

        guard let previous = activeUpdatePillView else {
            installUpdatePillView(newView)
            updatePillWidthConstraint?.constant = targetWidth
            activeUpdatePillView = newView
            return
        }

        installUpdatePillView(newView)
        activeUpdatePillView = newView

        guard animated, view.window != nil else {
            updatePillWidthConstraint?.constant = targetWidth
            previous.removeFromSuperview()
            return
        }

        newView.alphaValue = 0
        view.layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Layout.pillTransitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            updatePillWidthConstraint?.animator().constant = targetWidth
            previous.animator().alphaValue = 0
            newView.animator().alphaValue = 1
            view.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak previous] in
            Task { @MainActor [weak previous] in
                previous?.removeFromSuperview()
            }
        })
    }

    private func installUpdatePillView(_ pill: NSView) {
        updatePillSlot.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: updatePillSlot.topAnchor),
            pill.bottomAnchor.constraint(equalTo: updatePillSlot.bottomAnchor),
            pill.centerXAnchor.constraint(equalTo: updatePillSlot.centerXAnchor),
        ])
    }

    private func makeUpdatePillRenderID(for state: UpdateState) -> String {
        switch state {
        case .idle: return "idle"
        case .checking: return "checking"
        case .upToDate: return "upToDate"
        case .available(let v, _): return "available-\(v)"
        case .downloading(let p): return "downloading-\(Int(p * 100))"
        case .readyToInstall: return "readyToInstall"
        case .installing(let p, let s): return "installing-\(Int(p * 100))-\(s)"
        case .error(let m): return "error-\(m)"
        }
    }

    private func makeActionPill(
        text: String,
        iconName: String,
        iconColor: NSColor,
        prominent: NSColor?,
        action: @escaping () -> Void
    ) -> NSView {
        let pill = CapsulePillView()
        let style: CapsulePillView.Style = prominent.map { .prominent($0) } ?? .subtle
        pill.configure(
            text: text,
            iconName: iconName,
            iconColor: prominent == nil ? iconColor : .white,
            textColor: prominent == nil ? .secondaryLabelColor : .white,
            textFont: .systemFont(ofSize: 12, weight: .medium),
            style: style,
            horizontalPadding: 14,
            verticalPadding: 6,
            action: action
        )
        return pill
    }

    private func makeStatusPill(iconName: String, iconColor: NSColor, text: String) -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        iconView.contentTintColor = iconColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeLoadingPill(text: String) -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .labelColor

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeProgressPill(progress: Double, text: String, color: NSColor) -> NSView {
        AboutProgressPillView(progress: progress, text: text, color: color)
    }

    // MARK: - Helpers

    private func appIcon(preferredSize: CGFloat) -> NSImage {
        let size = NSSize(width: preferredSize, height: preferredSize)
        if let icon = NSApplication.shared.applicationIconImage.copy() as? NSImage {
            icon.size = size
            return icon
        }
        let fallback = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage(size: size)
        fallback.size = size
        return fallback
    }

    private func makeIconShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 14
        return shadow
    }
}

// MARK: - Version Info Line

/// Borderless monospace "v… · Build …" line with a copy icon that fades in on
/// hover. Tapping runs the configured action (copies version info).
@MainActor
private final class AboutVersionInfoLineView: NSView {

    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    private var trackingArea: NSTrackingArea?
    private var action: (() -> Void)?
    private var iconPinned = false

    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            updateAppearance(animated: true)
        }
    }
    private var isPressing = false {
        didSet {
            guard oldValue != isPressing else { return }
            updateAppearance(animated: true)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        iconView.alphaValue = 0

        let iconContainer = NSView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.setContentHuggingPriority(.required, for: .horizontal)
        iconContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconContainer.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 14),
            iconContainer.heightAnchor.constraint(equalToConstant: 14),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(lessThanOrEqualTo: iconContainer.widthAnchor),
            iconView.heightAnchor.constraint(lessThanOrEqualTo: iconContainer.heightAnchor),
        ])

        let stack = NSStackView(views: [label, iconContainer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])

        updateAppearance(animated: false)
    }

    func configure(text: String, iconName: String?, iconColor: NSColor, iconPinned: Bool = false, action: @escaping () -> Void) {
        label.stringValue = text
        if let iconName {
            let cfg = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)
            iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
            iconView.contentTintColor = iconColor
            iconView.isHidden = false
        } else {
            iconView.image = nil
            iconView.isHidden = true
        }
        self.action = action
        self.iconPinned = iconPinned
        updateTrackingAreas()
        updateAppearance(animated: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        guard action != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard action != nil else { return }
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard action != nil else { return }
        isHovering = false
        isPressing = false
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard action != nil else { return }
        isPressing = true
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        guard action != nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        isPressing = bounds.contains(location)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let action else { return }
        let location = convert(event.locationInWindow, from: nil)
        let wasPressing = isPressing
        isPressing = false
        if wasPressing && bounds.contains(location) {
            action()
        }
    }

    private func updateAppearance(animated: Bool) {
        let textColor: NSColor
        let iconAlpha: CGFloat
        if iconPinned {
            textColor = isHovering || isPressing ? .labelColor : .secondaryLabelColor
            iconAlpha = 1.0
        } else if isPressing || isHovering {
            textColor = .labelColor
            iconAlpha = 1.0
        } else {
            textColor = .secondaryLabelColor
            iconAlpha = action == nil ? 0 : 0.55
        }

        let apply = {
            self.label.textColor = textColor
            self.iconView.alphaValue = iconAlpha
        }

        guard animated, window != nil else {
            apply()
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            apply()
        }
    }
}

// MARK: - Resource Tile

/// Glass tile with an icon badge (top-left), title (bottom-left), and an
/// arrow that springs in on hover. Opens `url` on click.
@MainActor
private final class AboutResourceTileView: NSView {

    private enum Metric {
        static let cornerRadius: CGFloat = 14
        static let height: CGFloat = 96
        static let iconBadgeSize: CGFloat = 36
        static let iconBadgeCorner: CGFloat = 10
        static let iconPointSize: CGFloat = 16
    }

    private let url: URL

    private var neutralTint: NSColor {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .white : .black
    }

    private let glassView = LiquidGlassAppKitView(cornerRadius: Metric.cornerRadius, variant: .regular)

    private let iconBadge = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let arrowView = NSImageView()

    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            if !isHovering { isPressing = false }
            updateAppearance(animated: true)
        }
    }
    private var isPressing = false {
        didSet {
            guard oldValue != isPressing else { return }
            updateAppearance(animated: true)
        }
    }

    init(title: String, iconName: String, url: URL) {
        self.url = url
        super.init(frame: .zero)
        setup(title: title, iconName: iconName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup(title: String, iconName: String) {
        wantsLayer = true
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false

        glassView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassView)

        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = Metric.iconBadgeCorner
        iconBadge.layer?.cornerCurve = .continuous
        iconBadge.layer?.backgroundColor = neutralTint.withAlphaComponent(0.08).cgColor
        iconBadge.translatesAutoresizingMaskIntoConstraints = false

        if let iconImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Metric.iconPointSize, weight: .semibold)) {
            iconView.image = iconImage
        }
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        if let arrowImage = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
            arrowView.image = arrowImage
        }
        arrowView.contentTintColor = .tertiaryLabelColor
        arrowView.translatesAutoresizingMaskIntoConstraints = false
        arrowView.wantsLayer = true
        arrowView.alphaValue = 0

        addSubview(iconBadge)
        addSubview(titleLabel)
        addSubview(arrowView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metric.height),

            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),

            iconBadge.widthAnchor.constraint(equalToConstant: Metric.iconBadgeSize),
            iconBadge.heightAnchor.constraint(equalToConstant: Metric.iconBadgeSize),
            iconBadge.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            iconBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            iconView.centerXAnchor.constraint(equalTo: iconBadge.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBadge.centerYAnchor),

            arrowView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            arrowView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        updateAppearance(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        isPressing = true
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        let location = convert(event.locationInWindow, from: nil)
        isPressing = bounds.contains(location)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let location = convert(event.locationInWindow, from: nil)
        let wasPressing = isPressing
        isPressing = false
        if wasPressing && bounds.contains(location) {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateAppearance(animated: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let activeTint = neutralTint

        let arrowAlpha: CGFloat
        let arrowScale: CGFloat
        let badgeAlpha: CGFloat
        let badgeIconColor: NSColor

        if isPressing {
            arrowAlpha = 1.0
            arrowScale = 0.90
            badgeAlpha = dark ? 0.18 : 0.14
            badgeIconColor = .labelColor
        } else if isHovering {
            arrowAlpha = 1.0
            arrowScale = 1.0
            badgeAlpha = dark ? 0.14 : 0.11
            badgeIconColor = .labelColor
        } else {
            arrowAlpha = 0
            arrowScale = 0.55
            badgeAlpha = dark ? 0.08 : 0.06
            badgeIconColor = .secondaryLabelColor
        }

        let apply = {
            self.iconBadge.layer?.backgroundColor = activeTint.withAlphaComponent(badgeAlpha).cgColor
            self.iconView.contentTintColor = badgeIconColor
        }

        guard animated, window != nil, let arrowLayer = arrowView.layer else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            apply()
            arrowView.alphaValue = arrowAlpha
            arrowView.layer?.setValue(arrowScale, forKeyPath: "transform.scale")
            CATransaction.commit()
            return
        }

        recenterAnchor(arrowLayer)

        CATransaction.begin()
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0))
        apply()

        let scaleAnim = CASpringAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = (arrowLayer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? arrowScale
        scaleAnim.toValue = arrowScale
        scaleAnim.damping = isHovering && !isPressing ? 12 : 20
        scaleAnim.stiffness = 280
        scaleAnim.mass = 1
        scaleAnim.initialVelocity = 0
        scaleAnim.duration = scaleAnim.settlingDuration
        arrowLayer.setValue(arrowScale, forKeyPath: "transform.scale")
        arrowLayer.add(scaleAnim, forKey: "arrow.scale")

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = isHovering ? 0.16 : 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            arrowView.animator().alphaValue = arrowAlpha
        }

        CATransaction.commit()
    }

    private func recenterAnchor(_ layer: CALayer) {
        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let anchor = layer.anchorPoint
        if abs(anchor.x - 0.5) < 0.001 && abs(anchor.y - 0.5) < 0.001 { return }
        let position = layer.position
        layer.position = CGPoint(
            x: position.x + (0.5 - anchor.x) * bounds.width,
            y: position.y + (0.5 - anchor.y) * bounds.height
        )
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }
}

// MARK: - Progress Pill

/// Vertical "text over a thin progress bar" pill for download/install states.
@MainActor
private final class AboutProgressPillView: NSView {

    private enum Constants {
        static let width: CGFloat = 140
    }

    init(progress: Double, text: String, color: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: text)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let barBackground = NSView()
        barBackground.wantsLayer = true
        barBackground.layer?.cornerRadius = 1.5
        barBackground.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        barBackground.translatesAutoresizingMaskIntoConstraints = false

        let barFill = NSView()
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 1.5
        barFill.layer?.backgroundColor = color.cgColor
        barFill.translatesAutoresizingMaskIntoConstraints = false

        barBackground.addSubview(barFill)
        NSLayoutConstraint.activate([
            barBackground.widthAnchor.constraint(equalToConstant: Constants.width),
            barBackground.heightAnchor.constraint(equalToConstant: 3),
            barFill.leadingAnchor.constraint(equalTo: barBackground.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barBackground.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barBackground.bottomAnchor),
            barFill.widthAnchor.constraint(equalToConstant: max(0, min(1, progress)) * Constants.width),
        ])

        let stack = NSStackView(views: [titleLabel, barBackground])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
