import AppKit
import OpenStillCore

/// Lightroom Classic's look: flat dark grays, square panels, no glass.
enum LRColors {
    static let backdrop = NSColor(calibratedWhite: 0.09, alpha: 1)
    static let panel = NSColor(calibratedWhite: 0.19, alpha: 1)
    static let header = NSColor(calibratedWhite: 0.215, alpha: 1)
    static let strip = NSColor(calibratedWhite: 0.14, alpha: 1)
    static let canvas = NSColor(calibratedWhite: 0.24, alpha: 1)
    static let text = NSColor(calibratedWhite: 0.80, alpha: 1)
    static let dim = NSColor(calibratedWhite: 0.52, alpha: 1)
    static let bright = NSColor(calibratedWhite: 0.94, alpha: 1)
    static let line = NSColor(calibratedWhite: 0.105, alpha: 1)
}

/// Panel state shared by the Lightroom layout's views, saved as it changes.
@MainActor final class LightroomState {
    static let shared = LightroomState()
    private(set) var panels = LightroomPanels.load()
    func update(_ change: (inout LightroomPanels) -> Void) { change(&panels); panels.save() }
}

/// A top-down stack for panel contents.
final class LRStack: NSStackView { override var isFlipped: Bool { true } }

/// A plain view with a solid background color.
class LRFill: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    init(_ color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); dirtyRect.fill() }
}

// MARK: - Collapsible sections

