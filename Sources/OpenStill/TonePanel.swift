import AppKit
import CoreImage
import OpenStillCore

private final class CurveGraph: NSView {
    var values = ToneCurves.identity { didSet { needsDisplay = true } }
    var color = NSColor.white
    var changed: (([Double],Bool)->Void)?
    private var handle:Int?
    override var acceptsFirstResponder:Bool { true }
    override init(frame:NSRect) { super.init(frame:frame); setAccessibilityElement(true); setAccessibilityLabel("Tone curve: drag a point, or use the five output sliders below"); setAccessibilityRole(.image) }
    required init?(coder:NSCoder) { fatalError() }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.08,alpha:0.7).setFill(); NSBezierPath(roundedRect:bounds,xRadius:6,yRadius:6).fill()
        let r = bounds.insetBy(dx:10,dy:10)
        NSColor.separatorColor.setStroke()
        for i in 0...4 {
            let f = Double(i)/4, line = NSBezierPath()
            line.move(to:CGPoint(x:r.minX+f*r.width,y:r.minY)); line.line(to:CGPoint(x:r.minX+f*r.width,y:r.maxY))
            line.move(to:CGPoint(x:r.minX,y:r.minY+f*r.height)); line.line(to:CGPoint(x:r.maxX,y:r.minY+f*r.height)); line.stroke()
        }
        let curve = NSBezierPath(); curve.lineWidth = 1.5; color.setStroke()
        for i in 0...256 { let x = Double(i)/256; let p = CGPoint(x:r.minX+x*r.width,y:r.minY+ToneCurves.value(at:x,points:values)*r.height); if i == 0 { curve.move(to:p) } else { curve.line(to:p) } }
        curve.stroke(); color.setFill()
        for (i,v) in values.enumerated() { NSBezierPath(ovalIn:CGRect(x:r.minX+Double(i)/4*r.width-3,y:r.minY+v*r.height-3,width:6,height:6)).fill() }
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow,from:nil), r = bounds.insetBy(dx:10,dy:10)
        handle = min(4,max(0,Int(((p.x-r.minX)/r.width*4).rounded()))); update(event,final:false)
    }
    override func mouseDragged(with event:NSEvent) { update(event,final:false) }
    override func mouseUp(with event:NSEvent) { update(event,final:true); handle = nil }
    private func update(_ event:NSEvent, final:Bool) {
        guard let handle else { return }; let p = convert(event.locationInWindow,from:nil), r = bounds.insetBy(dx:10,dy:10)
        values[handle] = min(1,max(0,(p.y-r.minY)/r.height)); changed?(values,final)
    }
}
private final class CurveSlider: NSSlider {
    var change:((Double,Bool)->Void)?
    private var tracking = false
    @objc func adjust() { change?(doubleValue,!tracking) }
    override func mouseDown(with event:NSEvent) { tracking = true; super.mouseDown(with:event); tracking = false; change?(doubleValue,true) }
}
final class ToneCurvePanel: NSStackView {
    var changed: ((ToneCurves,Bool)->Void)?
    private let channel = NSPopUpButton(frame:.zero,pullsDown:false)
    private let graph = CurveGraph()
    private var sliders:[CurveSlider] = []
    private var settings = ToneCurves()
    private let paths:[WritableKeyPath<ToneCurves,[Double]>] = [\.master,\.red,\.green,\.blue]
    override init(frame:NSRect) {
        super.init(frame:frame); orientation = .vertical; alignment = .leading; spacing = 8
        channel.addItems(withTitles:["Master","Red","Green","Blue"]); channel.target = self; channel.action = #selector(selectChannel); channel.setAccessibilityLabel("Curve channel")
        addArrangedSubview(channel); channel.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        addArrangedSubview(graph); graph.widthAnchor.constraint(equalTo:widthAnchor).isActive = true; graph.heightAnchor.constraint(equalToConstant:155).isActive = true
        graph.changed = { [weak self] values,final in guard let self else { return }; self.settings[keyPath:self.paths[self.channel.indexOfSelectedItem]] = values; self.refresh(); self.changed?(self.settings,final) }
        for i in 0..<5 {
            let label = NSTextField(labelWithString:["Blacks","Shadows","Midtones","Highlights","Whites"][i]); label.font = .systemFont(ofSize:10); label.widthAnchor.constraint(equalToConstant:65).isActive = true
            let slider = CurveSlider(value:Double(i)/4,minValue:0,maxValue:1,target:nil,action:nil); slider.target = slider; slider.action = #selector(CurveSlider.adjust); slider.isContinuous = true; slider.setAccessibilityLabel("Curve " + label.stringValue)
            slider.change = { [weak self] value,final in guard let self else { return }; self.settings[keyPath:self.paths[self.channel.indexOfSelectedItem]][i] = value; self.refresh(); self.changed?(self.settings,final) }
            let row = NSStackView(views:[label,slider]); row.spacing = 8; addArrangedSubview(row); row.widthAnchor.constraint(equalTo:widthAnchor).isActive = true; sliders.append(slider)
        }
        let reset = NSButton(title:"Reset curves",target:self,action:#selector(reset)); reset.bezelStyle = .rounded; addArrangedSubview(reset)
    }
    required init?(coder:NSCoder) { fatalError() }
    func update(_ next:ToneCurves, enabled:Bool) { settings = next.sanitized; channel.isEnabled = enabled; graph.isHidden = !enabled; sliders.forEach { $0.isEnabled = enabled }; refresh() }
    @objc private func selectChannel() { refresh() }
    @objc private func reset() { settings = ToneCurves(); refresh(); changed?(settings,true) }
    private func refresh() {
        let i = max(0,channel.indexOfSelectedItem), values = settings[keyPath:paths[i]]
        graph.color = [NSColor.white,.systemRed,.systemGreen,.systemBlue][i]; graph.values = values
        for (slider,value) in zip(sliders,values) { slider.doubleValue = value }
    }
}
final class HistogramPanel: NSView {
    var histogram:PhotoHistogram? { didSet { needsDisplay = true } }
    var sensor:Double? { didSet { needsDisplay = true } }
    override init(frame:NSRect) { super.init(frame:frame); heightAnchor.constraint(equalToConstant:112).isActive = true; setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("RGB and luminance histogram with output and sensor clipping") }
    required init?(coder:NSCoder) { fatalError() }
    override func draw(_ dirtyRect:NSRect) {
        let area = CGRect(x:0,y:38,width:bounds.width,height:bounds.height-38)
        NSColor(calibratedWhite:0.06,alpha:0.7).setFill(); NSBezierPath(roundedRect:area,xRadius:5,yRadius:5).fill()
        guard let histogram else { return }
        for (bins,color) in [(histogram.red,NSColor.systemRed),(histogram.green,.systemGreen),(histogram.blue,.systemBlue),(histogram.luminance,.white)] {
            let maximum = max(1,bins.max() ?? 1), path = NSBezierPath()
            for i in 0..<256 {
                let p = CGPoint(x:area.minX+Double(i)/255*area.width,y:area.minY+log1p(Double(bins[i]))/log1p(Double(maximum))*area.height)
                if i == 0 { path.move(to:p) } else { path.line(to:p) }
            }
            color.withAlphaComponent(0.65).setStroke(); path.lineWidth = 1; path.stroke()
        }
        let output = String(format:"sRGB output: shadows %.1f%% · highlights %.1f%%",histogram.shadowClipped*100,histogram.highlightClipped*100)
        let raw = sensor.map { String(format:"RAW sensor saturation: %.2f%%",$0*100) } ?? "RAW sensor: available in RAW mode"
        let attrs:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:9),.foregroundColor:NSColor.secondaryLabelColor]
        (output as NSString).draw(at:CGPoint(x:0,y:20),withAttributes:attrs); (raw as NSString).draw(at:CGPoint(x:0,y:5),withAttributes:attrs)
        setAccessibilityValue(output + ". " + raw)
    }
}

