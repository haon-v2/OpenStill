import AppKit
import OpenStillCore

/// Settings → AI Assistant: install the optional OpenStill MCP, connect it to an AI app, and choose what the AI may do.
final class AssistantSettings: NSViewController {
    private let installed = NSTextField(labelWithString: "")
    private let install = NSButton(title: "Install OpenStill MCP", target: nil, action: nil)
    private let uninstall = NSButton(title: "Uninstall", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let claudeDesktop = NSButton(title: "Connect to Claude Desktop", target: nil, action: nil)
    private let claudeCode = NSButton(title: "Copy command for Claude Code", target: nil, action: nil)
    private let allow = NSButton(checkboxWithTitle: "Allow AI assistants to edit in OpenStill", target: nil, action: nil)
    private let previewSize = NSPopUpButton()
    private let connected = NSTextField(labelWithString: "")
    private let recent = NSTextView()
    private var busy = false
    private static let sizes = [512, 768, 1024, 1536, 2048]

    init() { super.init(nibName: nil, bundle: nil); title = "AI Assistant" }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        func note(_ text: String) -> NSTextField { let l = NSTextField(wrappingLabelWithString: text); l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor; return l }
        func heading(_ text: String) -> NSTextField { let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 15, weight: .semibold); return l }
        for (button, action) in [(install, #selector(installMCP)), (uninstall, #selector(uninstallMCP)), (claudeDesktop, #selector(toggleClaudeDesktop)), (claudeCode, #selector(copyClaudeCode))] {
            button.bezelStyle = .rounded; button.target = self; button.action = action
        }
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        installed.font = .systemFont(ofSize: 12); status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        allow.target = self; allow.action = #selector(toggleAllow)
        previewSize.addItems(withTitles: Self.sizes.map { "\($0) px" }); previewSize.target = self; previewSize.action = #selector(choosePreviewSize)
        previewSize.setAccessibilityLabel("Largest preview the AI may see")
        connected.font = .systemFont(ofSize: 11)
        recent.isEditable = false; recent.font = .monospacedSystemFont(ofSize: 10, weight: .regular); recent.textColor = .secondaryLabelColor; recent.drawsBackground = false
        let scroll = NSScrollView(); scroll.documentView = recent; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        recent.minSize = NSSize(width: 0, height: 110); recent.isVerticallyResizable = true; recent.autoresizingMask = [.width]

        let intro = note("The OpenStill MCP lets an AI app such as Claude edit your photos in OpenStill: find photos, look at previews, move sliders, add masks, rate and keyword, export, and find free LUTs. It’s an optional download from github.com/\(Assistant.repository) and isn’t installed until you choose to.")
        let installRow = NSStackView(views: [install, uninstall, progress]); installRow.spacing = 8
        let connectRow = NSStackView(views: [claudeDesktop, claudeCode]); connectRow.spacing = 8
        let connectNote = note("Claude Desktop: OpenStill adds itself to Claude’s settings (a backup is kept), then restart Claude. Claude Code: paste the copied command in Terminal. Other MCP apps can run the program in \(Assistant.mcpFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
        let sizeRow = NSStackView(views: [NSTextField(labelWithString: "Largest preview the AI may see:"), previewSize]); sizeRow.spacing = 8
        let privacy = note("OpenStill does the editing on this Mac, and only OpenStill saves your edits, so AI changes appear live, can be undone like any edit, and never clash with yours. Previews the AI looks at are sent to your AI app’s provider. Originals never leave your Mac. Masks, sky and other image AI stay on this Mac.")
        let samplingNote = note("When your AI app supports it, OpenStill’s logo designer can use your connected AI instead of the local model.")
        let stack = NSStackView(views: [heading("OpenStill MCP"), intro, installed, installRow, status,
                                        heading("Connect an AI app"), connectRow, connectNote,
                                        heading("Access"), allow, sizeRow, connected, privacy, samplingNote,
                                        heading("Recent AI actions"), scroll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.setCustomSpacing(20, after: status); stack.setCustomSpacing(20, after: connectNote); stack.setCustomSpacing(20, after: samplingNote)
        for label in [intro, status, connectNote, privacy, samplingNote] { label.widthAnchor.constraint(equalToConstant: 470).isActive = true }
        scroll.widthAnchor.constraint(equalToConstant: 470).isActive = true
        view = stack
        preferredContentSize = stack.fittingSize
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AssistantServer.changed, object: nil)
        refresh()
    }

    @objc func refresh() {
        guard isViewLoaded else { return }
        let version = MCPInstall.installedVersion
        installed.stringValue = version.map { "Installed · version \($0)" } ?? "Not installed"
        install.title = version == nil ? "Install OpenStill MCP" : "Check for Update"
        install.isEnabled = !busy; uninstall.isEnabled = !busy && version != nil
        let config = try? Data(contentsOf: MCPInstall.claudeDesktopConfig)
        claudeDesktop.title = MCPInstall.isConnectedToClaudeDesktop(config) ? "Disconnect from Claude Desktop" : "Connect to Claude Desktop"
        claudeDesktop.isEnabled = version != nil || MCPInstall.isConnectedToClaudeDesktop(config)
        claudeCode.isEnabled = version != nil
        allow.state = UserDefaults.standard.bool(forKey: Assistant.allowKey) ? .on : .off
        let size = Assistant.previewSize(UserDefaults.standard.object(forKey: Assistant.previewKey) as? Int)
        previewSize.selectItem(at: Self.sizes.firstIndex(of: size) ?? 2)
        let server = AssistantServer.shared
        connected.stringValue = !server.isRunning ? "AI assistants can’t edit right now." :
            server.clients.isEmpty ? "Waiting for an AI app to connect." :
            "Connected: " + server.clients.map { $0.name + ($0.supportsSampling ? " (can also answer OpenStill’s AI requests)" : "") }.joined(separator: ", ")
        let formatter = DateFormatter(); formatter.dateStyle = .none; formatter.timeStyle = .short
        recent.string = server.recent.isEmpty ? "Nothing yet." : server.recent.map { formatter.string(from: $0.date) + "  " + $0.text }.joined(separator: "\n")
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
