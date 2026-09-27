import Foundation
import CoreGraphics
import ImageIO
import Vision
import SQLite3

/// A face found in a photo, before it is stored.
public struct DetectedFace: Equatable, Sendable {
    /// Normalized to the upright photo, origin at the top left.
    public var rect: CGRect
    /// A unit-length appearance vector for grouping similar faces.
    public var print: [Float]
    public init(rect: CGRect, print: [Float]) { self.rect = rect; self.print = print }
}

/// A face stored in the catalog.
public struct Face: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var photoID: UUID
    /// Normalized to the upright photo, origin at the top left.
    public var rect: CGRect
    public var print: [Float]
    /// The person it was named as, if any.
    public var personID: UUID?
    /// An unnamed group of similar faces, recomputed after each scan.
    public var cluster: Int?
}

public struct Person: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var faceCount = 0, photoCount = 0
}

/// Finds faces with Vision and describes each with an image feature print of the face crop. Runs on this Mac only.
public enum FaceDetector {
    /// Faces smaller than this share of the photo's short side are skipped: too small to recognize.
    public static let minimumSize: CGFloat = 0.04

    public static func detect(_ url: URL, maxPixelSize: Int = 1600) -> [DetectedFace] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary) else { return [] }
        return detect(image)
    }
    public static func detect(_ image: CGImage) -> [DetectedFace] {
        let request = VNDetectFaceRectanglesRequest()
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return [] }
        let width = CGFloat(image.width), height = CGFloat(image.height), short = min(width, height)
        var out: [DetectedFace] = []
        for observation in request.results ?? [] {
            // Vision's boxes are normalized with the origin at the bottom left.
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            guard min(rect.width * width, rect.height * height) >= short * minimumSize else { continue }
            guard let crop = crop(image, around: rect), let print = featurePrint(crop) else { continue }
            out.append(DetectedFace(rect: rect, print: print))
        }
        return out.sorted { $0.rect.minX < $1.rect.minX }
    }
    /// A square crop around the face with some margin, for a steadier description.
    static func crop(_ image: CGImage, around rect: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let side = max(rect.width * w, rect.height * h) * 1.4
        let center = CGPoint(x: rect.midX * w, y: rect.midY * h)
        let box = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side).intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard box.width >= 8, box.height >= 8 else { return nil }
        return image.cropping(to: box)
    }
    static func featurePrint(_ image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return nil }
        guard let observation = request.results?.first else { return nil }
        return FaceClustering.normalized(vector(observation))
    }
    static func vector(_ observation: VNFeaturePrintObservation) -> [Float] {
        let data = observation.data, count = observation.elementCount
        switch observation.elementType {
        case .float: return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        case .double: return data.withUnsafeBytes { $0.bindMemory(to: Double.self).prefix(count).map { Float($0) } }
        default: return []
        }
    }
}

/// Grouping of face descriptions. Vectors are unit length, so distances run from 0 (identical) to 2.
public enum FaceClustering {
    /// Default distance under which two faces are treated as the same person. Lower is stricter.
    public static let defaultThreshold: Float = 0.6

