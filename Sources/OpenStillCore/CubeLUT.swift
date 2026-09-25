import Foundation
import CoreImage

public struct CubeLUT {
    public let dimension: Int
    public let data: Data
    public let minimum: [Double]
    public let maximum: [Double]
    private static let cache = NSCache<NSString, LUTBox>()
    public static func load(_ url: URL) throws -> CubeLUT {
        let key = (url.path + EditStorage.fingerprint(url)) as NSString
        if let value = cache.object(forKey:key) { return value.value }
        let bytes = try Data(contentsOf:url)
        guard bytes.count < 64_000_000, let text = String(data:bytes,encoding:.utf8) else { throw LUTError.invalid }
        let lut = try CubeLUT(text:text); cache.countLimit = 12; cache.setObject(LUTBox(lut),forKey:key); return lut
    }
    public init(text: String) throws {
        var n = 0, values:[Float] = [], low = [0.0,0,0], high = [1.0,1,1]
        for line in text.components(separatedBy:.newlines) {
            let parts = line.split(separator:"#",maxSplits:1,omittingEmptySubsequences:false)[0].split(whereSeparator: { $0.isWhitespace })
            guard let first = parts.first else { continue }
            if first == "TITLE" { continue }
            if first == "LUT_3D_SIZE" { guard parts.count == 2, let size = Int(parts[1]), (2...65).contains(size) else { throw LUTError.invalid }; n = size; continue }
            if first == "DOMAIN_MIN" || first == "DOMAIN_MAX" {
                let v = parts.dropFirst().compactMap { Double($0) }; guard v.count == 3, v.allSatisfy(\.isFinite) else { throw LUTError.invalid }
                if first == "DOMAIN_MIN" { low = v } else { high = v }; continue
            }
            guard parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]), [r,g,b].allSatisfy({ $0.isFinite && abs($0)<100 }) else { throw LUTError.invalid }
            values += [r,g,b,1]
            guard values.count <= 65*65*65*4 else { throw LUTError.invalid }
        }
        guard n >= 2, values.count == n*n*n*4, (0..<3).allSatisfy({ high[$0]>low[$0] }) else { throw LUTError.invalid }
        dimension = n; data = values.withUnsafeBytes { Data($0) }; minimum = low; maximum = high
    }
    public func apply(_ image: CIImage) -> CIImage {
        var normalized = image
        if minimum != [0,0,0] || maximum != [1,1,1] {
            let s = (0..<3).map { 1/(maximum[$0]-minimum[$0]) }
            normalized = image.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:s[0],y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:s[1],z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:s[2],w:0),"inputBiasVector":CIVector(x:-minimum[0]*s[0],y:-minimum[1]*s[1],z:-minimum[2]*s[2],w:0)])
        }
        return normalized.applyingFilter("CIColorCubeWithColorSpace",parameters:["inputCubeDimension":dimension,"inputCubeData":data,"inputColorSpace":CGColorSpace(name:CGColorSpace.sRGB)!])
    }
}
private final class LUTBox { let value:CubeLUT; init(_ value:CubeLUT) { self.value = value } }
public enum LUTError: LocalizedError {
    case invalid
    public var errorDescription: String? { "This is not a supported 3D .cube LUT (2–65 points per dimension)." }
}

public enum ColorMixer {
    public static let names = ["Red","Orange","Yellow","Green","Aqua","Blue","Purple","Magenta"]
    public static let centers = [0.0,1.0/12,1.0/6,1.0/3,0.5,2.0/3,0.75,5.0/6]
    private static let cache = NSCache<NSString,NSData>()
    public static func apply(_ image: CIImage, bands:[ColorBand]) -> CIImage {
        let key = bands.map { "\($0.hue):\($0.saturation):\($0.lightness ?? 0)" }.joined(separator:",") as NSString
        let data: Data
        if let cached = cache.object(forKey:key) { data = cached as Data }
        else {
            let n = 33; var values:[Float] = []; values.reserveCapacity(n*n*n*4)
            for b in 0..<n { for g in 0..<n { for r in 0..<n {
                let rgb = [Double(r)/32,Double(g)/32,Double(b)/32], maxV = rgb.max()!, minV = rgb.min()!, delta = maxV-minV
                var h = 0.0
                if delta > 0 {
                    if maxV == rgb[0] { h = ((rgb[1]-rgb[2])/delta).truncatingRemainder(dividingBy:6)/6 }
                    else if maxV == rgb[1] { h = ((rgb[2]-rgb[0])/delta+2)/6 }
                    else { h = ((rgb[0]-rgb[1])/delta+4)/6 }
                    if h < 0 { h += 1 }
                }
                let lightness = (maxV+minV)/2
                let sat = delta == 0 ? 0 : delta/max(0.000001,1-abs(2*lightness-1))
                var dh = 0.0, ds = 0.0, dl = 0.0
                for i in 0..<min(8,bands.count) {
                    let d = abs(h-centers[i]); let distance = min(d,1-d)
                    let width = (i == 1 || i == 6) ? 0.085 : 0.13
                    let weight = pow(max(0,1-max(0,distance-0.02)/(width-0.02)),2)*min(1,sat*5)
                    dh += bands[i].hue*weight*0.12; ds += bands[i].saturation*weight; dl += (bands[i].lightness ?? 0)*weight
                }
                h = (h+dh+1).truncatingRemainder(dividingBy:1)
                let saturation = min(1,max(0,sat*(1+ds)))
                let l = min(1,max(0,lightness + (dl >= 0 ? (1-lightness)*dl : lightness*dl)))
                let out = Self.rgb(hue:h,saturation:saturation,lightness:l)
                values += [Float(out[0]),Float(out[1]),Float(out[2]),1]
            } } }
            data = values.withUnsafeBytes { Data($0) }; cache.countLimit = 8; cache.setObject(data as NSData,forKey:key)
        }
        return image.applyingFilter("CIColorCubeWithColorSpace",parameters:["inputCubeDimension":33,"inputCubeData":data,"inputColorSpace":CGColorSpace(name:CGColorSpace.sRGB)!])
    }
    public static func rgb(hue:Double,saturation:Double,lightness:Double) -> [Double] {
        let h = (hue.truncatingRemainder(dividingBy:1)+1).truncatingRemainder(dividingBy:1)
        let c = (1-abs(2*lightness-1))*saturation, x = c*(1-abs((h*6).truncatingRemainder(dividingBy:2)-1)), m = lightness-c/2
        let parts:[[Double]] = [[c,x,0],[x,c,0],[0,c,x],[0,x,c],[x,0,c],[c,0,x]]
        return parts[min(5,Int(h*6))].map { $0+m }
    }

}
