import AppKit
import OpenStillCore

/// The Studio look, after Compositor: always dark, neutral grays, and the accent as the only color.
/// Selection is translucent white, zones are split by hairlines, and bars keep fixed heights so the photo never jumps.
enum Studio {
    // Surfaces
    static let chrome = NSColor(calibratedWhite: 0.14, alpha: 1)
    static let canvas = NSColor(calibratedWhite: 0.105, alpha: 1)
    static let well = NSColor(calibratedWhite: 0.0, alpha: 0.35)
    static let hairline = NSColor(calibratedWhite: 1, alpha: 0.08)
    // Selection
    static let restFill = NSColor(calibratedWhite: 1, alpha: 0.035)
    static let restStroke = NSColor(calibratedWhite: 1, alpha: 0.08)
    static let hoverFill = NSColor(calibratedWhite: 1, alpha: 0.06)
    static let selectedFill = NSColor(calibratedWhite: 1, alpha: 0.12)
    static let selectedStroke = NSColor(calibratedWhite: 1, alpha: 0.16)
    // Text
    static let text = NSColor(calibratedWhite: 0.92, alpha: 1)
    static let secondary = NSColor(calibratedWhite: 0.62, alpha: 1)
    static let tertiary = NSColor(calibratedWhite: 0.42, alpha: 1)
    static var accent: NSColor { Appearance.accent }

    // Metrics
    static let optionsBarHeight: CGFloat = 42
    static let statusBarHeight: CGFloat = 30
    static let railWidth: CGFloat = 56
    static let railButton: CGFloat = 36
    static let inset: CGFloat = 18
    static let filmstripHeight: CGFloat = 92

    // Type
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let controlFont = NSFont.systemFont(ofSize: 12)
    static let smallFont = NSFont.systemFont(ofSize: 11)
    static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// A label in the bar's type.
    static func label(_ text: String, font: NSFont = controlFont, color: NSColor = secondary) -> NSTextField {
        let l = NSTextField(labelWithString: text); l.font = font; l.textColor = color; l.lineBreakMode = .byTruncatingTail
        return l
    }
    /// A small vertical hairline between groups of controls in a bar.
    static func separator() -> NSView {
        let v = LRFill(hairline); v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([v.widthAnchor.constraint(equalToConstant: 1), v.heightAnchor.constraint(equalToConstant: 18)])
        return v
    }
    /// A capsule push button in the bar style; `primary` fills it with the accent (Done, Apply).
    static func button(_ title: String, primary: Bool = false, _ run: @escaping () -> Void) -> StudioButton {
        StudioButton(title: title, primary: primary, run: run)
    }
    /// Honors motion settings: animations shorten to nothing when Reduce Motion is on.
    static func animate(_ duration: TimeInterval = 0.18, _ changes: @escaping () -> Void) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0 : duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = !reduce
            changes()
        }
    }
}

/// A capsule button drawn in the Studio style: translucent white at rest, accent-filled when primary.
final class StudioButton: NSButton {
    private let run: () -> Void
    private let primary: Bool
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    init(title: String, primary: Bool, run: @escaping () -> Void) {
        self.run = run; self.primary = primary
        super.init(frame: .zero)
        self.title = title; isBordered = false; font = primary ? .systemFont(ofSize: 12, weight: .semibold) : Studio.controlFont
        target = self; action = #selector(clicked)
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: font ?? Studio.controlFont]).width
        return NSSize(width: ceil(w) + 26, height: 26)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    @objc private func clicked() { run() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5), path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        if primary {
            Studio.accent.withAlphaComponent(isEnabled ? (isHighlighted ? 0.8 : 1) : 0.35).setFill(); path.fill()
        } else {
            (isHighlighted ? Studio.selectedFill : hovering && isEnabled ? Studio.hoverFill : Studio.restFill).setFill(); path.fill()
            Studio.restStroke.setStroke(); path.lineWidth = 1; path.stroke()
        }
        let color: NSColor = primary ? .black : (isEnabled ? Studio.text : Studio.tertiary)
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? Studio.controlFont, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
}

