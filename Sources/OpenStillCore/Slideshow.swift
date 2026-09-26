import Foundation
import CoreImage
import AVFoundation
import CoreVideo

public enum SlideTransition: String, Codable, CaseIterable, Sendable {
    case cut, crossfade, fadeThroughBlack
    public var title: String { self == .cut ? "Cut" : self == .crossfade ? "Crossfade" : "Fade through black" }
}
public struct SlideshowSettings: Codable, Equatable, Sendable {
    public var secondsPerSlide = 4.0
    public var transition = SlideTransition.crossfade
    public var transitionSeconds = 1.0
    /// Slow zoom and pan across each photo.
    public var kenBurns = true
    public var loop = true
    /// Music file (MP3, AAC, WAV…), played during the show and mixed into exported video.
    public var musicPath: String?
    /// Exported video size and frame rate.
    public var width = 1920, height = 1080, fps = 30
    public init() {}
    public var sanitized: Self {
        var s = self
        func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double { v.isFinite ? min(hi, max(lo, v)) : fallback }
        s.secondsPerSlide = clamp(secondsPerSlide, 1, 60, 4)
        s.transitionSeconds = transition == .cut ? 0 : clamp(transitionSeconds, 0.2, s.secondsPerSlide / 2, 1)
        s.width = min(3840, max(320, width / 2 * 2)); s.height = min(2160, max(180, height / 2 * 2)); s.fps = min(60, max(12, fps))
        return s
    }
    public func duration(slides: Int) -> Double { Double(max(0, slides)) * sanitized.secondsPerSlide }
}

public enum SlideshowError: LocalizedError {
    case noPhotos, writer(String), music
    public var errorDescription: String? {
        switch self {
        case .noPhotos: return "Choose at least one photo for the slideshow."
        case .writer(let why): return "The video couldn’t be written: \(why)"
        case .music: return "The music file couldn’t be read. Choose an MP3, AAC, M4A or WAV file."
        }
    }
}

