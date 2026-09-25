import Foundation
import CoreImage

/// Upright modes. Each finds straight lines in the photograph and solves for the rotation and keystone that make them level
/// and plumb; Guided uses lines the user draws instead.
public enum UprightMode: String, Codable, CaseIterable, Sendable {
    case off, auto, level, vertical, full, guided
    public var title: String {
        switch self { case .off: return "Off"; case .auto: return "Auto"; case .level: return "Level"; case .vertical: return "Vertical"; case .full: return "Full"; case .guided: return "Guided" }
    }
}
/// A straight line in display-oriented, lens-corrected coordinates before the perspective transform (0…1, y up).
public struct GuideLine: Codable, Equatable, Sendable {
    public var x1, y1, x2, y2: Double
    public init(_ a: CGPoint, _ b: CGPoint) { x1 = a.x; y1 = a.y; x2 = b.x; y2 = b.y }
    public var start: CGPoint { CGPoint(x: x1, y: y1) }
    public var end: CGPoint { CGPoint(x: x2, y: y2) }
}
/// What Upright found, in the same units as the manual sliders. Stored so rendering never repeats the line search.
public struct UprightSolution: Codable, Equatable, Sendable {
    public var mode: UprightMode
    public var rotate = 0.0, vertical = 0.0, horizontal = 0.0
    public init(mode: UprightMode, rotate: Double = 0, vertical: Double = 0, horizontal: Double = 0) {
        self.mode = mode; self.rotate = rotate; self.vertical = vertical; self.horizontal = horizontal
    }
}
/// Perspective correction applied after lens corrections and before straighten and crop. Values act on the photo as it is
/// displayed (after 90° rotation and flip), so "Vertical" always means the displayed vertical.
public struct TransformSettings: Codable, Equatable, Sendable {
    /// −1…1. Negative widens the top (camera tilted up), positive widens the bottom.
    public var vertical = 0.0
    /// −1…1. Positive enlarges the left side, negative the right.
    public var horizontal = 0.0
    /// Degrees, −15…15, counterclockwise like Straighten.
    public var rotate = 0.0
    /// −1…1. Positive stretches vertically, negative horizontally.
    public var aspect = 0.0
    /// 0.5…1.5.
    public var scale = 1.0
    /// −1…1, a fraction of half the frame.
    public var offsetX = 0.0, offsetY = 0.0
    /// Scale up just enough that no empty area shows at the edges.
    public var constrain = true
    public var upright: UprightSolution?
    public var guides: [GuideLine]?
    public init() {}
    public static let rotateLimit = 15.0
    public var sanitized: Self {
        var s = self
        func clamp(_ x: Double, _ low: Double, _ high: Double, _ fallback: Double) -> Double { x.isFinite ? min(high, max(low, x)) : fallback }
        s.vertical = clamp(vertical, -1, 1, 0); s.horizontal = clamp(horizontal, -1, 1, 0); s.rotate = clamp(rotate, -Self.rotateLimit, Self.rotateLimit, 0)
        s.aspect = clamp(aspect, -1, 1, 0); s.scale = clamp(scale, 0.5, 1.5, 1); s.offsetX = clamp(offsetX, -1, 1, 0); s.offsetY = clamp(offsetY, -1, 1, 0)
        if var u = upright {
            u.rotate = clamp(u.rotate, -Self.rotateLimit, Self.rotateLimit, 0); u.vertical = clamp(u.vertical, -1, 1, 0); u.horizontal = clamp(u.horizontal, -1, 1, 0)
            s.upright = u.mode == .off ? nil : u
        }
        if let guides { let valid = guides.filter { [$0.x1, $0.y1, $0.x2, $0.y2].allSatisfy(\.isFinite) }.prefix(4); s.guides = valid.isEmpty ? nil : Array(valid) }
        return s
    }
    public var hasEffect: Bool {
        let s = sanitized
        return s.vertical != 0 || s.horizontal != 0 || s.rotate != 0 || s.aspect != 0 || s.scale != 1 || s.offsetX != 0 || s.offsetY != 0
            || (s.upright.map { $0.rotate != 0 || $0.vertical != 0 || $0.horizontal != 0 } ?? false)
    }
}

