import AppKit
import OpenStillCore

/// Sits behind the photo canvas and shows the HDR render in an extended-dynamic-range layer.
/// The canvas leaves the photo's rectangle transparent and keeps drawing its overlays on top.
final class HDRBackdrop: NSView {
    private let imageLayer = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.isHidden = true
        if #available(macOS 14, *) { imageLayer.wantsExtendedDynamicRangeContent = true }
        layer?.addSublayer(imageLayer)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { false }
    func show(_ image: CGImage?, in rect: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.frame = rect; imageLayer.isHidden = image == nil
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
    /// HDR previews need macOS 14 and a display that can show brighter than SDR white.
    static var available: Bool {
        guard #available(macOS 14, *) else { return false }
        return (NSScreen.screens.map(\.maximumPotentialExtendedDynamicRangeColorComponentValue).max() ?? 1) > 1.01
    }
    /// Stops of headroom the brightest display offers right now (0 on SDR displays).
    static var currentHeadroom: Double {
        let value = NSScreen.screens.map(\.maximumExtendedDynamicRangeColorComponentValue).max() ?? 1
        return log2(max(1, Double(value)))
    }
}