/// One of Lightroom's panel sections: a header you click to open or close, and its contents.
/// Left-panel headers read "▼ Navigator"; right-panel headers are right-aligned, "Basic ▼", as in Lightroom.
final class LRSection: NSView {
    let title: String
    let key: String
    let group: String
    let side: PanelEdge
    let body = LRStack()
    private let header: LRSectionHeader
    private let initiallyOpen: Bool
    /// The other sections in the same panel, for solo mode and Expand/Collapse All.
    var siblings: () -> [LRSection] = { [] }
    var toggled: (() -> Void)?
    init(_ title: String, module: LightroomModule, side: PanelEdge, open: Bool = true, accessory: NSView? = nil) {
        self.title = title; self.side = side; initiallyOpen = open
        key = LightroomPanels.key(module, side, title); group = LightroomPanels.group(module, side)
        header = LRSectionHeader(title: title, side: side, accessory: accessory)
        super.init(frame: .zero)
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 8
        body.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 14, right: 14)
        // A stack, so a closed section's hidden contents take no space.
        let column = LRStack(views: [header, body]); column.orientation = .vertical; column.spacing = 0; column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false; addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor), column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor), body.widthAnchor.constraint(equalTo: column.widthAnchor), header.heightAnchor.constraint(equalToConstant: 28),
        ])
        header.clicked = { [weak self] option in self?.headerClicked(option: option) }
        header.menuProvider = { [weak self] in self?.headerMenu() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    var isOpen: Bool { LightroomState.shared.panels.isExpanded(key, default: initiallyOpen) }
    /// Rereads the saved open/closed state.
    func refresh() { body.isHidden = !isOpen; header.open = isOpen; header.solo = LightroomState.shared.panels.solo.contains(group) }
    private func headerClicked(option: Bool) {
        if option { toggleSolo(); return }
        let keys = siblings().map(\.key)
        LightroomState.shared.update { $0.setExpanded(key, !isOpen, siblings: keys) }
        for section in siblings() { section.refresh() }; refresh()
        toggled?()
    }
    @objc private func toggleSolo() {
        let keys = siblings().map(\.key)
        LightroomState.shared.update { $0.toggleSolo(group, keep: key, siblings: keys) }
        for section in siblings() { section.refresh() }; refresh(); toggled?()
    }
    @objc private func expandAll() { setAll(true) }
    @objc private func collapseAll() { setAll(false) }
    private func setAll(_ open: Bool) {
        LightroomState.shared.update { panels in for section in siblings() { panels.expanded[section.key] = open } }
        for section in siblings() { section.refresh() }; toggled?()
    }
    private func headerMenu() -> NSMenu {
        let menu = NSMenu()
        let solo = NSMenuItem(title: "Solo Mode", action: #selector(toggleSolo), keyEquivalent: ""); solo.target = self
        solo.state = LightroomState.shared.panels.solo.contains(group) ? .on : .off; menu.addItem(solo)
        menu.addItem(.separator())
        for (title, action) in [("Expand All", #selector(expandAll)), ("Collapse All", #selector(collapseAll))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    /// Adds a view across the section's full width.
    func add(_ view: NSView) {
        body.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -body.edgeInsets.left - body.edgeInsets.right).isActive = true
    }
}

private final class LRSectionHeader: NSView {
    var clicked: ((Bool) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var open = true { didSet { needsDisplay = true; setAccessibilityExpanded(open) } }
    var solo = false { didSet { needsDisplay = true } }
    private let title: String
    private let side: PanelEdge
    init(title: String, side: PanelEdge, accessory: NSView?) {
        self.title = title; self.side = side
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.disclosureTriangle); setAccessibilityLabel(title)
        setAccessibilityHelp("Opens or closes the \(title) panel. Option-click for solo mode.")
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false; addSubview(accessory)
            NSLayoutConstraint.activate([accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
                                         side == .left ? accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10) : accessory.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)])
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        LRColors.header.setFill(); bounds.fill()
        LRColors.line.setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: LRColors.text]
        let size = (title as NSString).size(withAttributes: attrs)
        let triangle = NSBezierPath(), y = bounds.midY
        if side == .left {
            (title as NSString).draw(at: NSPoint(x: 26, y: y - size.height / 2), withAttributes: attrs)
            drawTriangle(triangle, at: NSPoint(x: 13, y: y))
        } else {
            (title as NSString).draw(at: NSPoint(x: bounds.width - 26 - size.width, y: y - size.height / 2), withAttributes: attrs)
            drawTriangle(triangle, at: NSPoint(x: bounds.width - 13, y: y))
        }
    }
    /// ▼ when open; ◀ (right panel) or ▶ (left panel) when closed. Solo mode draws it dotted, as Lightroom does.
    private func drawTriangle(_ path: NSBezierPath, at c: NSPoint) {
        let s: CGFloat = 4
        if open { path.move(to: NSPoint(x: c.x - s, y: c.y - s / 2)); path.line(to: NSPoint(x: c.x + s, y: c.y - s / 2)); path.line(to: NSPoint(x: c.x, y: c.y + s)) }
        else if side == .left { path.move(to: NSPoint(x: c.x - s / 2, y: c.y - s)); path.line(to: NSPoint(x: c.x - s / 2, y: c.y + s)); path.line(to: NSPoint(x: c.x + s, y: c.y)) }
        else { path.move(to: NSPoint(x: c.x + s / 2, y: c.y - s)); path.line(to: NSPoint(x: c.x + s / 2, y: c.y + s)); path.line(to: NSPoint(x: c.x - s, y: c.y)) }
        path.close()
        if solo { LRColors.text.setStroke(); path.setLineDash([1.5, 1.5], count: 2, phase: 0); path.lineWidth = 1; path.stroke() }
        else { LRColors.dim.setFill(); path.fill() }
    }
    override func mouseDown(with event: NSEvent) { clicked?(event.modifierFlags.contains(.option)) }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    override func accessibilityPerformPress() -> Bool { clicked?(false); return true }
}

/// A panel column: sections that stay put at the top (Navigator, Histogram), sections that scroll, and a row of buttons at the bottom.
final class LRPanelColumn: LRFill {
    let fixed = LRStack()
    let scrolling = LRStack()
    private let scroll = NSScrollView()
    let footer = NSStackView()
    /// Status messages (AI progress, errors) above the buttons.
    let note = NSTextField(wrappingLabelWithString: "")
    private var sections: [LRSection] = []
    init() {
        super.init(LRColors.panel)
        appearance = NSAppearance(named: .darkAqua)
        for stack in [fixed, scrolling] { stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0 }
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = scrolling
        footer.spacing = 6; footer.distribution = .fillEqually; footer.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        note.font = .systemFont(ofSize: 10); note.textColor = LRColors.dim; note.maximumNumberOfLines = 3; note.lineBreakMode = .byTruncatingTail
        for v in [fixed, scroll, note, footer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        scrolling.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            fixed.topAnchor.constraint(equalTo: topAnchor), fixed.leadingAnchor.constraint(equalTo: leadingAnchor), fixed.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: fixed.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -4),
            note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), note.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor), footer.trailingAnchor.constraint(equalTo: trailingAnchor), footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrolling.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), scrolling.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), scrolling.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Adds a section; `pinned` sections stay at the top while the rest scroll.
    func add(_ section: LRSection, pinned: Bool = false) {
        let stack = pinned ? fixed : scrolling
        stack.addArrangedSubview(section); section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        sections.append(section)
        section.siblings = { [weak self] in self?.sections.filter { $0.group == section.group } ?? [] }
    }
    /// A view that stays at the top without a section header, e.g. the Develop tool strip.
    func pin(_ view: NSView) { fixed.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: fixed.widthAnchor).isActive = true }
    /// Lightroom's flat bottom buttons, e.g. Import… / Export… or Previous / Reset.
    func setButtons(_ buttons: [(String, () -> Void)]) {
        footer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (title, run) in buttons { footer.addArrangedSubview(LRButton(title, run)) }
        footer.isHidden = buttons.isEmpty
    }
    func refreshSections() { sections.forEach { $0.refresh() } }
}

