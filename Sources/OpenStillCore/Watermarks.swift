import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct WatermarkLogo:Codable,Identifiable {
    public var id=UUID(),name:String,asset:String,design:LogoDesign?
    public init(name:String,asset:String,design:LogoDesign?=nil){self.name=name;self.asset=asset;self.design=design}
}
public enum WatermarkAnchor:Int,Codable,CaseIterable {
    case topLeft,top,topRight,left,center,right,bottomLeft,bottom,bottomRight
    public var title:String{["Top left","Top center","Top right","Center left","Center","Center right","Bottom left","Bottom center","Bottom right"][rawValue]}
}
public struct WatermarkSettings:Codable,Equatable {
    public var asset:String,anchor:WatermarkAnchor = .bottomRight,size=20.0,margin=3.0,opacity=0.8
    public init(asset:String){self.asset=asset}
    public var sanitized:Self{var s=self;s.size=size.isFinite ? min(100,max(1,size)):20;s.margin=margin.isFinite ? min(25,max(0,margin)):3;s.opacity=opacity.isFinite ? min(1,max(0,opacity)):0.8;return s}
}
public enum Watermarks {
    public static func library(root:URL=EditStorage.root)->[WatermarkLogo]{(try? JSONDecoder().decode([WatermarkLogo].self,from:Data(contentsOf:root.appendingPathComponent("WatermarkLogos.json")))) ?? []}
    public static func saveLibrary(_ logos:[WatermarkLogo],root:URL=EditStorage.root)throws{try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try JSONEncoder().encode(logos).write(to:root.appendingPathComponent("WatermarkLogos.json"),options:.atomic)}
    public static func importLogo(_ source:URL)throws->WatermarkLogo {
        guard ["png","tif","tiff","jpg","jpeg","pdf","svg"].contains(source.pathExtension.lowercased()) else{throw LogoError.invalid("Import a PNG, TIFF, JPEG, PDF, or static SVG logo.")}
        _ = try image(source,maximum:512)
        let asset=try EditStorage.newAsset(extension:source.pathExtension.lowercased());try FileManager.default.copyItem(at:source,to:asset)
        let logo=WatermarkLogo(name:source.deletingPathExtension().lastPathComponent,asset:asset.lastPathComponent);var logos=library();logos.append(logo);try saveLibrary(logos);return logo
    }
    public static func saveDesign(_ design:LogoDesign)throws->WatermarkLogo {
        let vector=try LogoRenderer.vector(design),asset=try EditStorage.newAsset(extension:"svg")
        try Data(vector.svg(title:design.name+(design.tagline.isEmpty ? "":" · "+design.tagline)).utf8).write(to:asset,options:.atomic)
        let logo=WatermarkLogo(name:design.name,asset:asset.lastPathComponent,design:design);var logos=library();logos.append(logo);try saveLibrary(logos);return logo
    }
    public static func image(_ url:URL,maximum:Int)throws->CIImage {
        switch url.pathExtension.lowercased(){
        case "svg":return CIImage(cgImage:try StaticSVG.read(Data(contentsOf:url)).raster(maximum:maximum))
        case "pdf":
            guard let doc=CGPDFDocument(url as CFURL),let page=doc.page(at:1) else{throw LogoError.invalid("This PDF has no readable first page.")}
            let box=page.getBoxRect(.cropBox);guard box.width>0,box.height>0 else{throw EditError.render}
            let scale=Double(maximum)/max(box.width,box.height),width=max(1,Int(box.width*scale)),height=max(1,Int(box.height*scale))
            guard width*height<=64_000_000,let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw EditError.render}
            context.concatenate(page.getDrawingTransform(.cropBox,rect:CGRect(x:0,y:0,width:width,height:height),rotate:0,preserveAspectRatio:true));context.drawPDFPage(page)
            guard let image=context.makeImage() else{throw EditError.render};return CIImage(cgImage:image)
        default:return try ModernRenderer.readImage(url)
        }
    }
    public static func rect(image:CGSize,logo:CGSize,settings:WatermarkSettings)->CGRect {
        let s=settings.sanitized,margin=min(image.width,image.height)*s.margin/100
        let width=min(image.width*s.size/100,image.width-2*margin),scale=min(width/max(1,logo.width),(image.height-2*margin)/max(1,logo.height)),size=CGSize(width:logo.width*scale,height:logo.height*scale)
        let column=s.anchor.rawValue%3,row=s.anchor.rawValue/3
        let x=column==0 ? margin:column==1 ? (image.width-size.width)/2:image.width-margin-size.width
        let y=row==0 ? image.height-margin-size.height:row==1 ? (image.height-size.height)/2:margin
        return CGRect(origin:CGPoint(x:x,y:y),size:size)
    }
    public static func apply(_ source:CIImage,settings:WatermarkSettings)throws->CIImage {
        let s=settings.sanitized;guard s.opacity>0 else{return source}
        let logo=try image(EditStorage.asset(s.asset),maximum:max(64,min(8000,Int(source.extent.width*s.size/100))))
        let target=rect(image:source.extent.size,logo:logo.extent.size,settings:s)
        let scaled=logo.transformed(by:CGAffineTransform(translationX:-logo.extent.minX,y:-logo.extent.minY)).transformed(by:CGAffineTransform(scaleX:target.width/logo.extent.width,y:target.height/logo.extent.height)).transformed(by:CGAffineTransform(translationX:target.minX+source.extent.minX,y:target.minY+source.extent.minY))
        let faded=scaled.applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:s.opacity)])
        return faded.composited(over:source).cropped(to:source.extent)
    }
    public static func export(_ design:LogoDesign,to url:URL)throws {
        let vector=try LogoRenderer.vector(design)
        switch url.pathExtension.lowercased(){case "svg":try Data(vector.svg(title:design.name+" · "+design.tagline).utf8).write(to:url,options:.atomic)
        case "pdf":try vector.writePDF(to:url)
        case "png":let image=try vector.raster(maximum:3000);guard let writer=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else{throw EditError.render};CGImageDestinationAddImage(writer,image,nil);guard CGImageDestinationFinalize(writer) else{throw EditError.render}
        default:throw LogoError.invalid("Export logos as SVG, PDF, or transparent PNG.")}
    }
}
