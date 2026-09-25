import Foundation
import Testing
@testable import OpenStillCore

@Suite struct BatchEditsTests {
    @Test func defaultsPreserveGeometryMasksAIAndCameraBalance()throws {
        var source=PhotoEdits(),target=PhotoEdits();source.exposure=1.5;source.glow.amount=55;source.rotation=2;source.baseAsset="other.osfloat";source.setMask(AdjustmentMask(kind:"linear"),for:"Glow");source.advanced?.rawWhiteBalance=[3,1,2,1]
        target.rotation=1;target.baseAsset="mine.osfloat";target.setMask(AdjustmentMask(kind:"radial"),for:"Glow");target.advanced?.rawWhiteBalance=[2,1,3,1]
        let result=try BatchEdits.merging(source,into:target,options:BatchOptions(),geometryCompatible:false)
        #expect(result.exposure==1.5);#expect(result.glow.amount==55);#expect(result.rotation==1);#expect(result.baseAsset==target.baseAsset)
        #expect(result.advanced?.masks==target.advanced?.masks);#expect(result.advanced?.rawWhiteBalance==target.advanced?.rawWhiteBalance)
    }
    @Test func geometryRequiresCompatibilityAndMaskCopiesAreIndependent()throws {
        var source=PhotoEdits(),options=BatchOptions();source.rotation=2;source.setMask(AdjustmentMask(kind:"linear").independentCopy(),for:"Glow")
        options.groups=[.glow,.geometry];options.masks=true
        #expect(throws:BatchError.self){try BatchEdits.merging(source,into:PhotoEdits(),options:options,geometryCompatible:false)}
        let result=try BatchEdits.merging(source,into:PhotoEdits(),options:options,geometryCompatible:true)
        #expect(result.rotation==2);#expect(result.advanced?.masks["Glow"]?.components?.first?.id != source.advanced?.masks["Glow"]?.components?.first?.id)
    }
    @Test func journalUndoAndLaterEditConflict()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let store=PhotoRecordStore(root:root)
        func item(_ name:String)throws->ShootItem {
            let path=root.appendingPathComponent(name);try Data(name.utf8).write(to:path)
            return ShootItem(url:path,record:try store.record(for:path),captured:Date())
        }
        var source=try item("source.jpg");let a=try item("a.jpg"),b=try item("b.jpg")
        var edits=PhotoEdits();edits.exposure=1.2;var doc=source.record.active.document;doc.commit(edits,title:"Exposure");source.record.updateDocument(doc)
        let preview=try BatchEdits.prepare(source:source,targets:[a,b],options:BatchOptions())
        let applied=try BatchEdits.apply(preview,store:store)
        #expect(try store.read(a.id).active.document.current.exposure==1.2)
        #expect(BatchEdits.latest(store:store)?.id==applied.id)
        try store.update(b.id){record in var d=record.active.document;var e=d.current;e.exposure=2;d.commit(e,title:"Later");record.updateDocument(d)}
        let undo=try BatchEdits.undo(applied,store:store)
        #expect(try store.read(a.id).active.document.current.exposure==0)
        #expect(try store.read(b.id).active.document.current.exposure==2)
        #expect(undo.entries[0].undone);#expect(undo.entries[1].failure != nil)
        #expect(try store.read(a.id).active.document.steps.last?.title=="Undo batch")
    }
    @Test func batchKeepsSuccessWhenAnotherSourceChanges()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let store=PhotoRecordStore(root:root)
        var items:[ShootItem]=[]
        for name in ["source","a","b"] {let url=root.appendingPathComponent(name+".jpg");try Data(name.utf8).write(to:url);items.append(ShootItem(url:url,record:try store.record(for:url),captured:Date()))}
        var e=PhotoEdits();e.exposure=1;var d=items[0].record.active.document;d.commit(e,title:"Edit");items[0].record.updateDocument(d)
        let plan=try BatchEdits.prepare(source:items[0],targets:Array(items.dropFirst()),options:BatchOptions())
        try Data("replacement".utf8).write(to:items[2].url)
        let result=try BatchEdits.apply(plan,store:store)
        #expect(try store.read(items[1].id).active.document.current.exposure==1)
        #expect(try store.read(items[2].id).active.document.current.exposure==0)
        #expect(result.entries[1].failure != nil)
    }
}
