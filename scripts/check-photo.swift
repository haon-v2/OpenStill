import Foundation
import ImageIO
import CryptoKit

// Compile with Sources/OpenStillCore/*.swift to inspect local files without
// copying them into the repository. Prints no serial numbers or GPS metadata.
@main enum CheckPhoto {
    static func main() throws {
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let photo = try PhotoDecoder.render(url)
            let metadata = PhotoMetadata.read(url)
            let preview = PanasonicPreview.read(url).first
            var matches = false
            if let preview, let source = CGImageSourceCreateWithData(preview.data as CFData, nil) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(preview.width, preview.height)
                ]
                if let expected = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                   let expectedData = expected.dataProvider?.data as Data?,
                   let actualData = photo.image.dataProvider?.data as Data? {
                    matches = SHA256.hash(data: expectedData) == SHA256.hash(data: actualData)
                }
            }
            let report: [String: Any] = ["file": url.lastPathComponent, "camera": metadata.camera,
                                       "lens": metadata.lens, "viewing": photo.description,
                                       "matchesEmbeddedCameraJPEG": matches,
                                       "embeddedSizes": PanasonicPreview.read(url).map { "\($0.width) × \($0.height)" }]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