    public static func normalized(_ v: [Float]) -> [Float] {
        let length = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard length > 0, length.isFinite else { return v }
        return v.map { $0 / length }
    }
    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum: Float = 0
        for i in a.indices { let d = a[i] - b[i]; sum += d * d }
        return sqrt(sum)
    }
    /// The normalized mean of several descriptions.
    public static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count { for i in v.indices { sum[i] += v[i] } }
        return normalized(sum)
    }
    /// Groups vectors: each joins the nearest group whose centre is within `threshold`, else starts a new one; then every vector is
    /// reassigned once to its nearest centre. Returns a group number per vector; groups are numbered by size, largest first.
    public static func cluster(_ vectors: [[Float]], threshold: Float = defaultThreshold) -> [Int] {
        guard !vectors.isEmpty else { return [] }
        var centres: [[Float]] = [], members: [[Int]] = []
        var sums: [[Float]] = []
        for (i, v) in vectors.enumerated() {
            var best = -1, bestDistance = Float.infinity
            for (c, centre) in centres.enumerated() { let d = distance(v, centre); if d < bestDistance { bestDistance = d; best = c } }
            if best >= 0, bestDistance <= threshold {
                members[best].append(i); for k in v.indices where k < sums[best].count { sums[best][k] += v[k] }
                centres[best] = normalized(sums[best])
            } else { centres.append(v); sums.append(v); members.append([i]) }
        }
        // One refinement pass against the final centres keeps early faces from sticking to a group that drifted away.
        var labels = [Int](repeating: 0, count: vectors.count)
        for (i, v) in vectors.enumerated() {
            var best = 0, bestDistance = Float.infinity
            for (c, centre) in centres.enumerated() { let d = distance(v, centre); if d < bestDistance { bestDistance = d; best = c } }
            labels[i] = bestDistance <= threshold ? best : members.firstIndex { $0.contains(i) } ?? best
        }
        var sizes: [Int: Int] = [:]
        for l in labels { sizes[l, default: 0] += 1 }
        let order = sizes.keys.sorted { sizes[$0]! == sizes[$1]! ? $0 < $1 : sizes[$0]! > sizes[$1]! }
        var renumber: [Int: Int] = [:]
        for (n, l) in order.enumerated() { renumber[l] = n }
        return labels.map { renumber[$0]! }
    }
}

// MARK: - Catalog storage

