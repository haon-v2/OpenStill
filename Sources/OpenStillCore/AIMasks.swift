import Foundation
import CoreImage
import ImageIO
import Vision

/// Selections made on this Mac with Apple's Vision framework, saved as grayscale mask images in source orientation.
/// Each becomes an ordinary "object" mask component, so it follows crops, lens corrections and Transform.
public enum AIMaskKind: String, CaseIterable, Codable, Sendable {
    case subject, background, people, person, face, eyes, eyebrows, lips, skin, sky, depth
    public var title: String {
        switch self {
        case .subject: return "Subject"
        case .background: return "Background"
        case .people: return "People"
        case .person: return "Person"
        case .face: return "Face"
        case .eyes: return "Eyes"
        case .eyebrows: return "Eyebrows"
        case .lips: return "Lips"
        case .skin: return "Skin"
        case .sky: return "Sky"
        case .depth: return "Depth range"
        }
    }
}

public enum AIMaskError: LocalizedError {
    case nothingFound(String), systemVersion, noDepth
    public var errorDescription: String? {
        switch self {
        case .nothingFound(let what): return "No \(what) was found in this photo."
        case .systemVersion: return "This selection needs macOS 14 or later."
        case .noDepth: return "This photo has no depth information. Portrait-mode HEIC photos from an iPhone include it; for other photos, set up the local AI tools to estimate depth."
        }
    }
}

