import Foundation

/// A tethered shooting session: shots from the camera land in one folder, are named in sequence and get a preset and metadata.
/// The camera connection itself (ImageCaptureCore) lives in the app; this is the part that doesn't need a camera.
public struct TetherSession: Codable, Equatable {
    public var name: String
    /// The parent folder; the session gets its own folder inside it.
    public var parent: URL
    public var developPreset: PhotoEdits?
    public var developPresetName: String?
    public var metadata: IPTCMetadata?
    public var started: Date
    public init(name: String, parent: URL, started: Date = Date()) {
        self.name = name; self.parent = parent; self.started = started
    }

    /// Safe for a file or folder name: no slashes, colons or control characters, not starting with a dot.
    public static func clean(_ text: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let s = String(String.UnicodeScalarView(text.unicodeScalars.map { bad.contains($0) ? "-" : $0 })).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(s.drop { $0 == "." }.prefix(80))
        return trimmed.isEmpty ? "Session" : trimmed
    }
    /// "2026-09-27 Studio portraits", inside the parent folder.
    public var folder: URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return parent.appendingPathComponent(f.string(from: started) + " " + Self.clean(name), isDirectory: true)
    }
    /// The next free name for a shot, e.g. "Studio portraits-0007.CR3", keeping the camera's extension.
    public func destination(for cameraName: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = (cameraName as NSString).pathExtension
        let stem = Self.clean(name)
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var used = 0
        for file in existing {
            let base = (file as NSString).deletingPathExtension
            if base.hasPrefix(stem + "-"), let n = Int(base.dropFirst(stem.count + 1)) { used = max(used, n) }
        }
        var n = used + 1
        while true {
            let candidate = stem + "-" + String(format: "%04d", n) + (ext.isEmpty ? "" : "." + ext)
            if !existing.contains(candidate) { return folder.appendingPathComponent(candidate) }
            n += 1
        }
    }
    /// Adds a downloaded shot to the library with the session's preset and metadata. Returns its record.
    @discardableResult public func ingest(_ url: URL, store: PhotoRecordStore = EditStorage.records) throws -> PhotoRecord {
        let record = try store.record(for: url)
        guard developPreset != nil || metadata != nil else { return record }
        return try store.update(record.id) { record in
            if let metadata { record.iptc = record.iptc.applying(metadata) }
            if let preset = developPreset {
                var document = record.active.document
                document.commit(PhotoImport.applying(preset, to: document.current), title: developPresetName ?? "Tether preset")
                record.updateDocument(document)
            }
        }
    }
}
