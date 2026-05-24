import AppKit

@MainActor
final class SettingsWindowPresenter {

    static let shared = SettingsWindowPresenter()

    private var window: NSWindow?
    private var windowController: NSWindowController?

    private init() {}

    func show() {
        if window == nil {
            createWindow()
        }
        guard let window else { return }

        if !window.isVisible {
            window.center()
        }
        // Activate without switching activation policy — this stays an
        // accessory app (no dock icon) while still receiving key events.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async { [weak window] in
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func createWindow() {
        let vc = SettingsViewController()

        let size = NSSize(width: 870, height: 650)
        let win = SettingsWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = SettingsTab.general.title
        win.titleVisibility = .visible
        win.titlebarAppearsTransparent = false
        win.titlebarSeparatorStyle = .automatic
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        win.collectionBehavior.insert(.fullScreenAuxiliary)
        win.collectionBehavior.insert(.moveToActiveSpace)
        win.hidesOnDeactivate = false
        win.level = .normal

        // Unified toolbar so macOS 26 Liquid Glass applies naturally.
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        win.toolbar = toolbar
        win.toolbarStyle = .unified

        win.contentViewController = vc
        win.setContentSize(size)
        win.contentMinSize = size
        win.contentMaxSize = size
        win.center()

        self.window = win
        self.windowController = NSWindowController(window: win)
    }
}

private final class SettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Handle Cmd+W locally — the app is accessory and has no main menu, so
    /// there's no File > Close menu item routing the shortcut to performClose.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
