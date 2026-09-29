import AppKit
import CoreImage
import ImageIO
import OpenStillCore

/// One card in the browser: a preset, a LUT look (one card per push/pull family) or a replacement sky.
enum Look: Equatable {
    case lut(LUTItem)
    case preset(PresetRecipe)
    case sky(SkyItem)
    var id: String {
        switch self {
        case .lut(let item): return "lut:" + item.entry.id
        case .preset(let preset): return "preset:" + preset.id
        case .sky(let sky): return "sky:" + sky.entry.id
        }
    }
    var title: String {
        switch self {
        case .lut(let item): return item.entry.name
        case .preset(let preset): return preset.name
        case .sky(let sky): return sky.entry.name
        }
    }
}

private final class LookCard: NSView {
    var look: Look?
    var preview: NSImage? { didSet { needsDisplay = true } }
    var failed = false { didSet { needsDisplay = true } }
    var applied = false { didSet { needsDisplay = true } }
    var favorite = false { didSet { needsDisplay = true } }
    var variants = 0 { didSet { needsDisplay = true } }
    var enabled = true { didSet { needsDisplay = true } }
    var click: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private var hovering = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { if enabled, bounds.contains(convert(event.locationInWindow, from: nil)) { click?() } }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { look.map { $0.title + (applied ? ", applied" : "") } }
    override func accessibilityPerformPress() -> Bool { guard enabled else { return false }; click?(); return true }
    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 1, dy: 1), path = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        (hovering && enabled ? Studio.hoverFill : Studio.restFill).setFill(); path.fill()
        let photo = NSRect(x: 5, y: 26, width: bounds.width - 10, height: bounds.height - 31)
        if let preview {
            let scale = min(photo.width / preview.size.width, photo.height / preview.size.height)
            let size = NSSize(width: preview.size.width * scale, height: preview.size.height * scale)
            let rect = NSRect(x: photo.midX - size.width / 2, y: photo.midY - size.height / 2, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            preview.draw(in: rect, from: .zero, operation: .sourceOver, fraction: enabled ? 1 : 0.55)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let symbol = NSImage(systemSymbolName: failed ? "exclamationmark.triangle" : "photo", accessibilityDescription: nil)
            symbol?.draw(in: NSRect(x: photo.midX - 9, y: photo.midY - 9, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 0.4)
        }
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
        ((look?.title ?? "") as NSString).draw(in: NSRect(x: 6, y: 6, width: bounds.width - 12, height: 15), withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: applied ? .semibold : .medium), .foregroundColor: enabled ? Studio.text : Studio.tertiary, .paragraphStyle: style])
        if favorite { NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?.draw(in: NSRect(x: 9, y: bounds.height - 21, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 0.9) }
        if variants > 1 {
            let badge = "\(variants)" as NSString, attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.white]
            let size = badge.size(withAttributes: attrs), rect = NSRect(x: bounds.width - size.width - 17, y: 30, width: size.width + 8, height: 14)
            NSColor(white: 0, alpha: 0.55).setFill(); NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            badge.draw(at: NSPoint(x: rect.minX + 4, y: rect.minY + 1.5), withAttributes: attrs)
        }
        if applied {
            Studio.accent.setStroke(); path.lineWidth = 2; path.stroke()
            NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.draw(in: NSRect(x: bounds.width - 22, y: bounds.height - 22, width: 15, height: 15))
        }
    }
}

private final class LookItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LookItem")
    var card: LookCard { view as! LookCard }
    override func loadView() { view = LookCard() }
}

