import AppKit
import OpenStillCore

/// Upright mode buttons and a readout of what Upright applied.
final class TransformPanel: NSStackView {
    var command: ((String) -> Void)?
    /// Two rows of three, so the labels fit the panel width.
    private let rows = [Array(UprightMode.allCases.prefix(3)), Array(UprightMode.allCases.suffix(3))]
    private lazy var modes = rows.map { NSSegmentedControl(labels: $0.map(\.title), trackingMode: .selectOne, target: nil, action: nil) }
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let clear = NSButton(title: "Clear guides", target: nil, action: nil)
    override init(frame: NSRect) {
        super.init(frame: frame); orientation = .vertical; alignment = .leading; spacing = 8
        let title = NSTextField(labelWithString: "UPRIGHT"); title.font = .systemFont(ofSize: 10, weight: .semibold); title.textColor = .secondaryLabelColor
        for (row, control) in modes.enumerated() {
            control.target = self; control.action = #selector(choose(_:)); control.tag = row; control.controlSize = .small; control.segmentStyle = .rounded
            control.segmentDistribution = .fillEqually; control.setAccessibilityLabel("Upright mode")
            for (i, mode) in rows[row].enumerated() { control.setToolTip(Self.help(mode), forSegment: i) }
        }
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        clear.target = self; clear.action = #selector(clearGuides); clear.bezelStyle = .rounded; clear.font = .systemFont(ofSize: 11)
        for view in ([title] as [NSView]) + modes + [detail, clear] { addArrangedSubview(view); view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        update(TransformSettings(), enabled: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    private static func help(_ mode: UprightMode) -> String {
        switch mode {
        case .off: return "No automatic perspective correction."
        case .auto: return "Balanced level, vertical and gentle horizontal correction."
        case .level: return "Rotate so horizontal lines are level."
        case .vertical: return "Level, and make vertical lines parallel."
        case .full: return "Level, vertical and horizontal perspective."
        case .guided: return "Draw 2–4 lines on the photo that should be vertical or horizontal."
        }
    }
    func update(_ settings: TransformSettings, enabled: Bool) {
        let mode = settings.upright?.mode ?? .off
        for (row, control) in modes.enumerated() { control.selectedSegment = rows[row].firstIndex(of: mode) ?? -1; control.isEnabled = enabled }
        clear.isEnabled = enabled && settings.guides?.isEmpty == false
        clear.isHidden = settings.guides?.isEmpty != false && mode != .guided
        if let u = settings.upright {
            func n(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(2))) }
            detail.stringValue = "\(u.mode.title): rotate \(n(u.rotate))°, vertical \(n(u.vertical)), horizontal \(n(u.horizontal)). The sliders below add to it."
        } else {
            detail.stringValue = Self.help(mode)
        }
    }
    func setEnabled(_ enabled: Bool) { modes.forEach { $0.isEnabled = enabled }; clear.isEnabled = enabled }
    @objc private func choose(_ sender: NSSegmentedControl) {
        guard rows[sender.tag].indices.contains(sender.selectedSegment) else { return }
        for other in modes where other !== sender { other.selectedSegment = -1 }
        command?("upright:" + rows[sender.tag][sender.selectedSegment].rawValue)
    }
    @objc private func clearGuides() { command?("clearGuides") }
}
