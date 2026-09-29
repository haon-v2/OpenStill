import AppKit

/// A non-modal floating panel beside the editor (Presets & LUTs, History, Info, Navigator).
/// It remembers where you left it, stays above the window without dimming it, and hides when OpenStill isn't active.
final class StudioPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let name: String
    var closed: (() -> Void)?
    init(name: String, title: String, content: NSView, size: NSSize) {
        self.name = name
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.title = title
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = Studio.chrome
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 240, height: 200)
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self
        let root = LRFill(Studio.chrome)
        panel.contentView = root
        content.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.setFrameAutosaveName("OpenStill.StudioPanel." + name)
    }
    var isVisible: Bool { panel.isVisible }
    /// Shows it where it was last time; the first time, just inside the main window's left edge.
    func show(beside window: NSWindow?) {
        if !panel.setFrameUsingName("OpenStill.StudioPanel." + name), let window {
            let f = window.frame
            panel.setFrameOrigin(NSPoint(x: f.minX + 72, y: f.maxY - panel.frame.height - 110))
        }
        panel.orderFront(nil)
    }
    func close() { panel.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { closed?() }
}
