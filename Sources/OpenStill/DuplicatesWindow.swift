import AppKit
import OpenStillCore

/// Library → Actions → Find duplicates…: exact copies and near-duplicates (bursts, re-exports) among the photos shown.
/// Nothing is deleted; extras can be flagged as rejects, which never removes files.
final class DuplicatesWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var changed: (() -> Void)?
    private let urls: [URL]
    private var groups: [DuplicateGroup] = []
    private var rows: [(group: Int, url: URL?)] = []
    private var records: [URL: PhotoRecord] = [:]
    private var running = false, cancelled = false
    private let mode = NSSegmentedControl(labels: ["Exact copies", "Similar photos"], trackingMode: .selectOne, target: nil, action: nil)
    private let sensitivity = NSSlider(value: 0.35, minValue: 0.15, maxValue: 0.7, target: nil, action: nil)
    private let sensitivityLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let find = NSButton(title: "Find", target: nil, action: nil)
    private let reject = NSButton(title: "Flag extras as rejects", target: nil, action: nil)

    init(urls: [URL]) {
        self.urls = urls
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Find Duplicates"; window.delegate = self; window.isReleasedWhenClosed = false; window.center(); Appearance.configure(window)
        let root = Appearance.panel(in: window)
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(modeChanged); mode.setAccessibilityLabel("What to find")
        sensitivity.target = self; sensitivity.action = #selector(sensitivityChanged); sensitivity.setAccessibilityLabel("How similar")
        let header = NSStackView(views: [mode, NSTextField(labelWithString: "Match"), sensitivity, sensitivityLabel]); header.spacing = 8
        sensitivity.widthAnchor.constraint(equalToConstant: 140).isActive = true
        for (id, title, width) in [("file", "Photo", 300.0), ("info", "", 200)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = true; table.doubleAction = #selector(reveal); table.target = self
        table.setAccessibilityLabel("Duplicate groups")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1; progress.isHidden = true
        find.target = self; find.action = #selector(run); find.bezelStyle = .rounded; find.keyEquivalent = "\r"
        reject.target = self; reject.action = #selector(flagExtras); reject.bezelStyle = .rounded; reject.isEnabled = false
        reject.toolTip = "In each group, keeps the highest-rated (then picked, then largest) photo and flags the others as rejects. Files are never deleted."
        let revealButton = NSButton(title: "Show in Finder", target: self, action: #selector(reveal)); revealButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [revealButton, NSView(), progress, reject, find]); buttons.spacing = 8
        let stack = NSStackView(views: [header, scroll, status, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            progress.widthAnchor.constraint(equalToConstant: 140)
        ])
        modeChanged()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func modeChanged() {
        let similar = mode.selectedSegment == 1
        sensitivity.isEnabled = similar; sensitivityChanged()
        status.stringValue = similar ? "Compares how \(urls.count) photos look (bursts, small edits, re-exports). Runs on this Mac and can take a while."
                                     : "Finds files among \(urls.count) photos whose contents are byte-for-byte identical."
    }
    @objc private func sensitivityChanged() {
        let v = sensitivity.doubleValue
        sensitivityLabel.stringValue = mode.selectedSegment == 0 ? "" : v < 0.3 ? "Nearly identical" : v < 0.45 ? "Bursts and edits" : "Loosely similar"
    }
    @objc private func run() {
        guard !running else { cancelled = true; return }
        running = true; cancelled = false; find.title = "Stop"; reject.isEnabled = false; progress.isHidden = false; progress.doubleValue = 0
        groups = []; rebuildRows()
        let similar = mode.selectedSegment == 1, threshold = Float(sensitivity.doubleValue), urls = self.urls
        status.stringValue = similar ? "Comparing photos…" : "Checking file contents…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = similar
                ? DuplicateFinder.similar(urls, threshold: threshold, progress: { done, total in DispatchQueue.main.async { self?.progress.doubleValue = total == 0 ? 1 : Double(done) / Double(total) } }, cancelled: { self?.cancelled ?? true })
                : DuplicateFinder.exact(urls, cancelled: { self?.cancelled ?? true })
            var records: [URL: PhotoRecord] = [:]
            for url in found.flatMap(\.urls) { records[url] = try? EditStorage.record(url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false; self.find.title = "Find"; self.progress.isHidden = true
                self.groups = found; self.records = records; self.rebuildRows()
                let extra = found.reduce(0) { $0 + $1.urls.count - 1 }
                self.status.stringValue = self.cancelled ? "Stopped." : found.isEmpty ? "No duplicates found." : "\(found.count) group\(found.count == 1 ? "" : "s"), \(extra) extra photo\(extra == 1 ? "" : "s"). Double-click to show in Finder. ★ marks the one to keep."
                self.reject.isEnabled = !found.isEmpty
            }
        }
    }
    private func rebuildRows() {
        rows = []
        for (i, group) in groups.enumerated() { rows.append((i, nil)); rows += group.urls.map { (group: i, url: Optional($0)) } }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].url == nil }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row], group = groups[entry.group]
        guard let url = entry.url else {
            let text = group.kind == .exact ? "Identical copies (\(group.urls.count))" : "Similar photos (\(group.urls.count))"
            let label = NSTextField(labelWithString: text); label.font = .boldSystemFont(ofSize: 11); return label
        }
        let keep = DuplicateFinder.best(group, records: records) == url
        if tableColumn?.identifier.rawValue == "info" {
            let r = records[url]
            var parts: [String] = []
            if let r, r.rating > 0 { parts.append(String(repeating: "★", count: r.rating)) }
            if r?.flag == .pick { parts.append("Pick") } else if r?.flag == .reject { parts.append("Rejected") }
            parts.append(ByteCountFormatter.string(fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file))
            let label = NSTextField(labelWithString: parts.joined(separator: " · ")); label.textColor = .secondaryLabelColor; return label
        }
        let label = NSTextField(labelWithString: (keep ? "★ " : "    ") + (url.path as NSString).abbreviatingWithTildeInPath)
        label.lineBreakMode = .byTruncatingHead; label.toolTip = url.path
        return label
    }
    @objc private func reveal() {
        let chosen = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].url : nil }
        if !chosen.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(chosen) }
    }
    @objc private func flagExtras() {
        var flagged = 0, failed = 0
        for group in groups {
            let keep = DuplicateFinder.best(group, records: records)
            for url in group.urls where url != keep {
                guard let record = records[url] else { failed += 1; continue }
                if record.flag == .reject { continue }
                do { records[url] = try ShootWorkflow.mark(record.id, flag: .reject); flagged += 1 } catch { failed += 1 }
            }
        }
        table.reloadData(); changed?()
        status.stringValue = "Flagged \(flagged) photo\(flagged == 1 ? "" : "s") as rejected." + (failed > 0 ? " \(failed) couldn’t be flagged." : "") + " Filter by Rejects in the library to review them; files are never deleted."
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelled = true; return true }
}
