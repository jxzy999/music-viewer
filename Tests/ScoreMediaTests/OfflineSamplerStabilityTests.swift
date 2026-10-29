import XCTest
import AVFAudio
import ScoreCore
@testable import ScoreMedia

final class OfflineSamplerStabilityTests: XCTestCase {
    func testInvalidSamplesAreRejectedBeforePeakCalibration() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        buffer.frameLength = 4096
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for c in 0..<2 { channels[c].initialize(repeating: 0.25, count: 4096) }
        XCTAssertEqual(try OfflineAudioRenderer.validatedPeak(buffer), 0.25)
        for channel in 0..<2 {
            for index in [0, 2048, 4095] {
                for invalid in [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
                    channels[channel][index] = invalid
                    XCTAssertThrowsError(try OfflineAudioRenderer.validatedPeak(buffer))
                    channels[channel][index] = 0.25
                }
            }
        }
        for c in 0..<2 { channels[c].initialize(repeating: 0, count: 4096) }
        XCTAssertEqual(try OfflineAudioRenderer.validatedPeak(buffer), 0)
    }

    func testAlternatingShortAndLongSamplesStayAudibleAcrossFreshSamplers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SamplerStability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let xml = "<score-partwise version='4.0'><part-list><score-part id='P1'><part-name>Test</part-name></score-part></part-list><part id='P1'><measure number='1'><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes><note dynamics='30'><pitch><step>C</step><octave>4</octave></pitch><duration>3</duration><voice>1</voice><type>half</type><dot/></note><note><rest/><duration>1</duration><voice>1</voice></note></measure></part></score-partwise>"
        let source = folder.appendingPathComponent("note.musicxml")
        try Data(xml.utf8).write(to: source)
        var project = try ProjectFile.load(source)
        project.settings.partInstruments["P1"] = "piano"
        project.settings.performance.defaultTempoQPM = 60
        project.settings.performance.reverbWetDryMix = 0
        let plan = try PerformanceCompiler.compile(project)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        var referenceRMS: Double?
        // A single render often passes with native disk streaming enabled.
        // Alternating sample lengths repeatedly crosses its initial preload
        // boundary and reproduced the original failure without any file reader.
        for iteration in 0..<20 {
            for (name, frames) in [("short", 2400), ("long", 96000)] {
                let sampleFolder = folder.appendingPathComponent("\(iteration)-\(name)", isDirectory: true)
                try FileManager.default.createDirectory(at: sampleFolder, withIntermediateDirectories: true)
                let sampleURL = sampleFolder.appendingPathComponent("C4.wav")
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
                buffer.frameLength = AVAudioFrameCount(frames)
                let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                for i in 0..<frames { samples[i] = Float(sin(Double(i) * 2 * .pi * 261.625565 / 48000) * 0.25) }
                do {
                    let file = try AVAudioFile(forWriting: sampleURL, settings: format.settings)
                    try file.write(from: buffer)
                }
                let audio = try await OfflineAudioRenderer(validationInstrument: sampleURL).render(plan: plan, project: project, to: sampleFolder.appendingPathComponent("result.caf"), progress: { _ in })
                let file = try AVAudioFile(forReading: audio.url)
                let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                try file.read(into: pcm)
                let peak = try OfflineAudioRenderer.validatedPeak(pcm)
                XCTAssertGreaterThan(peak, 0.001)
                XCTAssertLessThanOrEqual(peak, 0.89126)
                if name == "long" {
                    let data = try XCTUnwrap(pcm.floatChannelData?[0])
                    func rms(_ start: Int) -> Double {
                        sqrt((start..<(start + 4800)).reduce(0.0) { $0 + Double(data[$1]) * Double(data[$1]) } / 4800)
                    }
                    let value = rms(48000) // Beyond the failing ~0.408 second boundary.
                    XCTAssertTrue(value.isFinite)
                    XCTAssertGreaterThan(value, 0.001)
                    XCTAssertEqual(rms(76800) / value, 1, accuracy: 0.03)
                    if let referenceRMS { XCTAssertEqual(value, referenceRMS, accuracy: referenceRMS * 0.001) }
                    else { referenceRMS = value }
                }
                try FileManager.default.removeItem(at: sampleFolder)
            }
        }
    }

    func testAllBuiltInScoresHaveFiniteAudibleOutputWithDryAndWetMixes() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BuiltinAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["FurElise", "BachGavotte", "OdeToJoy", "Greensleeves", "AmazingGrace"] {
            var project = try ProjectFile.load(root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples/\(name).scorefilm"))
            let plan = try PerformanceCompiler.compile(project)
            for wet in [0.0, 12.0] {
                project.settings.performance.reverbWetDryMix = wet
                let audio = try await OfflineAudioRenderer().render(plan: plan, project: project, to: folder.appendingPathComponent("\(name)-\(Int(wet)).caf"), progress: { _ in })
                let file = try AVAudioFile(forReading: audio.url)
                let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                try file.read(into: pcm)
                XCTAssertEqual(try OfflineAudioRenderer.validatedPeak(pcm), 0.89125, accuracy: 0.00002)
                let data = try XCTUnwrap(pcm.floatChannelData?[0])
                for note in plan.notes {
                    let start = Int((note.start + 0.025) * 48000)
                    let end = min(Int((note.start + 0.105) * 48000), Int(pcm.frameLength))
                    let energy = (start..<end).reduce(0.0) { $0 + Double(data[$1]) * Double(data[$1]) }
                    XCTAssertGreaterThan(sqrt(energy / Double(end - start)), 0.0005, "\(name) wet=\(wet), \(note.id) at \(note.start)")
                }
            }
        }
    }
}
