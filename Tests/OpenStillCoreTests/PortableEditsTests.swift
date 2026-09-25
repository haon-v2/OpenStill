import Foundation
import Testing
@testable import OpenStillCore

@Suite struct PortableEditsTests {
    @Test func packagesCarryAllHistoryAssetsAndAppendVersions()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("photo.jpg");try Data("fixture".utf8).write(to:source)
        let assets=root.appendingPathComponent("Assets");try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
        for name in ["old.cube","new.cube","object.png"]{try Data(name.utf8).write(to:assets.appendingPathComponent(name))}
        let store=PhotoRecordStore(root:root.appendingPathComponent("local"));var record=try store.record(for:source),doc=record.active.document,e=PhotoEdits()
        e.ensureAdvanced();e.advanced?.lutAsset="old.cube";doc.commit(e,title:"Old look")
        var selection=AdjustmentMask(kind:"object");selection.asset="object.png";e.setMask(selection.independentCopy(),for:"Glow");e.advanced?.lutAsset="new.cube";doc.commit(e,title:"New look");record.updateDocument(doc);record.rating=4;record.flag = .pick;try store.save(record)
        let destination=root.appendingPathComponent("export.openstilledits");try PortableEdits.export(record:record,source:source,to:destination,includeOriginal:true,assetRoot:assets)
        let checked=try PortableEdits.inspect(destination);#expect(checked.manifest.assets.count==3);#expect(checked.record.bookmark==nil);#expect(checked.record.sourcePath=="photo.jpg")
        let clean=PhotoRecordStore(root:root.appendingPathComponent("clean")),imported=try PortableEdits.importPackage(destination,store:clean)
        #expect(imported.rating==4);#expect(imported.flag == .pick);#expect(imported.active.document.steps.map(\.title)==doc.steps.map(\.title))
        #expect(imported.active.document.current.advanced?.lutAsset != "new.cube")
        for name in try PortableEdits.assets(in:imported){#expect(FileManager.default.fileExists(atPath:clean.root.appendingPathComponent("EditAssets/"+name).path))}
        let again=try PortableEdits.importPackage(destination,relink:source,store:store)
        #expect(again.versions.count==record.versions.count+checked.record.versions.count);#expect(again.versions[0].document.steps==record.versions[0].document.steps)
        #expect(again.versions[0].id==record.versions[0].id)
    }
    @Test func relinkRequiresContentAndChecksumsRejectTampering()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("same.jpg");try Data("original".utf8).write(to:source)
        let store=PhotoRecordStore(root:root.appendingPathComponent("store")),record=try store.record(for:source),package=root.appendingPathComponent("photo.openstilledits")
        try PortableEdits.export(record:record,source:source,to:package,includeOriginal:false)
        #expect(try PortableEdits.inspect(package).original==nil)
        let wrong=root.appendingPathComponent("wrong.jpg");try Data("wrong".utf8).write(to:wrong)
        #expect(throws:WorkflowError.self){try PortableEdits.importPackage(package,relink:wrong,store:store)}
        let moved=root.appendingPathComponent("moved.jpg");try FileManager.default.moveItem(at:source,to:moved)
        #expect(try PortableEdits.importPackage(package,relink:moved,store:store).id==record.id)
        try Data("tampered".utf8).write(to:package.appendingPathComponent("document.json"))
        #expect(throws:WorkflowError.self){try PortableEdits.inspect(package)}
    }
}
