import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

public struct PhotoCatalog {
    public let urls: [URL]
    public let selectedIndex: Int
    public let folder: URL?

    public static func supports(_ url: URL) -> Bool {
        if RawDecoder.isRAW(url) { return true }
        let supported = CGImageSourceCopyTypeIdentifiers() as! [String]
        // Standard identifiers also work when Launch Services tag lookup is unavailable
        // (for example, in command-line test environments).
        let standard: [String: String] = [
            "jpg": "public.jpeg", "jpeg": "public.jpeg", "jpe": "public.jpeg",
            "png": "public.png", "tif": "public.tiff", "tiff": "public.tiff",
            "heic": "public.heic", "heif": "public.heif", "gif": "com.compuserve.gif",
            "webp": "org.webmproject.webp", "avif": "public.avif", "jxl": "public.jpeg-xl",
            "bmp": "com.microsoft.bmp", "psd": "com.adobe.photoshop-image",
            "dng": "com.adobe.raw-image", "cr2": "com.canon.cr2-raw-image",
            "cr3": "com.canon.cr3-raw-image", "crw": "com.canon.crw-raw-image",
            "nef": "com.nikon.raw-image", "nrw": "com.nikon.nrw-raw-image",
            "arw": "com.sony.arw-raw-image", "sr2": "com.sony.sr2-raw-image",
            "raf": "com.fuji.raw-image", "orf": "com.olympus.or-raw-image",
            "rw2": "com.panasonic.rw2-raw-image", "pef": "com.pentax.raw-image"
        ]
        if let identifier = standard[url.pathExtension.lowercased()] { return supported.contains(identifier) }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return supported.contains { identifier in
            guard let readable = UTType(identifier) else { return false }
            return type.conforms(to: readable)
        }
    }

    /// Opens a folder (or the folder of one photo), or exactly the given files when there are several.
    /// With `includeSubfolders`, a folder's nested folders are scanned too; hidden files and packages are skipped.
    public static func open(_ inputs: [URL], includeSubfolders: Bool = false) throws -> PhotoCatalog {
        guard !inputs.isEmpty else { return PhotoCatalog(urls: [], selectedIndex: 0, folder: nil) }
        let first = inputs[0].standardizedFileURL
        let isDirectory = try first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let directory = isDirectory ? first : first.deletingLastPathComponent()
        let candidates: [URL]
        if inputs.count == 1 && includeSubfolders {
            var found: [URL] = []
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let next = enumerator?.nextObject() as? URL { found.append(next) }
            candidates = found
        } else if inputs.count == 1 {
            candidates = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        } else {
            candidates = inputs
        }
        let urls = candidates.filter {
            supports($0) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.map(\.standardizedFileURL).sorted {
            let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        return PhotoCatalog(urls: urls, selectedIndex: urls.firstIndex(of: first) ?? 0,
                            folder: inputs.count == 1 ? directory : nil)
    }
}

extension PhotoCatalog {
    /// Exactly these files (for a collection), skipping ones that are missing or unsupported.
    public static func files(_ inputs: [URL]) -> PhotoCatalog {
        let urls = inputs.map(\.standardizedFileURL).filter { supports($0) && FileManager.default.fileExists(atPath: $0.path) }
            .sorted { let o = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent); return o == .orderedSame ? $0.path < $1.path : o == .orderedAscending }
        return PhotoCatalog(urls: urls, selectedIndex: 0, folder: nil)
    }
}

public enum PhotoReadError: LocalizedError {
    case unreadable
    public var errorDescription: String? { "This image couldn’t be decoded. It may be damaged or use a format this Mac doesn’t support." }
}

public struct DecodedPhoto {
    public enum Rendering { case original, cameraPreview, rawDevelopment }
    public let image: CGImage
    public let rendering: Rendering
    public let sourceImage: CIImage?
    public init(image: CGImage, rendering: Rendering, sourceImage: CIImage? = nil) {
        self.image = image; self.rendering = rendering; self.sourceImage = sourceImage
    }
    public var description: String {
        switch rendering {
        case .original: return "Original image"
        case .cameraPreview: return "Camera preview · \(image.width) × \(image.height) px"
        case .rawDevelopment: return "RAW rendering · Camera LUT not applied"
        }
    }
}

public enum PhotoDecoder {
    // ImageIO applies EXIF orientation and preserves the image's color space.
    // Panasonic RAW uses its largest camera JPEG; ordinary images use original dimensions.
    public static func decode(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        if url.pathExtension == "osfloat" { return try ModernRenderer.display(FloatImageBridge.read(url)) }
        return try render(url, maxPixelSize: maxPixelSize).image
    }

    public static func render(_ url: URL, maxPixelSize: Int? = nil) throws -> DecodedPhoto {
        let isPanasonicRAW = url.pathExtension.lowercased() == "rw2"
        if isPanasonicRAW {
            for preview in PanasonicPreview.read(url) {
                if let source = CGImageSourceCreateWithData(preview.data as CFData, nil),
                   let image = try? decode(source, maxPixelSize: maxPixelSize) {
                    return DecodedPhoto(image: image, rendering: .cameraPreview)
                }
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw PhotoReadError.unreadable }
        return DecodedPhoto(image: try decode(source, maxPixelSize: maxPixelSize),
                            rendering: isPanasonicRAW ? .rawDevelopment : .original)
    }

    private static func decode(_ source: CGImageSource, maxPixelSize: Int?) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw PhotoReadError.unreadable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize ?? max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoReadError.unreadable
        }
        return image
    }
}

public enum PhotoGeometry {
    public static func zoomOffset(_ offset: CGPoint, pointer: CGPoint, viewport: CGSize, oldImage: CGSize, newImage: CGSize) -> CGPoint {
        let ratio = newImage.width / max(0.001, oldImage.width)
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let next = CGPoint(x: pointer.x - center.x - (pointer.x - center.x - offset.x) * ratio,
                           y: pointer.y - center.y - (pointer.y - center.y - offset.y) * ratio)
        return clampedOffset(next, image: newImage, viewport: viewport)
    }

    public static func displaySize(pixels: CGSize, viewport: CGSize, backingScale: CGFloat, native: Bool) -> CGSize {
        let backing = max(1, backingScale)
        let factor = native ? 1 : min(1, min(viewport.width * backing / max(1, pixels.width),
                                            viewport.height * backing / max(1, pixels.height)))
        return CGSize(width: pixels.width * factor / backing, height: pixels.height * factor / backing)
    }

    public static func clampedOffset(_ offset: CGPoint, image: CGSize, viewport: CGSize) -> CGPoint {
        let x = max(0, (image.width - viewport.width) / 2)
        let y = max(0, (image.height - viewport.height) / 2)
        return CGPoint(x: min(x, max(-x, offset.x)), y: min(y, max(-y, offset.y)))
    }
}
