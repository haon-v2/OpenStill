import AppKit
import OpenStillCore

/// Sits behind the photo canvas and shows the photo in GPU layers, so Core Animation scales and composites it
/// (the canvas only draws its overlays and leaves the photo's rectangle clear). The same layers show HDR renders in
/// extended dynamic range. When zoomed in, a sharper render of the visible part sits over the whole-frame image.
final class PhotoBackdrop: NSView {
    private let imageLayer = CALayer()
    private let detailLayer = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
        layer?.masksToBounds = true   // a zoomed-in photo is larger than the view; it must not spill over the bars around it
        for l in [imageLayer, detailLayer] {
            l.contentsGravity = .resize
            l.isHidden = true
            l.minificationFilter = .trilinear
            if #available(macOS 14, *) { l.wantsExtendedDynamicRangeContent = true }
            layer?.addSublayer(l)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { false }
    /// Shows `image` filling `rect`, and `detail` (0–1 of the photo, from the bottom left) over its part of it.
    func show(_ image: CGImage?, in rect: CGRect, detail: (image: CGImage, region: CGRect)? = nil, crisp: Bool = false) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if (imageLayer.contents as AnyObject?) !== image { imageLayer.contents = image }
        imageLayer.frame = rect; imageLayer.isHidden = image == nil
        imageLayer.magnificationFilter = crisp ? .nearest : .linear
        if let detail, image != nil {
            if (detailLayer.contents as AnyObject?) !== detail.image { detailLayer.contents = detail.image }
            detailLayer.frame = CGRect(x: rect.minX + detail.region.minX * rect.width, y: rect.minY + detail.region.minY * rect.height,
                                       width: detail.region.width * rect.width, height: detail.region.height * rect.height)
            detailLayer.magnificationFilter = crisp ? .nearest : .linear
            detailLayer.isHidden = false
        } else { detailLayer.isHidden = true; detailLayer.contents = nil }
        CATransaction.commit()
    }
    /// HDR previews need macOS 14 and a display that can show brighter than SDR white.
    static var hdrAvailable: Bool {
        guard #available(macOS 14, *) else { return false }
        return (NSScreen.screens.map(\.maximumPotentialExtendedDynamicRangeColorComponentValue).max() ?? 1) > 1.01
    }
}
