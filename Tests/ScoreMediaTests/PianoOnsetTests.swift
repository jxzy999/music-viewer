import XCTest
import AVFAudio
import ScoreCore
@testable import ScoreMedia

final class PianoOnsetTests: XCTestCase {
    func testNativePianoImportKeepsTheSoundFontSampleRanges() throws {
        let sampler = AVAudioUnitSampler()
        try sampler.loadSoundBankInstrument(at: MediaResources.soundBank, program: 0, bankMSB: 121, bankLSB: 0)
        let instrument = try XCTUnwrap(sampler.auAudioUnit.fullState?["Instrument"] as? [String: Any])
        let layers = try XCTUnwrap(instrument["Layers"] as? [[String: Any]])
        // AUSampler can merge equivalent layers. Compare effective sample zones,
        // not its layer count: the unnormalized font activated up to 35 samples
        // per key/velocity pair instead of the intended one or two.
        let bounds = try layers.flatMap { layer in
            let zones = try XCTUnwrap(layer["Zones"] as? [[String: Any]])
            return zones.map { zone in
                (max(layer["min key"] as? Int ?? 0, zone["min key"] as? Int ?? 0),
                 min(layer["max key"] as? Int ?? 127, zone["max key"] as? Int ?? 127),
                 max(layer["min vel"] as? Int ?? 0, zone["min vel"] as? Int ?? 0),
                 min(layer["max vel"] as? Int ?? 127, zone["max vel"] as? Int ?? 127))
            }
        }
        XCTAssertEqual(bounds.count, 200)
        var histogram: [Int: Int] = [:]
        for pitch in 0...127 {
            for velocity in 1...127 {
                let count = bounds.filter { $0.0 <= pitch && pitch <= $0.1 && $0.2 <= velocity && velocity <= $0.3 }.count
                histogram[count, default: 0] += 1
            }
        }
        XCTAssertEqual(histogram, [1: 15_748, 2: 508])
        for (pitch, velocity) in [(76, 33), (60, 33), (45, 76)] {
            XCTAssertEqual(bounds.filter { $0.0 <= pitch && pitch <= $0.1 && $0.2 <= velocity && velocity <= $0.3 }.count, 1)
        }
    }

    func testPianoThemeKeepsWrittenNotesAudibleInBothPasses() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let template = root.appendingPathComponent("Tests/Fixtures/FurEliseTheme.scorefilm")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PianoOnset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = try ProjectFile.load(template)
        let plan = try PerformanceCompiler.compile(project)
        XCTAssertEqual(plan.notes.count, 106)
        var reports: [[String: Any]] = []
        for wet in [0.0, 12.0] {
            project.settings.performance.reverbWetDryMix = wet
            let rendered = try await OfflineAudioRenderer().render(plan: plan, project: project, to: folder.appendingPathComponent("piano-\(Int(wet)).caf"), progress: { _ in })
            let file = try AVAudioFile(forReading: rendered.url)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            var events: [[String: Any]] = []
            var weak: [String] = []
            for note in plan.notes {
                let begin = Int((note.start + 0.025) * rendered.sampleRate)
                let end = min(Int((note.start + 0.105) * rendered.sampleRate), Int(buffer.frameLength))
                let sum = (begin..<end).reduce(0.0) { $0 + Double(channel[$1]) * Double(channel[$1]) }
                let rms = sqrt(sum / Double(end - begin))
                events.append(["id": note.id, "pitch": note.pitch, "voice": note.voice, "start": note.start, "end": note.end, "velocity": note.velocity, "rms": rms])
                // pp is deliberately quiet; -66 dBFS leaves ample headroom for
                // dynamics, but catches the near-silent missing-onset intervals.
                if rms < 0.0005 { weak.append("\(note.id) pitch=\(note.pitch) at=\(String(format: "%.3f", note.start)) rms=\(rms)") }
            }
            reports.append(["reverbPercent": wet, "events": events, "weakEvents": weak])
            XCTAssertTrue(weak.isEmpty, "\(Int(wet))% reverb: \(weak.joined(separator: "; "))")
        }
        if let path = ProcessInfo.processInfo.environment["SCOREFILM_ONSET_REPORT"] {
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}
