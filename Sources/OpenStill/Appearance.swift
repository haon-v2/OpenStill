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
    static func workspace() -> NSView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    static func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = window.styleMask.contains(.fullSizeContentView)
        // The whole app is dark (see AppDelegate); secondary windows use the Studio chrome like the main window.
        window.backgroundColor = Studio.chrome
        window.isOpaque = true
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
}

/// A flat panel in the Studio chrome color. Children live inside contentView.
class ChromePanel: NSView {
    let contentView = NSView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.backgroundColor = Studio.chrome.cgColor
        contentView.translatesAutoresizingMaskIntoConstraints = false; addSubview(contentView)
        NSLayoutConstraint.activate([contentView.leadingAnchor.constraint(equalTo: leadingAnchor), contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     contentView.topAnchor.constraint(equalTo: topAnchor), contentView.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in guard let self else { return }; Appearance.applyAccent(in: self.contentView) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        Appearance.applyAccent(in: contentView)
        contentView.needsDisplay = true
    }
}
