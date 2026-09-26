import Foundation
import CoreImage

public struct MaskPoint: Codable, Equatable {
    public var x: Double; public var y: Double
    public init(_ p: CGPoint) { x = p.x; y = p.y }
    public var point: CGPoint { CGPoint(x:x,y:y) }
}
public struct MaskStroke: Codable, Equatable {
    public var points: [MaskPoint]
    public var radius: Double
    public var subtract: Bool
    public var softness: Double?
    public var strength: Double?
    public init(points: [MaskPoint], radius: Double, subtract: Bool = false) { self.points = points; self.radius = radius; self.subtract = subtract }
}
public struct AdjustmentMask: Codable, Equatable {
    public var components: [MaskComponent]?
    public var range: RangeSelection?
    public var kind = "brush"
    public var strokes: [MaskStroke] = []
    public var start = MaskPoint(CGPoint(x:0.25,y:0.5))
    public var end = MaskPoint(CGPoint(x:0.75,y:0.5))
    public var asset: String?
    public var feather = 0.3
    public var inverted = false
    public init(kind: String = "brush") { self.kind = kind; if kind == "linear" { feather = 1 } }
    /// Shared by the rendered mask and its live canvas preview.
    public static func linearEndpoints(start: CGPoint, end: CGPoint, feather: Double) -> (CGPoint, CGPoint) {
        let mid = CGPoint(x:(start.x+end.x)/2,y:(start.y+end.y)/2)
        let f = max(0.01,min(1,feather))
        return (CGPoint(x:mid.x+(start.x-mid.x)*f,y:mid.y+(start.y-mid.y)*f),
                CGPoint(x:mid.x+(end.x-mid.x)*f,y:mid.y+(end.y-mid.y)*f))
    }
    public func image(size: CGSize) throws -> CIImage {
        let bounds = CGRect(origin:.zero,size:size)
        let black = CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:bounds)
        var mask: CIImage
        switch kind {
        case "linear":
            let a = CGPoint(x:start.x*size.width,y:start.y*size.height), b = CGPoint(x:end.x*size.width,y:end.y*size.height)
            let (low,high) = Self.linearEndpoints(start:a,end:b,feather:feather)
            mask = CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(cgPoint:low),"inputPoint1":CIVector(cgPoint:high),"inputColor0":CIColor(red:0,green:0,blue:0),"inputColor1":CIColor(red:1,green:1,blue:1)])!.outputImage!.cropped(to:bounds)
        case "radial":
            let center = CGPoint(x:start.x*size.width,y:start.y*size.height)
            let rx = max(1,abs(end.x-start.x)*size.width), ry = max(1,abs(end.y-start.y)*size.height)
            mask = CIFilter(name:"CIRadialGradient",parameters:["inputCenter":CIVector(x:0,y:0),"inputRadius0":max(0,1-feather),"inputRadius1":1,"inputColor0":CIColor(red:1,green:1,blue:1),"inputColor1":CIColor(red:0,green:0,blue:0)])!.outputImage!
                .transformed(by:CGAffineTransform(scaleX:rx,y:ry).concatenating(CGAffineTransform(translationX:center.x,y:center.y))).cropped(to:bounds)
        case "object", "depthMap":
            guard let asset else { mask=black; break }
            // Depth maps are data, not pictures: read their values without color management.
            let decoded = try PhotoDecoder.decode(EditStorage.asset(asset))
            mask = kind == "depthMap" ? CIImage(cgImage:decoded,options:[.colorSpace:NSNull()]) : CIImage(cgImage:decoded)
            mask = mask.transformed(by:CGAffineTransform(scaleX:size.width/mask.extent.width,y:size.height/mask.extent.height)).cropped(to:bounds)
        default: mask = black
        }
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            let w = max(1,Int(size.width)), h = max(1,Int(size.height))
            guard let ctx = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { throw EditError.render }
            ctx.setFillColor(gray:0,alpha:1);ctx.fill(bounds)
            let r = max(1,stroke.radius*min(size.width,size.height))
            ctx.setStrokeColor(gray:1,alpha:1);ctx.setFillColor(gray:1,alpha:1);ctx.setLineWidth(r*2);ctx.setLineCap(.round);ctx.setLineJoin(.round)
            ctx.beginPath();ctx.move(to:CGPoint(x:first.x*size.width,y:first.y*size.height))
            for p in stroke.points.dropFirst() { ctx.addLine(to:CGPoint(x:p.x*size.width,y:p.y*size.height)) };ctx.strokePath()
            ctx.fillEllipse(in:CGRect(x:first.x*size.width-r,y:first.y*size.height-r,width:r*2,height:r*2))
            guard let cg = ctx.makeImage() else { throw EditError.render }
            var coverage = CIImage(cgImage:cg)
            if let softness = stroke.softness, softness > 0 { coverage = coverage.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:r*min(1,softness)*0.45]).cropped(to:bounds) }
            let strength = min(1,max(0,stroke.strength ?? 1))
            coverage = coverage.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:strength,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:strength,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:strength,w:0)])
            let value = stroke.subtract ? 0.0 : 1.0
            mask = CIImage(color:CIColor(red:value,green:value,blue:value)).cropped(to:bounds).applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:mask,kCIInputMaskImageKey:coverage])
        }
        if feather > 0 && (kind == "brush" || kind == "object") {
            mask = mask.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:feather*min(size.width,size.height)*0.012]).cropped(to:bounds)
        }
        if inverted { mask = mask.applyingFilter("CIColorInvert") }
        return mask.composited(over:black).cropped(to:bounds)
    }
}

