import AppKit
import Darwin
import OpenStillCore

/// Listens for the OpenStill MCP on a local socket, only while Settings → AI Assistant → "Allow AI assistants to edit" is on.
/// OpenStill stays the only process that saves edits: every request runs here, on the main thread, through the same code as the app's own controls.
final class AssistantServer {
    static let shared = AssistantServer()
    static let changed = Notification.Name("OpenStillAssistantChanged")
    /// Runs a tool on the main thread and replies once.
    var handler: ((_ tool: String, _ arguments: [String: JSONValue], _ reply: @escaping (Result<JSONValue, Error>) -> Void) -> Void)?
    /// Connected AI apps (main thread).
    private(set) var clients: [AssistantClient] = []
    /// The latest requests, newest first, for Settings (main thread).
    private(set) var recent: [(date: Date, text: String)] = []
    private(set) var isRunning = false
    var samplingClient: AssistantClient? { clients.first { $0.supportsSampling } }

    private let queue = DispatchQueue(label: "OpenStill.assistant")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    private var pendingSamples: [String: (Result<JSONValue, Error>) -> Void] = [:]

    private final class Connection {
        let fd: Int32
        var source: DispatchSourceRead?
        var framing = AssistantFraming()
        var client: AssistantClient?
        init(fd: Int32) { self.fd = fd }
    }

    /// Starts or stops listening to match the setting.
    func applySetting() {
        if UserDefaults.standard.bool(forKey: Assistant.allowKey) {
            do { try start() } catch { log("Couldn’t start: " + error.localizedDescription) }
        } else { stop() }
    }

