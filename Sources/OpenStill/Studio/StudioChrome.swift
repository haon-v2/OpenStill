import AppKit
import OpenStillCore

/// The 56-point rail of tools on the left. Tools sit at the top; view toggles (Before/After, Clipping) at the bottom.
final class ToolRail: StudioBar {
    struct Item { let id: String; let symbol: String; let label: String }
    var choose: ((String) -> Void)?
    /// Which set of buttons is showing (1 Library, 2 Develop), so they're only rebuilt when that changes.
    var mode = 0
    private let top = NSStackView(), bottom = NSStackView()
    private var buttons: [String: StudioIconButton] = [:]
    init() {
        super.init(edge: .none)
        for s in [top, bottom] { s.orientation = .vertical; s.spacing = 10; s.alignment = .centerX; s.translatesAutoresizingMaskIntoConstraints = false; addSubview(s) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor, constant: 16), top.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12), bottom.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottom.topAnchor.constraint(greaterThanOrEqualTo: top.bottomAnchor, constant: 16),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.toolbar); setAccessibilityLabel("Tools")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Studio.hairline.setFill(); NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
    /// Replaces the rail's buttons (Develop's tools, or the Library's views).
    func setItems(top items: [Item], bottom lower: [Item]) {
        for s in [top, bottom] { s.arrangedSubviews.forEach { $0.removeFromSuperview() } }
        buttons = [:]
        func make(_ item: Item) -> StudioIconButton {
            let b = StudioIconButton(symbol: item.symbol, label: item.label) { [weak self] in self?.choose?(item.id) }
            buttons[item.id] = b; return b
        }
        items.forEach { top.addArrangedSubview(make($0)) }
        lower.forEach { bottom.addArrangedSubview(make($0)) }
    }
    /// Highlights the chosen tool and any toggles that are on.
    func show(selected: String?, on: Set<String> = []) {
        for (id, b) in buttons { b.selected = id == selected || on.contains(id) }
    }
    func setEnabled(_ enabled: Bool, for ids: Set<String>) { for id in ids { buttons[id]?.isEnabled = enabled } }
}

/// The 42-point bar above the photo: the current tool's name, its settings, then its actions (Cancel, Done) on the right.
/// It keeps its height whatever the tool, so switching tools never moves the photo.
final class ToolOptionsBar: StudioBar {
    private let title = Studio.label("", font: Studio.titleFont, color: Studio.text)
    private let controls = NSStackView(), actions = NSStackView()
    init() {
        super.init(edge: .bottom)
        for s in [controls, actions] { s.orientation = .horizontal; s.spacing = 12; s.alignment = .centerY; s.translatesAutoresizingMaskIntoConstraints = false }
        actions.spacing = 8
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        controls.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for v in [title, controls, actions] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Studio.inset), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            controls.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 18), controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Studio.inset), actions.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.toolbar); setAccessibilityLabel("Tool options")
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(title text: String, controls items: [NSView], actions buttons: [NSView] = []) {
        title.stringValue = text
        for s in [controls, actions] { s.arrangedSubviews.forEach { $0.removeFromSuperview() } }
        items.forEach { controls.addArrangedSubview($0) }
        buttons.forEach { actions.addArrangedSubview($0) }
    }
}

/// The 30-point line at the bottom: what's open on the left; the current tool's keys, or what's happening, on the right.
/// A busy spinner appears only after 250 ms, so quick work never flashes.
final class StudioStatusBar: StudioBar {
    private let info = Studio.label("", font: Studio.statusFont)
    private let message = Studio.label("", font: Studio.statusFont)
    private let spinner = NSProgressIndicator()
    private var hint = ""
    private static let idle = UUID()
    private var messageToken = StudioStatusBar.idle
    private var busyToken = UUID()
    init() {
        super.init(edge: .top)
        spinner.style = .spinning; spinner.controlSize = .mini; spinner.isDisplayedWhenStopped = false
        message.alignment = .right
        info.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [info, spinner, message] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Studio.inset), info.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Studio.inset), message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.leadingAnchor.constraint(greaterThanOrEqualTo: info.trailingAnchor, constant: 24),
            spinner.trailingAnchor.constraint(equalTo: message.leadingAnchor, constant: -6), spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Status")
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Zoom, size and file on the left.
    func setInfo(_ text: String) { info.stringValue = text; info.toolTip = text }
    /// The keys for the current tool, shown whenever there's no message.
    func setHint(_ text: String) { hint = text; if messageToken == idleToken { message.stringValue = hint; message.textColor = Studio.secondary } }
    private var idleToken: UUID { Self.idle }
    /// A message from the editor ("Edits saved", an AI step…). It stays while busy, otherwise for five seconds.
    func show(_ text: String, busy: Bool) {
        let token = UUID(); messageToken = token
        message.stringValue = text; message.textColor = Studio.text; message.toolTip = text
        setAccessibilityValue(text)
        if busy {
            let b = UUID(); busyToken = b
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in if self?.busyToken == b { self?.spinner.startAnimation(nil) } }
        } else {
            busyToken = UUID(); spinner.stopAnimation(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.messageToken == token else { return }
                self.messageToken = self.idleToken; self.message.stringValue = self.hint; self.message.textColor = Studio.secondary
            }
        }
    }
    func clearMessage() { busyToken = UUID(); spinner.stopAnimation(nil); messageToken = idleToken; message.stringValue = hint; message.textColor = Studio.secondary }
}

