import AppKit
import OpenStillCore

final class PhotoStore {
    private let images = NSCache<NSString, ImageBox>()
    private let thumbnails = NSCache<NSString, ImageBox>()
    private let imageQueue = OperationQueue()
    private let thumbnailQueue = OperationQueue()

    init() {
        images.totalCostLimit = 256 * 1024 * 1024
        thumbnails.totalCostLimit = 48 * 1024 * 1024
        imageQueue.maxConcurrentOperationCount = 2
        imageQueue.qualityOfService = .userInitiated
        thumbnailQueue.maxConcurrentOperationCount = 3
        thumbnailQueue.qualityOfService = .utility
    }

    func reset() {
        imageQueue.cancelAllOperations()
        thumbnailQueue.cancelAllOperations()
        images.removeAllObjects()
        thumbnails.removeAllObjects()
    }

    func cancelImageRequests() { imageQueue.cancelAllOperations() }

    func load(_ url: URL, thumbnail: Bool = false, version: EditVersion? = nil, completion: @escaping (Result<DecodedPhoto, Error>) -> Void) {
        let cache = thumbnail ? thumbnails : images
        let rawKey = version?.raw.cacheKey ?? ""
        let key = "\(url.path)|\(EditStorage.fingerprint(url))|\(version?.sourceMode.rawValue ?? "legacy")|\(version?.renderer.rawValue ?? "legacy")|\(rawKey)" as NSString
        if let cached = cache.object(forKey: key) {
            completion(.success(cached.photo))
            return
        }
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = Result { () -> DecodedPhoto in
                if !thumbnail, let version, version.renderer == .linear2020, RenderCache.applies(url, mode: version.sourceMode) {
                    // RAW: open from the screen-size proxy (decoded once, then cached on disk); the full decode waits until needed.
                    let proxy = try ModernRenderer.proxy(url, mode:version.sourceMode, raw:version.raw)
                    return DecodedPhoto(preview:try ModernRenderer.display(proxy.image), pixelSize:proxy.fullSize, rendering:.rawDevelopment,
                                        sourceImage:proxy.image, full:{ try ModernRenderer.display(ModernRenderer.source(url, mode:version.sourceMode, raw:version.raw, fast:true)) })
                }
                if !thumbnail, let version, version.renderer == .linear2020 {
                    let source = try ModernRenderer.source(url, mode:version.sourceMode, raw:version.raw, fast:true)
                    // The screen gets a preview; the full frame is only made if a tool needs every pixel.
                    return DecodedPhoto(preview:try ModernRenderer.screenImage(source), pixelSize:source.extent.size,
                                        rendering:version.sourceMode == .raw ? .rawDevelopment : (version.sourceMode == .cameraLook ? .cameraPreview : .original),
                                        sourceImage:source, full:{ try ModernRenderer.display(source) })
                }
                return try PhotoDecoder.render(url, maxPixelSize: thumbnail ? 240 : nil)
            }
            guard operation?.isCancelled == false else { return }
            if case .success(let photo) = result {
                cache.setObject(ImageBox(photo), forKey: key, cost: photo.preview.bytesPerRow * photo.preview.height)
            }
            DispatchQueue.main.async { completion(result) }
        }
        (thumbnail ? thumbnailQueue : imageQueue).addOperation(operation)
    }
}

private final class ImageBox {
    let photo: DecodedPhoto
    init(_ photo: DecodedPhoto) { self.photo = photo }
}
