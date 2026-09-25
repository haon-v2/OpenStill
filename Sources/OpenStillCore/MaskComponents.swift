import Foundation
import CoreImage

public enum MaskCombination:String,Codable,CaseIterable { case add,subtract,intersect }
public struct MaskComponent:Codable,Equatable,Identifiable {
    public var id=UUID()
    public var name:String
    public var visible=true
    public var opacity=1.0
    public var operation:MaskCombination = .add
    public var selection:AdjustmentMask
    public init(name:String,selection:AdjustmentMask){self.name=name;self.selection=selection}
    public func independentCopy()->Self {var copy=self;copy.id=UUID();copy.name += " copy";return copy}
}
public struct RangeSelection:Codable,Equatable {
    public var red=1.0,green=0.0,blue=0.0
    public var tolerance=0.15,softness=0.15,low=0.25,high=0.75
    public init(){}
    public var sanitized:Self {
        var s=self
        func clamp(_ x:Double,_ fallback:Double)->Double{x.isFinite ? min(1,max(0,x)):fallback}
        s.red=clamp(red,1);s.green=clamp(green,0);s.blue=clamp(blue,0);s.tolerance=clamp(tolerance,0.15);s.softness=clamp(softness,0.15)
        s.low=clamp(min(low,high),0.25);s.high=clamp(max(low,high),0.75);return s
    }
}
extension AdjustmentMask {
    public static let legacyComponentID=UUID(uuidString:"268FAD3F-5011-4720-9ADF-25475B9C78BA")!
    public var namedComponents:[MaskComponent] {
        if let components{return components}
        var selection=self;selection.components=nil
        var component=MaskComponent(name:"Mask 1",selection:selection);component.id=Self.legacyComponentID;return [component]
    }
    public func independentCopy()->Self {
        var copy=self;copy.components=namedComponents.map{$0.independentCopy()};copy.kind="stack"
        // Legacy inversion already belongs to its single component.
        if components == nil {copy.inverted=false}
        return copy
    }
    public func component(_ id:UUID?)->MaskComponent? {namedComponents.first{$0.id==id} ?? namedComponents.first}
    public mutating func updateComponent(_ component:MaskComponent){
        let legacy=components == nil
        var list=namedComponents
        if let i=list.firstIndex(where:{$0.id==component.id}){list[i]=component}else{list.append(component)}
        components=list;kind="stack";strokes=[];if legacy{inverted=false}
    }
    public mutating func replaceComponents(_ list:[MaskComponent]) {
        let legacy=components == nil;components=list;kind="stack";strokes=[];if legacy{inverted=false}
    }
    /// Range coverage samples the tool's incoming image; geometric selections
    /// travel through the same optical and crop transforms as the photograph.
    public func coverage(geometry:EditGeometry,lens:LensSettings,input:CIImage,modern:Bool)throws->CIImage {
        let bounds=geometry.extent
        let black=CIImage(color:.black).cropped(to:bounds)
        var result:CIImage
        if let components {
            result=black
            var first=true
            for component in components where component.visible {
                let coverage=try component.selection.coverage(geometry:geometry,lens:lens,input:input,modern:modern)
                let opacity=component.opacity.isFinite ? min(1,max(0,component.opacity)):1
                let mode=component.operation == .add ? 0.0:(component.operation == .subtract ? 1.0:2.0)
                // Starting with an intersection gives that component's coverage.
                let prior=first && component.operation == .intersect ? CIImage(color:.white).cropped(to:bounds):result
                guard let combined=MaskComponents.combine?.apply(extent:bounds,arguments:[prior,coverage,opacity,mode]) else {throw EditError.render}
                result=combined;first=false
            }
        } else if kind == "colorRange" || kind == "luminanceRange" {
            let range=(range ?? RangeSelection()).sanitized
            let space=CGColorSpace(name:CGColorSpace.extendedSRGB)!
            guard let rgb=input.matchedFromWorkingSpace(to:space),let coverage=MaskComponents.range?.apply(extent:bounds,arguments:[rgb,CIVector(x:range.red,y:range.green,z:range.blue),range.tolerance,range.softness,range.low,range.high,kind == "colorRange" ? 0.0:1.0]) else {throw EditError.render}
            result=coverage
            if feather > 0 {result=result.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:min(bounds.width,bounds.height)*max(0,min(1,feather))*0.012]).cropped(to:bounds)}
            for stroke in strokes {
                var brush=AdjustmentMask();brush.feather=0;var add=stroke;add.subtract=false;brush.strokes=[add]
                let painted=geometry.apply(try LensCorrections.apply(brush.image(size:geometry.sourceSize),settings:modern ? lens:LensSettings(),mask:true))
                let color=CIImage(color:stroke.subtract ? .black:.white).cropped(to:bounds)
                result=color.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:result,kCIInputMaskImageKey:painted])
            }
        } else {
            // Legacy shape inversion remains in image(size:), preserving coverage.
            let source=try image(size:geometry.sourceSize)
            return geometry.apply(modern ? try LensCorrections.apply(source,settings:lens,mask:true):source)
        }
        if inverted {result=result.applyingFilter("CIColorInvert")}
        return result.cropped(to:bounds)
    }
}
private enum MaskComponents {
    static let combine=CIColorKernel(source:"""
    kernel vec4 combineCoverage(__sample prior,__sample selection,float opacity,float mode) {
        float a=clamp(prior.r,0.0,1.0),b=clamp(selection.r,0.0,1.0)*opacity;
        float value=mode<0.5 ? max(a,b):(mode<1.5 ? a*(1.0-b):a*b);
        return vec4(value,value,value,1.0);
    }
    """)
    static let range=CIColorKernel(source:"""
    kernel vec4 rangeCoverage(__sample pixel,vec3 target,float tolerance,float softness,float low,float high,float mode) {
        vec3 rgb=clamp(unpremultiply(pixel).rgb,0.0,1.0);
        float value;
        float feather=max(0.0001,softness);
        if(mode<0.5) {
            // RGB distance also separates neutral colors; no hue discontinuity at red.
            float distance=length(rgb-target)/1.7320508;
            value=1.0-smoothstep(tolerance,tolerance+feather,distance);
        } else {
            float light=dot(rgb,vec3(0.2126,0.7152,0.0722));
            value=smoothstep(low-feather,low,light)*(1.0-smoothstep(high,high+feather,light));
        }
        return vec4(value,value,value,1.0);
    }
    """)
}
