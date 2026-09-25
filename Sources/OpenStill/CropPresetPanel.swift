import AppKit
import OpenStillCore

final class CropPresetPanel: NSStackView {
    var changed: (() -> Void)?
    private let preset = NSPopUpButton(frame:.zero,pullsDown:false)
    private let orientationPicker = NSSegmentedControl(labels:["Landscape","Portrait"],trackingMode:.selectOne,target:nil,action:nil)
    private let ratios: [Double?] = [nil,nil,1,1.5,4.0/3,1.25,16.0/9,21.0/9]
    override init(frame:NSRect) {
        super.init(frame:frame)
        orientation = .vertical; alignment = .leading; spacing = 10
        let label = NSTextField(labelWithString:"Crop preset"); label.font = .systemFont(ofSize:11,weight:.medium)
        preset.addItems(withTitles:["Freeform","Original proportions","Square · 1:1","Photo · 3:2","Standard · 4:3","Print · 5:4","Widescreen · 16:9","Cinema · 21:9"])
        preset.font = .systemFont(ofSize:11); preset.target = self; preset.action = #selector(selectPreset)
        preset.setAccessibilityLabel("Crop preset")
        orientationPicker.selectedSegment = 0; orientationPicker.controlSize = .small
        orientationPicker.target = self; orientationPicker.action = #selector(selectOrientation)
        orientationPicker.setAccessibilityLabel("Crop orientation")
        let hint = NSTextField(wrappingLabelWithString:"Choose portrait or landscape, then drag the frame to compose. Drag a corner to resize. Cropping keeps source detail; choose output pixel dimensions in Export.")
        hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor
        for view in [label,preset,orientationPicker,hint] {
            view.translatesAutoresizingMaskIntoConstraints = false; addArrangedSubview(view); view.widthAnchor.constraint(equalTo:widthAnchor).isActive = true
        }
        setEnabled(false)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    func aspect(for size:CGSize) -> Double? {
        let index = preset.indexOfSelectedItem
        guard ratios.indices.contains(index),index != 0 else {return nil}
        if index == 1 {return size.width/max(1,size.height)}
        guard let ratio = ratios[index] else {return nil}
        return orientationPicker.selectedSegment == 1 ? 1/ratio:ratio
    }
    private func updateTitles() {
        let portrait = orientationPicker.selectedSegment == 1
        let labels = portrait ? ["Photo · 2:3","Standard · 3:4","Print · 4:5","Widescreen · 9:16","Cinema · 9:21"] : ["Photo · 3:2","Standard · 4:3","Print · 5:4","Widescreen · 16:9","Cinema · 21:9"]
        for (i,label) in labels.enumerated() {preset.item(at:i+3)?.title = label}
        orientationPicker.isEnabled = preset.isEnabled && preset.indexOfSelectedItem > 2
    }
    @objc private func selectPreset() {updateTitles(); changed?()}
    @objc private func selectOrientation() {updateTitles(); changed?()}
    func setEnabled(_ enabled:Bool) {preset.isEnabled = enabled; updateTitles()}
}
