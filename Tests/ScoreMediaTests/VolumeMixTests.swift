import XCTest
import AVFAudio
import ScoreCore
@testable import ScoreMedia

final class VolumeMixTests: XCTestCase {
    private func rms(_ audio: RenderedAudio, at time: Double) throws -> Double {
        let file = try AVAudioFile(forReading: audio.url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 9600))
        file.framePosition = Int64(time * audio.sampleRate)
        try file.read(into: buffer, frameCount: 9600)
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        return sqrt((0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(data[$1]) * Double(data[$1]) } / Double(buffer.frameLength))
    }

    func testMasterAndVoiceFadersAreNotUndoneByOutputCalibration() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VolumeMix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let sample = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)); sample.frameLength = 96000
        let samples = try XCTUnwrap(sample.floatChannelData?[0])
        for i in 0..<96000 { samples[i] = Float(sin(Double(i) * 2 * .pi * 261.625565 / 48000) * 0.25) }
        let sampleURL = folder.appendingPathComponent("C4.wav")
        do { let file = try AVAudioFile(forWriting: sampleURL, settings: format.settings); try file.write(from: sample) }
        let pitch = "<pitch><step>C</step><octave>4</octave></pitch>"
        let xml = "<score-partwise version='4.0'><part-list><score-part id='P1'><part-name>Test</part-name></score-part></part-list><part id='P1'><measure number='1'><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes><note dynamics='30'>\(pitch)<duration>1</duration><voice>1</voice><type>quarter</type></note><note><rest/><duration>3</duration><voice>1</voice></note><backup><duration>4</duration></backup><note><rest/><duration>2</duration><voice>2</voice></note><note dynamics='100'>\(pitch)<duration>1</duration><voice>2</voice><type>quarter</type></note><note><rest/><duration>1</duration><voice>2</voice></note></measure></part></score-partwise>"
        let source = folder.appendingPathComponent("voices.musicxml")
        try Data(xml.utf8).write(to: source)
        var project = try ProjectFile.load(source)
        project.settings.partInstruments["P1"] = "piano"
        project.settings.performance.defaultTempoQPM = 60
        project.settings.performance.reverbWetDryMix = 0
        let renderer = OfflineAudioRenderer(validationInstrument: sampleURL)
        func render(_ project: ProjectFile, _ name: String) async throws -> RenderedAudio {
            try await renderer.render(plan: PerformanceCompiler.compile(project), project: project, to: folder.appendingPathComponent(name + ".caf"), progress: { _ in })
        }
        let baseline = try await render(project, "baseline")
        let melody = try rms(baseline, at: 0.2); let bass = try rms(baseline, at: 2.2)
        XCTAssertGreaterThan(melody, 0.001); XCTAssertGreaterThan(bass, melody * 2)

        project.settings.performance.masterVolume = 0.25
        let quietMaster = try await render(project, "master-quarter")
        XCTAssertEqual(try rms(quietMaster, at: 0.2) / melody, 0.25, accuracy: 0.01)
        XCTAssertEqual(try rms(quietMaster, at: 2.2) / bass, 0.25, accuracy: 0.01)
        XCTAssertEqual(quietMaster.frameCount, baseline.frameCount)

        project.settings.performance.masterVolume = nil
        project.settings.performance.voiceVolumes = [VoiceVolume(partId: "P1", voiceId: "1", volume: 2)]
        let louderMelody = try await render(project, "melody-double")
        XCTAssertEqual(try rms(louderMelody, at: 0.2) / melody, 2, accuracy: 0.04)
        XCTAssertEqual(try rms(louderMelody, at: 2.2) / bass, 1, accuracy: 0.02)

        project.settings.performance.voiceVolumes = [VoiceVolume(partId: "P1", voiceId: "1", volume: 0.25), VoiceVolume(partId: "P1", voiceId: "2", volume: 0.25)]
        let quietVoices = try await render(project, "voices-quarter")
        XCTAssertEqual(try rms(quietVoices, at: 0.2) / melody, 0.25, accuracy: 0.01)
        XCTAssertEqual(try rms(quietVoices, at: 2.2) / bass, 0.25, accuracy: 0.01)

        project.settings.performance.voiceVolumes = [VoiceVolume(partId: "P1", voiceId: "1", volume: 0)]
        let mutedVoice = try await render(project, "melody-muted")
        XCTAssertEqual(try rms(mutedVoice, at: 0.2), 0)
        XCTAssertEqual(try rms(mutedVoice, at: 2.2) / bass, 1, accuracy: 0.02)
        project.settings.performance.masterVolume = 0
        let mutedMaster = try await render(project, "master-muted")
        XCTAssertEqual(try rms(mutedMaster, at: 2.2), 0)
    }

    func testQuietPianoGetsAnAudibleDefaultWithoutClipping() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try ProjectFile.load(root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples/FurElise.scorefilm"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PianoLevel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try await OfflineAudioRenderer().render(plan: PerformanceCompiler.compile(project), project: project, to: folder.appendingPathComponent("piano.caf"), progress: { _ in })
        let file = try AVAudioFile(forReading: audio.url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        var peak: Float = 0
        for c in 0..<2 { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[c][i])) } }
        XCTAssertEqual(peak, 0.89125, accuracy: 0.00002)
        XCTAssertGreaterThan(try rms(audio, at: 7.95), 0.01)
        XCTAssertGreaterThan(try rms(audio, at: 16.1), 0.01)
    }
}
