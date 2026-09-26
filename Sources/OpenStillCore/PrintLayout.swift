import Foundation
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Paper in points (1/72 inch), portrait.
public struct PaperSize: Codable, Equatable, Sendable {
    public var name: String, width: Double, height: Double
    public init(name: String, width: Double, height: Double) { self.name = name; self.width = width; self.height = height }
    public static let letter = PaperSize(name: "US Letter", width: 612, height: 792)
    public static let a4 = PaperSize(name: "A4", width: 595.28, height: 841.89)
    public static let a3 = PaperSize(name: "A3", width: 841.89, height: 1190.55)
    public static let photo4x6 = PaperSize(name: "4 × 6 in", width: 288, height: 432)
    public static let photo5x7 = PaperSize(name: "5 × 7 in", width: 360, height: 504)
    public static let photo8x10 = PaperSize(name: "8 × 10 in", width: 576, height: 720)
    public static let photo13x19 = PaperSize(name: "13 × 19 in", width: 936, height: 1368)
    public static let all: [PaperSize] = [.letter, .a4, .a3, .photo4x6, .photo5x7, .photo8x10, .photo13x19]
}

public enum PrintStyle: String, Codable, CaseIterable, Sendable {
    /// One photo per page, as large as fits.
    case single
    /// Many small photos with file names, for picking and archiving.
    case contactSheet
    /// Your own rows and columns.
    case grid
    public var title: String { self == .single ? "Single photo" : self == .contactSheet ? "Contact sheet" : "Custom grid" }
}
public enum PrintSharpening: String, Codable, CaseIterable, Sendable {
    case none, low, standard, high
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var amount: Double { switch self { case .none: return 0; case .low: return 0.25; case .standard: return 0.5; case .high: return 0.9 } }
}
public enum PrintCaption: String, Codable, CaseIterable, Sendable {
    case none, filename, title
    public var title: String { self == .none ? "No captions" : self == .filename ? "File name" : "Title (or file name)" }
}

public struct PrintLayout: Codable, Equatable {
    public var style = PrintStyle.single
    public var paper = PaperSize.letter
    public var landscape = false
    /// Margins and spacing between photos, in points.
    public var margin = 36.0, spacing = 12.0
    public var rows = 2, columns = 2
    public var caption = PrintCaption.none
    public var sharpening = PrintSharpening.standard
    /// Resolution photos are rendered at for printing.
    public var dpi = 300
    /// Printer/paper ICC profile asset (RGB), or nil for sRGB.
    public var profileAsset: String?
    public var intent = RenderingIntent.perceptual
    public init() {}
    public var sanitized: Self {
        var s = self
        func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double { v.isFinite ? min(hi, max(lo, v)) : fallback }
        s.margin = clamp(margin, 0, 144, 36); s.spacing = clamp(spacing, 0, 72, 12)
        s.rows = min(12, max(1, rows)); s.columns = min(10, max(1, columns)); s.dpi = min(720, max(72, dpi))
        if !(paper.width.isFinite && paper.height.isFinite && paper.width >= 72 && paper.height >= 72 && paper.width <= 4000 && paper.height <= 4000) { s.paper = .letter }
        return s
    }
    /// Page size in points after orientation.
    public var pageSize: CGSize { landscape ? CGSize(width: paper.height, height: paper.width) : CGSize(width: paper.width, height: paper.height) }
    public var grid: (rows: Int, columns: Int) {
        switch style {
        case .single: return (1, 1)
        case .contactSheet: return landscape ? (4, 6) : (6, 4)
        case .grid: return (rows, columns)
        }
    }
    public var perPage: Int { grid.rows * grid.columns }
    var effectiveCaption: PrintCaption { style == .contactSheet && caption == .none ? .filename : caption }
}

public struct PrintItem {
    public var image: CIImage
    public var filename: String
    public var title: String
    public init(image: CIImage, filename: String, title: String = "") { self.image = image; self.filename = filename; self.title = title }
    var label: String { title.isEmpty ? filename : title }
}

