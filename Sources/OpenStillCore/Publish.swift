import Foundation
import CryptoKit
import Security

// MARK: OAuth 1.0a (Flickr and SmugMug)

/// API key and secret you register with the service, plus the access token OpenStill receives after you approve it in the browser.
public struct OAuthCredentials: Codable, Equatable, Sendable {
    public var consumerKey: String, consumerSecret: String
    public var token = "", tokenSecret = ""
    public init(consumerKey: String, consumerSecret: String, token: String = "", tokenSecret: String = "") {
        self.consumerKey = consumerKey; self.consumerSecret = consumerSecret; self.token = token; self.tokenSecret = tokenSecret
    }
    public var isAuthorized: Bool { !token.isEmpty && !tokenSecret.isEmpty }
}

public enum OAuth1 {
    /// RFC 3986 percent-encoding (only unreserved characters stay as they are).
    public static func encode(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    /// HMAC-SHA1 signature over the method, base URL and every query, form and oauth_ parameter.
    public static func signature(method: String, url: URL, parameters: [(String, String)], consumerSecret: String, tokenSecret: String) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        components.query = nil; components.fragment = nil
        let base = components.url!.absoluteString
        let normalized = (parameters + query).map { (encode($0.0), encode($0.1)) }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let text = method.uppercased() + "&" + encode(base) + "&" + encode(normalized)
        let key = SymmetricKey(data: Data((encode(consumerSecret) + "&" + encode(tokenSecret)).utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(text.utf8), using: key)
        return Data(mac).base64EncodedString()
    }
    /// The `Authorization: OAuth …` header value. `parameters` are form fields that are signed too (not file uploads or JSON bodies).
    public static func header(method: String, url: URL, parameters: [(String, String)] = [], credentials: OAuthCredentials, extra: [String: String] = [:],
                              nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""), timestamp: String = String(Int(Date().timeIntervalSince1970))) -> String {
        var oauth: [String: String] = ["oauth_consumer_key": credentials.consumerKey, "oauth_nonce": nonce, "oauth_signature_method": "HMAC-SHA1", "oauth_timestamp": timestamp, "oauth_version": "1.0"]
        if !credentials.token.isEmpty { oauth["oauth_token"] = credentials.token }
        for (k, v) in extra { oauth[k] = v }
        oauth["oauth_signature"] = signature(method: method, url: url, parameters: parameters + oauth.map { ($0.key, $0.value) }, consumerSecret: credentials.consumerSecret, tokenSecret: credentials.tokenSecret)
        return "OAuth " + oauth.sorted { $0.key < $1.key }.map { "\(encode($0.key))=\"\(encode($0.value))\"" }.joined(separator: ", ")
    }
    public static func formDecode(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
            if let key = parts.first { out[key] = parts.count > 1 ? parts[1] : "" }
        }
        return out
    }
}

/// Service tokens live in the login keychain, never in OpenStill's files.
public enum Keychain {
    static let service = "OpenStill Publish"
    public static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw PublishError.keychain(status) }
    }
    public static func load(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
    public static func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}

// MARK: Services

public enum PublishServiceKind: String, Codable, CaseIterable, Sendable {
    case folder, flickr, smugmug
    public var title: String { self == .folder ? "Folder (local or synced)" : self == .flickr ? "Flickr" : "SmugMug" }
    /// Where OAuth tokens are requested and approved.
    var endpoints: (request: URL, authorize: URL, access: URL)? {
        switch self {
        case .folder: return nil
        case .flickr: return (URL(string: "https://www.flickr.com/services/oauth/request_token")!, URL(string: "https://www.flickr.com/services/oauth/authorize")!, URL(string: "https://www.flickr.com/services/oauth/access_token")!)
        case .smugmug: return (URL(string: "https://api.smugmug.com/services/oauth/1.0a/getRequestToken")!, URL(string: "https://api.smugmug.com/services/oauth/1.0a/authorize")!, URL(string: "https://api.smugmug.com/services/oauth/1.0a/getAccessToken")!)
        }
    }
}
public enum PublishError: LocalizedError, Equatable {
    case keychain(OSStatus), notConnected, noFolder, noAlbum, service(String)
    public var errorDescription: String? {
        switch self {
        case .keychain(let status): return "The keychain refused to store the sign-in (\(status))."
        case .notConnected: return "Connect this service first: enter your API key and secret, then approve OpenStill in the browser."
        case .noFolder: return "Choose a folder for this collection."
        case .noAlbum: return "Enter the SmugMug album key (the part after /album/ in the album’s API address)."
        case .service(let message): return message
        }
    }
}
public protocol PublishService {
    /// Uploads `file` and returns the service's id for it. With `replacing`, the old copy is replaced (or removed after the new upload).
    func upload(_ file: URL, name: String, title: String, replacing: String?) async throws -> String
    func remove(_ remoteID: String) async throws
}

