import AVFoundation
import Core
import CoreVideo
import SceneBridge

// The lock screen only plays videos, so a scene shown there is first rendered into a short loop,
// once per screen size, and cached next to the scene (see LockRenderCache).

enum LockSceneRecorder {
    static let fps = 30
    static let loopSeconds = 10.0

    enum Failure: LocalizedError {
        case writer(String)
        var errorDescription: String? {
            switch self {
            case .writer(let reason): return "Couldn’t make the lock screen video: \(reason)"
            }
        }
    }

    /// Renders `item` off screen at `width`×`height` into the cache and returns the video's URL.
    /// Runs off the main actor; a scene takes a few seconds per 10-second loop.
    static func render(_ item: VideoItem, width: Int, height: Int) async throws -> URL {
        let video = LockRenderCache.videoURL(for: item, width: width, height: height)
        let partial = LockRenderCache.partialURL(for: item, width: width, height: height)
        let stamp = LockRenderCache.sourceStamp(for: item)
        try? FileManager.default.removeItem(at: partial)

        let renderer = try Renderer(pkgPath: item.url.path)
        renderer.resize(width: UInt32(width), height: UInt32(height))
        renderer.setMuted(muted: true)
        // The loop is recorded once, so a clock or date the scene computes would freeze at this time.
        renderer.setHideScriptedText(hide: true)
        defer { renderer.stop() }

        let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure.writer("no video track") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(loopSeconds * Double(fps))
        for frame in 0..<frames {
            try Task.checkCancellation()
            // The renderer returns BGRA rows, top first, tightly packed.
            let pixels = try renderer.renderFrame(time: Double(frame) / Double(fps))
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure.writer("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                pixels.withUnsafeBytes { src in
                    for row in 0..<height {
                        memcpy(base + row * stride, src.baseAddress! + row * width * 4, width * 4)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw Failure.writer(writer.error?.localizedDescription ?? "append")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.writer(writer.error?.localizedDescription ?? "finish")
        }

        try? FileManager.default.removeItem(at: video)
        try FileManager.default.moveItem(at: partial, to: video)
        try LockRenderCache.writeMeta(.init(width: width, height: height, fps: fps, loopSeconds: loopSeconds,
                                            sourceStamp: stamp), for: item)
        LockRenderCache.removeStale(for: item, keepingWidth: width, height: height)
        return video
    }
}
