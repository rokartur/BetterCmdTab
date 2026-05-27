import AppKit
import BetterSettings
import BetterUpdater
import Combine
import QuartzCore

@MainActor
final class AboutSettingsViewController: SettingsTabViewController {

    private enum Layout {
        static let iconSize: CGFloat = 128
        static let capsuleHeight: CGFloat = 24
        static let quickLinksSpacing: CGFloat = 8
        static let pillTransitionDuration: TimeInterval = 0.22
    }

    private let updater = GitHubUpdater.shared
    private var cancellables = Set<AnyCancellable>()

    private var copiedVersion = false
    private var copiedVersionTask: Task<Void, Never>?
    private var upToDateResetTask: Task<Void, Never>?
    private var lastRenderedUpdatePillID: String?

    // MARK: - Views

    private let versionPill = CapsulePillView()
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
        buildQuickLinks()
        buildFooter()

        bindUpdater()
        refreshVersionPill()
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
        let heroSection = NSView()
        heroSection.translatesAutoresizingMaskIntoConstraints = false

        let heroStack = NSStackView()
        heroStack.orientation = .vertical
        heroStack.alignment = .centerX
        heroStack.spacing = 0
        heroStack.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = appIcon(preferredSize: Layout.iconSize)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true
        iconView.shadow = makeIconShadow()
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Layout.iconSize),
        ])

        let titleLabel = NSTextField(labelWithString: AppInfo.displayName)
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(labelWithString: "Faster window switching for macOS")
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        versionPill.translatesAutoresizingMaskIntoConstraints = false
        versionPill.setAccessibilityLabel("Click to copy version info")
        versionPill.heightAnchor.constraint(equalToConstant: Layout.capsuleHeight).isActive = true

        heroStack.addArrangedSubview(iconView)
        heroStack.setCustomSpacing(12, after: iconView)

        heroStack.addArrangedSubview(titleLabel)
        heroStack.setCustomSpacing(2, after: titleLabel)

        heroStack.addArrangedSubview(subtitleLabel)
        heroStack.setCustomSpacing(12, after: subtitleLabel)

        heroStack.addArrangedSubview(versionPill)
        heroStack.setCustomSpacing(8, after: versionPill)

        heroStack.addArrangedSubview(updatePillSlot)
        updatePillSlot.heightAnchor.constraint(equalToConstant: Layout.capsuleHeight).isActive = true
        let widthConstraint = updatePillSlot.widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.isActive = true
        updatePillWidthConstraint = widthConstraint

        heroSection.addSubview(heroStack)
        NSLayoutConstraint.activate([
            heroStack.topAnchor.constraint(equalTo: heroSection.topAnchor, constant: 4),
            heroStack.leadingAnchor.constraint(equalTo: heroSection.leadingAnchor),
            heroStack.trailingAnchor.constraint(equalTo: heroSection.trailingAnchor),
            heroStack.bottomAnchor.constraint(equalTo: heroSection.bottomAnchor),
        ])

        addArrangedFullWidth(heroSection)
    }

    // MARK: - Quick links

    private func buildQuickLinks() {
        let issues = QuickLinkCardView(
            title: "Report an Issue",
            iconName: "exclamationmark.bubble.fill",
            url: URL(string: "https://github.com/rokartur/BetterCmdTab/issues")!
        )
        let sourceCode = QuickLinkCardView(
            title: "Source Code",
            iconName: "chevron.left.forwardslash.chevron.right",
            url: URL(string: "https://github.com/rokartur/BetterCmdTab")!
        )

        let stack = NSStackView(views: [issues, sourceCode])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = Layout.quickLinksSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: section.topAnchor),
            stack.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: section.bottomAnchor),
        ])

        addArrangedFullWidth(section)
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

        addArrangedFullWidth(section)
    }

    private func addArrangedFullWidth(_ section: NSView) {
        // Base controller provides the scrolling, full-width content stack.
        addArrangedSubview(section)
    }

    // MARK: - Version pill

    private func refreshVersionPill() {
        let text = copiedVersion
            ? "Copied!"
            : "v\(AppInfo.appVersion)  ·  Build \(AppInfo.appBuildNumber)"

        versionPill.configure(
            text: text,
            iconName: copiedVersion ? "checkmark" : nil,
            iconColor: copiedVersion ? .systemGreen : .secondaryLabelColor,
            textColor: .secondaryLabelColor,
            textFont: .monospacedSystemFont(ofSize: 11, weight: .medium),
            style: .subtle,
            horizontalPadding: 10,
            verticalPadding: 5,
            action: { [weak self] in
                self?.copyVersionInfo()
            }
        )
    }

    private func copyVersionInfo() {
        let versionString = "\(AppInfo.displayName) \(AppInfo.appVersion) (\(AppInfo.appBuildNumber))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(versionString, forType: .string)

        copiedVersion = true
        refreshVersionPill()

        copiedVersionTask?.cancel()
        copiedVersionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, !Task.isCancelled else { return }
            self.copiedVersion = false
            self.refreshVersionPill()
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
            // Nothing fancy — let the pill stay in "up to date" until the next check.
            _ = self
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
                text: "Check for Updates",
                iconName: "arrow.triangle.2.circlepath",
                iconColor: .secondaryLabelColor,
                prominent: nil
            ) { [weak self] in
                guard let self else { return }
                Task { await self.updater.checkForUpdates(force: true) }
            }

        case .checking:
            newView = makeLoadingPill(text: "Checking…")

        case .upToDate:
            newView = makeStatusPill(
                iconName: "checkmark.circle.fill",
                iconColor: .systemGreen,
                text: "You're up to date!"
            )

        case .available(let version, _):
            newView = makeActionPill(
                text: "v\(version) — View Update",
                iconName: "arrow.down.circle.fill",
                iconColor: .controlAccentColor,
                prominent: .controlAccentColor
            ) {
                UpdateWindowPresenter.shared.show()
            }

        case .downloading(let progress):
            newView = makeProgressPill(
                progress: progress,
                text: "Downloading \(Int(progress * 100))%",
                color: .controlAccentColor
            )

        case .installing(let progress, let step):
            let text = step.isEmpty
                ? "Installing \(Int(progress * 100))%"
                : step
            newView = makeProgressPill(progress: progress, text: text, color: .systemOrange)

        case .readyToInstall:
            newView = makeActionPill(
                text: "Restart to Update",
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
        let style: CapsulePillView.Style
        if let prominent {
            style = .prominent(prominent)
        } else {
            style = .subtle
        }
        pill.configure(
            text: text,
            iconName: iconName,
            iconColor: iconColor,
            textColor: prominent == nil ? .secondaryLabelColor : .labelColor,
            textFont: .systemFont(ofSize: 11, weight: .medium),
            style: style,
            horizontalPadding: 12,
            verticalPadding: 5,
            action: action
        )
        return pill
    }

    private func makeStatusPill(iconName: String, iconColor: NSColor, text: String) -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        iconView.contentTintColor = iconColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
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
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeProgressPill(progress: Double, text: String, color: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let trackWidth: CGFloat = 140
        let background = NSView()
        background.wantsLayer = true
        background.layer?.cornerRadius = 1.5
        background.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        background.translatesAutoresizingMaskIntoConstraints = false

        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 1.5
        fill.layer?.backgroundColor = color.cgColor
        fill.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(fill)
        NSLayoutConstraint.activate([
            background.widthAnchor.constraint(equalToConstant: trackWidth),
            background.heightAnchor.constraint(equalToConstant: 3),
            fill.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            fill.topAnchor.constraint(equalTo: background.topAnchor),
            fill.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            fill.widthAnchor.constraint(equalToConstant: max(0, min(1, progress)) * trackWidth),
        ])

        let stack = NSStackView(views: [label, background])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
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
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 8
        return shadow
    }
}