/// Writes JPEGs into a folder: a web server's folder, or one that iCloud Drive, Dropbox or a NAS keeps in sync.
public struct FolderService: PublishService {
    public var folder: URL
    public init(folder: URL) { self.folder = folder }
    public func upload(_ file: URL, name: String, title: String, replacing: String?) async throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let old = replacing { try? fm.removeItem(at: folder.appendingPathComponent(URL(fileURLWithPath: old).lastPathComponent)) }
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent, ext = URL(fileURLWithPath: name).pathExtension
        var target = folder.appendingPathComponent(name), n = 2
        while fm.fileExists(atPath: target.path) { target = folder.appendingPathComponent("\(stem)-\(n).\(ext)"); n += 1 }
        try fm.copyItem(at: file, to: target)
        return target.lastPathComponent
    }
    public func remove(_ remoteID: String) async throws {
        let target = folder.appendingPathComponent(URL(fileURLWithPath: remoteID).lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }
}

enum HTTP {
    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PublishError.service("The service answered \(code): " + String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }
    static func multipart(fields: [(String, String)], file: URL, fileField: String, filename: String, boundary: String) throws -> Data {
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        for (k, v) in fields { line("--\(boundary)"); line("Content-Disposition: form-data; name=\"\(k)\""); line(""); line(v) }
        line("--\(boundary)"); line("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\""); line("Content-Type: image/jpeg"); line("")
        body.append(try Data(contentsOf: file)); line(""); line("--\(boundary)--")
        return body
    }
}

