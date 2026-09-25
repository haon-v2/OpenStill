import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

@Suite struct CameraProfileTests {
    func patch(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: ModernRenderer.workingSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    func rgb(_ image: CIImage) -> [Double] {
        var data = [Float](repeating: 0, count: 4)
        ModernRenderer.context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: image.extent.minX, y: image.extent.minY, width: 1, height: 1), format: .RGBAf, colorSpace: ModernRenderer.workingSpace)
        return data.prefix(3).map(Double.init)
    }
    func chroma(_ c: [Double]) -> Double { c.max()! - c.min()! }
    /// A little-endian DCP with a name, a 2×2 hue/sat map shifting hue by `shift` degrees and an identity tone curve.
    func dcp(shift: Float, name: String = "Test Look", includeLook: Bool = true) -> Data {
        var entries: [(tag: UInt16, type: UInt16, count: UInt32, payload: [UInt8])] = []
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8*$0)) } }
        func floats(_ f: [Float]) -> [UInt8] { f.flatMap { le32($0.bitPattern) } }
        let ascii = Array(name.utf8) + [0]
        entries.append((50936, 2, UInt32(ascii.count), ascii))
        entries.append((50721, 10, 9, (0..<9).flatMap { i -> [UInt8] in le32(UInt32(bitPattern: Int32(i % 4 == 0 ? 1 : 0))) + le32(1) }))
        if includeLook {
            entries.append((50937, 4, 3, le32(2) + le32(2) + le32(1)))
            entries.append((50938, 11, 12, floats([shift, 1, 1, shift, 1, 1, shift, 1, 1, shift, 1, 1])))
            entries.append((50940, 11, 4, floats([0, 0, 1, 1])))
        }
        entries.sort { $0.tag < $1.tag }
        var out: [UInt8] = [0x49, 0x49, 0x52, 0x43] + le32(8)
        let ifdSize = 2 + entries.count*12 + 4
        var extra: [UInt8] = []
        let extraOffset = 8 + ifdSize
        out += [UInt8(entries.count & 0xff), UInt8(entries.count >> 8)]
        for e in entries {
            out += [UInt8(e.tag & 0xff), UInt8(e.tag >> 8), UInt8(e.type & 0xff), UInt8(e.type >> 8)] + le32(e.count)
            if e.payload.count <= 4 { out += e.payload + [UInt8](repeating: 0, count: 4 - e.payload.count) }
            else { out += le32(UInt32(extraOffset + extra.count)); extra += e.payload; if extra.count % 2 == 1 { extra.append(0) } }
        }
        out += le32(0)
        return Data(out + extra)
    }

    @Test func defaultsAreIdentityAndStoreNothing() throws {
        #expect(!ProfileSettings().hasEffect && !CalibrationSettings().hasEffect)
        let m = CalibrationSettings().matrix
        #expect(zip(m, [1.0, 0, 0, 0, 1, 0, 0, 0, 1]).allSatisfy { abs($0 - $1) < 1e-12 })
        var e = PhotoEdits(); e.profileAmount = 0.5; e.profileAmount = 1; e.calibrationRedHue = 0.3; e.calibrationRedHue = 0
        #expect(e.advanced?.profile == nil && e.advanced?.calibration == nil)
        let input = patch(0.3, 0.2, 0.1)
        let out = try CameraProfiles.apply(input, profile: ProfileSettings(), calibration: CalibrationSettings())
        #expect(zip(rgb(out), rgb(input)).allSatisfy { abs($0 - $1) < 1e-5 })
        var vivid = ProfileSettings(); vivid.look = .vivid; vivid.amount = 0
        #expect(!vivid.hasEffect)
    }
    @Test func calibrationMovesPrimariesAndKeepsNeutrals() throws {
        var c = CalibrationSettings(); c.redHue = 1; c.greenSaturation = -1; c.blueHue = -0.5
        let gray = rgb(try CameraProfiles.apply(patch(0.4, 0.4, 0.4), profile: ProfileSettings(), calibration: c))
        #expect(abs(gray[0] - gray[1]) < 1e-4 && abs(gray[1] - gray[2]) < 1e-4 && abs(gray[0] - 0.4) < 1e-3)
        var warm = CalibrationSettings(); warm.redHue = 0.8
        let red = rgb(try CameraProfiles.apply(patch(0.6, 0.05, 0.05), profile: ProfileSettings(), calibration: warm))
        #expect(red[1] > 0.1 && red[1] > red[2])
        var dull = CalibrationSettings(); dull.redSaturation = -1
        #expect(chroma(rgb(try CameraProfiles.apply(patch(0.6, 0.1, 0.1), profile: ProfileSettings(), calibration: dull))) < 0.45)
        var bad = CalibrationSettings(); bad.redHue = .nan; bad.blueSaturation = 9
        #expect(bad.sanitized.redHue == 0 && bad.sanitized.blueSaturation == 1)
    }
    @Test func builtInLooks() throws {
        func render(_ look: ProfileLook, _ c: (Double, Double, Double), amount: Double = 1) throws -> [Double] {
            var p = ProfileSettings(); p.look = look; p.amount = amount
            return rgb(try CameraProfiles.apply(patch(c.0, c.1, c.2), profile: p, calibration: CalibrationSettings()))
        }
        let color = (0.35, 0.18, 0.08)
        let mono = try render(.monochrome, color)
        #expect(abs(mono[0] - mono[1]) < 0.003 && abs(mono[1] - mono[2]) < 0.003)
        #expect(chroma(try render(.vivid, color)) > chroma([color.0, color.1, color.2]) * 1.1)
        #expect(chroma(try render(.neutral, color)) < chroma([color.0, color.1, color.2]))
        // Neutral lowers contrast: shadows come up, highlights come down.
        let shadow = try render(.neutral, (0.02, 0.02, 0.02)), light = try render(.neutral, (0.7, 0.7, 0.7))
        #expect(shadow[1] > 0.02 && light[1] < 0.7)
        let half = try render(.vivid, color, amount: 0.5), full = try render(.vivid, color)
        #expect(chroma(half) > chroma([color.0, color.1, color.2]) && chroma(half) < chroma(full))
        // Black stays black and the LUT keeps light up to its headroom.
        #expect(try render(.vivid, (0, 0, 0)).allSatisfy { abs($0) < 1e-3 })
        #expect(try render(.landscape, (2, 2, 2))[1] > 1.5)
    }
    @Test func readsAndAppliesDNGCameraProfiles() throws {
        let profile = try DNGCameraProfile(data: dcp(shift: 30))
        #expect(profile.name == "Test Look")
        #expect(profile.hueSatMap?.hues == 2 && profile.hueSatMap?.sats == 2 && profile.lookTable == nil)
        #expect(profile.toneCurve?.count == 2)
        // +30° moves red toward yellow; neutrals have no hue to move.
        let red = profile.apply(SIMD3(0.6, 0.1, 0.1))
        #expect(red.y > 0.2 && abs(red.x - 0.6) < 1e-6)
        let gray = profile.apply(SIMD3(0.3, 0.3, 0.3))
        #expect(abs(gray.x - 0.3) < 1e-9 && abs(gray.z - 0.3) < 1e-9)
        #expect(throws: DCPError.unreadable) { try DNGCameraProfile(data: Data("not a profile".utf8)) }
        #expect(throws: DCPError.noLook) { try DNGCameraProfile(data: dcp(shift: 0, includeLook: false)) }
        let tone = DNGCameraProfile.tone(SIMD3(0.2, 0.4, 0.6), curve: [(0, 0), (0.5, 0.7), (1, 1)])
        #expect(abs(tone.x - 0.28) < 1e-9 && abs(tone.z - 0.76) < 1e-9 && tone.y > tone.x && tone.y < tone.z)
    }
    @Test func importedProfileRendersAndTravelsWithPackages() throws {
        let asset = try EditStorage.newAsset(extension: "dcp")
        try dcp(shift: 40).write(to: asset)
        var e = PhotoEdits(); var p = ProfileSettings(); p.dcpAsset = asset.lastPathComponent; p.dcpName = "Test Look"; e.profile = p
        #expect(e.profile.hasEffect)
        let out = rgb(try CameraProfiles.apply(patch(0.5, 0.08, 0.08), profile: e.profile, calibration: CalibrationSettings()))
        #expect(out[1] > 0.15)
        let rendered = try ModernRenderer.process(patch(0.5, 0.08, 0.08), edits: e)
        #expect(rgb(rendered)[1] > 0.15)
        var doc = EditDocument(fingerprint: "fixture"); doc.commit(e, title: "Profile")
        let record = PhotoRecord(source: URL(fileURLWithPath: "/tmp/fixture.jpg"), fingerprint: "fixture", version: EditVersion(name: "Main", renderer: .linear2020, sourceMode: .original, document: doc))
        #expect(try PortableEdits.assets(in: record).contains(asset.lastPathComponent))
    }
    @Test func rawOptionsFlowIntoTheDecodeRecipe() throws {
        var o = RawOptions(); o.noise = .nan; o.colorNoise = 7; o.impulseNoise = -1
        #expect(o.sanitized.noise == 0 && o.sanitized.colorNoise == 3 && o.sanitized.impulseNoise == 0)
        var e = PhotoEdits(); e.rawNoise = 0.45; var options = e.rawOptions; options.demosaic = .dcb; e.rawOptions = options
        let raw = RenderRecipe(renderer: .linear2020, sourceMode: .raw, edits: e)
        #expect(raw.raw.options?.demosaic == .dcb && raw.raw.options?.noise == 0.45)
        #expect(raw.raw.cacheKey != RenderRecipe(renderer: .linear2020, sourceMode: .raw, edits: PhotoEdits()).raw.cacheKey)
        #expect(RenderRecipe(renderer: .linear2020, sourceMode: .original, edits: e).raw.options == nil)
        #expect(RawDemosaic.ahd.libraw == 3 && RawDemosaic.aahd.libraw == 12)
        e.rawOptions = RawOptions()
        #expect(e.advanced?.rawOptions == nil)
        // Settings saved before these options existed still decode.
        let json = #"{"highlightRecovery":2}"#
        let old = try JSONDecoder().decode(RawSettings.self, from: Data(json.utf8))
        #expect(old.options == nil && old.cacheKey == RawSettings().cacheKey)
    }
    @Test func batchCopiesProfileGroup() throws {
        var e = PhotoEdits(); var p = ProfileSettings(); p.look = .portrait; p.amount = 0.7; e.profile = p; e.calibrationBlueHue = 0.4; e.rawNoise = 0.2
        var options = BatchOptions(); options.groups = [.profile]
        let copied = try BatchEdits.merging(e, into: PhotoEdits(), options: options, geometryCompatible: true)
        #expect(copied.profile == e.profile && copied.calibration == e.calibration && copied.rawOptions == e.rawOptions)
        #expect(AdjustmentGroup.defaults.contains(.profile))
        options.groups = [.develop]
        #expect(try BatchEdits.merging(e, into: PhotoEdits(), options: options, geometryCompatible: true).profile == ProfileSettings())
    }
}
