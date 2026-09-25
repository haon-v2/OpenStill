import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import OpenStillCore

@Suite final class PanasonicPreviewTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    private func jpeg(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
        CGImageDestinationAddImage(destination, try #require(ctx.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func rw2(previews: [(UInt16, Data)], orientation: Int = 1, bigEndian: Bool = false) throws -> URL {
        var result = Data()
        func u16(_ value: UInt16) {
            let bytes = [UInt8(value & 255), UInt8(value >> 8)]
            result.append(contentsOf: bigEndian ? bytes.reversed() : bytes)
        }
        func u32(_ value: UInt32) {
            let bytes = (0..<4).map { UInt8((value >> ($0 * 8)) & 255) }
            result.append(contentsOf: bigEndian ? bytes.reversed() : bytes)
        }
        result.append(contentsOf: bigEndian ? [0x4d, 0x4d] : [0x49, 0x49])
        u16(85); u32(8)
        u16(UInt16(previews.count + 1))
        u16(0x0112); u16(3); u32(1); u16(UInt16(orientation)); u16(0)
        var offset = 8 + 2 + (previews.count + 1) * 12 + 4
        for (tag, data) in previews {
            u16(tag); u16(7); u32(UInt32(data.count)); u32(UInt32(offset))
            offset += data.count
        }
        u32(0)
        for (_, data) in previews { result.append(data) }
        let url = directory.appendingPathComponent(UUID().uuidString + ".RW2")
        try result.write(to: url)
        return url
    }

    @Test func prefersFullSizeCameraJPEGAndPreservesItsPixels() throws {
        let small = try jpeg(width: 120, height: 80), full = try jpeg(width: 600, height: 400)
        let raw = try rw2(previews: [(0x2e, small), (0x127, full)])
        let original = directory.appendingPathComponent("camera.jpg")
        try full.write(to: original)
        let actual = try PhotoDecoder.render(raw)
        let expected = try PhotoDecoder.decode(original)
        #expect(actual.rendering == .cameraPreview)
        #expect(actual.image.width == 600)
        #expect(actual.image.height == 400)
        #expect((actual.image.dataProvider?.data as Data?) == (expected.dataProvider?.data as Data?))
    }
    @Test func fullSizeJPEGReceivesRAWOrientation() throws {
        let raw = try rw2(previews: [(0x127, jpeg(width: 600, height: 400))], orientation: 8)
        let photo = try PhotoDecoder.render(raw)
        #expect(photo.image.width == 400)
        #expect(photo.image.height == 600)
    }
    @Test func retainsExistingJPEGOrientationWithoutDoubleRotation() throws {
        let raw = try rw2(previews: [(0x2e, jpeg(width: 300, height: 200, orientation: 6))], orientation: 6)
        let photo = try PhotoDecoder.render(raw)
        #expect(photo.image.width == 200)
        #expect(photo.image.height == 300)
    }
    @Test func allOrientationTransformsMatchImageIO() throws {
        for orientation in 1...8 {
            let jpegData = try jpeg(width: 120, height: 80)
            let raw = try rw2(previews: [(0x127, jpegData)], orientation: orientation)
            let expectedURL = directory.appendingPathComponent("orientation-\(orientation).jpg")
            try jpeg(width: 120, height: 80, orientation: orientation).write(to: expectedURL)
            let actual = try PhotoDecoder.decode(raw), expected = try PhotoDecoder.decode(expectedURL)
            #expect(actual.width == expected.width)
            #expect(actual.height == expected.height)
            #expect((actual.dataProvider?.data as Data?) == (expected.dataProvider?.data as Data?))
        }
    }
    @Test func filmstripUsesSameCameraLook() throws {
        let raw = try rw2(previews: [(0x127, jpeg(width: 900, height: 600))])
        let photo = try PhotoDecoder.render(raw, maxPixelSize: 240)
        #expect(photo.rendering == .cameraPreview)
        #expect(photo.image.width == 240)
        #expect(photo.image.height == 160)
    }
    @Test func fallsBackToValidSmallPreviewAndLabelsRealResolution() throws {
        let raw = try rw2(previews: [(0x2e, jpeg(width: 120, height: 80)), (0x127, Data("broken JPEG".utf8))])
        let photo = try PhotoDecoder.render(raw)
        #expect(photo.description == "Camera preview · 120 × 80 px")
    }
    @Test func readsBigEndianContainer() throws {
        let raw = try rw2(previews: [(0x127, jpeg(width: 120, height: 80))], orientation: 8, bigEndian: true)
        #expect(try PhotoDecoder.render(raw).image.height == 120)
    }
    @Test func sharingPreservesFullCameraJPEGAndPortraitPixels() throws {
        let raw = try rw2(previews: [(0x2e, jpeg(width: 120, height: 80)), (0x127, jpeg(width: 600, height: 400))], orientation: 8)
        let before = try Data(contentsOf: raw)
        let shared = try ShareExporter.prepare(raw, format: .jpeg, in: directory.appendingPathComponent("share"))
        #expect(try Data(contentsOf: shared) == PanasonicPreview.read(raw).first?.data)
        let actual = try PhotoDecoder.decode(shared), expected = try PhotoDecoder.decode(raw)
        #expect(actual.width == 400 && actual.height == 600)
        #expect((actual.dataProvider?.data as Data?) == (expected.dataProvider?.data as Data?))
        #expect(try Data(contentsOf: raw) == before)
    }
    @Test func sharingOriginalKeepsRAWBytesAndAvoidsOverwrite() throws {
        let raw = try rw2(previews: [(0x127, jpeg(width: 120, height: 80))])
        let before = try Data(contentsOf: raw)
        let copy = try ShareExporter.prepare(raw, format: .original, in: directory)
        #expect(copy != raw)
        #expect(copy.lastPathComponent.contains("(2)"))
        #expect(try Data(contentsOf: copy) == before)
        #expect(try Data(contentsOf: raw) == before)
    }
    @Test func sharingJPEGIsLosslessAndSavedCopiesHaveUniqueNames() throws {
        let source = directory.appendingPathComponent("portrait.jpg")
        let bytes = try jpeg(width: 120, height: 80, orientation: 6)
        try bytes.write(to: source)
        let prepared = try ShareExporter.prepare(source, format: .jpeg, in: directory.appendingPathComponent("share"))
        let saved = try ShareExporter.copy(prepared, to: directory)
        let second = try ShareExporter.copy(prepared, to: directory)
        #expect(saved.lastPathComponent == "portrait (2).jpg")
        #expect(second.lastPathComponent == "portrait (3).jpg")
        #expect(try Data(contentsOf: prepared) == bytes)
        #expect(try Data(contentsOf: saved) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
    }
    @Test func sharingRefusesMissingCameraLookAndCorruptJPEG() throws {
        let raw = try rw2(previews: [(0x127, Data("broken".utf8))])
        #expect(throws: ShareExportError.self) { try ShareExporter.prepare(raw, format: .jpeg, in: directory) }
        let bad = directory.appendingPathComponent("broken.jpg")
        try Data("broken".utf8).write(to: bad)
        #expect(throws: (any Error).self) { try ShareExporter.prepare(bad, format: .jpeg, in: directory) }
    }
    @Test func sharingConvertsPNGAtFullResolutionAndFlattensTransparency() throws {
        let source = directory.appendingPathComponent("transparent.png")
        let context = try #require(CGContext(data: nil, width: 180, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 180, height: 120))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let before = try Data(contentsOf: source)
        let shared = try ShareExporter.prepare(source, format: .jpeg, in: directory.appendingPathComponent("share"))
        let output = try PhotoDecoder.decode(shared)
        #expect(output.width == 180 && output.height == 120)
        let sample = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sample.draw(output, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try #require(sample.data).assumingMemoryBound(to: UInt8.self)
        #expect(pixel[0] > 250 && pixel[1] > 250 && pixel[2] > 250)
        #expect(try Data(contentsOf: source) == before)
    }
    @Test func batchSharingKeepsOrderAndDistinctFilesWithSameName() throws {
        let firstFolder = directory.appendingPathComponent("first")
        let secondFolder = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let first = firstFolder.appendingPathComponent("photo.jpg")
        let second = secondFolder.appendingPathComponent("photo.jpg")
        let a = try jpeg(width: 120, height: 80), b = try jpeg(width: 180, height: 120)
        try a.write(to: first)
        try b.write(to: second)
        var progress: [Int] = []
        let files = try ShareExporter.prepare([second, first], format: .jpeg, in: directory.appendingPathComponent("exports")) { done, total in
            progress.append(done)
            #expect(total == 2)
        }
        #expect(files.map(\.lastPathComponent) == ["photo.jpg", "photo (2).jpg"])
        #expect(try files.map { try Data(contentsOf: $0) } == [b, a])
        #expect(progress == [1, 2])
        #expect(try Data(contentsOf: first) == a)
        #expect(try Data(contentsOf: second) == b)
    }
    @Test func failedBatchRemovesOnlyItsExportsAndNamesFailedPhoto() throws {
        let source = directory.appendingPathComponent("good.jpg")
        try jpeg(width: 120, height: 80).write(to: source)
        let missing = directory.appendingPathComponent("missing.jpg")
        let exports = directory.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let existing = exports.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: existing)
        do {
            _ = try ShareExporter.prepare([source, missing], format: .jpeg, in: exports)
            Issue.record("Expected batch failure")
        } catch let error as BatchShareError {
            #expect(error.filename == "missing.jpg")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: exports.path) == ["keep.txt"])
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
    @Test func batchOriginalsRetainRAWAndJPEGFormats() throws {
        let raw = try rw2(previews: [(0x127, jpeg(width: 120, height: 80))])
        let jpg = directory.appendingPathComponent("photo.jpg")
        try jpeg(width: 120, height: 80).write(to: jpg)
        let originals = try [raw, jpg].map { try Data(contentsOf: $0) }
        let files = try ShareExporter.prepare([raw, jpg], format: .original, in: directory.appendingPathComponent("exports"))
        #expect(files.map(\.pathExtension) == ["RW2", "jpg"])
        #expect(try files.map { try Data(contentsOf: $0) } == originals)
    }
    @Test func rejectsInvalidOrOutOfBoundsContainers() throws {
        for data in [Data(), Data([0x49, 0x49, 85, 0, 255, 255, 255, 255]), Data([0x49, 0x49, 85, 0, 8, 0, 0, 0, 255, 255])] {
            let url = directory.appendingPathComponent(UUID().uuidString + ".RW2")
            try data.write(to: url)
            #expect(PanasonicPreview.read(url).isEmpty)
        }
        let valid = try rw2(previews: [(0x2e, jpeg(width: 120, height: 80))])
        var truncated = try Data(contentsOf: valid)
        truncated.removeLast(20)
        try truncated.write(to: valid)
        #expect(PanasonicPreview.read(valid).isEmpty)
    }
}
