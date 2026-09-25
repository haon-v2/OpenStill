import AppKit
import OpenStillCore

/// Camera profile choice, DCP import and the RAW decoding options.
final class ProfilePanel: NSStackView {
    var command: ((String) -> Void)?
    private let looks = NSPopUpButton(frame: .zero, pullsDown: false)
    private let importButton = NSButton(title: "Import DCP profile…", target: nil, action: nil)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let rawTitle = NSTextField(labelWithString: "RAW DECODING")
    private let demosaic = NSPopUpButton(frame: .zero, pullsDown: false)
    private let noise = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colorNoise = NSPopUpButton(frame: .zero, pullsDown: false)
    private let impulse = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rawHelp = NSTextField(wrappingLabelWithString: "Applied while LibRaw develops the file, so each change decodes the RAW again.")
    static let noiseLevels: [(String, Double)] = [("Off", 0), ("Low", 0.2), ("Medium", 0.45), ("High", 1)]
    private var rawRows: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame); orientation = .vertical; alignment = .leading; spacing = 8
        looks.target = self; looks.action = #selector(chooseLook); looks.setAccessibilityLabel("Camera profile")
        importButton.target = self; importButton.action = #selector(importDCP); importButton.bezelStyle = .rounded; importButton.font = .systemFont(ofSize: 11)
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        rawTitle.font = .systemFont(ofSize: 10, weight: .semibold); rawTitle.textColor = .secondaryLabelColor
        rawHelp.font = .systemFont(ofSize: 10); rawHelp.textColor = .secondaryLabelColor
        demosaic.addItems(withTitles: RawDemosaic.allCases.map(\.title))
        noise.addItems(withTitles: Self.noiseLevels.map { "Noise reduction: " + $0.0 })
        colorNoise.addItems(withTitles: ["Color noise: Off", "Color noise: 1 pass", "Color noise: 2 passes", "Color noise: 3 passes"])
        impulse.addItems(withTitles: ["Hot pixels: Off", "Hot pixels: Light", "Hot pixels: Full"])
        for (popup, label) in [(demosaic, "Demosaic method"), (noise, "RAW noise reduction"), (colorNoise, "RAW color noise"), (impulse, "Hot pixel and impulse noise")] {
            popup.target = self; popup.action = #selector(rawChanged); popup.setAccessibilityLabel(label)
        }
        let demosaicRow = NSStackView(views: [NSTextField(labelWithString: "Demosaic"), demosaic]); demosaicRow.distribution = .fill
        rawRows = [rawTitle, demosaicRow, noise, colorNoise, impulse, rawHelp]
        for view in [looks, importButton, detail] + rawRows { addArrangedSubview(view); view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        update(PhotoEdits(), raw: false, enabled: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ edits: PhotoEdits, raw: Bool, enabled: Bool) {
        let profile = edits.profile
        looks.removeAllItems()
        for look in ProfileLook.allCases { looks.addItem(withTitle: look.title); looks.lastItem?.representedObject = "look:" + look.rawValue }
        if profile.dcpAsset != nil {
            looks.menu?.addItem(.separator())
            looks.addItem(withTitle: profile.dcpName ?? "Imported DCP"); looks.lastItem?.representedObject = "dcp"
            looks.selectItem(at: looks.numberOfItems-1)
            detail.stringValue = "Imported DCP: its hue/saturation map, look table and tone curve are applied. Its color matrices are not; OpenStill keeps LibRaw’s camera matrix."
        } else {
            looks.selectItem(at: ProfileLook.allCases.firstIndex(of: profile.look) ?? 0)
            detail.stringValue = profile.look == .standard ? "Standard leaves colors as decoded. Other looks are OpenStill’s own starting points." : "\(profile.look.title) is one of OpenStill’s own looks. Amount below sets its strength."
        }
        let options = edits.rawOptions
        demosaic.selectItem(at: RawDemosaic.allCases.firstIndex(of: options.demosaic) ?? 0)
        noise.selectItem(at: Self.noiseLevels.enumerated().min { abs($0.element.1 - options.noise) < abs($1.element.1 - options.noise) }?.offset ?? 0)
        colorNoise.selectItem(at: options.colorNoise); impulse.selectItem(at: options.impulseNoise)
        rawRows.forEach { $0.isHidden = !raw }
        setEnabled(enabled)
    }
    func setEnabled(_ enabled: Bool) { for control in [looks, importButton, demosaic, noise, colorNoise, impulse] as [NSControl] { control.isEnabled = enabled } }
    @objc private func chooseLook() {
        guard let id = looks.selectedItem?.representedObject as? String, id != "dcp" else { return }
        command?("profile:" + id.dropFirst("look:".count))
    }
    @objc private func importDCP() { command?("importDCP") }
    @objc private func rawChanged() {
        let d = RawDemosaic.allCases[max(0, demosaic.indexOfSelectedItem)].rawValue
        command?("rawOptions:\(d):\(Self.noiseLevels[max(0, noise.indexOfSelectedItem)].1):\(max(0, colorNoise.indexOfSelectedItem)):\(max(0, impulse.indexOfSelectedItem))")
    }
}
