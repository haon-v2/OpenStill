import AppKit
import OpenStillCore

/// Hue/saturation disc: angle is hue, distance from the center is saturation. Double-click resets.
private final class GradeWheelView: NSView {
    var wheel = GradeWheel() { didSet { needsDisplay = true; updateAccessibility() } }
    var changed: ((GradeWheel, Bool) -> Void)?
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.45 } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.slider)
        heightAnchor.constraint(equalToConstant: 150).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    private var disc: CGRect { let side = min(bounds.width, bounds.height) - 12; return CGRect(x: bounds.midX - side/2, y: bounds.midY - side/2, width: side, height: side) }
    override func draw(_ dirtyRect: NSRect) {
        let r = disc, center = CGPoint(x: r.midX, y: r.midY), radius = r.width/2
        for step in 0..<120 {
            let a0 = Double(step)/120*2*Double.pi, a1 = Double(step+1)/120*2*Double.pi + 0.01
            let wedge = NSBezierPath(); wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: radius, startAngle: a0*180/Double.pi, endAngle: a1*180/Double.pi)
            wedge.close(); NSColor(hue: Double(step)/120, saturation: 0.75, brightness: 0.85, alpha: 1).setFill(); wedge.fill()
        }
        // Fade to neutral at the center, like saturation does.
        let fade = NSGradient(colors: [NSColor(white: 0.5, alpha: 1), NSColor(white: 0.5, alpha: 0)])
        fade?.draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero)
        NSColor.white.withAlphaComponent(0.35).setStroke(); NSBezierPath(ovalIn: r).stroke()
        let angle = wheel.hue*Double.pi/180, distance = wheel.saturation*radius
        let dot = CGPoint(x: center.x + cos(angle)*distance, y: center.y + sin(angle)*distance)
        let marker = NSBezierPath(ovalIn: CGRect(x: dot.x-6, y: dot.y-6, width: 12, height: 12))
        NSColor.white.setStroke(); marker.lineWidth = 2; marker.stroke()
    }
    private func set(_ event: NSEvent, final: Bool) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil), r = disc
        let dx = p.x - r.midX, dy = p.y - r.midY
        var next = wheel
        next.saturation = min(1, hypot(dx, dy)/(r.width/2))
        next.hue = ((atan2(dy, dx)*180/Double.pi) + 360).truncatingRemainder(dividingBy: 360)
        next.saturation = (next.saturation*100).rounded()/100; next.hue = next.hue.rounded()
        wheel = next; changed?(next, final)
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2 { var next = wheel; next.hue = 0; next.saturation = 0; wheel = next; changed?(next, true); return }
        set(event, final: false)
    }
    override func mouseDragged(with event: NSEvent) { set(event, final: false) }
    override func mouseUp(with event: NSEvent) { set(event, final: true) }
    private func updateAccessibility() { setAccessibilityValue("Hue \(Int(wheel.hue)) degrees, saturation \(Int(wheel.saturation*100)) percent") }
}

final class ColorGradingPanel: NSStackView {
    /// Region index (0 shadows, 1 midtones, 2 highlights, 3 global), its new wheel, undo title, final.
    var changed: ((Int, GradeWheel, String, Bool) -> Void)?
    private static let regions = ["Shadows", "Midtones", "Highlights", "Global"]
    private let region = NSSegmentedControl(labels: regions, trackingMode: .selectOne, target: nil, action: nil)
    private let wheelView = GradeWheelView()
    private let luminance = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let readout = NSTextField(labelWithString: "")
    private var grading = ColorGrading()
    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = 8
        region.selectedSegment = 0; region.controlSize = .small; region.target = self; region.action = #selector(regionChanged)
        region.setAccessibilityLabel("Color grading range")
        wheelView.changed = { [weak self] wheel, final in guard let self else { return }; self.send(wheel, "Color grading · hue", final) }
        let lumLabel = NSTextField(labelWithString: "Luminance"); lumLabel.font = .systemFont(ofSize: 11)
        luminance.controlSize = .small; luminance.isContinuous = true; luminance.target = self; luminance.action = #selector(luminanceChanged)
        luminance.setAccessibilityLabel("Luminance")
        readout.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); readout.textColor = .secondaryLabelColor
        for view in [region, wheelView, readout, lumLabel, luminance] {
            view.translatesAutoresizingMaskIntoConstraints = false; addArrangedSubview(view); view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    private var index: Int { max(0, region.selectedSegment) }
    private var paths: [WritableKeyPath<ColorGrading, GradeWheel>] { [\.shadows, \.midtones, \.highlights, \.global] }
    private func send(_ wheel: GradeWheel, _ title: String, _ final: Bool) {
        grading[keyPath: paths[index]] = wheel; refreshReadout()
        changed?(index, wheel, title, final)
    }
    @objc private func regionChanged() { refresh() }
    @objc private func luminanceChanged() {
        var wheel = grading[keyPath: paths[index]]; wheel.luminance = (luminance.doubleValue*100).rounded()/100
        let final = NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .keyDown
        send(wheel, "Color grading · luminance", final)
    }
    private func refreshReadout() {
        let w = grading[keyPath: paths[index]]
        readout.stringValue = "\(Self.regions[index]) · hue \(Int(w.hue))° · saturation \(Int((w.saturation*100).rounded())) · luminance \(w.luminance.formatted(.number.precision(.fractionLength(2))))"
    }
    private func refresh() {
        let w = grading[keyPath: paths[index]]
        wheelView.wheel = w; luminance.doubleValue = w.luminance; refreshReadout()
    }
    func update(_ settings: ColorGrading, enabled: Bool) { grading = settings; refresh(); setEnabled(enabled) }
    func setEnabled(_ enabled: Bool) { region.isEnabled = enabled; luminance.isEnabled = enabled; wheelView.isEnabled = enabled }
}