/// An icon button for the tool rail and bars: 36 × 36, a soft pill behind the selected one.
final class StudioIconButton: NSButton {
    var selected = false { didSet { needsDisplay = true; setAccessibilityValue(selected ? "selected" : nil) } }
    var side: CGFloat = Studio.railButton
    var symbolSize: CGFloat = 17
    var symbolName: String { didSet { needsDisplay = true } }
    private let run: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    init(symbol: String, label: String, side: CGFloat = Studio.railButton, run: @escaping () -> Void) {
        symbolName = symbol; self.side = side; self.run = run
        super.init(frame: .zero)
        isBordered = false; title = ""; toolTip = label; setAccessibilityLabel(label)
        target = self; action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    @objc private func clicked() { run() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5), pill = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        if selected || isHighlighted {
            Studio.selectedFill.setFill(); pill.fill(); Studio.selectedStroke.setStroke(); pill.lineWidth = 1; pill.stroke()
        } else if hovering && isEnabled {
            Studio.hoverFill.setFill(); pill.fill()
        }
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: symbolSize, weight: .regular).applying(.init(paletteColors: [selected ? Studio.text : Studio.secondary]))) else { return }
        let s = image.size
        image.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.3, respectFlipped: true, hints: nil)
    }
}

/// A row of capsule choices ("Library | Develop", "Heal | Clone"): translucent white marks the chosen one.
final class StudioSegments: NSView {
    var changed: ((Int) -> Void)?
    private(set) var labels: [String]
    var selected: Int { didSet { needsDisplay = true; updateAccessibility() } }
    private let font: NSFont
    private var widths: [CGFloat] = []
    init(_ labels: [String], selected: Int = 0, font: NSFont = .systemFont(ofSize: 12, weight: .medium)) {
        self.labels = labels; self.selected = selected; self.font = font
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true); setAccessibilityRole(.radioGroup)
        measure(); updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func measure() { widths = labels.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 22 }; invalidateIntrinsicContentSize() }
    override var intrinsicContentSize: NSSize { NSSize(width: widths.reduce(0, +) + 4, height: 26) }
    private func updateAccessibility() { setAccessibilityValue(labels.indices.contains(selected) ? labels[selected] : nil) }
    private func frames() -> [NSRect] {
        var x: CGFloat = 2, out: [NSRect] = []
        for w in widths { out.append(NSRect(x: x, y: 2, width: w, height: bounds.height - 4)); x += w }
        return out
    }
    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Studio.restFill.setFill(); outer.fill(); Studio.restStroke.setStroke(); outer.lineWidth = 1; outer.stroke()
        for (i, r) in frames().enumerated() {
            if i == selected {
                let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
                Studio.selectedFill.setFill(); pill.fill(); Studio.selectedStroke.setStroke(); pill.stroke()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: i == selected ? Studio.text : Studio.secondary]
            let size = (labels[i] as NSString).size(withAttributes: attrs)
            (labels[i] as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = frames().firstIndex(where: { $0.contains(p) }), i != selected else { return }
        selected = i; changed?(i)
    }
    override func accessibilityPerformPress() -> Bool { selected = (selected + 1) % max(1, labels.count); changed?(selected); return true }
}

/// A flat bar (options bar, status line, panel tabs) with a hairline on one edge.
class StudioBar: LRFill {
    enum Edge { case top, bottom, none }
    var edge: Edge { didSet { needsDisplay = true } }
    init(edge: Edge) { self.edge = edge; super.init(Studio.chrome) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Studio.hairline.setFill()
        switch edge {
        case .top: NSRect(x: 0, y: isFlipped ? 0 : bounds.height - 1, width: bounds.width, height: 1).fill()
        case .bottom: NSRect(x: 0, y: isFlipped ? bounds.height - 1 : 0, width: bounds.width, height: 1).fill()
        case .none: break
        }
    }
}

/// The 8-point strip on a panel's left edge that resizes it: drag left to widen.
final class PanelResizeEdge: NSView {
    var dragged: ((CGFloat) -> Void)?
    var finished: (() -> Void)?
    private var start: CGFloat = 0
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func draw(_ dirtyRect: NSRect) { Studio.hairline.setFill(); NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill() }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) { dragged?(start - event.locationInWindow.x); start = event.locationInWindow.x }
    override func mouseUp(with event: NSEvent) { finished?() }
}
