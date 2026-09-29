import AppKit
import OpenStillCore

/// Library view modes, as in Lightroom: Grid (G), Loupe (E), Compare (C) and Survey (N).
enum LibraryViewMode: Int, CaseIterable {
    case grid, loupe, compare, survey
    var title: String { ["Grid", "Loupe", "Compare", "Survey"][rawValue] }
}

/// Renders library photos at screen size, newest request first, keeping a few recent ones.
final class LibraryRenderer {
    private let queue = OperationQueue()
    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private let cache = NSCache<NSString, Box>()
    init() { queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .userInitiated; cache.countLimit = 12 }
    func cancel() { queue.cancelAllOperations() }
    func image(_ item: ShootItem, size: Int, done: @escaping (CGImage?) -> Void) {
        let key = "\(item.id)|\(item.record.active.revision)|\(item.record.activeVersionID)|\(size)" as NSString
        if let hit = cache.object(forKey: key) { done(hit.image); return }
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let image = try? autoreleasepool { try ModernRenderer.display(ModernRenderer.render(source: item.url, recipe: item.record.active.recipe, maximumDimension: size, keepSource: false)) }
            // The queue lets go of a finished operation, so read cancellation here rather than on the main thread.
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { if let image { self?.cache.setObject(Box(image), forKey: key) }; done(image) }
        }
        queue.addOperation(operation)
    }
}

/// One photo in Survey: click to make it the active photo, × to drop it from the survey.
private final class SurveyTile: NSView {
    let imageView = NSImageView(), name = NSTextField(labelWithString: ""), close = NSButton()
    var active = false { didSet { layer?.borderWidth = active ? 2 : 0 } }
    var chosen: (() -> Void)?, removed: (() -> Void)?
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 4; layer?.borderColor = NSColor.white.cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 10); name.textColor = LRColors.dim; name.lineBreakMode = .byTruncatingMiddle; name.alignment = .center
        close.bezelStyle = .circular; close.isBordered = false; close.image = Appearance.symbol("xmark.circle.fill", size: 14); close.target = self; close.action = #selector(remove)
        close.setAccessibilityLabel("Remove from survey")
        for v in [imageView, name, close] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 6), imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), imageView.bottomAnchor.constraint(equalTo: name.topAnchor, constant: -4),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            name.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 4), close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func remove() { removed?() }
    override func mouseDown(with event: NSEvent) { chosen?() }
}