public enum AIMasks {
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// An 8-bit grayscale image from a mask, scaled to `size`.
    static func grayscale(_ mask: CIImage, size: CGSize) throws -> CGImage {
        let scaled = mask.transformed(by: CGAffineTransform(scaleX: size.width / mask.extent.width, y: size.height / mask.extent.height)
            .concatenating(CGAffineTransform(translationX: -mask.extent.minX * size.width / mask.extent.width, y: -mask.extent.minY * size.height / mask.extent.height)))
        let bounds = CGRect(origin: .zero, size: size)
        guard let cg = context.createCGImage(scaled.cropped(to: bounds), from: bounds, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { throw EditError.render }
        return cg
    }
    static func size(_ image: CGImage) -> CGSize { CGSize(width: image.width, height: image.height) }
    /// Fraction of pixels above half coverage, to reject empty results.
    static func coverage(_ mask: CGImage) -> Double {
        let image = CIImage(cgImage: mask)
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return Double(pixel[0]) / 255
    }

    // MARK: Subject and background

    /// Every foreground object Vision finds, as one mask.
    public static func subject(_ image: CGImage) throws -> CGImage {
        guard #available(macOS 14.0, *) else { throw AIMaskError.systemVersion }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw AIMaskError.nothingFound("subject") }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        return try grayscale(CIImage(cvPixelBuffer: buffer), size: size(image))
    }
    public static func background(_ image: CGImage) throws -> CGImage {
        try grayscale(CIImage(cgImage: subject(image)).applyingFilter("CIColorInvert"), size: size(image))
    }

    // MARK: People

    /// Everyone in the photo, with soft hair edges.
    public static func people(_ image: CGImage) throws -> CGImage {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { throw AIMaskError.nothingFound("person") }
        let mask = try grayscale(CIImage(cvPixelBuffer: buffer), size: size(image))
        guard coverage(mask) > 0.002 else { throw AIMaskError.nothingFound("person") }
        return mask
    }
    /// How many separate people Vision finds (up to four), left to right.
    public static func personCount(_ image: CGImage) throws -> Int {
        guard #available(macOS 14.0, *) else { throw AIMaskError.systemVersion }
        let request = VNGeneratePersonInstanceMaskRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first?.allInstances.count ?? 0
    }
    /// One person, numbered from the left (0-based).
    public static func person(_ image: CGImage, index: Int) throws -> CGImage {
        guard #available(macOS 14.0, *) else { throw AIMaskError.systemVersion }
        let request = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw AIMaskError.nothingFound("person") }
        // Order instances by the horizontal center of their mask.
        var centers: [(Int, Double)] = []
        for instance in observation.allInstances {
            let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler)
            let mask = CIImage(cvPixelBuffer: buffer)
            let small = try grayscale(mask, size: CGSize(width: 64, height: 32))
            centers.append((instance, horizontalCenter(small)))
        }
        let ordered = centers.sorted { $0.1 < $1.1 }.map(\.0)
        guard ordered.indices.contains(index) else { throw AIMaskError.nothingFound("person \(index + 1)") }
        let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: ordered[index]), from: handler)
        return try grayscale(CIImage(cvPixelBuffer: buffer), size: size(image))
    }
    static func horizontalCenter(_ mask: CGImage) -> Double {
        guard let data = mask.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0.5 }
        var total = 0.0, weighted = 0.0
        for y in 0..<mask.height { for x in 0..<mask.width { let v = Double(bytes[y * mask.bytesPerRow + x]); total += v; weighted += v * Double(x) } }
        return total > 0 ? weighted / total / Double(max(1, mask.width - 1)) : 0.5
    }

    // MARK: Faces

    public enum FacePart: String, CaseIterable, Sendable { case face, eyes, eyebrows, lips }
    /// Faces and facial features from Vision's face landmarks, drawn as filled shapes with slightly soft edges.
    public static func face(_ image: CGImage, part: FacePart) throws -> CGImage {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let faces = (request.results ?? []).filter { $0.landmarks != nil }
        guard !faces.isEmpty else { throw AIMaskError.nothingFound("face") }
        let s = size(image), w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw EditError.render }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(origin: .zero, size: s))
        ctx.setFillColor(gray: 1, alpha: 1); ctx.setStrokeColor(gray: 1, alpha: 1); ctx.setLineJoin(.round); ctx.setLineCap(.round)
        for face in faces {
            guard let marks = face.landmarks else { continue }
            let box = VNImageRectForNormalizedRect(face.boundingBox, w, h)
            func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] { region?.pointsInImage(imageSize: s) ?? [] }
            func fill(_ pts: [CGPoint], grow: CGFloat) {
                guard pts.count > 2 else { return }
                ctx.beginPath(); ctx.addLines(between: pts); ctx.closePath()
                ctx.setLineWidth(grow); ctx.drawPath(using: .fillStroke)
            }
            switch part {
            case .face:
                // Jaw line and brows, plus the top of the face box for the forehead.
                var all = points(marks.faceContour) + points(marks.leftEyebrow) + points(marks.rightEyebrow)
                all += [CGPoint(x: box.minX + box.width * 0.2, y: box.maxY), CGPoint(x: box.maxX - box.width * 0.2, y: box.maxY)]
                fill(convexHull(all), grow: box.width * 0.04)
            case .eyes:
                fill(points(marks.leftEye), grow: box.width * 0.03); fill(points(marks.rightEye), grow: box.width * 0.03)
            case .eyebrows:
                for brow in [points(marks.leftEyebrow), points(marks.rightEyebrow)] where brow.count > 1 {
                    ctx.setLineWidth(box.width * 0.045); ctx.beginPath(); ctx.addLines(between: brow); ctx.strokePath()
                }
            case .lips:
                fill(points(marks.outerLips), grow: box.width * 0.015)
            }
        }
        guard let drawn = ctx.makeImage() else { throw EditError.render }
        let soft = CIImage(cgImage: drawn).clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, Double(min(w, h)) / 600)]).cropped(to: CGRect(origin: .zero, size: s))
        return try grayscale(soft, size: s)
    }
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return p }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for q in p { while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }; lower.append(q) }
        for q in p.reversed() { while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }; upper.append(q) }
        return Array(lower.dropLast() + upper.dropLast())
    }

    // MARK: Skin

    /// Skin: people coverage where the color falls in the usual skin-tone range (all complexions share a narrow chroma band).
    public static func skin(_ image: CGImage) throws -> CGImage {
        let person = CIImage(cgImage: try people(image))
        guard let tone = skinKernel?.apply(extent: CGRect(origin: .zero, size: size(image)), arguments: [CIImage(cgImage: image)]) else { throw EditError.render }
        let combined = tone.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: person])
        let mask = try grayscale(combined, size: size(image))
        guard coverage(mask) > 0.001 else { throw AIMaskError.nothingFound("skin") }
        return mask
    }
    static let skinKernel = CIColorKernel(source: """
    kernel vec4 skinTone(__sample s) {
        vec3 c = clamp(unpremultiply(s).rgb, 0.0, 1.0);
        float y = dot(c, vec3(0.299, 0.587, 0.114));
        float cb = 0.5 + dot(c, vec3(-0.168736, -0.331264, 0.5));
        float cr = 0.5 + dot(c, vec3(0.5, -0.418688, -0.081312));
        float inCb = smoothstep(0.27, 0.31, cb) * (1.0 - smoothstep(0.50, 0.54, cb));
        float inCr = smoothstep(0.50, 0.53, cr) * (1.0 - smoothstep(0.68, 0.72, cr));
        float lit = smoothstep(0.06, 0.12, y);
        float v = inCb * inCr * lit;
        return vec4(v, v, v, 1.0);
    }
    """)

    // MARK: Depth

    /// A depth map (near = white) from a photo's own depth data, such as an iPhone Portrait HEIC. Nil when there is none.
    public static func embeddedDepth(_ url: URL, size target: CGSize) -> CGImage? {
        let options: [CIImageOption: Any] = [.auxiliaryDisparity: true, .applyOrientationProperty: true]
        guard let disparity = CIImage(contentsOf: url, options: options) ?? CIImage(contentsOf: url, options: [.auxiliaryDepth: true, .applyOrientationProperty: true]).map({ $0.applyingFilter("CIDepthToDisparity") }) else { return nil }
        return try? normalized(disparity, size: target)
    }
    /// Stretches a disparity map to 0…1 using its own minimum and maximum.
    public static func normalized(_ disparity: CIImage, size target: CGSize) throws -> CGImage {
        let extent = disparity.extent
        let minMax = disparity.applyingFilter("CIAreaMinMax", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var pixels = [Float](repeating: 0, count: 8)
        context.render(minMax, toBitmap: &pixels, rowBytes: 32, bounds: CGRect(x: 0, y: 0, width: 2, height: 1), format: .RGBAf, colorSpace: nil)
        let low = pixels[0], high = max(pixels[4], low + 1e-4)
        let scale = 1 / (high - low)
        let stretched = disparity.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0), "inputBVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: CGFloat(-low * scale), y: CGFloat(-low * scale), z: CGFloat(-low * scale), w: 1)
        ]).applyingFilter("CIColorClamp")
        return try grayscale(stretched, size: target)
    }
    /// A stand-in depth map when a photo has none: the subject (or people) near, everything else far, with a soft falloff.
    public static func subjectDepth(_ image: CGImage) throws -> CGImage {
        let mask: CGImage
        if let found = try? subject(image) { mask = found } else { mask = try people(image) }
        let s = size(image)
        let soft = CIImage(cgImage: mask).clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Double(min(s.width, s.height)) * 0.01]).cropped(to: CGRect(origin: .zero, size: s))
        return try grayscale(soft, size: s)
    }
}
