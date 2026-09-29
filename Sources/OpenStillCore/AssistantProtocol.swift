import Foundation
import CryptoKit

/// Any JSON value: tool arguments and results passed between OpenStill and the OpenStill MCP.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v.isFinite ? v : 0)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    public var double: Double? { if case .number(let v) = self { return v }; if case .string(let s) = self { return Double(s) }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var int: Int? { double.flatMap { $0.isFinite ? Int($0) : nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
}

/// The local connection between OpenStill and the OpenStill MCP (a separate, optional download).
/// OpenStill is the only process that saves edits: the MCP only sends requests here, so AI edits and your own never conflict.
public enum Assistant {
    /// Bumped only for changes an older MCP or app can't understand.
    public static let protocolVersion = 1
    /// A fixed place the MCP can find, independent of a chosen catalog location.
    public static var folder: URL {
        if let path = ProcessInfo.processInfo.environment["OPENSTILL_ASSISTANT_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenStill", isDirectory: true)
    }
    public static var socketURL: URL { folder.appendingPathComponent("assistant.sock") }
    public static var mcpFolder: URL { folder.appendingPathComponent("MCP", isDirectory: true) }
    public static let allowKey = "OpenStillAllowAssistants"
    public static let previewKey = "OpenStillAssistantPreviewSize"
    public static let repository = "haon-v2/OpenStill-MCP"
    /// The longest edge of previews the AI may look at (512–2048, default 1024).
    public static func previewSize(_ stored: Int?) -> Int { min(2048, max(512, stored ?? 1024)) }
}

/// One line of newline-delimited JSON on the socket, in either direction.
/// hello (MCP → app) · request / response (MCP → app → MCP) · sample / sampleResult (app → MCP → client → app).
public struct AssistantMessage: Codable, Equatable {
    public var type: String
    public var id: String?
    public var version: Int?
    public var tool: String?
    public var arguments: JSONValue?
    public var result: JSONValue?
    public var error: String?
    public var client: AssistantClient?
    public init(type: String, id: String? = nil, version: Int? = nil, tool: String? = nil, arguments: JSONValue? = nil, result: JSONValue? = nil, error: String? = nil, client: AssistantClient? = nil) {
        self.type = type; self.id = id; self.version = version; self.tool = tool; self.arguments = arguments; self.result = result; self.error = error; self.client = client
    }
    public static func response(to id: String?, _ result: JSONValue) -> AssistantMessage { AssistantMessage(type: "response", id: id, result: result) }
    public static func failure(to id: String?, _ message: String) -> AssistantMessage { AssistantMessage(type: "response", id: id, error: message) }
    public func line() throws -> Data { var data = try JSONEncoder().encode(self); data.append(0x0A); return data }
}
/// The AI app on the other end of the MCP (for example "Claude"), and whether it can answer OpenStill's own AI requests (MCP sampling).
public struct AssistantClient: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var supportsSampling: Bool
    public init(name: String, version: String, supportsSampling: Bool) { self.name = name; self.version = version; self.supportsSampling = supportsSampling }
}
public enum AssistantError: LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
extension Assistant {
    /// Checks an MCP's hello. A different protocol version names which side needs updating.
    public static func accept(_ hello: AssistantMessage) throws -> AssistantClient {
        guard hello.type == "hello", let version = hello.version else { throw AssistantError.message("Expected a hello from OpenStill MCP.") }
        if version > protocolVersion { throw AssistantError.message("This OpenStill MCP is newer than OpenStill. Update OpenStill.") }
        if version < protocolVersion { throw AssistantError.message("This OpenStill MCP is out of date. Update it in Settings → AI Assistant.") }
        return hello.client ?? AssistantClient(name: "AI assistant", version: "", supportsSampling: false)
    }
}

/// Splits a byte stream into messages, one per line, refusing runaway lines.
public struct AssistantFraming {
    public static let maximumLine = 48_000_000
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [AssistantMessage] {
        buffer.append(data)
        var messages: [AssistantMessage] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { continue }
            messages.append(try JSONDecoder().decode(AssistantMessage.self, from: Data(line)))
        }
        if buffer.count > Self.maximumLine { buffer.removeAll(); throw AssistantError.message("A message was too large.") }
        return messages
    }
}

