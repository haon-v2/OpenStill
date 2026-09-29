import AppKit
import CoreImage
import OpenStillCore

private final class EditorStack: NSStackView { override var isFlipped: Bool { true } }
private final class EditSlider: NSSlider {
    var changed: ((Double, Bool) -> Void)?
    private var tracking = false
    convenience init(range: ClosedRange<Double>, value: Double) {
        self.init(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        target = self; action = #selector(change); isContinuous = true
    }
    @objc private func change() { changed?(doubleValue, !tracking) }
    override func mouseDown(with event: NSEvent) { tracking = true; super.mouseDown(with: event); tracking = false; changed?(doubleValue, true) }
    /// Draws the track as a gradient that shows what the slider does (cool → warm for Temp, green → magenta for Tint).
    func useGradient(_ colors: [NSColor]) {
        let (min, max, value, size) = (minValue, maxValue, doubleValue, controlSize)
        let cell = GradientSliderCell(); cell.colors = colors
        self.cell = cell
        minValue = min; maxValue = max; doubleValue = value; controlSize = size
        target = self; action = #selector(change); isContinuous = true
    }
}

/// A slider cell whose track is a thin gradient across its whole width.
final class GradientSliderCell: NSSliderCell {
    var colors: [NSColor] = [.gray, .white]
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSGradient(colors: colors)?.draw(in: NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2), angle: 0)
    }
}