/// Presets and LUT looks: categories, search, favorites, recent, and thumbnails of each look on the current photo.
/// Only visible cards exist and only they render thumbnails.
final class LookBrowserView: NSStackView, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    enum Mode: Int { case presets, luts, skies }
    var chooseLUT: ((LUTItem) -> Void)?
    var chooseSky: ((SkyItem) -> Void)?
    var choosePreset: ((PresetRecipe, Double) -> Void)?
    var command: ((String) -> Void)?
    /// LUT intensity, mask and import controls (filled by the editor panel).
    let lutControls = NSStackView()
    /// Save / import preset actions (filled by the editor panel).
    let presetControls = NSStackView()
    /// Sky sliders and actions (filled by the editor panel).
    let skyControls = NSStackView()
    private(set) var luts = LUTLibrary(imported: EditStorage.root.appendingPathComponent("LUTLibrary"))
    private(set) var presets = PresetLibrary.empty
    private(set) var skies = SkyLibrary.empty
    private let modePicker = NSSegmentedControl(labels: ["Presets", "LUTs", "Skies"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gridScroll = NSScrollView()
    private let collection = NSCollectionView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let variantPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let source = NSButton(title: "Creator & source ↗", target: nil, action: nil)
    private let amountRow = NSStackView()
    private let amount = NSSlider(value: 100, minValue: 0, maxValue: 200, target: nil, action: nil)
    private let amountValue = NSTextField(labelWithString: "100%")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private var mode = Mode.presets
    private var shown: [Look] = []
    private var edits = PhotoEdits()
    private var enabled = false
    private var active = false
    private var sourceURL: URL?
    private var appliedPreset: PresetRecipe?
    private var lastWidth: CGFloat = 0
    // Thumbnails
    private let images = NSCache<NSString, NSImage>()
    private var failures: Set<String> = []
    private var original: CGImage?
    private var linearSource: CIImage?
    private var renderSourceURL: URL?
    private var renderRecipe: RenderRecipe?
    private let queue = DispatchQueue(label: "OpenStill.LookPreviews", qos: .utility)
    private let generation = LUTPreviewGeneration()
    private let lock = NSLock()
    private var wanted: [String] = []
    private var working = false
    private static let favoritesKey = "OpenStill.FavoriteLooks", recentKey = "OpenStill.RecentLooks", modeKey = "OpenStill.LookBrowserMode"
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame); orientation = .vertical; alignment = .leading; spacing = 8
        images.countLimit = 400
        modePicker.target = self; modePicker.action = #selector(modeChanged); modePicker.segmentStyle = .capsule; modePicker.setAccessibilityLabel("Presets, LUTs or skies")
        mode = Mode(rawValue: UserDefaults.standard.integer(forKey: Self.modeKey)) ?? .presets; modePicker.selectedSegment = mode.rawValue
        add(modePicker)
        search.placeholderString = "Search looks"; search.target = self; search.action = #selector(filterChanged); search.sendsSearchStringImmediately = true; search.font = .systemFont(ofSize: 11); add(search)
        picker.target = self; picker.action = #selector(filterChanged); picker.font = .systemFont(ofSize: 11); picker.setAccessibilityLabel("Category"); add(picker)
        let layout = NSCollectionViewFlowLayout(); layout.minimumInteritemSpacing = 6; layout.minimumLineSpacing = 6
        collection.collectionViewLayout = layout; collection.dataSource = self; collection.delegate = self; collection.isSelectable = false
        collection.backgroundColors = [.clear]; collection.register(LookItem.self, forItemWithIdentifier: LookItem.identifier)
        gridScroll.documentView = collection; gridScroll.drawsBackground = false; gridScroll.hasVerticalScroller = true; gridScroll.autohidesScrollers = true
        gridScroll.heightAnchor.constraint(equalToConstant: 330).isActive = true; add(gridScroll)
        empty.font = .systemFont(ofSize: 11); empty.textColor = Studio.secondary; add(empty); empty.isHidden = true
        detail.font = .systemFont(ofSize: 11); detail.textColor = Studio.secondary; add(detail)
        variantPicker.target = self; variantPicker.action = #selector(variantChanged); variantPicker.font = .systemFont(ofSize: 11); variantPicker.setAccessibilityLabel("Look strength variant"); add(variantPicker); variantPicker.isHidden = true
        source.bezelStyle = .rounded; source.font = .systemFont(ofSize: 10); source.target = self; source.action = #selector(openSource); add(source); source.isHidden = true
        let amountLabel = NSTextField(labelWithString: "Amount"); amountLabel.font = .systemFont(ofSize: 11); amountLabel.textColor = Studio.secondary
        amount.target = self; amount.action = #selector(amountChanged); amount.isContinuous = true; amount.setAccessibilityLabel("Preset amount")
        amountValue.font = Studio.statusFont; amountValue.textColor = Studio.secondary; amountValue.alignment = .right; amountValue.widthAnchor.constraint(equalToConstant: 40).isActive = true
        amountRow.orientation = .horizontal; amountRow.spacing = 8; [amountLabel, amount, amountValue].forEach(amountRow.addArrangedSubview); add(amountRow)
        for stack in [lutControls, presetControls, skyControls] { stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; add(stack) }
        notice.font = .systemFont(ofSize: 10); notice.textColor = Studio.secondary; add(notice); notice.isHidden = true
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func add(_ view: NSView) { addArrangedSubview(view); view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    override func layout() {
        super.layout()
        if abs(gridScroll.bounds.width - lastWidth) > 0.5 { lastWidth = gridScroll.bounds.width; collection.collectionViewLayout?.invalidateLayout() }
    }

    // MARK: Libraries
    static var bundledResources: URL {
        let bundled = Bundle.main.resourceURL!
        return FileManager.default.fileExists(atPath: bundled.appendingPathComponent("LUTs/catalog.json").path) ? bundled : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
    }
    static var userPresets: URL { EditStorage.root.appendingPathComponent("Presets") }
    static var userSkies: URL { EditStorage.root.appendingPathComponent("Skies") }
    func reload() {
        let resources = Self.bundledResources, imports = EditStorage.root.appendingPathComponent("LUTLibrary")
        var problems: [String] = []
        do { luts = try LUTLibrary(bundled: resources.appendingPathComponent("LUTs"), imported: imports) }
        catch { luts = LUTLibrary(imported: imports); problems.append("The included LUT library couldn’t load. Imported looks are still available.") }
        do { presets = try PresetLibrary(bundled: resources.appendingPathComponent("Presets/presets.json"), user: Self.userPresets) }
        catch { presets = (try? PresetLibrary(bundled: nil, user: Self.userPresets)) ?? .empty; problems.append("The included presets couldn’t load. My Presets are still available.") }
        do { skies = try SkyLibrary(bundled: resources.appendingPathComponent("Skies"), user: Self.userSkies) }
        catch { skies = SkyLibrary.empty; problems.append("The included skies couldn’t load. Your own skies are still available.") }
        notice.stringValue = problems.joined(separator: "\n"); notice.isHidden = problems.isEmpty
        images.removeAllObjects(); failures.removeAll()
        rebuildPicker(); rebuild()
    }
    func item(id: String) -> LUTItem? { luts.items.first { $0.entry.id == id } }
    func imported(filename: String) -> LUTItem? { luts.items.first { !$0.isBundled && $0.url.lastPathComponent == filename } }
    func preset(id: String) -> PresetRecipe? { presets.presets.first { $0.id == id } }
    func preset(named name: String) -> PresetRecipe? { presets.presets.first { $0.name == name } }
    func sky(id: String) -> SkyItem? { skies.items.first { $0.entry.id == id } }

    // MARK: Photo and state from the editor
    func setActive(_ value: Bool) { active = value; generation.begin(); if value { requestVisible() } }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; amount.isEnabled = value && appliedPreset != nil
        for item in collection.visibleItems() { (item as? LookItem)?.card.enabled = value }
    }
    func setPhoto(_ image: CGImage?, edits next: PhotoEdits, source: CIImage? = nil, url: URL? = nil, recipe: RenderRecipe? = nil) {
        guard original !== image || linearSource !== source || edits != next else { return }
        if renderSourceURL != url { appliedPreset = nil }
        linearSource = source; renderSourceURL = url; renderRecipe = recipe
        original = image; edits = next; generation.begin(); images.removeAllObjects(); failures.removeAll()
        for item in collection.visibleItems() { (item as? LookItem)?.card.preview = nil; (item as? LookItem)?.card.failed = false }
        updateSelection(next); requestVisible()
    }
    /// The editor calls this after every committed change.
    func updateSelection(_ value: PhotoEdits) {
        edits = value
        let selected = luts.selected(for: value)
        for item in collection.visibleItems() { guard let card = (item as? LookItem)?.card, let look = card.look else { continue }; card.applied = isApplied(look, lut: selected) }
        amount.isEnabled = enabled && appliedPreset != nil
        variantPicker.isHidden = true
        if mode == .luts, let item = selected {
            let e = item.entry
            detail.stringValue = "\(e.displayName)\n\(e.description)\n\(e.creator) · \(licenseName(e.license))"
            sourceURL = URL(string: e.source).flatMap { ["https", "http"].contains($0.scheme ?? "") ? $0 : nil }
            let variants = luts.variants(of: item)
            if variants.count > 1 {
                variantPicker.removeAllItems()
                for v in variants { variantPicker.addItem(withTitle: v.entry.variant ?? "Normal"); variantPicker.lastItem?.representedObject = v.entry.id }
                variantPicker.selectItem(withTitle: e.variant ?? "Normal"); variantPicker.isHidden = false
            }
        } else if mode == .skies {
            let sky = skies.selected(for: value)
            let hasMask = value.advanced?.masks[PhotoEdits.skyMaskKey] != nil
            if let sky {
                detail.stringValue = "\(sky.entry.name)\n\(sky.entry.creator) · \(licenseName(sky.entry.license))"
                sourceURL = URL(string: sky.entry.source).flatMap { ["https", "http"].contains($0.scheme ?? "") ? $0 : nil }
            } else {
                detail.stringValue = value.sky.map { "\($0.name)\nSaved with this edit." } ?? (hasMask ? "Choose a sky. The rest of the photo is relit to match it."
                    : "Choose a sky. On-device AI finds the sky in this photo first (one-time setup of about 450 MB), then the rest of the photo is relit to match.")
                sourceURL = nil
            }
        } else if mode == .presets, let preset = appliedPreset {
            detail.stringValue = "\(preset.name)\n\(preset.description)" + (preset.lut.flatMap { id in luts.items.first { $0.entry.id == id.id } }.map { "\nLook: \($0.entry.displayName) · \($0.entry.creator) · \(licenseName($0.entry.license))" } ?? "")
            sourceURL = nil
        } else {
            detail.stringValue = mode == .luts ? (value.advanced?.lutName.map { "\($0)\nSaved with this edit." } ?? "Choose a look. Categories are suggestions: try any look on any photo.")
                : "Choose a preset. Presets change tone and color and keep your crop, masks and retouching."
            sourceURL = nil
        }
        source.isHidden = sourceURL == nil
    }
    private func licenseName(_ id: String) -> String { ["CC0-1.0": "CC0 (public domain)", "CC-BY-SA-4.0": "CC BY-SA 4.0"][id] ?? id }
    private func isApplied(_ look: Look, lut selected: LUTItem?) -> Bool {
        switch look {
        case .lut(let item): return selected.map { $0.entry.id == item.entry.id || ($0.entry.family != nil && $0.entry.family == item.entry.family) } ?? false
        case .preset(let p): return appliedPreset?.id == p.id
        case .sky(let sky): return edits.sky?.id == sky.entry.id
        }
    }

    // MARK: Filtering
    private var favorites: [String] { get { UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? [] } set { UserDefaults.standard.set(newValue, forKey: Self.favoritesKey) } }
    private var recent: [String] { get { UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [] } set { UserDefaults.standard.set(Array(newValue.prefix(24)), forKey: Self.recentKey) } }
    private func remember(_ look: Look) { recent = [look.id] + recent.filter { $0 != look.id } }
    private func rebuildPicker() {
        let previous = picker.selectedItem?.representedObject as? String
        picker.removeAllItems()
        func add(_ title: String, _ key: String, _ count: Int?) { picker.addItem(withTitle: count.map { "\(title)  (\($0))" } ?? title); picker.lastItem?.representedObject = key }
        if mode == .luts {
            let looks = luts.collapsed(luts.items)
            add("All looks", "All", looks.count); add("★ Favorites", "*favorites", nil); add("Recent", "*recent", nil); picker.menu?.addItem(.separator())
            for category in luts.categories.dropFirst() { add(category, category, looks.filter { $0.entry.category == category }.count) }
            if !luts.categories.contains("Imported") { add("Imported", "Imported", 0) }
        } else if mode == .skies {
            add("All skies", "All", skies.items.count); add("★ Favorites", "*favorites", nil); add("Recent", "*recent", nil); picker.menu?.addItem(.separator())
            for category in SkyLibrary.categories { add(category, category, skies.filtered(category).count) }
        } else {
            add("All presets", "All", presets.presets.count); add("★ Favorites", "*favorites", nil); add("Recent", "*recent", nil); picker.menu?.addItem(.separator())
            for category in presets.categories.dropFirst() { add(category, category, presets.filtered(category).count) }
        }
        if let previous, let index = picker.itemArray.firstIndex(where: { $0.representedObject as? String == previous }) { picker.selectItem(at: index) } else { picker.selectItem(at: 0) }
    }
    private func filteredLooks() -> [Look] {
        let key = picker.selectedItem?.representedObject as? String ?? "All", text = search.stringValue
        var looks: [Look]
        if mode == .luts {
            let base = key.hasPrefix("*") ? luts.items : luts.filtered(key)
            looks = luts.collapsed(luts.search(text, in: base)).map(Look.lut)
        } else if mode == .skies {
            let base = key.hasPrefix("*") ? skies.items : skies.filtered(key)
            let words = text.lowercased().split(separator: " ").map(String.init)
            looks = base.filter { sky in words.allSatisfy { w in ([sky.entry.name, sky.entry.category] + (sky.entry.tags ?? [])).joined(separator: " ").lowercased().contains(w) } }.map(Look.sky)
        } else {
            let base = key.hasPrefix("*") ? presets.presets : presets.filtered(key)
            looks = presets.search(text, in: base).map(Look.preset)
        }
        if key == "*favorites" { let f = Set(favorites); looks = looks.filter { f.contains($0.id) } }
        if key == "*recent" { let order = recent; looks = looks.filter { order.contains($0.id) }.sorted { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! } }
        return looks
    }
    private func rebuild() {
        generation.begin(); lock.lock(); wanted.removeAll(); lock.unlock()
        shown = filteredLooks(); collection.reloadData(); collection.scroll(.zero)
        let key = picker.selectedItem?.representedObject as? String
        empty.stringValue = key == "Imported" ? "No imported LUTs yet. Use Import .cube LUT below." : key == "Your Skies" ? "No skies of your own yet. Use Use your own sky… below." : key == PresetLibrary.myPresets ? "No presets of your own yet. Use Save current as preset below."
            : key == "*favorites" ? "No favorites yet. Right-click a look to add it." : key == "*recent" ? "Looks you apply appear here." : "Nothing matches “\(search.stringValue)”."
        empty.isHidden = !shown.isEmpty
        lutControls.isHidden = mode != .luts; presetControls.isHidden = mode != .presets; amountRow.isHidden = mode != .presets; skyControls.isHidden = mode != .skies
        search.placeholderString = mode == .luts ? "Search \(luts.collapsed(luts.items).count) looks" : mode == .skies ? "Search \(skies.items.count) skies" : "Search \(presets.presets.count) presets"
        updateSelection(edits)
    }
    @objc private func modeChanged() {
        mode = Mode(rawValue: modePicker.selectedSegment) ?? .presets; UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        rebuildPicker(); rebuild(); requestVisible()
    }
    @objc private func filterChanged() { rebuild(); requestVisible() }
    @objc private func openSource() { if let sourceURL { NSWorkspace.shared.open(sourceURL) } }
    @objc private func variantChanged() {
        guard enabled, let id = variantPicker.selectedItem?.representedObject as? String, let item = item(id: id) else { return }
        chooseLUT?(item)
    }
    @objc private func amountChanged() {
        amountValue.stringValue = "\(Int(amount.doubleValue.rounded()))%"
        guard let preset = appliedPreset, enabled, NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .keyDown else { return }
        choosePreset?(preset, amount.doubleValue / 100)
    }
    private func choose(_ look: Look) {
        guard enabled else { return }
        remember(look)
        switch look {
        case .lut(let item): chooseLUT?(item)
        case .sky(let sky): chooseSky?(sky)
        case .preset(let preset):
            appliedPreset = preset; amount.doubleValue = 100; amountValue.stringValue = "100%"
            choosePreset?(preset, 1)
        }
    }
    private func menu(for look: Look) -> NSMenu {
        let menu = NSMenu()
        let isFavorite = favorites.contains(look.id)
        menu.addItem(ClosureMenuItem(isFavorite ? "Remove from Favorites" : "Add to Favorites") { [weak self] in
            guard let self else { return }
            self.favorites = isFavorite ? self.favorites.filter { $0 != look.id } : self.favorites + [look.id]
            if (self.picker.selectedItem?.representedObject as? String) == "*favorites" { self.rebuild() } else { self.refreshVisibleCards() }
        })
        if case .preset(let preset) = look, preset.snapshot != nil {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Rename…") { [weak self] in self?.renamePreset(preset.name) })
            menu.addItem(ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Self.userPresets.appendingPathComponent(preset.name).appendingPathExtension(PresetLibrary.fileExtension)]) })
            menu.addItem(ClosureMenuItem("Delete") { [weak self] in
                guard let self else { return }
                do { try PresetLibrary.delete(preset.name, in: Self.userPresets); if self.appliedPreset?.id == preset.id { self.appliedPreset = nil }; self.reload() }
                catch { self.command?("status:" + error.localizedDescription) }
            })
        }
        if case .sky(let sky) = look, sky.entry.category == "Your Skies" {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([sky.url]) })
            menu.addItem(ClosureMenuItem("Delete") { [weak self] in
                try? FileManager.default.removeItem(at: sky.url); try? FileManager.default.removeItem(at: sky.url.deletingPathExtension().appendingPathExtension("json")); self?.reload()
            })
        }
        if case .lut(let item) = look, !item.isBundled {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) })
        }
        return menu
    }
    private func renamePreset(_ name: String) {
        let alert = NSAlert(); alert.messageText = "Rename preset"
        let field = NSTextField(string: name); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try PresetLibrary.rename(name, to: field.stringValue, in: Self.userPresets); appliedPreset = nil; reload() }
        catch { command?("status:" + error.localizedDescription) }
    }
    /// Shows a preset the editor just applied (for example after saving or importing one).
    func showApplied(_ preset: PresetRecipe) { appliedPreset = preset; amount.doubleValue = 100; amountValue.stringValue = "100%"; updateSelection(edits) }
    func showSkies() {
        if mode != .skies { modePicker.selectedSegment = Mode.skies.rawValue; modeChanged() }
    }
    func showMyPresets() {
        if mode != .presets { modePicker.selectedSegment = Mode.presets.rawValue; modeChanged() }
        if let index = picker.itemArray.firstIndex(where: { $0.representedObject as? String == PresetLibrary.myPresets }) { picker.selectItem(at: index); filterChanged() }
    }

    // MARK: Collection view
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: LookItem.identifier, for: indexPath) as! LookItem
        let look = shown[indexPath.item], card = item.card
        card.look = look; card.enabled = enabled; card.preview = images.object(forKey: look.id as NSString); card.failed = failures.contains(look.id)
        card.favorite = favorites.contains(look.id); card.applied = isApplied(look, lut: luts.selected(for: edits))
        if case .lut(let lut) = look { card.variants = luts.variants(of: lut).count; card.toolTip = lut.entry.description + "\n" + lut.entry.creator } else { card.variants = 0 }
        if case .preset(let preset) = look { card.toolTip = preset.description }
        if case .sky(let sky) = look { card.toolTip = sky.entry.category + " · " + sky.entry.creator }
        card.click = { [weak self] in self?.choose(look) }
        card.menuProvider = { [weak self] in self?.menu(for: look) }
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let width = max(80, floor((gridScroll.contentSize.width - 6) / 2))
        return NSSize(width: width, height: 100)
    }
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard indexPath.item < shown.count else { return }
        want(shown[indexPath.item].id)
    }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard let id = (item as? LookItem)?.card.look?.id else { return }
        lock.lock(); wanted.removeAll { $0 == id }; lock.unlock()
    }
    private func refreshVisibleCards() {
        let f = Set(favorites)
        for item in collection.visibleItems() { guard let card = (item as? LookItem)?.card, let look = card.look else { continue }; card.favorite = f.contains(look.id) }
    }

    // MARK: Thumbnails
    private func requestVisible() {
        for path in collection.indexPathsForVisibleItems().sorted() where path.item < shown.count { want(shown[path.item].id) }
    }
    private func want(_ id: String) {
        guard active, original != nil || linearSource != nil || id.hasPrefix("sky:"), images.object(forKey: id as NSString) == nil, !failures.contains(id) else { return }
        lock.lock(); if !wanted.contains(id) { wanted.append(id) }; lock.unlock()
        kick()
    }
    private func kick() {
        lock.lock(); let start = !working && !wanted.isEmpty; if start { working = true }; lock.unlock()
        if start { pump(token: generation.begin()) }
    }
    /// Renders wanted thumbnails newest-first on a background queue; cards scrolled away drop out of the queue.
    private func pump(token: UUID) {
        let snapshot = edits, selected = luts.selected(for: edits)?.entry.id
        let original = original, linearSource = linearSource, recipe = renderRecipe, url = renderSourceURL
        let looks = Dictionary((shown).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }), lutLibrary = luts, gate = generation
        queue.async { [weak self] in
            while true {
                guard let self else { return }
                self.lock.lock()
                guard gate.isCurrent(token), let id = self.wanted.popLast() else {
                    // A newer photo or edit took over: start again with it if cards are still waiting.
                    let restart = !self.wanted.isEmpty; self.working = false; self.lock.unlock()
                    if restart { DispatchQueue.main.async { [weak self] in self?.kick() } }
                    return
                }
                self.lock.unlock()
                guard let look = looks[id] else { continue }
                let result = Result { try autoreleasepool { () -> CGImage in
                    var preview = snapshot; preview.ensureAdvanced(); var override: CubeLUT?
                    switch look {
                    case .lut(let item):
                        preview.advanced!.lutAsset = nil; preview.lutAmount = selected == item.entry.id ? snapshot.lutAmount : 0.7; override = try item.load()
                    case .preset(let preset):
                        preview = preset.edits(from: snapshot); preview.ensureAdvanced()
                        if let lut = preset.lut, let item = lutLibrary.items.first(where: { $0.entry.id == lut.id }) { preview.advanced!.lutAsset = nil; preview.lutAmount = lut.amount; override = try item.load() }
                    case .sky(let sky):
                        // With a sky selection, the sky on this photo; without one, the sky itself.
                        guard snapshot.advanced?.masks[PhotoEdits.skyMaskKey] != nil, original != nil || linearSource != nil else { return try Self.thumbnail(sky.url) }
                        var settings = SkyReplacement(id: sky.entry.id, name: sky.entry.name, asset: sky.url.path, mean: sky.entry.mean, horizonColor: sky.entry.horizon,
                                                      relight: SkyItem.defaultRelight[sky.entry.category] ?? 0.6)
                        if let current = snapshot.sky { settings.horizon = current.horizon; settings.exposure = current.exposure; settings.defocus = current.defocus; settings.atmosphere = current.atmosphere; settings.flip = current.flip }
                        preview.sky = settings
                    }
                    if let url, var recipe { recipe.edits = preview; return try ModernRenderer.display(ModernRenderer.render(source: url, recipe: recipe, maximumDimension: 240, lutOverride: override)) }
                    if let linearSource { return try ModernRenderer.display(ModernRenderer.process(linearSource, edits: preview, maximumDimension: 240, lutOverride: override)) }
                    guard let original else { throw LUTError.invalid }
                    return try PhotoEditor.render(original, edits: preview, lutOverride: override, previewMaxDimension: 240)
                } }
                DispatchQueue.main.async { [weak self] in
                    guard let self, gate.isCurrent(token) else { return }
                    switch result {
                    case .success(let image): self.images.setObject(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), forKey: id as NSString)
                    case .failure: self.failures.insert(id)
                    }
                    for item in self.collection.visibleItems() {
                        guard let card = (item as? LookItem)?.card, card.look?.id == id else { continue }
                        card.preview = self.images.object(forKey: id as NSString); card.failed = self.failures.contains(id)
                    }
                }
            }
        }
    }
}

