import Foundation

/// One entry from GitHub's releases API.
public struct AppRelease: Decodable, Equatable, Sendable {
    public let tagName: String
    public let name: String?
    public let htmlURL: URL
    public let draft: Bool
    public let prerelease: Bool
    enum CodingKeys: String, CodingKey { case tagName = "tag_name", name, htmlURL = "html_url", draft, prerelease }
    public init(tagName: String, name: String?, htmlURL: URL, draft: Bool = false, prerelease: Bool = false) {
        self.tagName = tagName; self.name = name; self.htmlURL = htmlURL; self.draft = draft; self.prerelease = prerelease
    }
    /// Version numbers from the tag ("v0.8.0"), else from the title ("OpenStill v.0.1").
    public var version: [Int]? { UpdateCheck.version(in: tagName) ?? name.flatMap { UpdateCheck.version(in: $0) } }
    public var versionString: String { version.map { $0.map(String.init).joined(separator: ".") } ?? tagName }
    public var title: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? tagName }
}

public enum UpdateError: LocalizedError, Equatable {
    case http(Int), unreadable
    public var errorDescription: String? {
        switch self {
        case .http(403), .http(429): return "GitHub is limiting requests right now. Try again in an hour."
        case .http(404): return "The OpenStill releases page couldn’t be found on GitHub."
        case .http(let code): return "GitHub answered with an error (HTTP \(code)). Try again later."
        case .unreadable: return "GitHub’s release list couldn’t be read."
        }
    }
}

/// Checks OpenStill's GitHub releases. Only the public release list is requested; nothing about the user or their photos is sent.
public enum UpdateCheck {
    public static let repository = "haon-v2/OpenStill"
    public static var releasesAPI: URL { URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")! }
    public static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }

    /// The first dotted number in the text: "v0.8.1" → [0, 8, 1], "OpenStill v.0.1" → [0, 1].
    public static func version(in text: String) -> [Int]? {
        var parts: [Int] = [], digits = "", started = false
        for character in text {
            if character.isASCII, character.isNumber { digits.append(character); started = true }
            else if started, character == ".", !digits.isEmpty { parts.append(Int(digits) ?? 0); digits = "" }
            else if started { break }
        }
        if !digits.isEmpty { parts.append(Int(digits) ?? 0) }
        return parts.isEmpty ? nil : parts
    }
    public static func isNewer(_ candidate: [Int], than current: [Int]) -> Bool {
        for index in 0..<max(candidate.count, current.count) {
            let a = index < candidate.count ? candidate[index] : 0, b = index < current.count ? current[index] : 0
            if a != b { return a > b }
        }
        return false
    }
    /// The highest-versioned published release newer than `current`, or nil when up to date.
    public static func newest(in releases: [AppRelease], newerThan current: String) -> AppRelease? {
        let installed = version(in: current) ?? [0]
        return releases.filter { !$0.draft }
            .compactMap { release in release.version.map { (release, $0) } }
            .filter { isNewer($0.1, than: installed) }
            .max { isNewer($1.1, than: $0.1) }?.0
    }
    public static func parse(_ data: Data) throws -> [AppRelease] {
        do { return try JSONDecoder().decode([AppRelease].self, from: data) } catch { throw UpdateError.unreadable }
    }
    public static func fetchReleases(completion: @escaping @Sendable (Result<[AppRelease], Error>) -> Void) {
        var request = URLRequest(url: releasesAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenStill", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data else { completion(.failure(UpdateError.http(status))); return }
            completion(Result { try parse(data) })
        }.resume()
    }
}