public struct FlickrService: PublishService {
    public var credentials: OAuthCredentials
    public init(credentials: OAuthCredentials) { self.credentials = credentials }
    public func upload(_ file: URL, name: String, title: String, replacing: String?) async throws -> String {
        guard credentials.isAuthorized else { throw PublishError.notConnected }
        let url = URL(string: "https://up.flickr.com/services/upload/")!, boundary = "OpenStill-" + UUID().uuidString
        let fields = [("title", title.isEmpty ? URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent : title)]
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue(OAuth1.header(method: "POST", url: url, parameters: fields, credentials: credentials), forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try HTTP.multipart(fields: fields, file: file, fileField: "photo", filename: name, boundary: boundary)
        let reply = String(decoding: try await HTTP.send(request), as: UTF8.self)
        guard reply.contains("stat=\"ok\""), let start = reply.range(of: "<photoid>"), let end = reply.range(of: "</photoid>"), start.upperBound < end.lowerBound else {
            throw PublishError.service("Flickr didn’t accept the photo: " + String(reply.prefix(300)))
        }
        let id = String(reply[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
        if let old = replacing { try? await remove(old) }
        return id
    }
    public func remove(_ remoteID: String) async throws {
        guard credentials.isAuthorized else { throw PublishError.notConnected }
        let url = URL(string: "https://api.flickr.com/services/rest/")!
        let fields = [("method", "flickr.photos.delete"), ("photo_id", remoteID), ("format", "json"), ("nojsoncallback", "1")]
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue(OAuth1.header(method: "POST", url: url, parameters: fields, credentials: credentials), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\(OAuth1.encode($0.0))=\(OAuth1.encode($0.1))" }.joined(separator: "&").utf8)
        let reply = String(decoding: try await HTTP.send(request), as: UTF8.self)
        guard reply.contains("\"stat\":\"ok\"") else { throw PublishError.service("Flickr didn’t remove the photo: " + String(reply.prefix(300))) }
    }
}

public struct SmugMugService: PublishService {
    public var credentials: OAuthCredentials
    public var albumKey: String
    public init(credentials: OAuthCredentials, albumKey: String) { self.credentials = credentials; self.albumKey = albumKey }
    public func upload(_ file: URL, name: String, title: String, replacing: String?) async throws -> String {
        guard credentials.isAuthorized else { throw PublishError.notConnected }
        guard !albumKey.isEmpty else { throw PublishError.noAlbum }
        let url = URL(string: "https://upload.smugmug.com/")!, data = try Data(contentsOf: file)
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = data
        request.setValue(OAuth1.header(method: "POST", url: url, credentials: credentials), forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "Content-MD5")
        request.setValue("/api/v2/album/\(albumKey)", forHTTPHeaderField: "X-Smug-AlbumUri")
        request.setValue("JSON", forHTTPHeaderField: "X-Smug-ResponseType"); request.setValue("v2", forHTTPHeaderField: "X-Smug-Version")
        request.setValue(name, forHTTPHeaderField: "X-Smug-FileName")
        if !title.isEmpty { request.setValue(title, forHTTPHeaderField: "X-Smug-Title") }
        // SmugMug replaces an image in place, keeping its place in the album.
        if let old = replacing, let imageURI = old.components(separatedBy: "|").first, !imageURI.isEmpty { request.setValue(imageURI, forHTTPHeaderField: "X-Smug-ImageUri") }
        let reply = try JSONSerialization.jsonObject(with: try await HTTP.send(request)) as? [String: Any]
        guard (reply?["stat"] as? String) == "ok", let image = reply?["Image"] as? [String: Any], let imageURI = image["ImageUri"] as? String else {
            throw PublishError.service("SmugMug didn’t accept the photo: \(reply?["message"] ?? "no answer")")
        }
        return imageURI + "|" + (image["AlbumImageUri"] as? String ?? "")
    }
    public func remove(_ remoteID: String) async throws {
        guard credentials.isAuthorized else { throw PublishError.notConnected }
        let parts = remoteID.components(separatedBy: "|"), path = parts.count > 1 && !parts[1].isEmpty ? parts[1] : parts[0]
        guard let url = URL(string: "https://api.smugmug.com" + path) else { return }
        var request = URLRequest(url: url); request.httpMethod = "DELETE"
        request.setValue(OAuth1.header(method: "DELETE", url: url, credentials: credentials), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await HTTP.send(request)
    }
}

/// Browser sign-in: request a token, you approve OpenStill on the service's site and paste the code it shows, then the token is exchanged.
public enum OAuthSignIn {
    public static func start(_ kind: PublishServiceKind, key: String, secret: String) async throws -> (credentials: OAuthCredentials, authorize: URL) {
        guard let endpoints = kind.endpoints else { throw PublishError.notConnected }
        let consumer = OAuthCredentials(consumerKey: key, consumerSecret: secret)
        var request = URLRequest(url: endpoints.request); request.httpMethod = "POST"
        request.setValue(OAuth1.header(method: "POST", url: endpoints.request, credentials: consumer, extra: ["oauth_callback": "oob"]), forHTTPHeaderField: "Authorization")
        let reply = OAuth1.formDecode(String(decoding: try await HTTP.send(request), as: UTF8.self))
        guard let token = reply["oauth_token"], let tokenSecret = reply["oauth_token_secret"] else { throw PublishError.service("The service didn’t return a sign-in token. Check the API key and secret.") }
        var authorize = URLComponents(url: endpoints.authorize, resolvingAgainstBaseURL: false)!
        authorize.queryItems = [URLQueryItem(name: "oauth_token", value: token)] + (kind == .flickr ? [URLQueryItem(name: "perms", value: "delete")] : [URLQueryItem(name: "Access", value: "Full"), URLQueryItem(name: "Permissions", value: "Modify")])
        return (OAuthCredentials(consumerKey: key, consumerSecret: secret, token: token, tokenSecret: tokenSecret), authorize.url!)
    }
    public static func finish(_ kind: PublishServiceKind, pending: OAuthCredentials, verifier: String) async throws -> OAuthCredentials {
        guard let endpoints = kind.endpoints else { throw PublishError.notConnected }
        var request = URLRequest(url: endpoints.access); request.httpMethod = "POST"
        request.setValue(OAuth1.header(method: "POST", url: endpoints.access, credentials: pending, extra: ["oauth_verifier": verifier.trimmingCharacters(in: .whitespacesAndNewlines)]), forHTTPHeaderField: "Authorization")
        let reply = OAuth1.formDecode(String(decoding: try await HTTP.send(request), as: UTF8.self))
        guard let token = reply["oauth_token"], let tokenSecret = reply["oauth_token_secret"] else { throw PublishError.service("The service didn’t confirm the sign-in. Try again and paste the newest code.") }
        return OAuthCredentials(consumerKey: pending.consumerKey, consumerSecret: pending.consumerSecret, token: token, tokenSecret: tokenSecret)
    }
}

// MARK: Collections and tracking

public struct PublishedPhoto: Codable, Equatable, Sendable {
    public var remoteID: String
    /// The version and edit revision that was published; a later edit makes the photo "modified".
    public var versionID: UUID, revision: UUID
    public var date: Date
}
public enum PublishState: String, Sendable { case new, modified, published }

public struct PublishCollection: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var kind: PublishServiceKind
    public var folderPath: String?
    public var albumKey: String?
    public var export = ExportSettings()
    /// Photos in the collection, by record id, in the order added.
    public var photos: [UUID] = []
    public var published: [UUID: PublishedPhoto] = [:]
    /// Photos taken out of the collection whose published copies still need removing.
    public var pendingRemoval: [PublishedPhoto] = []
    public init(name: String, kind: PublishServiceKind) {
        self.name = name; self.kind = kind
        export.format = .jpeg; export.profile = .sRGB; export.longestEdge = 2048; export.keepGPS = false; export.filenameTemplate = "{name}"
    }
    public var keychainAccount: String { "\(kind.rawValue)-\(id.uuidString)" }
    public func state(of record: PhotoRecord) -> PublishState {
        guard let done = published[record.id] else { return .new }
        return done.versionID == record.active.id && done.revision == record.active.revision ? .published : .modified
    }
    public mutating func add(_ ids: [UUID]) { for id in ids where !photos.contains(id) { photos.append(id) } }
    public mutating func remove(_ ids: [UUID]) {
        for id in ids {
            photos.removeAll { $0 == id }
            if let done = published.removeValue(forKey: id) { pendingRemoval.append(done) }
        }
    }
}

public enum PublishStore {
    static func file(_ root: URL) -> URL { root.appendingPathComponent("PublishCollections.json") }
    public static func load(root: URL = EditStorage.root) -> [PublishCollection] {
        (try? JSONDecoder().decode([PublishCollection].self, from: Data(contentsOf: file(root)))) ?? []
    }
    public static func save(_ collections: [PublishCollection], root: URL = EditStorage.root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(collections).write(to: file(root), options: .atomic)
    }
    public static func credentials(for collection: PublishCollection) -> OAuthCredentials? {
        Keychain.load(account: collection.keychainAccount).flatMap { try? JSONDecoder().decode(OAuthCredentials.self, from: $0) }
    }
    public static func saveCredentials(_ credentials: OAuthCredentials, for collection: PublishCollection) throws {
        try Keychain.save(try JSONEncoder().encode(credentials), account: collection.keychainAccount)
    }
    public static func service(for collection: PublishCollection) throws -> PublishService {
        switch collection.kind {
        case .folder:
            guard let path = collection.folderPath, !path.isEmpty else { throw PublishError.noFolder }
            return FolderService(folder: URL(fileURLWithPath: path, isDirectory: true))
        case .flickr:
            guard let c = credentials(for: collection), c.isAuthorized else { throw PublishError.notConnected }
            return FlickrService(credentials: c)
        case .smugmug:
            guard let c = credentials(for: collection), c.isAuthorized else { throw PublishError.notConnected }
            return SmugMugService(credentials: c, albumKey: collection.albumKey ?? "")
        }
    }
}

public enum Publisher {
    public struct Report: Sendable { public var published = 0, removed = 0, failures: [String] = [] }
    /// Publishes new and modified photos and removes the ones taken out of the collection. `items` are the library photos (by record id).
    public static func run(_ collection: inout PublishCollection, items: [UUID: ShootItem], service: PublishService, progress: ((Int, Int) -> Void)? = nil) async -> Report {
        var report = Report()
        for old in collection.pendingRemoval {
            do { try await service.remove(old.remoteID); report.removed += 1; collection.pendingRemoval.removeAll { $0 == old } }
            catch { report.failures.append("Remove \(old.remoteID): \(error.localizedDescription)") }
        }
        let due = collection.photos.compactMap { items[$0] }.filter { collection.state(of: $0.record) != .published }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("OpenStill-publish-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        for (i, item) in due.enumerated() {
            progress?(i, due.count)
            do {
                let job = ExportJob(item)
                let name = try ExportWorkflow.filename(job, index: i, settings: collection.export)
                let file = temp.appendingPathComponent(name)
                try autoreleasepool {
                    let image = try ModernRenderer.render(source: item.url, recipe: item.record.active.recipe.sdr)
                    try ModernRenderer.export(image, to: file, source: item.url, settings: collection.export, metadata: collection.export.keepMetadata ? item.record.metadata : nil)
                }
                let remote = try await service.upload(file, name: name, title: item.record.iptc.title, replacing: collection.published[item.id]?.remoteID)
                collection.published[item.id] = PublishedPhoto(remoteID: remote, versionID: item.record.active.id, revision: item.record.active.revision, date: Date())
                report.published += 1
            } catch { report.failures.append("\(item.url.lastPathComponent): \(error.localizedDescription)") }
        }
        progress?(due.count, due.count)
        return report
    }
}