// TEMPORARY: driven by LayoutDump on CI.
extension LookBrowserView {
    func harness(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init), arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "mode": modePicker.selectedSegment = Int(arg) ?? 0; modeChanged()
        case "search": search.stringValue = arg; filterChanged()
        case "category":
            if let i = picker.itemArray.firstIndex(where: { ($0.representedObject as? String) == arg }) { picker.selectItem(at: i); filterChanged() } else { print("LOOKS no category \(arg)") }
        case "pick": if let look = shown.first(where: { $0.title == arg }) { choose(look) } else { print("LOOKS no look \(arg)") }
        case "variant": if let i = variantPicker.itemArray.firstIndex(where: { $0.title == arg }) { variantPicker.selectItem(at: i); variantChanged() }
        case "amount": amount.doubleValue = Double(arg) ?? 100; amountValue.stringValue = arg + "%"; if let p = appliedPreset { choosePreset?(p, amount.doubleValue / 100) }
        case "favorite": if let look = shown.first(where: { $0.title == arg }) { favorites = favorites + [look.id]; refreshVisibleCards() }
        case "save": try? PresetLibrary.save(PhotoEdits(), name: arg, in: Self.userPresets, replacing: true); reload()
        case "scroll": collection.scroll(NSPoint(x: 0, y: Double(arg) ?? 0))
        default: print("LOOKS unknown \(command)")
        }
    }
    func harnessSummary() -> String {
        let visible = collection.visibleItems().compactMap { ($0 as? LookItem)?.card }
        return "mode=\(mode) shown=\(shown.count) visible=\(visible.count) withThumbnail=\(visible.filter { $0.preview != nil }.count) failed=\(visible.filter(\.failed).count) category=\(picker.titleOfSelectedItem ?? "") detail=\(detail.stringValue.replacingOccurrences(of: "\n", with: " | "))"
    }
}

extension LookBrowserView {
    /// A small copy of an image file, for sky cards.
    static func thumbnail(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw LUTError.invalid }
        return image
    }
}

extension SkyLibrary {
    static let empty = try! SkyLibrary(bundled: nil, user: URL(fileURLWithPath: "/nonexistent-openstill-skies"))
}

extension PresetLibrary {
    static let empty = try! PresetLibrary(bundled: nil, user: URL(fileURLWithPath: "/nonexistent-openstill-presets"))
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler; super.init(title: title, action: #selector(run), keyEquivalent: ""); target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// A push button that runs a closure.
final class ClosureButton: NSButton {
    private var handler: () -> Void = {}
    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler; target = self; action = #selector(run)
    }
    @objc private func run() { handler() }
}