/// Loupe, Compare and Survey inside the Library, in place of the grid.
final class LibraryStage: NSView {
    var mode = LibraryViewMode.loupe
    /// Keys the stage doesn't use go to the grid (ratings, flags, labels, view modes).
    var keyHandler: ((NSEvent) -> Void)?
    /// Left and right arrows: the previous or next photo.
    var step: ((Int) -> Void)?
    var remove: ((UUID) -> Void)?
    var activate: ((UUID) -> Void)?
    var swapCompare: (() -> Void)?
    private let renderer = LibraryRenderer()
    private let canvases = [PhotoCanvas(), PhotoCanvas()]
    private let titles = [NSTextField(labelWithString: ""), NSTextField(labelWithString: "")]
    private let compareRow = NSStackView(), surveyGrid = NSView(), swapButton = NSButton(title: "Swap", target: nil, action: nil)
    private var tiles: [SurveyTile] = []
    private var shown: [UUID] = []
    private var token = UUID()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = LRColors.canvas.cgColor
        for (i, canvas) in canvases.enumerated() {
            canvas.appearance = NSAppearance(named: .darkAqua)
            canvas.viewportChanged = { [weak self] in guard let self, self.mode == .compare else { return }; self.canvases[1 - i].setViewport(self.canvases[i].viewport) }
            canvas.toggleZoom = { [weak canvas] in guard let canvas else { return }; canvas.native = !canvas.native }
            titles[i].font = .systemFont(ofSize: 11, weight: .medium); titles[i].textColor = LRColors.text
        }
        swapButton.bezelStyle = .rounded; swapButton.controlSize = .small; swapButton.target = self; swapButton.action = #selector(swap)
        let columns = (0..<2).map { i -> NSStackView in
            let c = NSStackView(views: [titles[i], canvases[i]]); c.orientation = .vertical; c.alignment = .centerX; c.spacing = 6
            canvases[i].widthAnchor.constraint(equalTo: c.widthAnchor).isActive = true
            return c
        }
        compareRow.setViews(columns, in: .leading); compareRow.distribution = .fillEqually; compareRow.spacing = 8
        let host = NSStackView(views: [compareRow, swapButton]); host.orientation = .vertical; host.spacing = 8
        compareRow.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true
        for v in [host, surveyGrid] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                                         v.topAnchor.constraint(equalTo: topAnchor, constant: 10), v.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)])
        }
        setAccessibilityLabel("Library photo view")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch Shortcuts.combo(from: event)?.key {
        case "left" where !event.modifierFlags.contains(.command): step?(-1)
        case "right" where !event.modifierFlags.contains(.command): step?(1)
        default: keyHandler?(event)
        }
    }
    @objc private func swap() { swapCompare?() }
    /// Loupe shows the first photo; Compare the first two (select, candidate); Survey all of them, with `active` highlighted.
    func show(_ items: [ShootItem], mode: LibraryViewMode, active: UUID?) {
        self.mode = mode
        let wanted = items.map(\.id)
        let changed = wanted != shown
        shown = wanted
        let compare = mode == .compare, survey = mode == .survey
        compareRow.superview?.isHidden = survey; surveyGrid.isHidden = !survey
        swapButton.isHidden = !compare; canvases[1].superview?.isHidden = !compare
        titles.forEach { $0.isHidden = !compare }
        if survey { layoutSurvey(items, active: active, reload: changed); return }
        guard changed else { return }
        renderer.cancel(); let t = UUID(); token = t
        for i in 0..<(compare ? 2 : 1) {
            let canvas = canvases[i]
            guard items.indices.contains(i) else { canvas.image = nil; canvas.message = compare ? "Select two photos to compare." : "Select a photo."; titles[i].stringValue = ""; continue }
            let item = items[i]
            titles[i].stringValue = (i == 0 ? "Select: " : "Candidate: ") + item.url.lastPathComponent
            canvas.message = "Loading…"
            renderer.image(item, size: 2400) { [weak self, weak canvas] image in
                guard let self, self.token == t, let canvas else { return }
                let state = compare ? self.canvases[1 - i].viewport : nil
                canvas.image = image; canvas.message = image == nil ? "Couldn’t show this photo." : ""
                if let state, i == 1 { canvas.setViewport(state) }
            }
        }
        if !compare { canvases[1].image = nil }
    }
    private func layoutSurvey(_ items: [ShootItem], active: UUID?, reload: Bool) {
        if reload {
            tiles.forEach { $0.removeFromSuperview() }; tiles = []
            renderer.cancel(); let t = UUID(); token = t
            for item in items {
                let tile = SurveyTile(); tile.name.stringValue = item.url.lastPathComponent
                tile.chosen = { [weak self] in self?.activate?(item.id) }
                tile.removed = { [weak self] in self?.remove?(item.id) }
                surveyGrid.addSubview(tile); tiles.append(tile)
                renderer.image(item, size: 1200) { [weak self, weak tile] image in
                    guard self?.token == t, let tile else { return }
                    tile.imageView.image = image.map { NSImage(cgImage: $0, size: .zero) }
                }
            }
        }
        for (tile, item) in zip(tiles, items) { tile.active = item.id == active }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard mode == .survey, !tiles.isEmpty else { return }
        // The most columns that keep tiles as large as possible.
        let area = surveyGrid.bounds, n = tiles.count
        var best = (columns: 1, size: CGSize.zero)
        for columns in 1...n {
            let rows = Int(ceil(Double(n) / Double(columns)))
            let size = CGSize(width: area.width / CGFloat(columns), height: area.height / CGFloat(rows))
            if min(size.width, size.height * 1.3) > min(best.size.width, best.size.height * 1.3) { best = (columns, size) }
        }
        for (i, tile) in tiles.enumerated() {
            let row = i / best.columns, column = i % best.columns
            tile.frame = CGRect(x: CGFloat(column) * best.size.width, y: area.height - CGFloat(row + 1) * best.size.height, width: best.size.width, height: best.size.height).insetBy(dx: 4, dy: 4)
        }
    }
    func stop() { renderer.cancel(); shown = [] }
}