/// The sliders an AI can set by name, in OpenStill's own units.
public enum AssistantAdjustments {
    public struct Slider {
        public let name: String
        public let path: WritableKeyPath<PhotoEdits, Double>
        public let range: ClosedRange<Double>
        public let neutral: Double
        public let help: String
    }
    public static let sliders: [Slider] = [
        Slider(name: "exposure", path: \.exposure, range: -4...4, neutral: 0, help: "Stops of brightness."),
        Slider(name: "contrast", path: \.contrast, range: 0.5...1.5, neutral: 1, help: "Smart Contrast: 1 is neutral, 1.5 strongest, 0.5 flattest."),
        Slider(name: "highlights", path: \.highlightsAmount, range: -1...1, neutral: 0, help: "−1 recovers bright areas, +1 brightens them."),
        Slider(name: "shadows", path: \.shadowsAmount, range: -1...1, neutral: 0, help: "−1 deepens shadows, +1 lifts them."),
        Slider(name: "whites", path: \.whites, range: -1...1, neutral: 0, help: "Sets the white point."),
        Slider(name: "blacks", path: \.blacks, range: -1...1, neutral: 0, help: "Sets the black point."),
        Slider(name: "temperature", path: \.temperature, range: 2500...10000, neutral: 6500, help: "White balance in kelvin; higher is warmer."),
        Slider(name: "tint", path: \.tint, range: -100...100, neutral: 0, help: "Positive adds magenta, negative adds green."),
        Slider(name: "vibrance", path: \.vibrance, range: -1...1, neutral: 0, help: "Boosts muted colors more than saturated ones."),
        Slider(name: "saturation", path: \.saturation, range: 0...2, neutral: 1, help: "1 is neutral, 0 is black and white."),
        Slider(name: "clarity", path: \.clarity, range: -1...1, neutral: 0, help: "Broad midtone contrast."),
        Slider(name: "texture", path: \.texture, range: -1...1, neutral: 0, help: "Medium-sized detail."),
        Slider(name: "dehaze", path: \.dehaze, range: -1...1, neutral: 0, help: "Removes (or adds) haze."),
        Slider(name: "sharpness", path: \.sharpness, range: 0...2, neutral: 0, help: "Sharpening amount."),
        Slider(name: "noise_reduction", path: \.denoise, range: 0...1, neutral: 0, help: "Luminance noise reduction."),
        Slider(name: "vignette", path: \.vignette, range: -1...1, neutral: 0, help: "Negative darkens the edges, positive lightens them."),
        Slider(name: "straighten", path: \.straighten, range: -20...20, neutral: 0, help: "Rotation in degrees."),
        Slider(name: "lut_amount", path: \.lutAmount, range: 0...1, neutral: 1, help: "Strength of the applied LUT."),
    ]
    /// Applies the named values. Values outside a slider's range are limited to it; unknown names and non-numbers are refused.
    public static func apply(_ values: [String: JSONValue], to edits: PhotoEdits) throws -> (edits: PhotoEdits, changed: [String]) {
        guard !values.isEmpty else { throw AssistantError.message("Give at least one slider, e.g. {\"exposure\": 0.5}.") }
        var next = edits, changed: [String] = []
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            guard let slider = sliders.first(where: { $0.name == name }) else {
                throw AssistantError.message("Unknown slider “\(name)”. Sliders: " + sliders.map(\.name).joined(separator: ", ") + ".")
            }
            guard let number = value.double, number.isFinite else { throw AssistantError.message("“\(name)” needs a number.") }
            next[keyPath: slider.path] = min(slider.range.upperBound, max(slider.range.lowerBound, number))
            changed.append(name)
        }
        return (next.sanitized, changed)
    }
    /// The current values, for the AI to read before changing them.
    public static func describe(_ edits: PhotoEdits) -> JSONValue {
        var values: [String: JSONValue] = [:]
        for slider in sliders { values[slider.name] = .number((edits[keyPath: slider.path] * 1000).rounded() / 1000) }
        values["monochrome"] = .bool(edits.monochrome > 0.5)
        values["mask_layers"] = .array(edits.localAdjustments.map { .string($0.name) })
        values["lut"] = edits.advanced?.lutName.map { .string($0) } ?? .null
        values["cropped"] = .bool(edits.crop != nil)
        return .object(values)
    }
    /// A description of every slider, for the MCP's tool schema and the AI's help.
    public static var catalog: JSONValue {
        .array(sliders.map { .object(["name": .string($0.name), "min": .number($0.range.lowerBound), "max": .number($0.range.upperBound), "neutral": .number($0.neutral), "help": .string($0.help)]) })
    }
}

