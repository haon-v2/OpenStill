import Foundation
import CoreImage

public enum AdjustmentGroup:String,Codable,CaseIterable {
    case develop,curves,color,monochrome,details,glow,vignette,sunrays,lut,enhance,lens,geometry,retouch,presence,grading,grain,transform,profile
    public var title:String {
        switch self {case .develop:return "Develop";case .curves:return "Curves";case .color:return "Color";case .monochrome:return "Black & white";case .details:return "Details & noise";case .glow:return "Glow";case .vignette:return "Vignette";case .sunrays:return "Sunrays";case .lut:return "LUT";case .enhance:return "Enhance";case .lens:return "Lens corrections";case .geometry:return "Crop & rotation";case .retouch:return "Healing & cloning";case .presence:return "Clarity, texture & dehaze";case .grading:return "Color grading";case .grain:return "Grain";case .transform:return "Transform";case .profile:return "Profile, calibration & RAW decoding"}
    }
    var maskKeys:[String] {
        switch self {case .details:return ["Details","Structure","Denoise"];case .retouch:return ["Retouch"];case .presence:return ["Clarity","Texture","Dehaze"];case .lens,.geometry,.transform,.profile:return [];default:return [title]}
    }
    public static let defaults=Set(allCases.filter{![.lens,.geometry,.retouch,.transform].contains($0)})
}
public struct BatchOptions {
    public var groups=AdjustmentGroup.defaults
    public var masks=false
    public init(){}
    public var needsGeometry:Bool{masks || groups.contains(.geometry) || groups.contains(.retouch)}
}
public struct BatchGeometry:Equatable {
    public let mode:SourceMode,renderer:RendererVersion,width:Int,height:Int
    public init(mode:SourceMode,renderer:RendererVersion,width:Int,height:Int){self.mode=mode;self.renderer=renderer;self.width=width;self.height=height}
    public static func read(_ item:ShootItem)throws->Self {
        guard item.record.active.document.current.baseAsset==nil else{throw BatchError.incompatibleGeometry}
        let recipe=item.record.active.recipe
        let image=try ModernRenderer.source(item.url,mode:recipe.sourceMode,raw:recipe.raw)
        return Self(mode:recipe.sourceMode,renderer:recipe.renderer,width:Int(image.extent.width),height:Int(image.extent.height))
    }
}
public enum BatchError:LocalizedError {
    case changed,incompatibleGeometry,noAdjustments
    public var errorDescription:String? {
        switch self {case .changed:return "This photo changed after the batch preview. Refresh the selection and try again.";case .incompatibleGeometry:return "Masks, crop, and retouching require matching source modes, renderers, and oriented dimensions, without an AI replacement image.";case .noAdjustments:return "Select at least one adjustment group."}
    }
}
public struct BatchEntry:Codable {
    public let photoID:UUID,sourcePath:String,sourceHash:String,versionID:UUID,beforeRevision:UUID
    public let before:PhotoEdits,after:PhotoEdits
    public var appliedVersionID=UUID(),afterRevision=UUID()
    public var upgraded=false,undone=false
    public var failure:String?
}
public struct BatchTransaction:Codable,Identifiable {
    public var id=UUID(),created=Date()
    public var sourceName:String
    public var entries:[BatchEntry]
}
public enum BatchEdits {
    public static func merging(_ source:PhotoEdits,into target:PhotoEdits,options:BatchOptions,geometryCompatible:Bool)throws->PhotoEdits {
        guard !options.groups.isEmpty else{throw BatchError.noAdjustments}
        guard !options.needsGeometry || geometryCompatible else{throw BatchError.incompatibleGeometry}
        var result=target;result.ensureAdvanced()
        for group in options.groups {
            switch group {
            case .develop:result.exposure=source.exposure;result.contrast=source.contrast;result.highlights=source.highlights;result.shadows=source.shadows;result.temperature=source.temperature;result.tint=source.tint;result.advanced?.neutralBalance=source.advanced?.neutralBalance
            case .curves:result.advanced?.curves=source.advanced?.curves
            case .color:result.saturation=source.saturation;result.vibrance=source.vibrance;result.advanced?.colors=source.advanced?.colors ?? AdvancedEdits().colors
            case .monochrome:result.blackAndWhite=source.blackAndWhite;result.monochrome=source.monochrome;result.blacks=source.blacks;result.whites=source.whites
            case .details:result.structure=source.structure;result.sharpness=source.sharpness;result.denoise=source.denoise
            case .glow:result.advanced?.glow=source.advanced?.glow
            case .vignette:result.vignette=source.vignette;result.schemaVersion=source.schemaVersion
            case .sunrays:result.advanced?.sunSettings=source.advanced?.sunSettings;result.sunrays=source.sunrays;result.sunX=source.sunX;result.sunY=source.sunY;result.sunLength=source.sunLength
            case .lut:result.advanced?.lutAsset=source.advanced?.lutAsset;result.advanced?.lutName=source.advanced?.lutName;result.advanced?.lutID=source.advanced?.lutID;result.lutAmount=source.lutAmount
            case .enhance:result.autoEnhance=source.autoEnhance
            case .lens:result.lens=source.lens;result.defringe=source.defringe
            case .geometry:result.crop=source.crop;result.rotation=source.rotation;result.flip=source.flip;result.straighten=source.straighten
            case .retouch:result.retouch=source.retouch.map{var stroke=$0;stroke.id=UUID();return stroke}
            case .presence:result.clarity=source.clarity;result.texture=source.texture;result.dehaze=source.dehaze
            case .grading:result.colorGrading=source.colorGrading
            case .grain:result.grain=source.grain
            case .profile:result.profile=source.profile;result.calibration=source.calibration;result.rawOptions=source.rawOptions
            case .transform:
                // Guides belong to one photo; detected Upright modes are solved again for each target in prepare.
                var transform=source.transform;transform.guides=nil
                if transform.upright?.mode == .guided {transform.upright=nil}
                result.transform=transform
            }
            if options.masks {for key in group.maskKeys{result.setMask(source.advanced?.masks[key]?.independentCopy(),for:key)}}
        }
        // Never transfer baked AI pixels, layers, source mode, or camera-specific WB multipliers.
        return result.sanitized
    }
    public static func prepare(source:ShootItem,targets:[ShootItem],options:BatchOptions)throws->BatchTransaction {
        let geometry=options.needsGeometry ? try BatchGeometry.read(source):nil
        var entries:[BatchEntry]=[]
        for target in targets where target.id != source.id {
            var error:String?,after=target.record.active.document.current
            do {
                let compatible=try geometry.map{$0 == (try BatchGeometry.read(target))} ?? true
                after=try merging(source.record.active.document.current,into:after,options:options,geometryCompatible:compatible)
                if options.groups.contains(.transform),let mode=after.transform.upright?.mode {
                    var recipe=target.record.active.recipe;recipe.edits=after
                    after.transform.upright=try Upright.analyze(source:target.url,recipe:recipe,mode:mode)
                }
            }catch let reason {error=reason.localizedDescription}
            var entry=BatchEntry(photoID:target.id,sourcePath:target.url.path,sourceHash:target.record.contentFingerprint,versionID:target.record.activeVersionID,beforeRevision:target.record.active.revision,before:target.record.active.document.current,after:after)
            entry.failure=error;entries.append(entry)
        }
        return BatchTransaction(sourceName:source.url.lastPathComponent,entries:entries)
    }
    private static func needsModern(_ e:PhotoEdits)->Bool{!e.curves.isIdentity || e.neutralBalance != NeutralBalance() || e.optics.hasEffect || e.profile.hasEffect || e.calibration.hasEffect || !e.retouch.isEmpty || e.advanced?.masks.values.contains{$0.components != nil || $0.range != nil}==true}
    private static func journalURL(_ id:UUID,store:PhotoRecordStore)->URL{store.root.appendingPathComponent("BatchHistory/\(id.uuidString).json")}
    private static func save(_ transaction:BatchTransaction,store:PhotoRecordStore)throws {
        let path=journalURL(transaction.id,store:store);try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(transaction).write(to:path,options:.atomic)
    }
    public static func latest(store:PhotoRecordStore = EditStorage.records)->BatchTransaction? {
        let folder=store.root.appendingPathComponent("BatchHistory")
        return ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).compactMap{try? JSONDecoder().decode(BatchTransaction.self,from:Data(contentsOf:$0))}.filter{!$0.entries.allSatisfy(\.undone)}.max{$0.created<$1.created}
    }
    /// The journal is durable before any photo changes, making an interrupted batch undoable.
    public static func apply(_ preview:BatchTransaction,store:PhotoRecordStore = EditStorage.records,cancelled:()->Bool = {false},progress:(Int,Int)->Void = {_,_ in})throws->BatchTransaction {
        var transaction=preview
        for i in transaction.entries.indices {
            let entry=transaction.entries[i]
            if entry.failure != nil || entry.before == entry.after {transaction.entries[i].undone=true;continue}
            let record=try? store.read(entry.photoID)
            transaction.entries[i].upgraded=record?.active.renderer == .legacy && needsModern(entry.after)
            if !transaction.entries[i].upgraded{transaction.entries[i].appliedVersionID=entry.versionID}
        }
        try save(transaction,store:store)
        for i in transaction.entries.indices {
            if cancelled(){for pending in i..<transaction.entries.count{transaction.entries[pending].undone=true};try save(transaction,store:store);break}
            let entry=transaction.entries[i]
            guard entry.failure==nil,entry.before != entry.after else{continue}
            do {
                guard try PhotoRecordStore.contentHash(URL(fileURLWithPath:entry.sourcePath))==entry.sourceHash else{throw WorkflowError.changedSource}
                try store.update(entry.photoID){record in
                    guard record.activeVersionID==entry.versionID,record.active.revision==entry.beforeRevision else{throw BatchError.changed}
                    if entry.upgraded {
                        record.upgrade();let index=record.versions.count-1
                        record.versions[index].id=entry.appliedVersionID;record.activeVersionID=entry.appliedVersionID
                    }
                    var document=record.active.document;document.commit(entry.after,title:"Batch · \(transaction.sourceName)");record.updateDocument(document)
                    let index=record.versions.firstIndex{$0.id==entry.appliedVersionID}!
                    record.versions[index].revision=entry.afterRevision
                }
            }catch{transaction.entries[i].failure=error.localizedDescription;transaction.entries[i].undone=true}
            try save(transaction,store:store);progress(i+1,transaction.entries.count)
        }
        return transaction
    }
    public static func undo(_ previous:BatchTransaction,store:PhotoRecordStore = EditStorage.records)throws->BatchTransaction {
        var transaction=previous
        for i in transaction.entries.indices where !transaction.entries[i].undone {
            let entry=transaction.entries[i]
            do {
                try store.update(entry.photoID){record in
                    // Do not overwrite adjustments made after the batch, even if their values match.
                    guard record.activeVersionID==entry.appliedVersionID,record.active.revision==entry.afterRevision else{throw BatchError.changed}
                    var document=record.active.document;document.commit(entry.before,title:"Undo batch");record.updateDocument(document)
                    if entry.upgraded{record.activeVersionID=entry.versionID}
                }
                transaction.entries[i].undone=true;transaction.entries[i].failure=nil
            }catch{transaction.entries[i].failure=error.localizedDescription}
            try save(transaction,store:store)
        }
        return transaction
    }
}