/// Library › Quick Develop: nudge the selected photos' settings up or down, as one undoable batch.
final class QuickDevelopPanel: NSStackView {
    var command: ((String) -> Void)?
    private var buttons: [NSButton] = []
    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        let wb = NSPopUpButton(frame: .zero, pullsDown: true); wb.controlSize = .small; wb.font = .systemFont(ofSize: 11)
        wb.addItem(withTitle: "White Balance")
        for preset in WhiteBalancePreset.allCases { let item = NSMenuItem(title: preset.title, action: #selector(chooseWB(_:)), keyEquivalent: ""); item.target = self; item.representedObject = preset.rawValue; wb.menu?.addItem(item) }
        wb.setAccessibilityLabel("Quick Develop white balance"); buttons.append(wb)
        addRow("", [wb])
        // Each row: large down, small down, small up, large up.
        let rows: [(String, String, Double, Double)] = [
            ("Temperature", "temperature", 250, 1000), ("Tint", "tint", 5, 20), ("Exposure", "exposure", 1.0 / 3, 1), ("Contrast", "contrast", 0.05, 0.2),
            ("Highlights", "highlights", 0.05, 0.2), ("Shadows", "shadows", 0.05, 0.2), ("Whites", "whites", 0.05, 0.2), ("Blacks", "blacks", 0.05, 0.2),
            ("Clarity", "clarity", 0.05, 0.2), ("Vibrance", "vibrance", 0.05, 0.2),
        ]
        for (title, key, small, large) in rows {
            let steps: [(String, Double)] = [("◀◀", -large), ("◀", -small), ("▶", small), ("▶▶", large)]
            let row = steps.map { symbol, amount -> NSButton in
                let b = LRButton(symbol) { [weak self] in self?.command?("lib:qd:\(key):\(amount)") }
                b.setAccessibilityLabel("\(title) \(amount > 0 ? "up" : "down")\(abs(amount) == large ? " a lot" : "")"); b.widthAnchor.constraint(equalToConstant: 34).isActive = true
                buttons.append(b); return b
            }
            addRow(title, row)
        }
        let auto = LRButton("Auto Tone") { [weak self] in self?.command?("lib:qd:auto") }, reset = LRButton("Reset All") { [weak self] in self?.command?("lib:qd:reset") }
        buttons += [auto, reset]
        addRow("", [auto, reset])
        let note = NSTextField(wrappingLabelWithString: "Changes every selected photo. Actions → Undo batch reverses it."); note.font = .systemFont(ofSize: 10); note.textColor = LRColors.dim
        addArrangedSubview(note); note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        setEnabled(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    private func addRow(_ title: String, _ controls: [NSView]) {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 11); label.textColor = LRColors.text; label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let row = NSStackView(views: [label] + controls); row.spacing = 3; addArrangedSubview(row)
    }
    @objc private func chooseWB(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String { command?("lib:qd:wb:" + raw) } }
    func setEnabled(_ on: Bool) { buttons.forEach { $0.isEnabled = on } }
}

/// Library › Keyword List: every keyword with its photo count. The checkbox adds or removes it on the selected photos; the arrow filters the library to it.
final class KeywordListPanel: NSStackView, NSSearchFieldDelegate {
    var command: ((String) -> Void)?
    private let search = NSSearchField(), rows = NSStackView(), scroll = NSScrollView()
    private var tree: [KeywordNode] = []
    private var states: [String: NSControl.StateValue] = [:]
    private var enabled = false
    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        search.placeholderString = "Filter keywords"; search.controlSize = .small; search.delegate = self; search.setAccessibilityLabel("Filter keywords")
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 2
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(rows)
        NSLayoutConstraint.activate([rows.topAnchor.constraint(equalTo: document.topAnchor), rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                                     rows.trailingAnchor.constraint(equalTo: document.trailingAnchor), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)])
        scroll.documentView = document; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        for v in [search, scroll] as [NSView] { addArrangedSubview(v); v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    /// `states`: for each keyword path, whether all, some or none of the selected photos carry it.
    func update(counts: [(String, Int)], states: [String: NSControl.StateValue], enabled: Bool) {
        tree = KeywordTree.build(counts); self.states = states; self.enabled = enabled; rebuild()
    }
    func controlTextDidChange(_ obj: Notification) { rebuild() }
    private func rebuild() {
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        let list = KeywordTree.rows(tree, filter: search.stringValue)
        if list.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: tree.isEmpty ? "No keywords yet. Add some in Keywording." : "No keywords match."); empty.font = .systemFont(ofSize: 10); empty.textColor = LRColors.dim
            rows.addArrangedSubview(empty); return
        }
        for (node, depth) in list.prefix(400) {
            let check = NSButton(checkboxWithTitle: node.name, target: self, action: #selector(toggle(_:)))
            check.allowsMixedState = true; check.state = states[node.path] ?? .off; check.isEnabled = enabled; check.font = .systemFont(ofSize: 11)
            check.identifier = NSUserInterfaceItemIdentifier(node.path); check.setAccessibilityLabel("Keyword \(node.path)")
            let count = NSTextField(labelWithString: "\(node.count)"); count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); count.textColor = LRColors.dim
            let show = NSButton(title: "›", target: self, action: #selector(filter(_:))); show.isBordered = false; show.identifier = check.identifier
            show.toolTip = "Show the photos with this keyword"; show.setAccessibilityLabel("Show photos with \(node.path)")
            let indent = NSView(); indent.widthAnchor.constraint(equalToConstant: CGFloat(depth) * 14).isActive = true
            let row = NSStackView(views: [indent, check, NSView(), count, show]); row.spacing = 4
            rows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }
    @objc private func toggle(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        // Mixed or off adds to every selected photo; on removes.
        command?((states[path] == .on ? "lib:keyword:remove:" : "lib:keyword:add:") + path)
    }
    @objc private func filter(_ sender: NSButton) { if let path = sender.identifier?.rawValue { command?("lib:keyword:filter:" + path) } }
}
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Library › Keywording: type keywords, or click one of a Keyword Set's nine (⌥1–⌥9) or a suggestion.
final class KeywordSetPanel: NSStackView, NSTextFieldDelegate {
    var command: ((String) -> Void)?
    private let entry = NSTextField(), setPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let setGrid = NSGridView(), suggestionGrid = NSGridView(), suggestionTitle = NSTextField(labelWithString: "Keyword Suggestions")
    private var sets: [KeywordSet] = []
    private(set) var current: [String] = []
    private var applied = Set<String>()
    private var enabled = false
    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        entry.placeholderString = "Add keywords, separated by commas"; entry.controlSize = .small; entry.font = .systemFont(ofSize: 11); entry.delegate = self
        entry.target = self; entry.action = #selector(addTyped); entry.setAccessibilityLabel("Add keywords to the selected photos")
        setPicker.controlSize = .small; setPicker.font = .systemFont(ofSize: 11); setPicker.target = self; setPicker.action = #selector(pickSet); setPicker.setAccessibilityLabel("Keyword set")
        suggestionTitle.font = .systemFont(ofSize: 11, weight: .medium); suggestionTitle.textColor = LRColors.dim
        let setTitle = NSTextField(labelWithString: "Keyword Set"); setTitle.font = .systemFont(ofSize: 11, weight: .medium); setTitle.textColor = LRColors.dim
        for v in [entry, suggestionTitle, suggestionGrid, setTitle, setPicker, setGrid] as [NSView] { addArrangedSubview(v); v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        for g in [setGrid, suggestionGrid] { g.rowSpacing = 3; g.columnSpacing = 3 }
        reloadSets()
    }
    required init?(coder: NSCoder) { fatalError() }
    func reloadSets() {
        sets = KeywordSets.all(); let chosen = setPicker.indexOfSelectedItem
        setPicker.removeAllItems(); setPicker.addItems(withTitles: sets.map(\.name))
        setPicker.selectItem(at: chosen >= 0 && chosen < sets.count ? chosen : 0)
        pickSet()
    }
    /// The selected photos' keywords (for highlighting) and the suggestions for them.
    func update(applied: Set<String>, suggestions: [String], enabled: Bool) {
        self.applied = Set(applied.map { $0.lowercased() }); self.enabled = enabled; entry.isEnabled = enabled
        fill(suggestionGrid, suggestions, numbered: false)
        suggestionTitle.isHidden = suggestions.isEmpty; suggestionGrid.isHidden = suggestions.isEmpty
        if setPicker.indexOfSelectedItem == 0 { sets[0] = KeywordSet(name: "Recent Keywords", keywords: KeywordSets.recent()) }
        pickSet()
    }
    @objc private func pickSet() {
        let i = max(0, setPicker.indexOfSelectedItem)
        current = sets.indices.contains(i) ? sets[i].keywords : []
        fill(setGrid, current, numbered: true)
    }
    private func fill(_ grid: NSGridView, _ words: [String], numbered: Bool) {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        var row: [NSView] = []
        for (i, word) in words.prefix(9).enumerated() {
            let leaf = word.components(separatedBy: " > ").last ?? word
            let b = LRButton(leaf) { [weak self] in self?.command?("lib:keyword:toggle:" + word) }
            b.state = applied.contains(word.lowercased()) ? .on : .off; b.setButtonType(.pushOnPushOff); b.isEnabled = enabled
            b.toolTip = numbered ? "\(word) · ⌥\(i + 1)" : word; b.setAccessibilityLabel((applied.contains(word.lowercased()) ? "Remove keyword " : "Add keyword ") + word)
            row.append(b)
            if row.count == 3 { grid.addRow(with: row); row = [] }
        }
        if !row.isEmpty { while row.count < 3 { row.append(NSView()) }; grid.addRow(with: row) }
        for c in 0..<grid.numberOfColumns { grid.column(at: c).width = 70 }
    }
    @objc private func addTyped() {
        let words = IPTCMetadata.parseKeywords(entry.stringValue); guard !words.isEmpty else { return }
        entry.stringValue = ""
        for w in words { command?("lib:keyword:add:" + w) }
    }
    /// ⌥1–⌥9.
    func applySetKeyword(_ index: Int) { if current.indices.contains(index) { command?("lib:keyword:toggle:" + current[index]) } }
}

/// Rename Photos (F2): a template, a start number and a preview of the first new names.
final class RenameAccessory: NSStackView, NSComboBoxDelegate, NSTextFieldDelegate {
    let template = NSComboBox(), start = NSTextField(string: "1"), preview = NSTextField(wrappingLabelWithString: "")
    private let items: [ShootItem]
    init(items: [ShootItem]) {
        self.items = items
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 150))
        orientation = .vertical; alignment = .leading; spacing = 8
        template.addItems(withObjectValues: BatchRename.templates); template.stringValue = "{date}_{name}"; template.delegate = self; template.completes = false
        template.setAccessibilityLabel("File name template")
        start.delegate = self; start.setAccessibilityLabel("Start number"); start.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let startRow = NSStackView(views: [NSTextField(labelWithString: "Start number for {index}:"), start]); startRow.spacing = 6
        let tokens = NSTextField(wrappingLabelWithString: "{name} {index} {date} {yyyy} {MM} {dd} {camera} {title}. The extension stays; XMP sidecars follow."); tokens.font = .systemFont(ofSize: 10); tokens.textColor = .secondaryLabelColor
        preview.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        for v in [template, startRow, tokens, preview] as [NSView] { addArrangedSubview(v) }
        for v in [template, tokens, preview] as [NSView] { v.widthAnchor.constraint(equalToConstant: 380).isActive = true }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    var startNumber: Int { max(0, Int(start.stringValue) ?? 1) }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func comboBoxSelectionDidChange(_ notification: Notification) { DispatchQueue.main.async { self.refresh() } }
    func refresh() {
        do {
            let names = try items.prefix(4).enumerated().map { i, item in item.url.lastPathComponent + " → " + (try BatchRename.name(item, template: template.stringValue, index: startNumber + i)) }
            preview.stringValue = names.joined(separator: "\n") + (items.count > 4 ? "\n… and \(items.count - 4) more" : ""); preview.textColor = .labelColor
        } catch { preview.stringValue = error.localizedDescription; preview.textColor = .systemRed }
    }
}

/// Watches the Auto Import folder while the app is open and imports what settles there.
final class AutoImportMonitor {
    var imported: (([URL], ImportReport) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var running = false, pending = false
    private var settings = AutoImportSettings()
    func start(_ settings: AutoImportSettings) {
        stop(); self.settings = settings
        guard settings.isReady, let watched = settings.watched else { return }
        let fd = open(watched.path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            s.setEventHandler { [weak self] in
                // Wait for the copy to finish before looking.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.check() }
            }
            s.setCancelHandler { close(fd) }; s.resume(); source = s
        }
        // A slow poll catches anything the folder events missed.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.check() }
        check()
    }
    func stop() { source?.cancel(); source = nil; timer?.invalidate(); timer = nil }
    func check() {
        guard settings.isReady else { return }
        if running { pending = true; return }
        running = true
        let settings = self.settings
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = AutoImport.run(settings)
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                if !report.imported.isEmpty || !report.failed.isEmpty { self.imported?(report.imported, report) }
                if self.pending { self.pending = false; self.check() }
            }
        }
    }
}

