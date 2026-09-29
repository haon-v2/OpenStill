import AppKit
import OpenStillCore

/// Masks, Lightroom style: as many masks as you like, each with its own sliders.
/// The list at the top picks a mask; below are its sliders and its mask tools (brush, gradients, AI selections…).
final class MaskLayersPanel: NSStackView {
    /// "maskLayer:new:brush", "maskLayer:select:<id>", "maskLayer:delete:<id>"…
    var command: ((String) -> Void)?
    /// A layer's sliders, name or visibility changed.
    var changed: ((LocalAdjustment, String, Bool) -> Void)?
    /// The selected layer's mask tools are placed here by the editor panel.
    let maskHolder = NSView()
    private(set) var selected: UUID?
    private var layers: [LocalAdjustment] = []
    private var enabled = false
    private let list = NSStackView(), detail = NSStackView(), empty = NSTextField(wrappingLabelWithString: "")
    private let newMask = NSPopUpButton(frame: .zero, pullsDown: true), actions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let name = NSTextField()
    private var sliders: [(ContinuousSlider, NSTextField, WritableKeyPath<LocalSettings, Double>)] = []
    static let kinds: [(String, String)] = [("Brush", "brush"), ("Linear Gradient", "linear"), ("Radial Gradient", "radial"), ("Select Subject", "ai.subject"),
                                            ("Select Sky", "ai.sky"), ("Select Background", "ai.background"), ("Select People", "ai.people"), ("Object", "object"),
                                            ("Color Range", "colorRange"), ("Luminance Range", "luminanceRange"), ("Depth Range", "ai.depth")]
    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = 8
        newMask.addItem(withTitle: "+ New Mask")
        for (title, kind) in Self.kinds { let item = NSMenuItem(title: title, action: #selector(create(_:)), keyEquivalent: ""); item.target = self; item.representedObject = kind; newMask.menu?.addItem(item) }
        newMask.controlSize = .small; newMask.font = .systemFont(ofSize: 11); newMask.setAccessibilityLabel("Create a new mask")
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 2
        empty.stringValue = "Each mask has its own sliders. Create one, paint or select the area, then adjust it. Add as many as you need."
        empty.font = .systemFont(ofSize: 10); empty.textColor = .secondaryLabelColor
        name.controlSize = .small; name.font = .systemFont(ofSize: 11); name.target = self; name.action = #selector(rename); name.setAccessibilityLabel("Mask name")
        actions.addItem(withTitle: "Mask Actions")
        for (title, verb) in [("Duplicate", "duplicate"), ("Invert", "invert"), ("Show / Hide Overlay", "show"), ("Reset Sliders", "reset"), ("Delete Mask", "delete")] {
            let item = NSMenuItem(title: title, action: #selector(act(_:)), keyEquivalent: ""); item.target = self; item.representedObject = verb; actions.menu?.addItem(item)
        }
        actions.controlSize = .small; actions.font = .systemFont(ofSize: 11); actions.setAccessibilityLabel("Mask actions")
        detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 6
        let top = NSStackView(views: [name, actions]); top.spacing = 6
        detail.addArrangedSubview(top); top.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        for (title, path, range) in LocalSettings.sliders {
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 11); label.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let value = NSTextField(labelWithString: "0"); value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); value.textColor = .secondaryLabelColor
            value.alignment = .right; value.widthAnchor.constraint(equalToConstant: 36).isActive = true
            let slider = ContinuousSlider(range: range); slider.setAccessibilityLabel("Mask " + title)
            slider.changed = { [weak self] v, final in self?.slide(path, title: title, value: v, final: final); value.stringValue = Self.format(v, range: range) }
            // Double-click a slider's label to reset it, as in Lightroom.
            let reset = NSClickGestureRecognizer(target: self, action: #selector(resetSlider(_:))); reset.numberOfClicksRequired = 2; label.addGestureRecognizer(reset); label.identifier = NSUserInterfaceItemIdentifier(title)
            let row = NSStackView(views: [label, slider, value]); row.spacing = 6
            detail.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
            sliders.append((slider, value, path))
        }
        let maskTitle = NSTextField(labelWithString: "Mask area"); maskTitle.font = .systemFont(ofSize: 11, weight: .semibold); maskTitle.textColor = .secondaryLabelColor
        detail.addArrangedSubview(maskTitle)
        detail.addArrangedSubview(maskHolder); maskHolder.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        for v in [newMask, list, empty, detail] as [NSView] { addArrangedSubview(v); v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    static func format(_ v: Double, range: ClosedRange<Double>) -> String { range.upperBound > 1 ? String(format: "%+.2f", v) : String(format: "%+.0f", v * 100) }
    var selectedLayer: LocalAdjustment? { layers.first { $0.id == selected } }
    func update(_ next: [LocalAdjustment], enabled: Bool) {
        layers = next; self.enabled = enabled
        if let s = selected, !layers.contains(where: { $0.id == s }) { selected = layers.last?.id }
        if selected == nil { selected = layers.last?.id }
        refresh()
    }
    func select(_ id: UUID?) { selected = id; refresh() }
    private func refresh() {
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        for layer in layers {
            let eye = NSButton(image: Appearance.symbol(layer.hidden ? "eye.slash" : "eye", size: 11) ?? NSImage(), target: self, action: #selector(toggleHidden(_:)))
            eye.isBordered = false; eye.identifier = NSUserInterfaceItemIdentifier(layer.id.uuidString); eye.setAccessibilityLabel((layer.hidden ? "Show " : "Hide ") + layer.name)
            let row = NSButton(title: layer.name, target: self, action: #selector(choose(_:)))
            row.identifier = NSUserInterfaceItemIdentifier(layer.id.uuidString); row.alignment = .left; row.bezelStyle = .rounded; row.controlSize = .small
            row.setButtonType(.pushOnPushOff); row.state = layer.id == selected ? .on : .off; row.isEnabled = enabled
            row.setAccessibilityLabel("Mask " + layer.name + (layer.id == selected ? ", selected" : ""))
            let line = NSStackView(views: [eye, row]); line.spacing = 4
            list.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        list.isHidden = layers.isEmpty; empty.isHidden = !layers.isEmpty
        let layer = selectedLayer
        detail.isHidden = layer == nil
        newMask.isEnabled = enabled; actions.isEnabled = enabled; name.isEnabled = enabled
        if let layer {
            if name.currentEditor() == nil { name.stringValue = layer.name }
            for (slider, value, path) in sliders {
                slider.doubleValue = layer.settings[keyPath: path]; slider.isEnabled = enabled
                value.stringValue = Self.format(layer.settings[keyPath: path], range: slider.minValue...slider.maxValue)
            }
        }
    }
    private func edit(_ title: String, final: Bool, _ change: (inout LocalAdjustment) -> Void) {
        guard let i = layers.firstIndex(where: { $0.id == selected }) else { return }
        change(&layers[i]); changed?(layers[i], title, final)
    }
    private func slide(_ path: WritableKeyPath<LocalSettings, Double>, title: String, value: Double, final: Bool) {
        edit((selectedLayer?.name ?? "Mask") + " · " + title, final: final) { $0.settings[keyPath: path] = value }
    }
    @objc private func resetSlider(_ sender: NSClickGestureRecognizer) {
        guard let title = sender.view?.identifier?.rawValue, let path = LocalSettings.sliders.first(where: { $0.0 == title })?.1 else { return }
        slide(path, title: "Reset " + title, value: 0, final: true); refresh()
    }
    @objc private func create(_ sender: NSMenuItem) { if let kind = sender.representedObject as? String { command?("maskLayer:new:" + kind) } }
    @objc private func choose(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        selected = id; refresh(); command?("maskLayer:select:" + id.uuidString)
    }
    @objc private func toggleHidden(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }), let i = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[i].hidden.toggle(); changed?(layers[i], layers[i].name + (layers[i].hidden ? " · Hide" : " · Show"), true); refresh()
    }
    @objc private func rename() {
        let text = name.stringValue.trimmingCharacters(in: .whitespaces); guard !text.isEmpty, text != selectedLayer?.name else { return }
        edit("Rename mask", final: true) { $0.name = text }; refresh()
    }
    @objc private func act(_ sender: NSMenuItem) {
        guard let verb = sender.representedObject as? String, let id = selected else { return }
        if verb == "reset" { edit("Reset mask sliders", final: true) { $0.settings = LocalSettings() }; refresh(); return }
        command?("maskLayer:\(verb):" + id.uuidString)
    }
}
