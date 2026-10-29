import Foundation
import AVFAudio
import Observation

@MainActor @Observable
public final class AudioTransport {
    public private(set) var isPlaying = false
    public var position = 0.0
    public private(set) var duration = 0.0
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startFrame: Int64 = 0
    @ObservationIgnored private var scheduled = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var deviceObserver: (any NSObjectProtocol)?
    public private(set) var deviceChangeCount = 0

    public init() {
        engine.attach(player)
        deviceObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleDeviceConfigurationChange()
            }
        }
    }

    public var time: Double {
        guard isPlaying, let file, let render = player.lastRenderTime, let clock = player.playerTime(forNodeTime: render) else { return position }
        let latency = engine.outputNode.presentationLatency
        return min(duration, max(Double(startFrame) / file.processingFormat.sampleRate, Double(startFrame + clock.sampleTime) / file.processingFormat.sampleRate - latency))
    }

    func handleDeviceConfigurationChange() {
        guard isPlaying else { return }
        let current = time
        pause(); seek(to: current); deviceChangeCount += 1
    }

    public func load(_ audio: RenderedAudio) throws {
        stop()
        engine.stop()
        let file = try AVAudioFile(forReading: audio.url)
        self.file = file; duration = audio.duration; position = 0
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        seek(to: 0)
    }

    public func play() throws {
        guard file != nil else { return }
        if !engine.isRunning { try engine.start() }
        if position >= duration - 0.02 { seek(to: 0) }
        if !scheduled { seek(to: position) }
        player.play(); isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.position = self.time
            }
        }
    }

    public func pause() {
        let current = time
        player.pause(); isPlaying = false; position = current
        timer?.invalidate(); timer = nil
    }

    public func seek(to seconds: Double) {
        guard let file else { position = 0; return }
        let resume = isPlaying
        player.stop(); generation += 1
        position = min(duration, max(0, seconds))
        startFrame = min(file.length, Int64(position * file.processingFormat.sampleRate))
        let count = file.length - startFrame
        scheduled = count > 0
        if count > 0 {
            let token = generation
            player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(min(count, Int64(UInt32.max))), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token, self.engine.isRunning else { return }
                    self.isPlaying = false; self.scheduled = false; self.position = self.duration
                    self.timer?.invalidate(); self.timer = nil
                }
            }
        }
        if resume, scheduled { player.play() }
        else { isPlaying = false }
    }

    public func stop() {
        generation += 1
        player.stop(); isPlaying = false; position = 0; scheduled = false
        timer?.invalidate(); timer = nil
    }

    public func unload() {
        stop(); engine.stop(); file = nil; duration = 0
    }

    public func shutdown() {
        unload()
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
        deviceObserver = nil
    }
}
