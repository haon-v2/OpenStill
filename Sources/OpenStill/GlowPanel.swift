import AppKit
import OpenStillCore

private final class GlowSlider: NSSlider {
    var changed: ((Double, Bool) -> Void)?
    private var tracking = false
    @objc func change() { changed?(doubleValue, !tracking) }
    override func mouseDown(with event: NSEvent) {
        tracking = true
        super.mouseDown(with: event)
        tracking = false
        changed?(doubleValue, true)
    }
}

final class GlowPanel: NSStackView {
    var changed: ((GlowSettings, String, Bool) -> Void)?
    private var settings = GlowSettings()
    private let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let advanced = NSStackView()
    private let disclosure = NSButton(title: "Advanced", target: nil, action: nil)
    private let reset = NSButton(title: "Reset Glow", target: nil, action: nil)
    private var controls: [(GlowSlider, NSTextField, WritableKeyPath<GlowSettings, Double>)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = 12
        let label = NSTextField(labelWithString: "Type")
        label.font = .systemFont(ofSize: 11)
        add(label, to: self)
        mode.addItems(withTitles: GlowMode.allCases.map(\.title))
        mode.font = .systemFont(ofSize: 11)
        mode.target = self; mode.action = #selector(typeChanged)
        mode.setAccessibilityLabel("Glow type")
        add(mode, to: self)
        slider("Amount", path: \.amount, range: 0...100, in: self)

        disclosure.isBordered = false; disclosure.alignment = .left
        disclosure.font = .systemFont(ofSize: 11, weight: .medium)
        disclosure.image = Appearance.symbol("chevron.right", size: 9)
        disclosure.imagePosition = .imageLeading
        disclosure.target = self; disclosure.action = #selector(toggleAdvanced)
        disclosure.setAccessibilityLabel("Show advanced Glow controls")
        add(disclosure, to: self)
        advanced.orientation = .vertical; advanced.alignment = .leading; advanced.spacing = 12
        add(advanced, to: self); advanced.isHidden = true
        slider("Softness", path: \.softness, range: 0...100, in: advanced)
        slider("Brightness", path: \.brightness, range: -100...100, in: advanced)
        slider("Contrast", path: \.contrast, range: -100...100, in: advanced)
        slider("Warmth", path: \.warmth, range: -100...100, in: advanced)
        reset.bezelStyle = .rounded; reset.font = .systemFont(ofSize: 11)
        reset.target = self; reset.action = #selector(resetGlow)
        add(reset, to: self)
        let hint = NSTextField(wrappingLabelWithString: "Glow blooms around highlights. Soft Focus adds gentle diffusion. Use Masking to place the effect.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        add(hint, to: self)
        update(GlowSettings(), enabled: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func add(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func slider(_ title: String, path: WritableKeyPath<GlowSettings, Double>, range: ClosedRange<Double>, in stack: NSStackView) {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 11)
        let value = NSTextField(labelWithString: "0")
        value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); value.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, NSView(), value])
        add(row, to: stack)
        let slider = GlowSlider(value: settings[keyPath: path], minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        slider.controlSize = .small; slider.isContinuous = true
        slider.target = slider; slider.action = #selector(GlowSlider.change)
        slider.setAccessibilityLabel("Glow " + title)
        if range.lowerBound < 0 {
            slider.numberOfTickMarks = 3; slider.allowsTickMarkValuesOnly = false
            slider.toolTip = "Negative or positive; the center mark is neutral."
        }
        slider.changed = { [weak self, weak value] number, final in
            guard let self else { return }
            self.settings[keyPath: path] = number
            value?.stringValue = Self.display(number)
            self.changed?(self.settings, "Glow · " + title, final)
        }
        controls.append((slider, value, path)); add(slider, to: stack)
    }
    private static func display(_ value: Double) -> String {
        let number = Int(value.rounded())
        return number > 0 ? "\(number)" : (number < 0 ? "−\(-number)" : "0")
    }
    @objc private func typeChanged() {
        guard GlowMode.allCases.indices.contains(mode.indexOfSelectedItem) else { return }
        settings.mode = GlowMode.allCases[mode.indexOfSelectedItem]
        changed?(settings, "Glow · " + settings.mode.title, true)
    }
    @objc private func toggleAdvanced() {
        advanced.isHidden.toggle()
        disclosure.image = Appearance.symbol(advanced.isHidden ? "chevron.right" : "chevron.down", size: 9)
        disclosure.setAccessibilityLabel((advanced.isHidden ? "Show" : "Hide") + " advanced Glow controls")
    }
    @objc private func resetGlow() {
        settings = GlowSettings()
        changed?(settings, "Reset Glow", true)
    }
    func update(_ settings: GlowSettings, enabled: Bool) {
        self.settings = settings.sanitized
        mode.selectItem(at: GlowMode.allCases.firstIndex(of: self.settings.mode) ?? 0)
        for (slider, label, path) in controls {
            slider.doubleValue = self.settings[keyPath: path]
            label.stringValue = Self.display(slider.doubleValue)
        }
        setEnabled(enabled)
    }
    func setEnabled(_ enabled: Bool) {
        mode.isEnabled = enabled; reset.isEnabled = enabled
        for (slider, _, _) in controls { slider.isEnabled = enabled }
    }
}
