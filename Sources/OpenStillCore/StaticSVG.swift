import Foundation
import CoreGraphics

/// A deliberately static SVG subset. Unsupported constructs fail explicitly instead
/// of executing content, resolving URLs, or silently dropping visible artwork.
public enum StaticSVG {
    public static func read(_ data:Data)throws->VectorLogo {
        guard data.count<=10_000_000,let text=String(data:data,encoding:.utf8),!text.lowercased().contains("<!doctype"),!text.lowercased().contains("<!entity") else{throw LogoError.invalid("Use a static UTF-8 SVG without a DTD or external entities. Export the logo as plain SVG or transparent PNG.")}
        let delegate=SVGReader(),parser=XMLParser(data:data);parser.shouldResolveExternalEntities=false;parser.delegate=delegate
        guard parser.parse(),delegate.failure==nil,let bounds=delegate.bounds,!delegate.elements.isEmpty else{throw delegate.failure ?? LogoError.invalid("This SVG could not be read. Export text as outlines and use paths, shapes, solid fills, and strokes.")}
        return VectorLogo(bounds:bounds,elements:delegate.elements)
    }
}
private final class SVGReader:NSObject,XMLParserDelegate {
    struct State {var transform=CGAffineTransform.identity,fill:CGColor?=CGColor(gray:0,alpha:1),stroke:CGColor?,width:CGFloat=1,opacity:CGFloat=1,fillOpacity:CGFloat=1,strokeOpacity:CGFloat=1,evenOdd=false,cap:CGLineCap = .butt,join:CGLineJoin = .miter}
    var stack:[State]=[],elements:[VectorElement]=[],bounds:CGRect?,failure:Error?,ignored=0
    func fail(_ parser:XMLParser,_ reason:String){failure=LogoError.invalid(reason+" Export plain SVG with outlined text, or use a transparent PNG.");parser.abortParsing()}
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes attributes:[String:String]) {
        if name=="title" || name=="desc" || name=="metadata" || ignored>0{ignored += 1;return}
        do {
            guard stack.count<64,elements.count<10000,["svg","g","path","rect","circle","ellipse","line","polyline","polygon"].contains(name) else{throw LogoError.invalid("Unsupported SVG element: \(name).")}
            guard !(name=="svg" && !stack.isEmpty) else{throw LogoError.invalid("Nested SVG viewports are not supported.")}
            var attrs=attributes
            if let style=attrs.removeValue(forKey:"style"){
                for item in style.split(separator:";") {let pair=item.split(separator:":",maxSplits:1).map{String($0).trimmingCharacters(in:.whitespacesAndNewlines)};guard pair.count==2 else{throw LogoError.invalid("Invalid SVG style.")};attrs[pair[0]]=pair[1]}
            }
            let allowed:Set<String>=["xmlns","version","id","viewBox","width","height","preserveAspectRatio","fill","stroke","stroke-width","opacity","fill-opacity","stroke-opacity","fill-rule","stroke-linecap","stroke-linejoin","transform","d","x","y","x1","x2","y1","y2","cx","cy","r","rx","ry","points"]
            guard attrs.keys.allSatisfy({allowed.contains($0)}),!attrs.values.contains(where:{$0.lowercased().contains("url(")}) else{throw LogoError.invalid("This SVG uses unsupported attributes, active content, or references.")}
            var state=stack.last ?? State()
            if let t=attrs["transform"]{state.transform=try SVGNumbers.transform(t).concatenating(state.transform)}
            if let fill=attrs["fill"]{state.fill=try Self.color(fill)};if let stroke=attrs["stroke"]{state.stroke=try Self.color(stroke)}
            if let value=attrs["stroke-width"]{state.width=try SVGNumbers.scalar(value)}
            if let value=attrs["opacity"]{state.opacity *= min(1,max(0,try SVGNumbers.scalar(value)))}
            if let value=attrs["fill-opacity"]{state.fillOpacity=min(1,max(0,try SVGNumbers.scalar(value)))}
            if let value=attrs["stroke-opacity"]{state.strokeOpacity=min(1,max(0,try SVGNumbers.scalar(value)))}
            if let value=attrs["fill-rule"]{guard ["evenodd","nonzero"].contains(value) else{throw LogoError.invalid("Unsupported fill rule.")};state.evenOdd=value=="evenodd"}
            if let value=attrs["stroke-linecap"]{guard ["butt","round","square"].contains(value) else{throw LogoError.invalid("Unsupported stroke cap.")};state.cap=value=="round" ? .round:value=="square" ? .square:.butt}
            if let value=attrs["stroke-linejoin"]{guard ["miter","round","bevel"].contains(value) else{throw LogoError.invalid("Unsupported stroke join.")};state.join=value=="round" ? .round:value=="bevel" ? .bevel:.miter}
            stack.append(state)
            func n(_ key:String,_ fallback:CGFloat=0)throws->CGFloat{try attrs[key].map(SVGNumbers.scalar) ?? fallback}
            if name=="svg" {
                if let viewBox=attrs["viewBox"] {let v=try SVGNumbers.list(viewBox);guard v.count==4 else{throw LogoError.invalid("Invalid viewBox.")};bounds=CGRect(x:v[0],y:v[1],width:v[2],height:v[3])}
                else{bounds=try CGRect(x:0,y:0,width:n("width"),height:n("height"))}
                guard let b=bounds,b.width>0,b.height>0,b.width<=100000,b.height<=100000 else{throw LogoError.invalid("SVG needs a finite, positive viewBox or dimensions.")};return
            }
            if name=="g"{return}
            guard bounds != nil else{throw LogoError.invalid("Missing SVG root.")}
            let path=CGMutablePath()
            switch name {
            case "path":path.addPath(try SVGPath.parse(attrs["d"] ?? ""))
            case "rect":let rect=try CGRect(x:n("x"),y:n("y"),width:n("width"),height:n("height"));guard rect.width>=0,rect.height>=0 else{throw LogoError.invalid("Invalid rectangle.")};let rx=try n("rx",n("ry")),ry=try n("ry",rx);path.addRoundedRect(in:rect,cornerWidth:max(0,rx),cornerHeight:max(0,ry))
            case "circle","ellipse":let x=try n("cx"),y=try n("cy"),rx=try n(name=="circle" ? "r":"rx"),ry=try n(name=="circle" ? "r":"ry");guard rx>=0,ry>=0 else{throw LogoError.invalid("Invalid ellipse.")};path.addEllipse(in:CGRect(x:x-rx,y:y-ry,width:rx*2,height:ry*2))
            case "line":path.move(to:try CGPoint(x:n("x1"),y:n("y1")));path.addLine(to:try CGPoint(x:n("x2"),y:n("y2")))
            case "polyline","polygon":let values=try SVGNumbers.list(attrs["points"] ?? "");guard values.count>=4,values.count%2==0 else{throw LogoError.invalid("Invalid polygon points.")};path.move(to:CGPoint(x:values[0],y:values[1]));for i in stride(from:2,to:values.count,by:2){path.addLine(to:CGPoint(x:values[i],y:values[i+1]))};if name=="polygon"{path.closeSubpath()}
            default:break
            }
            var element=VectorElement(path:path);element.transform=state.transform;element.fill=state.fill?.copy(alpha:state.fillOpacity);element.stroke=state.stroke?.copy(alpha:state.strokeOpacity);element.lineWidth=state.width;element.opacity=state.opacity;element.evenOdd=state.evenOdd;element.lineCap=state.cap;element.lineJoin=state.join;elements.append(element)
        }catch{fail(parser,error.localizedDescription)}
    }
    func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName:String?){if ignored>0{ignored -= 1}else if !stack.isEmpty{stack.removeLast()}}
    func parser(_ parser:XMLParser,foundCharacters string:String){if ignored==0 && !string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{fail(parser,"Visible SVG text must be converted to outlines.")}}
    private static func color(_ value:String)throws->CGColor? {
        let text=value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased();if text=="none"{return nil}
        let colors=["white":"ffffff","black":"000000","red":"ff0000","green":"008000","blue":"0000ff","gray":"808080","grey":"808080","yellow":"ffff00","cyan":"00ffff","magenta":"ff00ff","orange":"ffa500","purple":"800080"]
        var hex=colors[text] ?? (text.hasPrefix("#") ? String(text.dropFirst()):"")
        if hex.count==3{hex=hex.map{String(repeating:String($0),count:2)}.joined()}
        if hex.count==6,UInt32(hex,radix:16) != nil{return LogoColor(hex).cg}
        if text.hasPrefix("rgb("),text.hasSuffix(")") {let values=try SVGNumbers.list(String(text.dropFirst(4).dropLast()));if values.count==3{return CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:values.map{min(255,max(0,$0))/255}+[1])}}
        throw LogoError.invalid("Use solid SVG colors; gradients, patterns, and linked paints are not supported.")
    }
}
private enum SVGNumbers {
    static let regex=try! NSRegularExpression(pattern:"[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.?[0-9]*)(?:[eE][-+]?[0-9]+)?")
    static func scalar(_ text:String)throws->CGFloat {let raw=text.hasSuffix("px") ? String(text.dropLast(2)):text;guard let value=Double(raw.trimmingCharacters(in:.whitespacesAndNewlines)),value.isFinite,abs(value)<=1e7 else{throw LogoError.invalid("SVG coordinates must be finite numbers in pixels.")};return CGFloat(value)}
    static func list(_ text:String)throws->[CGFloat] {
        let matches=regex.matches(in:text,range:NSRange(text.startIndex...,in:text));var end=text.startIndex,result:[CGFloat]=[]
        for match in matches {let range=Range(match.range,in:text)!;guard text[end..<range.lowerBound].allSatisfy({$0.isWhitespace || $0==","}) else{throw LogoError.invalid("Invalid SVG numbers.")};result.append(try scalar(String(text[range])));end=range.upperBound}
        guard text[end...].allSatisfy({$0.isWhitespace || $0==","}) else{throw LogoError.invalid("Invalid SVG number suffix.")};return result
    }
    static func transform(_ text:String)throws->CGAffineTransform {
        let regex=try NSRegularExpression(pattern:"([A-Za-z]+)\\s*\\(([^)]*)\\)");var result=CGAffineTransform.identity,end=text.startIndex
        for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)){let range=Range(match.range,in:text)!;guard text[end..<range.lowerBound].allSatisfy({$0.isWhitespace || $0==","}) else{throw LogoError.invalid("Invalid SVG transform.")};end=range.upperBound;let key=String(text[Range(match.range(at:1),in:text)!]),v=try list(String(text[Range(match.range(at:2),in:text)!]));let next:CGAffineTransform
            switch key {
            case "matrix" where v.count==6:next=CGAffineTransform(a:v[0],b:v[1],c:v[2],d:v[3],tx:v[4],ty:v[5])
            case "translate" where v.count==1 || v.count==2:next=CGAffineTransform(translationX:v[0],y:v.count==2 ? v[1]:0)
            case "scale" where v.count==1 || v.count==2:next=CGAffineTransform(scaleX:v[0],y:v.count==2 ? v[1]:v[0])
            case "rotate" where v.count==1 || v.count==3:let x=v.count==3 ? v[1]:0,y=v.count==3 ? v[2]:0;next=CGAffineTransform(translationX:-x,y:-y).rotated(by:v[0] * .pi/180).concatenating(CGAffineTransform(translationX:x,y:y))
            case "skewX" where v.count==1:next=CGAffineTransform(a:1,b:0,c:tan(v[0] * .pi/180),d:1,tx:0,ty:0)
            case "skewY" where v.count==1:next=CGAffineTransform(a:1,b:tan(v[0] * .pi/180),c:0,d:1,tx:0,ty:0)
            default:throw LogoError.invalid("Unsupported SVG transform.")}
            result=next.concatenating(result)
        }
        guard text[end...].allSatisfy({$0.isWhitespace || $0==","}),[result.a,result.b,result.c,result.d,result.tx,result.ty].allSatisfy({$0.isFinite && abs($0)<1e10}) else{throw LogoError.invalid("Invalid SVG transform.")};return result
    }
}
private enum SVGPath {
    static func parse(_ text:String)throws->CGPath {
        let regex=try NSRegularExpression(pattern:"[A-Za-z]|[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.?[0-9]*)(?:[eE][-+]?[0-9]+)?")
        let matches=regex.matches(in:text,range:NSRange(text.startIndex...,in:text));guard matches.count<200000 else{throw LogoError.invalid("This SVG path is too complex.")}
        var tokens:[String]=[],end=text.startIndex
        for match in matches{let range=Range(match.range,in:text)!;guard text[end..<range.lowerBound].allSatisfy({$0.isWhitespace || $0==","}) else{throw LogoError.invalid("Invalid SVG path.")};tokens.append(String(text[range]));end=range.upperBound}
        guard text[end...].allSatisfy({$0.isWhitespace || $0==","}) else{throw LogoError.invalid("Invalid SVG path.")}
        let path=CGMutablePath();var i=0,command="",previous="",point=CGPoint.zero,start=CGPoint.zero,control=CGPoint.zero
        func number()throws->CGFloat{guard i<tokens.count,Double(tokens[i]) != nil else{throw LogoError.invalid("Incomplete SVG path command.")};defer{i += 1};return try SVGNumbers.scalar(tokens[i])}
        func readPoint(_ relative:Bool)throws->CGPoint{let x=try number(),y=try number();return CGPoint(x:x+(relative ? point.x:0),y:y+(relative ? point.y:0))}
        while i<tokens.count {
            if tokens[i].count==1,tokens[i].first!.isLetter{command=tokens[i];i += 1}
            guard !command.isEmpty else{throw LogoError.invalid("Missing SVG path command.")}
            let upper=command.uppercased(),relative=command != upper
            switch upper {
            case "M":point=try readPoint(relative);path.move(to:point);start=point;command=relative ? "l":"L"
            case "L":point=try readPoint(relative);path.addLine(to:point)
            case "H":point.x=try number()+(relative ? point.x:0);path.addLine(to:point)
            case "V":point.y=try number()+(relative ? point.y:0);path.addLine(to:point)
            case "C":let a=try readPoint(relative),b=try readPoint(relative),to=try readPoint(relative);path.addCurve(to:to,control1:a,control2:b);control=b;point=to
            case "S":let a=["C","S"].contains(previous) ? CGPoint(x:2*point.x-control.x,y:2*point.y-control.y):point,b=try readPoint(relative),to=try readPoint(relative);path.addCurve(to:to,control1:a,control2:b);control=b;point=to
            case "Q":let a=try readPoint(relative),to=try readPoint(relative);path.addQuadCurve(to:to,control:a);control=a;point=to
            case "T":let a=["Q","T"].contains(previous) ? CGPoint(x:2*point.x-control.x,y:2*point.y-control.y):point,to=try readPoint(relative);path.addQuadCurve(to:to,control:a);control=a;point=to
            case "A":let rx=try number(),ry=try number(),rotation=try number(),large=try number(),sweep=try number(),to=try readPoint(relative);guard [0,1].contains(large),[0,1].contains(sweep) else{throw LogoError.invalid("Invalid SVG arc flags.")};arc(path,from:point,to:to,rx:rx,ry:ry,angle:rotation,large:large==1,sweep:sweep==1);point=to
            case "Z":path.closeSubpath();point=start;command=""
            default:throw LogoError.invalid("Unsupported SVG path command: \(command).")
            }
            previous=upper
        }
        return path
    }
    static func arc(_ path:CGMutablePath,from:CGPoint,to:CGPoint,rx:CGFloat,ry:CGFloat,angle:CGFloat,large:Bool,sweep:Bool){
        if from==to{return};var rx=abs(rx),ry=abs(ry);if rx==0 || ry==0{path.addLine(to:to);return}
        let phi=angle * .pi/180,c=cos(phi),s=sin(phi),dx=(from.x-to.x)/2,dy=(from.y-to.y)/2,x=c*dx+s*dy,y = -s*dx+c*dy
        let lambda=x*x/(rx*rx)+y*y/(ry*ry);if lambda>1{rx *= sqrt(lambda);ry *= sqrt(lambda)}
        let numerator=max(0,rx*rx*ry*ry-rx*rx*y*y-ry*ry*x*x),denominator=rx*rx*y*y+ry*ry*x*x
        let factor=(large==sweep ? -1.0:1.0)*sqrt(numerator/max(1e-20,denominator)),cx=factor*rx*y/ry,cy = -factor*ry*x/rx
        let center=CGPoint(x:c*cx-s*cy+(from.x+to.x)/2,y:s*cx+c*cy+(from.y+to.y)/2)
        let first=atan2((y-cy)/ry,(x-cx)/rx),last=atan2((-y-cy)/ry,(-x-cx)/rx)
        var delta=last-first;if !sweep && delta>0{delta -= 2 * .pi};if sweep && delta<0{delta += 2 * .pi}
        let steps=max(1,Int(ceil(abs(delta)/(.pi/2)))),step=delta/CGFloat(steps)
        func p(_ theta:CGFloat)->CGPoint{CGPoint(x:center.x+c*rx*cos(theta)-s*ry*sin(theta),y:center.y+s*rx*cos(theta)+c*ry*sin(theta))}
        func derivative(_ theta:CGFloat)->CGPoint{CGPoint(x: -c*rx*sin(theta)-s*ry*cos(theta),y: -s*rx*sin(theta)+c*ry*cos(theta))}
        for index in 0..<steps{let a=first+CGFloat(index)*step,b=a+step,k=4/3*tan(step/4),pa=p(a),pb=p(b),da=derivative(a),db=derivative(b);path.addCurve(to:index==steps-1 ? to:pb,control1:CGPoint(x:pa.x+k*da.x,y:pa.y+k*da.y),control2:CGPoint(x:pb.x-k*db.x,y:pb.y-k*db.y))}
    }
}
