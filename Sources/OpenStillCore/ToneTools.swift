import Foundation
import CoreImage

public struct ToneCurves: Codable, Equatable {
    public static let identity = [0.0,0.25,0.5,0.75,1.0]
    public var master = identity, red = identity, green = identity, blue = identity
    public init() {}
    public var isIdentity: Bool { self == ToneCurves() }
    /// The same monotonic cubic interpolation used by the image kernel.
    public static func value(at x: Double, points: [Double]) -> Double {
        guard points.count == 5 else { return x }
        if x < 0 { return points[0]+x*4*(points[1]-points[0]) }
        if x > 1 { return points[4]+(x-1)*4*(points[4]-points[3]) }
        let i = min(3,max(0,Int(floor(x*4)))), p = points[i], q = points[i+1]
        let previous = i == 0 ? 2*p-q : points[i-1]
        let next = i == 3 ? 2*q-p : points[i+2]
        let d = q-p, sign = d < 0 ? -1.0 : 1.0, t = x*4-Double(i)
        let m0 = d == 0 ? 0 : sign*min(3*abs(d),max(0,sign*0.5*(q-previous)))
        let m1 = d == 0 ? 0 : sign*min(3*abs(d),max(0,sign*0.5*(next-p)))
        return (2*t*t*t-3*t*t+1)*p+(t*t*t-2*t*t+t)*m0+(-2*t*t*t+3*t*t)*q+(t*t*t-t*t)*m1
    }
    public var sanitized: ToneCurves {
        var s = self
        func clean(_ points:[Double]) -> [Double] {
            guard points.count == 5 else { return Self.identity }
            return points.enumerated().map { $0.element.isFinite ? min(1,max(0,$0.element)) : Self.identity[$0.offset] }
        }
        s.master = clean(master); s.red = clean(red); s.green = clean(green); s.blue = clean(blue); return s
    }
}
public struct NeutralBalance: Codable, Equatable {
    public var red = 1.0, green = 1.0, blue = 1.0
    public init(red:Double = 1, green:Double = 1, blue:Double = 1) { self.red = red; self.green = green; self.blue = blue }
    public var gains: [Double] { [red,green,blue].map { $0.isFinite ? min(8,max(0.125,$0)) : 1 } }
}
extension PhotoEdits {
    public var curves: ToneCurves {
        get { advanced?.curves ?? ToneCurves() }
        set { ensureAdvanced(); advanced!.curves = newValue.isIdentity ? nil : newValue.sanitized }
    }
    public var neutralBalance: NeutralBalance {
        get { advanced?.neutralBalance ?? NeutralBalance() }
        set { ensureAdvanced(); advanced!.neutralBalance = newValue == NeutralBalance() ? nil : newValue }
    }
}
public enum ToneTools {
    private static let curve = CIColorKernel(source:"""
    float tone(float x, vec4 a, float e) {
        float i = floor(clamp(x,0.0,0.99999)*4.0);
        float p; float q; float prev; float next;
        if (i < 0.5) { p=a.x; q=a.y; prev=2.0*p-q; next=a.z; }
        else if (i < 1.5) { p=a.y; q=a.z; prev=a.x; next=a.w; }
        else if (i < 2.5) { p=a.z; q=a.w; prev=a.y; next=e; }
        else { p=a.w; q=e; prev=a.z; next=2.0*q-p; }
        float t = x*4.0-i;
        float d=q-p; float m0=0.5*(q-prev); float m1=0.5*(next-p);
        if (d == 0.0) { m0=0.0; m1=0.0; }
        else { m0=sign(d)*clamp(sign(d)*m0,0.0,3.0*abs(d)); m1=sign(d)*clamp(sign(d)*m1,0.0,3.0*abs(d)); }
        if (x < 0.0) return a.x+x*4.0*(a.y-a.x);
        if (x > 1.0) return e+(x-1.0)*4.0*(e-a.w);
        return (2.0*t*t*t-3.0*t*t+1.0)*p+(t*t*t-2.0*t*t+t)*m0+(-2.0*t*t*t+3.0*t*t)*q+(t*t*t-t*t)*m1;
    }
    kernel vec4 photographicCurves(__sample pixel, vec4 m, float me, vec4 r, float re, vec4 g, float ge, vec4 b, float be) {
        vec4 p=unpremultiply(pixel);
        p.rgb=vec3(tone(tone(p.r,m,me),r,re),tone(tone(p.g,m,me),g,ge),tone(tone(p.b,m,me),b,be));
        return premultiply(p);
    }
    """)
    static func applyCurves(_ image:CIImage, settings:ToneCurves) throws -> CIImage {
        let settings = settings.sanitized
        guard !settings.isIdentity else { return image }
        let sRGB = CGColorSpace(name:CGColorSpace.extendedSRGB)!
        guard let input = image.matchedFromWorkingSpace(to:sRGB) else { throw EditError.render }
        var args:[Any] = [input]
        for points in [settings.master,settings.red,settings.green,settings.blue] {
            args += [CIVector(x:points[0],y:points[1],z:points[2],w:points[3]), points[4]]
        }
        guard let output = curve?.apply(extent:image.extent,arguments:args)?.matchedToWorkingSpace(from:sRGB) else { throw EditError.render }
        return output
    }
    static func balance(_ image:CIImage, settings:NeutralBalance) -> CIImage {
        let gains = settings.gains
        return image.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:gains[0],y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:gains[1],z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:gains[2],w:0)])
    }
    public static func neutralSample(_ image:CIImage, point:CGPoint) throws -> NeutralBalance {
        let extent = image.extent
        let x = extent.minX+min(1,max(0,point.x))*extent.width, y = extent.minY+min(1,max(0,point.y))*extent.height
        let region = CGRect(x:x-3,y:y-3,width:7,height:7).intersection(extent)
        let sample = image.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:region)])
        var rgba = [Float](repeating:0,count:4)
        ModernRenderer.context.render(sample,toBitmap:&rgba,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:ModernRenderer.workingSpace)
        guard rgba[3] > 0.01, rgba[0...2].allSatisfy({ $0 > 0.002 && $0.isFinite }) else { throw EditError.render }
        let avg = Double(rgba[0]+rgba[1]+rgba[2])/3
        return NeutralBalance(red:avg/Double(rgba[0]),green:avg/Double(rgba[1]),blue:avg/Double(rgba[2]))
    }
}
public struct PhotoHistogram {
    public var red = [Int](repeating:0,count:256), green = [Int](repeating:0,count:256), blue = [Int](repeating:0,count:256), luminance = [Int](repeating:0,count:256)
    public var shadowClipped = 0.0, highlightClipped = 0.0
    public static func measure(_ image:CIImage, profile:ExportProfile = .sRGB) -> PhotoHistogram {
        let scale = min(1,512/max(image.extent.width,image.extent.height))
        let small = image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let bounds = small.extent.integral, w = Int(bounds.width), h = Int(bounds.height)
        guard w > 0, h > 0 else { return PhotoHistogram() }
        var pixels = [Float](repeating:0,count:w*h*4)
        ModernRenderer.context.render(small,toBitmap:&pixels,rowBytes:w*16,bounds:bounds,format:.RGBAf,colorSpace:profile.colorSpace)
        var result = PhotoHistogram(), count = 0, low = 0, high = 0
        func bin(_ x:Float) -> Int { Int(min(255,max(0,(x*255).rounded()))) }
        for i in stride(from:0,to:pixels.count,by:4) where pixels[i+3] > 0.01 {
            let a = pixels[i+3], r = pixels[i]/a, g = pixels[i+1]/a, b = pixels[i+2]/a
            guard r.isFinite, g.isFinite, b.isFinite else { continue }
            result.red[bin(r)] += 1; result.green[bin(g)] += 1; result.blue[bin(b)] += 1
            result.luminance[bin(r*0.2126+g*0.7152+b*0.0722)] += 1
            count += 1; if max(r,max(g,b)) >= 1-0.5/255 { high += 1 }; if min(r,min(g,b)) <= 0.5/255 { low += 1 }
        }
        if count > 0 { result.shadowClipped = Double(low)/Double(count); result.highlightClipped = Double(high)/Double(count) }
        return result
    }
}
