import Foundation
import ImageIO

/// Reads camera-rendered JPEGs without asking a RAW developer to recreate the look.
/// Panasonic documents these container entries as JpgFromRaw (0x002e) and
/// JpgFromRaw2 (0x0127): https://exiftool.org/TagNames/PanasonicRaw.html
enum PanasonicPreview {
    struct JPEG {
        let data: Data
        let width: Int
        let height: Int
    }

    static func read(_ url: URL) -> [JPEG] {
        guard url.pathExtension.lowercased() == "rw2",
              let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        do {
            let fileSize = try file.seekToEnd()
            func bytes(at offset: UInt64, count: Int) throws -> Data? {
                guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else { return nil }
                try file.seek(toOffset: offset)
                guard let data = try file.read(upToCount: count), data.count == count else { return nil }
                return data
            }
            guard let header = try bytes(at: 0, count: 8) else { return [] }
            let little: Bool
            if header[0] == 0x49 && header[1] == 0x49 { little = true }
            else if header[0] == 0x4d && header[1] == 0x4d { little = false }
            else { return [] }
            func u16(_ data: Data, _ offset: Int) -> UInt16 {
                let a = UInt16(data[offset]), b = UInt16(data[offset + 1])
                return little ? a | (b << 8) : (a << 8) | b
            }
            func u32(_ data: Data, _ offset: Int) -> UInt32 {
                let a = UInt32(u16(data, offset)), b = UInt32(u16(data, offset + 2))
                return little ? a | (b << 16) : (a << 16) | b
            }
            guard [UInt16(42), 85].contains(u16(header, 2)) else { return [] }
            let directoryOffset = UInt64(u32(header, 4))
            guard directoryOffset >= 8, let countData = try bytes(at: directoryOffset, count: 2) else { return [] }
            let count = Int(u16(countData, 0))
            guard count <= 4096, let entries = try bytes(at: directoryOffset + 2, count: count * 12) else { return [] }
            var orientation = 1
            var locations: [(UInt64, Int)] = []
            for index in 0..<count {
                let start = index * 12, tag = u16(entries, start), type = u16(entries, start + 2)
                let length = u32(entries, start + 4)
                if tag == 0x0112, type == 3, length == 1 {
                    let value = Int(u16(entries, start + 8))
                    if (1...8).contains(value) { orientation = value }
                }
                if [UInt16(0x002e), 0x0127].contains(tag), [UInt16(1), 7].contains(type),
                   length > 4, length <= 64 * 1024 * 1024 {
                    locations.append((UInt64(u32(entries, start + 8)), Int(length)))
                }
            }
            var previews: [JPEG] = []
            for (offset, length) in locations {
                guard let jpeg = try bytes(at: offset, count: length), jpeg.starts(with: [0xff, 0xd8, 0xff]),
                      let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 100_000, height <= 100_000,
                      Int64(width) * Int64(height) <= 150_000_000 else { continue }
                // The S9's full-size JPEG has no EXIF orientation. Supply the container's
                // orientation in a tiny APP1 segment without recompressing any pixels.
                let data = properties[kCGImagePropertyOrientation] == nil
                    ? withOrientation(orientation, jpeg: jpeg) : jpeg
                previews.append(JPEG(data: data, width: width, height: height))
            }
            return previews.sorted { Int64($0.width) * Int64($0.height) > Int64($1.width) * Int64($1.height) }
        } catch { return [] }
    }

    static func withOrientation(_ orientation: Int, jpeg: Data) -> Data {
        guard (2...8).contains(orientation), jpeg.starts(with: [0xff, 0xd8]) else { return jpeg }
        let payload: [UInt8] = [
            0x45, 0x78, 0x69, 0x66, 0, 0, // Exif signature
            0x49, 0x49, 0x2a, 0, 8, 0, 0, 0, // Little-endian TIFF
            1, 0, // One IFD entry
            0x12, 0x01, 3, 0, 1, 0, 0, 0, UInt8(orientation), 0, 0, 0,
            0, 0, 0, 0 // No next IFD
        ]
        let segmentLength = payload.count + 2
        var result = Data([0xff, 0xd8, 0xff, 0xe1, UInt8(segmentLength >> 8), UInt8(segmentLength & 0xff)])
        result.append(contentsOf: payload)
        result.append(jpeg.dropFirst(2))
        return result
    }
}
