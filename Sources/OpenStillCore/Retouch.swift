import Foundation
import CoreImage

public enum RetouchMode:String,Codable,CaseIterable {case heal,clone}
public struct RetouchStroke:Codable,Equatable,Identifiable {
    public var id=UUID()
    public var mode:RetouchMode
    public var source:MaskPoint
    public var destination:MaskPoint
    public var points:[MaskPoint]
    public var radius:Double,feather:Double,opacity:Double
    public init(mode:RetouchMode,source:CGPoint,destination:CGPoint,points:[CGPoint],radius:Double,feather:Double,opacity:Double){
        self.mode=mode;self.source=MaskPoint(source);self.destination=MaskPoint(destination);self.points=points.map(MaskPoint.init);self.radius=radius;self.feather=feather;self.opacity=opacity
    }
    public var sanitized:Self {
        var s=self
        func clamp(_ v:Double,_ low:Double,_ high:Double,_ fallback:Double)->Double{v.isFinite ? min(high,max(low,v)):fallback}
        s.radius=clamp(radius,0.0001,0.5,0.025);s.feather=clamp(feather,0,1,0.5);s.opacity=clamp(opacity,0,1,1)
        func point(_ p:MaskPoint)->MaskPoint{MaskPoint(CGPoint(x:clamp(p.x,0,1,0.5),y:clamp(p.y,0,1,0.5)))}
        s.source=MaskPoint(CGPoint(x:clamp(source.x,-2,3,0.5),y:clamp(source.y,-2,3,0.5)));s.destination=point(destination);s.points=points.map(point);return s
    }
}
/// UI-only sampling state. Aligned strokes keep one offset until a new source is chosen.
public struct RetouchSession {
    public var mode:RetouchMode = .heal
    public var radius=0.025,feather=0.5,opacity=1.0
    public var aligned=true {didSet{if oldValue != aligned{offset=nil}}}
    public private(set) var source:CGPoint?
    private var offset:CGPoint?
    public init(){}
    public mutating func setSource(_ point:CGPoint){source=point;offset=nil}
    public mutating func reset(){source=nil;offset=nil}
    public mutating func stroke(points:[CGPoint],radius:Double)->RetouchStroke? {
        guard let first=points.first,let source else{return nil}
        let sampled:CGPoint
        if aligned,let offset{sampled=CGPoint(x:first.x+offset.x,y:first.y+offset.y)}
        else{sampled=source;if aligned{offset=CGPoint(x:source.x-first.x,y:source.y-first.y)}}
        return RetouchStroke(mode:mode,source:sampled,destination:first,points:points,radius:radius,feather:feather,opacity:opacity)
    }
}
extension PhotoEdits {
    public var retouch:[RetouchStroke] {
        get{advanced?.retouch ?? []}
        set{ensureAdvanced();advanced!.retouch=newValue.isEmpty ? nil:newValue.map(\.sanitized)}
    }
}
public enum Retouch {
    private static let heal=CIColorKernel(source:"""
    kernel vec4 healTexture(__sample source,__sample sourceTone,__sample targetTone) {
        vec4 s=unpremultiply(source),a=unpremultiply(sourceTone),b=unpremultiply(targetTone);
        return premultiply(vec4(s.rgb-a.rgb+b.rgb,s.a));
    }
    """)
    public static func apply(_ image:CIImage,strokes:[RetouchStroke])throws->CIImage {
        var output=image
        let bounds=image.extent,size=bounds.size
        for stroke in strokes.map(\.sanitized) where !stroke.points.isEmpty && stroke.opacity > 0 {
            let before=output
            let dx=(stroke.destination.x-stroke.source.x)*size.width,dy=(stroke.destination.y-stroke.source.y)*size.height
            let translation=CGAffineTransform(translationX:dx,y:dy)
            let source=before.clampedToExtent().transformed(by:translation).cropped(to:bounds)
            let effect:CIImage
            if stroke.mode == .heal {
                let radius=max(1,stroke.radius*min(size.width,size.height)*0.7)
                let tone=before.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius])
                let sourceTone=tone.transformed(by:translation).cropped(to:bounds)
                guard let healed=heal?.apply(extent:bounds,arguments:[source,sourceTone,tone.cropped(to:bounds)])else{throw EditError.render}
                effect=healed
            }else{effect=source}
            var shape=AdjustmentMask();shape.feather=0
            var brush=MaskStroke(points:stroke.points,radius:stroke.radius);brush.softness=stroke.feather;brush.strength=stroke.opacity;shape.strokes=[brush]
            let mask=try shape.image(size:size)
            output=effect.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:before,kCIInputMaskImageKey:mask]).cropped(to:bounds)
        }
        return output
    }
}
