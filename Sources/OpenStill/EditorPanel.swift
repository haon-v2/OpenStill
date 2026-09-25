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
    var sectionChanged: ((Int) -> Void)?
    private var sliders: [(EditSlider, NSTextField, WritableKeyPath<PhotoEdits, Double>)] = []
    private var toggles: [(NSButton, WritableKeyPath<PhotoEdits, Bool>)] = []
    private var editButtons: [NSButton] = []
    private var states = PhotoEdits()
    var brushChanged: ((String,Double,Double,Double)->Void)?
    private var maskPanels:[String:MaskPanel] = [:]
    private var workspaces:[(NSSegmentedControl,NSView,MaskPanel)] = []
    private let mixer = ColorMixerPanel()
    private let cropPresets = CropPresetPanel()
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
    private let retouch = RetouchPanel()
    var retouchSettingsChanged:((RetouchSession)->Void)?
    private var lutMask: MaskPanel?
    private let lutBrowser = LUTBrowserView()
    private var activeTab = 0
    var selectedTab: Int { activeTab }
    private var hasPhoto = false
    private var busy = false
    private var toolBodies: [NSView] = []
    private var headers: [NSButton] = []

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
        addTitle("TOOLS", to: tools)
        tool("Layers", symbol: "square.3.layers.3d", in: tools) { content in
            self.slider("Edit strength", path: \.opacity, range: 0...1, in: content)
            self.action("Add image layer…", "addLayer", to: content)
            self.slider("Layer opacity", path: \.overlayOpacity, range: 0...1, in: content)
            self.action("Normal blend", "blendNormal", to: content)
            self.action("Screen blend", "blendScreen", to: content)
            self.action("Multiply blend", "blendMultiply", to: content)
            self.action("Remove image layer", "removeLayer", to: content)
        }
        tool("Crop & rotate", symbol: "crop.rotate", in: tools) { content in
            self.fullWidth(self.cropPresets,in:content)
            self.cropPresets.changed = { [weak self] in self?.command?("crop") }
            self.action("Draw crop", "crop", to: content)
            self.action("Apply crop", "applyCrop", to: content)
            self.action("Cancel crop", "cancelTool", to: content)
            self.action("Rotate clockwise", "rotate", to: content)
            self.action("Flip horizontally", "flip", to: content)
            self.slider("Straighten", path: \.straighten, range: -20...20, in: content)
            self.action("Auto straighten from lines", "autoStraighten", to: content)
            self.action("AI align horizon", "horizon", to: content)
            self.action("Reset crop & rotation", "resetCrop", to: content)
        }
        tool("Lens corrections",symbol:"camera.filters",in:tools) { content in
            self.fullWidth(self.lens,in:content)
            self.lens.changed = { [weak self] settings,final in guard let self else{return};self.states.lens=settings;self.editChanged?(self.states,"Lens corrections",final) }
            self.lens.match = { [weak self] in self?.command?("matchLens") }
            self.addTitle("DEFRINGE", to: content)
            self.help("Removes purple and green color fringes along high-contrast edges.", to: content)
            self.slider("Purple amount", path: \.defringePurple, range: 0...1, in: content)
            self.slider("Purple hue from (°)", path: \.defringePurpleLow, range: 180...360, in: content)
            self.slider("Purple hue to (°)", path: \.defringePurpleHigh, range: 180...360, in: content)
            self.slider("Green amount", path: \.defringeGreen, range: 0...1, in: content)
            self.slider("Green hue from (°)", path: \.defringeGreenLow, range: 30...200, in: content)
            self.slider("Green hue to (°)", path: \.defringeGreenHigh, range: 30...200, in: content)
        }
        tool("Transform", symbol: "perspective", in: tools) { content in
            self.fullWidth(self.transformPanel, in: content)
            self.transformPanel.command = { [weak self] in self?.command?($0) }
            self.addTitle("MANUAL", to: content)
            self.slider("Vertical", path: \.transformVertical, range: -1...1, in: content)
            self.slider("Horizontal", path: \.transformHorizontal, range: -1...1, in: content)
            self.slider("Rotate (°)", path: \.transformRotate, range: -15...15, in: content)
            self.slider("Aspect", path: \.transformAspect, range: -1...1, in: content)
            self.slider("Scale", path: \.transformScale, range: 0.5...1.5, in: content)
            self.slider("X offset", path: \.transformOffsetX, range: -1...1, in: content)
            self.slider("Y offset", path: \.transformOffsetY, range: -1...1, in: content)
            self.toggle("Constrain crop", path: \.transformConstrain, in: content)
            self.help("Constrain crop enlarges the photo so no empty edges show. Turned off, empty edges export as white in JPEG and transparent in PNG and TIFF.", to: content)
            self.action("Reset transform", "resetTransform", to: content)
        }
        addTitle("IMAGE QUALITY", to: tools)
        tool("Noise removal  AI", symbol: "waveform.path", in: tools) { content in
            self.help("Local SCUNet denoising. Full-resolution photos can take several minutes.", to: content)
            self.action("Remove noise", "ai:denoise", to: content)
        }
        tool("Detail restoration  AI", symbol: "viewfinder", in: tools) { content in
            self.help("Restore detail with Real-ESRGAN while keeping the original dimensions. Review fine textures at 100%.", to: content)
            self.action("Restore detail", "ai:detail", to: content)
        }
        addTitle("ESSENTIALS", to: tools)
        tool("Develop", symbol: "sun.max", in: tools, expanded: false) { content in
            self.action("Auto", "autoTone", to:content)
            self.action("White balance eyedropper", "whiteBalance", to:content)
            self.action("Reset white balance", "resetWhiteBalance", to:content)
            self.slider("Exposure", path: \.exposure, range: -4...4, in: content)
            self.slider("Contrast", path: \.contrast, range: 0.5...1.5, in: content)
            self.slider("Highlights", path: \.highlights, range: 0...1, in: content)
            self.slider("Shadows", path: \.shadows, range: 0...1, in: content)
            self.slider("Whites", path: \.whites, range: -1...1, in: content)
            self.slider("Blacks", path: \.blacks, range: -1...1, in: content)
            self.help("Whites and Blacks are shared with the Black & white tool and use its mask.", to: content)
            self.slider("Temperature", path: \.temperature, range: 2500...10000, in: content)
            self.slider("Tint", path: \.tint, range: -100...100, in: content)
        }
        tool("Dehaze", symbol: "aqi.medium", in: tools) { content in
            self.slider("Dehaze", path: \.dehaze, range: -1...1, in: content)
            self.help("Positive removes atmospheric haze; negative adds it.", to: content)
        }
        tool("Curves", symbol:"point.topleft.down.curvedto.point.bottomright.up", in:tools) { content in
            self.fullWidth(self.curves,in:content)
            self.curves.changed = { [weak self] curves,final in
                guard let self else { return }; self.states.curves = curves; self.editChanged?(self.states,"Tone curves",final)
            }
        }
        tool("Enhance", symbol: "wand.and.rays", in: tools) { content in
            self.toggle("Auto light & color", path: \.autoEnhance, in: content)
            self.help("Analyzes the photograph for automatic tonal and color adjustments.", to: content)
        }
        tool("Retouch",symbol:"bandage",in:tools) { content in
            self.fullWidth(self.retouch,in:content)
            self.retouch.command = { [weak self] in self?.command?($0) }
            self.retouch.settingsChanged = { [weak self] in self?.retouchSettingsChanged?($0) }
        }
        tool("Erase  AI", symbol: "eraser", in: tools) { content in
            self.help("Choose Masking to select an area, then return here to remove it. AI fills it using the surrounding photograph.", to: content)
            self.action("Remove selected area", "ai:erase", to: content)
        }
        tool("Structure", symbol: "circle.hexagongrid", in: tools) { self.slider("Structure", path: \.structure, range: 0...1, in: $0) }
        tool("Clarity", symbol: "circle.lefthalf.filled", in: tools) { content in
            self.slider("Clarity", path: \.clarity, range: -1...1, in: content)
            self.help("Midtone contrast over broad areas. Negative softens.", to: content)
        }
        tool("Texture", symbol: "square.grid.3x3.middle.filled", in: tools) { content in
            self.slider("Texture", path: \.texture, range: -1...1, in: content)
            self.help("Medium-sized detail such as skin, bark or fabric. Negative smooths it.", to: content)
        }
        tool("Color", symbol: "paintpalette", in: tools) {
            self.slider("Saturation", path: \.saturation, range: 0...2, in: $0)
            self.slider("Vibrance", path: \.vibrance, range: -1...1, in: $0)
            self.addTitle("COLOR MIXER",to:$0)
            self.fullWidth(self.mixer,in:$0)
            self.mixer.changed = { [weak self] index,band,title,final in
                guard let self else { return };self.states.ensureAdvanced();self.states.advanced!.colors[index] = band
                self.editChanged?(self.states,title,final)
            }
        }
        tool("Color grading", symbol: "circle.circle", in: tools) { content in
            self.fullWidth(self.grading, in: content)
            self.grading.changed = { [weak self] index, wheel, title, final in
                guard let self else { return }
                var settings = self.states.colorGrading
                switch index { case 0: settings.shadows = wheel; case 1: settings.midtones = wheel; case 2: settings.highlights = wheel; default: settings.global = wheel }
                self.states.colorGrading = settings
                self.editChanged?(self.states, title, final)
            }
            self.slider("Blending", path: \.gradeBlending, range: 0...1, in: content)
            self.slider("Balance", path: \.gradeBalance, range: -1...1, in: content)
            self.help("Drag in a wheel to tint that tonal range. Double-click a wheel to reset it.", to: content)
        }
        tool("Black & white", symbol: "circle", in: tools) {
            self.slider("Monochrome strength", path: \.monochrome, range: 0...1, in: $0)
            self.slider("Blacks", path: \.blacks, range: -1...1, in: $0)
            self.slider("Whites", path: \.whites, range: -1...1, in: $0)
        }
        tool("Details", symbol: "square.dotted", in: tools) { self.slider("Sharpen", path: \.sharpness, range: 0...2, in: $0) }
        tool("Denoise", symbol: "square.grid.3x3", in: tools) { self.slider("Noise reduction", path: \.denoise, range: 0...1, in: $0) }
        tool("Vignette", symbol: "circle.square", in: tools) { self.slider("Black − / White +", path: \.vignette, range: -1...1, in: $0) }
        addTitle("CREATIVE", to: tools)
        tool("Glow", symbol: "sun.haze", in: tools) { content in
            self.fullWidth(self.glow, in: content)
            self.glow.changed = { [weak self] settings, title, final in
                guard let self else { return }
                self.states.glow = settings
                self.editChanged?(self.states, title, final)
            }
        }
        tool("Grain", symbol: "circle.dotted", in: tools) { content in
            self.slider("Amount", path: \.grainAmount, range: 0...1, in: content)
            self.slider("Size", path: \.grainSize, range: 0...1, in: content)
            self.slider("Roughness", path: \.grainRoughness, range: 0...1, in: content)
        }
        addTitle("LANDSCAPE", to: tools)
        tool("Sky replacement  AI", symbol: "cloud", in: tools) { content in
            self.help("Choose your own sky photograph. Local AI finds the sky boundary and blends it into the current photo.", to: content)
            self.action("Choose sky & replace…", "ai:sky", to: content)
        }
        tool("Sunrays", symbol: "sun.max", in: tools) { content in
            self.fullWidth(self.sunrays, in:content)
            self.sunrays.changed = { [weak self] settings,title,final in
                guard let self else {return}
                // Controller resolves legacy output-relative coordinates against the source.
                self.states.sunSettings = settings
                self.editChanged?(self.states,title,final)
            }
            self.sunrays.command = { [weak self] in self?.command?($0) }
        }
        addTitle("ON THIS MAC", to: tools)
        action("Set up local AI tools…", "setupAI", to: tools)
        action("Cancel AI processing", "cancelAI", to: tools)
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
        showTab(0)
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
    private func tool(_ title: String, symbol: String, in stack: NSStackView, expanded: Bool = false, content: (NSStackView) -> Void) {
        let header = ToolHeaderButton(title: title.replacingOccurrences(of: "  AI", with: ""), target: self, action: #selector(expandTool(_:)))
        header.ai = title.hasSuffix("  AI"); header.expanded = expanded
        header.isBordered = false; header.alignment = .left; header.font = .systemFont(ofSize: 13)
        header.image = Appearance.symbol(symbol); header.imagePosition = .imageLeading
        header.tag = toolBodies.count; header.heightAnchor.constraint(equalToConstant: 36).isActive = true
        header.setAccessibilityLabel(title + " controls")
        fullWidth(header, in: stack)
        let contentStack = NSStackView(); contentStack.orientation = .vertical; contentStack.alignment = .leading; contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
        fullWidth(contentStack,in:stack)
        if title == "Crop & rotate" || title == "Lens corrections" || title == "Transform" { content(contentStack) }
        else {
            let key = title.replacingOccurrences(of:"  AI",with:"")
            let tabs = NSSegmentedControl(labels:["Adjustments","Masking"],trackingMode:.selectOne,target:self,action:#selector(workspaceChanged(_:)))
            tabs.selectedSegment = 0;tabs.segmentStyle = .rounded;tabs.tag = workspaces.count;tabs.setAccessibilityLabel(key+" workspace");fullWidth(tabs,in:contentStack)
            let adjustments = NSStackView();adjustments.orientation = .vertical;adjustments.alignment = .leading;adjustments.spacing = 12
            fullWidth(adjustments,in:contentStack);content(adjustments)
            let mask = makeMaskPanel(key);fullWidth(mask,in:contentStack);mask.isHidden = true
            mask.done = { [weak self,weak tabs] in guard let tabs else { return };tabs.selectedSegment = 0;self?.workspaceChanged(tabs) }
            workspaces.append((tabs,adjustments,mask))
        }
        contentStack.isHidden = !expanded
        toolBodies.append(contentStack);headers.append(header)
    }
    @objc private func workspaceChanged(_ sender:NSSegmentedControl) {
        command?("finishMask")
        let (_,adjustments,mask) = workspaces[sender.tag]
        adjustments.isHidden = sender.selectedSegment == 1;mask.isHidden = sender.selectedSegment == 0
        mask.resetInteraction()
        if let index = toolBodies.firstIndex(where: { $0 === sender.superview }) { focusTool(headers[index]) }
    }
    private func makeMaskPanel(_ key:String) -> MaskPanel {
        let panel = MaskPanel(key:key);maskPanels[key] = panel
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
    @objc private func toggleLUTMask() { command?("finishMask");lutMask?.isHidden.toggle();lutMask?.resetInteraction() }
    func selectedMaskComponent(key:String)->UUID? { maskPanels[key]?.selectedID }
    func maskInteraction(key:String,kind:String?,subtract:Bool,visible:Bool) { maskPanels[key]?.interaction(kind:kind,subtract:subtract,visible:visible) }
    func resetMaskInteractions() { for panel in maskPanels.values { panel.resetInteraction() } }
    func resizeBrush(key:String,delta:Double) { maskPanels[key]?.resizeBrush(delta) }

    func refreshLUTs() { lutBrowser.reload() }
    func libraryLUT(id:String) -> LUTItem? { lutBrowser.item(id:id) }
    func importedLUT(filename:String) -> LUTItem? { lutBrowser.imported(filename:filename) }
    func updateHistogram(_ value:PhotoHistogram?, sensor:Double?) { histogram.histogram = value; histogram.sensor = sensor }
    func setClippingOverlay(_ on:Bool) { histogram.clippingShown = on }
    func updateVersions(_ record:PhotoRecord?, raw:Bool) { versions.update(record, raw:raw) }
    func setLUTPhoto(_ image:CGImage?,edits:PhotoEdits, source:CIImage? = nil, url:URL? = nil, recipe:RenderRecipe? = nil) { lutBrowser.setPhoto(image,edits:edits, source:source, url:url, recipe:recipe) }
    private func slider(_ title: String, path: WritableKeyPath<PhotoEdits, Double>, range: ClosedRange<Double>, in stack: NSStackView) {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 11)
        let value = NSTextField(labelWithString: ""); value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); value.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [label, NSView(), value]); fullWidth(heading, in: stack)
        let slider = EditSlider(range: range, value: states[keyPath: path]); slider.controlSize = .small; slider.setAccessibilityLabel(title)
        slider.changed = { [weak self, weak value] number, final in
            guard let self else { return }; self.states[keyPath: path] = number
            value?.stringValue = Self.number(number)
            self.editChanged?(self.states, title, final)
        }
        sliders.append((slider, value, path)); fullWidth(slider, in: stack)
    }
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
    @objc private func expandTool(_ sender: NSButton) { command?("finishMask"); let open = toolBodies[sender.tag].isHidden; for body in toolBodies { body.isHidden = true }; toolBodies[sender.tag].isHidden = !open
        for (index, header) in headers.enumerated() { (header as? ToolHeaderButton)?.expanded = index == sender.tag && open }
        for panel in maskPanels.values { panel.resetInteraction() }
        if open { focusTool(sender) }
    }
    private func focusTool(_ header:NSView) {
        DispatchQueue.main.async { [weak self,weak header] in
            guard let self,let header,let document = self.toolsScroll.documentView else { return }
            self.layoutSubtreeIfNeeded()
            let y = header.convert(header.bounds,to:document).minY-8
            let maximum = max(0,document.bounds.height-self.toolsScroll.contentView.bounds.height)
            self.toolsScroll.contentView.scroll(to:NSPoint(x:0,y:min(maximum,max(0,y))))
            self.toolsScroll.reflectScrolledClipView(self.toolsScroll.contentView)
        }
    }
    func showTab(_ index: Int) {
        command?("finishMask")
        activeTab = index
        lutBrowser.setActive(index == 1)
        for (i, view) in [toolsScroll, presetScroll, historyScroll, info].enumerated() { view.isHidden = i != index }
        sectionTitle.stringValue = ["Edit", "Presets", "History", "Info"][index]
        sectionChanged?(index)
    }
    func openTool(_ name: String, masking: Bool = false) {
        showTab(0)
        guard let header = headers.first(where: { $0.title == name }) else { return }
        if toolBodies[header.tag].isHidden { expandTool(header) }
        if masking, let workspace = workspaces.first(where: { $0.0.superview === toolBodies[header.tag] }) {
            workspace.0.selectedSegment = 1
            workspaceChanged(workspace.0)
        }
        focusTool(header)
    }
    func openCurrentMask() {
        if activeTab == 1 { if lutMask?.isHidden == true {toggleLUTMask()}; return }
        let current = headers.enumerated().first { entry in !toolBodies[entry.offset].isHidden && workspaces.contains(where: { $0.0.superview === toolBodies[entry.offset] }) }?.element.title
        openTool(current ?? "Develop", masking: true)
    }
    func show(_ metadata: PhotoMetadata?, rendering: String? = nil) {
        info.show(metadata, rendering: rendering)
        summary.stringValue = metadata.map { "\($0.camera)\n\($0.lens)" } ?? "Open a photograph to begin"
        func compact(_ value:String) -> String { value == "Not recorded" ? "—" : value }
        settings.stringValue = metadata.map { "ISO \(compact($0.iso))  ·  \(compact($0.focalLength))  ·  \(compact($0.aperture))  ·  \(compact($0.shutter))" } ?? "—"
        summary.toolTip = summary.stringValue; settings.toolTip = settings.stringValue
    }
    func update(_ edits: PhotoEdits, document: EditDocument?, enabled: Bool) {
        states = edits; hasPhoto = enabled
        lutBrowser.updateSelection(edits);lutBrowser.setEnabled(enabled && !busy)
        for (key,panel) in maskPanels { panel.update(edits.advanced?.masks[key],enabled:enabled && !busy) }
        mixer.update(edits.advanced?.colors,enabled:enabled && !busy)
        cropPresets.setEnabled(enabled && !busy)
        glow.update(edits.glow,enabled:enabled && !busy)
        grading.update(edits.colorGrading,enabled:enabled && !busy)
        sunrays.update(edits.sunSettings,enabled:enabled && !busy)
        curves.update(edits.curves,enabled:enabled && !busy)
        lens.update(edits.lens,available:enabled && !busy)
        transformPanel.update(edits.transform,enabled:enabled && !busy)
        retouch.update(edits.retouch)
        for (slider, label, path) in sliders { slider.doubleValue = edits[keyPath: path]; label.stringValue = Self.number(edits[keyPath: path]); slider.isEnabled = enabled && !busy }
        for (button, path) in toggles { button.state = edits[keyPath: path] ? .on : .off; button.isEnabled = enabled && !busy }
        for button in editButtons { button.isEnabled = (enabled && !busy) || button.identifier?.rawValue == "setupAI" || (busy && button.identifier?.rawValue == "cancelAI") }
        historyStack.arrangedSubviews.forEach { historyStack.removeArrangedSubview($0); $0.removeFromSuperview() }
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
        lutBrowser.setEnabled(hasPhoto && !busy)
        for panel in maskPanels.values { panel.setEnabled(hasPhoto && !busy) }
        mixer.setEnabled(hasPhoto && !busy)
        cropPresets.setEnabled(hasPhoto && !busy)
        glow.setEnabled(hasPhoto && !busy)
        grading.setEnabled(hasPhoto && !busy)
        sunrays.setEnabled(hasPhoto && !busy)
        transformPanel.setEnabled(hasPhoto && !busy)
        for (slider, _, _) in sliders { slider.isEnabled = hasPhoto && !busy }
        for (button, _) in toggles { button.isEnabled = hasPhoto && !busy }
        for button in editButtons { button.isEnabled = button.identifier?.rawValue == "cancelAI" ? busy : ((hasPhoto && !busy) || (!busy && button.identifier?.rawValue == "setupAI")) }
    }
}
