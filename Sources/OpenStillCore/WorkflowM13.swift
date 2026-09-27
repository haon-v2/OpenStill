import Foundation
import CoreImage
import CoreGraphics
import CoreText
import SQLite3

// MARK: - Edit In (Photoshop, Affinity or any app)

/// How "Edit In" hands a photo to another app: a rendered copy next to the original, added to the library and stacked with it.
public struct EditInSettings: Codable, Equatable {
    /// The app to open the copy in; nil opens it in the default app for the format.
    public var appPath: String?
    public var format: ExportFormat = .tiff
    public var profile: ExportProfile = .proPhotoRGB
    public var bitDepth = 16
    public init() {}
    public var exportSettings: ExportSettings {
        var s = ExportSettings(); s.format = format; s.profile = profile; s.bitDepth = bitDepth; s.quality = 1; s.keepMetadata = true
        return s.sanitized
    }
}
public enum EditIn {
    private static func file(_ root: URL) -> URL { root.appendingPathComponent("EditIn.json") }
    public static func load(root: URL = EditStorage.root) -> EditInSettings { (try? JSONDecoder().decode(EditInSettings.self, from: Data(contentsOf: file(root)))) ?? EditInSettings() }
    public static func save(_ settings: EditInSettings, root: URL = EditStorage.root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: file(root), options: .atomic)
    }
    /// "IMG_0042-Edit.tif", or "-Edit-2", "-Edit-3"… when that name is taken.
    public static func target(for source: URL, format: ExportFormat) -> URL {
        let ext = format == .jpeg ? "jpg" : format == .heif ? "heic" : format == .tiff ? "tif" : format.rawValue
        let folder = source.deletingLastPathComponent(), stem = source.deletingPathExtension().lastPathComponent + "-Edit"
        for n in 1..<10_000 {
            let candidate = folder.appendingPathComponent(stem + (n == 1 ? "" : "-\(n)") + "." + ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent(stem + "-" + UUID().uuidString.prefix(8) + "." + ext)
    }
    /// Renders the photo with its edits, adds the copy to the library and stacks it on top of the original.
    public static func prepare(_ item: ShootItem, settings: EditInSettings = load(), store: PhotoRecordStore = EditStorage.records) throws -> URL {
        let output = target(for: item.url, format: settings.format)
        let image = try ModernRenderer.render(source: item.url, recipe: item.record.active.recipe.sdr)
        try ModernRenderer.export(image, to: output, source: item.url, settings: settings.exportSettings, metadata: item.record.metadata, location: item.record.geotag)
        let copy = try store.record(for: output)
        // The copy carries the original's rating, label and keywords.
        _ = try? store.update(copy.id) { r in r.rating = item.record.rating; r.label = item.record.label; r.metadata = item.record.metadata }
        let existing = store.catalog?.stacks().first { $0.value.contains(item.id) }?.value ?? [item.id]
        _ = try? store.catalog?.createStack([copy.id] + existing.filter { $0 != copy.id })
        return output
    }
}

// MARK: - After export

/// What happens after an export finishes, like Lightroom's Post-Processing menu.
public enum ExportAfter: Codable, Equatable, Sendable {
    case nothing, showInFinder
    case openIn(app: String)
    /// A shell script or executable the person chose; it gets the exported files as arguments.
    case runScript(path: String)
    public var title: String {
        switch self {
        case .nothing: return "Do nothing"
        case .showInFinder: return "Show in Finder"
        case .openIn(let app): return "Open in " + ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        case .runScript(let path): return "Run " + (path as NSString).lastPathComponent
        }
    }
    /// Runs a chosen script with the exported files. Returns the exit status and what it printed.
    public static func runScript(_ path: String, files: [URL], timeout: TimeInterval = 300) throws -> (status: Int32, output: String) {
        let script = URL(fileURLWithPath: path)
        guard FileManager.default.isExecutableFile(atPath: script.path) || script.pathExtension == "sh" else { throw CocoaError(.fileReadNoPermission) }
        let process = Process(), pipe = Pipe()
        if FileManager.default.isExecutableFile(atPath: script.path) { process.executableURL = script; process.arguments = files.map(\.path) }
        else { process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [script.path] + files.map(\.path) }
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data.prefix(4000), as: UTF8.self))
    }
}

// MARK: - Smart Previews

