import Foundation
import ImageIO

public enum ShootSort:String,CaseIterable {case filename,captured,rating}
public enum ShootFlagFilter:String,CaseIterable {case all,picks,rejects,unflagged}
public struct ShootItem:Identifiable {
    public let url:URL
    public var record:PhotoRecord
    public let captured:Date
    public var id:UUID{record.id}
    public init(url:URL,record:PhotoRecord,captured:Date){self.url=url;self.record=record;self.captured=captured}
    public static func read(_ url:URL)throws->Self {
        let record=try EditStorage.record(url)
        var date=(try? url.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? Date.distantPast
        if let io=CGImageSourceCreateWithURL(url as CFURL,nil),let props=CGImageSourceCopyPropertiesAtIndex(io,0,nil) as? [String:Any],
           let exif=props[kCGImagePropertyExifDictionary as String] as? [String:Any],let stamp=exif["DateTimeOriginal"] as? String {
            let parser=DateFormatter();parser.locale=Locale(identifier:"en_US_POSIX");parser.timeZone=TimeZone(secondsFromGMT:0);parser.dateFormat="yyyy:MM:dd HH:mm:ss";date=parser.date(from:stamp) ?? date
        }
        return Self(url:url,record:record,captured:date)
    }
}
public enum ShootWorkflow {
    public static func filter(_ items:[ShootItem],minimumRating:Int,flag:ShootFlagFilter,sort:ShootSort)->[ShootItem] {
        items.filter { item in
            item.record.rating >= min(5,max(0,minimumRating)) && (flag == .all || (flag == .picks && item.record.flag == .pick) || (flag == .rejects && item.record.flag == .reject) || (flag == .unflagged && item.record.flag == .none))
        }.sorted {a,b in
            if sort == .rating && a.record.rating != b.record.rating{return a.record.rating>b.record.rating}
            if sort == .captured && a.captured != b.captured{return a.captured<b.captured}
            let order=a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
            return order == .orderedSame ? a.url.path<b.url.path:order == .orderedAscending
        }
    }
    @discardableResult public static func mark(_ id:UUID,rating:Int? = nil,flag:PhotoFlag? = nil,store:PhotoRecordStore = EditStorage.records)throws->PhotoRecord {
        try store.update(id) {record in if let rating{record.rating=min(5,max(0,rating))};if let flag{record.flag=flag} }
    }
}
