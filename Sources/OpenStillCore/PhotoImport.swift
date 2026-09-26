import Foundation
import CryptoKit
import ImageIO

/// One photo found on a card or in a folder, before it is imported.
public struct ImportCandidate: Identifiable, Equatable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let captured: Date
    /// XMP sidecar next to the photo on the card, copied along with it.
    public let sidecar: URL?
    /// The same contents are already in the library (same size and SHA-256).
    public var alreadyImported = false
    public var include = true
    public init(url: URL, size: Int64, captured: Date, sidecar: URL?) { self.url = url; self.size = size; self.captured = captured; self.sidecar = sidecar }
}

/// Destination folders, file names, a second copy and what to apply to imported photos.
public struct ImportSettings: Codable, Equatable {
    public var destination: URL
    /// Folders inside the destination, e.g. "{yyyy}/{yyyy}-{MM}-{dd}". Empty puts files directly in the destination.
    public var folderTemplate = "{yyyy}/{yyyy}-{MM}-{dd}"
    /// File name without extension. Tokens: {name} {yyyy} {MM} {dd} {date} {time} {index} {camera}.
    public var nameTemplate = "{name}"
    /// A verified second copy with the same folders and names, e.g. on another drive.
    public var backup: URL?
    public var skipAlreadyImported = true
    public var metadata: IPTCMetadata?
    /// Develop settings from a saved preset, applied to the imported photos' first version.
    public var developPreset: PhotoEdits?
    public var developPresetName: String?
    public init(destination: URL) { self.destination = destination }
    public static let folderTemplates = ["{yyyy}/{yyyy}-{MM}-{dd}", "{yyyy}/{MM}", "{yyyy}-{MM}-{dd}", "{camera}/{yyyy}-{MM}-{dd}", ""]
    public static let nameTemplates = ["{name}", "{date}_{name}", "{date}_{time}_{index}", "{yyyy}{MM}{dd}-{index}", "{camera}_{index}"]
}

public struct ImportReport: Equatable {
    public var imported: [URL] = []
    public var skipped = 0
    public var failed: [String] = []
    public var backupFailed: [String] = []
    public var cancelled = false
    public var summary: String {
        var lines = ["\(imported.count) photo\(imported.count == 1 ? "" : "s") imported and verified."]
        if skipped > 0 { lines.append("\(skipped) already in your library, skipped.") }
        if !failed.isEmpty { lines.append("\(failed.count) couldn’t be imported:\n" + failed.prefix(20).map { "• " + $0 }.joined(separator: "\n")) }
        if !backupFailed.isEmpty { lines.append("The backup copy failed for \(backupFailed.count):\n" + backupFailed.prefix(20).map { "• " + $0 }.joined(separator: "\n")) }
        if cancelled { lines.append("Stopped before the end. Photos already copied are kept.") }
        lines.append("Nothing was deleted from the source.")
        return lines.joined(separator: "\n\n")
    }
}

public enum ImportError: LocalizedError {
    case verification(String), template
    public var errorDescription: String? {
        switch self {
        case .verification(let name): return "\(name): the copy didn’t match the original, so it was removed."
        case .template: return "The folder or name template makes an invalid file name."
        }
    }
}

