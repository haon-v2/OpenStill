import Foundation
import CoreGraphics
import CoreText
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum LogoError:LocalizedError {
    case invalid(String)
    public var errorDescription:String?{if case .invalid(let reason)=self{return reason};return nil}
}
public struct LogoColor:Codable,Equatable {
    public var hex:String
    public init(_ hex:String){self.hex=hex}
    public var cg:CGColor {
        let value=UInt32(hex.replacingOccurrences(of:"#",with:""),radix:16) ?? 0xffffff
        return CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[CGFloat((value>>16)&255)/255,CGFloat((value>>8)&255)/255,CGFloat(value&255)/255,1])!
    }
}
public enum LogoTypography:String,Codable,CaseIterable {case sans,serif,script,mono
    public var fontName:String{switch self{case .sans:return "HelveticaNeue-Light";case .serif:return "Baskerville";case .script:return "SnellRoundhand";case .mono:return "Menlo"}}
}
public enum LogoLayout:String,Codable,CaseIterable{case horizontal,stacked,typeOnly}
public enum LogoSymbol:String,Codable,CaseIterable{case none,aperture,mountain,frame,monogram}
public struct LogoSuggestion:Codable,Equatable {
    public var typography:LogoTypography = .sans,layout:LogoLayout = .horizontal,symbol:LogoSymbol = .aperture
    public var spacing=3.0,symbolSize=1.0
    public init(){}
}
public struct LogoDesign:Codable,Equatable,Identifiable {
    public var id=UUID(),name:String,tagline:String
    public var suggestion=LogoSuggestion(),color=LogoColor("#FFFFFF"),accent=LogoColor("#FFFFFF")
    public init(name:String,tagline:String=""){self.name=name;self.tagline=tagline}
}
public struct VectorElement {
    public var path:CGPath,transform:CGAffineTransform = .identity,fill:CGColor? = CGColor(gray:0,alpha:1),stroke:CGColor?,lineWidth:CGFloat=1,opacity:CGFloat=1,evenOdd=false
    public var lineCap:CGLineCap = .butt,lineJoin:CGLineJoin = .miter
    public init(path:CGPath){self.path=path}
}
public struct VectorLogo {
    public var bounds:CGRect,elements:[VectorElement]
    public init(bounds:CGRect,elements:[VectorElement]){self.bounds=bounds;self.elements=elements}
    public func draw(in context:CGContext){
        context.saveGState();context.translateBy(x:0,y:bounds.height);context.scaleBy(x:1,y:-1);context.translateBy(x:-bounds.minX,y:-bounds.minY)
        for element in elements {context.saveGState();context.concatenate(element.transform);context.setAlpha(element.opacity);context.addPath(element.path);if let fill=element.fill{context.setFillColor(fill)};if let stroke=element.stroke{context.setStrokeColor(stroke)};context.setLineWidth(element.lineWidth);context.setLineCap(element.lineCap);context.setLineJoin(element.lineJoin)
            let mode:CGPathDrawingMode=element.fill != nil ? (element.stroke != nil ? (element.evenOdd ? .eoFillStroke:.fillStroke):(element.evenOdd ? .eoFill:.fill)):.stroke
            if element.fill != nil || element.stroke != nil{context.drawPath(using:mode)}else{context.beginPath()};context.restoreGState()
        };context.restoreGState()
    }
    public func raster(maximum:Int=2000)throws->CGImage {
        let scale=min(8,Double(maximum)/max(bounds.width,bounds.height)),w=max(1,Int((bounds.width*scale).rounded())),h=max(1,Int((bounds.height*scale).rounded()))
        guard w*h<=64_000_000,let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw EditError.render}
        context.scaleBy(x:CGFloat(w)/bounds.width,y:CGFloat(h)/bounds.height);draw(in:context)
        guard let result=context.makeImage() else{throw EditError.render};return result
    }
    public func writePDF(to url:URL)throws {
        var box=CGRect(origin:.zero,size:bounds.size)
        guard let consumer=CGDataConsumer(url:url as CFURL),let context=CGContext(consumer:consumer,mediaBox:&box,nil) else{throw EditError.render}
        context.beginPDFPage(nil);draw(in:context);context.endPDFPage();context.closePDF()
    }
    public func svg(title:String="Photographer watermark")->String {
        func escape(_ s:String)->String{s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
        func color(_ c:CGColor?)->String{guard let c,let rgb=c.converted(to:CGColorSpace(name:CGColorSpace.sRGB)!,intent:.relativeColorimetric,options:nil),let v=rgb.components else{return "none"};return String(format:"#%02X%02X%02X",Int(min(1,max(0,v[0]))*255),Int(min(1,max(0,v[1]))*255),Int(min(1,max(0,v[2]))*255))}
        func number(_ x:CGFloat)->String{String(format:"%.5f",Double(x))}
        let paths=elements.map{e -> String in
            var data="";e.path.applyWithBlock{item in let v=item.pointee;func p(_ i:Int)->String{number(v.points[i].x)+" "+number(v.points[i].y)};switch v.type{case .moveToPoint:data += "M"+p(0);case .addLineToPoint:data += "L"+p(0);case .addQuadCurveToPoint:data += "Q"+p(0)+" "+p(1);case .addCurveToPoint:data += "C"+p(0)+" "+p(1)+" "+p(2);case .closeSubpath:data += "Z";@unknown default:break}}
            let t=e.transform,transform=[t.a,t.b,t.c,t.d,t.tx,t.ty].map(number).joined(separator:" ")
            return "<path d=\"\(data)\" transform=\"matrix(\(transform))\" fill=\"\(color(e.fill))\" stroke=\"\(color(e.stroke))\" stroke-width=\"\(number(e.lineWidth))\" fill-opacity=\"\(number(e.fill?.alpha ?? 1))\" stroke-opacity=\"\(number(e.stroke?.alpha ?? 1))\" opacity=\"\(number(e.opacity))\" fill-rule=\"\(e.evenOdd ? "evenodd":"nonzero")\" stroke-linecap=\"\(e.lineCap == .round ? "round":e.lineCap == .square ? "square":"butt")\" stroke-linejoin=\"\(e.lineJoin == .round ? "round":e.lineJoin == .bevel ? "bevel":"miter")\"/>"
        }.joined(separator:"\n")
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(number(bounds.minX)) \(number(bounds.minY)) \(number(bounds.width)) \(number(bounds.height))\"><title>\(escape(title))</title>\n\(paths)\n</svg>"
    }
}
public enum LogoRenderer {
    private static func text(_ value:String,font:String,size:CGFloat,spacing:Double)throws->CGPath {
        let attributes:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName(font as CFString,size,nil),NSAttributedString.Key(kCTKernAttributeName as String):spacing]
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:value,attributes:attributes)),result=CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count=CTRunGetGlyphCount(run);var glyphs=[CGGlyph](repeating:0,count:count),positions=[CGPoint](repeating:.zero,count:count),indices=[CFIndex](repeating:0,count:count)
            CTRunGetStringIndices(run,CFRange(location:0,length:0),&indices);CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs);CTRunGetPositions(run,CFRange(location:0,length:0),&positions)
            let font=(CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for i in 0..<count {
                let unit=(value as NSString).character(at:indices[i])
                let blank=UnicodeScalar(unit).map{CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)} ?? false
                if glyphs[i] == 0 && !blank {throw LogoError.invalid("This font cannot draw every character. Choose another font or import your logo as an image.")}
                if let path=CTFontCreatePathForGlyph(font,glyphs[i],nil){result.addPath(path,transform:CGAffineTransform(translationX:positions[i].x,y:positions[i].y))}
                else if !blank {throw LogoError.invalid("This text includes characters without vector outlines, such as emoji. Remove them or import a transparent logo image.")}
            }
        }
        guard !result.isEmpty || value.trimmingCharacters(in:.whitespaces).isEmpty else{throw LogoError.invalid("This text has no vector outlines. Choose another font or import a transparent image.")}
        return result
    }
    public static func vector(_ design:LogoDesign)throws->VectorLogo {
        guard !design.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,design.name.count<=160,design.tagline.count<=240 else{throw LogoError.invalid("Enter a photographer name of up to 160 characters and an optional tagline of up to 240.")}
        let spec=design.suggestion,spacing=min(20,max(-5,spec.spacing.isFinite ? spec.spacing:3)),symbolSize=min(1.6,max(0.4,spec.symbolSize.isFinite ? spec.symbolSize:1))
        var elements:[VectorElement]=[]
        func add(_ path:CGPath,_ color:CGColor,stroke:Bool=false,width:CGFloat=3){var e=VectorElement(path:path);if stroke{e.fill=nil;e.stroke=color;e.lineWidth=width;e.lineCap = .round;e.lineJoin = .round}else{e.fill=color};elements.append(e)}
        let stacked=spec.layout == .stacked,hasSymbol=spec.symbol != .none && spec.layout != .typeOnly
        let textPath=try text(design.name,font:spec.typography.fontName,size:72,spacing:spacing)
        let textWidth=max(1,textPath.boundingBoxOfPath.width),available:CGFloat=hasSymbol && !stacked ? 760:940,scale=min(1,available/textWidth)
        let left:CGFloat=hasSymbol && !stacked ? 215:(1000-textWidth*scale)/2
        let baseline:CGFloat=stacked && hasSymbol ? 330:175
        var transform=CGAffineTransform(a:scale,b:0,c:0,d:-scale,tx:left-textPath.boundingBoxOfPath.minX*scale,ty:baseline)
        add(textPath.copy(using:&transform)!,design.color.cg)
        if !design.tagline.isEmpty {
            let tag=try text(design.tagline,font:"HelveticaNeue",size:23,spacing:max(1,spacing)),width=max(1,tag.boundingBoxOfPath.width),size=min(1,available/width)
            var t=CGAffineTransform(a:size,b:0,c:0,d:-size,tx:left+(textWidth*scale-width*size)/2-tag.boundingBoxOfPath.minX*size,ty:baseline+42)
            add(tag.copy(using:&t)!,design.color.cg)
        }
        if hasSymbol {
            let center=CGPoint(x:stacked ? 500:110,y:stacked ? 125:150),r=CGFloat(62*symbolSize),path=CGMutablePath()
            switch spec.symbol {
            case .none:break
            case .aperture:
                path.addEllipse(in:CGRect(x:center.x-r,y:center.y-r,width:r*2,height:r*2))
                for i in 0..<6 {let a=Double(i)*Double.pi/3,b=a+1.3;path.move(to:CGPoint(x:center.x+r*CGFloat(cos(a)),y:center.y+r*CGFloat(sin(a))));path.addLine(to:CGPoint(x:center.x+r*0.28*CGFloat(cos(b)),y:center.y+r*0.28*CGFloat(sin(b))))};add(path,design.accent.cg,stroke:true,width:3)
            case .mountain:
                path.move(to:CGPoint(x:center.x-r,y:center.y+r*0.5));path.addLine(to:CGPoint(x:center.x-r*0.15,y:center.y-r*0.65));path.addLine(to:CGPoint(x:center.x+r*0.3,y:center.y));path.addLine(to:CGPoint(x:center.x+r*0.55,y:center.y-r*0.25));path.addLine(to:CGPoint(x:center.x+r,y:center.y+r*0.5));add(path,design.accent.cg,stroke:true,width:4)
            case .frame:
                for x in [-1.0,1.0]{for y in [-1.0,1.0]{let p=CGPoint(x:center.x+CGFloat(x)*r,y:center.y+CGFloat(y)*r*0.7);path.move(to:CGPoint(x:p.x-CGFloat(x)*r*0.45,y:p.y));path.addLine(to:p);path.addLine(to:CGPoint(x:p.x,y:p.y-CGFloat(y)*r*0.45))}};add(path,design.accent.cg,stroke:true,width:3)
            case .monogram:
                let initials=design.name.split(separator:" ").prefix(2).compactMap(\.first).map(String.init).joined(),glyph=try text(initials,font:spec.typography.fontName,size:r,spacing:0),box=glyph.boundingBoxOfPath
                var t=CGAffineTransform(a:1,b:0,c:0,d:-1,tx:center.x-box.midX,ty:center.y+box.midY);add(glyph.copy(using:&t)!,design.accent.cg)
            }
        }
        let bounds=CGRect(x:0,y:0,width:1000,height:stacked && hasSymbol ? 440:300)
        return VectorLogo(bounds:bounds,elements:elements)
    }
}
