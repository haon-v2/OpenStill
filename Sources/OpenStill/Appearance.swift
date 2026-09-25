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
    /// Float secondary-window content above a system backdrop, including behind glass.
    static func panel(in window: NSWindow) -> NSView {
        let root = workspace()
        window.contentView = root
        let chrome = glass()
        chrome.cornerRadius = 18
        chrome.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            chrome.topAnchor.constraint(equalTo: root.topAnchor, constant: 8), chrome.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        return chrome.contentView
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

class HoverButton: NSButton {
    private var tracking: NSTrackingArea?
    var hovered = false
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    func drawHighlight(selected: Bool = false) {
        guard selected || hovered && isEnabled || isHighlighted else { return }
        (selected ? Appearance.accent.withAlphaComponent(0.14) : NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.12 : 0.055)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
    }
    func drawSymbol(_ symbol: NSImage?, in rect: NSRect, opacity: CGFloat = 0.8) {
        guard let symbol else { return }
        let scale = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let fitted = NSRect(x: rect.midX-size.width/2, y: rect.midY-size.height/2, width: size.width, height: size.height)
        symbol.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: isEnabled ? opacity : 0.25, respectFlipped: true, hints: nil)
    }
}

final class ToolbarIconButton: HoverButton {
    override func draw(_ dirtyRect: NSRect) {
        drawHighlight(selected: state == .on)
        drawSymbol(image, in: NSRect(x: (bounds.width-17)/2, y: (bounds.height-17)/2, width: 17, height: 17))
    }
}

final class ToolHeaderButton: HoverButton {
    var expanded = false { didSet { needsDisplay = true } }
    var ai = false
    override func draw(_ dirtyRect: NSRect) {
        drawHighlight(selected: expanded)
        drawSymbol(image, in: NSRect(x: 9, y: (bounds.height-17)/2, width: 17, height: 17))
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: NSRect(x: 36, y: (bounds.height-17)/2, width: bounds.width-(ai ? 92 : 62), height: 17), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: expanded ? .medium : .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        if ai {
            ("AI" as NSString).draw(in: NSRect(x: bounds.width-49, y: (bounds.height-13)/2, width: 20, height: 13), withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
        }
        drawSymbol(Appearance.symbol(expanded ? "chevron.down" : "chevron.right", size: 9), in: NSRect(x: bounds.width-18, y: (bounds.height-9)/2, width: 9, height: 9), opacity: hovered || expanded ? 0.8 : 0.35)
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