public enum SlideshowRenderer {
    /// Fits a photo into the frame on black, with an optional slow zoom (`progress` 0…1 through the slide).
    public static func slide(_ image: CIImage, frame: CGSize, progress: Double, kenBurns: Bool, index: Int) -> CIImage {
        let photo = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let size = photo.extent.size
        guard size.width > 0, size.height > 0 else { return black(frame) }
        var scale = min(frame.width / size.width, frame.height / size.height)
        var dx = 0.0, dy = 0.0
        if kenBurns {
            // Alternate zooming in and out, drifting a little, so consecutive slides don't all move the same way.
            let t = min(1, max(0, progress)), zoomIn = index % 2 == 0
            let zoom = 1 + 0.08 * (zoomIn ? t : 1 - t)
            scale *= zoom
            let drift = (zoom - 1) * 0.5
            dx = (index % 3 == 0 ? -1 : 1) * drift * frame.width * (t - 0.5)
            dy = (index % 4 < 2 ? -1 : 1) * drift * frame.height * (t - 0.5)
        }
        let w = size.width * scale, h = size.height * scale
        let placed = photo.transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: (frame.width - w) / 2 + dx, y: (frame.height - h) / 2 + dy)))
        return placed.composited(over: black(frame)).cropped(to: CGRect(origin: .zero, size: frame))
    }
    static func black(_ frame: CGSize) -> CIImage { CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: frame)) }
    /// The frame at `time` seconds. Each slide lasts `secondsPerSlide`; the transition into the next slide overlaps its end.
    public static func frame(at time: Double, slides: [CIImage], settings: SlideshowSettings, size: CGSize) -> CIImage {
        let s = settings.sanitized
        guard !slides.isEmpty else { return black(size) }
        let per = s.secondsPerSlide, index = min(slides.count - 1, max(0, Int(time / per)))
        let local = time - Double(index) * per
        func show(_ i: Int, _ t: Double) -> CIImage { slide(slides[i], frame: size, progress: t / per, kenBurns: s.kenBurns, index: i) }
        let current = show(index, local)
        let into = local - (per - s.transitionSeconds)
        guard s.transition != .cut, into > 0, index + 1 < slides.count || (s.loop && slides.count > 1) else { return current }
        let nextIndex = (index + 1) % slides.count
        let next = show(nextIndex, into)
        let f = min(1, max(0, into / s.transitionSeconds))
        switch s.transition {
        case .cut: return current
        case .crossfade: return current.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: next, kCIInputTimeKey: f])
        case .fadeThroughBlack:
            return f < 0.5 ? dim(current, 1 - f * 2) : dim(next, (f - 0.5) * 2)
        }
    }
    static func dim(_ image: CIImage, _ level: Double) -> CIImage {
        let v = CIVector(x: level, y: 0, z: 0, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": v, "inputGVector": CIVector(x: 0, y: level, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: level, w: 0)])
    }

    /// Renders an H.264 movie (with the music, trimmed or looped to the show's length) to `url`.
    /// `slides` are the edited photos; they're scaled down to the frame size first.
    public static func exportVideo(_ slides: [CIImage], settings: SlideshowSettings, to url: URL, progress: ((Double) -> Void)? = nil, cancelled: @escaping () -> Bool = { false }) async throws {
        var s = settings.sanitized; s.loop = false
        guard !slides.isEmpty else { throw SlideshowError.noPhotos }
        let size = CGSize(width: s.width, height: s.height)
        // Pre-scale so each frame doesn't resample a full-size photo.
        let prepared: [CIImage] = slides.map { image in
            let scale = min(1, 1.15 * max(size.width / image.extent.width, size.height / image.extent.height))
            guard scale < 1 else { return image }
            let small = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            guard let cg = ModernRenderer.context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return small }
            return CIImage(cgImage: cg)
        }
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mov) } catch { throw SlideshowError.writer(error.localizedDescription) }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: s.width, AVVideoHeightKey: s.height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: s.width, kCVPixelBufferHeightKey as String: s.height,
        ])
        guard writer.canAdd(video) else { throw SlideshowError.writer("no video track") }
        writer.add(video)
        let duration = s.duration(slides: prepared.count)
        let audio = try await musicSamples(s.musicPath, duration: duration)
        var audioInput: AVAssetWriterInput?
        if audio != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }
        guard writer.startWriting() else { throw SlideshowError.writer(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: .zero)
        let frames = Int((duration * Double(s.fps)).rounded()), space = CGColorSpace(name: CGColorSpace.sRGB)!
        var nextAudio = 0
        // The writer interleaves tracks, so audio is fed alongside the frames rather than after them.
        // Never wait on audio while video is still to come: the writer may be holding audio back until it gets more video.
        // A stuck writer is reported with its state rather than hanging forever.
        func stalled(_ step: String) -> SlideshowError {
            .writer("\(step) stalled (writer \(writer.status.rawValue), video ready \(video.isReadyForMoreMediaData), audio ready \(audioInput?.isReadyForMoreMediaData ?? false), audio \(nextAudio)/\(audio?.count ?? 0)): \(writer.error?.localizedDescription ?? "no error")")
        }
        func feedAudio(until seconds: Double, wait: Bool = false) async throws {
            guard let audioInput, let audio else { return }
            let started = Date()
            while nextAudio < audio.count, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(audio[nextAudio])) <= seconds {
                if audioInput.isReadyForMoreMediaData {
                    audioInput.append(audio[nextAudio]); nextAudio += 1
                    // Once the music is all in, tell the writer so it stops waiting for more.
                    if nextAudio == audio.count { audioInput.markAsFinished() }
                }
                else if wait {
                    if Date().timeIntervalSince(started) > 20 { throw stalled("Music") }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                else { return }
            }
        }
        for n in 0..<frames {
            if cancelled() { writer.cancelWriting(); throw CocoaError(.userCancelled) }
            try await feedAudio(until: Double(n) / Double(s.fps) + 0.5)
            let waiting = Date()
            while !video.isReadyForMoreMediaData {
                if Date().timeIntervalSince(waiting) > 20 { writer.cancelWriting(); throw stalled("Frame \(n)") }
                try await feedAudio(until: Double(n) / Double(s.fps) + 1)
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw SlideshowError.writer(writer.error?.localizedDescription ?? "no pixel buffers") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw SlideshowError.writer("no pixel buffer") }
            let image = frame(at: Double(n) / Double(s.fps), slides: prepared, settings: s, size: size)
            ModernRenderer.context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: space)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(s.fps))) else { throw SlideshowError.writer(writer.error?.localizedDescription ?? "frame \(n)") }
            if n % 15 == 0 { progress?(Double(n) / Double(max(1, frames))) }
        }
        video.markAsFinished()
        try await feedAudio(until: duration + 1, wait: true)
        if let audioInput, let audio, nextAudio < audio.count { audioInput.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw SlideshowError.writer(writer.error?.localizedDescription ?? "unfinished") }
        progress?(1)
    }

    /// Decoded music as PCM sample buffers covering `duration` seconds, or nil without music.
    /// A short track is repeated in an audio composition, so every repeat has correct timing.
    static func musicSamples(_ path: String?, duration: Double) async throws -> [CMSampleBuffer]? {
        guard let path, !path.isEmpty else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { throw SlideshowError.music }
        let length = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        guard length > 0.1 else { throw SlideshowError.music }
        let composition = AVMutableComposition()
        guard let music = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SlideshowError.music }
        var offset = 0.0
        while offset < duration {
            let piece = min(length, duration - offset)
            do {
                try music.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: piece, preferredTimescale: 44_100)), of: track, at: CMTime(seconds: offset, preferredTimescale: 44_100))
            } catch { throw SlideshowError.music }
            offset += piece
        }
        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: composition) } catch { throw SlideshowError.music }
        let output = AVAssetReaderTrackOutput(track: music, outputSettings: pcm)
        reader.add(output)
        guard reader.startReading() else { throw SlideshowError.music }
        var out: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() { out.append(sample) }
        guard reader.status == .completed, !out.isEmpty else { throw SlideshowError.music }
        return out
    }
}
