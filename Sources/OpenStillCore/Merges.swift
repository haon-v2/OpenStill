import Foundation
import CoreImage
import ImageIO
import Vision
import simd

/// HDR merge, panorama and focus stacking. Photos are aligned with Vision's homographic registration,
/// merged in linear light, and written as a 16-bit float TIFF next to the originals.
public enum MergeKind: String, CaseIterable, Sendable {
    case hdr, panorama, focusStack
    public var title: String {
        switch self { case .hdr: return "HDR"; case .panorama: return "Panorama"; case .focusStack: return "Focus stack" }
    }
    var suffix: String {
        switch self { case .hdr: return "HDR"; case .panorama: return "Pano"; case .focusStack: return "Stack" }
    }
}
public enum PanoramaProjection: String, CaseIterable, Sendable {
    case cylindrical, perspective
    public var title: String { self == .cylindrical ? "Cylindrical" : "Perspective" }
}
public struct MergeOptions: Sendable {
    /// Align hand-held shots. Off assumes a tripod (HDR and focus stacks only).
    public var align = true
    /// 0…1: how strongly moving things are taken from one exposure only (HDR).
    public var deghost = 0.5
    public var projection = PanoramaProjection.cylindrical
    /// Crop the panorama to the largest rectangle with no empty edges.
    public var autoCrop = true
    /// Largest panorama in pixels; bigger results are scaled down.
    public var maximumPixels = 150_000_000
    public init() {}
}
public enum MergeError: LocalizedError, Equatable {
    case tooFew, unreadable(String), noOverlap(String, String), tooLarge
    public var errorDescription: String? {
        switch self {
        case .tooFew: return "Select at least two photos to merge."
        case .unreadable(let name): return "\(name) couldn’t be read."
        case .noOverlap(let a, let b): return "\(a) and \(b) couldn’t be aligned. Panorama frames need to overlap by about a third, in the order they were taken."
        case .tooLarge: return "The aligned photos don’t fit together. Check that they’re from the same scene."
        }
    }
}

public enum Merges {
    static let context = ModernRenderer.context
    static let luma = SIMD3<Float>(0.2627, 0.6780, 0.0593)   // Rec. 2020, the working space

    // MARK: Entry point

