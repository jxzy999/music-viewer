// Run each mode in a fresh process; this diagnostic never plays audio.
// swift script/probe_sampler_streaming.swift --mode streaming --iterations 30 --output /tmp/streaming.json
// swift script/probe_sampler_streaming.swift --mode preload --iterations 30 --output /tmp/preload.json
// Add --keep to retain every generated source sample and exclude file deletion as a cause.
import Foundation
import AVFAudio
import AudioToolbox

struct Options {
    var mode = "preload"
    var iterations = 30
    var keep = false
    var output: URL?

    init() throws {
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--mode": mode = args.next() ?? ""
            case "--iterations": iterations = Int(args.next() ?? "") ?? 0
            case "--keep": keep = true
            case "--output":
                guard let path = args.next() else { throw ProbeError.invalid("Missing --output path") }
                output = URL(fileURLWithPath: path)
            default: throw ProbeError.invalid("Unknown option: \(arg)")
            }
        }
        guard ["streaming", "preload"].contains(mode), (1...1000).contains(iterations) else {
            throw ProbeError.invalid("Use --mode streaming|preload and --iterations 1...1000")
        }
        if let output, FileManager.default.fileExists(atPath: output.path) {
            throw ProbeError.invalid("Report already exists: \(output.path)")
        }
    }
}

enum ProbeError: Error { case invalid(String) }
let rate = 48_000.0
let blockFrames: AVAudioFrameCount = 4096
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw ProbeError.invalid("\(operation) failed: \(status)") }
}

func property(_ sampler: AVAudioUnitSampler, _ id: AudioUnitPropertyID) throws -> UInt32 {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try check(AudioUnitGetProperty(sampler.audioUnit, id, kAudioUnitScope_Global, 0, &value, &size), "Read property \(id)")
    guard size == MemoryLayout<UInt32>.size else { throw ProbeError.invalid("Unexpected property size") }
    return value
}

func makeSample(seconds: Double, at url: URL) throws {
    let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let count = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: count)!
    buffer.frameLength = count
    for i in 0..<Int(count) {
        buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 261.625565 / rate) * 0.25)
    }
    let file = try AVAudioFile(forWriting: url, settings: mono.settings)
    try file.write(from: buffer)
}