/// 3×3 row-major matrix acting on column vectors (x, y, 1).
struct Homography: Equatable {
    var m: [Double]
    static let identity = Homography(m: [1,0,0, 0,1,0, 0,0,1])
    static func * (a: Homography, b: Homography) -> Homography {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { r[i*3+j] = a.m[i*3]*b.m[j] + a.m[i*3+1]*b.m[3+j] + a.m[i*3+2]*b.m[6+j] } }
        return Homography(m: r)
    }
    /// Nil behind the camera (w ≤ 0), where a point has no image.
    func apply(_ p: CGPoint) -> CGPoint? {
        let w = m[6]*p.x + m[7]*p.y + m[8]
        guard w > 1e-9 else { return nil }
        return CGPoint(x: (m[0]*p.x + m[1]*p.y + m[2])/w, y: (m[3]*p.x + m[4]*p.y + m[5])/w)
    }
    var inverse: Homography? {
        let a = m
        let c0 = a[4]*a[8]-a[5]*a[7], c1 = a[5]*a[6]-a[3]*a[8], c2 = a[3]*a[7]-a[4]*a[6]
        let det = a[0]*c0 + a[1]*c1 + a[2]*c2
        guard abs(det) > 1e-12 else { return nil }
        let inv = [c0, a[2]*a[7]-a[1]*a[8], a[1]*a[5]-a[2]*a[4],
                   c1, a[0]*a[8]-a[2]*a[6], a[2]*a[3]-a[0]*a[5],
                   c2, a[1]*a[6]-a[0]*a[7], a[0]*a[4]-a[1]*a[3]]
        return Homography(m: inv.map { $0/det })
    }
    static func translation(_ x: Double, _ y: Double) -> Homography { Homography(m: [1,0,x, 0,1,y, 0,0,1]) }
    static func scale(_ x: Double, _ y: Double) -> Homography { Homography(m: [x,0,0, 0,y,0, 0,0,1]) }
    static func rotation(degrees: Double) -> Homography { let a = degrees * .pi/180; return Homography(m: [cos(a),-sin(a),0, sin(a),cos(a),0, 0,0,1]) }
    /// Keystone about the frame center: points where 1 + kx·x + ky·y < 1 are enlarged.
    static func keystone(vertical: Double, horizontal: Double) -> Homography {
        Homography(m: [1,0,0, 0,1,0, horizontal*Perspective.keystoneStrength, vertical*Perspective.keystoneStrength, 1])
    }
}

/// Rotation and flip between the source (as decoded) and the display frame, in 0…1 coordinates with y up.
public struct DisplayOrientation: Equatable, Sendable {
    public var turn: Int, flip: Bool
    public init(turn: Int, flip: Bool) { self.turn = ((turn % 4) + 4) % 4; self.flip = flip }
    public func display(_ q: CGPoint) -> CGPoint {
        var d: CGPoint
        switch turn { case 1: d = CGPoint(x: q.y, y: 1-q.x); case 2: d = CGPoint(x: 1-q.x, y: 1-q.y); case 3: d = CGPoint(x: 1-q.y, y: q.x); default: d = q }
        if flip { d.x = 1-d.x }
        return d
    }
    public func source(_ display: CGPoint) -> CGPoint {
        var d = display
        if flip { d.x = 1-d.x }
        switch turn { case 1: return CGPoint(x: 1-d.y, y: d.x); case 2: return CGPoint(x: 1-d.x, y: 1-d.y); case 3: return CGPoint(x: d.y, y: 1-d.x); default: return d }
    }
    public func displaySize(_ source: CGSize) -> CGSize { turn % 2 == 0 ? source : CGSize(width: source.height, height: source.width) }
}