extension LibraryCatalog {
    func prepareFaces() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS people (id TEXT PRIMARY KEY, name TEXT NOT NULL, created REAL);
        CREATE TABLE IF NOT EXISTS faces (id TEXT PRIMARY KEY, photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
            x REAL, y REAL, w REAL, h REAL, print BLOB, person_id TEXT REFERENCES people(id) ON DELETE SET NULL, cluster INTEGER);
        CREATE INDEX IF NOT EXISTS faces_photo ON faces(photo_id);
        CREATE INDEX IF NOT EXISTS faces_person ON faces(person_id);
        CREATE TABLE IF NOT EXISTS face_rejections (face_id TEXT NOT NULL REFERENCES faces(id) ON DELETE CASCADE, person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
            PRIMARY KEY(face_id, person_id));
        CREATE TABLE IF NOT EXISTS face_scans (photo_id TEXT PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE, fingerprint TEXT, scanned REAL);
        """)
    }
    static func blob(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func floats(_ s: OpaquePointer, _ i: Int32) -> [Float] {
        let count = Int(sqlite3_column_bytes(s, i)) / MemoryLayout<Float>.size
        guard count > 0, let bytes = sqlite3_column_blob(s, i) else { return [] }
        return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: Float.self), count: count))
    }

    /// Whether the photo still needs a face scan: never scanned, or its contents changed since.
    public func needsFaceScan(_ photo: UUID, fingerprint: String) -> Bool {
        var scanned: String?
        _ = try? run("SELECT fingerprint FROM face_scans WHERE photo_id = ?", [.text(photo.uuidString)]) { scanned = Self.text($0, 0) }
        return scanned != fingerprint
    }
    /// Stores a photo's faces. Faces already named keep their person when a new face overlaps them.
    public func replaceFaces(for photo: UUID, fingerprint: String, _ detected: [DetectedFace]) throws {
        let previous = faces(photo: photo)
        try transaction {
            try run("DELETE FROM faces WHERE photo_id = ?", [.text(photo.uuidString)])
            for face in detected {
                let person = previous.filter { $0.personID != nil }.max { overlap($0.rect, face.rect) < overlap($1.rect, face.rect) }
                let keep = person.flatMap { overlap($0.rect, face.rect) > 0.5 ? $0.personID : nil }
                try run("INSERT INTO faces(id, photo_id, x, y, w, h, print, person_id) VALUES(?,?,?,?,?,?,?,?)",
                        [.text(UUID().uuidString), .text(photo.uuidString), .real(face.rect.minX), .real(face.rect.minY), .real(face.rect.width), .real(face.rect.height),
                         .blob(Self.blob(face.print)), keep.map { Value.text($0.uuidString) } ?? Value.null])
            }
            try run("INSERT OR REPLACE INTO face_scans(photo_id, fingerprint, scanned) VALUES(?,?,?)", [.text(photo.uuidString), .text(fingerprint), .real(Date().timeIntervalSince1970)])
        }
    }
    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b); guard !i.isNull else { return 0 }
        let union = a.width * a.height + b.width * b.height - i.width * i.height
        return union > 0 ? i.width * i.height / union : 0
    }

    public func faces(photo: UUID? = nil, person: UUID? = nil, unnamed: Bool = false) -> [Face] {
        var clauses: [String] = [], values: [Value] = []
        if let photo { clauses.append("photo_id = ?"); values.append(.text(photo.uuidString)) }
        if let person { clauses.append("person_id = ?"); values.append(.text(person.uuidString)) }
        if unnamed { clauses.append("person_id IS NULL") }
        var out: [Face] = []
        let sql = "SELECT id, photo_id, x, y, w, h, print, person_id, cluster FROM faces" + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")) + " ORDER BY photo_id, x"
        _ = try? run(sql, values) { s in
            guard let id = UUID(uuidString: Self.text(s, 0)), let photo = UUID(uuidString: Self.text(s, 1)) else { return }
            out.append(Face(id: id, photoID: photo, rect: CGRect(x: sqlite3_column_double(s, 2), y: sqlite3_column_double(s, 3), width: sqlite3_column_double(s, 4), height: sqlite3_column_double(s, 5)),
                            print: Self.floats(s, 6), personID: UUID(uuidString: Self.text(s, 7)), cluster: Self.real(s, 8).map { Int($0) }))
        }
        return out
    }
    public var faceCount: Int { var n = 0; _ = try? run("SELECT count(*) FROM faces") { n = Int(sqlite3_column_int64($0, 0)) }; return n }

    public func people() -> [Person] {
        var out: [Person] = []
        _ = try? run("""
        SELECT people.id, people.name, count(faces.id), count(DISTINCT faces.photo_id) FROM people LEFT JOIN faces ON faces.person_id = people.id
        GROUP BY people.id ORDER BY people.name COLLATE NOCASE
        """) { s in
            if let id = UUID(uuidString: Self.text(s, 0)) { out.append(Person(id: id, name: Self.text(s, 1), faceCount: Int(sqlite3_column_int64(s, 2)), photoCount: Int(sqlite3_column_int64(s, 3)))) }
        }
        return out
    }
    /// The person with this name (ignoring case), created if needed.
    @discardableResult public func person(named name: String) throws -> Person {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = people().first(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) { return existing }
        let p = Person(id: UUID(), name: String(clean.prefix(120)))
        try run("INSERT INTO people(id, name, created) VALUES(?,?,?)", [.text(p.id.uuidString), .text(p.name), .real(Date().timeIntervalSince1970)])
        return p
    }
    public func renamePerson(_ id: UUID, to name: String) throws {
        try run("UPDATE people SET name = ? WHERE id = ?", [.text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))), .text(id.uuidString)])
    }
    /// Removes the name; its faces become unnamed again.
    public func deletePerson(_ id: UUID) throws { try run("DELETE FROM people WHERE id = ?", [.text(id.uuidString)]) }

    /// Names faces as a person (nil clears the name). Naming a face also forgets an earlier "not this person".
    public func assign(_ faces: [UUID], to person: UUID?) throws {
        try transaction {
            for face in faces {
                try run("UPDATE faces SET person_id = ? WHERE id = ?", [person.map { Value.text($0.uuidString) } ?? Value.null, .text(face.uuidString)])
                if let person { try run("DELETE FROM face_rejections WHERE face_id = ? AND person_id = ?", [.text(face.uuidString), .text(person.uuidString)]) }
            }
        }
    }
    /// "Not this person": the faces are unnamed if they had this name and won't be suggested for it again.
    public func reject(_ faces: [UUID], from person: UUID) throws {
        try transaction {
            for face in faces {
                try run("UPDATE faces SET person_id = NULL WHERE id = ? AND person_id = ?", [.text(face.uuidString), .text(person.uuidString)])
                try run("INSERT OR IGNORE INTO face_rejections(face_id, person_id) VALUES(?,?)", [.text(face.uuidString), .text(person.uuidString)])
            }
        }
    }
    /// Regroups the unnamed faces and stores the group numbers.
    public func updateFaceClusters(threshold: Float = FaceClustering.defaultThreshold) throws {
        let unnamed = faces(unnamed: true)
        let labels = FaceClustering.cluster(unnamed.map(\.print), threshold: threshold)
        try transaction {
            try run("UPDATE faces SET cluster = NULL")
            for (face, label) in zip(unnamed, labels) { try run("UPDATE faces SET cluster = ? WHERE id = ?", [.int(Int64(label)), .text(face.id.uuidString)]) }
        }
    }
    /// Groups of similar unnamed faces with at least `minimum` faces, largest first.
    public func unnamedGroups(minimum: Int = 2) -> [[Face]] {
        Dictionary(grouping: faces(unnamed: true).filter { $0.cluster != nil }, by: { $0.cluster! })
            .values.filter { $0.count >= minimum }.sorted { $0.count == $1.count ? $0[0].cluster! < $1[0].cluster! : $0.count > $1.count }
    }
    /// Unnamed faces that look like this person, closest first, skipping faces rejected for them.
    public func suggestions(for person: UUID, threshold: Float = FaceClustering.defaultThreshold, limit: Int = 200) -> [(face: Face, distance: Float)] {
        guard let centre = FaceClustering.centroid(faces(person: person).map(\.print)) else { return [] }
        var rejected = Set<UUID>()
        _ = try? run("SELECT face_id FROM face_rejections WHERE person_id = ?", [.text(person.uuidString)]) { if let id = UUID(uuidString: Self.text($0, 0)) { rejected.insert(id) } }
        return faces(unnamed: true).filter { !rejected.contains($0.id) }
            .map { ($0, FaceClustering.distance($0.print, centre)) }.filter { $0.1 <= threshold }
            .sorted { $0.1 < $1.1 }.prefix(limit).map { (face: $0.0, distance: $0.1) }
    }
    /// Photos with a face named as this person.
    public func photos(with person: UUID) -> [UUID] {
        var out: [UUID] = []
        _ = try? run("SELECT DISTINCT photo_id FROM faces WHERE person_id = ?", [.text(person.uuidString)]) { if let id = UUID(uuidString: Self.text($0, 0)) { out.append(id) } }
        return out
    }
    /// Names of the people in a photo.
    public func peopleNames(in photo: UUID) -> [String] {
        var out: [String] = []
        _ = try? run("SELECT DISTINCT people.name FROM faces JOIN people ON people.id = faces.person_id WHERE faces.photo_id = ? ORDER BY people.name COLLATE NOCASE",
                     [.text(photo.uuidString)]) { out.append(Self.text($0, 0)) }
        return out
    }
}

/// Keeps "People > Name" keywords in step with named faces, as Lightroom does, so names are searchable and exported.
public enum PeopleKeywords {
    public static let parent = "People"
    /// Replaces the photo's People keywords with the names of the people in it. Returns the updated record, or nil if nothing changed.
    @discardableResult public static func sync(_ photo: UUID, catalog: LibraryCatalog, store: PhotoRecordStore) throws -> PhotoRecord? {
        let names = catalog.peopleNames(in: photo)
        let record = try store.read(photo)
        let updated = apply(names, to: record.iptc)
        guard updated != record.iptc else { return nil }
        return try store.update(photo) { $0.iptc = updated }
    }
    static func apply(_ names: [String], to metadata: IPTCMetadata) -> IPTCMetadata {
        var m = metadata
        m.keywords = m.keywords.filter { !$0.hasPrefix(parent + " > ") } + names.map { parent + " > " + $0 }
        return m.sanitized
    }
}