/// Small, editable stand-ins for photos on drives that aren't connected: the decoded photo at 2560 pixels, before any edits.
/// While the original is missing, the renderer uses the preview; edits are saved to the original's record as usual.
public enum SmartPreviews {
    public static let longEdge = 2560
    public static func directory(root: URL = EditStorage.root) -> URL { root.appendingPathComponent("SmartPreviews", isDirectory: true) }
    public static func url(fingerprint: String, root: URL = EditStorage.root) -> URL { directory(root: root).appendingPathComponent(fingerprint + ".tiff") }
    public static func exists(_ record: PhotoRecord, root: URL = EditStorage.root) -> Bool { FileManager.default.fileExists(atPath: url(fingerprint: record.contentFingerprint, root: root).path) }
    /// Decodes the original (RAW decoding included) and saves it as a 16-bit TIFF.
    @discardableResult public static func build(_ source: URL, record: PhotoRecord, root: URL = EditStorage.root) throws -> URL {
        let recipe = record.active.recipe
        var image = try ModernRenderer.source(source, mode: recipe.sourceMode, raw: recipe.raw)
        let scale = min(1, Double(longEdge) / max(image.extent.width, image.extent.height))
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let target = url(fingerprint: record.contentFingerprint, root: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var settings = ExportSettings(); settings.format = .tiff; settings.bitDepth = 16; settings.profile = .proPhotoRGB; settings.keepMetadata = false
        let temp = target.deletingLastPathComponent().appendingPathComponent(".building-" + UUID().uuidString + ".tiff")
        try ModernRenderer.export(image, to: temp, source: nil, settings: settings)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }
    public static func remove(_ record: PhotoRecord, root: URL = EditStorage.root) { try? FileManager.default.removeItem(at: url(fingerprint: record.contentFingerprint, root: root)) }
    /// The preview to use for a missing original, found through the catalog by the original's path.
    public static func stand(in source: URL, root: URL = EditStorage.root, catalog: LibraryCatalog? = EditStorage.records.catalog) -> URL? {
        guard !FileManager.default.fileExists(atPath: source.path), let catalog, let id = catalog.recordID(path: source.standardizedFileURL.path),
              let fingerprint = catalog.photo(id)?.fingerprint, !fingerprint.isEmpty else { return nil }
        let preview = url(fingerprint: fingerprint, root: root)
        return FileManager.default.fileExists(atPath: preview.path) ? preview : nil
    }
    /// Total size on disk, for Settings.
    public static func diskUsage(root: URL = EditStorage.root) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(root: root), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

extension LibraryCatalog {
    /// The photo last seen at this path, whatever its size or date.
    public func recordID(path: String) -> UUID? {
        var id: UUID?
        _ = try? run("SELECT id FROM photos WHERE path = ? LIMIT 1", [.text(path)]) { id = UUID(uuidString: Self.text($0, 0)) }
        return id
    }
    /// A consistent copy of the catalog database, even while it's in use.
    public func backup(to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try execute("VACUUM INTO '" + destination.path.replacingOccurrences(of: "'", with: "''") + "'")
    }
}

// MARK: - Catalog backup, export and location

public enum BackupFrequency: String, Codable, CaseIterable, Sendable {
    case never, everyQuit, daily, weekly
    public var title: String { switch self { case .never: return "Never"; case .everyQuit: return "Every time OpenStill quits"; case .daily: return "Once a day, when quitting"; case .weekly: return "Once a week, when quitting" } }
}
public struct BackupSettings: Codable, Equatable {
    public var frequency = BackupFrequency.weekly
    /// How many backups to keep; older ones are deleted.
    public var keep = 5
    public var folder: URL?
    public var last: Date?
    public init() {}
}
public enum CatalogBackup {
    private static func file(_ root: URL) -> URL { root.appendingPathComponent("Backup.json") }
    public static func load(root: URL = EditStorage.root) -> BackupSettings { (try? JSONDecoder().decode(BackupSettings.self, from: Data(contentsOf: file(root)))) ?? BackupSettings() }
    public static func save(_ settings: BackupSettings, root: URL = EditStorage.root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: file(root), options: .atomic)
    }
    public static func defaultFolder(root: URL = EditStorage.root) -> URL { root.appendingPathComponent("Backups", isDirectory: true) }
    public static func isDue(_ settings: BackupSettings, now: Date = Date()) -> Bool {
        guard let last = settings.last else { return settings.frequency != .never }
        switch settings.frequency {
        case .never: return false
        case .everyQuit: return true
        case .daily: return now.timeIntervalSince(last) >= 86_400 - 60
        case .weekly: return now.timeIntervalSince(last) >= 7 * 86_400 - 60
        }
    }
    /// Copies the catalog, the edit records and the settings into a dated folder, then deletes backups beyond `keep`.
    @discardableResult public static func run(store: PhotoRecordStore = EditStorage.records, into folder: URL? = nil, keep: Int = 5, now: Date = Date()) throws -> URL {
        let root = store.root, fm = FileManager.default
        let base = folder ?? defaultFolder(root: root)
        let stamp = DateFormatter(); stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyy-MM-dd HHmmss"
        var target = base.appendingPathComponent("Backup " + stamp.string(from: now), isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: target.path) { target = base.appendingPathComponent("Backup " + stamp.string(from: now) + " \(n)", isDirectory: true); n += 1 }
        let staging = base.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try store.catalog?.backup(to: staging.appendingPathComponent("Catalog.sqlite"))
            for name in ["PhotoRecords", "BatchHistory", "RenameHistory"] {
                let from = root.appendingPathComponent(name)
                if fm.fileExists(atPath: from.path) { try fm.copyItem(at: from, to: staging.appendingPathComponent(name)) }
            }
            for json in ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []) where json.pathExtension == "json" {
                try fm.copyItem(at: json, to: staging.appendingPathComponent(json.lastPathComponent))
            }
            try fm.moveItem(at: staging, to: target)
        } catch { try? fm.removeItem(at: staging); throw error }
        let backups = ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("Backup ") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(max(1, keep)) { try? fm.removeItem(at: old) }
        return target
    }
}
/// Export as Catalog: the selected photos' edits (and optionally their originals) as one folder of portable edit packages.
public enum CatalogExport {
    public static let fileExtension = "openstillcatalog"
    public static func export(_ items: [ShootItem], to destination: URL, includeOriginals: Bool) throws -> (exported: Int, failed: [String]) {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var exported = 0, failed: [String] = []
        for (i, item) in items.enumerated() {
            let name = String(format: "%04d-", i + 1) + item.url.deletingPathExtension().lastPathComponent + ".openstilledits"
            do { try PortableEdits.export(record: item.record, source: item.url, to: destination.appendingPathComponent(name), includeOriginal: includeOriginals); exported += 1 }
            catch { failed.append("\(item.url.lastPathComponent): \(error.localizedDescription)") }
        }
        return (exported, failed)
    }
    /// Imports every package in an exported catalog. Packages without their original are linked to a file with the same name in `relinkFolder`.
    public static func importCatalog(_ folder: URL, relinkFolder: URL? = nil, store: PhotoRecordStore = EditStorage.records) -> (imported: [PhotoRecord], failed: [String]) {
        let packages = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "openstilledits" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var imported: [PhotoRecord] = [], failed: [String] = []
        for package in packages {
            do {
                var relink: URL?
                if let relinkFolder, let inspection = try? PortableEdits.inspect(package), inspection.manifest.original == nil {
                    relink = relinkFolder.appendingPathComponent((inspection.record.sourcePath as NSString).lastPathComponent)
                }
                imported.append(try PortableEdits.importPackage(package, relink: relink, store: store))
            } catch { failed.append("\(package.lastPathComponent): \(error.localizedDescription)") }
        }
        return (imported, failed)
    }
}
/// Which catalog folder the app uses. A change takes effect the next time OpenStill opens.
public enum CatalogLocation {
    public static let defaultsKey = "OpenStillCatalogRoot"
    public static var chosen: URL? { UserDefaults.standard.string(forKey: defaultsKey).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } }
    public static func choose(_ folder: URL?) { UserDefaults.standard.set(folder?.path, forKey: defaultsKey) }
}

