import Foundation
import CoreImage
import ImageIO
import CryptoKit
import CImagingBridge

public struct LensProfile: Equatable {
    public let id:String, name:String, maker:String
    public let crop:Double, capabilities:Int
    let index:Int32
    public var title:String { name.lowercased().hasPrefix(maker.lowercased()) ? name : maker+" · "+name }
}
public struct LensSettings: Codable, Equatable {
    public var enabled = false
    public var profileID:String?
    public var focal = 50.0, aperture = 5.6, distance = 1000.0, crop = 1.0
    public var distortion = true, chromaticAberration = true, opticalVignette = true
    public var manualDistortion = 0.0, manualChromatic = 0.0, manualVignette = 0.0
    public init() {}
    public var sanitized:Self {
        var s=self
        func finite(_ x:Double,_ low:Double,_ high:Double,_ fallback:Double)->Double { x.isFinite ? min(high,max(low,x)) : fallback }
        s.focal=finite(focal,1,2000,50);s.aperture=finite(aperture,0.5,128,5.6);s.distance=finite(distance,0.1,10000,1000);s.crop=finite(crop,0.1,10,1)
        s.manualDistortion=finite(manualDistortion,-1,1,0);s.manualChromatic=finite(manualChromatic,-1,1,0);s.manualVignette=finite(manualVignette,-1,1,0)
        return s
    }
    var flags:Int32 { (distortion ? 8:0) | (chromaticAberration ? 1:0) | (opticalVignette ? 2:0) }
    public var hasEffect:Bool { enabled && (profileID != nil || manualDistortion != 0 || manualChromatic != 0 || manualVignette != 0) }
}
extension PhotoEdits {
    public var lens:LensSettings {
        get { advanced?.lens ?? LensSettings() }
        set { ensureAdvanced(); advanced!.lens = newValue.sanitized }
    }
}
public final class LensLibrary {
    public static let shared = LensLibrary()
    private let db:OSLensDatabase?
    private let lock=NSLock()
    public let profiles:[LensProfile]
    public init(directory:URL? = nil) {
        let paths=[directory,Bundle.main.resourceURL?.appendingPathComponent("LensProfiles"),URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/LensProfiles")].compactMap{$0}
        let loaded=paths.lazy.compactMap { os_lens_open($0.path) }.first
        db=loaded
        profiles=(0..<os_lens_count(loaded)).map { index in
            let name=String(cString:os_lens_name(loaded,index)),maker=String(cString:os_lens_maker(loaded,index)),crop=Double(os_lens_crop(loaded,index))
            let id=SHA256.hash(data:Data("\(maker)|\(name)|\(crop)".utf8)).map{String(format:"%02x",$0)}.joined()
            return LensProfile(id:id,name:name,maker:maker,crop:crop,capabilities:Int(os_lens_capabilities(loaded,index)),index:index)
        }
    }
    deinit { os_lens_close(db) }
    public func profile(id:String?) -> LensProfile? { profiles.first{$0.id == id} }
    public func suggested(for url:URL) -> LensSettings {
        var s=LensSettings()
        guard let io=CGImageSourceCreateWithURL(url as CFURL,nil),let props=CGImageSourceCopyPropertiesAtIndex(io,0,nil) as? [String:Any] else { return s }
        let tiff=props[kCGImagePropertyTIFFDictionary as String] as? [String:Any] ?? [:], exif=props[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:], aux=props[kCGImagePropertyExifAuxDictionary as String] as? [String:Any] ?? [:]
        let make=tiff["Make"] as? String ?? "", model=tiff["Model"] as? String ?? ""
        let lens=exif["LensModel"] as? String ?? aux["LensModel"] as? String ?? aux["Lens"] as? String ?? ""
        s.focal=(exif["FocalLength"] as? NSNumber)?.doubleValue ?? 50
        s.aperture=(exif["FNumber"] as? NSNumber)?.doubleValue ?? 5.6
        let distance=(exif["SubjectDistance"] as? NSNumber)?.doubleValue ?? 0
        if distance > 0 { s.distance=distance }
        lock.lock(); let crop=Double(os_camera_crop(db,make,model));lock.unlock()
        if crop > 0 { s.crop=crop }
        func normalized(_ s:String)->String { s.lowercased().filter{ $0.isLetter || $0.isNumber } }
        let exact=normalized(lens)
        let matches=profiles.filter { profile in
            crop > 0 && profile.crop <= crop*1.01 && !exact.isEmpty &&
            (normalized(profile.name)==exact || normalized(profile.maker+profile.name)==exact)
        }
        // No fuzzy focal-range-only matching. Ambiguous or missing EXIF remains manual.
        if matches.count == 1, exif["FocalLength"] != nil { s.profileID=matches[0].id }
        return s.sanitized
    }
    fileprivate func maps(_ settings:LensSettings,size:CGSize) throws -> LensMaps {
        let settings=settings.sanitized
        let width=max(2,Int(size.width.rounded())),height=max(2,Int(size.height.rounded()))
        let gw=min(513,width),gh=min(513,height), count=gw*gh*4
        var data=[Float](repeating:0,count:count*4)
        if let profile=profile(id:settings.profileID) {
            lock.lock()
            let result=os_lens_maps(db,profile.index,Float(settings.crop),Int32(width),Int32(height),Float(settings.focal),Float(settings.aperture),Float(settings.distance),settings.flags,Int32(gw),Int32(gh),&data)
            lock.unlock()
            guard result >= 0 else { throw LensError.unavailable }
        } else if settings.profileID != nil { throw LensError.unavailable }
        else {
            for y in 0..<gh { for x in 0..<gw {
                let i=(y*gw+x)*4
                for c in 0..<3 { data[c*count+i]=Float((Double(x)/Double(gw-1)*Double(width-1)+0.5)/Double(width));data[c*count+i+1]=Float((Double(y)/Double(gh-1)*Double(height-1)+0.5)/Double(height));data[c*count+i+3]=1 }
                for c in 0..<4 { data[3*count+i+c]=1 }
            } }
        }
        // Manual radial controls supplement any available profile. Coordinates stay
        // in the oriented source, shared by retouching and selection overlays.
        for y in 0..<gh { for x in 0..<gw {
            let off=(y*gw+x)*4
            for c in 0..<3 {
                let i=c*count+off,px=Double(data[i])-0.5,py=Double(data[i+1])-0.5
                let r2=(px*px+py*py)*2, d=1+settings.manualDistortion*0.25*r2
                let ca=1+settings.manualChromatic*0.004*Double(c-1)
                data[i]=Float(0.5+px*d*ca);data[i+1]=Float(0.5+py*d*ca)
            }
            let px=Double(x)/Double(gw-1)-0.5,py=Double(y)/Double(gh-1)-0.5
            let gain=Float(pow(2,settings.manualVignette*(px*px+py*py)*4))
            for c in 0..<3 { data[3*count+off+c] *= gain }
        } }
        return LensMaps(data:data,width:gw,height:gh,size:size)
    }
}
public enum LensError:LocalizedError {
    case unavailable
    public var errorDescription:String? { "This lens profile is unavailable. Choose a bundled profile or use the manual correction sliders." }
}
private final class LensMaps {
    let images:[CIImage],data:[Float],width:Int,height:Int,size:CGSize
    init(data:[Float],width:Int,height:Int,size:CGSize) {
        self.data=data;self.width=width;self.height=height;self.size=size
        let count=width*height*4
        images=(0..<4).map { plane in
            let bytes=data.withUnsafeBufferPointer { Data(buffer:UnsafeBufferPointer(start:$0.baseAddress!+plane*count,count:count)) }
            return CIImage(bitmapData:bytes,bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:nil)
                .transformed(by:CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:CGFloat(height)))
        }
    }
    func sourcePoint(_ point:CGPoint)->CGPoint {
        let x=min(Double(width-1),max(0,(point.x*size.width-0.5)/(size.width-1)*Double(width-1)))
        let y=min(Double(height-1),max(0,(point.y*size.height-0.5)/(size.height-1)*Double(height-1)))
        let ix=min(width-2,Int(x)),iy=min(height-2,Int(y)),fx=x-Double(ix),fy=y-Double(iy)
        func component(_ c:Int)->Double {
            func value(_ dx:Int,_ dy:Int)->Double { Double(data[width*height*4+((iy+dy)*width+ix+dx)*4+c]) }
            return (value(0,0)*(1-fx)+value(1,0)*fx)*(1-fy)+(value(0,1)*(1-fx)+value(1,1)*fx)*fy
        }
        return CGPoint(x:component(0),y:component(1))
    }
}
public enum LensCorrections {
    private static let cache:NSCache<NSString,LensMaps> = { let c=NSCache<NSString,LensMaps>();c.countLimit=5;return c }()
    private static func maps(_ settings:LensSettings,size:CGSize)throws->LensMaps {
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        let key=String(decoding:try encoder.encode(settings.sanitized),as:UTF8.self)+"|\(size.width)|\(size.height)"
        if let maps=cache.object(forKey:key as NSString) { return maps }
        let maps=try LensLibrary.shared.maps(settings,size:size);cache.setObject(maps,forKey:key as NSString);return maps
    }
    private static let warp=CIKernel(source:"""
    kernel vec4 opticalCorrection(sampler image,sampler redMap,sampler greenMap,sampler blueMap,sampler gains,vec2 size,vec2 grid,float mask) {
        vec2 p=(destCoord()-vec2(0.5))/(size-vec2(1.0))*(grid-vec2(1.0))+vec2(0.5);
        vec2 g=sample(greenMap,samplerTransform(greenMap,p)).xy*size;
        if(mask>0.5) return sample(image,samplerTransform(image,g));
        vec2 r=sample(redMap,samplerTransform(redMap,p)).xy*size;
        vec2 b=sample(blueMap,samplerTransform(blueMap,p)).xy*size;
        vec4 green=sample(image,samplerTransform(image,g));
        vec3 rgb=vec3(sample(image,samplerTransform(image,r)).r,green.g,sample(image,samplerTransform(image,b)).b);
        return vec4(rgb*sample(gains,samplerTransform(gains,p)).rgb,green.a);
    }
    """)
    public static func apply(_ image:CIImage,settings:LensSettings,mask:Bool = false)throws->CIImage {
        guard settings.hasEffect else { return image }
        let bounds=image.extent, maps=try maps(settings,size:bounds.size)
        guard let output=warp?.apply(extent:bounds,roiCallback:{ index,_ in index == 0 ? bounds : maps.images[0].extent },arguments:[image.clampedToExtent()]+maps.images+[CIVector(x:bounds.width,y:bounds.height),CIVector(x:Double(maps.width),y:Double(maps.height)),mask ? 1.0:0.0]) else { throw EditError.render }
        return output.cropped(to:bounds)
    }
    public static func correctedPoint(_ source:CGPoint,size:CGSize,settings:LensSettings)->CGPoint {
        guard settings.hasEffect else{return source}
        var p=source
        // Invert the same smooth map used by image sampling for source markers.
        for _ in 0..<12 {
            let value=sourcePoint(p,size:size,settings:settings)
            let dx=source.x-value.x,dy=source.y-value.y
            if hypot(dx,dy)<0.00001{break}
            p.x += dx;p.y += dy
        }
        return p
    }
    public static func sourcePoint(_ point:CGPoint,size:CGSize,settings:LensSettings)->CGPoint {
        guard settings.hasEffect, let maps=try? maps(settings,size:size) else { return point }
        return maps.sourcePoint(point)
    }
}
