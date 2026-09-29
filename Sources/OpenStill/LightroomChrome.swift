import AppKit
import OpenStillCore

/// The panels' colors, from the Studio palette (see Studio in StudioStyle.swift).
enum LRColors {
    static let backdrop = Studio.canvas
    static let panel = Studio.chrome
    static let strip = Studio.chrome
    static let canvas = Studio.canvas
    static let text = NSColor(calibratedWhite: 0.86, alpha: 1)
    static let dim = Studio.secondary
    static let bright = Studio.text
    static let line = Studio.hairline
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
    init(_ color: NSColor) {
        self.color = color; super.init(frame: .zero)
        // Since macOS 14 views don't clip their drawing, and the dirty rect can reach past the view; stay inside it.
        if #available(macOS 14.0, *) { clipsToBounds = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { guard color.alphaComponent > 0 else { return }; color.setFill(); bounds.intersection(dirtyRect).fill() }
}

// MARK: - Collapsible sections

/// A collapsible panel section: a header you click to open or close, and its contents.
/// Option-click a header for solo mode (opening one closes the others); Control-click for Expand / Collapse All.
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
        body.edgeInsets = NSEdgeInsets(top: 2, left: 18, bottom: 16, right: 18)
        // A stack, so a closed section's hidden contents take no space.
        let column = LRStack(views: [header, body]); column.orientation = .vertical; column.spacing = 0; column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false; addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor), column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor), body.widthAnchor.constraint(equalTo: column.widthAnchor), header.heightAnchor.constraint(equalToConstant: 36),
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
        let keys = siblings().map(\.key), open = !isOpen, key = key
        LightroomState.shared.update { $0.setExpanded(key, open, siblings: keys) }
        for section in siblings() { section.refresh() }; refresh()
        toggled?()
    }
    @objc private func toggleSolo() {
        let keys = siblings().map(\.key), group = group, key = key
        LightroomState.shared.update { $0.toggleSolo(group, keep: key, siblings: keys) }
        for section in siblings() { section.refresh() }; refresh(); toggled?()
    }
    @objc private func expandAll() { setAll(true) }
    @objc private func collapseAll() { setAll(false) }
    private func setAll(_ open: Bool) {
        let keys = siblings().map(\.key)
        LightroomState.shared.update { panels in for key in keys { panels.expanded[key] = open } }
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
                                         accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)])
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    private var hovering = false { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// A chevron and the title in 13-point semibold, with a hairline above: the Studio section header.
    override func draw(_ dirtyRect: NSRect) {
        LRColors.line.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: hovering || open ? Studio.text : NSColor(calibratedWhite: 0.78, alpha: 1)]
        let size = (title as NSString).size(withAttributes: attrs), y = bounds.midY
        (title as NSString).draw(at: NSPoint(x: 34, y: y - size.height / 2), withAttributes: attrs)
        let name = open ? "chevron.down" : "chevron.right"
        if let chevron = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [solo ? Studio.accent : Studio.secondary]))) {
            let s = chevron.size
            chevron.draw(in: NSRect(x: 18 + (10 - s.width) / 2, y: y - s.height / 2, width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        _ = side
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
        footer.spacing = 8; footer.distribution = .fillEqually; footer.edgeInsets = NSEdgeInsets(top: 10, left: 18, bottom: 12, right: 18)
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
    /// A view at the top of the scrolling part, e.g. a tool drawer: tall contents scroll instead of stretching the window.
    func top(_ view: NSView) { scrolling.insertArrangedSubview(view, at: 0); view.widthAnchor.constraint(equalTo: scrolling.widthAnchor).isActive = true }
    /// Lightroom's flat bottom buttons, e.g. Import… / Export… or Previous / Reset.
    func setButtons(_ buttons: [(String, () -> Void)]) {
        footer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (title, run) in buttons { footer.addArrangedSubview(LRButton(title, run)) }
        footer.isHidden = buttons.isEmpty
    }
    func refreshSections() { sections.forEach { $0.refresh() } }
    func scrollToTop() {
        layoutSubtreeIfNeeded()
        let y = scrolling.isFlipped ? 0 : max(0, scrolling.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// A capsule button for panels (Previous, Reset, Sync…), drawn like the Studio bar buttons.
final class LRButton: NSButton {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        self.title = title; isBordered = false; font = Studio.controlFont
        target = self; action = #selector(clicked)
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font ?? Studio.controlFont]).width) + 24, height: 26) }
    @objc private func clicked() { run() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5), path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (isHighlighted ? Studio.selectedFill : Studio.restFill).setFill(); path.fill(); Studio.restStroke.setStroke(); path.lineWidth = 1; path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? Studio.controlFont, .foregroundColor: isEnabled ? Studio.text : Studio.tertiary]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

// MARK: - Identity plate

/// The identity plate at the toolbar's left: "OpenStill", your own text, or a logo (Develop › Identity Plate…).
final class IdentityPlate: NSView {
    static let textKey = "OpenStillIdentityPlateText", imageKey = "OpenStillIdentityPlateImage"
    private let text = Studio.label("OpenStill", font: .systemFont(ofSize: 13, weight: .semibold), color: Studio.text)
    private let logo = NSImageView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        logo.imageScaling = .scaleProportionallyDown
        for v in [text, logo] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), text.centerYAnchor.constraint(equalTo: centerYAnchor), text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            logo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.heightAnchor.constraint(equalToConstant: 20), logo.widthAnchor.constraint(lessThanOrEqualToConstant: 140),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        let custom = UserDefaults.standard.string(forKey: Self.textKey) ?? ""
        text.stringValue = custom.isEmpty ? "OpenStill" : custom
        let image = UserDefaults.standard.string(forKey: Self.imageKey).flatMap { NSImage(contentsOfFile: $0) }
        logo.image = image; logo.isHidden = image == nil; text.isHidden = image != nil
        setAccessibilityLabel(image == nil ? text.stringValue : "Identity plate")
    }
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
        Studio.well.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
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
