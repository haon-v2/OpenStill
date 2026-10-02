import AppKit
import OpenStillCore

/// TEMPORARY CI check: virtual copies, collection sets and Delete on a copy, in the real app.
enum CopySelfTest {
    static func runIfRequested(window: NSWindow?) {
        guard let prefix = ProcessInfo.processInfo.environment["OPENSTILL_COPY_SELFTEST"] else { return }
        func say(_ s: String) { print("COPY " + s); fflush(stdout) }
        func capture(_ name: String) {
            guard let number = window?.windowNumber else { return }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", String(number), "\(prefix)-\(name).png"]; try? p.run(); p.waitUntilExit()
        }
        func after(_ s: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: work) }
        after(8) {
            guard let viewer = window?.contentViewController as? ViewerController else { say("no viewer"); exit(2) }
            viewer.showEditor(); viewer.select(0)
            after(5) {
                viewer.createVirtualCopy()
                after(5) {
                    say("urls \(viewer.urls.map { $0.lastPathComponent + ($0.fragment.map { "#" + $0.prefix(13) } ?? "") }) selected=\(viewer.selected) copy=\(viewer.photoRecord?.copyName ?? "-")")
                    var e = viewer.currentEdits; e.exposure = -1.5; e.saturation = 0
                    viewer.changeEdits(e, title: "Test", commit: true)
                    after(6) {
                        let original = try? EditStorage.record(VirtualCopy.file(viewer.urls[viewer.selected]))
                        say("copy exposure=\(viewer.currentEdits.exposure) original exposure=\(original?.active.document.current.exposure ?? -99)")
                        capture("develop")
                        let catalog = EditStorage.records.catalog
                        if let set = try? catalog?.createCollectionSet(name: "Trips"), let inner = try? catalog?.createCollectionSet(name: "Europe", parent: set.id),
                           let c = try? catalog?.createCollection(name: "Paris") { try? catalog?.move(collection: c.id, into: inner.id) }
                        _ = try? catalog?.createCollection(name: "Portfolio")
                        viewer.showLibrary(); viewer.studio.libraryTab = 1; viewer.layoutStudio(); viewer.librarySidebar.page = 1; viewer.librarySidebar.reloadCollections()
                        after(6) {
                            say("library items \(viewer.libraryBrowser?.visibleURLs.count ?? -1)")
                            capture("library")
                            viewer.showEditor()
                            after(4) {
                                let copyURL = viewer.urls[viewer.selected]
                                say("deleting \(copyURL.lastPathComponent) isCopy=\(VirtualCopy.isCopy(copyURL))")
                                viewer.trashPhoto()
                                after(2) {
                                    let sheet = window?.attachedSheet
                                    let texts = sheet.map { allText(in: $0.contentView) } ?? []
                                    say("sheet \(texts.prefix(4))")
                                    capture("delete")
                                    say("file still there \(FileManager.default.fileExists(atPath: copyURL.path))")
                                    exit(0)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    static func allText(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var out: [String] = []
        if let f = view as? NSTextField, !f.stringValue.isEmpty { out.append(f.stringValue) }
        if let b = view as? NSButton, !b.title.isEmpty { out.append("[" + b.title + "]") }
        for s in view.subviews { out += allText(in: s) }
        return out
    }
}