// MARK: - Book

public enum BookTemplate: String, Codable, CaseIterable, Sendable {
    case single, fullBleed, twoUp, fourUp
    public var title: String { switch self { case .single: return "One photo"; case .fullBleed: return "Full bleed"; case .twoUp: return "Two photos"; case .fourUp: return "Four photos" } }
    public var slots: Int { switch self { case .single, .fullBleed: return 1; case .twoUp: return 2; case .fourUp: return 4 } }
}
public struct BookPage: Codable, Equatable {
    public var template: BookTemplate
    public var photos: [UUID?]
    public var caption = ""
    public init(template: BookTemplate, photos: [UUID?] = []) {
        self.template = template; self.photos = Array((photos + Array(repeating: nil, count: template.slots)).prefix(template.slots))
    }
}
public struct BookDocument: Codable, Equatable {
    public var title = "Untitled Book"
    public var paper = PaperSize(name: "Square 8 × 8 in", width: 576, height: 576)
    public var margin = 36.0
    public var gap = 12.0
    public var pages: [BookPage] = []
    public init() {}
    public static let papers: [PaperSize] = [PaperSize(name: "Square 8 × 8 in", width: 576, height: 576), PaperSize(name: "Landscape 10 × 8 in", width: 720, height: 576), .letter, .a4]
}
public enum BookEngine {
    /// Where the photos go on a page, in PDF points (origin bottom left). Captions take a strip at the bottom.
    public static func cells(_ template: BookTemplate, document: BookDocument, caption: Bool) -> [CGRect] {
        let page = CGRect(x: 0, y: 0, width: document.paper.width, height: document.paper.height)
        if template == .fullBleed { return [page] }
        var area = page.insetBy(dx: document.margin, dy: document.margin)
        if caption { area.origin.y += 28; area.size.height -= 28 }
        let g = document.gap
        switch template {
        case .single, .fullBleed: return [area]
        case .twoUp:
            let landscape = area.width >= area.height
            if landscape { let w = (area.width - g) / 2; return [CGRect(x: area.minX, y: area.minY, width: w, height: area.height), CGRect(x: area.minX + w + g, y: area.minY, width: w, height: area.height)] }
            let h = (area.height - g) / 2; return [CGRect(x: area.minX, y: area.minY + h + g, width: area.width, height: h), CGRect(x: area.minX, y: area.minY, width: area.width, height: h)]
        case .fourUp:
            let w = (area.width - g) / 2, h = (area.height - g) / 2
            return [CGRect(x: area.minX, y: area.minY + h + g, width: w, height: h), CGRect(x: area.minX + w + g, y: area.minY + h + g, width: w, height: h),
                    CGRect(x: area.minX, y: area.minY, width: w, height: h), CGRect(x: area.minX + w + g, y: area.minY, width: w, height: h)]
        }
    }
    /// Auto Layout: the photos in order, filling pages of this template.
    public static func autoLayout(_ photos: [UUID], template: BookTemplate) -> [BookPage] {
        stride(from: 0, to: photos.count, by: template.slots).map { BookPage(template: template, photos: Array(photos[$0..<min(photos.count, $0 + template.slots)])) }
    }
    /// A photo filling its cell (cropped to fit, like Lightroom's zoom-to-fill).
    public static func fill(_ size: CGSize, in cell: CGRect) -> CGRect {
        let scale = max(cell.width / max(1, size.width), cell.height / max(1, size.height))
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h)
    }
    /// Writes the book as a PDF. `images` gives each photo, rendered at print size.
    public static func pdf(_ document: BookDocument, images: [UUID: CGImage], to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: document.paper.width, height: document.paper.height)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: document.title] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
        for page in document.pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
            let cells = self.cells(page.template, document: document, caption: !page.caption.isEmpty)
            for (cell, id) in zip(cells, page.photos) {
                guard let id, let image = images[id] else { continue }
                context.saveGState(); context.clip(to: cell)
                context.interpolationQuality = .high
                context.draw(image, in: fill(CGSize(width: image.width, height: image.height), in: cell))
                context.restoreGState()
            }
            if !page.caption.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 11, nil),
                                  NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.2, alpha: 1)]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: page.caption, attributes: attributes))
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                context.textPosition = CGPoint(x: (box.width - width) / 2, y: document.margin)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
    private static func file(_ root: URL) -> URL { root.appendingPathComponent("Book.json") }
    public static func load(root: URL = EditStorage.root) -> BookDocument { (try? JSONDecoder().decode(BookDocument.self, from: Data(contentsOf: file(root)))) ?? BookDocument() }
    public static func save(_ document: BookDocument, root: URL = EditStorage.root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: file(root), options: .atomic)
    }
}

