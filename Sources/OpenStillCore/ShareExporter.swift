import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ShareFormat: String, CaseIterable {
    case jpeg, original
    public var title: String { self == .jpeg ? "JPEG — as viewed" : "Original file" }
}

public enum ShareExportError: LocalizedError {
    case cameraPreviewUnavailable, couldNotWrite
    public var errorDescription: String? {
        switch self {
        case .cameraPreviewUnavailable:
            return "This RAW file has no usable camera JPEG. Choose Original file to share the RAW instead."
        case .couldNotWrite: return "The sharing copy couldn’t be created. Try another destination."
        }
    }
}

public enum ShareExporter {
    /// Prepare every selected file in order. A failed file prevents sharing an incomplete batch.
    public static func prepare(_ sources: [URL], format: ShareFormat, in directory: URL,
                               edits: [URL: PhotoEdits] = [:], recipes: [URL: RenderRecipe] = [:],
                               progress: (Int, Int) -> Void = { _, _ in }) throws -> [URL] {
        var files: [URL] = []
        do {
            for source in sources {
                do {
                    let file = try autoreleasepool { try prepare(source, format: format, in: directory, edits: edits[source] ?? PhotoEdits(), recipe:recipes[source]) }
                    files.append(file)
                    progress(files.count, sources.count)
                } catch {
                    throw BatchShareError(filename: source.lastPathComponent, underlying: error)
                }
            }
            return files
        } catch {
            // These are only newly created temporary exports, never the source files.
            for file in files { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }
    /// Creates a dedicated sharing copy. Never writes to the source or overwrites a file.
    public static func prepare(_ source: URL, format: ShareFormat, in directory: URL, edits: PhotoEdits = PhotoEdits(), recipe: RenderRecipe? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = format == .original ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent + ".jpg"
        let destination = availableURL(name: name, in: directory)
        if format == .original {
            try FileManager.default.copyItem(at: source, to: destination)
        } else if var recipe {
            recipe.edits = edits
            try ModernRenderer.export(ModernRenderer.render(source:source, recipe:recipe), to:destination, source:source, settings:ExportSettings())
        } else if !edits.isOriginal {
            try PhotoEditor.write(PhotoEditor.render(source: source, edits: edits), to: destination, source: source, type: .jpeg)
        } else if ["jpg", "jpeg", "jpe"].contains(source.pathExtension.lowercased()) {
            // Validate first; preserve the original JPEG bytes and metadata.
            _ = try PhotoDecoder.decode(source, maxPixelSize: 1)
            try FileManager.default.copyItem(at: source, to: destination)
        } else if source.pathExtension.lowercased() == "rw2" {
            var cameraJPEG: Data?
            for preview in PanasonicPreview.read(source) {
                guard let imageSource = CGImageSourceCreateWithData(preview.data as CFData, nil),
                      CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1
                      ] as CFDictionary) != nil else { continue }
                cameraJPEG = preview.data
                break
            }
            guard let cameraJPEG else { throw ShareExportError.cameraPreviewUnavailable }
            try cameraJPEG.write(to: destination, options: .withoutOverwriting)
        } else {
            let photo = try PhotoDecoder.render(source)
            let image = photo.image
            // Flatten transparency against white and encode a full-size, high-quality JPEG.
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ShareExportError.couldNotWrite }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = context.makeImage() else { throw ShareExportError.couldNotWrite }
            let data = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw ShareExportError.couldNotWrite }
            CGImageDestinationAddImage(output, flattened, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw ShareExportError.couldNotWrite }
            try (data as Data).write(to: destination, options: .withoutOverwriting)
        }
        return destination
    }

    public static func copy(_ prepared: URL, to directory: URL) throws -> URL {
        let target = availableURL(name: prepared.lastPathComponent, in: directory)
        try FileManager.default.copyItem(at: prepared, to: target)
        return target
    }

    public static func availableURL(name: String, in directory: URL) -> URL {
        let filename = URL(fileURLWithPath: name).lastPathComponent
        var target = directory.appendingPathComponent(filename)
        let stem = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)"))
            index += 1
        }
        return target
    }
}

public struct BatchShareError: LocalizedError {
    public let filename: String
    public let underlying: Error
    public var errorDescription: String? { "Couldn’t prepare \(filename). \(underlying.localizedDescription) No photos are ready to share; change the format or selection and try again." }
}