    /// Merges the photos (in order) and writes a float TIFF next to the first one. Returns the new file.
    public static func merge(_ urls: [URL], kind: MergeKind, options: MergeOptions = MergeOptions(), progress: ((String) -> Void)? = nil) throws -> URL {
        guard urls.count >= 2 else { throw MergeError.tooFew }
        progress?("Reading \(urls.count) photos…")
        var images: [CIImage] = []
        for url in urls {
            let mode: SourceMode = RawDecoder.isRAW(url) ? .raw : .original
            guard let image = try? ModernRenderer.source(url, mode: mode) else { throw MergeError.unreadable(url.lastPathComponent) }
            images.append(image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)))
        }
        let names = urls.map(\.lastPathComponent)
        let result: CIImage
        switch kind {
        case .hdr: result = try hdr(images, names: names, exposures: urls.map(exposureValue), options: options, progress: progress)
        case .focusStack: result = try focusStack(images, names: names, options: options, progress: progress)
        case .panorama: result = try panorama(images, names: names, focalLengths: urls.map(focalLength35mm), options: options, progress: progress)
        }
        progress?("Writing the merged photo…")
        let reference = urls[referenceIndex(urls.count)]
        let destination = outputURL(for: urls[0], kind: kind)
        try writeFloatTIFF(result, to: destination, metadataFrom: reference)
        return destination
    }
    static func referenceIndex(_ count: Int) -> Int { count / 2 }
    /// "<first photo>-HDR.tif", never replacing an existing file.
    public static func outputURL(for first: URL, kind: MergeKind) -> URL {
        let folder = first.deletingLastPathComponent(), base = first.deletingPathExtension().lastPathComponent + "-" + kind.suffix
        var candidate = folder.appendingPathComponent(base + ".tif"), n = 2
        while FileManager.default.fileExists(atPath: candidate.path) { candidate = folder.appendingPathComponent("\(base)-\(n).tif"); n += 1 }
        return candidate
    }

    // MARK: HDR

    public static func hdr(_ images: [CIImage], names: [String]? = nil, exposures: [Double?]? = nil, options: MergeOptions = MergeOptions(), progress: ((String) -> Void)? = nil) throws -> CIImage {
        guard images.count >= 2 else { throw MergeError.tooFew }
        let names = names ?? images.indices.map { "Photo \($0 + 1)" }
        let proxies = images.map { Proxy($0) }
        // The middle brightness is the reference: it has the most usable pixels to align and compare against.
        let order = proxies.indices.sorted { proxies[$0].median < proxies[$1].median }
        let r = order[order.count / 2]
        var transforms = [double3x3](repeating: matrix_identity_double3x3, count: images.count)
        var scales = [Double](repeating: 1, count: images.count)
        for i in images.indices where i != r {
            progress?("Aligning \(names[i])…")
            let h = options.align ? align(proxies[i], to: proxies[r]) ?? matrix_identity_double3x3 : matrix_identity_double3x3
            transforms[i] = h
            scales[i] = exposureRatio(proxies[i], to: proxies[r], transform: h)
                ?? both(exposures?[r] ?? nil, exposures?[i] ?? nil).map { $0.0 / $0.1 } ?? proxies[r].median / max(proxies[i].median, 1e-6)
        }
        progress?("Merging exposures…")
        let extent = images[r].extent
        let darkest = scales.indices.max { scales[$0] < scales[$1] }!    // needs the most gain: shortest exposure
        let brightest = scales.indices.min { scales[$0] < scales[$1] }!
        var sum = zero(extent), weights = zero(extent)
        for i in images.indices {
            let full = fullResolution(transforms[i], from: proxies[i], to: proxies[r])
            let warped = try warp(images[i], full, extent: extent)
            let coverage = try warp(images[i], full, extent: extent, feather: 0)
            guard let w = hdrWeight?.apply(extent: extent, arguments: [warped, coverage, images[r], scales[i], i == brightest ? 1.0 : 0.0, i == darkest ? 1.0 : 0.0, options.deghost, i == r ? 1.0 : 0.0]) else { throw EditError.render }
            sum = try accumulate(sum, warped, w, scale: scales[i]); weights = try add(weights, w)
        }
        return try divide(sum, weights)
    }
    /// Weight of one exposure: well-exposed pixels count most; the brightest frame owns the shadows and the darkest the highlights.
    /// Pixels that disagree with the reference (something moved) are taken from the reference instead.
    static let hdrWeight = CIColorKernel(source: """
    kernel vec4 hdrWeight(__sample img, __sample cov, __sample ref, float scale, float lowOpen, float highOpen, float deghost, float isRef) {
        float v = max(img.r, max(img.g, img.b));
        float low = lowOpen > 0.5 ? 1.0 : smoothstep(0.002, 0.04, v);
        float high = highOpen > 0.5 ? 1.0 : 1.0 - smoothstep(0.80, 0.97, v);
        float w = max(low * high, 0.0005);
        if (isRef < 0.5 && deghost > 0.0) {
            float rv = max(ref.r, max(ref.g, ref.b));
            float valid = smoothstep(0.01, 0.04, rv) * (1.0 - smoothstep(0.85, 0.97, rv)) * low * high;
            vec3 k = vec3(0.2627, 0.6780, 0.0593);
            float d = abs(log2((dot(img.rgb, k) * scale + 0.0001) / (dot(ref.rgb, k) + 0.0001)));
            w *= 1.0 - clamp(deghost, 0.0, 1.0) * valid * smoothstep(0.4, 1.2, d);
        }
        w *= cov.r;
        return vec4(w, w, w, 1.0);
    }
    """)

    // MARK: Focus stacking

    public static func focusStack(_ images: [CIImage], names: [String]? = nil, options: MergeOptions = MergeOptions(), progress: ((String) -> Void)? = nil) throws -> CIImage {
        guard images.count >= 2 else { throw MergeError.tooFew }
        let names = names ?? images.indices.map { "Photo \($0 + 1)" }
        let proxies = images.map { Proxy($0) }
        let r = referenceIndex(images.count), extent = images[r].extent
        let radius = max(1.5, min(extent.width, extent.height) * 0.003)
        var sum = zero(extent), weights = zero(extent)
        for i in images.indices {
            progress?(i == r ? "Measuring sharpness…" : "Aligning \(names[i])…")
            let h = i == r || !options.align ? matrix_identity_double3x3 : align(proxies[i], to: proxies[r]) ?? matrix_identity_double3x3
            let full = fullResolution(h, from: proxies[i], to: proxies[r])
            let warped = try warp(images[i], full, extent: extent)
            let coverage = try warp(images[i], full, extent: extent, feather: 0)
            let w = try sharpness(warped, coverage: coverage, radius: radius)
            sum = try accumulate(sum, warped, w, scale: 1); weights = try add(weights, w)
        }
        return try divide(sum, weights)
    }
    /// Local detail energy: |Laplacian| of perceptual luminance, smoothed, raised to a power so the sharpest frame wins.
    static func sharpness(_ image: CIImage, coverage: CIImage, radius: Double) throws -> CIImage {
        let extent = image.extent
        guard let gray = perceptual?.apply(extent: extent, arguments: [image]) else { throw EditError.render }
        let laplacian = gray.clampedToExtent().applyingFilter("CIConvolution3X3", parameters: [kCIInputWeightsKey: CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9), kCIInputBiasKey: 0]).cropped(to: extent)
        guard let magnitude = absolute?.apply(extent: extent, arguments: [laplacian]) else { throw EditError.render }
        let energy = magnitude.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        guard let w = focusWeight?.apply(extent: extent, arguments: [energy, coverage]) else { throw EditError.render }
        return w
    }
    static let perceptual = CIColorKernel(source: "kernel vec4 perceptualLuma(__sample s) { float y = sqrt(max(dot(s.rgb, vec3(0.2627, 0.6780, 0.0593)), 0.0)); return vec4(y, y, y, 1.0); }")
    static let absolute = CIColorKernel(source: "kernel vec4 absoluteValue(__sample s) { return vec4(abs(s.rgb), 1.0); }")
    static let focusWeight = CIColorKernel(source: """
    kernel vec4 focusWeight(__sample e, __sample cov) {
        float x = e.r * 40.0;
        float w = (x * x * x * x + 0.000001) * cov.r;
        return vec4(w, w, w, 1.0);
    }
    """)

    // MARK: Panorama

    public static func panorama(_ images: [CIImage], names: [String]? = nil, focalLengths: [Double?]? = nil, options: MergeOptions = MergeOptions(), progress: ((String) -> Void)? = nil) throws -> CIImage {
        guard images.count >= 2 else { throw MergeError.tooFew }
        let names = names ?? images.indices.map { "Photo \($0 + 1)" }
        var inputs = images
        if options.projection == .cylindrical {
            inputs = try images.indices.map { i in
                let size = images[i].extent.size, long = max(size.width, size.height)
                // 35 mm equivalent focal length → pixels on the long side; about 40 mm when unknown.
                let f = (focalLengths?[i] ?? nil).map { $0 * Double(long) / 36 } ?? Double(long) * 0.9
                return try cylindrical(images[i], focal: f)
            }
        }
        let proxies = inputs.map { Proxy($0) }
        let r = inputs.count / 2
        // Neighbouring frames are registered to each other, then chained to the middle frame.
        var toReference = [double3x3](repeating: matrix_identity_double3x3, count: inputs.count)
        var gains = [Double](repeating: 1, count: inputs.count)
        for step in 1..<inputs.count {
            for i in [r - step, r + step] where inputs.indices.contains(i) {
                let neighbour = i < r ? i + 1 : i - 1
                progress?("Aligning \(names[i]) with \(names[neighbour])…")
                guard let h = align(proxies[i], to: proxies[neighbour], strict: true) else { throw MergeError.noOverlap(names[min(i, neighbour)], names[max(i, neighbour)]) }
                let full = fullResolution(h, from: proxies[i], to: proxies[neighbour])
                toReference[i] = toReference[neighbour] * full
                gains[i] = gains[neighbour] * (exposureRatio(proxies[i], to: proxies[neighbour], transform: h) ?? 1)
            }
        }
        // Canvas: bounding box of every frame, moved to the origin and scaled down if huge.
        var box = CGRect.null
        for i in inputs.indices { box = box.union(bounds(of: inputs[i].extent, under: toReference[i])) }
        let total = inputs.reduce(0.0) { $0 + Double($1.extent.width * $1.extent.height) }
        guard box.width.isFinite, box.height.isFinite, Double(box.width * box.height) < total * 12 else { throw MergeError.tooLarge }
        let fit = min(1, sqrt(Double(options.maximumPixels) / Double(box.width * box.height)))
        let place = double3x3(rows: [SIMD3(fit, 0, -Double(box.minX) * fit), SIMD3(0, fit, -Double(box.minY) * fit), SIMD3(0, 0, 1)])
        let extent = CGRect(x: 0, y: 0, width: (box.width * fit).rounded(.down), height: (box.height * fit).rounded(.down))
        progress?("Blending \(inputs.count) frames…")
        let feather = min(inputs[r].extent.width, inputs[r].extent.height) * 0.12
        var sum = zero(extent), weights = zero(extent)
        for i in inputs.indices {
            let h = place * toReference[i]
            let warped = try warp(inputs[i], h, extent: extent)
            let w = try warp(inputs[i], h, extent: extent, feather: Double(feather))
            sum = try accumulate(sum, warped, w, scale: gains[i]); weights = try add(weights, w)
        }
        var result = try divide(sum, weights)
        if options.autoCrop, let crop = largestCoveredRectangle(result) { result = result.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)) }
        return result
    }
    /// Wraps a frame onto a cylinder of radius `focal` (pixels), so a row of frames lines up with a shift.
    static func cylindrical(_ image: CIImage, focal f: Double) throws -> CIImage {
        let w = Double(image.extent.width), h = Double(image.extent.height)
        let width = (2 * f * atan(w / (2 * f))).rounded(.down)
        let extent = CGRect(x: 0, y: 0, width: width, height: h), source = image.extent
        guard let out = cylinderKernel?.apply(extent: extent, roiCallback: { _, _ in source }, arguments: [image.clampedToExtent(), CIVector(x: w, y: h), f, width]) else { throw EditError.render }
        return out
    }
    static let cylinderKernel = CIKernel(source: """
    kernel vec4 cylinder(sampler image, vec2 size, float f, float width) {
        vec2 d = destCoord();
        float theta = (d.x - width * 0.5) / f;
        float x = f * tan(theta) + size.x * 0.5;
        float y = (d.y - size.y * 0.5) / cos(theta) + size.y * 0.5;
        if (x < 0.0 || y < 0.0 || x > size.x || y > size.y) return vec4(0.0);
        return sample(image, samplerTransform(image, vec2(x, y)));
    }
    """)
    /// The largest axis-aligned rectangle where every pixel is covered (alpha), found on a small copy.
    static func largestCoveredRectangle(_ image: CIImage) -> CGRect? {
        let extent = image.extent, scale = min(1, 480 / max(extent.width, extent.height))
        let w = max(1, Int(extent.width * scale)), h = max(1, Int(extent.height * scale))
        let small = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / extent.width, y: CGFloat(h) / extent.height))
        var pixels = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &pixels, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
        var covered = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { covered[i] = pixels[i * 4 + 3] > 0.99 }
        guard let cell = maximalRectangle(covered, width: w, height: h) else { return nil }
        // Grid rows run top to bottom; Core Image's y axis runs up. Pull in by a pixel to stay clear of soft edges.
        let sx = extent.width / CGFloat(w), sy = extent.height / CGFloat(h)
        let rect = CGRect(x: CGFloat(cell.x + 1) * sx, y: CGFloat(h - cell.y - cell.height + 1) * sy, width: CGFloat(cell.width - 2) * sx, height: CGFloat(cell.height - 2) * sy).integral
        return rect.width > 16 && rect.height > 16 ? rect.intersection(extent) : nil
    }
    /// Largest all-true rectangle in a row-major grid (histogram method), in grid cells.
    static func maximalRectangle(_ grid: [Bool], width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int)? {
        var heights = [Int](repeating: 0, count: width), best: (x: Int, y: Int, width: Int, height: Int)?, bestArea = 0
        for row in 0..<height {
            for x in 0..<width { heights[x] = grid[row * width + x] ? heights[x] + 1 : 0 }
            var stack: [Int] = []
            for x in 0...width {
                let current = x == width ? 0 : heights[x]
                while let top = stack.last, heights[top] >= current {
                    stack.removeLast()
                    let left = stack.last.map { $0 + 1 } ?? 0, area = heights[top] * (x - left)
                    if area > bestArea { bestArea = area; best = (left, row - heights[top] + 1, x - left, heights[top]) }
                }
                stack.append(x)
            }
        }
        return best
    }

    // MARK: Registration

    /// A small copy for alignment: linear luminance, and an exposure-normalized gamma image for Vision.
    struct Proxy {
        let width: Int, height: Int, scale: Double
        let linear: [Float]       // top row first
        let normalized: [Float]   // 0…1, gamma encoded, median lifted to middle gray
        let median: Double
        let cgImage: CGImage?
        init(_ image: CIImage, longest: Double = 1024) {
            let extent = image.extent
            scale = min(1, longest / Double(max(extent.width, extent.height)))
            width = max(1, Int((Double(extent.width) * scale).rounded())); height = max(1, Int((Double(extent.height) * scale).rounded()))
            let small = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
            var pixels = [Float](repeating: 0, count: width * height * 4)
            Merges.context.render(small, toBitmap: &pixels, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: ModernRenderer.workingSpace)
            var lum = [Float](repeating: 0, count: width * height)
            for i in 0..<(width * height) { lum[i] = max(0, pixels[i * 4] * Merges.luma.x + pixels[i * 4 + 1] * Merges.luma.y + pixels[i * 4 + 2] * Merges.luma.z) }
            linear = lum
            let sorted = lum.filter { $0 > 0 }.sorted()
            median = sorted.isEmpty ? 0.18 : Double(sorted[sorted.count / 2])
            let gain = Float(0.18 / max(median, 1e-6))
            normalized = lum.map { powf(min(1, $0 * gain), 1 / 2.2) }
            let bytes = normalized.map { UInt8(max(0, min(255, $0 * 255 + 0.5))) }
            let w = width, h = height
            cgImage = CGDataProvider(data: Data(bytes) as CFData).flatMap {
                CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        }
        /// Bilinear sample at a Core Image coordinate (origin bottom left, pixel centres at +0.5).
        func sample(_ values: [Float], _ x: Double, _ y: Double) -> Float? {
            let fx = x - 0.5, fy = Double(height) - y - 0.5
            guard fx >= 0, fy >= 0, fx <= Double(width - 1), fy <= Double(height - 1) else { return nil }
            let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let ax = Float(fx - Double(x0)), ay = Float(fy - Double(y0))
            let top = values[y0 * width + x0] * (1 - ax) + values[y0 * width + x1] * ax
            let bottom = values[y1 * width + x0] * (1 - ax) + values[y1 * width + x1] * ax
            return top * (1 - ay) + bottom * ay
        }
    }
    /// Homography taking `floating` proxy coordinates to `reference` proxy coordinates, or nil when no good match.
    /// Vision's matrix convention is checked against the pixels rather than assumed.
    static func align(_ floating: Proxy, to reference: Proxy, strict: Bool = false) -> double3x3? {
        var candidates: [double3x3] = strict ? [] : [matrix_identity_double3x3]
        if let a = floating.cgImage, let b = reference.cgImage {
            let request = VNHomographicImageRegistrationRequest(targetedCGImage: a, options: [:])
            if (try? VNImageRequestHandler(cgImage: b, options: [:]).perform([request])) != nil,
               let result = request.results?.first as? VNImageHomographicAlignmentObservation {
                let m = result.warpTransform
                let v = double3x3(columns: (SIMD3<Double>(m.columns.0), SIMD3<Double>(m.columns.1), SIMD3<Double>(m.columns.2)))
                let flipF = double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, -1, Double(floating.height)), SIMD3(0, 0, 1)])
                let flipR = double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, -1, Double(reference.height)), SIMD3(0, 0, 1)])
                for base in [v, v.transpose] where abs(base.determinant) > 1e-9 {
                    for c in [base, base.inverse] { candidates += [c, flipR * c * flipF] }
                }
            }
        }
        var best: (double3x3, Double)?
        for h in candidates {
            guard let s = score(h, floating, reference), s.1 >= (strict ? 0.08 : 0.3) else { continue }
            if best == nil || s.0 < best!.1 { best = (h, s.0) }
        }
        guard let best else { return nil }
        if strict, best.1 > 0.1 { return nil }
        return best.0
    }
    /// Mean luminance difference (gamma, exposure-normalized) and the fraction of the reference the floating frame covers.
    static func score(_ h: double3x3, _ floating: Proxy, _ reference: Proxy) -> (Double, Double)? {
        guard abs(h.determinant) > 1e-9 else { return nil }
        let inverse = h.inverse, n = 48
        var total = 0.0, count = 0
        for gy in 0..<n { for gx in 0..<n {
            let x = (Double(gx) + 0.5) / Double(n) * Double(reference.width), y = (Double(gy) + 0.5) / Double(n) * Double(reference.height)
            let q = inverse * SIMD3(x, y, 1)
            guard q.z > 1e-9 else { continue }
            guard let a = floating.sample(floating.normalized, q.x / q.z, q.y / q.z), let b = reference.sample(reference.normalized, x, y) else { continue }
            total += Double(abs(a - b)); count += 1
        } }
        guard count > 0 else { return nil }
        return (total / Double(count), Double(count) / Double(n * n))
    }
    /// Multiplier that brings `floating` to the reference exposure, from pixels both frames expose well.
    static func exposureRatio(_ floating: Proxy, to reference: Proxy, transform h: double3x3) -> Double? {
        guard abs(h.determinant) > 1e-9 else { return nil }
        let inverse = h.inverse, n = 96
        var ratios: [Float] = []
        for gy in 0..<n { for gx in 0..<n {
            let x = (Double(gx) + 0.5) / Double(n) * Double(reference.width), y = (Double(gy) + 0.5) / Double(n) * Double(reference.height)
            let q = inverse * SIMD3(x, y, 1)
            guard q.z > 1e-9, let a = floating.sample(floating.linear, q.x / q.z, q.y / q.z), let b = reference.sample(reference.linear, x, y) else { continue }
            guard a > 0.02, a < 0.75, b > 0.02, b < 0.75 else { continue }
            ratios.append(b / a)
        } }
        guard ratios.count >= 40 else { return nil }
        ratios.sort()
        let value = Double(ratios[ratios.count / 2])
        return value.isFinite && value > 0 ? value : nil
    }
    /// A proxy-space homography expressed in full-resolution pixels.
    static func fullResolution(_ h: double3x3, from floating: Proxy, to reference: Proxy) -> double3x3 {
        let down = double3x3(diagonal: SIMD3(floating.scale, floating.scale, 1)), up = double3x3(diagonal: SIMD3(1 / reference.scale, 1 / reference.scale, 1))
        return up * h * down
    }
    static func bounds(of rect: CGRect, under h: double3x3) -> CGRect {
        var box = CGRect.null
        for (x, y) in [(rect.minX, rect.minY), (rect.maxX, rect.minY), (rect.minX, rect.maxY), (rect.maxX, rect.maxY)] {
            let p = h * SIMD3(Double(x), Double(y), 1)
            guard p.z > 1e-9 else { return CGRect(x: 0, y: 0, width: CGFloat.infinity, height: CGFloat.infinity) }
            box = box.union(CGRect(x: p.x / p.z, y: p.y / p.z, width: 0, height: 0))
        }
        return box
    }

    // MARK: Compositing

    /// Resamples `image` through homography `h` onto `extent`. With `feather`, returns the blend weight instead:
    /// 1 inside the frame, falling to 0 over `feather` pixels at its edges, and 0 where the frame doesn't reach.
    static func warp(_ image: CIImage, _ h: double3x3, extent: CGRect, feather: Double? = nil) throws -> CIImage {
        let inverse = h.inverse, source = image.extent
        let rows = (0..<3).map { r in CIVector(x: inverse[0][r], y: inverse[1][r], z: inverse[2][r]) }
        guard let out = warpKernel?.apply(extent: extent, roiCallback: { _, _ in source }, arguments: [image.clampedToExtent()] + rows + [CIVector(x: source.width, y: source.height), feather ?? -1.0]) else { throw EditError.render }
        return out
    }
    static let warpKernel = CIKernel(source: """
    kernel vec4 homography(sampler image, vec3 r0, vec3 r1, vec3 r2, vec2 size, float feather) {
        vec3 d = vec3(destCoord(), 1.0);
        float z = dot(r2, d);
        if (z <= 0.0) return feather < 0.0 ? vec4(0.0) : vec4(0.0, 0.0, 0.0, 1.0);
        vec2 p = vec2(dot(r0, d), dot(r1, d)) / z;
        vec4 s = sample(image, samplerTransform(image, p));
        float inside = (p.x >= 0.0 && p.y >= 0.0 && p.x <= size.x && p.y <= size.y) ? step(0.5, s.a) : 0.0;
        if (feather < 0.0) return inside > 0.5 ? vec4(s.rgb / max(s.a, 0.0001), 1.0) : vec4(0.0);
        float edge = min(min(p.x, size.x - p.x), min(p.y, size.y - p.y));
        float w = feather > 0.0 ? smoothstep(0.0, feather, edge) : 1.0;
        w = inside * (w + 0.001);
        return vec4(w, w, w, 1.0);
    }
    """)
    static func zero(_ extent: CGRect) -> CIImage { CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: extent) }
    static let accumulateKernel = CIColorKernel(source: "kernel vec4 mergeAccumulate(__sample acc, __sample img, __sample w, float scale) { return vec4(acc.rgb + img.rgb * scale * w.r, 1.0); }")
    static let addKernel = CIColorKernel(source: "kernel vec4 mergeAdd(__sample a, __sample b) { return vec4(a.rgb + b.rgb, 1.0); }")
    static let divideKernel = CIColorKernel(source: """
    kernel vec4 mergeDivide(__sample sum, __sample w) {
        return w.r > 0.0000001 ? vec4(sum.rgb / w.r, 1.0) : vec4(0.0);
    }
    """)
    static func accumulate(_ sum: CIImage, _ image: CIImage, _ weight: CIImage, scale: Double) throws -> CIImage {
        guard let out = accumulateKernel?.apply(extent: sum.extent, arguments: [sum, image, weight, scale]) else { throw EditError.render }
        return out
    }
    static func add(_ a: CIImage, _ b: CIImage) throws -> CIImage {
        guard let out = addKernel?.apply(extent: a.extent, arguments: [a, b]) else { throw EditError.render }
        return out
    }
    static func divide(_ sum: CIImage, _ weights: CIImage) throws -> CIImage {
        guard let out = divideKernel?.apply(extent: sum.extent, arguments: [sum, weights]) else { throw EditError.render }
        return out
    }

    // MARK: Files

    /// Shutter × ISO ÷ aperture², for ordering exposures when pixels can't tell.
    static func exposureValue(_ url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let time = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue, time > 0 else { return nil }
        let iso = ((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue).flatMap { $0 > 0 ? $0 : nil } ?? 100
        let f = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? 1
        return time * iso / max(f * f, 0.01)
    }
    static func focalLength35mm(_ url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let f = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.doubleValue, f > 0 else { return nil }
        return f
    }
    /// A 16-bit float TIFF in linear light, keeping values brighter than white. Camera details come from `metadataFrom`.
    public static func writeFloatTIFF(_ image: CIImage, to url: URL, metadataFrom source: URL? = nil) throws {
        var image = image
        if let source, let io = CGImageSourceCreateWithURL(source as CFURL, nil), let original = CGImageSourceCopyPropertiesAtIndex(io, 0, nil) as? [String: Any] {
            var props: [String: Any] = [:]
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyGPSDictionary] { props[key as String] = original[key as String] }
            var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFOrientation as String] = 1; tiff[kCGImagePropertyTIFFSoftware as String] = "OpenStill"
            props[kCGImagePropertyTIFFDictionary as String] = tiff
            var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            exif.removeValue(forKey: "MakerNote"); exif[kCGImagePropertyExifPixelXDimension as String] = Int(image.extent.width); exif[kCGImagePropertyExifPixelYDimension as String] = Int(image.extent.height)
            props[kCGImagePropertyExifDictionary as String] = exif
            props[kCGImagePropertyOrientation as String] = 1
            image = image.settingProperties(props)
        }
        for name in [CGColorSpace.extendedLinearITUR_2020, CGColorSpace.extendedLinearDisplayP3, CGColorSpace.extendedLinearSRGB] {
            guard let space = CGColorSpace(name: name), let data = context.tiffRepresentation(of: image, format: .RGBAh, colorSpace: space, options: [:]) else { continue }
            try data.write(to: url, options: .atomic)
            return
        }
        throw EditError.render
    }
}

private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? { if let a, let b { return (a, b) } else { return nil } }
