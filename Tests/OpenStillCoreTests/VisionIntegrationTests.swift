import Foundation
import CoreImage
import Testing
@testable import OpenStillCore

/// Opt-in checks against local QA photographs; no photos are uploaded.
@Suite struct VisionIntegrationTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["OPENSTILL_QA_HORIZON"] != nil))
    func horizonCorrectionRotatesInTheRightDirection() throws {
        let path = try #require(ProcessInfo.processInfo.environment["OPENSTILL_QA_HORIZON"])
        let original = try PhotoDecoder.decode(URL(fileURLWithPath:path))
        let before = (try? VisionEditor.horizon(original)) ?? 0
        var edits = PhotoEdits();edits.straighten = 7
        let tilted = try PhotoEditor.render(original,edits:edits)
        try PhotoEditor.write(tilted,to:URL(fileURLWithPath:"/tmp/OpenStill-AI-QA/horizon-tilted.png"))
        let correction = try VisionEditor.horizon(tilted)
        print("Vision horizon: baseline \(before)°, after +7° \(correction)°")
        #expect(abs((correction-before)+7) < 3)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["OPENSTILL_QA_OBJECT"] != nil))
    func foregroundSelectionHasObjectAndBackground() throws {
        let path = try #require(ProcessInfo.processInfo.environment["OPENSTILL_QA_OBJECT"])
        let original = try PhotoDecoder.decode(URL(fileURLWithPath:path))
        let scale = min(1,1200/Double(max(original.width,original.height)))
        let image = CIImage(cgImage:original).transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let cg = try #require(CIContext().createCGImage(image,from:image.extent))
        try PhotoEditor.write(cg,to:URL(fileURLWithPath:"/tmp/OpenStill-AI-QA/vision-object-photo.png"))
        let mask = try VisionEditor.objectMask(cg,at:CGPoint(x:0.5,y:0.5))
        #expect(mask.width == cg.width && mask.height == cg.height)
        let context = try #require(CGContext(data:nil,width:mask.width,height:mask.height,bitsPerComponent:8,bytesPerRow:mask.width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue))
        context.draw(mask,in:CGRect(x:0,y:0,width:mask.width,height:mask.height))
        let data = try #require(context.data).assumingMemoryBound(to:UInt8.self)
        let samples = stride(from:0,to:mask.width*mask.height,by:100).map { data[$0] }
        #expect(data[(mask.height/2)*mask.width+mask.width/2] > 200)
        #expect(samples.contains { $0 > 230 });#expect(samples.contains { $0 < 20 })
        try PhotoEditor.write(mask,to:URL(fileURLWithPath:"/tmp/OpenStill-AI-QA/vision-object-mask.png"))
    }
}
