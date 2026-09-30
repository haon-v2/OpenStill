import AppKit
import OpenStillCore

/// TEMPORARY for CI: runs AI erase through the real pipeline (stub worker) on each opened photo with a crop, straighten,
/// tone and a LUT-free edit, and saves before/after renders beside `OPENSTILL_ERASE_SELFTEST`.
enum EraseSelfTest {
    static func runIfRequested(_ viewer: ViewerController) {
        guard let prefix = ProcessInfo.processInfo.environment["OPENSTILL_ERASE_SELFTEST"] else { return }
        let count = viewer.urls.count
        func render(_ tag: String) -> String {
            guard let url = viewer.currentSource, var recipe = viewer.photoRecord?.active.recipe else { return "no photo" }
            recipe.edits = viewer.currentEdits
            do {
                let image = try ModernRenderer.render(source: url, recipe: recipe.sdr, maximumDimension: 1024)
                guard let cg = ModernRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                      let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return "render failed" }
                try jpeg.write(to: URL(fileURLWithPath: "\(prefix)-\(url.deletingPathExtension().lastPathComponent)-\(tag).jpg"))
                return "\(cg.width)×\(cg.height)"
            } catch { return "error \(error.localizedDescription)" }
        }
        func step(_ index: Int) {
            guard index < count else { exit(0) }
            viewer.showEditor(); viewer.select(index)
            waitOpen(viewer, 120) {
                let name = viewer.currentSource?.lastPathComponent ?? "?"
                print("PHOTO \(name) mode=\(viewer.photoRecord?.active.sourceMode.rawValue ?? "?") renderer=\(String(describing: viewer.photoRecord?.active.renderer)) size=\(viewer.editSourceSize())")
                var e = viewer.currentEdits
                e.crop = EditRect(CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)); e.straighten = 4; e.exposure = 0.7; e.contrast = 1.3; e.saturation = 1.4
                e.setMask(try! AssistantMasks.shape("radial", ["center": .array([.number(0.5), .number(0.5)]), "radius": .number(0.08)]), for: "Erase")
                viewer.changeEdits(e, title: "Test edit", commit: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    print("BEFORE \(name) \(render("1-before"))")
                    viewer.editingCommand("ai:erase")
                    waitAI(viewer, Date()) {
                        let after = viewer.currentEdits
                        print("AFTER1 \(name) base=\(after.baseAsset ?? "nil") base-size=\(after.baseAsset.flatMap { OSFloatHeader.size(of: EditStorage.asset($0)) }.map { "\($0)" } ?? "?") crop=\(String(describing: after.crop)) exposure=\(after.exposure) rawDenoise=\(String(describing: after.advanced?.rawDenoise)) status=\(viewer.info.lastStatus)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            print("RENDER1 \(name) \(render("2-after-erase"))")
                            viewer.editingCommand("ai:erase")
                            waitAI(viewer, Date()) {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    print("RENDER2 \(name) \(render("3-after-second-erase")) status=\(viewer.info.lastStatus)")
                                    fflush(stdout); step(index + 1)
                                }
                            }
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { step(0) }
    }
    static func waitOpen(_ viewer: ViewerController, _ tries: Int, _ done: @escaping () -> Void) {
        if viewer.renderedPhoto != nil && viewer.photoRecord != nil || tries == 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: done); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitOpen(viewer, tries - 1, done) }
    }
    static func waitAI(_ viewer: ViewerController, _ started: Date, _ done: @escaping () -> Void) {
        let t = Date().timeIntervalSince(started)
        if t > 300 || (t > 1.5 && !viewer.aiPreparing && !viewer.localAI.isRunning) { done(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waitAI(viewer, started, done) }
    }
}
