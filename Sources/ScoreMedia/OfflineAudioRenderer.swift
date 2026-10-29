import Foundation
import AVFAudio
import AudioToolbox
import Accelerate
import ScoreCore

public struct RenderedAudio: Sendable {
    public let url: URL
    public let frameCount: Int64
    public let sampleRate: Double
    public var duration: Double { Double(frameCount) / sampleRate }
}

public actor OfflineAudioRenderer {
    public init() {}
    #if DEBUG
    private var validationInstrument: URL?
    public init(validationInstrument: URL) { self.validationInstrument = validationInstrument }
    #endif

    public func render(plan: PerformancePlan, project: ProjectFile, to url: URL, progress: @Sendable (Double) -> Void) throws -> RenderedAudio {
        let instances = Set(plan.notes.map(\.instanceID)).sorted()
        guard instances.count <= 128 else { throw ScoreError.unsupported("此曲需要超过 128 个独立乐器实例，暂不支持。") }
        guard instances.count > 8 || plan.notes.contains(where: { $0.volume != 1 }) else {
            return try renderSingle(plan: plan, project: project, to: url, instances: nil, normalize: true, progress: progress)
        }
        // Render unscaled stems on the original clock. Keep a reference mix at
        // unity faders so output calibration cannot undo the user's balance.
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ScoreError.invalid("音频缓存目标已存在。") }
        let folder = url.deletingLastPathComponent()
        var volumes: [String: Double] = [:]
        for note in plan.notes where volumes[note.instanceID] == nil { volumes[note.instanceID] = note.volume }
        let byVolume = Dictionary(grouping: instances, by: { volumes[$0] ?? 1 })
        let groups = byVolume.keys.sorted().flatMap { volume in
            let ids = byVolume[volume]!
            return stride(from: 0, to: ids.count, by: 8).map { (instances: Set(ids[$0..<min($0 + 8, ids.count)]), volume: Float(volume)) }
        }
        var stems: [RenderedAudio] = []
        let mixedURL = folder.appendingPathComponent("mix-\(UUID().uuidString).caf")
        var completed = false
        defer {
            for stem in stems { try? FileManager.default.removeItem(at: stem.url) }
            try? FileManager.default.removeItem(at: mixedURL)
            if !completed { try? FileManager.default.removeItem(at: url) }
        }
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            let stemURL = folder.appendingPathComponent("stem-\(UUID().uuidString).caf")
            let stem = try renderSingle(plan: plan, project: project, to: stemURL, instances: group.instances, normalize: false) { value in
                progress(0.8 * (Double(index) + value) / Double(groups.count))
            }
            stems.append(stem)
        }
        let rate = 48_000.0
        let frames = stems.map(\.frameCount).max() ?? 0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let reference = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let mixedChannels = mixed.floatChannelData, let referenceChannels = reference.floatChannelData, let inputChannels = input.floatChannelData else {
            throw ScoreError.invalid("无法创建分组混音缓冲。")
        }
        let sources = try stems.map { try AVAudioFile(forReading: $0.url) }
        var file: AVAudioFile? = try AVAudioFile(forWriting: mixedURL, settings: format.settings)
        var position: Int64 = 0
        var peak: Float = 0
        var referencePeak: Float = 0
        while position < frames {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(4096, frames - position))
            mixed.frameLength = count
            reference.frameLength = count
            for channel in 0..<2 {
                mixedChannels[channel].initialize(repeating: 0, count: Int(count))
                referenceChannels[channel].initialize(repeating: 0, count: Int(count))
            }
            for (source, group) in zip(sources, groups) {
                let available = min(Int64(count), source.length - source.framePosition)
                guard available > 0 else { continue }
                try source.read(into: input, frameCount: AVAudioFrameCount(available))
                guard Int64(input.frameLength) == available else { throw ScoreError.invalid("分组音频缓存提前结束。") }
                var volume = group.volume
                for channel in 0..<2 {
                    vDSP_vadd(referenceChannels[channel], 1, inputChannels[channel], 1, referenceChannels[channel], 1, vDSP_Length(input.frameLength))
                    vDSP_vsma(inputChannels[channel], 1, &volume, mixedChannels[channel], 1, mixedChannels[channel], 1, vDSP_Length(input.frameLength))
                }
            }
            peak = max(peak, try Self.validatedPeak(mixed))
            referencePeak = max(referencePeak, try Self.validatedPeak(reference))
            try file?.write(from: mixed)
            position += Int64(count)
            progress(0.8 + 0.1 * Double(position) / Double(max(1, frames)))
        }
        file = nil
        let source = try AVAudioFile(forReading: mixedURL)
        let destination = try AVAudioFile(forWriting: url, settings: format.settings)
        var gain = outputGain(peak: peak, referencePeak: referencePeak, masterVolume: project.settings.performance.masterVolume ?? 1)
        position = 0
        while position < frames {
            try Task.checkCancellation()
            try source.read(into: mixed, frameCount: AVAudioFrameCount(min(4096, frames - position)))
            guard mixed.frameLength > 0 else { throw ScoreError.invalid("混音缓存提前结束。") }
            for channel in 0..<2 { vDSP_vsmul(mixedChannels[channel], 1, &gain, mixedChannels[channel], 1, vDSP_Length(mixed.frameLength)) }
            try destination.write(from: mixed)
            position += Int64(mixed.frameLength)
            progress(0.9 + 0.1 * Double(position) / Double(max(1, frames)))
        }
        completed = true
        return RenderedAudio(url: url, frameCount: frames, sampleRate: rate)
    }

    private func renderSingle(plan: PerformancePlan, project: ProjectFile, to url: URL, instances: Set<String>?, normalize: Bool, progress: @Sendable (Double) -> Void) throws -> RenderedAudio {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ScoreError.invalid("音频缓存目标已存在。") }
        let notes = plan.notes.filter { instances?.contains($0.instanceID) ?? true }
        let rate = 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw ScoreError.invalid("无法创建音频缓冲。") }
        let rawURL = url.deletingLastPathComponent().appendingPathComponent("raw-\(UUID().uuidString).caf")
        let engine = AVAudioEngine()
        let bus = AVAudioMixerNode()
        let room = AVAudioUnitReverb()
        room.auAudioUnit.isRenderingOffline = true
        room.loadFactoryPreset(.mediumRoom)
        engine.attach(bus); engine.attach(room)
        engine.connect(bus, to: room, format: format)
        engine.connect(room, to: engine.mainMixerNode, format: format)
        var samplers: [String: AVAudioUnitSampler] = [:]
        var descriptions: [String: PlaybackNote] = [:]
        var completed = false
        defer {
            engine.stop()
            try? FileManager.default.removeItem(at: rawURL)
            if !completed { try? FileManager.default.removeItem(at: url) }
        }
        for note in notes where samplers[note.instanceID] == nil {
            try Task.checkCancellation()
            guard samplers.count < 128 else { throw ScoreError.unsupported("此曲需要超过 128 个独立乐器实例，暂不支持。") }
            let sampler = AVAudioUnitSampler()
            sampler.auAudioUnit.isRenderingOffline = true
            // Disk streaming can emit corrupt PCM during fast offline rendering
            // even with the offline hint. Make samples resident when loading
            // the instrument, before the first render.
            var streamFromDisk: UInt32 = 0
            let streamStatus = AudioUnitSetProperty(sampler.audioUnit, kMusicDeviceProperty_StreamFromDisk, kAudioUnitScope_Global, 0, &streamFromDisk, UInt32(MemoryLayout<UInt32>.size))
            guard streamStatus == noErr else { throw ScoreError.invalid("无法配置乐器的离线采样模式：\(streamStatus)") }
            let bankURL: URL
            if note.instrument.bank.kind == "builtin" { bankURL = MediaResources.soundBank }
            else {
                guard let path = note.instrument.bank.path, let bytes = project.entries[path], ProjectFile.digest(bytes) == note.instrument.bank.sha256 else { throw ScoreError.invalid("内嵌音源缺失或校验失败。") }
                let folder = url.deletingLastPathComponent().appendingPathComponent("Banks", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                bankURL = folder.appendingPathComponent(ProjectFile.digest(bytes) + "." + URL(fileURLWithPath: path).pathExtension)
                if !FileManager.default.fileExists(atPath: bankURL.path) { try bytes.write(to: bankURL, options: .atomic) }
            }
            #if DEBUG
            if let validationInstrument { try sampler.loadAudioFiles(at: [validationInstrument]) }
            else {
                guard FileManager.default.isReadableFile(atPath: bankURL.path) else { throw ScoreError.invalid("乐器音源缺失或无法读取，请检查工程音源或重新安装应用。") }
                try sampler.loadSoundBankInstrument(at: bankURL, program: UInt8(note.instrument.program), bankMSB: UInt8(note.instrument.bankMSB), bankLSB: UInt8(note.instrument.bankLSB))
            }
            #else
            guard FileManager.default.isReadableFile(atPath: bankURL.path) else { throw ScoreError.invalid("乐器音源缺失或无法读取，请检查工程音源或重新安装应用。") }
            try sampler.loadSoundBankInstrument(at: bankURL, program: UInt8(note.instrument.program), bankMSB: UInt8(note.instrument.bankMSB), bankLSB: UInt8(note.instrument.bankLSB))
            #endif
            engine.attach(sampler)
            engine.connect(sampler, to: bus, format: format)
            samplers[note.instanceID] = sampler; descriptions[note.instanceID] = note
        }
        if samplers.isEmpty {
            let silent = AVAudioPlayerNode(); engine.attach(silent)
            engine.connect(silent, to: bus, format: format)
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        room.auAudioUnit.reset()
        room.wetDryMix = Float(project.settings.performance.reverbWetDryMix ?? 12)
        for (id, sampler) in samplers {
            sampler.auAudioUnit.reset()
            if let note = descriptions[id] {
                sampler.overallGain = Float(max(-90, note.instrument.gainDB))
                sampler.stereoPan = Float(note.instrument.pan * 100)
            }
        }
        var file: AVAudioFile? = try AVAudioFile(forWriting: rawURL, settings: format.settings)
        enum Action { case on(Int, Int), off(Int), pedal(Bool) }
        struct Event { let sample: Int64; let priority: Int; let instance: String; let action: Action }
        var events: [Event] = []
        for note in notes {
            events.append(Event(sample: Int64((note.start * rate).rounded()), priority: 2, instance: note.instanceID, action: .on(note.pitch, note.velocity)))
            events.append(Event(sample: Int64((note.end * rate).rounded()), priority: 1, instance: note.instanceID, action: .off(note.pitch)))
        }
        for control in plan.controls {
            // A grand-staff piano has one damper pedal. The notation's staff
            // locates the mark; independent pedals use separate logical parts.
            for (id, info) in descriptions where info.partID == control.partID {
                events.append(Event(sample: Int64((control.time * rate).rounded()), priority: 0, instance: id, action: .pedal(control.pedalDown)))
            }
        }
        let musicEnd = Int64((plan.duration * rate).rounded(.up))
        for id in samplers.keys { events.append(Event(sample: musicEnd, priority: 0, instance: id, action: .pedal(false))) }
        events = events.enumerated().sorted { a, b in
            if a.element.sample != b.element.sample { return a.element.sample < b.element.sample }
            if a.element.priority != b.element.priority { return a.element.priority < b.element.priority }
            return a.offset < b.offset
        }.map(\.element)
        let minimumEnd = musicEnd + Int64(project.settings.export.tailSeconds * rate)
        let maximumEnd = minimumEnd + Int64(10 * rate)
        var position: Int64 = 0; var eventIndex = 0; var silentFrames: Int64 = 0; var retries = 0; var globalPeak: Float = 0
        while position < maximumEnd {
            try Task.checkCancellation()
            while eventIndex < events.count, events[eventIndex].sample <= position {
                let event = events[eventIndex]
                if let sampler = samplers[event.instance] {
                    switch event.action {
                    case .on(let pitch, let velocity): sampler.startNote(UInt8(pitch), withVelocity: UInt8(velocity), onChannel: 0)
                    case .off(let pitch): sampler.stopNote(UInt8(pitch), onChannel: 0)
                    case .pedal(let down): sampler.sendController(64, withValue: down ? 127 : 0, onChannel: 0)
                    }
                }
                eventIndex += 1
            }
            let next = eventIndex < events.count ? events[eventIndex].sample : maximumEnd
            let frames = AVAudioFrameCount(min(4096, min(maximumEnd - position, max(1, next - position))))
            let status = try engine.renderOffline(frames, to: buffer)
            if status == .success {
                guard buffer.frameLength == frames else { throw ScoreError.invalid("离线合成返回了不完整音频块。") }
                let peak = try Self.validatedPeak(buffer)
                try file?.write(from: buffer)
                position += Int64(frames); retries = 0
                silentFrames = peak < 0.0001 ? silentFrames + Int64(frames) : 0
                globalPeak = max(globalPeak, peak)
                if position >= minimumEnd, eventIndex == events.count, silentFrames >= Int64(rate * 0.4) { break }
                progress(min(0.99, Double(position) / Double(max(1, minimumEnd))))
            } else {
                retries += 1
                guard status == .cannotDoInCurrentContext, retries < 100 else { throw ScoreError.invalid("离线合成无法继续：\(status.rawValue)") }
            }
        }
        file = nil // Close and finalize the CAF header before the second pass.
        let source = try AVAudioFile(forReading: rawURL)
        let destination = try AVAudioFile(forWriting: url, settings: format.settings)
        let gain: Float = normalize ? outputGain(peak: globalPeak, referencePeak: globalPeak, masterVolume: project.settings.performance.masterVolume ?? 1) : 1
        var written: Int64 = 0
        while written < position {
            try Task.checkCancellation()
            try source.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, position - written)))
            guard buffer.frameLength > 0 else { throw ScoreError.invalid("合成缓存提前结束。") }
            if let channels = buffer.floatChannelData {
                for c in 0..<2 {
                    var multiplier = gain
                    vDSP_vsmul(channels[c], 1, &multiplier, channels[c], 1, vDSP_Length(buffer.frameLength))
                    if position >= maximumEnd, written + Int64(buffer.frameLength) > position - 4800 {
                        for i in 0..<Int(buffer.frameLength) { channels[c][i] *= min(1, Float(position - written - Int64(i)) / 4800) }
                    }
                }
            }
            try destination.write(from: buffer); written += Int64(buffer.frameLength)
        }
        // Complete the final video frame with silence, using exactly the same PCM for preview and export.
        let samplesPerFrame = Int64(rate) / Int64(project.settings.export.fps.n)
        let padded = (position + samplesPerFrame - 1) / samplesPerFrame * samplesPerFrame
        while written < padded {
            buffer.frameLength = AVAudioFrameCount(min(4096, padded - written))
            if let channels = buffer.floatChannelData { for c in 0..<2 { channels[c].initialize(repeating: 0, count: Int(buffer.frameLength)) } }
            try destination.write(from: buffer); written += Int64(buffer.frameLength)
        }
        position = written
        progress(1)
        completed = true
        return RenderedAudio(url: url, frameCount: position, sampleRate: rate)
    }

    // Sum-of-squares propagates NaN/Infinity; max-magnitude alone can miss
    // NaN values and silently turn a corrupt render into an inaudible cache.
    static func validatedPeak(_ buffer: AVAudioPCMBuffer) throws -> Float {
        guard let channels = buffer.floatChannelData else { throw ScoreError.invalid("音频缓冲格式无效。") }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var energy: Float = 0
            vDSP_svesq(channels[channel], 1, &energy, vDSP_Length(buffer.frameLength))
            guard energy.isFinite else { throw ScoreError.invalid("乐器合成产生了无效采样，已停止生成音频。") }
            var value: Float = 0
            vDSP_maxmgv(channels[channel], 1, &value, vDSP_Length(buffer.frameLength))
            peak = max(peak, value)
        }
        return peak
    }

    private func outputGain(peak: Float, referencePeak: Float, masterVolume: Double) -> Float {
        let ceiling: Float = 0.89125 // -1 dBFS, leaving encoding headroom.
        let maximumBoost: Float = 15.848932 // +24 dB for very quiet instruments.
        let calibration = min(maximumBoost, ceiling / max(0.00001, referencePeak))
        return min(calibration, ceiling / max(0.00001, peak)) * Float(masterVolume)
    }
}
