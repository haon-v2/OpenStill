import Foundation
import Vision
import CoreImage

public enum VisionEditor {
    public static func horizon(_ image: CGImage) throws -> Double {
        let request = VNDetectHorizonRequest()
        try VNImageRequestHandler(cgImage:image).perform([request])
        guard let observation = request.results?.first, observation.confidence >= 0.3 else { throw VisionEditError.noHorizon }
        let angle = atan2(observation.transform.b,observation.transform.a)*180 / .pi
        guard angle.isFinite, abs(angle) <= 20 else { throw VisionEditError.noHorizon }
        return angle
    }
    public static func objectMask(_ image: CGImage, at point: CGPoint) throws -> CGImage {
        guard #available(macOS 14.0, *) else { throw VisionEditError.systemVersion }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage:image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw VisionEditError.noObject }
        let labels = observation.instanceMask
        CVPixelBufferLockBaseAddress(labels,.readOnly); defer { CVPixelBufferUnlockBaseAddress(labels,.readOnly) }
        let w = CVPixelBufferGetWidth(labels), h = CVPixelBufferGetHeight(labels), stride = CVPixelBufferGetBytesPerRow(labels)
        guard let bytes = CVPixelBufferGetBaseAddress(labels) else { throw VisionEditError.noObject }
        let x = min(w-1,max(0,Int(point.x*Double(w)))), y = min(h-1,max(0,Int((1-point.y)*Double(h))))
        let instance = Int(bytes.assumingMemoryBound(to:UInt8.self)[y*stride+x])
        guard instance > 0, observation.allInstances.contains(instance) else { throw VisionEditError.noObject }
        let buffer = try observation.generateScaledMaskForImage(forInstances:IndexSet(integer:instance),from:handler)
        let mask = CIImage(cvPixelBuffer:buffer)
        guard let output = CIContext().createCGImage(mask,from:mask.extent) else { throw EditError.render }
        return output
    }
}
public enum VisionEditError: LocalizedError {
    case noHorizon, noObject, systemVersion
    public var errorDescription: String? {
        switch self {
        case .noHorizon: return "No tilted horizon was confidently detected. The photo may already be level; use Straighten for manual alignment."
        case .noObject: return "No distinct foreground object was found at that point. Click inside a clear subject or use a brush mask."
        case .systemVersion: return "AI object selection requires macOS 14 or later. Brush, linear, and radial masks are available."
        }
    }
}
