import AppKit
import OpenStillCore

final class LocalAI {
    private var process: Process?
    var isRunning: Bool { process != nil }
    static var root: URL { EditStorage.root.appendingPathComponent("AI") }
    static var python: URL { root.appendingPathComponent("runtime/bin/python3") }
    /// Whether setup downloaded the models for a tool (tools added in newer versions need setup to run again).
    static func hasModel(_ kind: String) -> Bool {
        if stub { return true }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("ready.json")),
              let ready = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let models = ready["models"] as? [String: Any] else { return false }
        return models[kind] != nil
    }
    /// Tools listed in this version's model manifest that the last setup didn't download.
    static var missingModels: [String] {
        guard ready, let data = try? Data(contentsOf: script.deletingLastPathComponent().appendingPathComponent("models.json")), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return manifest.keys.filter { !hasModel($0) }.sorted()
    }
    /// TEMPORARY for CI: a stand-in worker that returns the photo unchanged (erase paints the masked area gray),
    /// so the app's real AI pipeline can be checked without the model download.
    static var stub: Bool { ProcessInfo.processInfo.environment["OPENSTILL_AI_STUB"] != nil }
    static var ready: Bool { stub || FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path) }
    static var script: URL {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("AI/engine.py"), FileManager.default.fileExists(atPath: resource.path) { return resource }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AI/engine.py")
    }
    func cancel() { process?.terminate() }
    func run(tool: String, arguments: [String] = [], status: @escaping (String) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        guard process == nil else { return }
        if Self.stub && tool != "setup" { Self.runStub(tool: tool, arguments: arguments, completion: completion); return }
        let executable: URL
        if tool == "setup" {
            let candidates = ["/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.11", "/usr/local/bin/python3.12", "/usr/local/bin/python3.11", "/usr/bin/python3"]
            guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                completion(.failure(NSError(domain: "OpenStill", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install Python 3.10–3.12, then choose Set up on-device AI again."]))); return
            }
            executable = URL(fileURLWithPath: path)
        } else {
            guard Self.ready else { completion(.failure(NSError(domain: "OpenStill", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose Set up on-device AI first. The one-time download is about 450 MB."]))); return }
            executable = Self.python
            let model = ["skymask": "sky", "depth": "depth", "upscale": "detail", "rawdenoise": "denoise"][tool] ?? tool
            if !Self.hasModel(model) {
                completion(.failure(NSError(domain: "OpenStill", code: 1, userInfo: [NSLocalizedDescriptionKey: "This tool needs a model added in this version of OpenStill. Choose Set up on-device AI again to download it."]))); return
            }
        }
        let task = Process(); task.executableURL = executable; task.arguments = [Self.script.path, tool] + arguments
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        let log = AILog()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let line = String(decoding: data, as: UTF8.self)
            log.append(line)
            if let last = line.split(separator: "\n").last {
                DispatchQueue.main.async { status(String(last.suffix(220))) }
            }
        }
        task.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.process = nil
                if finished.terminationStatus == 0 { completion(.success(())) }
                else {
                    let detail = finished.terminationReason == .uncaughtSignal ? "Processing cancelled. Your previous edit is unchanged." : String(log.text.suffix(1400))
                    completion(.failure(NSError(domain: "OpenStillAI", code: Int(finished.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "On-device AI processing failed." : detail])))
                }
            }
        }
        do { try task.run(); process = task }
        catch { pipe.fileHandleForReading.readabilityHandler = nil; completion(.failure(error)) }
    }
}
private final class AILog {
    private var storage = ""; private let lock = NSLock()
    func append(_ text: String) { lock.lock(); storage = String((storage+text).suffix(8000)); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return storage }
}

extension LocalAI {
    /// TEMPORARY for CI (see `stub`).
    static func runStub(tool: String, arguments: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
        DispatchQueue.global().async {
            let result = Result<Void, Error> {
                guard let input = value("--input"), let output = value("--output") else { throw CocoaError(.fileNoSuchFile) }
                var data = try Data(contentsOf: URL(fileURLWithPath: input))
                if tool == "erase", let maskPath = value("--mask"), data.count > 12,
                   let mask = CGImageSourceCreateWithURL(URL(fileURLWithPath: maskPath) as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) {
                    let w = Int(data[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }), h = Int(data[8..<12].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                    var gray = [UInt8](repeating: 0, count: w * h)
                    let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                    ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
                    data.withUnsafeMutableBytes { raw in
                        let floats = raw.baseAddress!.advanced(by: 12).assumingMemoryBound(to: Float.self)
                        for i in 0..<(w * h) where gray[i] > 127 { floats[i * 4] = 0.5; floats[i * 4 + 1] = 0.5; floats[i * 4 + 2] = 0.5 }
                    }
                }
                try data.write(to: URL(fileURLWithPath: output))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