public enum PrintLayoutEngine {
    static let captionHeight = 14.0
    /// Photo cells on a page, in PDF coordinates (origin bottom left), filled row by row from the top.
    public static func cells(_ layout: PrintLayout) -> [CGRect] {
        let l = layout.sanitized, page = l.pageSize, (rows, columns) = l.grid
        let caption = l.effectiveCaption == .none ? 0 : captionHeight
        let width = (page.width - 2 * l.margin - Double(columns - 1) * l.spacing) / Double(columns)
        let height = (page.height - 2 * l.margin - Double(rows - 1) * l.spacing) / Double(rows)
        guard width > 4, height > caption + 4 else { return [] }
        var out: [CGRect] = []
        for row in 0..<rows { for column in 0..<columns {
            let x = l.margin + Double(column) * (width + l.spacing)
            let top = page.height - l.margin - Double(row) * (height + l.spacing)
            out.append(CGRect(x: x, y: top - height, width: width, height: height))
        } }
        return out
    }
    /// Pages as lists of item indices.
    public static func pages(count: Int, layout: PrintLayout) -> [[Int]] {
        let per = max(1, layout.sanitized.perPage)
        return stride(from: 0, to: count, by: per).map { Array($0..<min(count, $0 + per)) }
    }
    /// The largest rectangle with the image's aspect ratio centred in `cell` (leaving room for a caption).
    public static func fit(_ size: CGSize, in cell: CGRect, caption: Bool) -> CGRect {
        var area = cell
        if caption { area.origin.y += captionHeight; area.size.height -= captionHeight }
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / size.width, area.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }
    /// Output colour space: the printer profile when it's an RGB profile, else sRGB.
    public static func colorSpace(_ layout: PrintLayout) -> CGColorSpace {
        if let asset = layout.profileAsset, let data = try? Data(contentsOf: EditStorage.asset(asset)),
           let space = CGColorSpace(iccData: data as CFData), space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }
    /// Scales a photo to the pixels its printed size needs and applies output sharpening.
    public static func prepare(_ image: CIImage, printedSize: CGSize, layout: PrintLayout) -> CIImage {
        let l = layout.sanitized
        let pixels = max(printedSize.width, printedSize.height) / 72 * Double(l.dpi)
        var out = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = pixels / max(out.extent.width, out.extent.height)
        if scale < 1 { out = out.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1]) }
        let amount = l.sharpening.amount
        if amount > 0 {
            // Radius grows with resolution so the effect looks the same at 240 or 360 dpi.
            let extent = out.extent
            out = out.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: Double(l.dpi) / 300 * 1.2, kCIInputIntensityKey: amount]).cropped(to: extent)
        }
        return out
    }
    /// Draws one page into a context whose units are points.
    static func drawPage(_ indices: [Int], items: [PrintItem], layout: PrintLayout, in context: CGContext, space: CGColorSpace) throws {
        let l = layout.sanitized, cells = cells(l), captioned = l.effectiveCaption != .none
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: l.pageSize))
        let intents: [RenderingIntent: CGColorRenderingIntent] = [.perceptual: .perceptual, .relative: .relativeColorimetric, .saturation: .saturation, .absolute: .absoluteColorimetric]
        context.setRenderingIntent(intents[l.intent] ?? .perceptual)
        for (slot, index) in indices.enumerated() where slot < cells.count {
            let item = items[index]
            let frame = fit(item.image.extent.size, in: cells[slot], caption: captioned)
            guard frame.width > 0 else { continue }
            let prepared = prepare(item.image, printedSize: frame.size, layout: l)
            guard let cg = ModernRenderer.context.createCGImage(prepared, from: prepared.extent, format: .RGBA8, colorSpace: space) else { throw EditError.render }
            context.interpolationQuality = .high
            context.draw(cg, in: frame)
            if captioned { drawCaption(l.effectiveCaption == .title ? item.label : item.filename, below: frame, cell: cells[slot], in: context) }
        }
    }
    static func drawCaption(_ text: String, below frame: CGRect, cell: CGRect, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 8, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.2, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attributed)
        let truncated = CTLineCreateTruncatedLine(line, cell.width, .middle, CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))) ?? line
        let width = CTLineGetTypographicBounds(truncated, nil, nil, nil)
        context.textPosition = CGPoint(x: cell.midX - width / 2, y: frame.minY - 10)
        CTLineDraw(truncated, context)
    }
    /// A print-ready PDF with every page.
    public static func pdf(_ items: [PrintItem], layout: PrintLayout, to url: URL) throws {
        let l = layout.sanitized, space = colorSpace(l)
        var box = CGRect(origin: .zero, size: l.pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextCreator as String: "OpenStill"] as CFDictionary) else { throw EditError.render }
        for page in pages(count: items.count, layout: l) {
            context.beginPDFPage(nil)
            try drawPage(page, items: items, layout: l, in: context, space: space)
            context.endPDFPage()
        }
        context.closePDF()
    }
    /// One page as an image at the layout's resolution (for "print to JPEG" and previews).
    public static func pageImage(_ page: [Int], items: [PrintItem], layout: PrintLayout, dpi: Int? = nil) throws -> CGImage {
        var l = layout.sanitized; if let dpi { l.dpi = dpi }
        let space = colorSpace(l), scale = Double(l.dpi) / 72
        let w = Int((l.pageSize.width * scale).rounded()), h = Int((l.pageSize.height * scale).rounded())
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw EditError.render }
        context.scaleBy(x: scale, y: scale)
        try drawPage(page, items: items, layout: l, in: context, space: space)
        guard let image = context.makeImage() else { throw EditError.render }
        return image
    }
    /// Writes each page as a JPEG in `folder` ("Print-1.jpg", …) and returns the files.
    public static func jpegs(_ items: [PrintItem], layout: PrintLayout, to folder: URL, name: String = "Print") throws -> [URL] {
        try pages(count: items.count, layout: layout).enumerated().map { number, page in
            let image = try pageImage(page, items: items, layout: layout)
            var url = folder.appendingPathComponent("\(name)-\(number + 1).jpg"), n = 2
            while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(name)-\(number + 1)-\(n).jpg"); n += 1 }
            guard let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw EditError.render }
            let dpi = Double(layout.sanitized.dpi)
            CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.95, kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
            guard CGImageDestinationFinalize(writer) else { throw EditError.render }
            return url
        }
    }
}