public struct ColorBand: Codable, Equatable {
    public var hue = 0.0; public var saturation = 0.0
    public var lightness: Double?
    public var displayMode: String?
    public init() {}
}
public struct AdvancedEdits: Codable, Equatable {
    public var lens: LensSettings?
    public var retouch: [RetouchStroke]?
    public var curves: ToneCurves?
    public var neutralBalance: NeutralBalance?
    public var rawWhiteBalance: [Float]?
    public var rawRecovery:Int?
    public var glow: GlowSettings?
    public var sunSettings: SunraysSettings?
    public var monochrome = 0.0, blacks = 0.0, whites = 0.0, straighten = 0.0
    public var colors = [ColorBand](repeating:ColorBand(),count:8)
    public var masks: [String:AdjustmentMask] = [:]
    public var lutAsset: String?
    public var lutName: String?
    public var lutID: String?
    public var lutAmount = 1.0
    public var sunLength = 0.4
    public var aiBackgroundAsset: String?
    public var aiFeatureKey: String?
    public var clarity: Double?
    public var texture: Double?
    public var dehaze: Double?
    public var colorGrading: ColorGrading?
    public var grain: GrainSettings?
    public var defringe: DefringeSettings?
    public var transform: TransformSettings?
    public var profile: ProfileSettings?
    public var calibration: CalibrationSettings?
    public var rawOptions: RawOptions?
    public var lensBlur: LensBlurSettings?
    public var rawDenoise: RawDenoiseBase?
    public init() {}
}

/// Maps original pixel coordinates into the oriented, straightened and cropped canvas.
public struct EditGeometry {
    public let transform: CGAffineTransform
    public let extent: CGRect
    public let sourceSize: CGSize
    public init(size: CGSize, edits: PhotoEdits) {
        sourceSize = size
        let rotations: [CGAffineTransform] = [.identity, CGAffineTransform(a:0,b:-1,c:1,d:0,tx:0,ty:size.width), CGAffineTransform(a:-1,b:0,c:0,d:-1,tx:size.width,ty:size.height), CGAffineTransform(a:0,b:1,c:-1,d:0,tx:size.height,ty:0)]
        let turn = ((edits.rotation%4)+4)%4
        var t = rotations[turn]
        let s = turn%2 == 0 ? size : CGSize(width:size.height,height:size.width)
        if edits.flip { t = t.concatenating(CGAffineTransform(a:-1,b:0,c:0,d:1,tx:s.width,ty:0)) }
        let a = edits.straighten * .pi/180
        if a != 0 {
            // Scale enough to keep every output corner inside the rotated source.
            let scale = max(abs(cos(a))+s.height/s.width*abs(sin(a)),abs(cos(a))+s.width/s.height*abs(sin(a)))
            let correction = CGAffineTransform(translationX:-s.width/2,y:-s.height/2).concatenating(CGAffineTransform(rotationAngle:a)).concatenating(CGAffineTransform(scaleX:scale,y:scale)).concatenating(CGAffineTransform(translationX:s.width/2,y:s.height/2))
            t = t.concatenating(correction)
        }
        let full = CGRect(origin:.zero,size:s)
        let crop = (edits.crop?.rect ?? CGRect(x:0,y:0,width:1,height:1)).intersection(CGRect(x:0,y:0,width:1,height:1))
        let r = crop.isNull ? CGRect.zero : CGRect(x:crop.minX*s.width,y:crop.minY*s.height,width:crop.width*s.width,height:crop.height*s.height).integral.intersection(full)
        transform = t.concatenating(CGAffineTransform(translationX:-r.minX,y:-r.minY))
        extent = CGRect(origin:.zero,size:r.size)
    }
    public func apply(_ image: CIImage) -> CIImage { image.transformed(by:transform).cropped(to:extent) }
    public func sourcePoint(_ displayed: CGPoint) -> CGPoint {
        let p = CGPoint(x:displayed.x*extent.width,y:displayed.y*extent.height).applying(transform.inverted())
        return CGPoint(x:min(1,max(0,p.x/sourceSize.width)),y:min(1,max(0,p.y/sourceSize.height)))
    }
}
