import AppKit
import QuartzCore

@MainActor
final class SettingsDetailViewController: NSViewController {

    private let container = NSView()
    private var currentChild: NSViewController?
    private var currentTab: SettingsTab?

    /// Cached controllers so switching tabs is instant after the first visit.
    private var cache: [SettingsTab: NSViewController] = [:]

    private var isAnimating = false

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        root.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    func show(_ tab: SettingsTab) {
        guard currentTab != tab else { return }

        let next = controller(for: tab)
        let oldView = currentChild?.view
        let newView = next.view
        newView.translatesAutoresizingMaskIntoConstraints = false

        if newView.superview !== container {
            container.addSubview(newView)
            NSLayoutConstraint.activate([
                newView.topAnchor.constraint(equalTo: container.topAnchor),
                newView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                newView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                newView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        } else {
            container.addSubview(newView, positioned: .above, relativeTo: nil)
        }

        currentChild = next
        currentTab = tab

        let shouldAnimate = oldView != nil
            && !isAnimating
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if let oldView, shouldAnimate {
            isAnimating = true
            newView.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                newView.animator().alphaValue = 1
                oldView.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak oldView] in
                Task { @MainActor [weak self, weak oldView] in
                    guard let self else { return }
                    oldView?.removeFromSuperview()
                    self.isAnimating = false
                }
            })
        } else {
            newView.alphaValue = 1
            oldView?.removeFromSuperview()
        }
    }

    private func controller(for tab: SettingsTab) -> NSViewController {
        if let cached = cache[tab] {
            return cached
        }
        let new: NSViewController
        switch tab {
        case .general: new = GeneralSettingsViewController()
        case .about:   new = AboutSettingsViewController()
        }
        cache[tab] = new
        addChild(new)
        return new
    }
}
