import AppKit
import OpenStillCore

/// The photos open in Develop, as capsule tabs in the toolbar. Click to switch, × to close; edited photos carry a dot.
/// When there are more tabs than room, the strip scrolls sideways and its edges fade.
final class PhotoTabStrip: NSView {
    var choose: ((String) -> Void)?
    var close: ((String) -> Void)?
    var closeOthers: ((String) -> Void)?
    private let scroll = NSScrollView()
    private let row = NSStackView()
    private var tabs: [PhotoTab] = []
    private let fade = CAGradientLayer()
    private var width: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        row.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(row)
        scroll.documentView = document
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed; scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        width = widthAnchor.constraint(equalToConstant: 360); width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            width, heightAnchor.constraint(equalToConstant: 34),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: document.leadingAnchor), row.topAnchor.constraint(equalTo: document.topAnchor),
            row.bottomAnchor.constraint(equalTo: document.bottomAnchor), document.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
        ])
        // Fade the edges where tabs continue out of view (a mask, so it works on any background).
        wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = fade
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateFade), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        setAccessibilityElement(true); setAccessibilityRole(.tabGroup); setAccessibilityLabel("Open photos")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The width the toolbar can spare; the strip scrolls when the tabs need more.
    func setAvailableWidth(_ w: CGFloat) { width.constant = max(160, w) }

    func show(_ state: OpenPhotoTabs) {
        let paths = state.paths
        if tabs.map(\.path) != paths {
            tabs.forEach { $0.removeFromSuperview() }
            tabs = paths.map { path in
                let tab = PhotoTab(path: path)
                tab.choose = { [weak self] in self?.choose?(path) }
                tab.close = { [weak self] in self?.close?(path) }
                tab.closeOthers = { [weak self] in self?.closeOthers?(path) }
                row.addArrangedSubview(tab)
                return tab
            }
        }
        for tab in tabs { tab.active = tab.path == state.active; tab.edited = state.edited.contains(tab.path) }
        if let active = tabs.first(where: \.active) {
            layoutSubtreeIfNeeded()
            active.scrollToVisible(active.bounds.insetBy(dx: -24, dy: 0))
        }
        updateFade()
    }
    override func layout() { super.layout(); updateFade() }
    @objc private func updateFade() {
        fade.frame = bounds
        guard let document = scroll.documentView, bounds.width > 0 else { return }
        let visible = scroll.contentView.bounds
        let left = visible.minX > 1, right = visible.maxX < document.frame.width - 1
        let f = min(0.2, 28 / bounds.width)
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        fade.colors = [left ? clear : solid, solid, solid, right ? clear : solid]
        fade.locations = [0, NSNumber(value: Double(f)), NSNumber(value: Double(1 - f)), 1]
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// One capsule tab: file name, a dot when edited, and a close button.
private final class PhotoTab: NSView {
    let path: String
    var choose: (() -> Void)?
    var close: (() -> Void)?
    var closeOthers: (() -> Void)?
    var active = false { didSet { style() } }
    var edited = false { didSet { needsDisplay = true; dotWidth.constant = edited ? 5 : 0; dotGap.constant = edited ? 5 : 0 } }
    private let title: NSTextField
    private var dotWidth: NSLayoutConstraint!, dotGap: NSLayoutConstraint!
    private let dot = LRFill(Studio.secondary)
    init(path: String) {
        self.path = path
        let name = (path as NSString).lastPathComponent
        title = Studio.label(name, font: .systemFont(ofSize: 12, weight: .medium))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = path
        dot.wantsLayer = true; dot.layer?.cornerRadius = 2.5; dot.layer?.masksToBounds = true; dot.translatesAutoresizingMaskIntoConstraints = false
        let x = StudioIconButton(symbol: "xmark", label: "Close \(name)", side: 16) { [weak self] in self?.close?() }
        x.symbolSize = 8
        for v in [dot, title, x] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        dotWidth = dot.widthAnchor.constraint(equalToConstant: 0); dotGap = title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 0)
        let w = title.widthAnchor.constraint(lessThanOrEqualToConstant: 155)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11), dot.centerYAnchor.constraint(equalTo: centerYAnchor), dotWidth, dot.heightAnchor.constraint(equalToConstant: 5),
            dotGap, title.centerYAnchor.constraint(equalTo: centerYAnchor), w, title.widthAnchor.constraint(greaterThanOrEqualToConstant: 35),
            x.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 4), x.centerYAnchor.constraint(equalTo: centerYAnchor), x.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.radioButton); setAccessibilityLabel(name)
        style()
    }
    private func style() {
        needsDisplay = true
        title.font = .systemFont(ofSize: 12, weight: active ? .semibold : .medium); title.textColor = active ? Studio.text : Studio.secondary
        setAccessibilitySelected(active)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5), path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (active ? Studio.selectedFill : Studio.restFill).setFill(); path.fill()
        (active ? NSColor(calibratedWhite: 1, alpha: 0.22) : Studio.restStroke).setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func mouseDown(with event: NSEvent) { choose?() }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { close?() } }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Close Tab") { [weak self] in self?.close?() })
        menu.addItem(ActionMenuItem("Close Other Tabs") { [weak self] in self?.closeOthers?() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Show in Finder") { [path] in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) })
        return menu
    }
    override func accessibilityPerformPress() -> Bool { choose?(); return true }
}
