import AppKit
import ImageCaptureCore
import UniformTypeIdentifiers
import OpenStillCore

/// Tethered shooting over USB with ImageCaptureCore: each new shot is copied into the session folder, gets the session's preset
/// and metadata, and opens in OpenStill. Cameras that support remote capture (PTP) can also be fired from here.
final class TetherWindow: OutputWindow, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    /// A shot was downloaded and added to the library.
    var shotArrived: ((URL) -> Void)?
    private let browser = ICDeviceBrowser()
    private var cameras: [ICCameraDevice] = []
    private var camera: ICCameraDevice?
    private var session: TetherSession?
    /// Items on the card when the session opened; only items added afterwards are new shots.
    private var ready = false
    private var shots = 0
    private let cameraPopup = NSPopUpButton()
    private let nameField = NSTextField(string: "Tethered session")
    private let folderLabel = NSTextField(labelWithString: "")
    private let metadataPopup = NSPopUpButton()
    private let developPopup = NSPopUpButton()
    private var parent: URL
    private var preset: (name: String, edits: PhotoEdits)?
    private var startButton: NSButton!, captureButton: NSButton!
    private let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("OpenStill Tether", isDirectory: true)

    init() {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        parent = UserDefaults.standard.string(forKey: "tetherParent").map { URL(fileURLWithPath: $0) } ?? pictures.appendingPathComponent("OpenStill Sessions", isDirectory: true)
        super.init(title: "Tethered Capture · OpenStill", items: [], size: NSSize(width: 560, height: 420))
        cameraPopup.addItem(withTitle: "Looking for cameras…"); cameraPopup.isEnabled = false
        nameField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        folderLabel.lineBreakMode = .byTruncatingMiddle; folderLabel.widthAnchor.constraint(equalToConstant: 280).isActive = true; folderLabel.stringValue = parent.path
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder)); choose.bezelStyle = .rounded
        metadataPopup.addItem(withTitle: "None"); for p in MetadataPresets.load() { metadataPopup.addItem(withTitle: p.name); metadataPopup.lastItem?.representedObject = p.id.uuidString }
        developPopup.addItems(withTitles: ["None", "Choose preset file…"]); developPopup.target = self; developPopup.action = #selector(chooseDevelopPreset)
        row("Camera", cameraPopup); row("Session name", nameField); row("Save in", folderLabel); row("", choose)
        row("Metadata", metadataPopup); row("Develop preset", developPopup)
        captureButton = button("Take Picture", #selector(capture)); captureButton.isEnabled = false
        startButton = button("Start Session", #selector(toggleSession), primary: true)
        status.stringValue = "Connect a camera with USB and switch it on. Shots taken with the camera’s shutter button (or Take Picture, when the camera supports it) are copied here as they arrive."
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue) ?? .camera
        // macOS asks the user about camera access itself when a session opens; there is no authorization call to make first.
        browser.start()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { endSession(); browser.stop() }

    @objc private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.parent = url; self.folderLabel.stringValue = url.path; UserDefaults.standard.set(url.path, forKey: "tetherParent")
        }
    }
    @objc private func chooseDevelopPreset() {
        guard developPopup.indexOfSelectedItem == 1, let window else { if developPopup.indexOfSelectedItem == 0 { preset = nil }; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "openstillpreset") ?? .json, .json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url, let edits = try? JSONDecoder().decode(PhotoEdits.self, from: Data(contentsOf: url)) else { self.developPopup.selectItem(at: self.preset == nil ? 0 : 2); return }
            self.preset = (url.deletingPathExtension().lastPathComponent, edits)
            while self.developPopup.numberOfItems > 2 { self.developPopup.removeItem(at: 2) }
            self.developPopup.addItem(withTitle: self.preset!.name); self.developPopup.selectItem(at: 2)
        }
    }

    // MARK: Session
    @objc private func toggleSession() {
        if session != nil { endSession(); return }
        guard cameras.indices.contains(cameraPopup.indexOfSelectedItem) else { status.stringValue = "No camera connected."; return }
        var s = TetherSession(name: nameField.stringValue, parent: parent)
        s.metadata = MetadataPresets.load().first { $0.id.uuidString == metadataPopup.selectedItem?.representedObject as? String }?.metadata
        s.developPreset = preset?.edits; s.developPresetName = preset?.name
        do { try FileManager.default.createDirectory(at: s.folder, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true) }
        catch { status.stringValue = error.localizedDescription; return }
        session = s; shots = 0; ready = false
        let device = cameras[cameraPopup.indexOfSelectedItem]; camera = device
        device.delegate = self; device.requestOpenSession()
        startButton.title = "End Session"; nameField.isEnabled = false; cameraPopup.isEnabled = false
        status.stringValue = "Connecting to \(device.name ?? "the camera")…"
    }
    private func endSession() {
        if let camera, camera.hasOpenSession { camera.requestCloseSession() }
        camera = nil; session = nil; ready = false
        startButton?.title = "Start Session"; nameField.isEnabled = true; cameraPopup.isEnabled = !cameras.isEmpty; captureButton?.isEnabled = false
    }
    @objc private func capture() { camera?.requestTakePicture() }

    // MARK: ICDeviceBrowserDelegate
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let device = device as? ICCameraDevice else { return }
        cameras.append(device); updateCameras()
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        cameras.removeAll { $0 === device }
        if device === camera { endSession(); status.stringValue = "The camera was disconnected." }
        updateCameras()
    }
    private func updateCameras() {
        cameraPopup.removeAllItems()
        if cameras.isEmpty { cameraPopup.addItem(withTitle: "No camera connected"); cameraPopup.isEnabled = false; return }
        for c in cameras { cameraPopup.addItem(withTitle: c.name ?? "Camera") }
        cameraPopup.isEnabled = session == nil
    }

    // MARK: ICDeviceDelegate
    func didRemove(_ device: ICDevice) { if device === camera { endSession(); status.stringValue = "The camera was disconnected." } }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { status.stringValue = "Couldn’t connect: \(error.localizedDescription)"; endSession() }
        else { status.stringValue = "Connected. Reading what’s already on the card…" }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    // MARK: ICCameraDeviceDelegate
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard device === camera, let session else { return }
        ready = true
        let remote = device.capabilities.contains(ICCameraDeviceCanTakePicture.rawValue)
        if device.capabilities.contains(ICCameraDeviceCanTakePictureUsingShutterReleaseOnCamera.rawValue) { device.requestEnableTethering() }
        captureButton.isEnabled = remote
        status.stringValue = "Ready. New shots go to “\(session.folder.lastPathComponent)”." + (remote ? "" : " This camera can’t be fired from the Mac; use its shutter button.")
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        guard camera === self.camera, ready else { return }
        for case let file as ICCameraFile in items where file.uti.map({ UTType($0)?.conforms(to: .image) ?? false }) ?? true {
            let name = file.name ?? "Shot"
            try? FileManager.default.removeItem(at: downloads.appendingPathComponent(name))
            camera.requestDownloadFile(file, options: [.downloadsDirectoryURL: downloads, .overwrite: true], downloadDelegate: self,
                                       didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)), contextInfo: nil)
        }
    }
    @objc func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        guard let session else { return }
        if let error { status.stringValue = "\(file.name ?? "A shot") couldn’t be copied: \(error.localizedDescription)"; return }
        let name = (options[ICDownloadOption.savedFilename.rawValue] as? String) ?? file.name ?? "Shot"
        let downloaded = downloads.appendingPathComponent(name)
        do {
            let target = try session.destination(for: file.name ?? name)
            try FileManager.default.moveItem(at: downloaded, to: target)
            try session.ingest(target)
            shots += 1
            status.stringValue = "\(shots) shot\(shots == 1 ? "" : "s") this session · last: \(target.lastPathComponent)"
            shotArrived?(target)
        } catch { status.stringValue = "\(name): \(error.localizedDescription)" }
    }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        if camera === self.camera, ready { captureButton.isEnabled = camera.capabilities.contains(ICCameraDeviceCanTakePicture.rawValue) }
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
