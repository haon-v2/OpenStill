import Foundation
import OpenStillCore

final class LogoModelDownload:NSObject,URLSessionDownloadDelegate {
    private var session:URLSession?,task:URLSessionDownloadTask?
    private let lock=NSLock();private var stopped=false,finished=false
    private let manifest:LogoModelManifest.Model,destination:URL
    var progress:((Double,String)->Void)?,completion:((Result<URL,Error>)->Void)?
    init(manifest:LogoModelManifest.Model,destination:URL){self.manifest=manifest;self.destination=destination;super.init()}
    func start(){guard let url=URL(string:manifest.url) else{finish(.failure(LogoError.invalid("Invalid model download address.")));return};let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=60;config.timeoutIntervalForResource=7200;session=URLSession(configuration:config,delegate:self,delegateQueue:nil);task=session?.downloadTask(with:url);task?.resume()}
    func cancel(){lock.lock();stopped=true;lock.unlock();task?.cancel();session?.invalidateAndCancel()}
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64){let fraction=min(1,Double(totalBytesWritten)/Double(manifest.bytes));DispatchQueue.main.async{[weak self] in self?.progress?(fraction,"Downloading \(Int64(Double(totalBytesWritten)/1_000_000)) of 639 MB…")}}
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL){
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode==200 else{throw LogoError.invalid("The model download failed. Try again when the connection is available.")}
            DispatchQueue.main.async{[weak self] in self?.progress?(1,"Verifying model checksum…")}
            guard (try location.resourceValues(forKeys:[.fileSizeKey]).fileSize).map(Int64.init)==manifest.bytes,try PhotoRecordStore.contentHash(location)==manifest.sha256 else{throw LogoError.invalid("The downloaded model failed verification. Please download it again.")}
            lock.lock();let cancelled=stopped;lock.unlock();if cancelled{throw CancellationError()}
            try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            if FileManager.default.fileExists(atPath:destination.path){try FileManager.default.removeItem(at:destination)}
            try FileManager.default.moveItem(at:location,to:destination);finish(.success(destination))
        }catch{finish(.failure(error))}
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){if let error{finish(.failure(error))}}
    private func finish(_ result:Result<URL,Error>){lock.lock();guard !finished else{lock.unlock();return};finished=true;lock.unlock();session?.finishTasksAndInvalidate();session=nil;task=nil;DispatchQueue.main.async{[weak self] in self?.completion?(result)}}
}
