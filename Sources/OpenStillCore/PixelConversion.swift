import Foundation
import Accelerate

/// Whole-buffer pixel conversions with Accelerate (vImage/vDSP) instead of per-pixel Swift loops.
public enum PixelConversion {
    /// LibRaw's packed 16-bit RGB → RGBA with opaque alpha, as bytes for a Core Image bitmap.
    public static func rgb16ToRGBA16(_ rgb: UnsafePointer<UInt16>, width: Int, height: Int) -> Data {
        var data = Data(count: width * height * 8)
        data.withUnsafeMutableBytes { out in
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: rgb), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 6)
            var dst = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 8)
            let error = vImageConvert_RGB16UtoRGBA16U(&src, nil, UInt16.max, &dst, false, vImage_Flags(kvImageNoFlags))
            if error != kvImageNoError {
                // Not expected for valid sizes; fall back to the plain loop rather than return garbage.
                let values = out.bindMemory(to: UInt16.self)
                for i in 0..<(width * height) { values[4*i] = rgb[3*i]; values[4*i+1] = rgb[3*i+1]; values[4*i+2] = rgb[3*i+2]; values[4*i+3] = .max }
            }
        }
        return data
    }

    /// Divides colour by alpha in place (RGBA float, tightly packed). Pixels with zero alpha keep their values.
    public static func unpremultiply(_ pixels: inout [Float], width: Int, height: Int) {
        pixels.withUnsafeMutableBufferPointer { values in
            var buffer = vImage_Buffer(data: values.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 16)
            if vImageUnpremultiplyData_RGBAFFFF(&buffer, &buffer, vImage_Flags(kvImageNoFlags)) != kvImageNoError {
                for i in stride(from: 0, to: values.count, by: 4) where values[i+3] > 0 { for c in 0..<3 { values[i+c] /= values[i+3] } }
            }
        }
    }

    /// Clamps alpha to 0…1 and multiplies colour by it in place. Returns false (leaving the buffer undefined) if any value isn't finite.
    public static func premultiplyValidating(_ values: UnsafeMutableBufferPointer<Float>, width: Int, height: Int) -> Bool {
        guard let base = values.baseAddress, values.count == width * height * 4 else { return false }
        // A NaN or infinity anywhere makes the sum non-finite; one vectorized pass instead of four checks per pixel.
        var sum: Float = 0
        vDSP_sve(base, 1, &sum, vDSP_Length(values.count))
        if !sum.isFinite {
            // The sum can overflow with huge but finite values; only then look at each value.
            guard values.allSatisfy({ $0.isFinite }) else { return false }
        }
        var low: Float = 0, high: Float = 1
        vDSP_vclip(base + 3, 4, &low, &high, base + 3, 4, vDSP_Length(width * height))
        var buffer = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 16)
        if vImagePremultiplyData_RGBAFFFF(&buffer, &buffer, vImage_Flags(kvImageNoFlags)) != kvImageNoError {
            for i in stride(from: 0, to: values.count, by: 4) { for c in 0..<3 { values[i+c] *= values[i+3] } }
        }
        return true
    }
}
