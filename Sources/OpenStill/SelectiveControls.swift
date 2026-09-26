import AppKit
import OpenStillCore

final class ContinuousSlider: NSSlider {
    var changed: ((Double,Bool)->Void)?
    private var tracking = false
    convenience init(range:ClosedRange<Double>, value:Double = 0) {
        self.init(value:value,minValue:range.lowerBound,maxValue:range.upperBound,target:nil,action:nil)
        target = self; action = #selector(change); isContinuous = true; controlSize = .small
    }
    @objc private func change() { changed?(doubleValue,!tracking) }
    override func mouseDown(with event:NSEvent) { tracking = true;super.mouseDown(with:event);tracking = false;changed?(doubleValue,true) }
}
private final class SpectrumSliderCell: NSSliderCell {
    var colors: [NSColor] = [.gray,.red]
    override func drawBar(inside rect:NSRect, flipped:Bool) {
        let track = NSRect(x:rect.minX,y:rect.midY-3,width:rect.width,height:6)
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect:track,xRadius:3,yRadius:3).addClip()
        NSGradient(colors:colors)?.draw(in:track,angle:0);NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.4).setFill();NSRect(x:track.midX-0.5,y:track.minY,width:1,height:6).fill()
    }
    override func drawKnob(_ rect:NSRect) {
        let knob = NSRect(x:rect.midX-5,y:rect.midY-5,width:10,height:10)
        NSColor.black.withAlphaComponent(0.55).setStroke();let path = NSBezierPath(ovalIn:knob);path.lineWidth = 3;path.stroke()
        NSColor.white.setFill();path.fill()
    }
}
private final class SwatchButton: NSButton {
    var color: NSColor = .red
    override func draw(_ dirtyRect:NSRect) {
        let circle = NSRect(x:bounds.midX-8,y:bounds.midY-8,width:16,height:16)
        color.setFill();NSBezierPath(ovalIn:circle).fill()
        if state == .on { NSColor.white.setStroke();let ring = NSBezierPath(ovalIn:circle.insetBy(dx:-3,dy:-3));ring.lineWidth = 1.5;ring.stroke() }
    }
}
private func hslColor(_ hue:Double,_ saturation:Double = 1,_ lightness:Double = 0.5) -> NSColor {
    let rgb = ColorMixer.rgb(hue:hue,saturation:saturation,lightness:lightness)
    return NSColor(srgbRed:rgb[0],green:rgb[1],blue:rgb[2],alpha:1)
}

