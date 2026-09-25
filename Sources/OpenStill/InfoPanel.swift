import AppKit
import OpenStillCore

private final class TopAlignedStack: NSStackView {
    override var isFlipped: Bool { true }
}

final class InfoPanel: NSView {
    private let stack = TopAlignedStack()
    private var fields: [String: NSTextField] = [:]
    private let allMetadata = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 24, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        let title = NSTextField(labelWithString: "Photo Info")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        for name in ["Camera", "Lens", "Source preview", "Shutter speed", "Aperture", "ISO", "Focal length", "35mm equivalent", "Exposure compensation", "Captured", "Dimensions", "File"] {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 4
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let value = NSTextField(wrappingLabelWithString: "—")
            value.font = .systemFont(ofSize: 13, weight: .medium)
            value.isSelectable = true
            value.setAccessibilityLabel(name)
            row.addArrangedSubview(label)
            row.addArrangedSubview(value)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            value.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            fields[name] = value
        }
        let detail = NSButton(title: "All recorded metadata ▾", target: self, action: #selector(toggleAll))
        detail.isBordered = false; detail.alignment = .left; detail.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(detail)
        allMetadata.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        allMetadata.textColor = .secondaryLabelColor; allMetadata.isSelectable = true
        allMetadata.isHidden = true; stack.addArrangedSubview(allMetadata)
        allMetadata.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggleAll() { allMetadata.isHidden.toggle() }

    func show(_ metadata: PhotoMetadata?, rendering: String? = nil) {
        let values: [String: String] = metadata.map { m in [
            "Camera": m.camera, "Lens": m.lens, "Shutter speed": m.shutter,
            "Aperture": m.aperture, "ISO": m.iso, "Focal length": m.focalLength,
            "35mm equivalent": m.focalLength35mm, "Exposure compensation": m.exposureBias,
            "Captured": m.captured, "Dimensions": m.dimensions, "File": "\(m.format) · \(m.fileSize)"
        ] } ?? [:]
        for (key, field) in fields { field.stringValue = key == "Source preview" ? (rendering ?? "—") : (values[key] ?? "—") }
        allMetadata.stringValue = metadata?.allFields.joined(separator: "\n\n") ?? "No metadata loaded."
    }
}