/// A flat gray Lightroom button.
final class LRButton: NSButton {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; controlSize = .small; font = .systemFont(ofSize: 11)
        target = self; action = #selector(clicked)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clicked() { run() }
}

// MARK: - Module picker

/// The top bar: the identity plate on the left and the modules on the right, "Library | Develop | Map | …".
final class LRModulePicker: LRFill {
    var choose: ((LightroomModule) -> Void)?
    var current: LightroomModule = .develop { didSet { restyle() } }
    private var buttons: [LightroomModule: NSButton] = [:]
    init() {
        super.init(LRColors.backdrop)
        let identity = NSTextField(labelWithString: "OpenStill")
        identity.font = .systemFont(ofSize: 19, weight: .light); identity.textColor = LRColors.dim
        let modules = NSStackView(); modules.spacing = 0
        for (index, module) in LightroomModule.allCases.enumerated() {
            if index > 0 {
                let bar = NSTextField(labelWithString: "|"); bar.font = .systemFont(ofSize: 15, weight: .ultraLight); bar.textColor = LRColors.dim.withAlphaComponent(0.6)
                modules.addArrangedSubview(bar)
            }
            let button = NSButton(title: module.title, target: self, action: #selector(picked(_:)))
            button.isBordered = false; button.tag = index; button.setAccessibilityLabel("\(module.title) module")
            buttons[module] = button; modules.addArrangedSubview(button)
            modules.setCustomSpacing(12, after: button)
            if index > 0 { modules.setCustomSpacing(12, after: modules.arrangedSubviews[modules.arrangedSubviews.count - 2]) }
        }
        for v in [identity, modules] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            identity.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22), identity.centerYAnchor.constraint(equalTo: centerYAnchor),
            modules.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22), modules.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func restyle() {
        for (module, button) in buttons {
            let active = module == current
            button.attributedTitle = NSAttributedString(string: module.title, attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: active ? .regular : .light),
                .foregroundColor: active ? LRColors.bright : LRColors.dim])
            button.setAccessibilityValue(active ? "Selected" : nil)
        }
    }
    @objc private func picked(_ sender: NSButton) { choose?(LightroomModule.allCases[sender.tag]) }
}

// MARK: - Edge toggles

/// The small triangle at each window edge that shows or hides that panel.
final class LREdgeToggle: NSView {
    let edge: PanelEdge
    var shown = true { didSet { needsDisplay = true; setAccessibilityLabel((shown ? "Hide " : "Show ") + name) } }
    var toggled: (() -> Void)?
    private var name: String { ["top": "module picker", "left": "left panel", "right": "right panel", "bottom": "filmstrip"][edge.rawValue] ?? "" }
    init(_ edge: PanelEdge) {
        self.edge = edge; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Hide " + name)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        LRColors.backdrop.setFill(); bounds.fill()
        let c = NSPoint(x: bounds.midX, y: bounds.midY), s: CGFloat = 3.5, p = NSBezierPath()
        // Points toward the edge while the panel shows (click to hide), away from it while hidden.
        let outward: Bool = shown
        switch (edge, outward) {
        case (.left, true), (.right, false): p.move(to: NSPoint(x: c.x - s, y: c.y)); p.line(to: NSPoint(x: c.x + s, y: c.y + s * 1.4)); p.line(to: NSPoint(x: c.x + s, y: c.y - s * 1.4))
        case (.right, true), (.left, false): p.move(to: NSPoint(x: c.x + s, y: c.y)); p.line(to: NSPoint(x: c.x - s, y: c.y + s * 1.4)); p.line(to: NSPoint(x: c.x - s, y: c.y - s * 1.4))
        case (.top, true), (.bottom, false): p.move(to: NSPoint(x: c.x, y: c.y + s)); p.line(to: NSPoint(x: c.x - s * 1.4, y: c.y - s)); p.line(to: NSPoint(x: c.x + s * 1.4, y: c.y - s))
        default: p.move(to: NSPoint(x: c.x, y: c.y - s)); p.line(to: NSPoint(x: c.x - s * 1.4, y: c.y + s)); p.line(to: NSPoint(x: c.x + s * 1.4, y: c.y + s))
        }
        p.close(); LRColors.dim.setFill(); p.fill()
    }
    override func mouseDown(with event: NSEvent) { toggled?() }
    override func accessibilityPerformPress() -> Bool { toggled?(); return true }
}