/// The projective part of the optics: maps between the lens-corrected image and the perspective-corrected output,
/// both in source-normalized coordinates.
public struct Perspective {
    static let keystoneStrength = 0.35
    let orientation: DisplayOrientation
    /// Half extents of the display frame in centered units (the longer one is 1).
    let ex: Double, ey: Double
    /// Output (centered) → lens-corrected input (centered).
    let inverse: Homography
    let forward: Homography

    public init?(_ settings: TransformSettings?, sourceSize: CGSize, orientation: DisplayOrientation) {
        guard let settings = settings?.sanitized, settings.hasEffect, sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let size = orientation.displaySize(sourceSize), r = max(size.width, size.height)/2
        ex = size.width/2/r; ey = size.height/2/r; self.orientation = orientation
        var h = Self.matrix(settings, ex: ex, ey: ey)
        if settings.constrain, let c = Self.constrainingScale(h, ex: ex, ey: ey) { h = Homography.scale(c, c) * h }
        guard let inv = h.inverse else { return nil }
        forward = h; inverse = inv
    }
    static func uprightMatrix(rotate: Double, vertical: Double, horizontal: Double) -> Homography {
        Homography.keystone(vertical: vertical, horizontal: horizontal) * Homography.rotation(degrees: rotate)
    }
    static func matrix(_ s: TransformSettings, ex: Double, ey: Double) -> Homography {
        let upright = s.upright.map { uprightMatrix(rotate: $0.rotate, vertical: $0.vertical, horizontal: $0.horizontal) } ?? .identity
        let manual = uprightMatrix(rotate: s.rotate, vertical: s.vertical, horizontal: s.horizontal)
        let stretch = pow(2, s.aspect*0.25)
        return Homography.translation(s.offsetX*ex*0.5, s.offsetY*ey*0.5) * Homography.scale(s.scale, s.scale)
            * Homography.scale(1/stretch, stretch) * manual * upright
    }
    /// The smallest enlargement (≥ 1) that keeps every output corner inside the photo, or nil when none is needed.
    static func constrainingScale(_ h: Homography, ex: Double, ey: Double) -> Double? {
        guard let inv = h.inverse else { return nil }
        func fits(_ c: Double) -> Bool {
            [(-ex,-ey),(ex,-ey),(-ex,ey),(ex,ey)].allSatisfy { corner in
                guard let p = inv.apply(CGPoint(x: corner.0/c, y: corner.1/c)) else { return false }
                return abs(p.x) <= ex*1.000001 && abs(p.y) <= ey*1.000001
            }
        }
        if fits(1) { return nil }
        var low = 1.0, high = 16.0
        guard fits(high) else { return nil }
        for _ in 0..<40 { let mid = (low+high)/2; if fits(mid) { high = mid } else { low = mid } }
        return high
    }
    func centered(_ d: CGPoint) -> CGPoint { CGPoint(x: (d.x-0.5)*2*ex, y: (d.y-0.5)*2*ey) }
    func uncentered(_ c: CGPoint) -> CGPoint { CGPoint(x: c.x/(2*ex)+0.5, y: c.y/(2*ey)+0.5) }
    /// Output point → the lens-corrected point it shows (source-normalized). Nil where the output shows nothing.
    public func input(_ output: CGPoint) -> CGPoint? {
        inverse.apply(centered(orientation.display(output))).map { orientation.source(uncentered($0)) }
    }
    /// Lens-corrected point → where it lands in the output (source-normalized).
    public func output(_ input: CGPoint) -> CGPoint? {
        forward.apply(centered(orientation.display(input))).map { orientation.source(uncentered($0)) }
    }
    /// Same as `input`/`output` but in the display frame, where guides are drawn.
    public func displayInput(_ displayOutput: CGPoint) -> CGPoint? { inverse.apply(centered(displayOutput)).map(uncentered) }
    public func displayOutput(_ displayInput: CGPoint) -> CGPoint? { forward.apply(centered(displayInput)).map(uncentered) }
}

// MARK: - Upright line search

