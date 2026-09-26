import Foundation
import ImageIO

/// What OpenStill reads from XMP: library metadata plus any Camera Raw develop settings.
public struct XMPMetadata: Equatable {
    /// 0…5. Adobe Bridge writes −1 for rejected photos; that becomes `flag = .reject`.
    public var rating: Int?
    public var flag: PhotoFlag?
    public var label: ColorLabel?
    public var iptc = IPTCMetadata()
    /// Camera Raw settings (`crs:` namespace) with simple values, by name, e.g. "Exposure2012": "+0.50".
    public var cameraRaw: [String: String] = [:]
    /// Camera Raw settings that are lists, e.g. "ToneCurvePV2012": ["0, 0", "255, 255"].
    public var cameraRawLists: [String: [String]] = [:]
    public init() {}
    /// Whether anything differs from an unrated, unflagged, unlabeled photo without metadata.
    public var isSet: Bool { (rating ?? 0) > 0 || (flag ?? PhotoFlag.none) != PhotoFlag.none || (label ?? ColorLabel.none) != ColorLabel.none || !iptc.isEmpty }
    public var hasLibraryMetadata: Bool { rating != nil || flag != nil || label != nil || !iptc.isEmpty }
    public var hasDevelopSettings: Bool { cameraRaw.keys.contains { !XMPSidecar.bookkeeping.contains($0) } || !cameraRawLists.isEmpty }

    /// The library fields of a record, as they are written to XMP.
    public init(record: PhotoRecord) {
        rating = record.rating; flag = record.flag; label = record.colorLabel; iptc = record.iptc
    }
    /// Copies rating, flag, label and metadata into a record. Fields missing from the XMP are left alone.
    public func apply(to record: inout PhotoRecord) {
        if let rating { record.rating = min(5, max(0, rating)) }
        if let flag { record.flag = flag }
        if let label { record.colorLabel = label }
        if !iptc.isEmpty { record.iptc = record.iptc.isEmpty ? iptc : record.iptc.applying(iptc) }
    }
}

public enum XMPError: LocalizedError {
    case unreadable, unwritable
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "The XMP file couldn’t be read."
        case .unwritable: return "The XMP metadata couldn’t be written."
        }
    }
}

/// Reads and writes `.xmp` sidecars next to photos, as Lightroom and Bridge do.
/// OpenStill only replaces the tags it owns and keeps everything else, including Camera Raw settings.
public enum XMPSidecar {
    public static let autoWriteKey = "writeXMPSidecars"
    /// The preference "Write metadata to XMP sidecars automatically".
    public static var autoWrite: Bool { UserDefaults.standard.bool(forKey: autoWriteKey) }

    enum Namespace {
        static let xmp = "http://ns.adobe.com/xap/1.0/"
        static let dc = "http://purl.org/dc/elements/1.1/"
        static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
        static let iptc = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
        static let lightroom = "http://ns.adobe.com/lightroom/1.0/"
        static let cameraRaw = "http://ns.adobe.com/camera-raw-settings/1.0/"
        static let openStill = "https://github.com/haon-v2/OpenStill/ns/1.0/"
    }
    /// Camera Raw bookkeeping values that aren't develop settings.
    static let bookkeeping: Set<String> = ["Version", "ProcessVersion", "HasSettings", "HasCrop", "AlreadyApplied", "RawFileName", "CameraProfileDigest", "ToneCurveName", "ToneCurveName2012", "ToneCurveName2012Digest", "LookName", "CropConstrainToWarp", "CropConstrainToUnitSquare", "OverrideLookVignette", "CompatibleVersion", "AutoWhiteVersion", "GrainSeed", "HDREditMode", "HDRMaxValue", "CurveRefineSaturation"]

    /// `IMG_0001.CR2` → `IMG_0001.xmp`, the name Lightroom and Bridge use.
    public static func url(for photo: URL) -> URL { photo.deletingPathExtension().appendingPathExtension("xmp") }

    /// The sidecar's XMP, or the XMP embedded in the photo when there is no sidecar.
    public static func read(_ photo: URL) -> XMPMetadata? {
        let sidecar = url(for: photo)
        if let data = try? Data(contentsOf: sidecar), let xmp = parse(data) { return xmp }
        guard let source = CGImageSourceCreateWithURL(photo as CFURL, nil), let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        return parse(metadata)
    }
    public static func parse(_ data: Data) -> XMPMetadata? {
        CGImageMetadataCreateFromXMPData(data as CFData).map(parse)
    }

