import Foundation
import CoreImage
import CImagingBridge

public enum RenderingIntent:Int,Codable,CaseIterable {
    case perceptual=0,relative=1,saturation=2,absolute=3
    public var title:String{switch self{case .perceptual:return "Perceptual";case .relative:return "Relative colorimetric";case .saturation:return "Saturation";case .absolute:return "Absolute colorimetric"}}
}
public struct ProofSettings:Equatable {
    public var enabled=false,profileAsset:String?,intent=RenderingIntent.relative,paper=false,gamut=false
    public init(){}
}
public enum ProofError:LocalizedError {
    case invalidProfile,transform
    public var errorDescription:String?{self == .invalidProfile ? "Choose a valid RGB, CMYK, or grayscale printer/paper ICC profile.":"This ICC profile cannot be used for the selected proofing transform."}
}
public enum SoftProof {
    public static func validate(_ bytes:Data)->Bool {
        guard bytes.count>=128,bytes.count<=32*1024*1024 else{return false}
        return bytes.withUnsafeBytes{os_proof_profile_valid($0.baseAddress,UInt32(bytes.count)) != 0}
    }
    public static func importProfile(_ url:URL)throws->String {
        let bytes=try Data(contentsOf:url);guard validate(bytes) else{throw ProofError.invalidProfile}
        let asset=try EditStorage.newAsset(extension:"icc");try bytes.write(to:asset,options:.atomic);return asset.lastPathComponent
    }
    public static func apply(_ image:CIImage,settings:ProofSettings)throws->CIImage {
        guard settings.enabled,let asset=settings.profileAsset else{return image}
        let proof=try Data(contentsOf:EditStorage.asset(asset));guard validate(proof) else{throw ProofError.invalidProfile}
        return try render(image,profile:proof,intent:settings.intent,paper:settings.paper,gamut:settings.gamut)
    }
    public static func render(_ image:CIImage,profile:Data,intent:RenderingIntent,paper:Bool,gamut:Bool)throws->CIImage {
        guard validate(profile) else{throw ProofError.invalidProfile}
        let space=ExportProfile.displayP3.colorSpace
        let icc=space.copyICCData()! as Data,w=Int(image.extent.width),h=Int(image.extent.height)
        guard w>0,h>0,w*h<=100_000_000 else{throw EditError.render}
        var pixels=[Float](repeating:0,count:w*h*4)
        ModernRenderer.context.render(image,toBitmap:&pixels,rowBytes:w*16,bounds:image.extent,format:.RGBAf,colorSpace:space)
        for i in stride(from:0,to:pixels.count,by:4){let a=pixels[i+3];if a>0{for c in 0..<3{pixels[i+c]/=a}}}
        let success=icc.withUnsafeBytes{input in profile.withUnsafeBytes{proof in os_proof_rgba(input.baseAddress,UInt32(icc.count),input.baseAddress,UInt32(icc.count),proof.baseAddress,UInt32(profile.count),Int32(intent.rawValue),paper ? 1:0,gamut ? 1:0,&pixels,UInt32(w*h))}}
        guard success != 0 else{throw ProofError.transform}
        for i in stride(from:0,to:pixels.count,by:4){for c in 0..<3{pixels[i+c]*=pixels[i+3]}}
        return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:space)
    }
}
