import AppKit
import OpenStillCore

/// TEMPORARY CI check: the library cache and relinking, driven through the real app with a disk image as the "card".
/// OPENSTILL_CACHE_SELFTEST=view:<prefix> opens photos so their looks are cached; =away:<prefix> runs with the card ejected,
/// then waits for it to be mounted again (under another name) and checks the photo relinked.
enum CacheSelfTest {
    static func runIfRequested(window: NSWindow?) {
        guard let spec = ProcessInfo.processInfo.environment["OPENSTILL_CACHE_SELFTEST"] else { return }
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let phase = parts[0], prefix = parts.count > 1 ? parts[1] : "/tmp/cache"
        func say(_ s: String) { print("CACHE " + s); fflush(stdout) }
        func capture(_ name: String) {
            guard let number = window?.windowNumber else { return }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", String(number), "\(prefix)-\(name).png"]
            try? p.run(); p.waitUntilExit()
        }
        func after(_ s: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: work) }
        after(8) {
            guard let viewer = window?.contentViewController as? ViewerController else { say("no viewer"); exit(2) }
            if phase == "view" {
                say("photos \(viewer.urls.map(\.path))")
                viewer.showEditor(); viewer.select(0)
                after(8) {
                    if viewer.urls.count > 1 { viewer.select(1) }
                    after(8) {
                        for url in viewer.urls {
                            let id = EditStorage.records.catalog?.recordID(path: url.standardizedFileURL.path)
                            say("cached \(url.lastPathComponent) \(id.flatMap { LibraryCache.image(for: $0) }.map { "\($0.width)x\($0.height)" } ?? "none")")
                        }
                        say("recent \(EditStorage.records.catalog?.recent().count ?? -1)")
                        capture("view"); exit(0)
                    }
                }
                return
            }
            // Away: the card is ejected.
            viewer.openRecentPhotos()
            after(6) {
                say("recent list \(viewer.urls.map(\.lastPathComponent)) missing \(viewer.urls.filter { !FileManager.default.fileExists(atPath: $0.path) }.count)")
                capture("library")
                viewer.showEditor(); viewer.select(0)
                after(5) {
                    say("banner hidden=\(viewer.missingBanner?.isHidden ?? true) canvas=\(viewer.canvas.image.map { "\($0.width)x\($0.height)" } ?? "none") message=\(viewer.canvas.message)")
                    capture("develop")
                    say("READY_FOR_MOUNT")
                    var waited = 0.0
                    func poll() {
                        if let source = viewer.currentSource, FileManager.default.fileExists(atPath: source.path) {
                            after(6) {
                                say("RELINKED \(viewer.currentSource?.path ?? "?") banner hidden=\(viewer.missingBanner?.isHidden ?? true) record=\(viewer.photoRecord?.sourcePath ?? "?") tabs=\(viewer.photoTabs.paths.map { ($0 as NSString).lastPathComponent })")
                                capture("relinked"); exit(0)
                            }
                            return
                        }
                        waited += 2; if waited > 120 { say("NOT RELINKED \(viewer.currentSource?.path ?? "?")"); capture("relinked"); exit(1) }
                        after(2, poll)
                    }
                    poll()
                }
            }
        }
    }
}