func render(_ source: URL, voices: Int, piano: Bool, mode: String) throws -> [String: Any] {
    let engine = AVAudioEngine()
    let bus = AVAudioMixerNode()
    let room = AVAudioUnitReverb()
    room.auAudioUnit.isRenderingOffline = true
    room.loadFactoryPreset(.mediumRoom)
    engine.attach(bus)
    engine.attach(room)
    engine.connect(bus, to: room, format: format)
    engine.connect(room, to: engine.mainMixerNode, format: format)
    var samplers: [AVAudioUnitSampler] = []
    var states: [[String: Any]] = []
    let expectedStreaming: UInt32 = mode == "preload" ? 0 : 1
    defer { engine.stop() }
    for _ in 0..<voices {
        let sampler = AVAudioUnitSampler()
        sampler.auAudioUnit.isRenderingOffline = true
        let initialStreaming = try property(sampler, kMusicDeviceProperty_StreamFromDisk)
        if mode == "preload" {
            var disabled: UInt32 = 0
            try check(AudioUnitSetProperty(sampler.audioUnit, kMusicDeviceProperty_StreamFromDisk, kAudioUnitScope_Global, 0, &disabled, UInt32(MemoryLayout<UInt32>.size)), "Disable sample streaming")
        }
        if piano {
            try sampler.loadSoundBankInstrument(at: source, program: 0, bankMSB: 121, bankLSB: 0)
        } else {
            try sampler.loadAudioFiles(at: [source])
        }
        let afterLoad = try property(sampler, kMusicDeviceProperty_StreamFromDisk)
        guard afterLoad == expectedStreaming else { throw ProbeError.invalid("Unexpected streaming state after instrument load: \(afterLoad)") }
        states.append(["initialStreamFromDisk": initialStreaming, "afterLoad": afterLoad])
        engine.attach(sampler)
        engine.connect(sampler, to: bus, format: format)
        samplers.append(sampler)
    }
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: blockFrames)
    try engine.start()
    room.auAudioUnit.reset()
    room.wetDryMix = 0
    for (index, sampler) in samplers.enumerated() {
        let afterStart = try property(sampler, kMusicDeviceProperty_StreamFromDisk)
        sampler.auAudioUnit.reset()
        let afterReset = try property(sampler, kMusicDeviceProperty_StreamFromDisk)
        let offline = try property(sampler, kAudioUnitProperty_OfflineRender)
        guard afterStart == expectedStreaming, afterReset == expectedStreaming, offline == 1 else {
            throw ProbeError.invalid("Sampler lost its requested render mode")
        }
        states[index]["afterStart"] = afterStart
        states[index]["afterReset"] = afterReset
        states[index]["offlineRender"] = offline
        sampler.overallGain = -6
        sampler.stereoPan = 0
        sampler.startNote(piano ? 76 : 60, withVelocity: piano ? 33 : 27, onChannel: 0)
    }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames)!
    var position = 0
    var firstInvalid: Int?
    var invalidSamples = 0
    var peak: Float = 0
    let windows = [0.2, 0.6, 1.5]
    var sums = windows.map { _ in 0.0 }
    var counts = windows.map { _ in 0 }
    var invalidWindows = windows.map { _ in 0 }
    while position < 192_000 {
        let count = AVAudioFrameCount(min(Int(blockFrames), 192_000 - position))
        let status = try engine.renderOffline(count, to: buffer)
        guard status == .success, buffer.frameLength == count else {
            throw ProbeError.invalid("Incomplete render at \(position): \(status.rawValue)")
        }
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for index in 0..<Int(count) {
                let frame = position + index
                let value = samples[index]
                if value.isFinite { peak = max(peak, abs(value)) }
                else {
                    invalidSamples += 1
                    if firstInvalid == nil { firstInvalid = frame }
                }
                for (window, time) in windows.enumerated() where frame >= Int(time * rate) && frame < Int((time + 0.1) * rate) {
                    if value.isFinite { sums[window] += Double(value) * Double(value); counts[window] += 1 }
                    else { invalidWindows[window] += 1 }
                }
            }
        }
        position += Int(count)
    }
    let levels = windows.enumerated().map { index, time -> [String: Any] in
        // Invalid windows are explicit; JSON never contains NaN or Infinity.
        let rms: Any = invalidWindows[index] == 0 && counts[index] > 0 ? sqrt(sums[index] / Double(counts[index])) as Any : NSNull()
        return ["startSeconds": time, "durationSeconds": 0.1, "rms": rms, "invalidSamples": invalidWindows[index]]
    }
    return ["frames": position, "invalidSamples": invalidSamples,
            "firstInvalidFrame": firstInvalid as Any? ?? NSNull(), "maxFiniteMagnitude": Double(peak),
            "windowLevels": levels, "samplerStates": states]
}

do {
    let options = try Options()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MusicViewer-SamplerProbe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { if !options.keep { try? FileManager.default.removeItem(at: root) } }
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let bank = repo.appendingPathComponent("Sources/ScoreMedia/Resources/GeneralUser-GS.sf2")
    var rounds: [[String: Any]] = []
    var failedRenders = 0
    for iteration in 0..<options.iterations {
        var result: [String: Any] = ["iteration": iteration]
        for (name, seconds, voices) in [("short", 0.05, 9), ("long", 2.0, 2)] {
            let folder = root.appendingPathComponent("\(iteration)-\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("C4.wav")
            try makeSample(seconds: seconds, at: source)
            let report = try autoreleasepool { try render(source, voices: voices, piano: false, mode: options.mode) }
            result[name] = report
            if report["invalidSamples"] as? Int != 0 { failedRenders += 1 }
            if !options.keep { try FileManager.default.removeItem(at: folder) }
        }
        let piano = try autoreleasepool { try render(bank, voices: 1, piano: true, mode: options.mode) }
        result["piano"] = piano
        if piano["invalidSamples"] as? Int != 0 { failedRenders += 1 }
        rounds.append(result)
        print("\(options.mode) \(iteration + 1)/\(options.iterations): cumulative invalid renders \(failedRenders)")
    }
    let report: [String: Any] = ["mode": options.mode, "iterations": options.iterations,
                               "renderCount": options.iterations * 3, "failedRenders": failedRenders,
                               "sampleRate": rate, "blockFrames": blockFrames,
                               "keptSources": options.keep, "temporaryDirectory": root.path,
                               "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                               "rounds": rounds]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    if let output = options.output {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .withoutOverwriting)
        print("Report: \(output.path)")
    }
    if options.keep { print("Retained sources: \(root.path)") }
    exit(failedRenders == 0 ? 0 : 1)
} catch {
    fputs("Sampler probe failed: \(error)\n", stderr)
    exit(2)
}