// MARK: - Auto Sync

/// Auto Sync: a change on the active photo also goes to the other selected photos, one setting group at a time.
public enum AutoSync {
    /// Per-photo work (crop, retouching, lens, Transform) is never synced automatically.
    public static let groups = AdjustmentGroup.defaults
    private static func only(_ group: AdjustmentGroup) -> BatchOptions { var o = BatchOptions(); o.groups = [group]; return o }
    /// The groups whose settings differ between two versions of one photo's edits.
    public static func changedGroups(from before: PhotoEdits, to after: PhotoEdits) -> Set<AdjustmentGroup> {
        Set(groups.filter { g in
            let a = (try? BatchEdits.merging(after, into: before, options: only(g), geometryCompatible: true)) ?? before
            let b = (try? BatchEdits.merging(before, into: before, options: only(g), geometryCompatible: true)) ?? before
            return a != b
        })
    }
    /// Simple sliders are synced one by one, so changing Exposure doesn't also copy Contrast.
    static let sliders: [WritableKeyPath<PhotoEdits, Double>] = [\.exposure, \.contrast, \.highlights, \.shadows, \.whites, \.blacks, \.temperature, \.tint,
        \.saturation, \.vibrance, \.clarity, \.texture, \.dehaze, \.structure, \.sharpness, \.denoise, \.vignette]
    /// Another photo's edits with just what changed copied from `after`.
    public static func apply(from before: PhotoEdits, to after: PhotoEdits, onto target: PhotoEdits) -> PhotoEdits {
        var result = target, settled = before
        for path in sliders where before[keyPath: path] != after[keyPath: path] { result[keyPath: path] = after[keyPath: path] }
        for path in sliders { settled[keyPath: path] = after[keyPath: path] }
        // Everything else (curves, color mixer, grading, grain…) goes by group.
        let changed = changedGroups(from: settled, to: after)
        guard !changed.isEmpty else { return result.sanitized }
        var o = BatchOptions(); o.groups = changed
        var merged = (try? BatchEdits.merging(after, into: result, options: o, geometryCompatible: true)) ?? result
        // A group copy brings its sliders too; keep the target's own values for the ones that didn't change.
        for path in sliders where before[keyPath: path] == after[keyPath: path] { merged[keyPath: path] = target[keyPath: path] }
        return merged.sanitized
    }
}