final class EditorPanel: GlassChrome {
    var editChanged: ((PhotoEdits, String, Bool) -> Void)?
    var command: ((String) -> Void)?
    var chooseHistory: ((Int) -> Void)?
    private let info = InfoPanel()
    private let body = NSView()
    private let summary = NSTextField(wrappingLabelWithString: "Open a photograph to begin")
    private let settings = NSTextField(labelWithString: "—")
    private let message = NSTextField(wrappingLabelWithString: "Edits are saved on this Mac. Originals stay untouched.")
    private let toolsScroll = NSScrollView()
    private let presetScroll = NSScrollView()
    private let historyScroll = NSScrollView()
    private let historyStack = EditorStack()
    private let sectionTitle = NSTextField(labelWithString: "Edit")
    private var sliders: [(EditSlider, NSTextField, WritableKeyPath<PhotoEdits, Double>)] = []
    private var toggles: [(NSButton, WritableKeyPath<PhotoEdits, Bool>)] = []
    private var editButtons: [NSButton] = []
    private var states = PhotoEdits()
    var brushChanged: ((String,Double,Double,Double)->Void)?
    private var maskPanels:[String:MaskPanel] = [:]
    private let mixer = ColorMixerPanel()
    let cropPresets = CropPresetPanel()
    func cropAspect(for size:CGSize) -> Double? { cropPresets.aspect(for:size) }
    func showCrop(selection:CGSize?,photo:CGSize?) { cropPresets.showCrop(selection:selection,photo:photo) }
    private let glow = GlowPanel()
    private let grading = ColorGradingPanel()
    private let sunrays = SunraysPanel()
    private let versions = VersionPanel()
    private let histogram = HistogramPanel()
    private let curves = ToneCurvePanel()
    private let lens = LensPanel()
    private let transformPanel = TransformPanel()
    private let profilePanel = ProfilePanel()
    private var rawSource = false
    private let retouch = RetouchPanel()
    private let pointColor = PointColorPanel()
    /// Mask layers, each with its own sliders; shared by both layouts.
    let maskLayers = MaskLayersPanel()
    /// Mask tools of each mask layer live here while they aren't shown.
    private let layerPanelStore = NSStackView()
    private var layerMaskBorrow: Borrowed?
    private var layerMaskKey: String?
    // Library (Lightroom layout): Quick Develop, Keyword Sets and the Keyword List.
    let quickDevelopPanel = QuickDevelopPanel()
    let keywordSetPanel = KeywordSetPanel()
    let keywordListPanel = KeywordListPanel()
    /// Snapshots: in the History tab (Luminar) or their own left-panel section (Lightroom).
    private let snapshotStack = EditorStack()
    var retouchSettingsChanged:((RetouchSession)->Void)?
    private var lutMask: MaskPanel?
    private let lutBrowser = LUTBrowserView()
    private var hasPhoto = false
    private var busy = false
    // The Studio arrangement (see the extension at the end of this file).
    /// Presets & LUTs, and History · Snapshots · Versions: shown in their own floating panels.
    let presetsColumn = LRPanelColumn(), historyColumn = LRPanelColumn()
    /// Status messages go to the window's status line.
    var statusChanged: ((String, Bool) -> Void)?
    private var lrColumns: [LightroomModule: LRPanelColumn] = [:]
    fileprivate var lrModule: LightroomModule?
    fileprivate var borrowed: [Borrowed] = []
    fileprivate var lrSlots: [LightroomModule: [(NSView, NSView, CGFloat?)]] = [:]
    fileprivate let lrCamera = NSTextField(labelWithString: "")
    fileprivate let lrDrawer = NSStackView()
    fileprivate let treatment = NSSegmentedControl(labels: ["Color", "Black & White"], trackingMode: .selectOne, target: nil, action: nil)
    fileprivate let lrKeywords = NSTextField(wrappingLabelWithString: "")
    fileprivate let maskTarget = NSPopUpButton(frame: .zero, pullsDown: false)
    fileprivate var drawerViews: [String: NSView] = [:]
    fileprivate var maskOrder: [String] = []
    fileprivate var maskBorrow: Borrowed?
    fileprivate let maskSlot = NSView()
    fileprivate let presetSlot = NSView(), historySlot = NSView(), versionSlot = NSView(), snapshotSlot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        settings.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        settings.textColor = .secondaryLabelColor
        settings.lineBreakMode = .byTruncatingTail
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        summary.maximumNumberOfLines = 2
        summary.isSelectable = true
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 3
        message.lineBreakMode = .byTruncatingTail
        sectionTitle.font = .systemFont(ofSize: 19, weight: .semibold)
        for v in [sectionTitle, summary, settings, body, message] { v.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(v) }
        NSLayoutConstraint.activate([
            sectionTitle.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16), sectionTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16), sectionTitle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            summary.topAnchor.constraint(equalTo: sectionTitle.bottomAnchor, constant: 16), summary.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22), summary.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22), summary.heightAnchor.constraint(equalToConstant: 34),
            settings.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 6), settings.leadingAnchor.constraint(equalTo: summary.leadingAnchor), settings.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            body.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), body.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), body.topAnchor.constraint(equalTo: settings.bottomAnchor, constant: 12), body.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -12),
            message.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22), message.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22), message.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16), message.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])
        let tools = installScroll(toolsScroll)
        fullWidth(histogram,in:tools)
        histogram.clicked = { [weak self] in self?.command?("toggleClipping") }
        addTitle("PHOTO & VERSIONS", to: tools)
        fullWidth(versions, in:tools)
        versions.command = { [weak self] in self?.command?($0) }
        // The shared panels wait here, out of sight, until the right panel or a floating panel borrows them.
        cropPresets.changed = { [weak self] in self?.command?("crop") }
        lens.changed = { [weak self] settings,final in guard let self else{return};self.states.lens=settings;self.editChanged?(self.states,"Lens corrections",final) }
        lens.match = { [weak self] in self?.command?("matchLens") }
        transformPanel.command = { [weak self] in self?.command?($0) }
        profilePanel.command = { [weak self] in self?.command?($0) }
        curves.changed = { [weak self] curves,final in
            guard let self else { return }; self.states.curves = curves; self.editChanged?(self.states,"Tone curves",final)
        }
        retouch.command = { [weak self] in self?.command?($0) }
        retouch.settingsChanged = { [weak self] in self?.retouchSettingsChanged?($0) }
        maskLayers.command = { [weak self] in self?.command?($0) }
        maskLayers.changed = { [weak self] layer, title, final in
            guard let self else { return }
            self.states.updateLocalAdjustment(layer.id) { $0 = layer }
            self.editChanged?(self.states, title, final)
        }
        mixer.changed = { [weak self] index,band,title,final in
            guard let self else { return };self.states.ensureAdvanced();self.states.advanced!.colors[index] = band
            self.editChanged?(self.states,title,final)
        }
        pointColor.changed = { [weak self] colors,title,final in guard let self else { return }; self.states.pointColors = colors; self.editChanged?(self.states,title,final) }
        pointColor.command = { [weak self] in self?.command?($0) }
        grading.changed = { [weak self] index, wheel, title, final in
            guard let self else { return }
            var settings = self.states.colorGrading
            switch index { case 0: settings.shadows = wheel; case 1: settings.midtones = wheel; case 2: settings.highlights = wheel; default: settings.global = wheel }
            self.states.colorGrading = settings
            self.editChanged?(self.states, title, final)
        }
        glow.changed = { [weak self] settings, title, final in
            guard let self else { return }
            self.states.glow = settings
            self.editChanged?(self.states, title, final)
        }
        sunrays.changed = { [weak self] settings,title,final in
            guard let self else {return}
            // Controller resolves legacy output-relative coordinates against the source.
            self.states.sunSettings = settings
            self.editChanged?(self.states,title,final)
        }
        sunrays.command = { [weak self] in self?.command?($0) }
        layerPanelStore.orientation = .vertical; layerPanelStore.isHidden = true
        for view in [cropPresets, lens, transformPanel, profilePanel, curves, retouch, maskLayers, layerPanelStore, mixer, pointColor, grading, glow, sunrays] as [NSView] { fullWidth(view, in: tools) }
        // One mask per tool for "Or limit a whole tool"; the names are the ones the renderer and saved edits use.
        for key in ["Layers", "Noise removal", "Detail restoration", "Lens blur", "Develop", "HDR", "Dehaze", "Curves", "Enhance", "Retouch", "Red eye", "Masks", "Erase", "Structure", "Clarity", "Texture", "Color", "Color grading", "Black & white", "Details", "Denoise", "Vignette", "Glow", "Grain", "Sky replacement", "Sunrays"] { let mask = makeMaskPanel(key); mask.done = { [weak self] in self?.command?("finishMask") }; mask.isHidden = true; fullWidth(mask, in: tools) }
        toolsScroll.isHidden = true
        let presets = installScroll(presetScroll)
        addTitle("LUT LIBRARY", to: presets)
        help("12 free looks, ready offline. LUTs add to the look already in your JPEG or S9 camera preview.", to: presets)
        fullWidth(lutBrowser,in:presets)
        lutBrowser.choose = { [weak self] item in self?.command?("libraryLUT:"+item.entry.id) }
        slider("LUT intensity",path:\.lutAmount,range:0...1,in:lutBrowser.controls)
        action("Remove LUT","removeLUT",to:lutBrowser.controls)
        addMaskControls("LUT",to:lutBrowser.controls)
        action("Import .cube LUT…","importLUT",to:presets)
        addTitle("ADJUSTMENT PRESETS",to:presets)
        help("Starting points for your edit. Presets keep your crop and image layers.",to:presets)
        for name in ["Natural", "Warm light", "Cool shadows", "Vivid", "Soft portrait", "Monochrome"] { action(name,"preset:"+name,to:presets) }
        action("Save current as preset…","savePreset",to:presets)
        action("Load preset…","loadPreset",to:presets)
        _ = installScroll(historyScroll, stack: historyStack)
        info.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(info)
        NSLayoutConstraint.activate([info.topAnchor.constraint(equalTo: body.topAnchor), info.bottomAnchor.constraint(equalTo: body.bottomAnchor), info.leadingAnchor.constraint(equalTo: body.leadingAnchor), info.trailingAnchor.constraint(equalTo: body.trailingAnchor)])
        show(nil)
        update(PhotoEdits(), document: nil, enabled: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    private func installScroll(_ scroll: NSScrollView, stack: EditorStack = EditorStack()) -> NSStackView {
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(scroll)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 24, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = stack
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: body.topAnchor), scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor), stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        return stack
    }
    private func fullWidth(_ view: NSView, in stack: NSStackView) { stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -stack.edgeInsets.left-stack.edgeInsets.right).isActive = true }
    private func addTitle(_ text: String, to stack: NSStackView) {
        let label = NSTextField(labelWithString: text.capitalized.replacingOccurrences(of: "Lut", with: "LUT")); label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false
        fullWidth(row, in: stack); row.heightAnchor.constraint(equalToConstant: 32).isActive = true
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 9), label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6)])
    }
    private func help(_ text: String, to stack: NSStackView) { let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; fullWidth(label, in: stack) }
    private func makeMaskPanel(_ key:String, listed:Bool = true) -> MaskPanel {
        let panel = MaskPanel(key:key);maskPanels[key] = panel;if listed { maskOrder.append(key) }
        panel.command = { [weak self] action in self?.command?("mask:"+key+":"+action) }
        panel.maskChanged = { [weak self] mask,title,final in guard let self else{return};self.states.setMask(mask,for:key);self.editChanged?(self.states,key+" · "+title,final) }
        panel.featherChanged = { [weak self,weak panel] value,final in
            guard let self,var root = self.states.advanced?.masks[key],var component=root.component(panel?.selectedID) else {return}
            component.selection.feather=value;root.updateComponent(component);self.states.setMask(root,for:key);self.editChanged?(self.states,key+" mask feather",final)
        }
        panel.brushChanged = { [weak self] radius,softness,strength in self?.brushChanged?(key,radius,softness,strength) }
        return panel
    }
    private func addMaskControls(_ key:String,to stack:NSStackView) {
        let button = NSButton(title:"Mask this LUT…",target:self,action:#selector(toggleLUTMask));button.bezelStyle = .rounded;button.font = .systemFont(ofSize:11);fullWidth(button,in:stack)
        let panel = makeMaskPanel(key);panel.isHidden = true;fullWidth(panel,in:stack);lutMask = panel
        panel.done = { [weak panel] in panel?.isHidden = true }
    }
    /// Shows the selected mask layer's mask tools under its sliders.
    func showLayerMask() {
        let key = maskLayers.selectedLayer?.maskKey
        guard key != layerMaskKey || (key != nil && layerMaskBorrow == nil) else { return }
        if let b = layerMaskBorrow { give(b); layerMaskBorrow = nil }
        layerMaskKey = key
        if let key, let panel = maskPanels[key] { layerMaskBorrow = lend(panel, into: maskLayers.maskHolder, height: nil); panel.resetInteraction() }
    }
    func selectMaskLayer(_ id: UUID?) { maskLayers.select(id); showLayerMask() }
    @objc private func toggleLUTMask() { command?("finishMask");lutMask?.isHidden.toggle();lutMask?.resetInteraction() }
    func selectedMaskComponent(key:String)->UUID? { maskPanels[key]?.selectedID }
    func selectMaskComponent(key:String,id:UUID) { maskPanels[key]?.selectComponent(id) }
    func maskInteraction(key:String,kind:String?,subtract:Bool,visible:Bool) { maskPanels[key]?.interaction(kind:kind,subtract:subtract,visible:visible) }
    func resetMaskInteractions() { for panel in maskPanels.values { panel.resetInteraction() } }
    func resizeBrush(key:String,delta:Double) { maskPanels[key]?.resizeBrush(delta) }

    func refreshLUTs() { lutBrowser.reload() }
    func libraryLUT(id:String) -> LUTItem? { lutBrowser.item(id:id) }
    func importedLUT(filename:String) -> LUTItem? { lutBrowser.imported(filename:filename) }
    func updateHistogram(_ value:PhotoHistogram?, sensor:Double?) { histogram.histogram = value; histogram.sensor = sensor }
    func setClippingOverlay(_ on:Bool) { histogram.clippingShown = on }
    func updateVersions(_ record:PhotoRecord?, raw:Bool) {
        versions.update(record, raw:raw)
        let isRaw = raw && record?.active.sourceMode == .raw
        if isRaw != rawSource { rawSource = isRaw; profilePanel.update(states, raw:isRaw, enabled:hasPhoto && !busy) }
    }
    func setLUTPhoto(_ image:CGImage?,edits:PhotoEdits, source:CIImage? = nil, url:URL? = nil, recipe:RenderRecipe? = nil) { lutBrowser.setPhoto(image,edits:edits, source:source, url:url, recipe:recipe) }
    /// A slider row: the name (drag it sideways to scrub, double-click to reset), the value, and the slider beneath.
    private func slider(_ title: String, path: WritableKeyPath<PhotoEdits, Double>, range: ClosedRange<Double>, in stack: NSStackView) {
        let label = ScrubLabel(title); label.font = .systemFont(ofSize: 12)
        let value = NSTextField(labelWithString: ""); value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); value.textColor = Studio.secondary
        value.alignment = .right
        let heading = NSStackView(views: [label, NSView(), value]); fullWidth(heading, in: stack)
        let slider = EditSlider(range: range, value: states[keyPath: path]); slider.controlSize = .small; slider.setAccessibilityLabel(title)
        if let colors = Self.gradients[title] { slider.useGradient(colors) }
        let reset = PhotoEdits()[keyPath: path]
        let set: (Double, Bool) -> Void = { [weak self, weak slider, weak value] number, final in
            guard let self else { return }
            let clamped = min(range.upperBound, max(range.lowerBound, number))
            self.states[keyPath: path] = clamped; slider?.doubleValue = clamped
            value?.stringValue = Self.number(clamped)
            self.editChanged?(self.states, title, final)
        }
        slider.changed = { [weak self, weak value] number, final in
            guard let self else { return }; self.states[keyPath: path] = number
            value?.stringValue = Self.number(number)
            self.editChanged?(self.states, title, final)
        }
        label.scrubbed = { [weak self, weak slider] dx, final in
            guard self != nil, let slider, slider.isEnabled else { return }
            set(slider.doubleValue + Double(dx) * (range.upperBound - range.lowerBound) / 300, final)
        }
        label.reset = { [weak slider] in guard let slider, slider.isEnabled else { return }; set(reset, true) }
        label.toolTip = "\(title) · drag sideways to change · double-click to reset"
        sliders.append((slider, value, path)); fullWidth(slider, in: stack)
    }
    /// Sliders whose track shows what they do.
    private static let gradients: [String: [NSColor]] = [
        "Temp": [NSColor(srgbRed: 0.22, green: 0.46, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.98, green: 0.82, blue: 0.18, alpha: 1)],
        "Tint": [NSColor(srgbRed: 0.28, green: 0.70, blue: 0.34, alpha: 1), NSColor(srgbRed: 0.70, green: 0.40, blue: 0.64, alpha: 1)],
        "Vibrance": [NSColor(white: 0.55, alpha: 1), NSColor(srgbRed: 0.86, green: 0.38, blue: 0.20, alpha: 1)],
        "Saturation": [NSColor(white: 0.55, alpha: 1), NSColor(srgbRed: 0.86, green: 0.18, blue: 0.20, alpha: 1)],
        "Exposure": [NSColor(white: 0.12, alpha: 1), NSColor(white: 0.95, alpha: 1)],
        "Highlights": [NSColor(white: 0.35, alpha: 1), NSColor(white: 0.95, alpha: 1)],
        "Shadows": [NSColor(white: 0.08, alpha: 1), NSColor(white: 0.6, alpha: 1)],
        "Whites": [NSColor(white: 0.45, alpha: 1), NSColor(white: 1, alpha: 1)],
        "Blacks": [NSColor(white: 0, alpha: 1), NSColor(white: 0.5, alpha: 1)],
    ]
    private func toggle(_ title: String, path: WritableKeyPath<PhotoEdits, Bool>, in stack: NSStackView) {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleEdit(_:)))
        button.tag = toggles.count; button.font = .systemFont(ofSize: 11); toggles.append((button, path)); fullWidth(button, in: stack)
    }
    private func action(_ title: String, _ command: String, to stack: NSStackView) {
        let button = NSButton(title: title, target: self, action: #selector(actionClicked(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(command); button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 11)
        if stack !== historyStack { editButtons.append(button) }
        button.isEnabled = hasPhoto && !busy || command == "setupAI"
        fullWidth(button, in: stack)
    }
    private static func number(_ number: Double) -> String { number.formatted(.number.precision(.fractionLength(abs(number) > 10 ? 0 : 2))) }
    @objc private func actionClicked(_ sender: NSButton) { command?(sender.identifier!.rawValue) }
    @objc private func toggleEdit(_ sender: NSButton) { let path = toggles[sender.tag].1; states[keyPath: path] = sender.state == .on; editChanged?(states, sender.title, true) }
    func show(_ metadata: PhotoMetadata?, rendering: String? = nil) {
        info.show(metadata, rendering: rendering)
        summary.stringValue = metadata.map { "\($0.camera)\n\($0.lens)" } ?? "Open a photograph to begin"
        func compact(_ value:String) -> String { value == "Not recorded" ? "—" : value }
        settings.stringValue = metadata.map { "ISO \(compact($0.iso))  ·  \(compact($0.focalLength))  ·  \(compact($0.aperture))  ·  \(compact($0.shutter))" } ?? "—"
        summary.toolTip = summary.stringValue; settings.toolTip = settings.stringValue
        lrCamera.stringValue = metadata == nil ? "" : settings.stringValue
    }
    func update(_ edits: PhotoEdits, document: EditDocument?, enabled: Bool) {
        states = edits; hasPhoto = enabled
        for layer in edits.localAdjustments where maskPanels[layer.maskKey] == nil {
            let panel = makeMaskPanel(layer.maskKey, listed: false); layerPanelStore.addArrangedSubview(panel)
        }
        lutBrowser.updateSelection(edits);lutBrowser.setEnabled(enabled && !busy)
        for (key,panel) in maskPanels { panel.update(edits.advanced?.masks[key],enabled:enabled && !busy) }
        maskLayers.update(edits.localAdjustments, enabled: enabled && !busy); showLayerMask()
        mixer.update(edits.advanced?.colors,enabled:enabled && !busy)
        cropPresets.setEnabled(enabled && !busy)
        glow.update(edits.glow,enabled:enabled && !busy)
        grading.update(edits.colorGrading,enabled:enabled && !busy)
        sunrays.update(edits.sunSettings,enabled:enabled && !busy)
        curves.update(edits.curves,enabled:enabled && !busy)
        lens.update(edits.lens,available:enabled && !busy)
        transformPanel.update(edits.transform,enabled:enabled && !busy)
        profilePanel.update(edits,raw:rawSource,enabled:enabled && !busy)
        retouch.update(edits.retouch)
        for (slider, label, path) in sliders { slider.doubleValue = edits[keyPath: path]; label.stringValue = Self.number(edits[keyPath: path]); slider.isEnabled = enabled && !busy }
        for (button, path) in toggles { button.state = edits[keyPath: path] ? .on : .off; button.isEnabled = enabled && !busy }
        treatment.selectedSegment = edits.monochrome >= 0.5 ? 1 : 0; treatment.isEnabled = enabled && !busy
        pointColor.update(edits.pointColors, enabled: enabled && !busy)
        for button in editButtons { button.isEnabled = (enabled && !busy) || button.identifier?.rawValue == "setupAI" || (busy && button.identifier?.rawValue == "cancelAI") }
        historyStack.arrangedSubviews.forEach { historyStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rebuildSnapshots(document, enabled: enabled && !busy)
        // In the Lightroom layout the snapshots have their own section on the left.
        if lrModule != .develop { addTitle("SNAPSHOTS", to: historyStack); fullWidth(snapshotStack, in: historyStack) }
        addTitle("EDIT HISTORY", to: historyStack)
        action("Undo", "undo", to: historyStack); action("Redo", "redo", to: historyStack)
        action("Compare with original (\\)", "compare", to: historyStack)
        action("Before / after split (Y)", "compareSplit", to: historyStack)
        action("Reset all edits", "reset", to: historyStack)
        if let document {
            for (index, step) in document.steps.enumerated().reversed() {
                let button = NSButton(title: (index == document.cursor ? "● " : "  ") + step.title, target: self, action: #selector(historyClicked(_:)))
                button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 12); button.tag = index; button.isEnabled = !busy
                fullWidth(button, in: historyStack)
            }
        }
    }
    @objc private func historyClicked(_ sender: NSButton) { chooseHistory?(sender.tag) }
    func status(_ text: String, busy: Bool = false) {
        message.stringValue = text; message.toolTip = text; self.busy = busy
        statusChanged?(text, busy)
        lutBrowser.setEnabled(hasPhoto && !busy)
        for panel in maskPanels.values { panel.setEnabled(hasPhoto && !busy) }
        mixer.setEnabled(hasPhoto && !busy)
        cropPresets.setEnabled(hasPhoto && !busy)
        glow.setEnabled(hasPhoto && !busy)
        grading.setEnabled(hasPhoto && !busy)
        pointColor.setEnabled(hasPhoto && !busy)
        sunrays.setEnabled(hasPhoto && !busy)
        transformPanel.setEnabled(hasPhoto && !busy)
        profilePanel.setEnabled(hasPhoto && !busy)
        for (slider, _, _) in sliders { slider.isEnabled = hasPhoto && !busy }
        for (button, _) in toggles { button.isEnabled = hasPhoto && !busy }
        for button in editButtons { button.isEnabled = button.identifier?.rawValue == "cancelAI" ? busy : ((hasPhoto && !busy) || (!busy && button.identifier?.rawValue == "setupAI")) }
    }
}

/// A view lent to the Lightroom arrangement, and where it goes back to.
fileprivate struct Borrowed {
    let view: NSView
    let stack: NSStackView?
    let index: Int
    let parent: NSView?
    let scroll: NSScrollView?
    let wasHidden: Bool
}

// MARK: - Lightroom Classic arrangement

extension EditorPanel {
    /// Switches between the Luminar arrangement (nil) and Lightroom Classic's Library or Develop panels.
    /// The same controls are used either way; the Lightroom panels borrow them and give them back.
    func setLightroom(_ module: LightroomModule?) {
        let target: LightroomModule? = module.map { $0 == .develop ? .develop : .library }
        guard target != lrModule else { return }
        command?("finishMask")
        showDrawer(nil)
        returnBorrowed()
        for column in lrColumns.values { column.isHidden = true }
        lrModule = target
        for v in [sectionTitle, summary, settings, body, message] as [NSView] { v.isHidden = target != nil }
        flatColor = target == nil ? nil : LRColors.panel
        guard let target else { return }
        let column = lrColumns[target] ?? buildLightroom(target)
        column.isHidden = false
        for (slot, view, height) in lrSlots[target] ?? [] { borrow(view, into: slot, height: height) }
        lutBrowser.setActive(target == .develop)
    }
    /// The Studio tool that's open: Masking shows its masks at the top of the panel; the other tools live in the options bar.
    /// The mask chosen in the Masking list, if any.
    var selectedMaskLayer: UUID? { maskLayers.selected }
    func showToolPanel(_ id: String?) {
        guard lrModule == .develop else { return }
        showDrawer(id == "masking" ? "masking" : nil)
    }
    /// Keywords of the photo selected in the library, for the Keywording panel.
    func showKeywords(_ keywords: [String]?) {
        lrKeywords.stringValue = keywords.map { $0.isEmpty ? "No keywords" : $0.joined(separator: ", ") } ?? "Select a photo to see its keywords."
    }

    private func buildLightroom(_ module: LightroomModule) -> LRPanelColumn {
        let column = LRPanelColumn()
        column.note.isHidden = true
        column.translatesAutoresizingMaskIntoConstraints = false; addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor)])
        lrColumns[module] = column
        var slots: [(NSView, NSView, CGFloat?)] = []
        func section(_ title: String, open: Bool = false, pinned: Bool = false, _ fill: (LRSection) -> Void) {
            let s = LRSection(title, module: module, side: .right, open: open); fill(s); column.add(s, pinned: pinned)
        }
        func slot(_ view: NSView, in s: LRSection, height: CGFloat? = nil) { let holder = NSView(); s.add(holder); slots.append((holder, view, height)) }
        func label(_ text: String, in s: LRSection) {
            let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 11, weight: .medium); l.textColor = LRColors.dim; s.add(l)
        }
        lrCamera.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); lrCamera.textColor = LRColors.dim; lrCamera.alignment = .center
        if module == .library {
            section("Histogram", open: true, pinned: true) { slot(histogram, in: $0) }
            for panel in [quickDevelopPanel, keywordSetPanel, keywordListPanel] as [NSView] {
                (panel as? QuickDevelopPanel)?.command = { [weak self] in self?.command?($0) }
                (panel as? KeywordSetPanel)?.command = { [weak self] in self?.command?($0) }
                (panel as? KeywordListPanel)?.command = { [weak self] in self?.command?($0) }
            }
            section("Quick Develop") { $0.add(quickDevelopPanel) }
            section("Keywording", open: true) { s in
                lrKeywords.font = .systemFont(ofSize: 11); lrKeywords.textColor = LRColors.text; lrKeywords.maximumNumberOfLines = 6
                s.add(lrKeywords); showKeywords(nil)
                s.add(keywordSetPanel)
                s.add(LRButton("Edit Keywords & Metadata…") { [weak self] in self?.command?("lr:metadata") })
            }
            section("Keyword List") { $0.add(keywordListPanel) }
            section("Metadata", open: true) { slot(info, in: $0, height: 460) }
            column.setButtons([("Sync Metadata…", { [weak self] in self?.command?("lr:syncMetadata") }), ("Sync Settings…", { [weak self] in self?.command?("lr:syncSettings") })])
            lrSlots[module] = slots
            return column
        }
        // Develop: the histogram and tool strip stay at the top; the adjustment panels scroll beneath, in Lightroom's order.
        section("Histogram", open: true, pinned: true) { s in slot(histogram, in: s); s.add(lrCamera) }
        lrDrawer.orientation = .vertical; lrDrawer.alignment = .leading; lrDrawer.spacing = 8
        lrDrawer.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 12, right: 14)
        column.top(lrDrawer)
        // Masking's masks sit at the top of the panel while the tool is open; Crop, Remove and Red Eye live in the options bar.
        let masking = LRStack()
        masking.orientation = .vertical; masking.alignment = .leading; masking.spacing = 8; fullWidth(masking, in: lrDrawer); masking.isHidden = true
        drawerViews = ["masking": masking]
        let layersHolder = NSView(); fullWidth(layersHolder, in: masking); slots.append((layersHolder, maskLayers, nil))
        let divider = NSBox(); divider.boxType = .separator; fullWidth(divider, in: masking)
        let target = NSTextField(labelWithString: "Or limit a whole tool:"); target.font = .systemFont(ofSize: 11); target.textColor = Studio.secondary
        maskTarget.removeAllItems(); maskTarget.addItems(withTitles: maskOrder); maskTarget.controlSize = .small; maskTarget.font = .systemFont(ofSize: 11)
        maskTarget.target = self; maskTarget.action = #selector(maskTargetChanged); maskTarget.setAccessibilityLabel("Adjustment the mask limits")
        if let develop = maskOrder.firstIndex(of: "Develop") { maskTarget.selectItem(at: develop) }
        let targetRow = NSStackView(views: [target, maskTarget]); targetRow.spacing = 6; fullWidth(targetRow, in: masking)
        help("A tool mask limits that whole tool (for example Glow or a LUT) to an area.", to: masking)
        fullWidth(maskSlot, in: masking)

        // Lightroom's order: Basic (profile first), Tone Curve, HSL / Color, B&W Mix, Color Grading, Detail, Geometry, Effects, Calibration.
        // Only Basic starts open; the others remember whether you left them open.
        section("Basic", open: true) { s in
            label("Profile", in: s); slot(profilePanel, in: s)
            slider("Profile amount", path: \.profileAmount, range: 0...2, in: s.body)
            treatment.target = self; treatment.action = #selector(treatmentChanged); treatment.controlSize = .small; treatment.setAccessibilityLabel("Treatment")
            let row = NSStackView(views: [labelView("Treatment"), treatment]); row.spacing = 8; s.add(row)
            label("White Balance", in: s)
            action("WB eyedropper", "whiteBalance", to: s.body); action("As Shot", "resetWhiteBalance", to: s.body)
            slider("Temp", path: \.temperature, range: 2500...10000, in: s.body)
            slider("Tint", path: \.tint, range: -100...100, in: s.body)
            label("Tone", in: s); action("Auto", "autoTone", to: s.body)
            slider("Exposure", path: \.exposure, range: -4...4, in: s.body)
            slider("Contrast", path: \.contrast, range: 0.5...1.5, in: s.body)
            slider("Highlights", path: \.highlightsAmount, range: -1...1, in: s.body)
            slider("Shadows", path: \.shadowsAmount, range: -1...1, in: s.body)
            slider("Whites", path: \.whites, range: -1...1, in: s.body)
            slider("Blacks", path: \.blacks, range: -1...1, in: s.body)
            label("Presence", in: s)
            slider("Texture", path: \.texture, range: -1...1, in: s.body)
            slider("Clarity", path: \.clarity, range: -1...1, in: s.body)
            slider("Dehaze", path: \.dehaze, range: -1...1, in: s.body)
            slider("Vibrance", path: \.vibrance, range: -1...1, in: s.body)
            slider("Saturation", path: \.saturation, range: 0...2, in: s.body)
            label("HDR", in: s)
            toggle("Edit in HDR", path: \.hdrEnabled, in: s.body)
            slider("HDR headroom (stops)", path: \.hdrHeadroom, range: 0.5...4, in: s.body)
        }
        section("Tone Curve") { s in slot(curves, in: s); action("Targeted adjustment (drag on photo)", "tat:curve", to: s.body) }
        section("HSL / Color") { s in
            slot(mixer, in: s)
            label("Targeted Adjustment", in: s); addTargetedColorActions(to: s.body)
            label("Point Color", in: s); slot(pointColor, in: s)
        }
        section("B&W Mix") { s in addGrayMix(to: s.body); help("Used when Treatment is Black & White.", to: s.body) }
        section("Color Grading") { s in
            slot(grading, in: s)
            slider("Blending", path: \.gradeBlending, range: 0...1, in: s.body)
            slider("Balance", path: \.gradeBalance, range: -1...1, in: s.body)
        }
        // Image quality: sharpening, noise, chromatic aberration and fringes, and the AI enhancements.
        section("Detail") { s in
            label("Sharpening", in: s); slider("Amount", path: \.sharpness, range: 0...2, in: s.body); addSharpeningDetail(to: s.body)
            label("Noise Reduction", in: s); slider("Luminance", path: \.denoise, range: 0...1, in: s.body); addNoiseDetail(to: s.body)
            action("Denoise with AI…", "ai:denoise", to: s.body); action("Denoise RAW data (keeps edits)", "ai:rawdenoise", to: s.body)
            label("Chromatic Aberration", in: s)
            action("Remove Chromatic Aberration", "autoCA", to: s.body); action("Turn off chromatic aberration removal", "autoCA:off", to: s.body)
            label("Defringe", in: s)
            slider("Purple amount", path: \.defringePurple, range: 0...1, in: s.body)
            slider("Purple hue from (°)", path: \.defringePurpleLow, range: 180...360, in: s.body)
            slider("Purple hue to (°)", path: \.defringePurpleHigh, range: 180...360, in: s.body)
            slider("Green amount", path: \.defringeGreen, range: 0...1, in: s.body)
            slider("Green hue from (°)", path: \.defringeGreenLow, range: 30...200, in: s.body)
            slider("Green hue to (°)", path: \.defringeGreenHigh, range: 30...200, in: s.body)
            label("Enhance", in: s); action("Restore detail (AI)", "ai:detail", to: s.body); action("Super Resolution 2×", "ai:upscale", to: s.body)
        }
        // Geometry: everything that changes the frame — crop and straighten, the lens profile and perspective.
        section("Geometry") { s in
            label("Crop & Straighten", in: s)
            s.add(LRButton("Crop & Straighten… (R)") { [weak self] in self?.command?("studio:tool:crop") })
            slider("Angle", path: \.straighten, range: -20...20, in: s.body)
            label("Lens Corrections", in: s); slot(lens, in: s)
            label("Transform", in: s); slot(transformPanel, in: s)
            slider("Vertical", path: \.transformVertical, range: -1...1, in: s.body)
            slider("Horizontal", path: \.transformHorizontal, range: -1...1, in: s.body)
            slider("Rotate", path: \.transformRotate, range: -15...15, in: s.body)
            slider("Aspect", path: \.transformAspect, range: -1...1, in: s.body)
            slider("Scale", path: \.transformScale, range: 0.5...1.5, in: s.body)
            slider("Offset X", path: \.transformOffsetX, range: -1...1, in: s.body)
            slider("Offset Y", path: \.transformOffsetY, range: -1...1, in: s.body)
            toggle("Constrain Crop", path: \.transformConstrain, in: s.body)
            action("Reset transform", "resetTransform", to: s.body)
        }
        section("Effects") { s in
            label("Post-Crop Vignetting", in: s); slider("Amount", path: \.vignette, range: -1...1, in: s.body)
            label("Grain", in: s)
            slider("Amount", path: \.grainAmount, range: 0...1, in: s.body)
            slider("Size", path: \.grainSize, range: 0...1, in: s.body)
            slider("Roughness", path: \.grainRoughness, range: 0...1, in: s.body)
            label("Lens Blur", in: s)
            action("Use the photo’s depth data", "lensBlur:camera", to: s.body)
            action("Estimate depth (on-device AI)", "lensBlur:ai", to: s.body)
            action("Keep the subject sharp", "lensBlur:subject", to: s.body)
            slider("Blur Amount", path: \.lensBlurAmount, range: 0...1, in: s.body)
            slider("Focus distance", path: \.lensBlurFocus, range: 0...1, in: s.body)
            slider("Focus range", path: \.lensBlurRange, range: 0...1, in: s.body)
            toggle("Blur the foreground too", path: \.lensBlurForeground, in: s.body)
            action("Remove lens blur", "lensBlur:remove", to: s.body)
            label("Glow", in: s); slot(glow, in: s)
            label("Sunrays", in: s); slot(sunrays, in: s)
            label("Structure", in: s)
            slider("Structure", path: \.structure, range: 0...1, in: s.body); toggle("Auto light & color", path: \.autoEnhance, in: s.body)
        }
        section("Calibration") { s in
            slider("Shadows Tint", path: \.calibrationShadowsTint, range: -1...1, in: s.body)
            label("Red Primary", in: s)
            slider("Hue", path: \.calibrationRedHue, range: -1...1, in: s.body); slider("Saturation", path: \.calibrationRedSaturation, range: -1...1, in: s.body)
            label("Green Primary", in: s)
            slider("Hue", path: \.calibrationGreenHue, range: -1...1, in: s.body); slider("Saturation", path: \.calibrationGreenSaturation, range: -1...1, in: s.body)
            label("Blue Primary", in: s)
            slider("Hue", path: \.calibrationBlueHue, range: -1...1, in: s.body); slider("Saturation", path: \.calibrationBlueSaturation, range: -1...1, in: s.body)
        }
        // OpenStill's own tools, after Lightroom's panels.
        section("Sky Replacement") { s in action("Choose sky & replace…", "ai:sky", to: s.body) }
        section("Layers") { s in
            slider("Edit strength", path: \.opacity, range: 0...1, in: s.body)
            action("Add image layer…", "addLayer", to: s.body)
            slider("Layer opacity", path: \.overlayOpacity, range: 0...1, in: s.body)
            action("Normal blend", "blendNormal", to: s.body); action("Screen blend", "blendScreen", to: s.body); action("Multiply blend", "blendMultiply", to: s.body)
            action("Remove image layer", "removeLayer", to: s.body)
        }
        section("On-Device AI") { s in
            help("Optional AI for sky and subject masks, object removal, noise reduction and depth. It downloads about 450 MB once and runs only on this Mac; nothing is uploaded.", to: s.body)
            action("Set up on-device AI…", "setupAI", to: s.body); action("Cancel AI processing", "cancelAI", to: s.body)
        }
        column.setButtons([("Previous", { [weak self] in self?.command?("previousSettings") }), ("Reset", { [weak self] in self?.command?("reset") })])
        lrSlots[module] = slots
        buildLeftDevelop()
        status(message.stringValue, busy: busy)
        return column
    }
    /// The floating panels' contents: Presets & LUTs; and History, Snapshots and Versions with Copy… / Paste.
    private func buildLeftDevelop() {
        for column in [presetsColumn, historyColumn] { column.note.isHidden = true }
        let presets = LRSection("Presets", module: .develop, side: .left, open: true)
        presets.add(presetSlot); presetsColumn.add(presets)
        let history = LRSection("History", module: .develop, side: .left, open: true)
        history.add(historySlot); historyColumn.add(history)
        let snapshots = LRSection("Snapshots", module: .develop, side: .left, open: true)
        snapshots.add(snapshotSlot); historyColumn.add(snapshots)
        let versionsSection = LRSection("Versions", module: .develop, side: .left, open: false)
        versionsSection.add(versionSlot); historyColumn.add(versionsSection)
        historyColumn.setButtons([("Copy Settings…", { [weak self] in self?.command?("lr:copy") }), ("Paste Settings", { [weak self] in self?.command?("lr:paste") })])
        if let presetsDoc = presetScroll.documentView, let historyDoc = historyScroll.documentView {
            lrSlots[.develop, default: []] += [(presetSlot, presetsDoc, nil), (snapshotSlot, snapshotStack, nil), (versionSlot, versions, nil), (historySlot, historyDoc, nil)]
        }
    }
    private func labelView(_ text: String) -> NSTextField { let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 11); l.textColor = Studio.secondary; return l }
    @objc private func treatmentChanged() {
        states.monochrome = treatment.selectedSegment == 1 ? 1 : 0
        editChanged?(states, "Treatment: " + (treatment.selectedSegment == 1 ? "Black & White" : "Color"), true)
    }
    private func showDrawer(_ id: String?) {
        for (key, view) in drawerViews { view.isHidden = key != id }
        lrDrawer.isHidden = id == nil
        if id != nil { DispatchQueue.main.async { [weak self] in self?.lrColumns[.develop]?.scrollToTop() } }
        if id == "masking" { borrowMask() } else { returnMask() }
    }
    @objc private func maskTargetChanged() { returnMask(); borrowMask() }
    private func borrowMask() {
        returnMask()
        guard let key = maskTarget.titleOfSelectedItem, let panel = maskPanels[key] else { return }
        maskBorrow = lend(panel, into: maskSlot, height: nil)
        panel.resetInteraction()
    }
    private func returnMask() { if let b = maskBorrow { give(b); maskBorrow = nil } }
    private func borrow(_ view: NSView, into slot: NSView, height: CGFloat?) {
        if let b = lend(view, into: slot, height: height) { borrowed.append(b) }
    }
    /// Moves a view into `slot`, remembering where it came from.
    private func lend(_ view: NSView, into slot: NSView, height: CGFloat?) -> Borrowed? {
        guard let parent = view.superview else { return nil }
        let stack = parent as? NSStackView
        let scroll = (parent as? NSClipView)?.enclosingScrollView
        let b = Borrowed(view: view, stack: stack, index: stack?.arrangedSubviews.firstIndex(of: view) ?? 0, parent: parent, scroll: scroll, wasHidden: view.isHidden)
        if let scroll { scroll.documentView = nil } else { view.removeFromSuperview() }
        view.isHidden = false; view.translatesAutoresizingMaskIntoConstraints = false; slot.addSubview(view)
        slot.translatesAutoresizingMaskIntoConstraints = false
        var pins = [view.leadingAnchor.constraint(equalTo: slot.leadingAnchor), view.trailingAnchor.constraint(equalTo: slot.trailingAnchor), view.topAnchor.constraint(equalTo: slot.topAnchor), view.bottomAnchor.constraint(equalTo: slot.bottomAnchor)]
        if let height { pins.append(slot.heightAnchor.constraint(equalToConstant: height)) }
        NSLayoutConstraint.activate(pins)
        return b
    }
    /// Puts a lent view back where it was.
    private func give(_ b: Borrowed) {
        let slot = b.view.superview
        b.view.removeFromSuperview(); b.view.isHidden = b.wasHidden
        slot?.constraints.filter { $0.firstAttribute == .height && $0.secondItem == nil }.forEach { $0.isActive = false }
        if let scroll = b.scroll {
            b.view.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = b.view
            NSLayoutConstraint.activate([b.view.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), b.view.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), b.view.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        } else if let stack = b.stack {
            stack.insertArrangedSubview(b.view, at: min(b.index, stack.arrangedSubviews.count))
            b.view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -stack.edgeInsets.left - stack.edgeInsets.right).isActive = true
        } else if let parent = b.parent {
            parent.addSubview(b.view)
            NSLayoutConstraint.activate([b.view.leadingAnchor.constraint(equalTo: parent.leadingAnchor), b.view.trailingAnchor.constraint(equalTo: parent.trailingAnchor), b.view.topAnchor.constraint(equalTo: parent.topAnchor), b.view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
        }
    }
    private func returnBorrowed() {
        returnMask()
        for b in borrowed.reversed() { give(b) }
        borrowed = []
    }
}

