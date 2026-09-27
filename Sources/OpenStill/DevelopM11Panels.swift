import AppKit
import OpenStillCore

/// A slider that reports whether the change is final (mouse released) or live.
final class TrackingSlider: NSSlider {
    var change: ((Double, Bool) -> Void)?
    private var tracking = false
    convenience init(range: ClosedRange<Double>) {
        self.init(value: 0, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        target = self; action = #selector(adjust); isContinuous = true; controlSize = .small
    }
    @objc private func adjust() { change?(doubleValue, !tracking) }
    override func mouseDown(with event: NSEvent) { tracking = true; super.mouseDown(with: event); tracking = false; change?(doubleValue, true) }
}

/// A round swatch of a picked color; the selected one has a ring.
private final class ColorSwatch: NSButton {
    var color = NSColor.gray { didSet { needsDisplay = true } }
    var selectedSwatch = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)
        color.setFill(); NSBezierPath(ovalIn: r).fill()
        (selectedSwatch ? NSColor.white : NSColor.black.withAlphaComponent(0.4)).setStroke()
        let ring = NSBezierPath(ovalIn: r); ring.lineWidth = selectedSwatch ? 2 : 1; ring.stroke()
    }
}

/// Point Color: pick colors from the photo, then shift the hue, saturation and luminance of colors near each one.
final class PointColorPanel: NSStackView {
    var changed: (([PointColor], String, Bool) -> Void)?
    var command: ((String) -> Void)?
    private var colors: [PointColor] = []
    private(set) var selected: Int?
    private let swatches = NSStackView()
    private let pick = NSButton(title: "Pick a color from the photo", target: nil, action: nil)
    private let remove = NSButton(title: "Remove this color", target: nil, action: nil)
    private let empty = NSTextField(wrappingLabelWithString: "Pick up to 8 colors. Each one changes only colors near it.")
    private var sliders: [(TrackingSlider, NSTextField, WritableKeyPath<PointColor, Double>)] = []
    private var enabled = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = 8
        swatches.spacing = 4
        pick.bezelStyle = .rounded; pick.controlSize = .small; pick.image = Appearance.symbol("eyedropper", size: 12); pick.imagePosition = .imageLeading
        pick.target = self; pick.action = #selector(pickColor); pick.setAccessibilityLabel("Pick a Point Color from the photo")
        remove.bezelStyle = .rounded; remove.controlSize = .small; remove.target = self; remove.action = #selector(removeColor)
        empty.font = .systemFont(ofSize: 10); empty.textColor = .secondaryLabelColor
        for v in [swatches, pick, empty] as [NSView] { addArrangedSubview(v) }
        empty.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        for (title, path, range) in [("Hue", \PointColor.hueShift, -1.0...1.0), ("Saturation", \PointColor.saturationShift, -1.0...1.0),
                                     ("Luminance", \PointColor.lightnessShift, -1.0...1.0), ("Range", \PointColor.range, 0.0...1.0)] {
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 11); label.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let value = NSTextField(labelWithString: ""); value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); value.textColor = .secondaryLabelColor
            value.widthAnchor.constraint(equalToConstant: 32).isActive = true
            let slider = TrackingSlider(range: range); slider.setAccessibilityLabel("Point Color " + title)
            slider.change = { [weak self] v, final in
                guard let self, let i = self.selected, self.colors.indices.contains(i) else { return }
                self.colors[i][keyPath: path] = v; value.stringValue = String(format: "%.0f", v * 100)
                self.changed?(self.colors, "Point Color " + title.lowercased(), final)
            }
            let row = NSStackView(views: [label, slider, value]); row.spacing = 6; addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            sliders.append((slider, value, path))
        }
        addArrangedSubview(remove)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ next: [PointColor], enabled: Bool) {
        colors = next; self.enabled = enabled
        if let i = selected, !colors.indices.contains(i) { selected = colors.isEmpty ? nil : colors.count - 1 }
        refresh()
    }
    func setEnabled(_ on: Bool) { enabled = on; refresh() }
    /// After a new color is picked, its sliders show.
    func selectLast() { selected = colors.isEmpty ? nil : colors.count - 1; refresh() }
    @objc private func pickColor() { command?("pointColor:pick") }
    @objc private func choose(_ sender: NSButton) { selected = sender.tag; refresh() }
    @objc private func removeColor() {
        guard let i = selected, colors.indices.contains(i) else { return }
        colors.remove(at: i); selected = colors.isEmpty ? nil : min(i, colors.count - 1)
        refresh(); changed?(colors, "Remove Point Color", true)
    }
    private func refresh() {
        swatches.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, c) in colors.enumerated() {
            let rgb = ColorMixer.rgb(hue: c.hue, saturation: c.saturation, lightness: c.lightness)
            let swatch = ColorSwatch(); swatch.isBordered = false; swatch.title = ""; swatch.tag = i
            swatch.color = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1); swatch.selectedSwatch = i == selected
            swatch.target = self; swatch.action = #selector(choose(_:)); swatch.setAccessibilityLabel("Point Color \(i + 1)")
            swatch.widthAnchor.constraint(equalToConstant: 24).isActive = true; swatch.heightAnchor.constraint(equalToConstant: 24).isActive = true
            swatches.addArrangedSubview(swatch)
        }
        swatches.isHidden = colors.isEmpty; empty.isHidden = !colors.isEmpty
        let current = selected.flatMap { colors.indices.contains($0) ? colors[$0] : nil }
        for (slider, label, path) in sliders {
            slider.superview?.isHidden = current == nil
            slider.doubleValue = current?[keyPath: path] ?? 0; label.stringValue = String(format: "%.0f", slider.doubleValue * 100)
            slider.isEnabled = enabled
        }
        remove.isHidden = current == nil; remove.isEnabled = enabled
        pick.isEnabled = enabled && colors.count < 8
    }
}
