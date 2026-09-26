import AppKit
import UniformTypeIdentifiers
import OpenStillCore

/// File → Import Lightroom Catalog…: reads an .lrcat read-only and brings ratings, labels, picks, keywords,
/// collections and develop settings into OpenStill. Photos stay where they are; moved drives can be relinked.
final class LightroomImportWindow: NSWindowController, NSWindowDelegate {
    var completed: (() -> Void)?
    private var catalog: LightroomCatalog?
    private var relink: [String: String] = [:]
    private let summary = NSTextField(wrappingLabelWithString: "Choose a Lightroom Classic catalog (.lrcat). It is only read; Lightroom’s copy isn’t changed.")
    private let roots = NSStackView()
    private let ratings = NSButton(checkboxWithTitle: "Ratings, picks and color labels", target: nil, action: nil)
    private let metadata = NSButton(checkboxWithTitle: "Keywords, title, caption and other metadata", target: nil, action: nil)
    private let collections = NSButton(checkboxWithTitle: "Collections (smart collections are skipped)", target: nil, action: nil)
    private let develop = NSButton(checkboxWithTitle: "Develop settings, as a version named “Lightroom”", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let chooseButton = NSButton(title: "Choose Catalog…", target: nil, action: nil)
    private let report = NSTextView()
    private var running = false, cancelled = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Import Lightroom Catalog"; window.delegate = self; window.isReleasedWhenClosed = false; window.center(); Appearance.configure(window)
        let root = Appearance.panel(in: window)
        let title = NSTextField(labelWithString: "Import from Lightroom Classic"); title.font = .systemFont(ofSize: 15, weight: .semibold)
        summary.font = .systemFont(ofSize: 12)
        roots.orientation = .vertical; roots.alignment = .leading; roots.spacing = 6
        for box in [ratings, metadata, collections, develop] { box.state = .on }
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1; progress.isHidden = true
        chooseButton.target = self; chooseButton.action = #selector(choose); chooseButton.bezelStyle = .rounded
        importButton.target = self; importButton.action = #selector(runImport); importButton.bezelStyle = .rounded; importButton.keyEquivalent = "\r"; importButton.isEnabled = false
        let close = NSButton(title: "Close", target: self, action: #selector(closeOrCancel)); close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [chooseButton, NSView(), close, importButton]); buttons.spacing = 8
        report.isEditable = false; report.font = .systemFont(ofSize: 11); report.textContainerInset = NSSize(width: 6, height: 6); report.drawsBackground = false
        let scroll = NSScrollView(); scroll.documentView = report; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.drawsBackground = false
        report.autoresizingMask = [.width]; report.isVerticallyResizable = true
        let note = NSTextField(wrappingLabelWithString: "Develop settings are translated to OpenStill’s own tools, so photos look close to Lightroom but not identical. Anything that can’t be carried over (masks, spot removal, profiles…) is listed after importing. Virtual copies aren’t imported.")
        note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, summary, roots, ratings, metadata, collections, develop, note, progress, scroll, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.setCustomSpacing(14, after: roots); stack.setCustomSpacing(12, after: note)
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor), note.widthAnchor.constraint(equalTo: stack.widthAnchor), roots.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a Lightroom Classic catalog (.lrcat)"
        if let type = UTType(filenameExtension: "lrcat") { panel.allowedContentTypes = [type] }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.load(url)
        }
    }
    private func load(_ url: URL) {
        summary.stringValue = "Reading \(url.lastPathComponent)…"; importButton.isEnabled = false; relink = [:]; show("")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try LightroomCatalog(url: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let catalog):
                    self.catalog = catalog
                    self.summary.stringValue = "\(url.lastPathComponent): \(catalog.photos.count) photos, \(catalog.collections.count) collections."
                    self.importButton.isEnabled = !catalog.photos.isEmpty
                    self.rebuildRoots()
                case .failure(let error):
                    self.catalog = nil; self.summary.stringValue = error.localizedDescription; self.rebuildRoots()
                }
            }
        }
    }
    private var options: LightroomImport {
        var o = LightroomImport()
        o.ratings = ratings.state == .on; o.keywordsAndMetadata = metadata.state == .on; o.collections = collections.state == .on; o.developSettings = develop.state == .on
        o.relink = relink.map { (from: $0.key, to: $0.value) }.sorted { $0.from.count > $1.from.count }
        return o
    }
    /// One row per top-level folder, showing how many photos are missing there and offering Relink.
    private func rebuildRoots() {
        roots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let catalog else { return }
        let resolver = options
        for root in catalog.roots {
            let inRoot = catalog.photos.filter { $0.path.hasPrefix(root) }
            let missing = inRoot.filter { !FileManager.default.fileExists(atPath: resolver.resolvedPath($0.path)) }.count
            let target = relink[root].map { " → \($0)" } ?? ""
            let label = NSTextField(labelWithString: "\(root)\(target)  ·  \(inRoot.count) photos" + (missing > 0 ? ", \(missing) not found" : ""))
            label.font = .systemFont(ofSize: 11); label.textColor = missing > 0 ? .systemOrange : .secondaryLabelColor; label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let button = NSButton(title: "Relink…", target: self, action: #selector(relinkRoot(_:))); button.bezelStyle = .rounded; button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier(root); button.isHidden = missing == 0 && relink[root] == nil
            button.setAccessibilityLabel("Relink photos from \(root)")
            let row = NSStackView(views: [label, NSView(), button]); row.spacing = 6
            roots.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: roots.widthAnchor).isActive = true
        }
    }
    @objc private func relinkRoot(_ sender: NSButton) {
        guard let root = sender.identifier?.rawValue, let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the folder that now holds what was in \(root)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.relink[root] = url.standardizedFileURL.path + "/"; self.rebuildRoots()
        }
    }
    @objc private func runImport() {
        guard let catalog, !running else { return }
        running = true; cancelled = false; importButton.isEnabled = false; chooseButton.isEnabled = false; progress.isHidden = false; progress.doubleValue = 0
        show("Importing…")
        let options = self.options
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = options.run(catalog) { done, total in
                DispatchQueue.main.async { self?.progress.doubleValue = total == 0 ? 1 : Double(done) / Double(total) }
                return !(self?.cancelled ?? true)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false; self.chooseButton.isEnabled = true; self.importButton.isEnabled = true; self.progress.doubleValue = 1
                var text = result.summary
                if !result.missingPaths.isEmpty { text += "\n\nNot found:\n" + result.missingPaths.prefix(50).joined(separator: "\n") + (result.missing > 50 ? "\n…" : "") }
                self.show(text); self.rebuildRoots(); self.completed?()
            }
        }
    }
    private func show(_ text: String) { report.string = text }
    @objc private func closeOrCancel() { if running { cancelled = true } else { close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if running { cancelled = true; return false }; return true }
}
