import AppKit
import OpenStillCore

final class LocalAI {
    private var process: Process?
    var isRunning: Bool { process != nil }
    static var root: URL { EditStorage.root.appendingPathComponent("AI") }
    static var python: URL { root.appendingPathComponent("runtime/bin/python3") }
    static var ready: Bool { FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: root.appendingPathComponent("ready.json").path) }
    static var script: URL {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("AI/engine.py"), FileManager.default.fileExists(atPath: resource.path) { return resource }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AI/engine.py")
    }
    func cancel() { process?.terminate() }
    func run(tool: String, arguments: [String] = [], status: @escaping (String) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        guard process == nil else { return }
        let executable: URL
        if tool == "setup" {
            let candidates = ["/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.11", "/usr/local/bin/python3.12", "/usr/local/bin/python3.11", "/usr/bin/python3"]
            guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                completion(.failure(NSError(domain: "OpenStill", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install Python 3.10–3.12, then choose Set up local AI tools again."]))); return
            }
            executable = URL(fileURLWithPath: path)
        } else {
            guard Self.ready else { completion(.failure(NSError(domain: "OpenStill", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose Set up local AI tools first. The one-time download is about 350 MB."]))); return }
            executable = Self.python
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
                    completion(.failure(NSError(domain: "OpenStillAI", code: Int(finished.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "Local AI processing failed." : detail])))
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