    func start() throws {
        guard !isRunning else { return }
        let path = Assistant.socketURL.path
        try FileManager.default.createDirectory(at: Assistant.folder, withIntermediateDirectories: true)
        if Self.someoneListens(at: path) { throw AssistantError.message("Another copy of OpenStill is already accepting AI requests.") }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AssistantError.message("Couldn’t open a local socket.") }
        var address = try Self.address(path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else { close(fd); unlink(path); throw AssistantError.message("Couldn’t listen for the OpenStill MCP.") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume(); acceptSource = source
        isRunning = true
        log("Listening for AI assistants.")
    }

    func stop() {
        guard isRunning else { return }
        queue.sync {
            for connection in connections.values { connection.source?.cancel(); close(connection.fd) }
            connections.removeAll()
            let failed = pendingSamples; pendingSamples.removeAll()
            DispatchQueue.main.async { failed.values.forEach { $0(.failure(AssistantError.message("AI assistants were turned off."))) } }
        }
        acceptSource?.cancel(); acceptSource = nil
        if listener >= 0 { close(listener); listener = -1 }
        unlink(Assistant.socketURL.path)
        isRunning = false; clients = []
        log("Stopped listening.")
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Asks the connected AI app to answer (MCP sampling), e.g. to design logos. Fails when no connected app supports it.
    func sample(_ request: JSONValue, timeout: TimeInterval = 180, completion: @escaping (Result<JSONValue, Error>) -> Void) {
        let id = UUID().uuidString
        queue.async { [weak self] in
            guard let self, let connection = self.connections.values.first(where: { $0.client?.supportsSampling == true }) else {
                DispatchQueue.main.async { completion(.failure(AssistantError.message("No connected AI app can answer requests from OpenStill."))) }
                return
            }
            self.pendingSamples[id] = completion
            self.send(AssistantMessage(type: "sample", id: id, arguments: request), on: connection)
            self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let waiting = self?.pendingSamples.removeValue(forKey: id) else { return }
                DispatchQueue.main.async { waiting(.failure(AssistantError.message("Your AI app didn’t answer in time."))) }
            }
        }
    }

    // MARK: Connections (on `queue`)
    private func acceptOne() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        // Only this Mac user's own processes may connect.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let connection = Connection(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak connection] in if let connection { self?.readable(connection) } }
        source.resume(); connection.source = source
        connections[fd] = connection
    }
    private func readable(_ connection: Connection) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(connection.fd, &buffer, buffer.count)
        guard count > 0 else { drop(connection); return }
        do {
            for message in try connection.framing.append(Data(buffer[0..<count])) { handle(message, from: connection) }
        } catch {
            send(.failure(to: nil, error.localizedDescription), on: connection); drop(connection)
        }
    }
    private func handle(_ message: AssistantMessage, from connection: Connection) {
        switch message.type {
        case "hello":
            do {
                let client = try Assistant.accept(message)
                connection.client = client
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                send(AssistantMessage(type: "welcome", id: message.id, version: Assistant.protocolVersion,
                                      result: .object(["app": .string("OpenStill"), "version": .string(version), "sliders": AssistantAdjustments.catalog])), on: connection)
                publishClients()
                DispatchQueue.main.async { self.log("Connected: \(client.name)" + (client.supportsSampling ? " (can answer OpenStill’s AI requests)" : "")) }
            } catch {
                send(.failure(to: message.id, error.localizedDescription), on: connection); drop(connection)
            }
        case "request":
            guard connection.client != nil else { send(.failure(to: message.id, "Say hello first."), on: connection); return }
            let tool = message.tool ?? "", arguments = message.arguments?.object ?? [:]
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.log(Self.summary(tool, arguments))
                guard let handler = self.handler else { self.reply(message.id, .failure(AssistantError.message("OpenStill is still starting.")), on: connection); return }
                handler(tool, arguments) { [weak self] result in self?.reply(message.id, result, on: connection) }
            }
        case "sampleResult":
            guard let id = message.id, let completion = pendingSamples.removeValue(forKey: id) else { return }
            let result: Result<JSONValue, Error> = message.error.map { .failure(AssistantError.message($0)) } ?? .success(message.result ?? .null)
            DispatchQueue.main.async { completion(result) }
        default:
            send(.failure(to: message.id, "Unknown message “\(message.type)”."), on: connection)
        }
    }
    private func reply(_ id: String?, _ result: Result<JSONValue, Error>, on connection: Connection) {
        queue.async { [weak self] in
            switch result {
            case .success(let value): self?.send(.response(to: id, value), on: connection)
            case .failure(let error): self?.send(.failure(to: id, error.localizedDescription), on: connection)
            }
        }
    }
    private func send(_ message: AssistantMessage, on connection: Connection) {
        guard connections[connection.fd] === connection, let data = try? message.line() else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(connection.fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && (errno == EAGAIN || errno == EINTR) { usleep(1000); continue }
                break
            }
        }
    }
    private func drop(_ connection: Connection) {
        guard connections.removeValue(forKey: connection.fd) != nil else { return }
        connection.source?.cancel(); close(connection.fd)
        if let name = connection.client?.name { DispatchQueue.main.async { self.log("Disconnected: \(name)") } }
        publishClients()
    }
    private func publishClients() {
        let list = connections.values.compactMap(\.client)
        DispatchQueue.main.async { self.clients = list; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    // MARK: Helpers
    private func log(_ text: String) {
        recent.insert((Date(), text), at: 0)
        if recent.count > 40 { recent.removeLast(recent.count - 40) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
    /// A short, readable line for the "Recent AI actions" list, without large values.
    static func summary(_ tool: String, _ arguments: [String: JSONValue]) -> String {
        let parts = arguments.keys.sorted().prefix(6).map { key -> String in
            switch arguments[key]! {
            case .number(let n): return "\(key) \((n * 100).rounded() / 100)"
            case .string(let s): return "\(key) “\(s.prefix(40))”"
            case .bool(let b): return "\(key) \(b)"
            case .object(let o): return "\(key) {" + o.keys.sorted().prefix(6).joined(separator: ", ") + "}"
            case .array(let a): return "\(key) [\(a.count)]"
            case .null: return key
            }
        }
        return tool.replacingOccurrences(of: "_", with: " ") + (parts.isEmpty ? "" : " · " + parts.joined(separator: ", "))
    }
    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw AssistantError.message("The socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        return address
    }
    /// True when a running OpenStill already answers on this socket (so a stale file can be replaced safely).
    private static func someoneListens(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path), var address = try? address(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        return result == 0
    }
}
