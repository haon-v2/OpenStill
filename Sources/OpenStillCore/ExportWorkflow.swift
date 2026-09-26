import Foundation
import Darwin

public struct ExportPreset:Codable,Identifiable {
    public var id=UUID(),name:String,settings:ExportSettings
    public init(name:String,settings:ExportSettings){self.name=name;self.settings=settings}
}
public enum ExportPresets {
    public static func load(root:URL = EditStorage.root)->[ExportPreset] {(try? JSONDecoder().decode([ExportPreset].self,from:Data(contentsOf:root.appendingPathComponent("ExportPresets.json")))) ?? []}
    public static func save(_ presets:[ExportPreset],root:URL = EditStorage.root)throws{try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);try JSONEncoder().encode(presets).write(to:root.appendingPathComponent("ExportPresets.json"),options:.atomic)}
}
public enum ExportJobState:String,Codable{case waiting,running,complete,failed,cancelled}
public struct ExportJob:Codable,Identifiable {
    public var id=UUID(),source:URL,sourceHash:String,recipe:RenderRecipe,versionName:String,captured:Date
    public var output:URL?,state=ExportJobState.waiting,error:String?
    public var metadata:IPTCMetadata?
    public init(_ item:ShootItem){source=item.url;sourceHash=item.record.contentFingerprint;recipe=item.record.active.recipe;versionName=item.record.active.name;captured=item.captured;metadata=item.record.metadata}
}
public struct ExportBatch:Codable,Identifiable {
    public var id=UUID(),jobs:[ExportJob],settings:ExportSettings,directory:URL
    public init(items:[ShootItem],settings:ExportSettings,directory:URL){jobs=items.map(ExportJob.init);self.settings=settings.sanitized;self.directory=directory}
}
public enum ExportWorkflowError:LocalizedError {
    case filename,directory
    public var errorDescription:String?{self == .filename ? "Use {name}, {index}, {date}, or {version} in a filename without slashes or path components.":"Choose an existing writable export folder."}
}
public enum ExportWorkflow {
    /// All full-resolution queued exports share one worker, leaving CPU/GPU time for editing previews.
    public static let queue:OperationQueue={let q=OperationQueue();q.name="OpenStill export queue";q.maxConcurrentOperationCount=1;q.qualityOfService = .utility;return q}()
    public static func filename(_ job:ExportJob,index:Int,settings:ExportSettings)throws->String {
        let date=ISO8601DateFormatter().string(from:job.captured).prefix(10)
        func safe(_ text:String)->String{text.replacingOccurrences(of:"/",with:"-").replacingOccurrences(of:":",with:"-").replacingOccurrences(of:"\\",with:"-")}
        var name=settings.filenameTemplate
        for (key,value) in [("name",job.source.deletingPathExtension().lastPathComponent),("index",String(format:"%03d",index+1)),("date",String(date)),("version",job.versionName)]{name=name.replacingOccurrences(of:"{\(key)}",with:safe(value))}
        guard !name.isEmpty,name != ".",name != "..",name.utf8.count<220,!name.contains("/"),!name.contains("\\"),!name.contains(":"),!name.contains("{"),!name.contains("}"),!name.unicodeScalars.contains(where:{$0.value<32}) else{throw ExportWorkflowError.filename}
        return name+"."+(settings.format == .jpeg ? "jpg":settings.format.rawValue)
    }
    private static func reserve(_ name:String,directory:URL,protected:Set<URL>)throws->URL {
        let original=URL(fileURLWithPath:name),stem=original.deletingPathExtension().lastPathComponent,ext=original.pathExtension
        for number in 0..<100_000 {
            let candidate=directory.appendingPathComponent(stem+(number==0 ? "":"-\(number)")+"."+ext)
            if protected.contains(candidate.standardizedFileURL.resolvingSymlinksInPath()){continue}
            let fd=open(candidate.path,O_WRONLY|O_CREAT|O_EXCL,0o600)
            if fd>=0{close(fd);return candidate}
            if errno != EEXIST{throw CocoaError(.fileWriteNoPermission)}
        }
        throw ExportWorkflowError.filename
    }
    /// Retry resumes only unfinished jobs. Successfully exported files are never removed.
    public static func run(_ batch:ExportBatch,cancelled:()->Bool={false},progress:(ExportBatch)->Void={_ in})->ExportBatch {
        var result=batch
        let protected=Set(batch.jobs.map{$0.source.standardizedFileURL.resolvingSymlinksInPath()})
        for i in result.jobs.indices where result.jobs[i].state != .complete {
            if cancelled(){result.jobs[i].state = .cancelled;continue}
            result.jobs[i].state = .running;result.jobs[i].error=nil;progress(result)
            do {
                try autoreleasepool {
                    let job=result.jobs[i]
                    guard try PhotoRecordStore.contentHash(job.source)==job.sourceHash else{throw WorkflowError.changedSource}
                    let name=try filename(job,index:i,settings:batch.settings)
                    let output=try reserve(name,directory:batch.directory,protected:protected)
                    do {
                        let image=try ModernRenderer.render(source:job.source,recipe:job.recipe)
                        try ModernRenderer.export(image,to:output,source:job.source,settings:batch.settings,metadata:batch.settings.keepMetadata ? job.metadata:nil)
                        result.jobs[i].output=output;result.jobs[i].state = .complete
                    }catch{try? FileManager.default.removeItem(at:output);throw error}
                }
            }catch{result.jobs[i].state = .failed;result.jobs[i].error=error.localizedDescription}
            progress(result)
        }
        progress(result);return result
    }
}