final class ColorMixerPanel: NSStackView {
    var changed: ((Int,ColorBand,String,Bool)->Void)?
    private var bands = [ColorBand](repeating:ColorBand(),count:8)
    private var selected = 0
    private var swatches:[SwatchButton] = []
    private let mode = NSSegmentedControl(labels:["Saturation","HSL"],trackingMode:.selectOne,target:nil,action:nil)
    private let heading = NSTextField(labelWithString:"Red")
    private let preview = NSView()
    private var rows:[NSStackView] = [], sliders:[ContinuousSlider] = [], values:[NSTextField] = []
    private let reset = NSButton(title:"Reset this color",target:nil,action:nil)
    override init(frame:NSRect) {
        super.init(frame:frame);orientation = .vertical;alignment = .leading;spacing = 12
        let palette = NSStackView();palette.distribution = .fillEqually;palette.spacing = 3
        for index in 0..<8 {
            let button = SwatchButton(title:"",target:self,action:#selector(selectColor(_:)));button.tag = index;button.color = hslColor(ColorMixer.centers[index]);button.setButtonType(.toggle);button.isBordered = false
            button.setAccessibilityLabel(ColorMixer.names[index]+" color channel");button.toolTip = ColorMixer.names[index]
            button.heightAnchor.constraint(equalToConstant:28).isActive = true;swatches.append(button);palette.addArrangedSubview(button)
        };add(palette)
        preview.wantsLayer = true;preview.layer?.cornerRadius = 5;preview.widthAnchor.constraint(equalToConstant:24).isActive = true;preview.heightAnchor.constraint(equalToConstant:18).isActive = true
        heading.font = .systemFont(ofSize:12,weight:.medium)
        let title = NSStackView(views:[preview,heading,NSView()]);title.spacing = 8;add(title)
        mode.target = self;mode.action = #selector(switchMode);mode.segmentStyle = .rounded;mode.setAccessibilityLabel("Selected color editing mode");add(mode)
        for (index,name) in ["Hue","Saturation","Lightness"].enumerated() {
            let row = NSStackView();row.orientation = .vertical;row.alignment = .leading;row.spacing = 5
            let label = NSTextField(labelWithString:name);label.font = .systemFont(ofSize:11)
            let value = NSTextField(labelWithString:"0");value.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular);value.textColor = .secondaryLabelColor
            let top = NSStackView(views:[label,NSView(),value]);row.addArrangedSubview(top);top.widthAnchor.constraint(equalTo:row.widthAnchor).isActive = true
            let slider = ContinuousSlider(range:-1...1);let cell = SpectrumSliderCell();slider.cell = cell;slider.minValue = -1;slider.maxValue = 1;slider.target = slider;slider.action = NSSelectorFromString("change");slider.isContinuous = true
            slider.changed = { [weak self] number,final in
                guard let self else { return };var band = self.bands[self.selected]
                if index == 0 { band.hue = number } else if index == 1 { band.saturation = number } else { band.lightness = number }
                self.bands[self.selected] = band;self.refresh();self.changed?(self.selected,band,ColorMixer.names[self.selected]+" "+name,final)
            }
            row.addArrangedSubview(slider);slider.widthAnchor.constraint(equalTo:row.widthAnchor).isActive = true
            sliders.append(slider);values.append(value);rows.append(row);add(row)
        }
        let hint = NSTextField(wrappingLabelWithString:"Choose a color above. Switching views keeps its adjustments.");hint.font = .systemFont(ofSize:10);hint.textColor = .secondaryLabelColor;add(hint)
        reset.bezelStyle = .rounded;reset.font = .systemFont(ofSize:11);reset.target = self;reset.action = #selector(resetColor);add(reset);refresh()
    }
    required init?(coder:NSCoder) { fatalError() }
    private func add(_ view:NSView) { addArrangedSubview(view);view.widthAnchor.constraint(equalTo:widthAnchor).isActive = true }
    @objc private func selectColor(_ sender:NSButton) { selected = sender.tag;refresh() }
    @objc private func switchMode() { bands[selected].displayMode = mode.selectedSegment == 1 ? "hsl" : "saturation";refresh();changed?(selected,bands[selected],ColorMixer.names[selected]+" controls",true) }
    @objc private func resetColor() { let mode = bands[selected].displayMode;bands[selected] = ColorBand();bands[selected].displayMode = mode;refresh();changed?(selected,bands[selected],"Reset "+ColorMixer.names[selected],true) }
    func update(_ bands:[ColorBand]?, enabled:Bool) {
        self.bands = bands ?? [ColorBand](repeating:ColorBand(),count:8);setEnabled(enabled);refresh()
    }
    func setEnabled(_ enabled:Bool) { for button in swatches { button.isEnabled = enabled };mode.isEnabled = enabled;reset.isEnabled = enabled;sliders.forEach { $0.isEnabled = enabled } }
    private func refresh() {
        let band = bands[selected], center = ColorMixer.centers[selected], hue = center+band.hue*0.12
        let hsl = band.displayMode == "hsl" || (band.displayMode == nil && (band.hue != 0 || (band.lightness ?? 0) != 0))
        mode.selectedSegment = hsl ? 1 : 0
        rows[0].isHidden = !hsl;rows[2].isHidden = !hsl
        for (i,button) in swatches.enumerated() { button.state = i == selected ? .on : .off;button.needsDisplay = true }
        heading.stringValue = ColorMixer.names[selected];preview.layer?.backgroundColor = hslColor(hue,min(1,max(0,0.65*(1+band.saturation))),0.5+(band.lightness ?? 0)*0.5).cgColor
        for (i,value) in [band.hue,band.saturation,band.lightness ?? 0].enumerated() {
            sliders[i].doubleValue = value;values[i].stringValue = String(format:"%+.0f",value*100)
            sliders[i].setAccessibilityLabel(ColorMixer.names[selected]+" "+["hue","saturation","lightness"][i])
            let cell = sliders[i].cell as! SpectrumSliderCell
            cell.colors = (0...12).map { step in
                let t = Double(step)/12
                if i == 0 { return hslColor(center+(t*2-1)*0.12) }
                if i == 1 { return hslColor(hue,min(1,1.3*t)) }
                return hslColor(hue,0.85,t)
            };sliders[i].needsDisplay = true
        }
    }
}

