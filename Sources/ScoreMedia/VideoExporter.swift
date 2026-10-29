import Foundation
import AVFoundation
import Metal
import CoreVideo
import ScoreCore

public struct ExportResult: Sendable {
    public let url: URL
    public let frameCount: Int
    public let duration: Double
    public let elapsed: Double
}

public actor VideoExporter {
    public init() {}

    public func export(scene: ScenePlan, audio: RenderedAudio, to destination: URL, progress: @Sendable (Double) -> Void) async throws -> ExportResult {
        let settings = scene.settings.export
        guard settings.width > 0, settings.width <= 1920, settings.height > 0, settings.height <= 1920, settings.width % 2 == 0, settings.height % 2 == 0, settings.fps.d == 1, [30,60].contains(settings.fps.n) else { throw ScoreError.invalid("首版支持横屏或竖屏 1080p、30／60 fps。") }
        let started = Date()
        let working = destination.deletingLastPathComponent().appendingPathComponent(".scorefilm-\(UUID().uuidString).mp4")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: working) } }
        let asset = AVURLAsset(url: audio.url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw ScoreError.invalid("合成音频没有可读取的音轨。") }
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw ScoreError.invalid("无法读取音频。") }
        reader.add(readerOutput)

        let renderer = try MetalSceneRenderer(scene: scene)
        let writer = try AVAssetWriter(outputURL: working, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: settings.width, AVVideoHeightKey: settings.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: settings.fps.n == 60 ? 18_000_000 : 12_000_000, AVVideoExpectedSourceFrameRateKey: settings.fps.n, AVVideoMaxKeyFrameIntervalKey: settings.fps.n * 2, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: settings.width, kCVPixelBufferHeightKey as String: settings.height, kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audio.sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000])
        sound.expectsMediaDataInRealTime = false
        guard writer.canAdd(video), writer.canAdd(sound) else { throw ScoreError.invalid("无法创建视频或 AAC 编码器。") }
        writer.add(video); writer.add(sound)
        guard writer.startWriting() else { throw writer.error ?? ScoreError.invalid("无法写入视频。") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading(), let pool = adaptor.pixelBufferPool else { writer.cancelWriting(); throw reader.error ?? ScoreError.invalid("无法准备导出缓冲。") }
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, renderer.device, nil, &textureCache) == kCVReturnSuccess, let cache = textureCache else { writer.cancelWriting(); throw ScoreError.invalid("无法创建图形缓冲。") }
        let samplesPerFrame = Int64(audio.sampleRate) / Int64(settings.fps.n)
        let count = Int((audio.frameCount + samplesPerFrame - 1) / samplesPerFrame)
        let endTime = CMTime(value: Int64(count), timescale: CMTimeScale(settings.fps.n))
        var frame = 0
        var nextAudio = readerOutput.copyNextSampleBuffer()
        var audioFinished = false; var videoFinished = false
        var lastAdvance = Date()
        do {
            while !videoFinished || !audioFinished {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? ScoreError.invalid("编码器提前停止。") }
                var advanced = false
                if !audioFinished, sound.isReadyForMoreMediaData {
                    if let sample = nextAudio {
                        // Feed each ready input independently. Gating audio on video PTS can
                        // deadlock when the writer waits for another audio interleave chunk.
                        guard sound.append(sample) else { throw writer.error ?? ScoreError.invalid("音频写入失败。") }
                        nextAudio = readerOutput.copyNextSampleBuffer(); advanced = true
                    } else {
                        guard reader.status == .completed else { throw reader.error ?? ScoreError.invalid("音频读取未完成。") }
                        sound.markAsFinished(); audioFinished = true; advanced = true
                    }
                }
                if !videoFinished, video.isReadyForMoreMediaData {
                    try autoreleasepool {
                        var pixel: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel) == kCVReturnSuccess, let pixel else { throw ScoreError.invalid("导出帧内存不足。") }
                        CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                        CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                        CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                        var cvTexture: CVMetalTexture?
                        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixel, nil, .bgra8Unorm, settings.width, settings.height, 0, &cvTexture) == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { throw ScoreError.invalid("无法生成导出纹理。") }
                        let pts = CMTime(value: Int64(frame), timescale: CMTimeScale(settings.fps.n))
                        try renderer.render(time: pts.seconds, to: texture, wait: true)
                        guard adaptor.append(pixel, withPresentationTime: pts) else { throw writer.error ?? ScoreError.invalid("视频帧写入失败。") }
                    }
                    frame += 1; advanced = true
                    if frame % 6 == 0 { progress(0.98 * Double(frame) / Double(count)) }
                    if frame == count { video.markAsFinished(); videoFinished = true }
                }
                if advanced { lastAdvance = Date() }
                else {
                    guard Date().timeIntervalSince(lastAdvance) < 30 else { throw ScoreError.invalid("编码器等待超过 30 秒，已停止此次导出。可以重试或调整导出参数。") }
                    try await Task.sleep(for: .milliseconds(3))
                }
            }
            writer.endSession(atSourceTime: endTime)
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? ScoreError.invalid("视频封装未完成。") }
            try await validateOutput(working, settings: settings, duration: endTime.seconds)
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: working) }
            else { try FileManager.default.moveItem(at: working, to: destination) }
            completed = true; progress(1)
            return ExportResult(url: destination, frameCount: count, duration: endTime.seconds, elapsed: Date().timeIntervalSince(started))
        } catch {
            reader.cancelReading(); writer.cancelWriting(); throw error
        }
    }

    private func validateOutput(_ url: URL, settings: ExportSettings, duration: Double) async throws {
        let asset = AVURLAsset(url: url)
        let pictures = try await asset.loadTracks(withMediaType: .video)
        let sounds = try await asset.loadTracks(withMediaType: .audio)
        guard pictures.count == 1, sounds.count == 1 else { throw ScoreError.invalid("成片的视频或音轨不完整，未替换已有文件。") }
        let size = try await pictures[0].load(.naturalSize)
        let fps = try await pictures[0].load(.nominalFrameRate)
        guard abs(size.width - Double(settings.width)) < 1, abs(size.height - Double(settings.height)) < 1, abs(fps - Float(settings.fps.n)) < 0.01 else { throw ScoreError.invalid("成片画幅或帧率与项目不一致。") }
        for track in [pictures[0], sounds[0]] {
            let range = try await track.load(.timeRange)
            guard range.start.seconds.isFinite, range.duration.seconds.isFinite, abs(range.start.seconds) < 1 / 48000.0, abs(range.duration.seconds - duration) <= 1 / Double(settings.fps.n) else { throw ScoreError.invalid("成片时长或起始位置不完整。") }
        }
        let formats = try await sounds[0].load(.formatDescriptions)
        guard let format = formats.first, let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format), audio.pointee.mSampleRate == 48000, audio.pointee.mChannelsPerFrame == 2 else { throw ScoreError.invalid("成片音轨格式与项目不一致。") }
    }
}
