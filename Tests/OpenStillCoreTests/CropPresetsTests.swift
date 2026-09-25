import Foundation
import Testing
@testable import OpenStillCore

@Suite struct CropPresetsTests {
    @Test func ratioLabelsReduceCommonSizes() {
        #expect(CropGeometry.ratioLabel(width:6000,height:4000) == "3:2")
        #expect(CropGeometry.ratioLabel(width:3840,height:2160) == "16:9")
        #expect(CropGeometry.ratioLabel(width:1080,height:1920) == "9:16")
        #expect(CropGeometry.ratioLabel(width:1080,height:1350) == "4:5")
        #expect(CropGeometry.ratioLabel(width:2520,height:1080) == "21:9")
        #expect(CropGeometry.ratioLabel(width:1600,height:1000) == "16:10")
        #expect(CropGeometry.ratioLabel(width:1500,height:1100) == "15:11")
        #expect(CropGeometry.ratioLabel(width:1080,height:566) == "1.91:1")
    }
    @Test func ratioLabelsToleratePixelRoundingAndApproximateOddSizes() {
        #expect(CropGeometry.ratioLabel(width:6000,height:4001) == "3:2")
        #expect(CropGeometry.ratioLabel(width:1001,height:1000) == "1:1")
        #expect(CropGeometry.ratioLabel(width:3000,height:1710) == "≈ 16:9")
        #expect(CropGeometry.ratioLabel(width:2637,height:1590) == "1.66:1")
        #expect(CropGeometry.ratioLabel(width:1590,height:2637) == "1:1.66")
        #expect(CropGeometry.ratioLabel(width:0,height:100) == "—")
        #expect(CropGeometry.ratioLabel(width:.nan,height:100) == "—")
    }
    @Test func pixelSizeAndLabelUseWholePixels() {
        let size = CropGeometry.pixelSize(of:CGRect(x:0.1,y:0.1,width:0.5,height:0.25),in:CGSize(width:6000,height:4000))
        #expect(size.width == 3000 && size.height == 1000)
        #expect(CropGeometry.sizeLabel(width:3000,height:1000) == "3000 × 1000 px · 3:1")
        let tiny = CropGeometry.pixelSize(of:CGRect(x:0,y:0,width:0,height:0),in:CGSize(width:100,height:100))
        #expect(tiny.width == 1 && tiny.height == 1)
    }
    @Test func presetListsMatchTheirOrientation() {
        #expect(!CropPreset.horizontal.isEmpty && !CropPreset.vertical.isEmpty)
        #expect(CropPreset.horizontal.allSatisfy { $0.orientation == .horizontal && $0.aspect > 1 })
        #expect(CropPreset.vertical.allSatisfy { $0.orientation == .vertical && $0.aspect < 1 })
        #expect(CropPreset.square.allSatisfy { $0.orientation == .square && $0.aspect == 1 })
        let all = CropPreset.square+CropPreset.horizontal+CropPreset.vertical
        #expect(Set(all.map(\.title)).count == all.count)
    }
    @Test func presetTitlesShowResolutionAndRatio() {
        let fullHD = CropPreset.horizontal.first { $0.name == "Full HD" }
        #expect(fullHD?.title == "Full HD · 1920 × 1080 · 16:9")
        #expect(CropPreset.horizontal.first?.title == "Photo · 3:2")
        #expect(CropPreset.horizontal.first { $0.name == "Cinema" }?.title == "Cinema · 21:9")
        #expect(CropPreset.vertical.first { $0.name == "Cinema" }?.title == "Cinema · 9:21")
        #expect(CropPreset.vertical.first { $0.name == "Portrait post" }?.title == "Portrait post · 1080 × 1350 · 4:5")
    }
    @Test func rotatedPresetsSwapOrientation() {
        for preset in CropPreset.horizontal+CropPreset.vertical {
            guard let turned = preset.rotated else { continue }
            #expect(abs(turned.aspect*preset.aspect-1) < 0.0001)
            #expect(turned.orientation != preset.orientation)
        }
        #expect(CropPreset.horizontal.first { $0.name == "4K UHD" }?.rotated?.name == "Vertical 4K UHD")
        #expect(CropPreset.horizontal.first { $0.name == "Full HD" }?.rotated?.name == "Story / Reel")
        #expect(CropPreset.vertical.first { $0.name == "Print" }?.rotated?.name == "Print")
    }
    @Test func resolutionPresetsReportWhenCropIsTooSmall() {
        let fullHD = CropPreset("Full HD",1920,1080,resolution:true)
        #expect(fullHD.isFilled(byWidth:1920,height:1080))
        #expect(!fullHD.isFilled(byWidth:1600,height:900))
        #expect(CropPreset("Photo",3,2).isFilled(byWidth:30,height:20))
    }
}
