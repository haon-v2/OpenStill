import AppKit
import CoreImage
import OpenStillCore

/// The curve graph. Point mode: click to add a point, drag to move it, double-click (or drag off the graph) to remove it.
private final class CurveGraph: NSView {
    var points = CurvePoint.identity { didSet { needsDisplay = true } }
    /// Draws this function instead of the points (the parametric curve), and disables point editing.
    var curve: ((Double) -> Double)? { didSet { needsDisplay = true } }
    var color = NSColor.white
    var changed: (([CurvePoint],Bool)->Void)?
    private var handle:Int?
    override var acceptsFirstResponder:Bool { true }
    override init(frame:NSRect) { super.init(frame:frame); setAccessibilityElement(true); setAccessibilityLabel("Tone curve: click to add a point, drag to move it, double-click to remove it"); setAccessibilityRole(.image) }
    required init?(coder:NSCoder) { fatalError() }
    private var area: CGRect { bounds.insetBy(dx:10,dy:10) }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.08,alpha:0.7).setFill(); NSBezierPath(roundedRect:bounds,xRadius:6,yRadius:6).fill()
        let r = area
        NSColor.separatorColor.setStroke()
        for i in 0...4 {
            let f = Double(i)/4, line = NSBezierPath()
            line.move(to:CGPoint(x:r.minX+f*r.width,y:r.minY)); line.line(to:CGPoint(x:r.minX+f*r.width,y:r.maxY))
            line.move(to:CGPoint(x:r.minX,y:r.minY+f*r.height)); line.line(to:CGPoint(x:r.maxX,y:r.minY+f*r.height)); line.stroke()
        }
        let path = NSBezierPath(); path.lineWidth = 1.5; color.setStroke()
        for i in 0...256 {
            let x = Double(i)/256, y = curve?(x) ?? CurvePoint.value(at:x,points:points)
            let p = CGPoint(x:r.minX+x*r.width,y:r.minY+min(1,max(0,y))*r.height); if i == 0 { path.move(to:p) } else { path.line(to:p) }
        }
        path.stroke()
        guard curve == nil else { return }
        color.setFill()
        for (i,p) in points.enumerated() {
            let dot = NSBezierPath(ovalIn:CGRect(x:r.minX+p.x*r.width-4,y:r.minY+p.y*r.height-4,width:8,height:8))
            dot.fill(); if i == handle { NSColor.white.setStroke(); dot.lineWidth = 1.5; dot.stroke() }
        }
        setAccessibilityValue(points.map { "\(Int($0.x*255)) to \(Int($0.y*255))" }.joined(separator:", "))
    }
    private func location(_ event:NSEvent) -> CurvePoint {
        let p = convert(event.locationInWindow,from:nil), r = area
        return CurvePoint((p.x-r.minX)/r.width,(p.y-r.minY)/r.height)
    }
    override func mouseDown(with event:NSEvent) {
        guard curve == nil, isEnabled else { return }
        window?.makeFirstResponder(self)
        let q = location(event), r = area
        let near = points.indices.min { hypot((points[$0].x-q.x)*r.width,(points[$0].y-q.y)*r.height) < hypot((points[$1].x-q.x)*r.width,(points[$1].y-q.y)*r.height) }
        let close = near.map { hypot((points[$0].x-q.x)*r.width,(points[$0].y-q.y)*r.height) < 9 } ?? false
        if event.clickCount == 2, close, let near, near != 0, near != points.count-1 { points.remove(at:near); handle = nil; changed?(points,true); return }
        if close, let near { handle = near }
        else if points.count < CurvePoint.maximumCount {
            let x = min(1,max(0,q.x)), onCurve = CurvePoint(x,CurvePoint.value(at:x,points:points))
            points.append(onCurve); points.sort { $0.x < $1.x }; handle = points.firstIndex(of:onCurve)
            changed?(points,false)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event:NSEvent) {
        guard let i = handle, points.indices.contains(i) else { return }
        var q = location(event)
        let lo = i == 0 ? 0 : points[i-1].x+0.01, hi = i == points.count-1 ? 1 : points[i+1].x-0.01
        q.x = min(hi,max(lo,q.x)); q.y = min(1,max(0,q.y))
        points[i] = q; changed?(points,false)
    }
    override func mouseUp(with event:NSEvent) {
        guard let i = handle, points.indices.contains(i) else { handle = nil; return }
        // Dragging an inner point well off the graph removes it, as in Lightroom.
        let q = location(event)
        if i != 0, i != points.count-1, q.y < -0.08 || q.y > 1.08 { points.remove(at:i) }
        handle = nil; changed?(points,true)
    }
    var isEnabled = true { didSet { needsDisplay = true } }
}
private final class CurveSlider: NSSlider {
    var change:((Double,Bool)->Void)?
    private var tracking = false
    @objc func adjust() { change?(doubleValue,!tracking) }
    override func mouseDown(with event:NSEvent) { tracking = true; super.mouseDown(with:event); tracking = false; change?(doubleValue,true) }
}
/// Tone Curve, as in Lightroom: a Parametric curve (four region sliders and three splits) and a Point curve per channel.
final class ToneCurvePanel: NSStackView {
    var changed: ((ToneCurves,Bool)->Void)?
    private let mode = NSSegmentedControl(labels:["Parametric","Point"], trackingMode:.selectOne, target:nil, action:nil)
    private let channel = NSSegmentedControl(labels:["RGB","Red","Green","Blue"], trackingMode:.selectOne, target:nil, action:nil)
    private let graph = CurveGraph()
    private let parametricRows = NSStackView()
    private let hint = NSTextField(wrappingLabelWithString:"Click the curve to add a point, drag to move it, double-click to remove it.")
    private var sliders:[(CurveSlider,NSTextField,WritableKeyPath<ParametricCurve,Double>)] = []
    private var settings = ToneCurves()
    private let pointPaths:[WritableKeyPath<ToneCurves,[CurvePoint]?>] = [\.masterPoints,\.redPoints,\.greenPoints,\.bluePoints]
    private let samplePaths:[WritableKeyPath<ToneCurves,[Double]>] = [\.master,\.red,\.green,\.blue]
    override init(frame:NSRect) {
        super.init(frame:frame); orientation = .vertical; alignment = .leading; spacing = 8
        mode.selectedSegment = 1; mode.target = self; mode.action = #selector(modeChanged); mode.setAccessibilityLabel("Curve type"); mode.controlSize = .small
        channel.selectedSegment = 0; channel.target = self; channel.action = #selector(modeChanged); channel.setAccessibilityLabel("Curve channel"); channel.controlSize = .small
        for v in [mode, channel] as [NSView] { addArrangedSubview(v) }
        addArrangedSubview(graph); graph.widthAnchor.constraint(equalTo:widthAnchor).isActive = true; graph.heightAnchor.constraint(equalTo:graph.widthAnchor, multiplier:0.9).isActive = true
        graph.changed = { [weak self] points,final in guard let self else { return }; self.setPoints(points); self.changed?(self.settings,final) }
        hint.font = .systemFont(ofSize:10); hint.textColor = .secondaryLabelColor; addArrangedSubview(hint); hint.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        parametricRows.orientation = .vertical; parametricRows.alignment = .leading; parametricRows.spacing = 6
        let rows:[(String,WritableKeyPath<ParametricCurve,Double>,ClosedRange<Double>)] = [("Highlights",\.highlights,-1...1),("Lights",\.lights,-1...1),("Darks",\.darks,-1...1),("Shadows",\.shadows,-1...1),
                                                                                     ("Shadow split",\.shadowSplit,0.1...0.4),("Midtone split",\.midtoneSplit,0.3...0.7),("Highlight split",\.highlightSplit,0.6...0.9)]
        for (title,path,range) in rows {
            let label = NSTextField(labelWithString:title); label.font = .systemFont(ofSize:10); label.widthAnchor.constraint(equalToConstant:82).isActive = true
            let value = NSTextField(labelWithString:""); value.font = .monospacedDigitSystemFont(ofSize:10, weight:.regular); value.textColor = .secondaryLabelColor; value.widthAnchor.constraint(equalToConstant:34).isActive = true
            let slider = CurveSlider(value:0,minValue:range.lowerBound,maxValue:range.upperBound,target:nil,action:nil); slider.target = slider; slider.action = #selector(CurveSlider.adjust); slider.isContinuous = true; slider.controlSize = .small
            slider.setAccessibilityLabel("Parametric curve " + title)
            slider.change = { [weak self] v,final in
                guard let self else { return }
                var p = self.settings.parametric ?? ParametricCurve(); p[keyPath:path] = v; self.settings.parametric = p.isIdentity && path != \.shadowSplit && path != \.midtoneSplit && path != \.highlightSplit ? nil : p
                self.refresh(); self.changed?(self.settings,final)
            }
            let row = NSStackView(views:[label,slider,value]); row.spacing = 6; parametricRows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:parametricRows.widthAnchor).isActive = true
            sliders.append((slider,value,path))
        }
        addArrangedSubview(parametricRows); parametricRows.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        let reset = NSButton(title:"Reset curve",target:self,action:#selector(reset)); reset.bezelStyle = .rounded; reset.controlSize = .small; addArrangedSubview(reset)
        refresh()
    }
    required init?(coder:NSCoder) { fatalError() }
    func update(_ next:ToneCurves, enabled:Bool) {
        settings = next.sanitized; mode.isEnabled = enabled; channel.isEnabled = enabled; graph.isEnabled = enabled
        sliders.forEach { $0.0.isEnabled = enabled }; refresh()
    }
    /// The curve currently shown, for the targeted adjustment tool: 0 master … 3 blue.
    var selectedChannel: Int { mode.selectedSegment == 1 ? max(0,channel.selectedSegment) : 0 }
    @objc private func modeChanged() { refresh() }
    @objc private func reset() {
        if mode.selectedSegment == 0 { settings.parametric = nil }
        else { let i = selectedChannel; settings[keyPath:pointPaths[i]] = nil; settings[keyPath:samplePaths[i]] = ToneCurves.identity }
        refresh(); changed?(settings,true)
    }
    /// Points of the selected channel. An older five-sample curve becomes five points the first time it's edited.
    private func currentPoints() -> [CurvePoint] {
        let i = selectedChannel
        if let points = settings[keyPath:pointPaths[i]] { return points }
        return zip(ToneCurves.identity,settings[keyPath:samplePaths[i]]).map { CurvePoint($0,$1) }
    }
    private func setPoints(_ points:[CurvePoint]) {
        let i = selectedChannel
        settings[keyPath:pointPaths[i]] = points; settings[keyPath:samplePaths[i]] = ToneCurves.identity
        settings = settings.sanitized
    }
    private func refresh() {
        let parametric = mode.selectedSegment == 0
        channel.isHidden = parametric; parametricRows.isHidden = !parametric; hint.isHidden = parametric
        let i = selectedChannel
        graph.color = parametric ? .white : [NSColor.white,.systemRed,.systemGreen,.systemBlue][i]
        let p = settings.parametric ?? ParametricCurve()
        graph.curve = parametric ? { p.value(at:$0) } : nil
        graph.points = currentPoints()
        for (slider,label,path) in sliders { slider.doubleValue = p[keyPath:path]; label.stringValue = String(format:"%.0f", p[keyPath:path]*100) }
    }
}
final class HistogramPanel: NSView {
    var histogram:PhotoHistogram? { didSet { needsDisplay = true } }
    var sensor:Double? { didSet { needsDisplay = true } }
    var clippingShown = false { didSet { needsDisplay = true } }
    var clicked:(()->Void)?
    override func mouseDown(with event:NSEvent) { clicked?() }
    override func accessibilityPerformPress() -> Bool { clicked?(); return clicked != nil }
    override init(frame:NSRect) { super.init(frame:frame); heightAnchor.constraint(equalToConstant:112).isActive = true; setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("RGB and luminance histogram with output and sensor clipping. Press to show clipped pixels on the photo") }
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
        let output = String(format:"sRGB output: shadows %.1f%% · highlights %.1f%%",histogram.shadowClipped*100,histogram.highlightClipped*100) + (clippingShown ? " · overlay on (J)" : " · click or J to show")
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
        let gate = histogramGate, job = gate.begin()
        histogramQueue.async { [weak self] in
            guard gate.isCurrent(job) else { return }   // a newer frame's histogram is already on the way
            let histogram = PhotoHistogram.measure(CIImage(cgImage:image))
            let sensor = raw ? source.flatMap { ModernRenderer.sensorClipping($0) } : nil
            DispatchQueue.main.async { guard let self, self.histogramToken == token, self.currentSource == source else { return }; self.info.updateHistogram(histogram,sensor:sensor) }
        }
    }
    func chooseWhiteBalance(at point:CGPoint) {
        guard let source = currentSource, let record = photoRecord, let original = renderedPhoto else { return }
        finishMaskEditing(); canvas.clearTool()
        let token = editToken, edits = currentEdits
        let geometry = EditGeometry(size:original.pixelSize,edits:edits)
        let samplePoint = LensCorrections.sourcePoint(geometry.sourcePoint(point),size:geometry.sourceSize,settings:edits.optics)
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