// MARK: - Navigator

/// Lightroom's Navigator: the whole photo, with a frame around the part shown when zoomed in. Click or drag to move there.
final class LRNavigator: NSView {
    weak var canvas: PhotoCanvas?
    init() {
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 160).isActive = true
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Navigator")
        setAccessibilityHelp("The whole photo. When zoomed in, click or drag here to move around it.")
    }
    required init?(coder: NSCoder) { fatalError() }
    private var photoRect: NSRect {
        guard let image = canvas?.image else { return .zero }
        let area = bounds.insetBy(dx: 2, dy: 6), w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(area.width / w, area.height / h)
        return NSRect(x: area.midX - w * scale / 2, y: area.midY - h * scale / 2, width: w * scale, height: h * scale)
    }
    override func draw(_ dirtyRect: NSRect) {
        LRColors.strip.setFill(); bounds.fill()
        guard let image = canvas?.image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = photoRect
        context.interpolationQuality = .medium; context.draw(image, in: rect)
        if let shown = canvas?.visibleFraction {
            let frame = NSRect(x: rect.minX + shown.minX * rect.width, y: rect.minY + shown.minY * rect.height, width: shown.width * rect.width, height: shown.height * rect.height)
            NSColor.white.setStroke(); let path = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5)); path.lineWidth = 1; path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    private func move(_ event: NSEvent) {
        let rect = photoRect, p = convert(event.locationInWindow, from: nil)
        guard rect.width > 0, canvas?.visibleFraction != nil else { return }
        canvas?.center(on: CGPoint(x: min(1, max(0, (p.x - rect.minX) / rect.width)), y: min(1, max(0, (p.y - rect.minY) / rect.height))))
    }
}