/// Where an imported LUT came from. Stored in the LUT library's sources.json.
public struct LUTSource: Codable, Equatable {
    public var name: String
    public var creator: String
    public var license: String
    public var sourcePage: String
    public var url: String
    public var foundByAI: Bool
    public init(name: String, creator: String, license: String, sourcePage: String, url: String, foundByAI: Bool) {
        self.name = name; self.creator = creator; self.license = license; self.sourcePage = sourcePage; self.url = url; self.foundByAI = foundByAI
    }
}
/// Imports free LUTs an AI found: https only, small files, a stated free license, and every file checked as a real 3D LUT.
public enum LUTImport {
    public static let maximumDownload = 20_000_000
    public static let maximumUnzipped = 200_000_000
    public static let maximumFiles = 60
    /// Licenses that allow free use, with the spellings people commonly write.
    public static let freeLicenses: [(name: String, aliases: [String])] = [
        ("CC0-1.0", ["cc0", "cc0 1.0", "cc0-1.0", "creative commons zero"]),
        ("Public Domain", ["public domain", "pd"]),
        ("CC-BY-4.0", ["cc-by-4.0", "cc by 4.0", "cc-by", "cc by", "creative commons attribution", "creative commons attribution 4.0"]),
        ("CC-BY-SA-4.0", ["cc-by-sa-4.0", "cc by-sa 4.0", "cc by sa", "cc-by-sa", "creative commons attribution-sharealike"]),
        ("MIT", ["mit", "mit license"]),
        ("Unlicense", ["unlicense", "the unlicense"]),
        ("Free for personal and commercial use", ["free for personal and commercial use", "free for commercial use", "royalty free", "royalty-free"]),
    ]
    /// The standard name of a free license, or nil when it isn't a recognized free license.
    public static func license(_ text: String) -> String? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return freeLicenses.first { $0.name.lowercased() == key || $0.aliases.contains(key) }?.name
    }
    public static func check(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else { throw AssistantError.message("LUTs can only be downloaded over https.") }
        guard url.user == nil, url.password == nil else { throw AssistantError.message("Links with a user name or password aren’t allowed.") }
        let local = host == "localhost" || host.hasSuffix(".local") || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") || host == "::1" || host.hasPrefix("[")
            || (host.hasPrefix("172.") && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0))
        guard !local else { throw AssistantError.message("LUTs can only come from public websites.") }
    }
    /// Validates and installs one downloaded .cube or .zip. Returns the installed files.
    public static func install(_ data: Data, suggestedName: String, source: LUTSource, into folder: URL) throws -> [URL] {
        guard let license = license(source.license) else {
            throw AssistantError.message("“\(source.license)” isn’t a recognized free license, so this LUT wasn’t imported. Free licenses: " + freeLicenses.map(\.name).joined(separator: ", ") + ".")
        }
        guard data.count <= maximumDownload else { throw AssistantError.message("This file is larger than 20 MB.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var cubes: [(name: String, text: String)] = []
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { cubes = try unzip(data) }
        else {
            guard let text = String(data: data, encoding: .utf8) else { throw AssistantError.message("This isn’t a .cube LUT or a .zip of them.") }
            cubes = [(suggestedName, text)]
        }
        var installed: [URL] = [], sources = provenance(folder)
        for cube in cubes {
            guard (try? CubeLUT(text: cube.text)) != nil else { continue }
            let base = cubes.count == 1 ? safeName(source.name) : safeName(source.name) + " — " + safeName(URL(fileURLWithPath: cube.name).deletingPathExtension().lastPathComponent)
            var target = folder.appendingPathComponent(base + ".cube"), n = 2
            while FileManager.default.fileExists(atPath: target.path) { target = folder.appendingPathComponent("\(base) \(n).cube"); n += 1 }
            try Data(cube.text.utf8).write(to: target, options: .atomic)
            installed.append(target)
        }
        guard !installed.isEmpty else { throw AssistantError.message("No valid 3D .cube LUT was found in this download.") }
        sources.removeAll { ($0["name"] as? String) == safeName(source.name) }
        sources.append(["name": safeName(source.name), "creator": source.creator, "source": source.sourcePage.isEmpty ? source.url : source.sourcePage,
                        "license": license, "url": source.url, "foundByAI": source.foundByAI])
        let json = try JSONSerialization.data(withJSONObject: sources, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: folder.appendingPathComponent("sources.json"), options: .atomic)
        return installed
    }
    static func provenance(_ folder: URL) -> [[String: Any]] {
        (try? Data(contentsOf: folder.appendingPathComponent("sources.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
    }
    /// Letters, digits, spaces and a few marks only: never a path.
    public static func safeName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()&+,"))
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { allowed.contains($0) ? $0 : " " }))
            .split(separator: " ").joined(separator: " ").prefix(80)
        return cleaned.isEmpty ? "Imported LUT" : String(cleaned)
    }
    /// Extracts only the .cube files, flattened (no folders, so no path tricks), after checking the unpacked size.
    static func unzip(_ data: Data) throws -> [(name: String, text: String)] {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("OpenStill-LUT-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let archive = temp.appendingPathComponent("download.zip"), out = temp.appendingPathComponent("out")
        try data.write(to: archive)
        let listing = try run("/usr/bin/unzip", ["-l", archive.path])
        // The last line is "  <total bytes>  <count> files".
        let total = listing.split(separator: "\n").last.flatMap { Int($0.split(separator: " ").first ?? "") } ?? Int.max
        guard total <= maximumUnzipped else { throw AssistantError.message("This archive unpacks to more than 200 MB.") }
        _ = try? run("/usr/bin/unzip", ["-qq", "-j", "-o", archive.path, "*.cube", "*.CUBE", "-d", out.path])
        let files = ((try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "cube" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= maximumFiles else { throw AssistantError.message("This archive has more than \(maximumFiles) LUTs.") }
        return files.compactMap { url in (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }.map { (url.lastPathComponent, $0) } }
    }
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: tool); task.arguments = arguments; task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        try task.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw AssistantError.message("This archive couldn’t be opened.") }
        return String(data: output, encoding: .utf8) ?? ""
    }
}

/// Which model designs logos: the connected AI assistant when it can answer (MCP sampling), otherwise the optional local model.
public enum LogoEngine: Equatable {
    case assistant(String)
    case local
    case unavailable
    public static func choose(assistant: AssistantClient?, localModelInstalled: Bool) -> LogoEngine {
        if let assistant, assistant.supportsSampling { return .assistant(assistant.name) }
        return localModelInstalled ? .local : .unavailable
    }
    public var label: String {
        switch self {
        case .assistant(let name): return "Designed by your connected AI (\(name))"
        case .local: return "Designed on this Mac (local model)"
        case .unavailable: return "Connect an AI assistant or download the local model to generate logos."
        }
    }
}

/// Finding photos in the catalog for an AI: simple filters, newest first, and a compact description of each.
public enum AssistantQuery {
    public static func filter(_ photos: [CatalogPhoto], _ args: [String: JSONValue]) -> [CatalogPhoto] {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate]
        func date(_ key: String) -> Date? { args[key]?.string.flatMap { iso.date(from: String($0.prefix(10))) } }
        let folder = args["folder"]?.string.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        let after = date("captured_after"), before = date("captured_before").map { $0.addingTimeInterval(86_400) }
        var result = photos.filter { p in
            if let folder, !(p.path == folder || p.path.hasPrefix(folder + "/")) { return false }
            if let text = args["text"]?.string, !p.matches(text: text) { return false }
            if let minimum = args["min_rating"]?.int, p.rating < minimum { return false }
            if let flag = args["flag"]?.string, p.flag.rawValue != flag { return false }
            if let label = args["label"]?.string, p.label.rawValue != label.lowercased() { return false }
            if let keyword = args["keyword"]?.string, !p.keywords.contains(where: { $0.localizedCaseInsensitiveContains(keyword) }) { return false }
            if let camera = args["camera"]?.string, !p.camera.localizedCaseInsensitiveContains(camera) { return false }
            if let edited = args["edited"]?.bool, p.edited != edited { return false }
            if let after, (p.captured ?? .distantPast) < after { return false }
            if let before, (p.captured ?? .distantFuture) >= before { return false }
            return true
        }
        result.sort { ($0.captured ?? Date(timeIntervalSince1970: $0.modified)) > ($1.captured ?? Date(timeIntervalSince1970: $1.modified)) }
        return Array(result.prefix(min(500, max(1, args["limit"]?.int ?? 50))))
    }
    public static func describe(_ p: CatalogPhoto) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(p.id.uuidString), "file": .string(p.filename), "path": .string(p.path),
                                      "rating": .number(Double(p.rating)), "flag": .string(p.flag.rawValue), "label": .string(p.label.rawValue),
                                      "edited": .bool(p.edited), "width": .number(Double(p.width)), "height": .number(Double(p.height))]
        if let captured = p.captured { o["captured"] = .string(ISO8601DateFormatter().string(from: captured)) }
        if !p.camera.isEmpty { o["camera"] = .string(p.camera) }
        if !p.lens.isEmpty { o["lens"] = .string(p.lens) }
        if let iso = p.iso { o["iso"] = .number(iso) }
        if let f = p.aperture { o["aperture"] = .number(f) }
        if let mm = p.focalLength { o["focal_length"] = .number(mm) }
        if !p.title.isEmpty { o["title"] = .string(p.title) }
        if !p.keywords.isEmpty { o["keywords"] = .array(p.keywords.map { .string($0) }) }
        return .object(o)
    }
}

