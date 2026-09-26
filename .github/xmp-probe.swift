import Foundation
import ImageIO
let dc = "http://purl.org/dc/elements/1.1/" as CFString
func dump(_ label: String, _ build: (CGMutableImageMetadata) -> Bool) {
    let m = CGImageMetadataCreateMutable()
    let ok = build(m)
    let data = CGImageMetadataCreateXMPData(m, nil) as Data?
    let text = data.map { String(decoding: $0, as: UTF8.self) } ?? "nil"
    let back = CGImageMetadataCopyStringValueWithPath(m, nil, "dc:title" as CFString) as String?
    print("=== \(label): set=\(ok) bytes=\(data?.count ?? -1) readback=\(back ?? "nil")")
    if let r = text.range(of: "<dc:title") { print(text[r.lowerBound...].prefix(260)) }
}
dump("alt+string") { m in CGImageMetadataTagCreate(dc, "dc" as CFString, "title" as CFString, .alternateText, "Hello" as CFString).map { CGImageMetadataSetTagWithPath(m, nil, "dc:title" as CFString, $0) } ?? false }
dump("alt+[string]") { m in CGImageMetadataTagCreate(dc, "dc" as CFString, "title" as CFString, .alternateText, ["Hello"] as CFArray).map { CGImageMetadataSetTagWithPath(m, nil, "dc:title" as CFString, $0) } ?? false }
dump("alt+dict") { m in CGImageMetadataTagCreate(dc, "dc" as CFString, "title" as CFString, .alternateText, ["x-default": "Hello"] as CFDictionary).map { CGImageMetadataSetTagWithPath(m, nil, "dc:title" as CFString, $0) } ?? false }
dump("alt+[tag]") { m in
    guard let item = CGImageMetadataTagCreate(dc, "dc" as CFString, "title" as CFString, .string, "Hello" as CFString),
          let tag = CGImageMetadataTagCreate(dc, "dc" as CFString, "title" as CFString, .alternateText, [item] as CFArray) else { return false }
    return CGImageMetadataSetTagWithPath(m, nil, "dc:title" as CFString, tag)
}
dump("path[x-default]") { m in CGImageMetadataSetValueWithPath(m, nil, "dc:title[x-default]" as CFString, "Hello" as CFString) }
dump("path plain") { m in CGImageMetadataSetValueWithPath(m, nil, "dc:title" as CFString, "Hello" as CFString) }
dump("path alt-lang") { m in CGImageMetadataSetValueWithPath(m, nil, "dc:title[?xml:lang=x-default]" as CFString, "Hello" as CFString) }
dump("parse template") { m in
    let xml = #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title><rdf:Alt><rdf:li xml:lang="x-default">Hello</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta>"#
    guard let parsed = CGImageMetadataCreateFromXMPData(Data(xml.utf8) as CFData), let tag = CGImageMetadataCopyTagWithPath(parsed, nil, "dc:title" as CFString) else { return false }
    print("parsed type", CGImageMetadataTagGetType(tag).rawValue, "value", CGImageMetadataTagCopyValue(tag) as Any)
    return CGImageMetadataSetTagWithPath(m, nil, "dc:title" as CFString, tag)
}
