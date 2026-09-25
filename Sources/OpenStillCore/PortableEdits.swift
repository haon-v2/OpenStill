import Foundation

public struct PackageAsset:Codable {public let name:String,checksum:String}
public struct PackageManifest:Codable {
    public var schemaVersion=1
    public let recordChecksum:String,assets:[PackageAsset],original:String?
}
public struct PortableInspection {
    public let folder:URL,record:PhotoRecord,manifest:PackageManifest
    public var original:URL?{manifest.original.map{folder.appendingPathComponent($0)}}
}
public enum PortableEdits {
    private static func basename(_ name:String)->Bool{!name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains(":") && !name.contains("\0") && name.utf8.count<256}
    private static func regular(_ path:URL)throws {
        let values=try path.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isRegularFile==true,values.isSymbolicLink != true else{throw WorkflowError.invalidPackage}
    }
    private static func walk(_ mask:AdjustmentMask,depth:Int=0,visit:(String)throws->Void)throws {
        guard depth<=8,mask.strokes.count<=10000,(mask.components?.count ?? 0)<=1000 else{throw WorkflowError.invalidPackage}
        guard [mask.feather,mask.start.x,mask.start.y,mask.end.x,mask.end.y].allSatisfy({$0.isFinite && abs($0)<=100}) else{throw WorkflowError.invalidPackage}
        for stroke in mask.strokes {guard stroke.points.count<=100000,stroke.radius.isFinite,stroke.radius>=0,stroke.radius<=2,stroke.points.allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<=100 && abs($0.y)<=100}) else{throw WorkflowError.invalidPackage}}
        if let asset=mask.asset{try visit(asset)}
        for component in mask.components ?? [] {guard component.opacity.isFinite,(0...1).contains(component.opacity) else{throw WorkflowError.invalidPackage};try walk(component.selection,depth:depth+1,visit:visit)}
    }
    public static func assets(in record:PhotoRecord)throws->Set<String> {
        guard record.isValid,record.versions.count<=10000 else{throw WorkflowError.invalidDocument}
        var assets=Set<String>()
        func collect(_ name:String)throws{guard basename(name) else{throw WorkflowError.invalidPackage};assets.insert(name)}
        for version in record.versions {
            guard version.document.steps.count<=100000 else{throw WorkflowError.invalidDocument}
            for step in version.document.steps {
                let e=step.edits
                if let crop=e.crop{guard [crop.x,crop.y,crop.width,crop.height].allSatisfy({$0.isFinite}),crop.width>0,crop.height>0 else{throw WorkflowError.invalidPackage}}
                for name in [e.baseAsset,e.overlayAsset,e.advanced?.lutAsset,e.advanced?.aiBackgroundAsset].compactMap({$0}){try collect(name)}
                for mask in e.advanced?.masks.values ?? Dictionary<String,AdjustmentMask>().values{try walk(mask,visit:collect)}
            }
        }
        return assets
    }
    public static func export(record:PhotoRecord,source:URL,to destination:URL,includeOriginal:Bool,assetRoot:URL = EditStorage.assets)throws {
        guard !FileManager.default.fileExists(atPath:destination.path) else{throw CocoaError(.fileWriteFileExists)}
        guard try PhotoRecordStore.contentHash(source)==record.contentFingerprint else{throw WorkflowError.changedSource}
        let assetNames=try assets(in:record),stage=destination.deletingLastPathComponent().appendingPathComponent(".openstill-package-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:stage.appendingPathComponent("Assets"),withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:stage)}
        var copied:[PackageAsset]=[]
        for name in assetNames.sorted(){let from=assetRoot.appendingPathComponent(name);try regular(from);let to=stage.appendingPathComponent("Assets/"+name);try FileManager.default.copyItem(at:from,to:to);copied.append(PackageAsset(name:name,checksum:try PhotoRecordStore.contentHash(to)))}
        var portable=record;portable.sourcePath=source.lastPathComponent;portable.bookmark=nil
        let document=stage.appendingPathComponent("document.json");try JSONEncoder().encode(portable).write(to:document,options:.atomic)
        let original=includeOriginal ? "original."+source.pathExtension.lowercased():nil
        if let original {guard basename(original) else{throw WorkflowError.invalidPackage};let to=stage.appendingPathComponent(original);try FileManager.default.copyItem(at:source,to:to);guard try PhotoRecordStore.contentHash(to)==record.contentFingerprint else{throw WorkflowError.changedSource}}
        let manifest=PackageManifest(recordChecksum:try PhotoRecordStore.contentHash(document),assets:copied,original:original)
        try JSONEncoder().encode(manifest).write(to:stage.appendingPathComponent("manifest.json"),options:.atomic)
        try FileManager.default.moveItem(at:stage,to:destination)
    }
    public static func inspect(_ folder:URL)throws->PortableInspection {
        let root=try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard root.isDirectory==true,root.isSymbolicLink != true else{throw WorkflowError.invalidPackage}
        let manifestURL=folder.appendingPathComponent("manifest.json"),documentURL=folder.appendingPathComponent("document.json")
        try regular(manifestURL);try regular(documentURL)
        guard (try manifestURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<4_000_000,(try documentURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<100_000_000 else{throw WorkflowError.invalidPackage}
        let manifest=try JSONDecoder().decode(PackageManifest.self,from:Data(contentsOf:manifestURL))
        guard manifest.schemaVersion==1,manifest.assets.count<=10000,manifest.recordChecksum == (try PhotoRecordStore.contentHash(documentURL)) else{throw WorkflowError.invalidPackage}
        let record=try JSONDecoder().decode(PhotoRecord.self,from:Data(contentsOf:documentURL))
        let expected=try assets(in:record)
        guard expected==Set(manifest.assets.map(\.name)),expected.count==manifest.assets.count else{throw WorkflowError.invalidPackage}
        let assetFolder=folder.appendingPathComponent("Assets"),values=try assetFolder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory==true,values.isSymbolicLink != true else{throw WorkflowError.invalidPackage}
        for asset in manifest.assets {guard basename(asset.name) else{throw WorkflowError.invalidPackage};let file=assetFolder.appendingPathComponent(asset.name);try regular(file);guard try PhotoRecordStore.contentHash(file)==asset.checksum else{throw WorkflowError.invalidPackage}}
        if let original=manifest.original{guard basename(original) else{throw WorkflowError.invalidPackage};let path=folder.appendingPathComponent(original);try regular(path);guard try PhotoRecordStore.contentHash(path)==record.contentFingerprint else{throw WorkflowError.invalidPackage}}
        return PortableInspection(folder:folder,record:record,manifest:manifest)
    }
    private static func remap(_ edits:PhotoEdits,mapping:[String:String])->PhotoEdits {
        var e=edits
        func name(_ old:String?)->String?{old.map{mapping[$0] ?? $0}}
        func mask(_ old:AdjustmentMask)->AdjustmentMask{var m=old;m.asset=name(m.asset);m.components=m.components?.map{var c=$0;c.selection=mask(c.selection);return c};return m}
        e.baseAsset=name(e.baseAsset);e.overlayAsset=name(e.overlayAsset)
        if var advanced=e.advanced{advanced.lutAsset=name(advanced.lutAsset);advanced.aiBackgroundAsset=name(advanced.aiBackgroundAsset);advanced.masks=advanced.masks.mapValues(mask);e.advanced=advanced}
        return e
    }
    /// Explicit import appends new IDs and preserves every pre-existing version and rating.
    public static func importPackage(_ folder:URL,relink:URL? = nil,store:PhotoRecordStore = EditStorage.records)throws->PhotoRecord {
        let package=try inspect(folder)
        var newOriginal:URL?,newAssets:[URL]=[];var committed=false
        defer{if !committed{for file in newAssets{try? FileManager.default.removeItem(at:file)};if let newOriginal{try? FileManager.default.removeItem(at:newOriginal)}}}
        let source:URL
        if let relink{source=relink}
        else if let original=package.original {
            let directory=store.root.appendingPathComponent("ImportedOriginals/"+UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let filename=basename(package.record.sourcePath) ? package.record.sourcePath:original.lastPathComponent
            source=directory.appendingPathComponent(filename);try FileManager.default.copyItem(at:original,to:source);newOriginal=source
        }else{throw WorkflowError.invalidPackage}
        guard try PhotoRecordStore.contentHash(source)==package.record.contentFingerprint else{throw WorkflowError.changedSource}
        let known=Set(((try? FileManager.default.contentsOfDirectory(at:store.root.appendingPathComponent("PhotoRecords"),includingPropertiesForKeys:nil)) ?? []).compactMap{UUID(uuidString:$0.deletingPathExtension().lastPathComponent)})
        let assetRoot=store.root.appendingPathComponent("EditAssets");try FileManager.default.createDirectory(at:assetRoot,withIntermediateDirectories:true)
        var mapping:[String:String]=[:]
        for asset in package.manifest.assets {
            let filename=UUID().uuidString+"."+URL(fileURLWithPath:asset.name).pathExtension,new=assetRoot.appendingPathComponent(filename)
            try FileManager.default.copyItem(at:folder.appendingPathComponent("Assets/"+asset.name),to:new);newAssets.append(new);mapping[asset.name]=filename
        }
        let existing=try store.record(for:source)
        let fingerprint=EditStorage.fingerprint(source)
        let result=try store.update(existing.id){record in
            for version in package.record.versions {
                var imported=version;imported.id=UUID();imported.revision=UUID();imported.name="Imported · "+version.name
                imported.document.fingerprint=fingerprint
                imported.document.steps=version.document.steps.map{EditStep($0.title,remap($0.edits,mapping:mapping))}
                record.versions.append(imported)
                if version.id==package.record.activeVersionID{record.activeVersionID=imported.id}
            }
            if !known.contains(record.id){record.rating=package.record.rating;record.flag=package.record.flag}
        }
        committed=true;return result
    }
}
