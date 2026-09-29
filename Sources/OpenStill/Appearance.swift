import AppKit

/// Shared chrome styling. The image canvas remains opaque and color-neutral.
enum Appearance {
    static func symbol(_ name: String, size: CGFloat = 16, description: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .light).applying(.init(paletteColors: [.labelColor])))
    }
    static let accent = NSColor(name: "OpenStill Green") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.34, green: 0.85, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.48, blue: 0.26, alpha: 1)
    }
    static func glass() -> GlassChrome { GlassChrome() }
    static func workspace() -> NSView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    static func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = window.styleMask.contains(.fullSizeContentView)
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = false
        window.appearance = nil
    }
    /// A secondary window's content: a flat, opaque panel like Lightroom's dialogs (no floating glass).
    static func panel(in window: NSWindow) -> NSView {
        let root = NSView()
        window.contentView = root
        window.isOpaque = true
        return root
    }
    /// Public AppKit tint properties keep native control drawing and accessibility.
    static func applyAccent(in view: NSView) {
        if let slider = view as? NSSlider {
            slider.trackFillColor = accent
            if #available(macOS 26.0, *), slider.minValue < 0, slider.maxValue > 0 { slider.neutralValue = 0 }
        }
        if let segments = view as? NSSegmentedControl { segments.selectedSegmentBezelColor = accent }
        if let button = view as? NSButton {
            // Preserve semantic colors on color wells, histogram channels and mask previews.
            if button.accessibilityRole() == .checkBox { button.bezelColor = accent }
        }
        for child in view.subviews { applyAccent(in: child) }
    }
    static func primary(_ button: NSButton) {
        button.bezelColor = accent
        if #available(macOS 26.0, *) { button.tintProminence = .primary }
    }
    static func line(in view: NSView, edge: NSLayoutConstraint.Attribute) {
        let line = NSBox(); line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(line)
        if edge == .leading {
            NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: view.leadingAnchor), line.topAnchor.constraint(equalTo: view.topAnchor), line.bottomAnchor.constraint(equalTo: view.bottomAnchor), line.widthAnchor.constraint(equalToConstant: 1)])
        } else {
            NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: view.leadingAnchor), line.trailingAnchor.constraint(equalTo: view.trailingAnchor), line.heightAnchor.constraint(equalToConstant: 1), edge == .top ? line.topAnchor.constraint(equalTo: view.topAnchor) : line.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        }
    }
}

/// Native Liquid Glass on macOS 26; a system material on earlier releases.
/// Children live inside contentView, never above an unrelated simulated glass layer.
class GlassChrome: NSView {
    let contentView = NSView()
    private let surface: NSView
    var cornerRadius: CGFloat = 22 {
        didSet {
            if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView { glass.cornerRadius = cornerRadius }
            else { surface.layer?.cornerRadius = cornerRadius }
        }
    }
    /// A solid color instead of glass, for Lightroom Classic's flat panels. Nil restores the glass.
    var flatColor: NSColor? {
        didSet {
            if let flatColor {
                if contentView.superview !== self {
                    if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView { glass.contentView = nil }
                    contentView.removeFromSuperview(); contentView.translatesAutoresizingMaskIntoConstraints = false; addSubview(contentView)
                    NSLayoutConstraint.activate([contentView.leadingAnchor.constraint(equalTo:leadingAnchor), contentView.trailingAnchor.constraint(equalTo:trailingAnchor), contentView.topAnchor.constraint(equalTo:topAnchor), contentView.bottomAnchor.constraint(equalTo:bottomAnchor)])
                }
                surface.isHidden = true; wantsLayer = true; layer?.backgroundColor = flatColor.cgColor
            } else if contentView.superview === self {
                contentView.removeFromSuperview()
                if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
                    contentView.translatesAutoresizingMaskIntoConstraints = true; glass.contentView = contentView
                } else {
                    surface.addSubview(contentView)
                    NSLayoutConstraint.activate([contentView.leadingAnchor.constraint(equalTo:surface.leadingAnchor), contentView.trailingAnchor.constraint(equalTo:surface.trailingAnchor), contentView.topAnchor.constraint(equalTo:surface.topAnchor), contentView.bottomAnchor.constraint(equalTo:surface.bottomAnchor)])
                }
                surface.isHidden = false; layer?.backgroundColor = nil
            }
        }
    }
    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular; glass.cornerRadius = 22
            glass.contentView = contentView
            surface = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .sidebar; material.blendingMode = .behindWindow
            material.state = .followsWindowActiveState
            material.wantsLayer = true; material.layer?.cornerRadius = 22; material.layer?.masksToBounds = true
            material.addSubview(contentView)
            contentView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([contentView.leadingAnchor.constraint(equalTo:material.leadingAnchor), contentView.trailingAnchor.constraint(equalTo:material.trailingAnchor), contentView.topAnchor.constraint(equalTo:material.topAnchor), contentView.bottomAnchor.constraint(equalTo:material.bottomAnchor)])
            surface = material
        }
        super.init(frame: frameRect)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([surface.leadingAnchor.constraint(equalTo:leadingAnchor),surface.trailingAnchor.constraint(equalTo:trailingAnchor),surface.topAnchor.constraint(equalTo:topAnchor),surface.bottomAnchor.constraint(equalTo:bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in guard let self else { return }; Appearance.applyAccent(in:self.contentView) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        Appearance.applyAccent(in:contentView)
        contentView.needsDisplay = true
    }
}