final class MaskPanel: NSStackView {
    var maskChanged:((AdjustmentMask?,String,Bool)->Void)?
    private let components=MaskComponentPanel()
    var selectedID:UUID? {components.selectedID}
    func selectComponent(_ id:UUID){components.select(id)}
    var command: ((String)->Void)?
    var featherChanged: ((Double,Bool)->Void)?
    var brushChanged: ((Double,Double,Double)->Void)?
    var done: (()->Void)?
    private let key:String
    private let stateLabel = NSTextField(labelWithString:"No mask · Entire photo")
    private let hint = NSTextField(wrappingLabelWithString:"Choose a tool to select an area.")
    private var buttons:[NSButton] = []
    private let brush = NSStackView(), gradient = NSStackView()
    private let paint = NSSegmentedControl(labels:["Paint","Erase"],trackingMode:.selectOne,target:nil,action:nil)
    private let overlay = NSButton(checkboxWithTitle:"Show red overlay",target:nil,action:nil)
    private let actions = NSPopUpButton(frame:.zero,pullsDown:true)
    private var size:ContinuousSlider!, softness:ContinuousSlider!, strength:ContinuousSlider!, feather:ContinuousSlider!
    private var featherLabel:NSTextField!
    private var selectedKind:String?
    private var hasMask = false, enabled = true
    override var isFlipped:Bool { true }
    init(key:String) {
        self.key = key;super.init(frame:.zero);orientation = .vertical;alignment = .leading;spacing = 12
        stateLabel.font = .systemFont(ofSize:11,weight:.medium);add(stateLabel)
        add(components);components.changed = { [weak self] mask,title,final in self?.maskChanged?(mask,title,final) };components.command = { [weak self] in self?.command?($0) }
        for pair in [[("Brush","paintbrush","brush"),("Linear","line.diagonal","linear")],[("Radial","circle.dashed","radial"),("Object AI","viewfinder","object")]] {
            let row = NSStackView();row.distribution = .fillEqually;row.spacing = 6
            for (name,symbol,kind) in pair {
                let button = NSButton(title:name,target:self,action:#selector(selectTool(_:)));button.identifier = NSUserInterfaceItemIdentifier(kind);button.setButtonType(.toggle);button.bezelStyle = .rounded;button.font = .systemFont(ofSize:11);button.image = Appearance.symbol(symbol,size:12);button.imagePosition = .imageLeading;button.setAccessibilityLabel(key+" mask "+name);buttons.append(button);row.addArrangedSubview(button)
            };add(row)
        }
        hint.font = .systemFont(ofSize:11);hint.textColor = .secondaryLabelColor;add(hint)
        for stack in [brush,gradient] { stack.orientation = .vertical;stack.alignment = .leading;stack.spacing = 10;add(stack) }
        paint.target = self;paint.action = #selector(paintMode);paint.segmentStyle = .rounded;paint.selectedSegment = 0;paint.setAccessibilityLabel(key+" brush mode");brush.addArrangedSubview(paint);paint.widthAnchor.constraint(equalTo:brush.widthAnchor).isActive = true
        size = control("Size",range:1...30,value:5,in:brush) { [weak self] _,_ in self?.brushSettings() }
        softness = control("Softness",range:0...100,value:30,in:brush) { [weak self] _,_ in self?.brushSettings() }
        strength = control("Strength",range:1...100,value:100,in:brush) { [weak self] _,_ in self?.brushSettings() }
        feather = control("Feather",range:0...100,value:30,in:gradient) { [weak self] value,final in self?.featherChanged?(value/100,final) }
        overlay.target = self;overlay.action = #selector(showOverlay);overlay.font = .systemFont(ofSize:11);overlay.setAccessibilityLabel(key+" show red mask overlay");add(overlay)
        actions.addItems(withTitles:["Mask actions","Invert combined mask","Clear all masks"]);actions.target = self;actions.action = #selector(maskAction);actions.font = .systemFont(ofSize:11);actions.setAccessibilityLabel(key+" mask actions");add(actions)
        let done = NSButton(title:"Back to adjustments",target:self,action:#selector(finish));done.bezelStyle = .rounded;done.font = .systemFont(ofSize:11);add(done)
        reveal()
    }
    required init?(coder:NSCoder) { fatalError() }
    private func add(_ view:NSView) { addArrangedSubview(view);view.widthAnchor.constraint(equalTo:widthAnchor).isActive = true }
    private func control(_ title:String,range:ClosedRange<Double>,value:Double,in stack:NSStackView,changed:@escaping(Double,Bool)->Void) -> ContinuousSlider {
        let label = NSTextField(labelWithString:title+"  \(Int(value))%");label.font = .systemFont(ofSize:11);stack.addArrangedSubview(label)
        if title == "Feather" { featherLabel = label }
        let slider = ContinuousSlider(range:range,value:value);slider.setAccessibilityLabel(key+" brush "+title.lowercased())
        slider.changed = { number,final in label.stringValue = title+"  \(Int(number))%";changed(number,final) }
        stack.addArrangedSubview(slider);slider.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true;return slider
    }
    @objc private func selectTool(_ sender:NSButton) { selectedKind = sender.identifier!.rawValue;paint.selectedSegment = 0;reveal();brushSettings();command?(selectedKind!) }
    @objc private func paintMode() { selectedKind = "brush";reveal();brushSettings();command?(paint.selectedSegment == 1 ? "erase" : "paint") }
    private func brushSettings() { guard size != nil,softness != nil,strength != nil else { return };brushChanged?(size.doubleValue/200,softness.doubleValue/100,strength.doubleValue/100) }
    @objc private func showOverlay() { command?("show") }
    @objc private func maskAction() { if actions.indexOfSelectedItem == 1 { command?("invert") };if actions.indexOfSelectedItem == 2 { command?("clear") };actions.selectItem(at:0) }
    @objc private func finish() { command?("done");done?() }
    func update(_ mask:AdjustmentMask?,enabled:Bool) {
        components.update(mask,enabled:enabled)
        let mask=mask?.component(components.selectedID)?.selection
        self.enabled = enabled;hasMask = mask != nil
        stateLabel.stringValue = key + " · " + (mask.map { (["object":"Object","colorRange":"Color range","luminanceRange":"Luminance range"][$0.kind] ?? $0.kind.capitalized)+" mask"+($0.inverted ? " · Inverted" : "") } ?? "No mask · Entire photo")
        feather.doubleValue = (mask?.feather ?? 0.3)*100;featherLabel.stringValue = "Feather  \(Int(feather.doubleValue))%"
        setEnabled(enabled)
    }
    func interaction(kind:String?,subtract:Bool,visible:Bool) { selectedKind = kind;paint.selectedSegment = subtract ? 1 : 0;overlay.state = visible ? .on : .off;reveal() }
    func resizeBrush(_ delta:Double) { size.doubleValue = min(30,max(1,size.doubleValue+delta));size.changed?(size.doubleValue,false) }
    func resetInteraction() { selectedKind = nil;paint.selectedSegment = 0;overlay.state = .off;reveal() }
    func setEnabled(_ enabled:Bool) {
        self.enabled = enabled;buttons.forEach { $0.isEnabled = enabled };paint.isEnabled = enabled
        for slider in [size,softness,strength] { slider?.isEnabled = enabled }
        feather.isEnabled = enabled && hasMask;overlay.isEnabled = enabled && hasMask;actions.isEnabled = enabled && hasMask
    }
    private func reveal() {
        brush.isHidden = selectedKind != "brush";gradient.isHidden = selectedKind == nil || selectedKind == "brush"
        for button in buttons { button.state = button.identifier?.rawValue == selectedKind ? .on : .off }
        switch selectedKind {
        case "brush": hint.stringValue = paint.selectedSegment == 1 ? "Erase from the selection. [ and ] resize the brush." : "Paint an area. [ and ] resize the brush."
        case "linear": hint.stringValue = "Drag to fade from unaffected to fully adjusted. Red previews the gradient as you drag. Brush can refine it."
        case "radial": hint.stringValue = "Drag from the center to the edge. Brush can refine the ellipse."
        case "object": hint.stringValue = "Click a foreground subject, then refine with Brush."
        default: hint.stringValue = "Choose a tool to select an area. Red shows your selection."
        }
    }
}