/// Mask layers an AI can add: a linear or radial shape from coordinates, or an on-device AI selection, with the layer's own sliders.
public enum AssistantMasks {
    /// AI selections run with Apple Vision (or the local sky model) on this Mac, the same as the New Mask menu.
    public static let aiKinds = ["subject": "ai.subject", "sky": "ai.sky", "background": "ai.background", "people": "ai.people"]
    public static let kinds = ["linear", "radial"] + aiKinds.keys.sorted()
    public static let sliderNames: [(String, WritableKeyPath<LocalSettings, Double>)] = [
        ("exposure", \.exposure), ("contrast", \.contrast), ("highlights", \.highlights), ("shadows", \.shadows), ("whites", \.whites), ("blacks", \.blacks),
        ("temperature", \.temperature), ("tint", \.tint), ("saturation", \.saturation), ("clarity", \.clarity), ("texture", \.texture),
        ("dehaze", \.dehaze), ("sharpness", \.sharpness), ("noise", \.noise),
    ]
    /// Sets a layer's sliders by name (exposure −4…4 stops, noise 0…1, the rest −1…1).
    public static func settings(_ values: [String: JSONValue], onto start: LocalSettings = LocalSettings()) throws -> LocalSettings {
        var s = start
        for (name, value) in values {
            guard let path = sliderNames.first(where: { $0.0 == name })?.1 else {
                throw AssistantError.message("Unknown mask slider “\(name)”. Mask sliders: " + sliderNames.map(\.0).joined(separator: ", ") + ".")
            }
            guard let number = value.double, number.isFinite else { throw AssistantError.message("“\(name)” needs a number.") }
            s[keyPath: path] = number
        }
        return s.sanitized
    }
    /// A linear or radial mask from coordinates measured from the photo's top-left corner (0…1).
    /// Linear: `from` is fully affected, fading to nothing at `to`. Radial: `center` and `radius` (fractions of width and height).
    public static func shape(_ kind: String, _ args: [String: JSONValue]) throws -> AdjustmentMask {
        func point(_ key: String, _ fallback: CGPoint) throws -> CGPoint {
            guard let value = args[key] else { return fallback }
            guard let list = value.array, list.count == 2, let x = list[0].double, let y = list[1].double, x.isFinite, y.isFinite else {
                throw AssistantError.message("“\(key)” needs [x, y] from the top-left, each 0 to 1.")
            }
            return CGPoint(x: min(1, max(0, x)), y: 1 - min(1, max(0, y)))
        }
        var mask = AdjustmentMask(kind: kind)
        switch kind {
        case "linear":
            mask.start = MaskPoint(try point("from", CGPoint(x: 0.5, y: 1))); mask.end = MaskPoint(try point("to", CGPoint(x: 0.5, y: 0.5)))
        case "radial":
            let center = try point("center", CGPoint(x: 0.5, y: 0.5))
            var rx = 0.3, ry = 0.3
            if let radius = args["radius"] {
                if let r = radius.double { rx = r; ry = r }
                else if let list = radius.array, list.count == 2, let a = list[0].double, let b = list[1].double { rx = a; ry = b }
                else { throw AssistantError.message("“radius” needs a number or [width, height] as fractions of the photo.") }
            }
            rx = min(1.5, max(0.01, rx.isFinite ? rx : 0.3)); ry = min(1.5, max(0.01, ry.isFinite ? ry : 0.3))
            mask.start = MaskPoint(center); mask.end = MaskPoint(CGPoint(x: center.x + rx, y: center.y + ry))
            mask.feather = 0.5
        default: throw AssistantError.message("Shapes are “linear” or “radial”.")
        }
        if let feather = args["feather"]?.double, feather.isFinite { mask.feather = min(1, max(0, feather)) }
        mask.inverted = args["invert"]?.bool ?? false
        return mask
    }
}