/// A detected or drawn straight segment in display-normalized coordinates, weighted by its support.
public struct LineSegment: Equatable, Sendable {
    public var start: CGPoint, end: CGPoint, weight: Double
    public init(_ start: CGPoint, _ end: CGPoint, weight: Double = 1) { self.start = start; self.end = end; self.weight = weight }
}

public enum Upright {
    /// Finds long straight edges in a display-oriented, lens-corrected image. Runs on the CPU at ≤ 640 px.
    public static func detectLines(_ image: CIImage, maximumDimension: Int = 640) -> [LineSegment] {
        let extent = image.extent
        guard extent.width >= 8, extent.height >= 8, extent.width.isFinite, extent.height.isFinite else { return [] }
        let scale = min(1, Double(maximumDimension)/max(extent.width, extent.height))
        let w = max(8, Int((extent.width*scale).rounded())), h = max(8, Int((extent.height*scale).rounded()))
        let small = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: Double(w)/extent.width, y: Double(h)/extent.height))
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.8])
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        var rgba = [Float](repeating: 0, count: w*h*4)
        ModernRenderer.context.render(small, toBitmap: &rgba, rowBytes: w*16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: ModernRenderer.workingSpace)
        // Row 0 of the bitmap is the top of the image; flip so y points up like everywhere else.
        var luma = [Float](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w {
            let i = ((h-1-y)*w + x)*4
            let l = 0.2627*rgba[i] + 0.678*rgba[i+1] + 0.0593*rgba[i+2]
            luma[y*w+x] = sqrt(max(0, l.isFinite ? l : 0)) // perceptual-ish, so dark edges count too
        } }
        return detectLines(luminance: luma, width: w, height: h)
    }

    /// Hough transform over gradient-oriented edge pixels, then each peak becomes its longest supported segment.
    static func detectLines(luminance luma: [Float], width w: Int, height h: Int) -> [LineSegment] {
        var gx = [Float](repeating: 0, count: w*h), gy = gx, mag = gx
        var magnitudes: [Float] = []
        for y in 1..<(h-1) { for x in 1..<(w-1) {
            func v(_ dx: Int, _ dy: Int) -> Float { luma[(y+dy)*w + x+dx] }
            let sx = (v(1,-1) + 2*v(1,0) + v(1,1)) - (v(-1,-1) + 2*v(-1,0) + v(-1,1))
            let sy = (v(-1,1) + 2*v(0,1) + v(1,1)) - (v(-1,-1) + 2*v(0,-1) + v(1,-1))
            let i = y*w+x; gx[i] = sx; gy[i] = sy; mag[i] = (sx*sx + sy*sy).squareRoot()
            if mag[i] > 0 { magnitudes.append(mag[i]) }
        } }
        guard magnitudes.count > 32 else { return [] }
        magnitudes.sort()
        let threshold = max(0.12, magnitudes[Int(Double(magnitudes.count-1)*0.85)])
        // Thin edges: keep local maxima along the gradient.
        var edges: [(x: Int, y: Int, theta: Double)] = []
        for y in 2..<(h-2) { for x in 2..<(w-2) {
            let i = y*w+x, m = mag[i]
            guard m >= threshold else { continue }
            let ux = Double(gx[i]/m), uy = Double(gy[i]/m)
            let ax = Int((ux).rounded()), ay = Int((uy).rounded())
            if m < mag[(y+ay)*w + x+ax] || m < mag[(y-ay)*w + x-ax] { continue }
            var theta = atan2(uy, ux); if theta < 0 { theta += .pi }; if theta >= .pi { theta -= .pi }
            edges.append((x, y, theta))
        } }
        guard edges.count > 16 else { return [] }
        let thetaBins = 360, diag = Double(w*w + h*h).squareRoot(), rhoBins = Int(diag*2)+3
        var acc = [Int32](repeating: 0, count: thetaBins*rhoBins)
        let cosT = (0..<thetaBins).map { cos(Double($0) * .pi/Double(thetaBins)) }, sinT = (0..<thetaBins).map { sin(Double($0) * .pi/Double(thetaBins)) }
        func rhoIndex(_ rho: Double) -> Int { Int((rho + diag).rounded()) }
        for e in edges {
            let center = Int((e.theta/Double.pi*Double(thetaBins)).rounded())
            for d in -4...4 {
                let t = ((center+d) % thetaBins + thetaBins) % thetaBins
                let r = rhoIndex(Double(e.x)*cosT[t] + Double(e.y)*sinT[t])
                if r >= 0 && r < rhoBins { acc[t*rhoBins + r] += 1 }
            }
        }
        let minimumLength = Double(max(w, h))*0.08
        var peaks: [(t: Int, r: Int, votes: Int32)] = []
        for t in 0..<thetaBins { for r in 0..<rhoBins where acc[t*rhoBins+r] >= Int32(minimumLength*0.6) { peaks.append((t, r, acc[t*rhoBins+r])) } }
        peaks.sort { $0.votes > $1.votes }
        var chosen: [(Int, Int)] = [], segments: [LineSegment] = []
        for peak in peaks {
            if segments.count >= 60 || chosen.count >= 200 { break }
            // Neighbors in (θ, ρ); across θ = 0/π the same line reappears with ρ negated.
            if chosen.contains(where: { c in
                let dt = abs(c.0 - peak.t)
                if dt <= 6 { return abs(c.1 - peak.r) <= 6 }
                return thetaBins - dt <= 6 && abs(Double(c.1 + peak.r) - 2*diag) <= 6
            }) { continue }
            chosen.append((peak.t, peak.r))
            let theta = Double(peak.t) * .pi/Double(thetaBins), rho = Double(peak.r) - diag
            let nx = cos(theta), ny = sin(theta), dx = -ny, dy = nx
            // Supporting edge pixels near the line with a matching orientation, ordered along it.
            var support: [(s: Double, x: Double, y: Double)] = []
            for e in edges {
                let distance = Double(e.x)*nx + Double(e.y)*ny - rho
                guard abs(distance) <= 1.5 else { continue }
                var dt = abs(e.theta - theta); dt = min(dt, .pi - dt)
                guard dt <= 6 * .pi/180 else { continue }
                support.append((Double(e.x)*dx + Double(e.y)*dy, Double(e.x), Double(e.y)))
            }
            guard support.count >= 8 else { continue }
            support.sort { $0.s < $1.s }
            // Longest run with gaps under 6 px.
            var best = 0..<0, start = 0
            for i in 1...support.count {
                if i == support.count || support[i].s - support[i-1].s > 6 {
                    if i - start > best.count { best = start..<i }
                    start = i
                }
            }
            let run = support[best]
            guard let first = run.first, let last = run.last, last.s - first.s >= minimumLength, Double(run.count) >= (last.s - first.s)*0.5 else { continue }
            // Total least squares through the run.
            let n = Double(run.count), mx = run.reduce(0) { $0 + $1.x }/n, my = run.reduce(0) { $0 + $1.y }/n
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for p in run { sxx += (p.x-mx)*(p.x-mx); syy += (p.y-my)*(p.y-my); sxy += (p.x-mx)*(p.y-my) }
            let angle = 0.5*atan2(2*sxy, sxx-syy), ux = cos(angle), uy = sin(angle)
            let a = run.map { ($0.x-mx)*ux + ($0.y-my)*uy }
            guard let lo = a.min(), let hi = a.max() else { continue }
            func normalized(_ t: Double) -> CGPoint { CGPoint(x: (mx + ux*t + 0.5)/Double(w), y: (my + uy*t + 0.5)/Double(h)) }
            segments.append(LineSegment(normalized(lo), normalized(hi), weight: hi - lo))
        }
        return segments
    }

    /// Solves Upright for the given lines (display-normalized) and display size. Nil when there are too few usable lines.
    public static func solve(_ mode: UprightMode, lines: [LineSegment], displaySize: CGSize) -> UprightSolution? {
        guard mode != .off, displaySize.width > 0, displaySize.height > 0 else { return nil }
        let r = max(displaySize.width, displaySize.height)/2, ex = displaySize.width/2/r, ey = displaySize.height/2/r
        let tolerance = mode == .guided ? 45.0 : 30.0
        func centered(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x-0.5)*2*ex, y: (p.y-0.5)*2*ey) }
        var verticals: [(CGPoint, CGPoint, Double)] = [], horizontals: [(CGPoint, CGPoint, Double)] = []
        for line in lines {
            let a = centered(line.start), b = centered(line.end), dx = b.x-a.x, dy = b.y-a.y
            guard hypot(dx, dy) > 1e-6, line.weight > 0 else { continue }
            let fromVertical = abs(atan2(dx, dy)), off = min(fromVertical, .pi - fromVertical) * 180 / .pi
            if off <= tolerance { verticals.append((a, b, line.weight)) }
            else if 90 - off <= tolerance { horizontals.append((a, b, line.weight)) }
        }
        let freeVertical = [.auto, .vertical, .full, .guided].contains(mode), freeHorizontal = [.auto, .full, .guided].contains(mode)
        let verticalWeight = 1.0, horizontalWeight = mode == .vertical ? 0.5 : 1.0
        switch mode {
        case .level: guard verticals.count + horizontals.count >= 1 else { return nil }
        case .vertical: guard verticals.count >= 2 || (verticals.count >= 1 && horizontals.count >= 1) else { return nil }
        case .guided: guard verticals.count + horizontals.count >= 1 else { return nil }
        default: guard verticals.count >= 2 || horizontals.count >= 2 else { return nil }
        }
        let total = verticals.reduce(0) { $0 + $1.2*verticalWeight } + horizontals.reduce(0) { $0 + $1.2*horizontalWeight }
        let cap = 8 * Double.pi/180
        let (lambdaV, lambdaH): (Double, Double) = mode == .auto ? (0.0004, 0.004) : (mode == .guided ? (1e-6, 1e-6) : (1e-5, 1e-5))
        func cost(_ rot: Double, _ v: Double, _ hz: Double) -> Double {
            let hm = Perspective.uprightMatrix(rotate: rot, vertical: v, horizontal: hz)
            var sum = 0.0
            func deviation(_ a: CGPoint, _ b: CGPoint, vertical: Bool) -> Double? {
                guard let p = hm.apply(a), let q = hm.apply(b) else { return nil }
                let dx = q.x-p.x, dy = q.y-p.y
                var angle = vertical ? atan2(dx, dy) : atan2(dy, dx)
                if angle > .pi/2 { angle -= .pi } else if angle < -.pi/2 { angle += .pi }
                return angle
            }
            for (a, b, w) in verticals { let d = deviation(a, b, vertical: true) ?? cap; sum += w*verticalWeight*min(d*d, cap*cap) }
            for (a, b, w) in horizontals { let d = deviation(a, b, vertical: false) ?? cap; sum += w*horizontalWeight*min(d*d, cap*cap) }
            return sum/max(total, 1e-9) + lambdaV*v*v + lambdaH*hz*hz + 1e-7*rot*rot
        }
        let limit = TransformSettings.rotateLimit
        var best = (rot: 0.0, v: 0.0, h: 0.0, c: cost(0, 0, 0))
        // Coarse grid, then a shrinking pattern search.
        let rotations = stride(from: -limit, through: limit, by: 1).map { $0 }
        let verticalsGrid = freeVertical ? stride(from: -1.0, through: 1.0, by: 0.1).map { $0 } : [0]
        let horizontalsGrid = freeHorizontal ? stride(from: -1.0, through: 1.0, by: 0.1).map { $0 } : [0]
        for rot in rotations { for v in verticalsGrid { for hz in horizontalsGrid {
            let c = cost(rot, v, hz); if c < best.c { best = (rot, v, hz, c) }
        } } }
        var step = (rot: 0.5, v: 0.05, h: 0.05)
        for _ in 0..<40 {
            var improved = false
            for delta in [(1.0,0.0,0.0),(-1,0,0),(0,1,0),(0,-1,0),(0,0,1),(0,0,-1)] {
                if delta.1 != 0 && !freeVertical || delta.2 != 0 && !freeHorizontal { continue }
                let rot = min(limit, max(-limit, best.rot + delta.0*step.rot)), v = min(1, max(-1, best.v + delta.1*step.v)), hz = min(1, max(-1, best.h + delta.2*step.h))
                let c = cost(rot, v, hz); if c < best.c - 1e-15 { best = (rot, v, hz, c); improved = true }
            }
            if !improved { step = (step.rot/2, step.v/2, step.h/2); if step.rot < 0.001 { break } }
        }
        func tidy(_ x: Double, _ places: Double) -> Double { abs(x) < 0.5/places ? 0 : (x*places).rounded()/places }
        return UprightSolution(mode: mode, rotate: tidy(best.rot, 100), vertical: tidy(best.v, 1000), horizontal: tidy(best.h, 1000))
    }
}