/// "FIT  100%  200%" in the Navigator header.
final class LRZoomLinks: NSStackView {
    var choose: ((Int) -> Void)?
    private var links: [NSButton] = []
    var selected = 0 { didSet { restyle() } }
    init() {
        super.init(frame: .zero); spacing = 8
        for (index, title) in ["FIT", "100%", "200%"].enumerated() {
            let b = NSButton(title: title, target: self, action: #selector(picked(_:))); b.isBordered = false; b.tag = index
            b.setAccessibilityLabel(["Fit", "100 percent", "200 percent"][index]); links.append(b); addArrangedSubview(b)
        }
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func restyle() {
        for b in links { b.attributedTitle = NSAttributedString(string: b.title, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: b.tag == selected ? LRColors.bright : LRColors.dim]) }
    }
    @objc private func picked(_ sender: NSButton) { choose?(sender.tag) }
}

// MARK: - Develop tool strip

/// The row of tools under the Develop histogram: Crop, Remove and Masking. The chosen tool's controls open beneath it.
final class LRToolStrip: LRFill {
    var choose: ((String?) -> Void)?
    private(set) var selected: String? { didSet { for b in buttons { b.state = b.identifier?.rawValue == selected ? .on : .off } } }
    private var buttons: [NSButton] = []
    init() {
        super.init(LRColors.panel)
        let row = NSStackView(); row.spacing = 22
        for (id, symbol, label) in [("crop", "crop", "Crop overlay (R)"), ("remove", "bandage", "Remove (Q)"), ("masking", "circle.dashed", "Masking (Shift-W)")] {
            let b = ToolbarIconButton(); b.identifier = .init(id); b.image = Appearance.symbol(symbol, size: 15, description: label)
            b.toolTip = label; b.setAccessibilityLabel(label); b.setButtonType(.pushOnPushOff); b.isBordered = false
            b.target = self; b.action = #selector(picked(_:)); b.widthAnchor.constraint(equalToConstant: 34).isActive = true; b.heightAnchor.constraint(equalToConstant: 28).isActive = true
            buttons.append(b); row.addArrangedSubview(b)
        }
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo: centerXAnchor), row.topAnchor.constraint(equalTo: topAnchor, constant: 4), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func picked(_ sender: NSButton) { select(sender.identifier?.rawValue == selected ? nil : sender.identifier?.rawValue) }
    func select(_ id: String?) { selected = id; choose?(id) }
    /// Updates the highlight without running the tool.
    func show(_ id: String?) { selected = id }
}

// MARK: - Filmstrip bar and toolbar

/// The bar above the filmstrip: Library grid, back / forward, and the source, "Folder : Trip · 124 photos / 1 selected / IMG_0001.CR3".
final class LRFilmstripBar: LRFill {
    var grid: (() -> Void)?
    var step: ((Int) -> Void)?
    private let source = NSTextField(labelWithString: "")
    init() {
        super.init(LRColors.strip)
        let row = NSStackView(); row.spacing = 6
        for (symbol, label, action) in [("square.grid.2x2", "Library grid (G)", #selector(showGrid)), ("chevron.left", "Previous photo", #selector(back)), ("chevron.right", "Next photo", #selector(forward))] {
            let b = ToolbarIconButton(); b.image = Appearance.symbol(symbol, size: 11, description: label); b.toolTip = label; b.setAccessibilityLabel(label)
            b.isBordered = false; b.target = self; b.action = action
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true; b.heightAnchor.constraint(equalToConstant: 20).isActive = true
            row.addArrangedSubview(b)
        }
        source.font = .systemFont(ofSize: 11); source.textColor = LRColors.dim; source.lineBreakMode = .byTruncatingMiddle
        source.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(source); row.setCustomSpacing(14, after: row.arrangedSubviews[2])
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8), row.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(source kind: String, name: String, count: Int, selected: Int, file: String?) {
        var text = "\(kind) : \(name)   \(count) photo\(count == 1 ? "" : "s") / \(selected) selected"
        if let file { text += " / \(file)" }
        source.stringValue = text; source.toolTip = text
    }
    @objc private func showGrid() { grid?() }
    @objc private func back() { step?(-1) }
    @objc private func forward() { step?(1) }
}

/// The toolbar under the photo in Develop (T shows or hides it): loupe, before/after, and the clipping warning.
final class LRDevelopToolbar: LRFill {
    var command: ((String) -> Void)?
    private let split = ToolbarIconButton(), loupe = ToolbarIconButton(), clipping = ToolbarIconButton()
    private let zoom = NSTextField(labelWithString: "")
    init() {
        super.init(LRColors.strip)
        let row = NSStackView(); row.spacing = 4
        for (button, id, symbol, label) in [(loupe, "loupe", "rectangle", "Loupe view"), (split, "compareSplit", "rectangle.split.2x1", "Before / after, left and right (Y)"), (clipping, "toggleClipping", "exclamationmark.triangle", "Show clipping (J)")] {
            button.identifier = .init(id); button.image = Appearance.symbol(symbol, size: 13, description: label); button.toolTip = label
            button.setAccessibilityLabel(label); button.setButtonType(.pushOnPushOff); button.isBordered = false; button.target = self; button.action = #selector(clicked(_:))
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true; button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            row.addArrangedSubview(button)
        }
        row.setCustomSpacing(18, after: split)
        zoom.font = .systemFont(ofSize: 11); zoom.textColor = LRColors.dim
        for v in [row, zoom] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), row.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     zoom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), zoom.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(split on: Bool, clipping clipped: Bool, zoom text: String) {
        split.state = on ? .on : .off; loupe.state = on ? .off : .on; clipping.state = clipped ? .on : .off; zoom.stringValue = text
    }
    @objc private func clicked(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        if id == "loupe" { if split.state == .on { command?("compareSplit") } else { sender.state = .on } } else { command?(id) }
    }
}