public enum PhotoImport {
    /// Every supported photo on the source (subfolders included, hidden files skipped), with already-imported ones marked.
    public static func scan(_ source: URL, catalog: LibraryCatalog? = EditStorage.records.catalog, cancelled: () -> Bool = { false }) -> [ImportCandidate] {
        let files = (try? PhotoCatalog.open([source], includeSubfolders: true).urls) ?? []
        var hashCache: [Int64: Set<String>] = [:]
        var out: [ImportCandidate] = []
        for url in files {
            if cancelled() { break }
            let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let sidecar = XMPSidecar.url(for: url)
            var candidate = ImportCandidate(url: url, size: size, captured: captureDate(url) ?? values?.creationDate ?? values?.contentModificationDate ?? Date(),
                                            sidecar: FileManager.default.fileExists(atPath: sidecar.path) ? sidecar : nil)
            // Hashing is only needed when the library holds a photo of exactly this size.
            if let catalog {
                let known = hashCache[size] ?? catalog.fingerprints(size: size); hashCache[size] = known
                if !known.isEmpty, let hash = try? PhotoRecordStore.contentHash(url), known.contains(hash) { candidate.alreadyImported = true; candidate.include = false }
            }
            out.append(candidate)
        }
        return out.sorted { $0.captured == $1.captured ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.captured < $1.captured }
    }
    /// EXIF DateTimeOriginal (camera local time), read without decoding the image.
    public static func captureDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let stamp = (exif[kCGImagePropertyExifDateTimeOriginal as String] ?? exif[kCGImagePropertyExifDateTimeDigitized as String]) as? String else { return nil }
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone.current; parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return parser.date(from: stamp)
    }
    static func camera(_ url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any], let model = tiff[kCGImagePropertyTIFFModel as String] as? String else { return "Camera" }
        return model.trimmingCharacters(in: .whitespaces)
    }

    /// Fills a template's tokens. Slashes are kept only when `folders` is true.
    public static func expand(_ template: String, candidate: ImportCandidate, index: Int, camera: String, folders: Bool) throws -> String {
        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: candidate.captured)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        func safe(_ s: String) -> String {
            String(s.unicodeScalars.map { ":/\\".unicodeScalars.contains($0) || $0.value < 32 ? "-" : Character($0) })
        }
        let values: [String: String] = [
            "name": candidate.url.deletingPathExtension().lastPathComponent, "yyyy": String(format: "%04d", c.year ?? 0), "MM": two(c.month), "dd": two(c.day),
            "date": String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0), "time": two(c.hour) + two(c.minute) + two(c.second),
            "index": String(format: "%04d", index + 1), "camera": camera
        ]
        var out = template
        for (key, value) in values { out = out.replacingOccurrences(of: "{\(key)}", with: safe(value)) }
        let parts = folders ? out.split(separator: "/", omittingEmptySubsequences: true).map(String.init) : [out]
        guard !out.contains("{"), !out.contains("}"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") && $0.utf8.count < 200 && (folders || !$0.contains("/")) }),
              folders || !out.isEmpty else { throw ImportError.template }
        return parts.joined(separator: "/")
    }

    /// Copies `source` to `destination` while hashing, then reads the copy back and compares. Returns the SHA-256.
    /// A copy that doesn't match is deleted. The source is only read.
    @discardableResult static func verifiedCopy(_ source: URL, to destination: URL) throws -> String {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent().appendingPathComponent("." + destination.lastPathComponent + ".importing")
        try? manager.removeItem(at: partial)
        guard manager.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
        var hash = SHA256()
        do {
            let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: partial)
            defer { try? input.close(); try? output.close() }
            while let block = try input.read(upToCount: 4 * 1024 * 1024), !block.isEmpty { hash.update(data: block); try output.write(contentsOf: block) }
            try output.synchronize()
        } catch { try? manager.removeItem(at: partial); throw error }
        let expected = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard (try? PhotoRecordStore.contentHash(partial)) == expected else { try? manager.removeItem(at: partial); throw ImportError.verification(source.lastPathComponent) }
        // Keep the original dates so the library sorts by them.
        if let attributes = try? manager.attributesOfItem(atPath: source.path) {
            try? manager.setAttributes([.modificationDate: attributes[.modificationDate] as Any, .creationDate: attributes[.creationDate] as Any].compactMapValues { $0 is Date ? $0 : nil }, ofItemAtPath: partial.path)
        }
        // link() fails instead of overwriting, so an existing file is never replaced.
        guard link(partial.path, destination.path) == 0 else { let code = errno; try? manager.removeItem(at: partial); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EEXIST) }
        try? manager.removeItem(at: partial)
        return expected
    }
    /// The first free name: IMG_0001.CR2, IMG_0001-1.CR2, …
    static func freeURL(_ folder: URL, stem: String, ext: String, taken: Set<String>) -> URL {
        for n in 0..<100_000 {
            let name = stem + (n == 0 ? "" : "-\(n)") + (ext.isEmpty ? "" : "." + ext)
            let url = folder.appendingPathComponent(name)
            if !taken.contains(url.path.lowercased()) && !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return folder.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    /// Copies the included candidates into the destination (and backup), verifying every copy, then adds them to the library.
    public static func run(_ candidates: [ImportCandidate], settings: ImportSettings, store: PhotoRecordStore = EditStorage.records,
                           progress: (Int, Int) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) -> ImportReport {
        var report = ImportReport()
        let chosen = candidates.filter { $0.include && !(settings.skipAlreadyImported && $0.alreadyImported) }
        report.skipped = candidates.filter { $0.alreadyImported && (settings.skipAlreadyImported || !$0.include) }.count
        let destination = settings.destination.standardizedFileURL
        var taken = Set<String>()
        for (index, candidate) in chosen.enumerated() {
            if cancelled() { report.cancelled = true; break }
            progress(index, chosen.count)
            do {
                let camera = settings.folderTemplate.contains("{camera}") || settings.nameTemplate.contains("{camera}") ? Self.camera(candidate.url) : "Camera"
                let folder = try expand(settings.folderTemplate, candidate: candidate, index: index, camera: camera, folders: true)
                let stem = try expand(settings.nameTemplate, candidate: candidate, index: index, camera: camera, folders: false)
                let ext = candidate.url.pathExtension
                let target = freeURL(folder.isEmpty ? destination : destination.appendingPathComponent(folder, isDirectory: true), stem: stem, ext: ext, taken: taken)
                taken.insert(target.path.lowercased())
                try verifiedCopy(candidate.url, to: target)
                if let sidecar = candidate.sidecar { try? verifiedCopy(sidecar, to: XMPSidecar.url(for: target)) }
                if let backup = settings.backup {
                    let relative = String(target.path.dropFirst(destination.path.count + 1))
                    let copy = backup.standardizedFileURL.appendingPathComponent(relative)
                    do {
                        try verifiedCopy(candidate.url, to: copy)
                        if let sidecar = candidate.sidecar { try? verifiedCopy(sidecar, to: XMPSidecar.url(for: copy)) }
                    } catch { report.backupFailed.append("\(candidate.url.lastPathComponent): \(error.localizedDescription)") }
                }
                // Add to the library, with metadata and a develop preset when asked.
                let record = try store.record(for: target)
                if settings.metadata != nil || settings.developPreset != nil {
                    try store.update(record.id) { record in
                        if let metadata = settings.metadata { record.iptc = record.iptc.applying(metadata) }
                        if let preset = settings.developPreset {
                            var document = record.active.document
                            document.commit(applying(preset, to: document.current), title: settings.developPresetName ?? "Import preset")
                            record.updateDocument(document)
                        }
                    }
                }
                report.imported.append(target)
            } catch { report.failed.append("\(candidate.url.lastPathComponent): \(error.localizedDescription)") }
        }
        progress(chosen.count, chosen.count)
        return report
    }
    /// A preset's look on top of a photo's own geometry, lens corrections and masks (as Load preset does).
    public static func applying(_ preset: PhotoEdits, to current: PhotoEdits) -> PhotoEdits {
        var e = preset.sanitized
        e.baseAsset = current.baseAsset; e.overlayAsset = current.overlayAsset; e.crop = current.crop; e.rotation = current.rotation; e.flip = current.flip
        e.ensureAdvanced(); e.straighten = current.straighten
        e.advanced!.masks = current.advanced?.masks ?? [:]; e.advanced!.transform = current.advanced?.transform
        e.advanced!.lens = current.advanced?.lens ?? e.advanced!.lens
        e.advanced!.aiBackgroundAsset = nil; e.advanced!.aiFeatureKey = nil; e.advanced!.lutAsset = nil; e.advanced!.lutName = nil; e.advanced!.lutID = nil
        return e
    }

    /// Mounted volumes that look like camera cards or other removable media, with a DCIM folder first.
    public static func removableVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return v?.volumeIsRemovable == true || v?.volumeIsEjectable == true || FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path)
        }.sorted { a, _ in FileManager.default.fileExists(atPath: a.appendingPathComponent("DCIM").path) }
    }
}
