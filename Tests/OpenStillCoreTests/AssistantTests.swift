import Foundation
import CoreGraphics
import Testing
@testable import OpenStillCore

@Suite(.serialized) final class AssistantTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    /// A tiny valid 2×2×2 identity LUT.
    var cube: String {
        var lines = ["TITLE \"Test\"", "LUT_3D_SIZE 2"]
        for b in 0...1 { for g in 0...1 { for r in 0...1 { lines.append("\(r) \(g) \(b)") } } }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test func messagesRoundTripAndFrameByLine() throws {
        let request = AssistantMessage(type: "request", id: "7", tool: "set_adjustments", arguments: .object(["values": .object(["exposure": .number(0.5)])]))
        var framing = AssistantFraming()
        var bytes = try request.line(); bytes.append(try AssistantMessage.response(to: "7", .string("ok")).line())
        let first = try framing.append(bytes.prefix(10))
        #expect(first.isEmpty)
        let rest = try framing.append(bytes.dropFirst(10))
        #expect(rest.count == 2 && rest[0] == request && rest[1].result == .string("ok"))
        #expect(rest[0].arguments?["values"]?["exposure"]?.double == 0.5)
        #expect(throws: (any Error).self) { var f = AssistantFraming(); _ = try f.append(Data("not json\n".utf8)) }
    }

    @Test func helloChecksTheProtocolVersion() throws {
        let client = AssistantClient(name: "Claude", version: "1", supportsSampling: true)
        #expect(try Assistant.accept(AssistantMessage(type: "hello", version: Assistant.protocolVersion, client: client)) == client)
        #expect(throws: AssistantError.message("This OpenStill MCP is newer than OpenStill. Update OpenStill.")) {
            try Assistant.accept(AssistantMessage(type: "hello", version: Assistant.protocolVersion + 1))
        }
        #expect(throws: (any Error).self) { try Assistant.accept(AssistantMessage(type: "hello", version: 0)) }
        #expect(throws: (any Error).self) { try Assistant.accept(AssistantMessage(type: "request", version: 1)) }
        #expect(Assistant.previewSize(nil) == 1024 && Assistant.previewSize(99_999) == 2048 && Assistant.previewSize(10) == 512)
    }

    @Test func slidersAreNamedLimitedAndValidated() throws {
        let (edits, changed) = try AssistantAdjustments.apply(["exposure": .number(9), "contrast": .number(1.2), "temperature": .string("7200"), "clarity": .number(-3)], to: PhotoEdits())
        #expect(edits.exposure == 4 && abs(edits.contrast - 1.2) < 1e-9 && edits.temperature == 7200 && edits.clarity == -1)
        #expect(changed == ["clarity", "contrast", "exposure", "temperature"])
        #expect(throws: (any Error).self) { try AssistantAdjustments.apply(["brightness": .number(1)], to: PhotoEdits()) }
        #expect(throws: (any Error).self) { try AssistantAdjustments.apply(["exposure": .string("lots")], to: PhotoEdits()) }
        #expect(throws: (any Error).self) { try AssistantAdjustments.apply([:], to: PhotoEdits()) }
        #expect(throws: (any Error).self) { try AssistantAdjustments.apply(["exposure": .number(.nan)], to: PhotoEdits()) }
        let described = AssistantAdjustments.describe(edits)
        #expect(described["exposure"]?.double == 4 && described["mask_layers"]?.array?.isEmpty == true)
        // Every slider can be read back and has a neutral value inside its range.
        for slider in AssistantAdjustments.sliders { #expect(slider.range.contains(slider.neutral) && described[slider.name] != nil) }
    }

    @Test func masksFromCoordinatesAndLayerSliders() throws {
        let linear = try AssistantMasks.shape("linear", ["from": .array([.number(0.5), .number(0)]), "to": .array([.number(0.5), .number(0.4)])])
        // Top-left coordinates become Core Image's bottom-left ones.
        #expect(linear.kind == "linear" && linear.start.y == 1 && abs(linear.end.y - 0.6) < 1e-9)
        let radial = try AssistantMasks.shape("radial", ["center": .array([.number(0.25), .number(0.25)]), "radius": .number(0.2), "invert": .bool(true)])
        #expect(radial.kind == "radial" && abs(radial.start.y - 0.75) < 1e-9 && abs(radial.end.x - 0.45) < 1e-9 && radial.inverted)
        #expect(throws: (any Error).self) { try AssistantMasks.shape("radial", ["center": .string("middle")]) }
        let settings = try AssistantMasks.settings(["exposure": .number(-9), "saturation": .number(0.4)])
        #expect(settings.exposure == -4 && settings.saturation == 0.4)
        #expect(throws: (any Error).self) { try AssistantMasks.settings(["glow": .number(1)]) }
        // The shape renders like a mask made by hand.
        var edits = PhotoEdits(); let layer = edits.addLocalAdjustment(named: "Sky"); edits.setMask(linear, for: layer.maskKey)
        #expect(try edits.advanced?.masks[layer.maskKey]?.image(size: CGSize(width: 32, height: 32)).extent.width == 32)
    }

    @Test func photoSearchFiltersAndSorts() {
        var a = CatalogPhoto(id: UUID(), path: "/Photos/Trip/a.jpg"); a.rating = 4; a.camera = "Canon EOS R5"; a.keywords = ["Places>Italy"]; a.captured = Date(timeIntervalSince1970: 1_700_000_000)
        var b = CatalogPhoto(id: UUID(), path: "/Photos/Trip/b.jpg"); b.rating = 2; b.flag = .pick; b.captured = Date(timeIntervalSince1970: 1_700_100_000)
        var c = CatalogPhoto(id: UUID(), path: "/Photos/Other/c.jpg"); c.label = .red; c.edited = true
        let all = [a, b, c]
        #expect(AssistantQuery.filter(all, [:]).map(\.id) == [b.id, a.id, c.id])
        #expect(AssistantQuery.filter(all, ["folder": .string("/Photos/Trip")]).count == 2)
        #expect(AssistantQuery.filter(all, ["min_rating": .number(3)]).map(\.id) == [a.id])
        #expect(AssistantQuery.filter(all, ["flag": .string("pick")]).map(\.id) == [b.id])
        #expect(AssistantQuery.filter(all, ["label": .string("Red"), "edited": .bool(true)]).map(\.id) == [c.id])
        #expect(AssistantQuery.filter(all, ["keyword": .string("italy"), "camera": .string("canon")]).map(\.id) == [a.id])
        #expect(AssistantQuery.filter(all, ["captured_after": .string("2023-11-15")]).map(\.id) == [b.id])
        #expect(AssistantQuery.filter(all, ["limit": .number(1)]).count == 1)
        #expect(AssistantQuery.describe(a)["rating"]?.double == 4 && AssistantQuery.describe(a)["keywords"]?.array?.count == 1)
    }

    @Test func lutImportNeedsHttpsAFreeLicenseAndARealLUT() throws {
        #expect(throws: (any Error).self) { try LUTImport.check(URL(string: "http://example.com/a.cube")!) }
        #expect(throws: (any Error).self) { try LUTImport.check(URL(string: "https://localhost/a.cube")!) }
        #expect(throws: (any Error).self) { try LUTImport.check(URL(string: "https://192.168.1.4/a.cube")!) }
        #expect(throws: (any Error).self) { try LUTImport.check(URL(string: "https://user:pw@example.com/a.cube")!) }
        try LUTImport.check(URL(string: "https://example.com/looks/a.cube")!)
        #expect(LUTImport.license("cc0") == "CC0-1.0" && LUTImport.license("Creative Commons Attribution") == "CC-BY-4.0" && LUTImport.license("All rights reserved") == nil)
        let folder = directory.appendingPathComponent("LUTLibrary")
        var source = LUTSource(name: "Film ../../Warm", creator: "Someone", license: "Proprietary", sourcePage: "https://example.com/luts", url: "https://example.com/a.cube", foundByAI: true)
        #expect(throws: (any Error).self) { try LUTImport.install(Data(self.cube.utf8), suggestedName: "a.cube", source: source, into: folder) }
        source.license = "CC0"
        #expect(throws: (any Error).self) { try LUTImport.install(Data("not a lut".utf8), suggestedName: "a.cube", source: source, into: folder) }
        let installed = try LUTImport.install(Data(cube.utf8), suggestedName: "a.cube", source: source, into: folder)
        #expect(installed.count == 1 && installed[0].deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(!installed[0].lastPathComponent.contains("/") && !installed[0].path.contains(".."))
        // The library lists it under "Found by AI" with its license.
        let item = try #require(LUTLibrary(imported: folder).filtered("Found by AI").first)
        #expect(item.entry.license == "CC0-1.0" && item.entry.creator == "Someone" && item.entry.source == "https://example.com/luts")
        #expect(try item.load().dimension == 2)
    }

    @Test func lutZipsAreFlattenedAndChecked() throws {
        let staging = directory.appendingPathComponent("zip"); let nested = staging.appendingPathComponent("pack/looks")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(cube.utf8).write(to: nested.appendingPathComponent("Warm.cube"))
        try Data(cube.utf8).write(to: nested.appendingPathComponent("Cool.CUBE"))
        try Data("broken".utf8).write(to: nested.appendingPathComponent("Broken.cube"))
        try Data("readme".utf8).write(to: staging.appendingPathComponent("pack/README.txt"))
        let archive = directory.appendingPathComponent("pack.zip")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); zip.arguments = ["-c", "-k", "--sequesterRsrc", staging.appendingPathComponent("pack").path, archive.path]
        try zip.run(); zip.waitUntilExit()
        let folder = directory.appendingPathComponent("Zipped")
        let source = LUTSource(name: "Pack", creator: "", license: "MIT", sourcePage: "", url: "https://example.com/pack.zip", foundByAI: true)
        let installed = try LUTImport.install(try Data(contentsOf: archive), suggestedName: "pack.zip", source: source, into: folder)
        #expect(Set(installed.map(\.lastPathComponent)) == ["Pack — Cool.cube", "Pack — Warm.cube"])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!files.contains { $0.hasSuffix(".txt") } && !files.contains("pack"))
    }

    @Test func logoEngineAndSamplingRequest() throws {
        let claude = AssistantClient(name: "Claude", version: "1", supportsSampling: true)
        let plain = AssistantClient(name: "Other", version: "1", supportsSampling: false)
        #expect(LogoEngine.choose(assistant: claude, localModelInstalled: false) == .assistant("Claude"))
        #expect(LogoEngine.choose(assistant: plain, localModelInstalled: true) == .local)
        #expect(LogoEngine.choose(assistant: nil, localModelInstalled: true) == .local)
        #expect(LogoEngine.choose(assistant: nil, localModelInstalled: false) == .unavailable)
        let request = try LogoInference.samplingRequest(name: "Ada Studio", tagline: "", style: "Bold and modern", symbol: "aperture", color: LogoColor("#FFFFFF"), accent: LogoColor("#FF8800"))
        let text = request["messages"]?.array?.first?["content"]?["text"]?.string ?? ""
        #expect(text.contains("Ada Studio") && text.contains("Bold and modern") && text.contains("\"candidates\""))
        #expect(request["systemPrompt"]?.string == LogoInference.instructions)
    }

    @Test func mcpInstallReadsReleasesChecksumsAndClaudeSettings() throws {
        let json = Data("""
        {"tag_name":"v1.2.0","assets":[
          {"name":"openstill-mcp-1.2.0.zip","browser_download_url":"https://github.com/haon-v2/OpenStill-MCP/releases/download/v1.2.0/openstill-mcp-1.2.0.zip"},
          {"name":"SHA256SUMS","browser_download_url":"https://github.com/haon-v2/OpenStill-MCP/releases/download/v1.2.0/SHA256SUMS"}]}
        """.utf8)
        let release = try MCPInstall.release(from: json)
        #expect(release.version == "1.2.0" && release.archiveName == "openstill-mcp-1.2.0.zip")
        let elsewhere = Data(String(decoding: json, as: UTF8.self).replacingOccurrences(of: "https://github.com/haon-v2/OpenStill-MCP", with: "https://evil.example").utf8)
        #expect(throws: (any Error).self) { try MCPInstall.release(from: elsewhere) }
        let payload = Data("program".utf8)
        let sums = MCPInstall.checksums("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  empty.zip\n\(SHA256Hex(payload))  openstill-mcp-1.2.0.zip\n")
        try MCPInstall.verify(payload, name: "openstill-mcp-1.2.0.zip", sums: sums)
        #expect(throws: (any Error).self) { try MCPInstall.verify(Data("tampered".utf8), name: "openstill-mcp-1.2.0.zip", sums: sums) }
        #expect(throws: (any Error).self) { try MCPInstall.verify(payload, name: "missing.zip", sums: sums) }
        // Claude Desktop's settings keep everything else.
        let existing = Data(#"{"theme":"dark","mcpServers":{"files":{"command":"/bin/files"}}}"#.utf8)
        let added = try MCPInstall.addingServer(to: existing, command: "/path/openstill-mcp")
        #expect(MCPInstall.isConnectedToClaudeDesktop(added) && !MCPInstall.isConnectedToClaudeDesktop(existing))
        let object = try JSONSerialization.jsonObject(with: added) as! [String: Any]
        #expect(object["theme"] as? String == "dark" && (object["mcpServers"] as? [String: Any])?["files"] != nil)
        #expect(!MCPInstall.isConnectedToClaudeDesktop(try MCPInstall.removingServer(from: added)))
        #expect(MCPInstall.isConnectedToClaudeDesktop(try MCPInstall.addingServer(to: nil, command: "/x")))
        #expect(throws: (any Error).self) { try MCPInstall.addingServer(to: Data("{broken".utf8), command: "/x") }
    }
    @Test func mcpInstallTakesTheProgramNotItsFolder() throws {
        // The release zip is made with `ditto -c -k --keepParent openstill-mcp`: a folder named like the program, holding it.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let parent = temp.appendingPathComponent("openstill-mcp"), mcp = temp.appendingPathComponent("MCP")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 1.2.0\n".utf8).write(to: parent.appendingPathComponent("openstill-mcp"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.appendingPathComponent("openstill-mcp").path)
        try Data("MIT".utf8).write(to: parent.appendingPathComponent("LICENSE"))
        let zip = temp.appendingPathComponent("mcp.zip")
        let ditto = Process(); ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); ditto.arguments = ["-c", "-k", "--keepParent", parent.path, zip.path]
        try ditto.run(); ditto.waitUntilExit()
        // A folder left by 0.0.20 is replaced by the program.
        try FileManager.default.createDirectory(at: mcp.appendingPathComponent("openstill-mcp"), withIntermediateDirectories: true)
        #expect(!MCPInstall.isProgram(mcp.appendingPathComponent("openstill-mcp")))
        try MCPInstall.install(archive: Data(contentsOf: zip), version: "1.2.0", into: mcp)
        #expect(MCPInstall.isProgram(mcp.appendingPathComponent("openstill-mcp")))
        #expect(try String(contentsOf: mcp.appendingPathComponent("VERSION"), encoding: .utf8) == "1.2.0\n")
        // A program that doesn't start isn't installed.
        try Data("#!/bin/sh\nexit 3\n".utf8).write(to: parent.appendingPathComponent("openstill-mcp"))
        try FileManager.default.removeItem(at: zip)
        let again = Process(); again.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); again.arguments = ["-c", "-k", "--keepParent", parent.path, zip.path]
        try again.run(); again.waitUntilExit()
        #expect(throws: (any Error).self) { try MCPInstall.install(archive: Data(contentsOf: zip), version: "1.3.0", into: mcp) }
        #expect(MCPInstall.isProgram(mcp.appendingPathComponent("openstill-mcp")))
    }
    private func SHA256Hex(_ data: Data) -> String {
        let task = Process(), pipe = Pipe(), input = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shasum"); task.arguments = ["-a", "256"]; task.standardOutput = pipe; task.standardInput = input
        try? task.run(); input.fileHandleForWriting.write(data); try? input.fileHandleForWriting.close(); task.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
    }
}
