import Foundation
import ImageIO

public struct PhotoMetadata {
    public let camera: String
    public let lens: String
    public let shutter: String
    public let aperture: String
    public let iso: String
    public let focalLength: String
    public let captured: String
    public let dimensions: String
    public let fileSize: String
    public let format: String
    public let exposureBias: String
    public let focalLength35mm: String
    public let allFields: [String]

    public static func read(_ url: URL) -> PhotoMetadata {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any] ?? [:]
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return PhotoMetadata(properties: properties, fileBytes: size, extension: url.pathExtension)
    }

    public init(properties: [String: Any], fileBytes: Int = 0, extension fileExtension: String = "") {
        func flatten(_ dictionary: [String: Any], prefix: String = "") -> [String] {
            dictionary.keys.sorted().flatMap { key -> [String] in
                let name = prefix.isEmpty ? key.trimmingCharacters(in: CharacterSet(charactersIn: "{}")) : prefix + " · " + key
                let value = dictionary[key]!
                if let nested = value as? [String: Any] { return flatten(nested, prefix: name) }
                if let data = value as? Data { return ["\(name): \(data.count) bytes (binary metadata)"] }
                return ["\(name): \(String(describing: value))"]
            }
        }
        allFields = flatten(properties)
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        let missing = "Not recorded"
        func string(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        }
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        func decimal(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
        let make = string(tiff["Make"])
        let model = string(tiff["Model"])
        if let make, let model {
            camera = model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
        } else { camera = model ?? make ?? missing }
        let lensModel = string(exif["LensModel"]) ?? string(aux["LensModel"]) ?? string(aux["Lens"])
        let lensMake = string(exif["LensMake"])
        if let lensModel {
            lens = lensMake.map { lensModel.localizedCaseInsensitiveContains($0) ? lensModel : "\($0) \(lensModel)" } ?? lensModel
        } else if let specification = exif["LensSpecification"] as? [NSNumber], specification.count == 4,
                  specification[0].doubleValue > 0, specification[1].doubleValue > 0 {
            let low = specification[0].doubleValue, high = specification[1].doubleValue
            let apertureLow = specification[2].doubleValue, apertureHigh = specification[3].doubleValue
            let range = low == high ? decimal(low) : "\(decimal(low))–\(decimal(high))"
            let fRange = apertureLow == apertureHigh ? decimal(apertureLow) : "\(decimal(apertureLow))–\(decimal(apertureHigh))"
            lens = "\(range) mm" + (apertureLow > 0 && apertureHigh > 0 ? " ƒ/\(fRange)" : "") + " (model not recorded)"
        } else { lens = missing }
        let exposure = number(exif["ExposureTime"]) ?? number(exif["ShutterSpeedValue"]).map { pow(2, -$0) }
        if let exposure, exposure > 0 {
            let reciprocal = (1 / exposure).rounded()
            shutter = exposure < 0.5 && reciprocal.isFinite ? "1/\(reciprocal.formatted(.number.grouping(.never).precision(.fractionLength(0)))) s" : "\(decimal(exposure)) s"
        } else { shutter = missing }
        let fNumber = number(exif["FNumber"]) ?? number(exif["ApertureValue"]).map { pow(2, $0 / 2) }
        aperture = fNumber.flatMap { $0 > 0 ? "ƒ/\(decimal($0))" : nil } ?? missing
        let isoValue = (exif["ISOSpeedRatings"] as? [NSNumber])?.first?.doubleValue ?? number(exif["PhotographicSensitivity"])
        iso = isoValue.map { decimal($0) } ?? missing
        focalLength = number(exif["FocalLength"]).map { "\(decimal($0)) mm" } ?? missing
        focalLength35mm = number(exif["FocalLenIn35mmFilm"]).flatMap { $0 > 0 ? "\(decimal($0)) mm" : nil } ?? missing
        exposureBias = number(exif["ExposureBiasValue"]).map { "\($0 > 0 ? "+" : "")\(decimal($0)) EV" } ?? missing
        if let date = string(exif["DateTimeOriginal"]) ?? string(tiff["DateTime"]) {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(secondsFromGMT: 0)
            parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let display = DateFormatter()
            display.dateFormat = "MMM d, yyyy · HH:mm:ss"
            display.timeZone = TimeZone(secondsFromGMT: 0)
            let stamp = parser.date(from: date).map { display.string(from: $0) } ?? date
            captured = stamp + (string(exif["OffsetTimeOriginal"]).map { " \($0)" } ?? "")
        } else { captured = missing }
        if let width = number(properties["PixelWidth"]), let height = number(properties["PixelHeight"]),
           width > 0, height > 0, width < Double(Int.max), height < Double(Int.max) {
            let orientation = number(properties["Orientation"]) ?? 1
            let swapped = orientation >= 5 && orientation <= 8
            dimensions = "\(Int(swapped ? height : width)) × \(Int(swapped ? width : height))"
        } else { dimensions = missing }
        fileSize = fileBytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(fileBytes), countStyle: .file) : "—"
        format = fileExtension.uppercased()
    }
}