/// Reference View: a photo kept side by side with the one being edited, for matching a look.
final class ReferenceWindow: NSWindowController, NSWindowDelegate {
    private let canvas = PhotoCanvas()
    private let renderer = LibraryRenderer()
    private let name = NSTextField(labelWithString: "")
    var useCurrent: (() -> Void)?
    init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "Reference"; window.isFloatingPanel = true; window.hidesOnDeactivate = true
        super.init(window: window); window.delegate = self
        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = LRColors.canvas.cgColor; window.contentView = root
        canvas.appearance = NSAppearance(named: .darkAqua); canvas.message = "Choose a reference photo."
        canvas.toggleZoom = { [weak canvas] in guard let canvas else { return }; canvas.native = !canvas.native }
        name.textColor = LRColors.text; name.font = .systemFont(ofSize: 11)
        let use = LRButton("Use Current Photo as Reference") { [weak self] in self?.useCurrent?() }
        let bar = NSStackView(views: [name, NSView(), use]); bar.spacing = 8
        for v in [canvas, bar] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor), canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8), bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10), bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ item: ShootItem) {
        name.stringValue = "Reference: " + item.url.lastPathComponent; canvas.message = "Loading…"
        renderer.image(item, size: 2000) { [weak self] image in self?.canvas.image = image; self?.canvas.message = image == nil ? "Couldn’t show this photo." : "" }
    }
    func windowWillClose(_ notification: Notification) { renderer.cancel() }
}