    static func parse(_ metadata: CGImageMetadata) -> XMPMetadata {
        var out = XMPMetadata()
        var subjects: [String] = [], hierarchy: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            guard let namespace = CGImageMetadataTagCopyNamespace(tag) as String?, let name = CGImageMetadataTagCopyName(tag) as String? else { return true }
            let text = string(tag), list = strings(tag)
            switch (namespace, name) {
            case (Namespace.xmp, "Rating"):
                if let value = text.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) {
                    if value < 0 { out.flag = .reject; out.rating = 0 } else { out.rating = min(5, max(0, Int(value.rounded()))) }
                }
            case (Namespace.xmp, "Label"):
                if let text, let label = ColorLabel.allCases.first(where: { $0 != .none && $0.rawValue.caseInsensitiveCompare(text.trimmingCharacters(in: .whitespaces)) == .orderedSame }) { out.label = label }
            case (Namespace.openStill, "Flag"):
                if let text, let flag = PhotoFlag(rawValue: text) { out.flag = flag }
            case (Namespace.dc, "title"): out.iptc.title = text ?? ""
            case (Namespace.dc, "description"): out.iptc.caption = text ?? ""
            case (Namespace.dc, "creator"): out.iptc.creator = list.joined(separator: "; ")
            case (Namespace.dc, "rights"): out.iptc.copyright = text ?? ""
            case (Namespace.dc, "subject"): subjects = list
            case (Namespace.lightroom, "hierarchicalSubject"): hierarchy = list
            case (Namespace.photoshop, "City"): out.iptc.city = text ?? ""
            case (Namespace.photoshop, "State"): out.iptc.state = text ?? ""
            case (Namespace.photoshop, "Country"): out.iptc.country = text ?? ""
            case (Namespace.iptc, "Location"): out.iptc.location = text ?? ""
            case (Namespace.cameraRaw, _):
                switch CGImageMetadataTagGetType(tag) {
                case .string: if let text { out.cameraRaw[name] = text }
                case .arrayOrdered, .arrayUnordered: out.cameraRawLists[name] = list
                default: out.cameraRaw[name] = text ?? "set"   // masks and local corrections: reported, not applied
                }
            default: break
            }
            return true
        }
        // Hierarchical keywords ("Places|France|Paris") win; plain subjects that aren't part of one are kept as they are.
        let paths = hierarchy.map { $0.split(separator: "|").map(String.init).joined(separator: " > ") }
        let parts = Set(paths.flatMap { $0.components(separatedBy: " > ").map { $0.lowercased() } })
        out.iptc.keywords = paths + subjects.filter { !parts.contains($0.lowercased()) }
        out.iptc = out.iptc.sanitized
        return out
    }
    /// The tags in an array value (lists and alternative text come back as arrays of tags).
    static func elements(_ value: CFTypeRef?) -> [CGImageMetadataTag] {
        guard let items = value as? [AnyObject] else { return [] }
        return items.compactMap { item in CFGetTypeID(item) == CGImageMetadataTagGetTypeID() ? (item as! CGImageMetadataTag) : nil }
    }
    /// A tag's text: a plain string, the default language of alternative text, or the first list item.
    static func string(_ tag: CGImageMetadataTag) -> String? {
        let value = CGImageMetadataTagCopyValue(tag)
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        guard CGImageMetadataTagGetType(tag) == .alternateText else { return strings(tag).first }
        let items = elements(value)
        func isDefault(_ item: CGImageMetadataTag) -> Bool {
            elements(CGImageMetadataTagCopyQualifiers(item)).contains { CGImageMetadataTagCopyName($0) as String? == "lang" && (CGImageMetadataTagCopyValue($0) as? String) == "x-default" }
        }
        let chosen = items.first(where: isDefault) ?? items.first
        return chosen.flatMap { CGImageMetadataTagCopyValue($0) as? String }
    }
    static func strings(_ tag: CGImageMetadataTag) -> [String] {
        let value = CGImageMetadataTagCopyValue(tag)
        if let text = value as? String { return [text] }
        if let items = value as? [AnyObject], items.allSatisfy({ $0 is String }) { return items.compactMap { $0 as? String } }
        return elements(value).compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    /// Writes the record's rating, flag, label and metadata to the photo's sidecar, keeping every other tag already in it.
    @discardableResult public static func write(_ record: PhotoRecord, for photo: URL) throws -> URL {
        let sidecar = url(for: photo)
        let existing = try? Data(contentsOf: sidecar)
        let data = try xmpData(XMPMetadata(record: record), merging: existing)
        if data == existing { return sidecar }
        try data.write(to: sidecar, options: .atomic)
        return sidecar
    }
    /// XMP for the library fields, on top of an existing packet whose other tags are kept.
    public static func xmpData(_ xmp: XMPMetadata, merging existing: Data? = nil) throws -> Data {
        let base = existing.flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }
        guard let metadata = base.flatMap({ CGImageMetadataCreateMutableCopy($0) }) ?? CGImageMetadataCreateMutable() as CGMutableImageMetadata? else { throw XMPError.unwritable }
        for (namespace, prefix) in [(Namespace.xmp, "xmp"), (Namespace.dc, "dc"), (Namespace.photoshop, "photoshop"), (Namespace.iptc, "Iptc4xmpCore"),
                                    (Namespace.lightroom, "lr"), (Namespace.openStill, "openstill")] {
            // Fails harmlessly when the packet already declares the namespace.
            CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace as CFString, prefix as CFString, nil)
        }
        func set(_ namespace: String, _ prefix: String, _ name: String, _ type: CGImageMetadataType, _ value: Any?) {
            let path = "\(prefix):\(name)" as CFString
            CGImageMetadataRemoveTagWithPath(metadata, nil, path)
            guard let value, let tag = CGImageMetadataTagCreate(namespace as CFString, prefix as CFString, name as CFString, type, value as CFTypeRef) else { return }
            CGImageMetadataSetTagWithPath(metadata, nil, path, tag)
        }
        func text(_ s: String) -> String? { s.isEmpty ? nil : s }
        func alternative(_ s: String) -> Any? { s.isEmpty ? nil : ["x-default": s] as NSDictionary }
        let m = xmp.iptc.sanitized
        let rating = xmp.flag == .reject && (xmp.rating ?? 0) == 0 ? nil : xmp.rating
        set(Namespace.xmp, "xmp", "Rating", .string, rating.map { String($0) })
        set(Namespace.xmp, "xmp", "Label", .string, xmp.label.flatMap { $0 == ColorLabel.none ? nil : $0.title })
        set(Namespace.openStill, "openstill", "Flag", .string, xmp.flag.flatMap { $0 == PhotoFlag.none ? nil : $0.rawValue })
        set(Namespace.dc, "dc", "title", .alternateText, alternative(m.title))
        set(Namespace.dc, "dc", "description", .alternateText, alternative(m.caption))
        set(Namespace.dc, "dc", "creator", .arrayOrdered, m.creator.isEmpty ? nil : [m.creator] as NSArray)
        set(Namespace.dc, "dc", "rights", .alternateText, alternative(m.copyright))
        // dc:subject lists every level by name; lr:hierarchicalSubject keeps the paths, as Lightroom writes them.
        var names: [String] = []
        for path in m.keywordPaths { if let leaf = path.components(separatedBy: " > ").last, !names.contains(leaf) { names.append(leaf) } }
        set(Namespace.dc, "dc", "subject", .arrayUnordered, names.isEmpty ? nil : names as NSArray)
        let hierarchical = m.keywords.filter { $0.contains(" > ") }.map { $0.replacingOccurrences(of: " > ", with: "|") }
        set(Namespace.lightroom, "lr", "hierarchicalSubject", .arrayUnordered, hierarchical.isEmpty ? nil : hierarchical as NSArray)
        set(Namespace.photoshop, "photoshop", "City", .string, text(m.city))
        set(Namespace.photoshop, "photoshop", "State", .string, text(m.state))
        set(Namespace.photoshop, "photoshop", "Country", .string, text(m.country))
        set(Namespace.iptc, "Iptc4xmpCore", "Location", .string, text(m.location))
        guard let data = CGImageMetadataCreateXMPData(metadata, nil) as Data? else { throw XMPError.unwritable }
        return data
    }
}