extension ViewerController {
    func updateHistogram(_ image:CGImage?) {
        let token = UUID(); histogramToken = token
        guard let image else { info.updateHistogram(nil,sensor:nil); return }
        let source = currentSource, raw = photoRecord?.active.sourceMode == .raw
        histogramQueue.async { [weak self] in
            let histogram = PhotoHistogram.measure(CIImage(cgImage:image))
            let sensor = raw ? source.flatMap { ModernRenderer.sensorClipping($0) } : nil
            DispatchQueue.main.async { guard let self, self.histogramToken == token, self.currentSource == source else { return }; self.info.updateHistogram(histogram,sensor:sensor) }
        }
    }
    func chooseWhiteBalance(at point:CGPoint) {
        guard let source = currentSource, let record = photoRecord, let original = renderedPhoto?.image else { return }
        finishMaskEditing(); canvas.clearTool()
        let token = editToken, edits = currentEdits
        let geometry = EditGeometry(size:CGSize(width:original.width,height:original.height),edits:edits)
        let samplePoint = LensCorrections.sourcePoint(geometry.sourcePoint(point),size:geometry.sourceSize,settings:edits.lens)
        info.status("Sampling neutral color…")
        editQueue.async { [weak self] in
            let result = Result { () -> PhotoEdits in
                var next = edits
                let input = try edits.baseAsset.map { try ModernRenderer.readImage(EditStorage.asset($0)) } ?? ModernRenderer.source(source,mode:record.active.sourceMode,raw:record.active.recipe.raw)
                let correction = try ToneTools.neutralSample(input,point:samplePoint)
                if record.active.sourceMode == .raw && edits.baseAsset == nil {
                    var original = try edits.advanced?.rawWhiteBalance ?? RawDecoder.cameraBalance(source)
                    let warmth = Float(edits.temperature/6500), tint = Float(pow(2,-edits.tint/200))
                    original[0] *= warmth; original[2] /= warmth; original[1] *= tint; original[3] *= tint
                    let gain = correction.gains
                    next.ensureAdvanced(); next.advanced!.rawWhiteBalance = [original[0]*Float(gain[0]),original[1]*Float(gain[1]),original[2]*Float(gain[2]),original[3]*Float(gain[1])]
                    next.temperature = 6500; next.tint = 0
                } else { next.neutralBalance = correction }
                return next
            }
            DispatchQueue.main.async {
                guard let self, self.currentSource == source, self.editToken == token else { return }
                switch result { case .success(let edits): self.changeEdits(edits,title:"White balance eyedropper",commit:true)
                case .failure: self.info.status("Choose a neutral gray area with visible detail, away from clipped highlights or deep shadows.") }
            }
        }
    }
}
