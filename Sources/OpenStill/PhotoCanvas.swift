import AppKit
import OpenStillCore

final class PhotoCanvas: NSView {
    enum Tool: Hashable { case browse, crop, erase, sun, whiteBalance, maskBrush, maskLinear, maskRadial, maskObject, maskRange, retouchSource, retouch }
    var tool: Tool = .browse { didSet { needsDisplay = true; updateAccessibility(); reportCrop() } }
    var sunPlaced: ((CGPoint, Bool) -> Void)?
    var sunPosition = CGPoint(x:0.7,y:0.8) { didSet { needsDisplay = true; updateAccessibility() } }
    private var draggingSun = false
    var maskDrawn: (([CGPoint], String) -> Void)?
    var retouchSourceChosen:((CGPoint)->Void)?
    var retouchDrawn:(([CGPoint])->Void)?
    var retouchSource:CGPoint? {didSet{needsDisplay=true}}
    var rangeChosen: ((CGPoint) -> Void)?
    var whiteBalanceChosen: ((CGPoint) -> Void)?
    var objectChosen: ((CGPoint) -> Void)?
    var maskOverlay: CGImage? { didSet { needsDisplay = true } }
    var maskRadius: CGFloat = 0.025
    var maskSubtract = false
    var maskSoftness = 0.3
    var maskFeather = 1.0
    var maskInverted = false
    var resizeMaskBrush: ((Double)->Void)?
    private var brushPointer: CGPoint?
    private var brushTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let brushTracking { removeTrackingArea(brushTracking) }
        brushTracking = NSTrackingArea(rect:.zero,options:[.activeInKeyWindow,.mouseMoved,.mouseEnteredAndExited,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(brushTracking!);super.updateTrackingAreas()
    }
    override func mouseMoved(with event:NSEvent) { brushPointer = convert(event.locationInWindow,from:nil);needsDisplay = true }
    override func mouseExited(with event:NSEvent) { brushPointer = nil;needsDisplay = true }
    private var maskPath: [CGPoint] = []
    private var cropStart: CGPoint?
    private var cropAspect: Double?
    private var cropMoveOrigin: CGRect?
    /// Full-resolution pixel size of the image being cropped; the preview can be smaller.
    private var cropPixels: CGSize?
    /// Reports the crop frame's pixel size (nil before one is drawn) and the pixel size being cropped (nil outside the crop tool).
    var cropReport: ((CGSize?, CGSize?) -> Void)?
    func beginCrop(aspect:Double?, pixels:CGSize? = nil) {
        clearTool(); native = false; cropAspect = aspect
        cropPixels = pixels ?? logicalPixels ?? image.map{CGSize(width:$0.width,height:$0.height)}
        tool = .crop
        if let aspect {cropSelection = CropGeometry.centered(in:cropPixels ?? .zero,aspect:aspect)}
        needsDisplay = true
    }
    private(set) var cropSelection: CGRect? { didSet { reportCrop() } }
    private func reportCrop() {
        guard tool == .crop, let pixels = cropPixels else { cropReport?(nil,nil); return }
        cropReport?(cropSelection.map { let size = CropGeometry.pixelSize(of:$0,in:pixels); return CGSize(width:size.width,height:size.height) }, pixels)
    }
    private var brushPaths: [[CGPoint]] = []
    var brushWidth: CGFloat = 0.035
    func clearTool() { draggingSun = false; tool = .browse; maskOverlay = nil; maskPath = []; cropStart = nil; cropMoveOrigin = nil; cropSelection = nil; brushPaths = []; needsDisplay = true }
    private var logicalPixels:CGSize?
    func replaceRenderedImage(_ next: CGImage, pixelSize:CGSize? = nil) {
        let saved = offset
        let oldSize=logicalPixels ?? image.map{CGSize(width:$0.width,height:$0.height)}
        let sameSize = oldSize == (pixelSize ?? CGSize(width:next.width,height:next.height))
        image = next;logicalPixels=pixelSize
        if sameSize { offset = saved }
    }
    func removalMask(width: Int, height: Int) -> CGImage? {
        guard !brushPaths.isEmpty, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width), y: CGFloat(height))
        context.setStrokeColor(gray: 1, alpha: 1); context.setFillColor(gray: 1, alpha: 1)
        context.setLineWidth(brushWidth); context.setLineCap(.round); context.setLineJoin(.round)
        for path in brushPaths {
            guard let first = path.first else { continue }
            context.beginPath(); context.move(to: first)
            for point in path.dropFirst() { context.addLine(to: point) }
            context.strokePath()
            context.fillEllipse(in: CGRect(x: first.x-brushWidth/2, y: first.y-brushWidth/2, width: brushWidth, height: brushWidth))
        }
        return context.makeImage()
    }
    var image: CGImage? { didSet { logicalPixels=nil;offset = .zero; needsDisplay = true } }
    private(set) var isFit = true
    private var pixelScale: CGFloat = 1
    var native: Bool {
        get { !isFit && abs(pixelScale - 1) < 0.001 }
        set { isFit = !newValue; pixelScale = 1; offset = .zero; zoomDidChange() }
    }
    var zoomChanged: (() -> Void)?
    var viewportChanged: (() -> Void)?
    struct Viewport {var fit:Bool;var scale:CGFloat;var pan:CGPoint}
    var viewport:Viewport {Viewport(fit:isFit,scale:pixelScale,pan:CGPoint(x:offset.x/max(1,bounds.width),y:offset.y/max(1,bounds.height)))}
    func setViewport(_ state:Viewport){isFit=state.fit;pixelScale=state.scale;offset=CGPoint(x:state.pan.x*bounds.width,y:state.pan.y*bounds.height);needsDisplay=true;updateAccessibility()}

    var zoomPercent: Int { Int((effectiveScale * 100).rounded()) }
    var navigate: ((Int) -> Void)?
    var toggleZoom: (() -> Void)?
    var openURLs: (([URL]) -> Void)?
    var openPanel: (() -> Void)?
    var escape: (() -> Void)?
    var requestTrash: (() -> Void)?
    var photoMenu: (() -> NSMenu?)?
    var message = "" { didSet { needsDisplay = true } }
    private var offset = CGPoint.zero
    private var dragPoint: CGPoint?
    private var cursorPushed = false
    private var accumulatedScroll: CGFloat = 0
    private var lastNavigation: TimeInterval = 0
    private var gestureNavigated = false
    private var dragHighlight = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateAccessibility() {
        setAccessibilityLabel("Photo preview")
        if tool == .sun {
            setAccessibilityHelp("Sun center: \(Int((sunPosition.x*100).rounded())) percent across, \(Int((sunPosition.y*100).rounded())) percent up. Click or drag inside or outside the photograph. Arrow keys nudge; Shift moves farther. Escape finishes placement.")
            return
        }
        setAccessibilityHelp("\(isFit ? "Fit to window" : "\(zoomPercent) percent"). Pinch or scroll to zoom. Drag to pan. Arrow keys or Option-scroll change photo. Double click toggles Fit and 100 percent.")
    }

    private var photoSize: CGSize {
        guard let image else { return .zero }
        if isFit {
            return PhotoGeometry.displaySize(pixels: (logicalPixels ?? CGSize(width: image.width, height: image.height)),
                                             viewport: tool == .sun ? CGSize(width:max(1,bounds.width-144),height:max(1,bounds.height-144)) : bounds.size, backingScale: window?.backingScaleFactor ?? 2, native: false)
        }
        let backing = window?.backingScaleFactor ?? 2
        let pixels=logicalPixels ?? CGSize(width:image.width,height:image.height)
        return CGSize(width:pixels.width*pixelScale/backing,height:pixels.height*pixelScale/backing)
    }

    private var effectiveScale: CGFloat {
        guard let image else { return 1 }
        return photoSize.width * (window?.backingScaleFactor ?? 2) / (logicalPixels?.width ?? CGFloat(image.width))
    }
    private var imageRect: CGRect {
        let size = photoSize
        return CGRect(x: bounds.midX-size.width/2+offset.x, y: bounds.midY-size.height/2+offset.y, width: size.width, height: size.height)
    }
    private func normalizedPoint(_ event: NSEvent) -> CGPoint? {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(1, max(0, (point.x-rect.minX)/rect.width)), y: min(1, max(0, (point.y-rect.minY)/rect.height)))
    }
    private func moveSun(_ event:NSEvent, final:Bool) {
        let rect = imageRect
        guard image != nil, rect.width > 0, rect.height > 0 else {return}
        let point = convert(event.locationInWindow,from:nil)
        sunPosition = CGPoint(x:(point.x-rect.minX)/rect.width,y:(point.y-rect.minY)/rect.height)
        sunPlaced?(sunPosition,final)
    }
    private func zoomDidChange() {
        needsDisplay = true
        updateAccessibility()
        zoomChanged?();viewportChanged?()
    }
    func scale(by factor: CGFloat, around pointer: CGPoint? = nil) {
        guard image != nil, factor.isFinite, factor > 0 else { return }
        let oldSize = photoSize
        let newScale = min(16, max(0.01, effectiveScale * factor))
        isFit = false
        pixelScale = newScale
        let anchor = pointer ?? CGPoint(x: bounds.midX, y: bounds.midY)
        offset = PhotoGeometry.zoomOffset(offset, pointer: anchor, viewport: bounds.size,
                                          oldImage: oldSize, newImage: photoSize)
        zoomDidChange()
    }
    override func magnify(with event: NSEvent) {
        scale(by: max(0.1, 1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.055, alpha: 1).setFill()
        bounds.fill()
        if let image, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.clip(to: bounds)
            let size = photoSize
            offset = PhotoGeometry.clampedOffset(offset, image: size, viewport: bounds.size)
            let backing = window?.backingScaleFactor ?? 2
            let rect = CGRect(x: ((bounds.midX - size.width / 2 + offset.x) * backing).rounded() / backing,
                              y: ((bounds.midY - size.height / 2 + offset.y) * backing).rounded() / backing,
                              width: size.width, height: size.height)
            context.interpolationQuality = native && logicalPixels == nil ? .none : .high
            context.draw(image, in: rect)
            if let maskOverlay, !(tool == .maskLinear && maskPath.count > 1) { context.draw(maskOverlay, in: rect) }
            if let first = maskPath.first, let last = maskPath.last {
                let a = CGPoint(x:rect.minX+first.x*rect.width,y:rect.minY+first.y*rect.height)
                let b = CGPoint(x:rect.minX+last.x*rect.width,y:rect.minY+last.y*rect.height)
                context.saveGState(); context.clip(to:rect)
                context.setStrokeColor((tool == .retouch ? NSColor.white:NSColor.systemRed).withAlphaComponent(0.65).cgColor)
                context.setLineWidth((tool == .maskBrush || tool == .retouch) ? maskRadius*2*min(rect.width,rect.height) : 1.5)
                context.setLineCap(.round); context.setLineJoin(.round)
                if tool == .maskLinear, hypot(b.x-a.x,b.y-a.y) > 0.5 {
                    let (low,high) = AdjustmentMask.linearEndpoints(start:a,end:b,feather:maskFeather)
                    let clear = CGColor(srgbRed:1,green:0.08,blue:0.08,alpha:0)
                    let red = CGColor(srgbRed:1,green:0.08,blue:0.08,alpha:0.42)
                    let colors = maskInverted ? [red,clear] : [clear,red]
                    if let gradient = CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:colors as CFArray,locations:[0,1]) {
                        context.drawLinearGradient(gradient,start:low,end:high,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
                    }
                    // Boundaries show the fade width, with the center at half strength.
                    let length = hypot(high.x-low.x,high.y-low.y)
                    let normal = CGPoint(x:-(high.y-low.y)/length,y:(high.x-low.x)/length)
                    let span = hypot(rect.width,rect.height)
                    context.setStrokeColor(NSColor.white.withAlphaComponent(0.75).cgColor);context.setLineWidth(0.8)
                    for t in [0.0,0.5,1.0] {
                        let point = CGPoint(x:low.x+(high.x-low.x)*t,y:low.y+(high.y-low.y)*t)
                        context.setLineDash(phase:0,lengths:t == 0.5 ? [4,4] : [])
                        context.move(to:CGPoint(x:point.x-normal.x*span,y:point.y-normal.y*span))
                        context.addLine(to:CGPoint(x:point.x+normal.x*span,y:point.y+normal.y*span));context.strokePath()
                    }
                    context.setLineDash(phase:0,lengths:[])
                    context.move(to:a);context.addLine(to:b);context.strokePath()
                    for point in [a,b] { context.setFillColor(NSColor.white.cgColor);context.fillEllipse(in:CGRect(x:point.x-3,y:point.y-3,width:6,height:6)) }
                } else if tool == .maskRadial {
                    context.strokeEllipse(in:CGRect(x:a.x-abs(b.x-a.x),y:a.y-abs(b.y-a.y),width:abs(b.x-a.x)*2,height:abs(b.y-a.y)*2))
                } else {
                    context.beginPath(); context.move(to:a)
                    for p in maskPath.dropFirst() { context.addLine(to:CGPoint(x:rect.minX+p.x*rect.width,y:rect.minY+p.y*rect.height)) }
                    if maskPath.count == 1 { context.addLine(to:CGPoint(x:a.x+0.1,y:a.y)) }
                    context.strokePath()
                }
                context.restoreGState()
            }
            if (tool == .maskBrush || tool == .retouch), let pointer = brushPointer, rect.contains(pointer) {
                let radius = maskRadius*min(rect.width,rect.height)
                context.setStrokeColor((tool == .retouch ? NSColor.white:NSColor.systemRed).cgColor);context.setLineWidth(1.5)
                context.strokeEllipse(in:CGRect(x:pointer.x-radius,y:pointer.y-radius,width:radius*2,height:radius*2))
                let inner = radius*(1-maskSoftness);context.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor);context.setLineWidth(0.7)
                context.strokeEllipse(in:CGRect(x:pointer.x-inner,y:pointer.y-inner,width:inner*2,height:inner*2))
                context.move(to:CGPoint(x:pointer.x-3,y:pointer.y));context.addLine(to:CGPoint(x:pointer.x+3,y:pointer.y))
                if !maskSubtract { context.move(to:CGPoint(x:pointer.x,y:pointer.y-3));context.addLine(to:CGPoint(x:pointer.x,y:pointer.y+3)) };context.strokePath()
            }
            if (tool == .retouch || tool == .retouchSource),let source=retouchSource {
                let p=CGPoint(x:rect.minX+source.x*rect.width,y:rect.minY+source.y*rect.height)
                context.setStrokeColor(NSColor.white.cgColor);context.setLineWidth(1)
                context.strokeEllipse(in:CGRect(x:p.x-6,y:p.y-6,width:12,height:12))
                context.move(to:CGPoint(x:p.x-10,y:p.y));context.addLine(to:CGPoint(x:p.x+10,y:p.y));context.move(to:CGPoint(x:p.x,y:p.y-10));context.addLine(to:CGPoint(x:p.x,y:p.y+10));context.strokePath()
            }
            if let crop = cropSelection, tool == .crop {
                let selection = CGRect(x: rect.minX+crop.minX*rect.width, y: rect.minY+crop.minY*rect.height, width: crop.width*rect.width, height: crop.height*rect.height)
                context.setStrokeColor(Appearance.accent.cgColor); context.setLineWidth(1.5); context.stroke(selection)
                context.setFillColor(NSColor.white.cgColor)
                for x in [selection.minX,selection.maxX] {for y in [selection.minY,selection.maxY] {context.fillEllipse(in:CGRect(x:x-3,y:y-3,width:6,height:6))}}
                context.setLineWidth(0.5)
                for fraction in [CGFloat(1.0/3), CGFloat(2.0/3)] {
                    context.move(to: CGPoint(x: selection.minX+selection.width*fraction, y: selection.minY)); context.addLine(to: CGPoint(x: selection.minX+selection.width*fraction,y:selection.maxY))
                    context.move(to: CGPoint(x:selection.minX,y:selection.minY+selection.height*fraction)); context.addLine(to: CGPoint(x:selection.maxX,y:selection.minY+selection.height*fraction)); context.strokePath()
                }
                if let pixels = cropPixels { drawCropLabel(crop, pixels:pixels, frame:selection) }
            }
            if tool == .erase {
                context.saveGState(); context.translateBy(x: rect.minX, y: rect.minY); context.scaleBy(x: rect.width, y: rect.height)
                context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.55).cgColor); context.setFillColor(NSColor.systemRed.withAlphaComponent(0.55).cgColor)
                context.setLineWidth(brushWidth); context.setLineCap(.round); context.setLineJoin(.round)
                for path in brushPaths {
                    guard let first = path.first else { continue }
                    context.beginPath(); context.move(to: first); for p in path.dropFirst() { context.addLine(to: p) }; context.strokePath()
                    context.fillEllipse(in: CGRect(x: first.x-brushWidth/2,y:first.y-brushWidth/2,width:brushWidth,height:brushWidth))
                }
                context.restoreGState()
            }
            context.restoreGState()
        }
        if tool == .sun, image != nil {
            let rect = imageRect
            NSColor.white.withAlphaComponent(0.25).setStroke()
            NSBezierPath(rect:rect).stroke()
            let actual = CGPoint(x:rect.minX+sunPosition.x*rect.width,y:rect.minY+sunPosition.y*rect.height)
            let p = CGPoint(x:min(bounds.maxX-18,max(18,actual.x)),y:min(bounds.maxY-18,max(18,actual.y)))
            let ring = NSBezierPath(ovalIn:CGRect(x:p.x-11,y:p.y-11,width:22,height:22))
            NSColor.black.withAlphaComponent(0.65).setFill(); ring.fill()
            NSColor.white.setStroke(); ring.lineWidth = 1.2; ring.stroke()
            let cross = NSBezierPath()
            cross.move(to:CGPoint(x:p.x-16,y:p.y)); cross.line(to:CGPoint(x:p.x+16,y:p.y))
            cross.move(to:CGPoint(x:p.x,y:p.y-16)); cross.line(to:CGPoint(x:p.x,y:p.y+16)); cross.lineWidth = 1; cross.stroke()
            let text = rect.contains(actual) ? "Sun center · Drag to move" : "Sun center · Outside photo"
            (text as NSString).draw(at:CGPoint(x:min(bounds.maxX-180,max(12,p.x-75)),y:max(10,p.y-32)),withAttributes:[.font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.white,.backgroundColor:NSColor.black.withAlphaComponent(0.65)])
        }
        if !message.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style
            ]
            (message as NSString).draw(in: NSRect(x: 30, y: bounds.midY - 35, width: bounds.width - 60, height: 70), withAttributes: attributes)
        }
        if dragHighlight {
            Appearance.accent.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 12, yRadius: 12)
            border.lineWidth = 3
            border.stroke()
        }
    }

    /// Aspect ratio and pixel size badge, inside the top edge of the frame (above it when the frame is short).
    private func drawCropLabel(_ crop:CGRect, pixels:CGSize, frame:CGRect) {
        let size = CropGeometry.pixelSize(of:crop,in:pixels)
        let text = (CropGeometry.ratioLabel(width:Double(size.width),height:Double(size.height)) + "  ·  \(size.width) × \(size.height)") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:11,weight:.semibold),.foregroundColor:NSColor.white]
        let textSize = text.size(withAttributes:attributes)
        var badge = CGRect(x:frame.midX-textSize.width/2-7,y:frame.maxY-textSize.height-12,width:textSize.width+14,height:textSize.height+6)
        if frame.height < badge.height*2+12 { badge.origin.y = frame.maxY+6 }
        badge.origin.x = min(bounds.maxX-badge.width-4,max(bounds.minX+4,badge.minX))
        badge.origin.y = min(bounds.maxY-badge.height-4,max(bounds.minY+4,badge.minY))
        NSColor.black.withAlphaComponent(0.65).setFill(); NSBezierPath(roundedRect:badge,xRadius:5,yRadius:5).fill()
        text.draw(at:CGPoint(x:badge.minX+7,y:badge.minY+3),withAttributes:attributes)
    }

    override func viewDidChangeBackingProperties() { needsDisplay = true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if tool == .sun, image != nil { draggingSun = true; moveSun(event,final:false); return }
        if tool != .browse && !imageRect.contains(convert(event.locationInWindow,from:nil)) { return }
        if tool != .browse, let point = normalizedPoint(event) {
            switch tool {
            case .crop:
                cropStart = point; cropMoveOrigin = nil
                if let selection = cropSelection {
                    let corners = [CGPoint(x:selection.minX,y:selection.minY),CGPoint(x:selection.maxX,y:selection.minY),CGPoint(x:selection.minX,y:selection.maxY),CGPoint(x:selection.maxX,y:selection.maxY)]
                    if let corner = corners.first(where:{hypot(($0.x-point.x)*imageRect.width,($0.y-point.y)*imageRect.height)<12}) {
                        cropStart = CGPoint(x:abs(corner.x-selection.minX)<0.0001 ? selection.maxX:selection.minX,y:abs(corner.y-selection.minY)<0.0001 ? selection.maxY:selection.minY)
                    } else if selection.contains(point) {cropMoveOrigin = selection}
                    else {cropSelection = nil}
                }
            case .erase: brushPaths.append([point])
            case .sun: break
            case .maskBrush, .maskLinear, .maskRadial: maskPath = [point]
            case .retouchSource:retouchSourceChosen?(point)
            case .retouch:if event.modifierFlags.contains(.option){retouchSourceChosen?(point)}else{maskPath=[point]}
            case .maskObject: objectChosen?(point)
            case .maskRange: rangeChosen?(point)
            case .whiteBalance: whiteBalanceChosen?(point)
            case .browse: break
            }
            needsDisplay = true; return
        }
        if event.clickCount == 2, image != nil { toggleZoom?(); return }
        dragPoint = convert(event.locationInWindow, from: nil)
        if image != nil { NSCursor.closedHand.push(); cursorPushed = true }
    }
    override func mouseDragged(with event: NSEvent) {
        if tool == .sun, draggingSun { moveSun(event,final:false); return }
        brushPointer = convert(event.locationInWindow,from:nil)
        if tool != .browse, let point = normalizedPoint(event) {
            if tool == .crop, let start = cropStart {
                if let origin = cropMoveOrigin {cropSelection = CropGeometry.moving(origin,by:CGPoint(x:point.x-start.x,y:point.y-start.y))}
                else {cropSelection = CropGeometry.rectangle(from:start,to:point,in:photoSize,aspect:cropAspect)}
            }
            if tool == .maskBrush || tool == .retouch { maskPath.append(point) }
            if (tool == .maskLinear || tool == .maskRadial), let first = maskPath.first { maskPath = [first,point] }
            if tool == .erase, !brushPaths.isEmpty { brushPaths[brushPaths.count-1].append(point) }
            needsDisplay = true; return
        }
        guard image != nil, let previous = dragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        offset.x += point.x - previous.x
        offset.y += point.y - previous.y
        dragPoint = point
        needsDisplay = true;viewportChanged?()
    }
    override func mouseUp(with event: NSEvent) {
        if tool == .crop {cropStart = nil; cropMoveOrigin = nil; return}
        if tool == .sun, draggingSun { draggingSun = false; moveSun(event,final:true); return }
        if !maskPath.isEmpty {
            let kind = tool == .maskBrush ? "brush" : (tool == .maskLinear ? "linear" : "radial")
            let points = maskPath; maskPath = []; if tool == .retouch {retouchDrawn?(points)}else{maskDrawn?(points,kind)}; needsDisplay = true
        }
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        dragPoint = nil
    }
    override func scrollWheel(with event: NSEvent) {
        if !event.modifierFlags.contains(.option), image != nil {
            guard event.momentumPhase.isEmpty else { return }
            let delta = event.scrollingDeltaY
            let amount = event.hasPreciseScrollingDeltas ? 0.008 : 0.12
            scale(by: exp(delta * amount), around: convert(event.locationInWindow, from: nil))
            return
        }
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) { accumulatedScroll = 0; gestureNavigated = false }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { accumulatedScroll = 0; return }
        if !event.phase.isEmpty && gestureNavigated { return }
        let raw = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        let delta = event.isDirectionInvertedFromDevice ? raw : -raw
        if event.timestamp - lastNavigation > 0.5 { accumulatedScroll = 0 }
        accumulatedScroll += delta
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 30 : 1
        if abs(accumulatedScroll) >= threshold && event.timestamp - lastNavigation > 0.22 {
            navigate?(accumulatedScroll > 0 ? 1 : -1)
            accumulatedScroll = 0
            gestureNavigated = true
            lastNavigation = event.timestamp
        }
    }
    override func keyDown(with event: NSEvent) {
        if tool == .sun, [123,124,125,126].contains(event.keyCode) {
            let step = event.modifierFlags.contains(.shift) ? 0.02 : 0.002
            if event.keyCode == 123 { sunPosition.x -= step }
            if event.keyCode == 124 { sunPosition.x += step }
            if event.keyCode == 125 { sunPosition.y -= step }
            if event.keyCode == 126 { sunPosition.y += step }
            sunPlaced?(sunPosition,true); return
        }
        if tool == .maskBrush, let key = event.charactersIgnoringModifiers, ["[","]"].contains(key) { resizeMaskBrush?(key == "[" ? -1 : 1);return }
        switch event.keyCode {
        case 51, 117:
            if !event.isARepeat { requestTrash?() }
        case 123, 126: navigate?(-1)
        case 124, 125, 49: navigate?(event.modifierFlags.contains(.shift) ? -1 : 1)
        case 53: escape?()
        default: super.keyDown(with: event)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? { photoMenu?() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragHighlight = true; needsDisplay = true; return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dragHighlight = false; needsDisplay = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragHighlight = false; needsDisplay = true
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        openURLs?(urls)
        return true
    }
}