/// "Label ——●—— 0.50" for the options bar: drag the label to scrub, double-click it to reset, type in the field, Up/Down steps.
final class StudioValue: NSStackView, NSTextFieldDelegate {
    var changed: ((Double, Bool) -> Void)?
    private let name: ScrubLabel
    private let slider: ContinuousSlider
    private let field = NSTextField()
    private let range: ClosedRange<Double>
    private let resetValue: Double
    private let decimals: Int
    private let unit: String
    var value: Double {
        get { slider.doubleValue }
        set { slider.doubleValue = min(range.upperBound, max(range.lowerBound, newValue)); showValue() }
    }
    init(_ title: String, range: ClosedRange<Double>, value: Double, reset: Double? = nil, decimals: Int = 2, unit: String = "", sliderWidth: CGFloat = 96) {
        self.range = range; resetValue = reset ?? value; self.decimals = decimals; self.unit = unit
        name = ScrubLabel(title); slider = ContinuousSlider(range: range, value: value)
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 6; alignment = .centerY
        slider.controlSize = .small; slider.widthAnchor.constraint(equalToConstant: sliderWidth).isActive = true
        slider.setAccessibilityLabel(title)
        field.font = Studio.statusFont; field.alignment = .right; field.isBordered = false; field.drawsBackground = false
        field.textColor = Studio.text; field.delegate = self; field.target = self; field.action = #selector(typed)
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true; field.setAccessibilityLabel(title + " value")
        slider.changed = { [weak self] v, final in self?.showValue(); self?.changed?(v, final) }
        name.scrubbed = { [weak self] dx, final in
            guard let self else { return }
            let span = self.range.upperBound - self.range.lowerBound
            self.value = self.value + Double(dx) * span / 300
            self.changed?(self.value, final)
        }
        name.reset = { [weak self] in guard let self else { return }; self.value = self.resetValue; self.changed?(self.value, true) }
        for v in [name, slider, field] as [NSView] { addArrangedSubview(v) }
        showValue()
    }
    required init(coder: NSCoder) { fatalError() }
    private func showValue() {
        let v = slider.doubleValue
        field.stringValue = (decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)) + unit
    }
    @objc private func typed() {
        let text = field.stringValue.replacingOccurrences(of: unit, with: "").trimmingCharacters(in: .whitespaces)
        if let v = Double(text) { value = v; changed?(value, true) } else { showValue() }
        window?.makeFirstResponder(nil)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let step = decimals == 0 ? 1.0 : pow(10, -Double(decimals)) * 10
        let shift = NSEvent.modifierFlags.contains(.shift) ? 10.0 : 1.0
        switch selector {
        case #selector(NSResponder.moveUp(_:)): value += step * shift; changed?(value, true); return true
        case #selector(NSResponder.moveDown(_:)): value -= step * shift; changed?(value, true); return true
        case #selector(NSResponder.cancelOperation(_:)): showValue(); window?.makeFirstResponder(nil); return true
        default: return false
        }
    }
}

/// A label you can drag sideways to change its value; double-click resets it.
final class ScrubLabel: NSTextField {
    var scrubbed: ((CGFloat, Bool) -> Void)?
    var reset: (() -> Void)?
    private var last: CGFloat = 0
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text; isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        font = Studio.controlFont; textColor = Studio.secondary
        toolTip = "Drag to change · Double-click to reset"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    private var moved = false
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { reset?(); return }
        last = event.locationInWindow.x; moved = false
    }
    override func mouseDragged(with event: NSEvent) { let x = event.locationInWindow.x; moved = true; scrubbed?(x - last, false); last = x }
    /// Letting go after a drag is one undo step; a plain click changes nothing.
    override func mouseUp(with event: NSEvent) { if moved { scrubbed?(0, true) }; moved = false }
}