// MARK: - Adaptive presets

public enum AdaptiveTarget: String, Codable, Sendable { case subject, background, sky }
/// A look that applies only to the subject, the background or the sky, masked for each photo when it's applied.
public struct AdaptivePreset: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let target: AdaptiveTarget
    /// Tool (mask key) → value.
    public let values: [String: Double]
    public var needsSkyModel: Bool { target == .sky }
}
public enum AdaptivePresets {
    public static let all: [AdaptivePreset] = [
        AdaptivePreset(name: "Subject: Pop", target: .subject, values: ["Clarity": 0.25, "Texture": 0.2]),
        AdaptivePreset(name: "Subject: Soften", target: .subject, values: ["Texture": -0.35, "Clarity": -0.1]),
        AdaptivePreset(name: "Background: Soften", target: .background, values: ["Texture": -0.4, "Clarity": -0.3]),
        AdaptivePreset(name: "Background: Clear haze", target: .background, values: ["Dehaze": 0.3]),
        AdaptivePreset(name: "Sky: Deepen", target: .sky, values: ["Dehaze": 0.35, "Clarity": 0.15]),
        AdaptivePreset(name: "Sky: Soft", target: .sky, values: ["Dehaze": -0.2, "Texture": -0.3]),
    ]
    /// Sets the preset's tools and limits each one to the mask. `maskAsset` is the subject or sky mask saved for this photo.
    public static func apply(_ preset: AdaptivePreset, to edits: PhotoEdits, maskAsset: String) -> PhotoEdits {
        var e = edits
        for (key, value) in preset.values {
            switch key {
            case "Clarity": e.clarity = value
            case "Texture": e.texture = value
            case "Dehaze": e.dehaze = value
            default: continue
            }
            var selection = AdjustmentMask(kind: "object"); selection.asset = maskAsset; selection.feather = 0.05
            selection.inverted = preset.target == .background
            var root = AdjustmentMask(kind: "stack"); root.components = []
            root.updateComponent(MaskComponent(name: preset.target == .sky ? "Sky" : preset.target == .background ? "Background" : "Subject", selection: selection))
            e.setMask(root, for: key)
        }
        return e.sanitized
    }
}