// MARK: - Develop controls added in M11 (shared by both layouts)

extension EditorPanel {
    fileprivate func addGrayMix(to stack: NSStackView) {
        let bands: [(String, WritableKeyPath<PhotoEdits, Double>)] = [("Red", \.grayMixRed), ("Orange", \.grayMixOrange), ("Yellow", \.grayMixYellow), ("Green", \.grayMixGreen),
                                                                      ("Aqua", \.grayMixAqua), ("Blue", \.grayMixBlue), ("Purple", \.grayMixPurple), ("Magenta", \.grayMixMagenta)]
        for (name, path) in bands { slider(name, path: path, range: -1...1, in: stack) }
        action("Auto mix", "grayMix:auto", to: stack); action("Reset mix", "grayMix:reset", to: stack)
    }
    fileprivate func addSharpeningDetail(to stack: NSStackView) {
        slider("Radius", path: \.sharpenRadius, range: 0.5...3, in: stack)
        slider("Detail", path: \.sharpenDetail, range: 0...1, in: stack)
        slider("Masking", path: \.sharpenMasking, range: 0...1, in: stack)
        help("Hold Option while dragging Masking in Lightroom shows the edge mask; here, Masking 0 sharpens everything and higher values only sharpen edges.", to: stack)
    }
    fileprivate func addNoiseDetail(to stack: NSStackView) {
        slider("Detail", path: \.noiseDetail, range: 0...1, in: stack)
        slider("Contrast", path: \.noiseContrast, range: 0...1, in: stack)
        slider("Color", path: \.colorNoise, range: 0...1, in: stack)
        slider("Color detail", path: \.colorNoiseDetail, range: 0...1, in: stack)
    }
    fileprivate func addTargetedColorActions(to stack: NSStackView) {
        action("Drag on photo: Saturation", "tat:saturation", to: stack)
        action("Drag on photo: Hue", "tat:hue", to: stack)
        action("Drag on photo: Luminance", "tat:luminance", to: stack)
    }
    /// Snapshots of the current version: New snapshot, then one row per snapshot (click to restore; Control-click to rename or delete).
    fileprivate func rebuildSnapshots(_ document: EditDocument?, enabled: Bool) {
        snapshotStack.orientation = .vertical; snapshotStack.alignment = .leading; snapshotStack.spacing = 4
        snapshotStack.arrangedSubviews.forEach { snapshotStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let add = NSButton(title: "New snapshot…", target: self, action: #selector(snapshotCommand(_:)))
        add.identifier = .init("snapshot:add"); add.bezelStyle = .rounded; add.controlSize = .small; add.isEnabled = enabled && document != nil
        snapshotStack.addArrangedSubview(add)
        for snap in (document?.snapshotList ?? []).reversed() {
            let row = NSButton(title: "◆ " + snap.name, target: self, action: #selector(snapshotCommand(_:)))
            row.identifier = .init("snapshot:restore:" + snap.id.uuidString); row.isBordered = false; row.alignment = .left; row.font = .systemFont(ofSize: 12); row.isEnabled = enabled
            row.toolTip = "Click to return to this snapshot · Control-click to rename or delete"
            let menu = NSMenu()
            for (title, verb) in [("Rename…", "rename"), ("Delete", "delete")] {
                let item = NSMenuItem(title: title, action: #selector(snapshotMenu(_:)), keyEquivalent: ""); item.target = self; item.representedObject = "snapshot:\(verb):" + snap.id.uuidString; menu.addItem(item)
            }
            row.menu = menu
            snapshotStack.addArrangedSubview(row)
        }
        if document?.snapshotList.isEmpty ?? true {
            let hint = NSTextField(wrappingLabelWithString: "Save the current edit as a named snapshot to come back to later."); hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
            snapshotStack.addArrangedSubview(hint)
        }
    }
    @objc fileprivate func snapshotCommand(_ sender: NSButton) { if let id = sender.identifier?.rawValue { command?(id) } }
    @objc fileprivate func snapshotMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { command?(id) } }
    /// After a Point Color is picked, show its sliders.
    func selectLastPointColor() { pointColor.selectLast() }
    /// The tone curve channel shown (0 RGB … 3 blue), for the targeted adjustment tool.
    var curveChannel: Int { curves.selectedChannel }
}
