import Foundation
import CryptoKit

/// Installing the optional OpenStill MCP from its own GitHub repo, and connecting it to AI apps.
/// Nothing here runs unless you choose Install in Settings → AI Assistant.
public enum MCPInstall {
    public static let executableName = "openstill-mcp"
    public static var executable: URL { Assistant.mcpFolder.appendingPathComponent(executableName) }
    public static var versionFile: URL { Assistant.mcpFolder.appendingPathComponent("VERSION") }
    public static var installedVersion: String? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return (try? String(contentsOf: versionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "installed"
    }
    public static var latestReleaseAPI: URL { URL(string: "https://api.github.com/repos/\(Assistant.repository)/releases/latest")! }

    public struct Release: Equatable {
        public let version: String
        public let archive: URL
        public let checksums: URL
        public let archiveName: String
    }
    /// Reads GitHub's "latest release" answer: the zip and its SHA256SUMS, both from the release's own downloads.
    public static func release(from json: Data) throws -> Release {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Answer: Decodable { let tag_name: String; let assets: [Asset] }
        let answer = try JSONDecoder().decode(Answer.self, from: json)
        let prefix = "https://github.com/\(Assistant.repository)/releases/download/"
        guard let zip = answer.assets.first(where: { $0.name.hasPrefix(executableName) && $0.name.hasSuffix(".zip") }),
              let sums = answer.assets.first(where: { $0.name == "SHA256SUMS" }),
              zip.browser_download_url.hasPrefix(prefix), sums.browser_download_url.hasPrefix(prefix),
              let archive = URL(string: zip.browser_download_url), let checksums = URL(string: sums.browser_download_url) else {
            throw AssistantError.message("The latest OpenStill MCP release is missing its download or checksums.")
        }
        let version = answer.tag_name.hasPrefix("v") ? String(answer.tag_name.dropFirst()) : answer.tag_name
        return Release(version: version, archive: archive, checksums: checksums, archiveName: zip.name)
    }
    /// "<sha256>  <file>" lines, as written by `shasum -a 256`.
    public static func checksums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) else { continue }
            result[parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : parts[1]] = parts[0].lowercased()
        }
        return result
    }
    public static func verify(_ data: Data, name: String, sums: [String: String]) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let expected = sums[name] else { throw AssistantError.message("The checksum list doesn’t include \(name).") }
        guard expected == digest else { throw AssistantError.message("The download didn’t match its checksum, so it wasn’t installed.") }
    }
    /// Unpacks a verified archive and installs the MCP program with its version.
    public static func install(archive data: Data, version: String) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("OpenStill-MCP-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let zip = temp.appendingPathComponent("mcp.zip"), out = temp.appendingPathComponent("out")
        try data.write(to: zip)
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); task.arguments = ["-x", "-k", zip.path, out.path]
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw AssistantError.message("The OpenStill MCP download couldn’t be unpacked.") }
        let found = FileManager.default.enumerator(at: out, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == executableName && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
        guard let program = found else { throw AssistantError.message("The download doesn’t contain the OpenStill MCP program.") }
        try FileManager.default.createDirectory(at: Assistant.mcpFolder, withIntermediateDirectories: true)
        let staged = Assistant.mcpFolder.appendingPathComponent(executableName + ".new")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: program, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        if FileManager.default.fileExists(atPath: executable.path) { _ = try FileManager.default.replaceItemAt(executable, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: executable) }
        try Data((version + "\n").utf8).write(to: versionFile, options: .atomic)
    }
    public static func uninstall() throws {
        if FileManager.default.fileExists(atPath: Assistant.mcpFolder.path) { try FileManager.default.removeItem(at: Assistant.mcpFolder) }
    }

    // MARK: Connecting AI apps
    public static var claudeDesktopConfig: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Claude/claude_desktop_config.json")
    }
    /// Claude Desktop's settings with an "openstill" MCP server added (or updated); everything else in the file is kept.
    public static func addingServer(to existing: Data?, command: String) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else { throw AssistantError.message("Claude Desktop’s settings file isn’t valid JSON, so it wasn’t changed.") }
            root = object
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["openstill"] = ["command": command, "args": [String]()]
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
    /// Claude Desktop's settings without the "openstill" server.
    public static func removingServer(from existing: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else { throw AssistantError.message("Claude Desktop’s settings file isn’t valid JSON, so it wasn’t changed.") }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: "openstill")
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
    public static func isConnectedToClaudeDesktop(_ existing: Data?) -> Bool {
        guard let existing, let root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return false }
        return (root["mcpServers"] as? [String: Any])?["openstill"] != nil
    }
    /// The command to paste in a terminal to add OpenStill to Claude Code.
    public static var claudeCodeCommand: String { "claude mcp add openstill -- \"\(executable.path)\"" }
}
