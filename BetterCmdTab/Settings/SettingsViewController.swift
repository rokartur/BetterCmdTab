import AppKit

@MainActor
enum SettingsTab: Int, CaseIterable {
    case general
    case switcher
    case appearance
    case experimental
    case about

    var title: String {
        switch self {
        case .general:      return "General"
        case .switcher:     return "Switcher"
        case .appearance:   return "Appearance"
        case .experimental: return "Experimental"
        case .about:        return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general:      return "gearshape.fill"
        case .switcher:     return "rectangle.stack.fill"
        case .appearance:   return "slider.horizontal.3"
        case .experimental: return "flask.fill"
        case .about:        return "info.circle.fill"
        }
    }

    struct IconPalette {
        let start: NSColor
        let end: NSColor
        let symbolColor: NSColor
        let symbolWeight: NSFont.Weight
        /// Size in points of the SF Symbol rendered inside the 20×20 badge.
        let symbolPointSize: CGFloat
    }

    var iconPalette: IconPalette {
        switch self {
        case .general:
            return IconPalette(
                start: NSColor(calibratedRed: 137.0/255, green: 138.0/255, blue: 143.0/255, alpha: 1),
                end: NSColor(calibratedRed: 103.0/255, green: 104.0/255, blue: 110.0/255, alpha: 1),
                symbolColor: .white,
                symbolWeight: .semibold,
                symbolPointSize: 14
            )
        case .switcher:
            // Orange → red gradient — warm and distinct from the gear, teal, and violet.
            return IconPalette(
                start: NSColor(calibratedRed: 255.0/255, green: 159.0/255, blue: 10.0/255, alpha: 1),
                end: NSColor(calibratedRed: 230.0/255, green: 70.0/255, blue: 40.0/255, alpha: 1),
                symbolColor: .white,
                symbolWeight: .semibold,
                symbolPointSize: 12
            )
        case .appearance:
            // Teal → blue gradient — distinct from the neutral gear and violet info.
            return IconPalette(
                start: NSColor(calibratedRed: 52.0/255, green: 199.0/255, blue: 190.0/255, alpha: 1),
                end: NSColor(calibratedRed: 30.0/255, green: 132.0/255, blue: 220.0/255, alpha: 1),
                symbolColor: .white,
                symbolWeight: .semibold,
                symbolPointSize: 12
            )
        case .experimental:
            // Pink → magenta gradient — signals these features are unstable/in-progress.
            return IconPalette(
                start: NSColor(calibratedRed: 255.0/255, green: 95.0/255, blue: 150.0/255, alpha: 1),
                end: NSColor(calibratedRed: 200.0/255, green: 40.0/255, blue: 120.0/255, alpha: 1),
                symbolColor: .white,
                symbolWeight: .semibold,
                symbolPointSize: 11
            )
        case .about:
            // Indigo → violet gradient with a white "i" — distinctive next to
            // the neutral gear icon.
            return IconPalette(
                start: NSColor(calibratedRed: 130.0/255, green: 108.0/255, blue: 255.0/255, alpha: 1),
                end: NSColor(calibratedRed: 76.0/255, green: 42.0/255, blue: 212.0/255, alpha: 1),
                symbolColor: .white,
                symbolWeight: .semibold,
                symbolPointSize: 11
            )
        }
    }
}

@MainActor
final class SettingsViewController: NSSplitViewController {

    private let sidebarVC = SettingsSidebarViewController()
    private let detailVC = SettingsDetailViewController()

    /// Locked sidebar width — matches BetterAudio's preferences sidebar.
    private let sidebarTargetWidth: CGFloat = 213
    /// AppKit source-list compensation so the rendered width matches the target.
    private let sidebarWidthCompensation: CGFloat = 2

    private var effectiveSidebarThickness: CGFloat {
        sidebarTargetWidth + sidebarWidthCompensation
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = effectiveSidebarThickness
        sidebarItem.maximumThickness = effectiveSidebarThickness
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(
            rawValue: NSLayoutConstraint.Priority.required.rawValue - 1
        )

        let contentWidth: CGFloat = 870 - effectiveSidebarThickness
        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.minimumThickness = contentWidth
        detailItem.maximumThickness = contentWidth

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)

        splitView.dividerStyle = .thin
        splitView.setPosition(effectiveSidebarThickness, ofDividerAt: 0)

        sidebarVC.onSelect = { [weak self] tab in
            guard let self else { return }
            self.detailVC.show(tab)
            self.view.window?.title = tab.title
        }
    }

    override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if dividerIndex == 0 {
            return effectiveSidebarThickness
        }
        return proposedPosition
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        sidebarVC.selectInitial()
    }
}
