import AppKit
import OpenStillCore
import UniformTypeIdentifiers

/// Camera profile looks, DCP import and RAW decoding options.
extension ViewerController {
    func profileCommand(_ name: String) {
        var edits = currentEdits
        if name == "importDCP" { importDCP(); return }
        if name.hasPrefix("profile:"), let look = ProfileLook(rawValue: String(name.dropFirst("profile:".count))) {
            var profile = edits.profile; profile.look = look; profile.dcpAsset = nil; profile.dcpName = nil
            edits.profile = profile; changeEdits(edits, title: "Profile · " + look.title, commit: true); return
        }
        if name.hasPrefix("rawOptions:") {
            let parts = name.split(separator: ":").map(String.init)
            guard parts.count == 5, let demosaic = RawDemosaic(rawValue: parts[1]), let noise = Double(parts[2]), let color = Int(parts[3]), let impulse = Int(parts[4]) else { return }
            var options = RawOptions(); options.demosaic = demosaic; options.noise = noise; options.colorNoise = color; options.impulseNoise = impulse
            guard options.sanitized != edits.rawOptions else { return }
            edits.rawOptions = options; changeEdits(edits, title: "RAW decoding", commit: true)
        }
    }
    private func importDCP() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.title = "Import DNG Camera Profile"; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dcp") ?? .data]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let profile = try DNGCameraProfile(data: Data(contentsOf: url))
                let asset = try EditStorage.newAsset(extension: "dcp")
                try FileManager.default.copyItem(at: url, to: asset)
                var edits = self.currentEdits, settings = edits.profile
                settings.dcpAsset = asset.lastPathComponent; settings.dcpName = profile.name ?? url.deletingPathExtension().lastPathComponent
                edits.profile = settings
                self.changeEdits(edits, title: "Profile · " + (settings.dcpName ?? "DCP"), commit: true)
            } catch { self.info.status("Couldn’t import this profile. " + error.localizedDescription) }
        }
    }
}
