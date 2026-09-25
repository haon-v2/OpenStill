import AppKit
import OpenStillCore

final class CropPresetPanel: NSStackView {
    var changed: (() -> Void)?
    private let preset = NSPopUpButton(frame:.zero,pullsDown:false)
    private let swap = NSButton(title:"Swap horizontal ↔ vertical",target:nil,action:nil)
    private let readout = NSTextField(wrappingLabelWithString:"")
    private let warning = NSTextField(wrappingLabelWithString:"")
    private enum Choice { case freeform, original, preset(CropPreset) }
    private var choices: [Choice] = []
    override init(frame:NSRect) {
        super.init(frame:frame)
        orientation = .vertical; alignment = .leading; spacing = 10
        let label = NSTextField(labelWithString:"Crop preset"); label.font = .systemFont(ofSize:11,weight:.medium)
        preset.font = .systemFont(ofSize:11); preset.target = self; preset.action = #selector(selectPreset)
        preset.setAccessibilityLabel("Crop preset")
        buildMenu()
        swap.bezelStyle = .rounded; swap.controlSize = .small; swap.font = .systemFont(ofSize:11)
        swap.target = self; swap.action = #selector(swapOrientation)
        swap.setAccessibilityLabel("Switch between the horizontal and vertical version of this preset")
        readout.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium); readout.setAccessibilityLabel("Crop size and aspect ratio")
        warning.font = .systemFont(ofSize:11); warning.textColor = .systemOrange; warning.isHidden = true
        let hint = NSTextField(wrappingLabelWithString:"Drag the frame to compose. Drag a corner to resize. Cropping keeps source detail; choose output pixel dimensions in Export.")
        hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor
        for view in [label,preset,swap,readout,warning,hint] {
            view.translatesAutoresizingMaskIntoConstraints = false; addArrangedSubview(view); view.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        }
        showCrop(selection:nil,photo:nil)
        setEnabled(false)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    private func buildMenu() {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title:String,_ choice:Choice) { menu.addItem(withTitle:title,action:nil,keyEquivalent:""); choices.append(choice) }
        func header(_ title:String) {
            menu.addItem(.separator()); choices.append(.freeform)
            let item = NSMenuItem(title:title,action:nil,keyEquivalent:""); item.isEnabled = false
            item.attributedTitle = NSAttributedString(string:title.uppercased(),attributes:[.font:NSFont.systemFont(ofSize:10,weight:.semibold),.foregroundColor:NSColor.secondaryLabelColor])
            menu.addItem(item); choices.append(.freeform)
        }
        add("Freeform",.freeform)
        add("Original proportions",.original)
        header("Square"); for p in CropPreset.square { add(p.title,.preset(p)) }
        header("Horizontal"); for p in CropPreset.horizontal { add(p.title,.preset(p)) }
        header("Vertical"); for p in CropPreset.vertical { add(p.title,.preset(p)) }
        preset.menu = menu
    }
    private var selectedPreset: CropPreset? {
        guard choices.indices.contains(preset.indexOfSelectedItem), case .preset(let p) = choices[preset.indexOfSelectedItem] else {return nil}
        return p
    }
    func aspect(for size:CGSize) -> Double? {
        guard choices.indices.contains(preset.indexOfSelectedItem) else {return nil}
        switch choices[preset.indexOfSelectedItem] {
        case .freeform: return nil
        case .original: return size.width/max(1,size.height)
        case .preset(let p): return p.aspect
        }
    }
    /// Shows the live crop size, or the photo being cropped before a frame is drawn.
    func showCrop(selection:CGSize?,photo:CGSize?) {
        warning.isHidden = true
        if let selection {
            let w = Int(selection.width.rounded()), h = Int(selection.height.rounded())
            readout.stringValue = "Crop  " + CropGeometry.sizeLabel(width:w,height:h)
            if let p = selectedPreset, !p.isFilled(byWidth:w,height:h) {
                warning.stringValue = "Smaller than \(p.width) × \(p.height). Exporting at that size will enlarge the photo."
                warning.isHidden = false
            }
        } else if let photo {
            readout.stringValue = "Photo  " + CropGeometry.sizeLabel(width:Int(photo.width.rounded()),height:Int(photo.height.rounded()))
        } else {
            readout.stringValue = "Choose a preset or Draw crop to see the size and aspect ratio."
        }
        readout.toolTip = readout.stringValue
    }
    private func updateSwap() { swap.isEnabled = preset.isEnabled && selectedPreset?.rotated != nil }
    @objc private func selectPreset() {updateSwap(); changed?()}
    @objc private func swapOrientation() {
        guard let target = selectedPreset?.rotated,
              let index = choices.firstIndex(where:{ if case .preset(let p) = $0 { return p == target }; return false }) else {return}
        preset.selectItem(at:index); updateSwap(); changed?()
    }
    func setEnabled(_ enabled:Bool) {preset.isEnabled = enabled; updateSwap()}
}
