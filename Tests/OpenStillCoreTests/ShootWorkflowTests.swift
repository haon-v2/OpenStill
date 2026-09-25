import Foundation
import Testing
@testable import OpenStillCore

@Suite struct ShootWorkflowTests {
    func item(_ name:String,_ rating:Int,_ flag:PhotoFlag,_ date:TimeInterval)->ShootItem {
        let url=URL(fileURLWithPath:"/fixtures/"+name)
        var record=PhotoRecord(source:url,fingerprint:name,version:EditVersion(name:"Original",renderer:.linear2020,sourceMode:.original,document:EditDocument(fingerprint:name)))
        record.rating=rating;record.flag=flag
        return ShootItem(url:url,record:record,captured:Date(timeIntervalSince1970:date))
    }
    @Test func filtersAndSortsWithoutDeletingRejects(){
        let items=[item("Photo-10.jpg",5,.reject,3),item("Photo-2.jpg",3,.pick,2),item("Photo-1.jpg",0,.none,1)]
        #expect(ShootWorkflow.filter(items,minimumRating:0,flag:.all,sort:.filename).map{$0.url.lastPathComponent} == ["Photo-1.jpg","Photo-2.jpg","Photo-10.jpg"])
        #expect(ShootWorkflow.filter(items,minimumRating:3,flag:.picks,sort:.rating).count==1)
        #expect(ShootWorkflow.filter(items,minimumRating:0,flag:.rejects,sort:.captured).first?.record.flag == .reject)
        #expect(ShootWorkflow.filter(items,minimumRating:0,flag:.all,sort:.rating).first?.record.rating==5)
        #expect(items.count==3)
    }
    @Test func ratingsPersistWithoutLosingEdits()throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=PhotoRecordStore(root:root),original=item("Photo.jpg",0,.none,0).record
        try store.save(original)
        try store.update(original.id){record in var e=PhotoEdits();e.exposure=1.2;var doc=record.active.document;doc.commit(e,title:"Exposure");record.updateDocument(doc)}
        let marked=try ShootWorkflow.mark(original.id,rating:5,flag:.reject,store:store)
        #expect(marked.active.document.current.exposure==1.2);#expect(marked.rating==5);#expect(marked.flag == .reject)
        let loaded=try PhotoRecordStore(root:root).read(original.id);#expect(loaded.rating==5);#expect(loaded.active.document.steps.count==2)
        #expect(try ShootWorkflow.mark(original.id,rating:100,store:store).rating==5)
    }
}
