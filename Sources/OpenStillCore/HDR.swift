import Foundation
import CoreImage

/// HDR editing: the finished SDR edit gets its brightest tones lifted above SDR white, up to `headroom` stops.
/// OpenStill's own highlight expansion (not Adobe's HDR mode); values already brighter than white, as in merged HDR
/// photos, keep their extra range, rolled off softly at the headroom.
public struct HDRSettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// Stops above SDR white for the brightest highlights.
    public var headroom = 2.0
    public init() {}
    public var sanitized: Self {
        var s = self
        s.headroom = headroom.isFinite ? min(4, max(0.5, headroom)) : 2
        return s
    }
}
extension PhotoEdits {
    public var hdr: HDRSettings {
        get { advanced?.hdr ?? HDRSettings() }
        set { ensureAdvanced(); advanced!.hdr = newValue == HDRSettings() ? nil : newValue.sanitized }
    }
    public var hdrEnabled: Bool { get { hdr.enabled } set { var s = hdr; s.enabled = newValue; hdr = s } }
    public var hdrHeadroom: Double { get { hdr.headroom } set { var s = hdr; s.headroom = newValue; hdr = s } }
}
extension RenderRecipe {
    /// The same recipe without HDR expansion: the SDR rendition of an HDR edit.
    public var sdr: RenderRecipe {
        guard edits.hdr.enabled else { return self }
        var copy = self; copy.edits.hdrEnabled = false; return copy
    }
}

public enum HDRTone {
    /// Linear Rec. 2020 luminance at which highlights start to lift.
    static let knee = 0.45
    static let expandKernel = CIColorKernel(source: """
    kernel vec4 hdrExpand(__sample s, float headroom, float knee) {
        vec3 rgb = max(s.rgb, vec3(0.0));
        float y = dot(rgb, vec3(0.2627, 0.6780, 0.0593));
        if (y <= 0.0) return s;
        float t = smoothstep(knee, 1.0, min(y, 1.0));
        float yo = y * exp2(headroom * t);
        float cap = exp2(headroom), start = cap * 0.75;
        if (yo > start) yo = start + (cap - start) * (1.0 - exp(-(yo - start) / (cap - start)));
        return vec4(rgb * (yo / y), s.a);
    }
    """)
    /// Lifts highlights of an SDR-referred image into the range above 1.0 (SDR white).
    public static func expand(_ image: CIImage, headroom: Double) throws -> CIImage {
        guard let out = expandKernel?.apply(extent: image.extent, arguments: [image, min(4, max(0.5, headroom)), knee]) else { throw EditError.render }
        return out
    }
    static let toneMapKernel = CIColorKernel(source: """
    kernel vec4 hdrToSDR(__sample s, float knee) {
        vec3 rgb = max(s.rgb, vec3(0.0));
        float y = dot(rgb, vec3(0.2627, 0.6780, 0.0593));
        if (y <= knee) return s;
        float span = 1.0 - knee;
        float yo = knee + span * (1.0 - exp(-(y - knee) / span));
        return vec4(rgb * (yo / y), s.a);
    }
    """)
    /// Brings an HDR image back into SDR range with a soft shoulder (for SDR previews of HDR images).
    public static func toneMapSDR(_ image: CIImage) throws -> CIImage {
        guard let out = toneMapKernel?.apply(extent: image.extent, arguments: [image, 0.7]) else { throw EditError.render }
        return out
    }
}

/// How an export carries HDR highlights.
public enum HDRExport: String, Codable, CaseIterable, Sendable {
    /// HEIF, 10 bit, Rec. 2100 PQ.
    case pq
    /// HEIF, 10 bit, Rec. 2100 HLG.
    case hlg
    /// An SDR JPEG or HEIF with an HDR gain map (ISO 21496-1 style, via Core Image). Needs macOS 15.
    case gainMap
    public var title: String {
        switch self { case .pq: return "HDR (PQ)"; case .hlg: return "HDR (HLG)"; case .gainMap: return "SDR + HDR gain map" }
    }
}
public enum HDRExportError: LocalizedError {
    case needsMacOS15, heifUnavailable
    public var errorDescription: String? {
        switch self {
        case .needsMacOS15: return "Gain map export needs macOS 15 or later. Choose HDR (PQ) or HDR (HLG) instead."
        case .heifUnavailable: return "This Mac can’t write HEIF files. Choose JPEG, PNG or TIFF."
        }
    }
}
