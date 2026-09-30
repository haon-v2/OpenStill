import Foundation
import CryptoKit

/// Installing the optional OpenStill MCP from its own GitHub repo, and connecting it to AI apps.
/// Nothing here runs unless you choose Install in Settings → AI Assistant.
public enum MCPInstall {
    public static let executableName = "openstill-mcp"
    public static var executable: URL { Assistant.mcpFolder.appendingPathComponent(executableName) }
    public static var versionFile: URL { Assistant.mcpFolder.appendingPathComponent("VERSION") }
    public static var installedVersion: String? {
        guard isProgram(executable) else { return nil }
        return (try? String(contentsOf: versionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "installed"
    }
    /// An executable regular file; a folder with the same name (which 0.0.20 installed by mistake) doesn't count.
    public static func isProgram(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true && FileManager.default.isExecutableFile(atPath: url.path)
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
    /// Unpacks a verified archive and installs the MCP program with its version, then checks that it runs.
    /// The release zip holds a folder named like the program, so only a regular file of that name is taken.
    public static func install(archive data: Data, version: String, into folder: URL = Assistant.mcpFolder) throws {
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
            .first { url in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return url.lastPathComponent == executableName && values?.isRegularFile == true && values?.isSymbolicLink != true
            }
        guard let program = found else { throw AssistantError.message("The download doesn’t contain the OpenStill MCP program.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent(executableName + ".new"), target = folder.appendingPathComponent(executableName)
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: program, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        guard runs(staged) else {
            try? FileManager.default.removeItem(at: staged)
            throw AssistantError.message("The downloaded OpenStill MCP didn’t start on this Mac, so it wasn’t installed.")
        }
        // Replaces an older program, or the folder 0.0.20 left in its place.
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: staged, to: target)
        try Data((version + "\n").utf8).write(to: folder.appendingPathComponent("VERSION"), options: .atomic)
    }
    /// Runs `program --version` and waits up to 10 seconds for it to succeed.
    static func runs(_ program: URL) -> Bool {
        let task = Process(); task.executableURL = program; task.arguments = ["--version"]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        let deadline = Date().addingTimeInterval(10)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if task.isRunning { task.terminate(); return false }
        return task.terminationStatus == 0
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
