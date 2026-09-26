import Foundation
import CoreImage
import ImageIO
import CRawBridge

public struct RawDecodeError: LocalizedError {
    public let message: String
    public var errorDescription: String? { "RAW development unavailable: \(message). Try Camera Look if an embedded preview is available." }
}
public struct RawImage {
    public let image: CIImage
    public let sensorClippedFraction: Double?
    public let cameraWhiteBalance: [Float]
}
public enum RawDecoder {
    public static let extensions: Set<String> = ["rw2","dng","cr2","cr3","crw","nef","nrw","arw","sr2","raf","orf","pef","srw","3fr","fff","iiq","rwl"]
    public static func isRAW(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    public static var version: String { String(cString: os_raw_version()) }
    public static func defaultMode(for url: URL) -> SourceMode {
        guard isRAW(url) else { return .original }
        var info = OSRawImage(); var error = [CChar](repeating: 0, count: 512)
        guard os_raw_probe(url.path, &info, &error, error.count) == 0 else { return .raw }
        let model = withUnsafePointer(to: &info.model) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
        return model == "DC-S9" ? .cameraLook : .raw
    }
    public static func cameraBalance(_ url:URL) throws -> [Float] {
        var info = OSRawImage(); var error = [CChar](repeating:0,count:512)
        guard os_raw_probe(url.path,&info,&error,error.count) == 0 else { throw RawDecodeError(message:String(cString:error)) }
        var balance = withUnsafePointer(to:&info.camera_white_balance) { $0.withMemoryRebound(to:Float.self,capacity:4) { Array(UnsafeBufferPointer(start:$0,count:4)) } }
        if balance[3] <= 0 { balance[3] = balance[1] }
        return balance
    }
    public static func decode(_ url: URL, settings: RawSettings = RawSettings(), halfSize:Bool = false) throws -> RawImage {
        let settings = settings.sanitized
        var output = OSRawImage(); var error = [CChar](repeating: 0, count: 512)
        let status: Int32
        let o = settings.options ?? RawOptions()
        var options = OSRawOptions(demosaic: settings.options == nil ? -1 : o.demosaic.libraw, noise_threshold: o.waveletThreshold, median_passes: Int32(o.colorNoise), fbdd: Int32(o.impulseNoise))
        if let wb = settings.whiteBalance {
            status = wb.withUnsafeBufferPointer { os_raw_decode(url.path, $0.baseAddress, Int32(settings.highlightRecovery), settings.temperature ?? 6500, settings.tint ?? 0, halfSize ? 1:0, &options, &output, &error, error.count) }
        } else { status = os_raw_decode(url.path, nil, Int32(settings.highlightRecovery), settings.temperature ?? 6500, settings.tint ?? 0, halfSize ? 1:0, &options, &output, &error, error.count) }
        guard status == 0, let pixels = output.pixels else { throw RawDecodeError(message: String(cString: error)) }
        defer { os_raw_release(&output) }
        let width = Int(output.width), height = Int(output.height)
        // LibRaw's RGB16 buffer has no alpha. Expand once at the decoding boundary,
        // retaining all 16 bits; subsequent edits remain floating-point CIImage graphs.
        var rgba = [UInt16](repeating: UInt16.max, count: width*height*4)
        for i in 0..<(width*height) { rgba[4*i] = pixels[3*i]; rgba[4*i+1] = pixels[3*i+1]; rgba[4*i+2] = pixels[3*i+2] }
        let data = rgba.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: width*8, size: CGSize(width: width, height: height), format: .RGBA16, colorSpace: ModernRenderer.workingSpace)
        let balance = withUnsafePointer(to: &output.camera_white_balance) { $0.withMemoryRebound(to: Float.self, capacity: 4) { Array(UnsafeBufferPointer(start: $0, count: 4)) } }
        return RawImage(image: image, sensorClippedFraction: output.sensor_clipped_fraction < 0 ? nil : output.sensor_clipped_fraction, cameraWhiteBalance: balance)
    }
    public static func cameraPreview(_ url: URL) throws -> CIImage {
        if url.pathExtension.lowercased() == "rw2" {
            for preview in PanasonicPreview.read(url) {
                if let image = CIImage(data: preview.data, options: [.applyOrientationProperty: true]) { return image }
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: false, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw RawDecodeError(message: "This file has no readable embedded camera preview")
        }
        return CIImage(cgImage: image)
    }
}
