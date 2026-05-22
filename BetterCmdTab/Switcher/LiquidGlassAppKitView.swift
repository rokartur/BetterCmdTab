import AppKit
import ObjectiveC.runtime
import os

final class LiquidGlassAppKitView: NSView {
    /// Probe ObjC property + setter existence before KVC. Defends against
    /// Apple renaming a private property on NSGlassEffectView between macOS 26
    /// betas — `responds(to:)` catches setter rename, `class_getProperty`
    /// catches @property removal that would otherwise trigger
    /// `setValue:forUndefinedKey:` → NSUndefinedKeyException → SIGABRT.
    private static func canSetProperty(_ object: AnyObject, key: String) -> Bool {
        let setterName = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        guard object.responds(to: Selector(setterName)) else { return false }
        let cls: AnyClass = type(of: object)
        return key.withCString { class_getProperty(cls, $0) != nil }
    }
    var cornerRadius: CGFloat { didSet { applyConfiguration() } }
    var variant: LiquidGlassVariant { didSet { applyConfiguration() } }
    var tintColor: NSColor? { didSet { applyConfiguration() } }
    var scrimState: ScrimState = .off { didSet { applyConfiguration() } }
    var subduedState: SubduedState = .normal { didSet { applyConfiguration() } }
    var glassOpaque: Bool = false { didSet { applyConfiguration() } }
    var disableAccentColor: Bool = true { didSet { applyConfiguration() } }
    var automaticGrouping: Bool = true { didSet { applyConfiguration() } }

    var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let newContent = contentView {
                installContentView(newContent)
            }
        }
    }

    private var backingView: NSView?

    init(
        cornerRadius: CGFloat = 12.0,
        variant: LiquidGlassVariant = .regular,
        tintColor: NSColor? = nil,
        scrimState: ScrimState = .off,
        subduedState: SubduedState = .normal,
        glassOpaque: Bool = false,
        disableAccentColor: Bool = true,
        automaticGrouping: Bool = true
    ) {
        self.cornerRadius = cornerRadius
        self.variant = variant
        self.tintColor = tintColor
        self.scrimState = scrimState
        self.subduedState = subduedState
        self.glassOpaque = glassOpaque
        self.disableAccentColor = disableAccentColor
        self.automaticGrouping = automaticGrouping
        super.init(frame: .zero)
        setupBackingView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @available(macOS 26.0, *)
    private func makeGlassEffectView() -> NSView? {
        return NSGlassEffectView(frame: .zero)
    }

    private func setupBackingView() {
        let backing: NSView
        if #available(macOS 26.0, *), let glass = makeGlassEffectView() {
            backing = glass
            configureGlassView(glass)
            Log.ui.debug("LiquidGlass: NSGlassEffectView active")
        } else {
            let effectView = NSVisualEffectView()
            configureFallbackView(effectView)
            backing = effectView
            Log.ui.debug("LiquidGlass: NSVisualEffectView fallback")
        }

        backing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backing, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor),
            backing.topAnchor.constraint(equalTo: topAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        backingView = backing
    }

    private func configureGlassView(_ glassView: NSView) {
        if Self.canSetProperty(glassView, key: "cornerRadius") {
            glassView.setValue(cornerRadius, forKey: "cornerRadius")
        } else {
            Log.ui.warning("NSGlassEffectView cornerRadius setter missing, skipping")
        }
        if let tintColor {
            if Self.canSetProperty(glassView, key: "tintColor") {
                glassView.setValue(tintColor, forKey: "tintColor")
            } else {
                Log.ui.warning("NSGlassEffectView tintColor setter missing, skipping")
            }
        }
    }

    private func configureFallbackView(_ effectView: NSVisualEffectView) {
        configureFallbackMaterial(effectView)
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true

        if scrimState == .on {
            let scrim = NSView()
            scrim.wantsLayer = true
            scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
            scrim.translatesAutoresizingMaskIntoConstraints = false
            effectView.addSubview(scrim)
            NSLayoutConstraint.activate([
                scrim.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                scrim.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
                scrim.topAnchor.constraint(equalTo: effectView.topAnchor),
                scrim.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            ])
        }
        if subduedState == .subdued {
            effectView.alphaValue = 0.7
        }
        if let tintColor {
            let tint = NSView()
            tint.wantsLayer = true
            tint.layer?.backgroundColor = tintColor.cgColor
            tint.translatesAutoresizingMaskIntoConstraints = false
            effectView.addSubview(tint)
            NSLayoutConstraint.activate([
                tint.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                tint.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
                tint.topAnchor.constraint(equalTo: effectView.topAnchor),
                tint.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            ])
        }
    }

    private func configureFallbackMaterial(_ effectView: NSVisualEffectView) {
        switch variant {
        case .regular: effectView.material = .popover
        case .clear: effectView.material = .hudWindow
        case .dock: effectView.material = .menu
        case .appIcons: effectView.material = .sidebar
        case .widgets: effectView.material = .headerView
        case .text: effectView.material = .contentBackground
        case .avPlayer: effectView.material = .fullScreenUI
        case .faceTime: effectView.material = .fullScreenUI
        case .controlCenter: effectView.material = .menu
        case .notificationCenter: effectView.material = .popover
        case .monogram: effectView.material = .headerView
        case .bubbles: effectView.material = .hudWindow
        case .identity: effectView.material = .contentBackground
        case .focusBorder: effectView.material = .toolTip
        case .focusPlatter: effectView.material = .underPageBackground
        case .keyboard: effectView.material = .menu
        case .sidebar: effectView.material = .sidebar
        case .abuttedSidebar: effectView.material = .sidebar
        case .inspector: effectView.material = .headerView
        case .control: effectView.material = .menu
        case .loupe: effectView.material = .popover
        case .slider: effectView.material = .menu
        case .camera: effectView.material = .fullScreenUI
        case .cartouchePopover: effectView.material = .popover
        }
    }

    private func applyConfiguration() {
        guard let backing = backingView else { return }
        if NSStringFromClass(type(of: backing)).contains("NSGlassEffectView") {
            configureGlassView(backing)
        } else if let effectView = backing as? NSVisualEffectView {
            effectView.layer?.cornerRadius = cornerRadius
            configureFallbackMaterial(effectView)
        }
    }

    private func installContentView(_ view: NSView) {
        guard let backing = backingView else {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            return
        }

        view.translatesAutoresizingMaskIntoConstraints = false

        if NSStringFromClass(type(of: backing)).contains("NSGlassEffectView"),
           Self.canSetProperty(backing, key: "contentView") {
            backing.setValue(view, forKey: "contentView")
        } else {
            backing.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: backing.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: backing.trailingAnchor),
                view.topAnchor.constraint(equalTo: backing.topAnchor),
                view.bottomAnchor.constraint(equalTo: backing.bottomAnchor),
            ])
        }
    }
}
