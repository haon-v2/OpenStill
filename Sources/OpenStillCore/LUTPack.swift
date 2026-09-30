import Foundation
import CryptoKit

/// Reads looks from the bundled `Library.lutpack` built by scripts/build-lut-pack.py.
///
/// The file starts with `OSLUTPK1`; each look is a raw-deflate stream of three planes (R, G, B) of dimension³
/// little-endian UInt16 values (value / (2^bits − 1); bits is 16 unless the catalog says otherwise), red index fastest,
/// stored as differences from the previous value (mod 2¹⁶).
public enum LUTPack {
    public static let magic = Data("OSLUTPK1".utf8)
    private static let lock = NSLock()
    private static var mapped: [URL:Data] = [:]
    private static let cache = NSCache<NSString,NSString>()

    private static func bytes(_ url:URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let data = mapped[url] { return data }
        let data = try Data(contentsOf:url,options:.alwaysMapped)
        guard data.prefix(magic.count) == magic else { throw LUTError.invalid }
        mapped[url] = data; return data
    }
    /// The decoded planes as little-endian UInt16 bytes, checked against the catalog's SHA-256.
    static func planes(pack url:URL, offset:Int, length:Int, dimension:Int, checksum:String) throws -> [UInt16] {
        let data = try bytes(url)
        guard (2...65).contains(dimension), offset >= magic.count, length > 0, offset+length <= data.count else { throw LUTError.invalid }
        let blob = data.subdata(in:data.startIndex+offset..<data.startIndex+offset+length)
        guard let inflated = try? (blob as NSData).decompressed(using:.zlib) as Data,
              inflated.count == dimension*dimension*dimension*3*2 else { throw LUTError.invalid }
        var values = [UInt16](repeating:0,count:inflated.count/2), previous:UInt16 = 0
        inflated.withUnsafeBytes { raw in
            for i in 0..<values.count {
                previous &+= UInt16(raw[2*i]) | UInt16(raw[2*i+1]) << 8
                values[i] = previous
            }
        }
        let digest = values.withUnsafeBytes { SHA256.hash(data:$0) }.map { String(format:"%02x",$0) }.joined()
        guard digest == checksum else { throw LUTError.invalid }
        return values
    }
    private static let tables = NSCache<NSString,LUTTableBox>()
    /// The look as a table, built without the `.cube` text: each value is `Float(Double(micro) / 1e6)`, which equals
    /// what parsing that text's six-decimal value gives for every possible value (checked for all 1,000,001), so a
    /// preview matches the copy applied to a photo exactly.
    public static func lut(pack url:URL, entry:LUTCatalogEntry) throws -> CubeLUT {
        guard let offset = entry.offset, let length = entry.length, let dimension = entry.dimension else { throw LUTError.invalid }
        let key = "\(url.path)#\(entry.id)" as NSString
        if let box = tables.object(forKey:key) { return box.value }
        let bits = entry.bits ?? 16
        guard (8...16).contains(bits) else { throw LUTError.invalid }
        let values = try planes(pack:url,offset:offset,length:length,dimension:dimension,checksum:entry.checksum), top = (1<<bits)-1
        guard values.allSatisfy({ Int($0) <= top }) else { throw LUTError.invalid }
        let count = dimension*dimension*dimension
        var rgba = [Float](repeating:1,count:count*4)
        for i in 0..<count {
            for c in 0..<3 { rgba[i*4+c] = Float(Double(micro(values[c*count+i],top))/1_000_000) }
        }
        let lut = CubeLUT(dimension:dimension,rgba:rgba)
        tables.countLimit = 48; tables.setObject(LUTTableBox(lut),forKey:key)
        return lut
    }
    private static func micro(_ value:UInt16, _ top:Int) -> Int { min(1_000_000,(Int(value)*1_000_000+top/2)/top) }
    /// `.cube` text for a packed look, so an applied look can be copied into the photo's own assets.
    public static func cubeText(pack url:URL, entry:LUTCatalogEntry) throws -> String {
        guard let offset = entry.offset, let length = entry.length, let dimension = entry.dimension else { throw LUTError.invalid }
        let key = "\(url.path)#\(entry.id)" as NSString
        if let text = cache.object(forKey:key) { return text as String }
        let bits = entry.bits ?? 16
        guard (8...16).contains(bits) else { throw LUTError.invalid }
        let values = try planes(pack:url,offset:offset,length:length,dimension:dimension,checksum:entry.checksum), top = (1<<bits)-1
        guard values.allSatisfy({ Int($0) <= top }) else { throw LUTError.invalid }
        let count = dimension*dimension*dimension
        var text = "TITLE \"\(entry.name.replacingOccurrences(of:"\"",with:"'"))\"\nLUT_3D_SIZE \(dimension)\n"
        text.reserveCapacity(text.utf8.count+count*27)
        for i in 0..<count {
            text += fixed(values[i],top) + " " + fixed(values[count+i],top) + " " + fixed(values[2*count+i],top) + "\n"
        }
        cache.countLimit = 16; cache.setObject(text as NSString,forKey:key)
        return text
    }
    /// value / top with six decimals, without Foundation formatting (a look has up to 107,811 of these).
    private static func fixed(_ value:UInt16, _ top:Int) -> String {
        let micro = micro(value,top)
        if micro >= 1_000_000 { return "1.000000" }
        let digits = String(micro)
        return "0." + String(repeating:"0",count:6-digits.count) + digits
    }
}
private final class LUTTableBox { let value:CubeLUT; init(_ value:CubeLUT) { self.value = value } }