extension PhotoEdits {
    public var transform: TransformSettings {
        get { advanced?.transform ?? TransformSettings() }
        set { let s = newValue.sanitized; if s == TransformSettings() && advanced == nil { return }; ensureAdvanced(); advanced!.transform = s == TransformSettings() ? nil : s }
    }
    public var transformVertical: Double { get { transform.vertical } set { transform.vertical = newValue } }
    public var transformHorizontal: Double { get { transform.horizontal } set { transform.horizontal = newValue } }
    public var transformRotate: Double { get { transform.rotate } set { transform.rotate = newValue } }
    public var transformAspect: Double { get { transform.aspect } set { transform.aspect = newValue } }
    public var transformScale: Double { get { transform.scale } set { transform.scale = newValue } }
    public var transformOffsetX: Double { get { transform.offsetX } set { transform.offsetX = newValue } }
    public var transformOffsetY: Double { get { transform.offsetY } set { transform.offsetY = newValue } }
    public var transformConstrain: Bool { get { transform.constrain } set { transform.constrain = newValue } }
    /// Lens corrections, perspective and the display orientation they are expressed in: everything the optical warp needs.
    public var optics: OpticalCorrection { OpticalCorrection(lens: lens, transform: advanced?.transform, turn: rotation, flip: flip) }
    /// The edits Upright analyzes: same orientation and lens corrections, without perspective, straighten or crop.
    public var uprightInput: PhotoEdits {
        var e = PhotoEdits(); e.rotation = rotation; e.flip = flip; e.baseAsset = baseAsset
        e.temperature = temperature; e.tint = tint
        if let raw = advanced?.rawWhiteBalance { e.ensureAdvanced(); e.advanced!.rawWhiteBalance = raw }
        if let recovery = advanced?.rawRecovery { e.ensureAdvanced(); e.advanced!.rawRecovery = recovery }
        if lens.hasEffect { e.lens = lens }
        return e
    }
}

extension Upright {
    /// Renders the photo as Upright sees it (oriented, lens-corrected, nothing else) and solves the mode.
    public static func analyze(source url: URL, recipe: RenderRecipe, mode: UprightMode) throws -> UprightSolution? {
        guard mode != .off, mode != .guided else { return nil }
        let input = try analysisImage(source: url, recipe: recipe)
        return solve(mode, lines: detectLines(input), displaySize: input.extent.size)
    }
    public static func analysisImage(source url: URL, recipe: RenderRecipe) throws -> CIImage {
        let plain = RenderRecipe(renderer: .linear2020, sourceMode: recipe.sourceMode, raw: recipe.raw, edits: recipe.edits.uprightInput)
        return try ModernRenderer.render(source: url, recipe: plain, maximumDimension: 900, stopBeforeTool: "Retouch")
    }
    /// Level rotation for the Straighten slider, from the same line search.
    public static func straightenAngle(lines: [LineSegment], displaySize: CGSize) -> Double? {
        solve(.level, lines: lines, displaySize: displaySize)?.rotate
    }
}
