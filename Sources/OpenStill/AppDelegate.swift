import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let viewer = ViewerController()
    private let updates = UpdateController()
    private lazy var settings = SettingsWindowController(updates: updates)

    func applicationDidFinishLaunching(_ notification: Notification) {
        createWindow()
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        updates.checkAtLaunch()
        let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        if !files.isEmpty { application(NSApp, open: files) }
    }
    private func createWindow() {
        guard window == nil else { window.makeKeyAndOrderFront(nil); return }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "OpenStill"
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        Appearance.configure(window)
        window.minSize = NSSize(width: 1040, height: 700)
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentViewController = viewer
        viewer.installToolbar(on:window)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("OpenStillViewer")
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    func application(_ sender: NSApplication, open urls: [URL]) { createWindow(); if let package=urls.first(where:{$0.pathExtension=="openstilledits"}){viewer.inspectPackage(package)}else{viewer.open(urls)} }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        createWindow(); return true
    }
    func applicationWillTerminate(_ notification: Notification) { viewer.localAI.cancel() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        NSApp.mainMenu = main
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            main.addItem(item)
            return submenu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil,
                 modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        let app = menu("OpenStill")
        add(app, "About OpenStill", #selector(showAbout), target: self)
        app.addItem(.separator())
        add(app, "Settings…", #selector(showSettings), ",", target: self)
        add(app, "Check for Updates…", #selector(UpdateController.checkForUpdates(_:)), target: updates)
        add(app, "Check for Updates Automatically", #selector(UpdateController.toggleAutomaticChecks(_:)), target: updates)
        app.addItem(.separator())
        add(app, "Hide OpenStill", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit OpenStill", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        add(file, "Open Photo or Folder…", #selector(ViewerController.openPanel), "o", target: viewer)
        add(file, "Export Edited Photo…", #selector(ViewerController.exportPhoto), "e", target: viewer, modifiers: [.command, .shift])
        add(file, "Export Portable Edits…", #selector(ViewerController.exportEditPackage), target: viewer)
        add(file, "Import Portable Edits…", #selector(ViewerController.importEditPackage), target: viewer)
        add(file, "Import Lightroom Catalog…", #selector(ViewerController.importLightroomCatalog), target: viewer)
        add(file, "Reveal in Finder", #selector(ViewerController.revealPhoto), "r", target: viewer)
        add(file, "Share Photo…", #selector(ViewerController.sharePhoto), "s", target: viewer, modifiers: [.command, .shift])
        add(file, "Move to Trash…", #selector(ViewerController.trashPhoto), "\u{7f}", target: viewer)
        file.addItem(.separator())
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("Edit")
        add(edit, "Undo Edit", #selector(ViewerController.undoEdit), "z", target: viewer)
        add(edit, "Redo Edit", #selector(ViewerController.redoEdit), "z", target: viewer, modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Select All Photos", #selector(ViewerController.selectAllPhotos), "a", target: viewer)
        let view = menu("View")
        add(view, "Photo Library", #selector(ViewerController.showLibrary), "g", target: viewer, modifiers: [.command, .option])
        add(view, "Edit Photograph", #selector(ViewerController.showEditor), "e", target: viewer, modifiers: [.command, .option])
        view.addItem(.separator())
        add(view, "Zoom In", #selector(ViewerController.zoomIn), "+", target: viewer)
        add(view, "Zoom Out", #selector(ViewerController.zoomOut), "-", target: viewer)
        add(view, "Fit to Window", #selector(ViewerController.fitPhoto), "0", target: viewer)
        add(view, "Actual Pixels (100%)", #selector(ViewerController.nativePhoto), "1", target: viewer)
        add(view, "Show / Hide Photo Info", #selector(ViewerController.toggleInfo), "i", target: viewer)
        add(view, "Show / Hide Clipping (J)", #selector(ViewerController.toggleClippingOverlay), target: viewer)
        add(view, "Before / After Split (Y)", #selector(ViewerController.toggleBeforeAfterSplit), target: viewer)
        view.addItem(.separator())
        add(view, "Previous Photo", #selector(ViewerController.previousPhoto), String(UnicodeScalar(NSLeftArrowFunctionKey)!), target: viewer, modifiers: [])
        add(view, "Next Photo", #selector(ViewerController.nextPhoto), String(UnicodeScalar(NSRightArrowFunctionKey)!), target: viewer, modifiers: [])
        view.addItem(.separator())
        add(view, "Enter / Exit Full Screen", #selector(ViewerController.toggleFullscreen), "f", target: viewer, modifiers: [.command, .control])
        let windowMenu = menu("Window")
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = windowMenu
    }
    @objc private func showSettings() { settings.showWindow(nil); settings.window?.center(); settings.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "OpenStill", .applicationVersion: Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "",
            .credits: NSAttributedString(string: "A free, open-source photo editor.\nMade for a closer look.\n\nMIT License · No accounts required."),
            .version: Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""
        ])
    }
}
