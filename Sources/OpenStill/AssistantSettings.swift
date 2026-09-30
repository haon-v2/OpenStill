import AppKit
import OpenStillCore

/// Settings → AI Assistant: install the optional OpenStill MCP, connect it to an AI app, and choose what the AI may do.
final class AssistantSettings: SettingsPage {
    private let installed = NSTextField(labelWithString: "")
    private lazy var install = button("Install", #selector(installMCP))
    private lazy var uninstall = button("Uninstall", #selector(uninstallMCP))
    private let progress = NSProgressIndicator()
    private let status = settingsNote("")
    private lazy var claudeDesktop = button("Connect", #selector(toggleClaudeDesktop))
    private lazy var claudeCode = button("Copy Command", #selector(copyClaudeCode))
    private lazy var allow = toggle(#selector(toggleAllow), label: "Allow AI assistants to edit in OpenStill")
    private let previewSize = NSPopUpButton()
    private let connected = NSTextField(labelWithString: "")
    private let recent = NSTextField(wrappingLabelWithString: "")
    private var busy = false
    private static let sizes = [512, 768, 1024, 1536, 2048]

    init() { super.init(title: SettingsSection.assistant.title) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        for f in [installed, connected] { f.font = .systemFont(ofSize: 12); f.textColor = Studio.secondary; f.lineBreakMode = .byTruncatingTail }
        connected.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        previewSize.addItems(withTitles: Self.sizes.map { "\($0) px" }); previewSize.target = self; previewSize.action = #selector(choosePreviewSize)
        previewSize.setAccessibilityLabel("Largest preview the AI may see")
        recent.font = .monospacedSystemFont(ofSize: 11, weight: .regular); recent.textColor = Studio.secondary
        group("OpenStill MCP", [row("OpenStill MCP", [progress, installed, install, uninstall],
                                    detail: "An optional download from github.com/\(Assistant.repository). It lets an AI app such as Claude edit your photos here.")])
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(6, after: last) }
        stack.addArrangedSubview(status); status.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        stack.setCustomSpacing(26, after: status)
        group("Connect an AI app", [
            row("Claude Desktop", [claudeDesktop], detail: "OpenStill adds itself to Claude's settings and keeps a backup. Restart Claude afterwards."),
            row("Claude Code", [claudeCode], detail: "Paste the copied command in Terminal."),
        ], note: "Other MCP apps can run the program in \(Assistant.mcpFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
        group("Access", [
            row("Allow AI assistants to edit", [allow], detail: "Off by default. OpenStill only listens for the MCP while this is on."),
            row("Largest preview", [previewSize], detail: "The biggest image the AI may look at."),
            row("Status", [connected]),
        ], note: "Only OpenStill saves your edits, so AI changes appear live, undo like any edit, and never clash with yours. Previews the AI looks at are sent to your AI app's provider; originals never leave your Mac. Masks, sky and other image AI stay on this Mac. When your AI app supports it, the logo designer can use it instead of the local model.")
        group("Recent AI actions", [recent])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AssistantServer.changed, object: nil)
    }

    @objc override func refresh() {
        guard isViewLoaded else { return }
        let version = MCPInstall.installedVersion
        installed.stringValue = version.map { "Version \($0)" } ?? "Not installed"
        install.title = version == nil ? "Install" : "Update"
        install.isEnabled = !busy; uninstall.isEnabled = !busy && version != nil
        let config = try? Data(contentsOf: MCPInstall.claudeDesktopConfig)
        claudeDesktop.title = MCPInstall.isConnectedToClaudeDesktop(config) ? "Disconnect" : "Connect"
        claudeDesktop.isEnabled = version != nil || MCPInstall.isConnectedToClaudeDesktop(config)
        claudeCode.isEnabled = version != nil
        allow.state = UserDefaults.standard.bool(forKey: Assistant.allowKey) ? .on : .off
        let size = Assistant.previewSize(UserDefaults.standard.object(forKey: Assistant.previewKey) as? Int)
        previewSize.selectItem(at: Self.sizes.firstIndex(of: size) ?? 2)
        let server = AssistantServer.shared
        connected.stringValue = !server.isRunning ? "Off" : server.clients.isEmpty ? "Waiting for an AI app" : "Connected: " + server.clients.map(\.name).joined(separator: ", ")
        connected.toolTip = server.clients.contains { $0.supportsSampling } ? "Your AI app can also answer OpenStill's own AI requests." : nil
        let formatter = DateFormatter(); formatter.dateStyle = .none; formatter.timeStyle = .short
        recent.stringValue = server.recent.isEmpty ? "Nothing yet." : server.recent.prefix(12).map { formatter.string(from: $0.date) + "  " + $0.text }.joined(separator: "\n")
    }

    @objc private func toggleAllow() {
        UserDefaults.standard.set(allow.state == .on, forKey: Assistant.allowKey)
        AssistantServer.shared.applySetting(); refresh()
    }
    @objc private func choosePreviewSize() {
        UserDefaults.standard.set(Self.sizes[max(0, previewSize.indexOfSelectedItem)], forKey: Assistant.previewKey)
    }
    @objc private func copyClaudeCode() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(MCPInstall.claudeCodeCommand, forType: .string)
        status.stringValue = "Copied. Paste it in Terminal to add OpenStill to Claude Code."
    }
    @objc private func toggleClaudeDesktop() {
        let url = MCPInstall.claudeDesktopConfig
        let existing = try? Data(contentsOf: url)
        let connecting = !MCPInstall.isConnectedToClaudeDesktop(existing)
        do {
            let next = connecting ? try MCPInstall.addingServer(to: existing, command: MCPInstall.executable.path) : try MCPInstall.removingServer(from: existing ?? Data("{}".utf8))
            let alert = NSAlert()
            alert.messageText = connecting ? "Add OpenStill to Claude Desktop?" : "Remove OpenStill from Claude Desktop?"
            alert.informativeText = (connecting ? "This entry is added to Claude Desktop’s settings. Everything else in the file stays as it is, and a backup is saved next to it.\n\n"
                                                : "Only OpenStill’s entry is removed; a backup is saved next to the file.\n\n")
                + "\"openstill\": { \"command\": \"\(MCPInstall.executable.path)\" }\n\nRestart Claude Desktop afterwards."
            alert.addButton(withTitle: connecting ? "Add" : "Remove"); alert.addButton(withTitle: "Cancel")
            guard let window = view.window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let existing { try existing.write(to: url.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.json.openstill-backup"), options: .atomic) }
                    try next.write(to: url, options: .atomic)
                    self?.status.stringValue = connecting ? "Added. Restart Claude Desktop, then turn on “Allow AI assistants to edit”." : "Removed from Claude Desktop."
                } catch { self?.status.stringValue = error.localizedDescription }
                self?.refresh()
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func uninstallMCP() {
        do { try MCPInstall.uninstall(); status.stringValue = "Uninstalled. You can also remove it from your AI app’s settings." } catch { status.stringValue = error.localizedDescription }
        refresh()
    }
    @objc private func installMCP() {
        busy = true; progress.startAnimation(nil); status.stringValue = "Checking github.com/\(Assistant.repository)…"; refresh()
        Self.fetch(MCPInstall.latestReleaseAPI) { [weak self] result in
            guard let self else { return }
            do {
                let release = try MCPInstall.release(from: try result.get())
                if release.version == MCPInstall.installedVersion { self.finish("OpenStill MCP \(release.version) is up to date."); return }
                self.status.stringValue = "Downloading OpenStill MCP \(release.version)…"
                Self.fetch(release.checksums) { sums in
                    Self.fetch(release.archive) { archive in
                        do {
                            let data = try archive.get()
                            try MCPInstall.verify(data, name: release.archiveName, sums: MCPInstall.checksums(String(decoding: try sums.get(), as: UTF8.self)))
                            try MCPInstall.install(archive: data, version: release.version)
                            self.finish("Installed OpenStill MCP \(release.version). Connect it to your AI app below.")
                        } catch { self.finish(error.localizedDescription) }
                    }
                }
            } catch { self.finish(error.localizedDescription) }
        }
    }
    private func finish(_ message: String) { busy = false; progress.stopAnimation(nil); status.stringValue = message; refresh() }
    private static func fetch(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("OpenStill", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Result<Data, Error> {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data, data.count < 100_000_000 else {
                    throw AssistantError.message("The download from GitHub failed. Try again later.")
                }
                return data
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
