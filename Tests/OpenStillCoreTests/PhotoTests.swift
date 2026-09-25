import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import OpenStillCore

@Suite final class PhotoTests {
    private var directory: URL!
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    private func fixture(_ name: String, width: Int = 120, height: Int = 80, metadata: [CFString: Any] = [:]) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let url = directory.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func testSinglePhotoLoadsNaturallySortedSiblingsAndKeepsSelection() throws {
        try fixture("photo10.jpg")
        let selected = try fixture("photo2.jpg")
        try fixture("photo1.jpg")
        try "ignored".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let catalog = try PhotoCatalog.open([selected])
        #expect(catalog.urls.map(\.lastPathComponent) == ["photo1.jpg", "photo2.jpg", "photo10.jpg"])
        #expect(catalog.selectedIndex == 1)
    }
    @Test func testFolderSkipsHiddenFilesDirectoriesAndSubfolders() throws {
        try fixture("visible.jpg")
        try fixture(".hidden.jpg")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("fake.jpg"), withIntermediateDirectories: true)
        let catalog = try PhotoCatalog.open([directory])
        #expect(catalog.urls.map(\.lastPathComponent) == ["visible.jpg"])
    }
    @Test func testMultipleFilesOnlyLoadSelectedFiles() throws {
        let a = try fixture("a.jpg"), c = try fixture("c.jpg")
        try fixture("b.jpg")
        #expect(try PhotoCatalog.open([c, a]).urls.map(\.lastPathComponent) == ["a.jpg", "c.jpg"])
    }
    @Test func testEmptyFolderAndUnreadableInput() throws {
        #expect(try PhotoCatalog.open([directory]).urls.isEmpty)
        #expect(throws: (any Error).self) { try PhotoCatalog.open([directory.appendingPathComponent("missing")]) }
    }
    @Test func testFullDecodePreservesPixelsAndThumbnailIsBounded() throws {
        let url = try fixture("large.jpg", width: 1800, height: 1200)
        let full = try PhotoDecoder.decode(url)
        #expect(full.width == 1800)
        #expect(full.height == 1200)
        let thumbnail = try PhotoDecoder.decode(url, maxPixelSize: 240)
        #expect(thumbnail.width == 240)
        #expect(thumbnail.height == 160)
    }
    @Test func testEXIFOrientationRotatesActualPixelsAndDimensions() throws {
        let url = try fixture("rotated.jpg", metadata: [kCGImagePropertyOrientation: 6])
        let image = try PhotoDecoder.decode(url)
        #expect(image.width == 80)
        #expect(image.height == 120)
        #expect(PhotoMetadata.read(url).dimensions == "80 × 120")
    }
    @Test func testCorruptPhotoThrows() throws {
        let url = directory.appendingPathComponent("corrupt.jpg")
        try Data("broken".utf8).write(to: url)
        #expect(throws: (any Error).self) { try PhotoDecoder.decode(url) }
    }
    @Test func testEmbeddedCameraAndLensSettingsRoundTrip() throws {
        let url = try fixture("camera.jpg", metadata: [
            kCGImagePropertyTIFFDictionary: ["Make": "Canon", "Model": "Canon EOS R5"],
            kCGImagePropertyExifDictionary: [
                "LensMake": "Canon", "LensModel": "RF24-70mm F2.8 L IS USM", "ExposureTime": 0.004,
                "FNumber": 2.8, "ISOSpeedRatings": [400], "FocalLength": 50,
                "DateTimeOriginal": "2026:09:24 10:30:00", "ExposureBiasValue": -1.0
            ]
        ])
        let metadata = PhotoMetadata.read(url)
        #expect(metadata.camera == "Canon EOS R5")
        #expect(metadata.lens == "Canon RF24-70mm F2.8 L IS USM")
        #expect(metadata.shutter == "1/250 s")
        #expect(metadata.aperture == "ƒ/2.8")
        #expect(metadata.iso == "400")
        #expect(metadata.focalLength == "50 mm")
        #expect(metadata.captured.contains("2026"))
        #expect(metadata.exposureBias == "-1 EV")
    }
    @Test func testMissingMetadataIsNotInvented() {
        let metadata = PhotoMetadata(properties: [:])
        #expect(metadata.camera == "Not recorded")
        #expect(metadata.lens == "Not recorded")
        #expect(metadata.iso == "Not recorded")
        #expect(metadata.aperture == "Not recorded")
        #expect(metadata.captured == "Not recorded")
    }
    @Test func testAuxLensAndAPEXFallbacks() {
        let metadata = PhotoMetadata(properties: [
            "{ExifAux}": ["LensModel": "FE 85mm F1.8"],
            "{Exif}": ["ShutterSpeedValue": 8.0, "ApertureValue": 4.0]
        ])
        #expect(metadata.lens == "FE 85mm F1.8")
        #expect(metadata.shutter == "1/256 s")
        #expect(metadata.aperture == "ƒ/4")
    }
    @Test func testLensSpecificationFallback() {
        let metadata = PhotoMetadata(properties: ["{Exif}": ["LensSpecification": [24, 70, 2.8, 2.8]]])
        #expect(metadata.lens == "24–70 mm ƒ/2.8 (model not recorded)")
    }
    @Test func testActualPixelsRespectRetinaAndStandardDisplays() {
        let pixels = CGSize(width: 6000, height: 4000), viewport = CGSize(width: 1000, height: 800)
        #expect(PhotoGeometry.displaySize(pixels: pixels, viewport: viewport, backingScale: 2, native: true) == CGSize(width: 3000, height: 2000))
        #expect(PhotoGeometry.displaySize(pixels: pixels, viewport: viewport, backingScale: 1, native: true) == pixels)
        let fit = PhotoGeometry.displaySize(pixels: pixels, viewport: viewport, backingScale: 2, native: false)
        #expect(abs((fit.width) - (1000)) <= 0.01)
        #expect(abs((fit.height) - (666.6667)) <= 0.01)
    }
    @Test func testFitDoesNotEnlargeSmallPhotosAndPanningStaysInBounds() {
        #expect(PhotoGeometry.displaySize(pixels: CGSize(width: 200, height: 100), viewport: CGSize(width: 1000, height: 800), backingScale: 2, native: false) == CGSize(width: 100, height: 50))
        #expect(PhotoGeometry.clampedOffset(CGPoint(x: 9000, y: -9000), image: CGSize(width: 3000, height: 2000), viewport: CGSize(width: 1000, height: 800)) == CGPoint(x: 1000, y: -600))
        #expect(PhotoGeometry.clampedOffset(CGPoint(x: 100, y: 100), image: CGSize(width: 100, height: 100), viewport: CGSize(width: 1000, height: 800)) == .zero)
    }

    @Test func testZoomKeepsPhotoPointUnderPointer() {
        let viewport = CGSize(width: 1000, height: 800)
        let offset = PhotoGeometry.zoomOffset(.zero, pointer: CGPoint(x: 750, y: 300), viewport: viewport,
                                              oldImage: CGSize(width: 1000, height: 800), newImage: CGSize(width: 2000, height: 1600))
        #expect(offset == CGPoint(x: -250, y: 100))
        let restored = PhotoGeometry.zoomOffset(offset, pointer: CGPoint(x: 750, y: 300), viewport: viewport,
                                                oldImage: CGSize(width: 2000, height: 1600), newImage: viewport)
        #expect(restored == .zero)
    }
}
