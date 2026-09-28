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
    private var activeTab = 0
    var selectedTab: Int { activeTab }
    private var hasPhoto = false
    private var busy = false
    private var toolBodies: [NSView] = []
    private var headers: [NSButton] = []
    // Lightroom Classic arrangement (see the extension at the end of this file).
    /// Presets, Versions and History: the left panel while developing in the Lightroom layout.
    let leftDevelopColumn = LRPanelColumn()
    private var lrColumns: [LightroomModule: LRPanelColumn] = [:]
    fileprivate var lrModule: LightroomModule?
    fileprivate var borrowed: [Borrowed] = []
    fileprivate var lrSlots: [LightroomModule: [(NSView, NSView, CGFloat?)]] = [:]
    fileprivate let lrCamera = NSTextField(labelWithString: "")
    fileprivate let lrStrip = LRToolStrip()
    fileprivate let lrDrawer = NSStackView()
    fileprivate let treatment = NSSegmentedControl(labels: ["Color", "Black & White"], trackingMode: .selectOne, target: nil, action: nil)
    fileprivate let lrKeywords = NSTextField(wrappingLabelWithString: "")
    fileprivate let maskTarget = NSPopUpButton(frame: .zero, pullsDown: false)
    fileprivate var drawerViews: [String: NSView] = [:]
    fileprivate var maskOrder: [String] = []
    fileprivate var maskBorrow: Borrowed?
    fileprivate let maskSlot = NSView()
    fileprivate let presetSlot = NSView(), historySlot = NSView(), versionSlot = NSView(), snapshotSlot = NSView()
    /// The Lightroom tool strip changed tool (crop, remove, masking or none).
    var lightroomTool: ((String?) -> Void)?

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
            self.addTitle("CHROMATIC ABERRATION", to: content)
            self.action("Remove chromatic aberration", "autoCA", to: content)
            self.action("Turn off chromatic aberration removal", "autoCA:off", to: content)
            self.help("Measures the red and blue color edges of this photo and lines them up with green. Works without a lens profile.", to: content)
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
            self.action("Denoise RAW data (keeps edits)", "ai:rawdenoise", to: content)
            self.help("For RAW photos: denoises the decoded sensor data, so every slider and mask stays adjustable. White balance changes afterwards are applied relative to the denoised image; RAW decoding options are fixed.", to: content)
        }
        tool("Detail restoration  AI", symbol: "viewfinder", in: tools) { content in
            self.help("Restore detail with Real-ESRGAN while keeping the original dimensions. Review fine textures at 100%.", to: content)
            self.action("Restore detail", "ai:detail", to: content)
            self.action("Super resolution 2×", "ai:upscale", to: content)
            self.help("Doubles the width and height with Real-ESRGAN as a new version; the current version is kept.", to: content)
        }
        addTitle("ESSENTIALS", to: tools)
        tool("Profile & calibration", symbol: "camera.aperture", in: tools) { content in
            self.fullWidth(self.profilePanel, in: content)
            self.profilePanel.command = { [weak self] in self?.command?($0) }
            self.slider("Profile amount", path: \.profileAmount, range: 0...2, in: content)
            self.addTitle("CALIBRATION", to: content)
            self.slider("Shadows tint", path: \.calibrationShadowsTint, range: -1...1, in: content)
            self.slider("Red primary hue", path: \.calibrationRedHue, range: -1...1, in: content)
            self.slider("Red primary saturation", path: \.calibrationRedSaturation, range: -1...1, in: content)
            self.slider("Green primary hue", path: \.calibrationGreenHue, range: -1...1, in: content)
            self.slider("Green primary saturation", path: \.calibrationGreenSaturation, range: -1...1, in: content)
            self.slider("Blue primary hue", path: \.calibrationBlueHue, range: -1...1, in: content)
            self.slider("Blue primary saturation", path: \.calibrationBlueSaturation, range: -1...1, in: content)
            self.help("Hue moves each primary around the color wheel: red toward yellow, green toward cyan, blue toward magenta. Neutral grays stay neutral.", to: content)
        }
        tool("Lens blur", symbol: "scope", in: tools) { content in
            self.help("Blurs the photo by distance, like a wide-aperture lens. First choose where the depth comes from.", to: content)
            self.action("Use the photo’s depth data", "lensBlur:camera", to: content)
            self.action("Estimate depth (on-device AI)", "lensBlur:ai", to: content)
            self.action("Keep the subject sharp", "lensBlur:subject", to: content)
            self.slider("Blur amount", path: \.lensBlurAmount, range: 0...1, in: content)
            self.slider("Focus distance", path: \.lensBlurFocus, range: 0...1, in: content)
            self.slider("Focus range", path: \.lensBlurRange, range: 0...1, in: content)
            self.toggle("Blur the foreground too", path: \.lensBlurForeground, in: content)
            self.help("Focus distance 1 is the nearest part of the scene, 0 the farthest. Portrait-mode iPhone photos carry depth data; other photos can use the on-device AI estimate or keep the subject sharp.", to: content)
            self.action("Remove lens blur", "lensBlur:remove", to: content)
        }
        tool("Develop", symbol: "sun.max", in: tools, expanded: false) { content in
            self.action("Auto", "autoTone", to:content)
            self.action("White balance eyedropper", "whiteBalance", to:content)
            self.action("Reset white balance", "resetWhiteBalance", to:content)
            self.slider("Exposure", path: \.exposure, range: -4...4, in: content)
            self.slider("Contrast", path: \.contrast, range: 0.5...1.5, in: content)
            self.slider("Highlights", path: \.highlightsAmount, range: -1...1, in: content)
            self.slider("Shadows", path: \.shadowsAmount, range: -1...1, in: content)
            self.slider("Whites", path: \.whites, range: -1...1, in: content)
            self.slider("Blacks", path: \.blacks, range: -1...1, in: content)
            self.help("Whites and Blacks are shared with the Black & white tool and use its mask.", to: content)
            self.slider("Temperature", path: \.temperature, range: 2500...10000, in: content)
            self.slider("Tint", path: \.tint, range: -100...100, in: content)
        }
        tool("HDR", symbol: "sun.max.circle", in: tools) { content in
            self.toggle("Edit in HDR", path: \.hdrEnabled, in: content)
            self.slider("Highlight headroom (stops)", path: \.hdrHeadroom, range: 0.5...4, in: content)
            self.help(HDRBackdrop.available
                ? "Bright highlights go above SDR white on this display. Export as HDR (PQ, HLG or a gain map) to keep them; SDR exports use the SDR rendition."
                : "This display shows SDR, so you see the SDR rendition. HDR exports (PQ, HLG or a gain map) still keep the brighter highlights for HDR screens.", to: content)
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
            self.action("Targeted adjustment: drag up or down on the photo", "tat:curve", to: content)
        }
        tool("Enhance", symbol: "wand.and.rays", in: tools) { content in
            self.toggle("Auto light & color", path: \.autoEnhance, in: content)
            self.help("Analyzes the photograph for automatic tonal and color adjustments.", to: content)
        }
        tool("Retouch",symbol:"bandage",in:tools) { content in
            self.fullWidth(self.retouch,in:content)
            self.retouch.command = { [weak self] in self?.command?($0) }
            self.retouch.settingsChanged = { [weak self] in self?.retouchSettingsChanged?($0) }
            self.addSpotControls(to: content)
        }
        tool("Red eye", symbol: "eye", in: tools) { content in self.addEyeControls(to: content) }
        tool("Masks", symbol: "circle.lefthalf.filled", in: tools) { content in
            self.fullWidth(self.maskLayers, in: content)
            self.maskLayers.command = { [weak self] in self?.command?($0) }
            self.maskLayers.changed = { [weak self] layer, title, final in
                guard let self else { return }
                self.states.updateLocalAdjustment(layer.id) { $0 = layer }
                self.editChanged?(self.states, title, final)
            }
            self.layerPanelStore.orientation = .vertical; self.layerPanelStore.isHidden = true; self.fullWidth(self.layerPanelStore, in: content)
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
            self.addTitle("TARGETED ADJUSTMENT",to:$0)
            self.addTargetedColorActions(to: $0)
            self.addTitle("POINT COLOR",to:$0)
            self.fullWidth(self.pointColor,in:$0)
            self.pointColor.changed = { [weak self] colors,title,final in guard let self else { return }; self.states.pointColors = colors; self.editChanged?(self.states,title,final) }
            self.pointColor.command = { [weak self] in self?.command?($0) }
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
            self.addTitle("B&W MIX", to: $0)
            self.addGrayMix(to: $0)
        }
        tool("Details", symbol: "square.dotted", in: tools) { content in
            self.slider("Sharpen", path: \.sharpness, range: 0...2, in: content)
            self.addSharpeningDetail(to: content)
        }
        tool("Denoise", symbol: "square.grid.3x3", in: tools) { content in
            self.slider("Noise reduction", path: \.denoise, range: 0...1, in: content)
            self.addNoiseDetail(to: content)
        }
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
            self.help("Choose your own sky photograph. On-device AI finds the sky boundary and blends it into the current photo.", to: content)
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
        action("Set up on-device AI…", "setupAI", to: tools)
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
        if title == "Crop & rotate" || title == "Lens corrections" || title == "Transform" || title == "Profile & calibration" { content(contentStack) }
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
        lutBrowser.setActive(index == 1 || lrModule == .develop)
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
    /// Luminar layout, Return: a tool showing its Masking tab goes back to its adjustments; otherwise the open tool collapses
    /// when a canvas tool was in use or it is the Masks tool. Returns whether anything closed.
    func finishLuminarTool(canvasToolWasActive: Bool) -> Bool {
        guard activeTab == 0 else { return false }
        if let workspace = workspaces.first(where: { $0.0.selectedSegment == 1 && $0.0.superview.map { !$0.isHidden } == true }) {
            workspace.0.selectedSegment = 0; workspaceChanged(workspace.0); return true
        }
        guard let index = toolBodies.firstIndex(where: { !$0.isHidden }), canvasToolWasActive || headers[index].title == "Masks" else { return false }
        toolBodies[index].isHidden = true
        (headers[index] as? ToolHeaderButton)?.expanded = false
        return true
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
        for column in lrColumns.values { column.note.stringValue = text }; leftDevelopColumn.note.stringValue = ""
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
        lrStrip.show(nil); showDrawer(nil)
        returnBorrowed()
        for column in lrColumns.values { column.isHidden = true }
        lrModule = target
        for v in [sectionTitle, summary, settings, body, message] as [NSView] { v.isHidden = target != nil }
        flatColor = target == nil ? nil : LRColors.panel
        guard let target else { showTab(activeTab); return }
        let column = lrColumns[target] ?? buildLightroom(target)
        column.isHidden = false
        for (slot, view, height) in lrSlots[target] ?? [] { borrow(view, into: slot, height: height) }
        lutBrowser.setActive(target == .develop)
    }
    /// The Lightroom tool strip: Crop (R), Remove (Q) or Masking (Shift-W), or nil to close the tool.
    func showLightroomTool(_ id: String?) {
        guard lrModule == .develop else { return }
        lrStrip.show(id); showDrawer(id)
    }
    var lightroomToolOpen: String? { lrStrip.selected }
    /// Keywords of the photo selected in the library, for the Keywording panel.
    func showKeywords(_ keywords: [String]?) {
        lrKeywords.stringValue = keywords.map { $0.isEmpty ? "No keywords" : $0.joined(separator: ", ") } ?? "Select a photo to see its keywords."
    }

    private func buildLightroom(_ module: LightroomModule) -> LRPanelColumn {
        let column = LRPanelColumn()
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
        column.pin(lrStrip)
        lrStrip.choose = { [weak self] id in self?.command?("finishMask"); self?.showDrawer(id); self?.lightroomTool?(id) }
        lrDrawer.orientation = .vertical; lrDrawer.alignment = .leading; lrDrawer.spacing = 8
        lrDrawer.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 12, right: 14)
        column.top(lrDrawer)
        let crop = LRStack(), remove = LRStack(), masking = LRStack(), redeye = LRStack()
        for box in [crop, remove, redeye, masking] { box.orientation = .vertical; box.alignment = .leading; box.spacing = 8; fullWidth(box, in: lrDrawer); box.isHidden = true }
        drawerViews = ["crop": crop, "remove": remove, "redeye": redeye, "masking": masking]
        addEyeControls(to: redeye)
        let cropHolder = NSView(); fullWidth(cropHolder, in: crop); slots.append((cropHolder, cropPresets, nil))
        slider("Angle", path: \.straighten, range: -20...20, in: crop)
        for (title, id) in [("Draw crop", "crop"), ("Apply crop", "applyCrop"), ("Auto straighten", "autoStraighten"), ("AI align horizon", "horizon"), ("Rotate clockwise", "rotate"), ("Flip horizontally", "flip"), ("Reset", "resetCrop")] { action(title, id, to: crop) }
        let removeHolder = NSView(); fullWidth(removeHolder, in: remove); slots.append((removeHolder, retouch, nil))
        help("Remove with AI: select the area with Masking, then:", to: remove); action("Remove selected area", "ai:erase", to: remove)
        addSpotControls(to: remove)
        let layersHolder = NSView(); fullWidth(layersHolder, in: masking); slots.append((layersHolder, maskLayers, nil))
        let divider = NSBox(); divider.boxType = .separator; fullWidth(divider, in: masking)
        let target = NSTextField(labelWithString: "Or limit a whole tool:"); target.font = .systemFont(ofSize: 11); target.textColor = LRColors.dim
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
            s.add(LRButton("Crop & Straighten… (R)") { [weak self] in self?.lrStrip.select("crop") })
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
    /// Develop's left panel: Presets, Versions (OpenStill's named alternatives) and History, with Copy… / Paste.
    private func buildLeftDevelop() {
        let presets = LRSection("Presets", module: .develop, side: .left, open: true)
        presets.add(presetSlot); leftDevelopColumn.add(presets)
        let snapshots = LRSection("Snapshots", module: .develop, side: .left, open: true)
        snapshots.add(snapshotSlot); leftDevelopColumn.add(snapshots)
        let versionsSection = LRSection("Versions", module: .develop, side: .left, open: false)
        versionsSection.add(versionSlot); leftDevelopColumn.add(versionsSection)
        let history = LRSection("History", module: .develop, side: .left, open: true)
        history.add(historySlot); leftDevelopColumn.add(history)
        leftDevelopColumn.setButtons([("Copy…", { [weak self] in self?.command?("lr:copy") }), ("Paste", { [weak self] in self?.command?("lr:paste") })])
        if let presetsDoc = presetScroll.documentView, let historyDoc = historyScroll.documentView {
            lrSlots[.develop, default: []] += [(presetSlot, presetsDoc, nil), (snapshotSlot, snapshotStack, nil), (versionSlot, versions, nil), (historySlot, historyDoc, nil)]
        }
    }
    private func labelView(_ text: String) -> NSTextField { let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 11); l.textColor = LRColors.dim; return l }
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
    fileprivate func addEyeControls(to stack: NSStackView) {
        action("Red eye: drag over an eye", "eye:redEye", to: stack)
        action("Pet eye: drag over an eye", "eye:petEye", to: stack)
        slider("Pupil size", path: \.eyePupil, range: 0.2...1, in: stack)
        slider("Darken", path: \.eyeDarken, range: 0...1, in: stack)
        toggle("Pet eye catchlight", path: \.eyeCatchlight, in: stack)
        action("Remove last eye", "eye:removeLast", to: stack); action("Clear all eyes", "eye:clear", to: stack)
        help("Sliders change the last eye you corrected.", to: stack)
    }
    fileprivate func addSpotControls(to stack: NSStackView) {
        action("Visualize Spots (on/off)", "spots:toggle", to: stack)
        let label = NSTextField(labelWithString: "Spot sensitivity"); label.font = .systemFont(ofSize: 11)
        let slider = TrackingSlider(range: 0...1); slider.doubleValue = 0.3; slider.setAccessibilityLabel("Visualize Spots sensitivity")
        slider.change = { [weak self] v, final in if final { self?.command?("spots:threshold:\(1 - v)") } }
        let row = NSStackView(views: [label, slider]); row.spacing = 8; fullWidth(row, in: stack)
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
