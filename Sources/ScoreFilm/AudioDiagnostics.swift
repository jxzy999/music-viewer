import Foundation
import AVFAudio
import ScoreCore
import ScoreMedia

@MainActor
enum AudioDiagnostics {
    static func run(to folder: URL) async throws {
        #if DEBUG
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tone = folder.appendingPathComponent("C4-tone.wav")
        let pulse = folder.appendingPathComponent("C4-pulse.wav")
        try sample(to: tone, pulse: false); try sample(to: pulse, pulse: true)
        let sustained = OfflineAudioRenderer(validationInstrument: tone)
        let transient = OfflineAudioRenderer(validationInstrument: pulse)
        let c = "<pitch><step>C</step><octave>4</octave></pitch>"
        let first = "<note id='one'>\(c)<duration>2</duration><voice>1</voice><type>half</type></note>"
        let second = "<note id='two'>\(c)<duration>1</duration><voice>2</voice><type>quarter</type></note>"
        let baseline = try project(first, label: "single-voice-baseline", folder: folder)
        let baselineAudio = try await sustained.render(plan: PerformanceCompiler.compile(baseline), project: baseline, to: folder.appendingPathComponent("single-voice.caf"), progress: { _ in })
        let baselineEarly = try rms(baselineAudio, at: 0.1)
        let baselineLate = try rms(baselineAudio, at: 1.8, duration: 0.15)
        let overlap = try project(first + "<backup><duration>2</duration></backup>" + second, label: "voice-ownership", folder: folder)
        let overlapAudio = try await sustained.render(plan: PerformanceCompiler.compile(overlap), project: overlap, to: folder.appendingPathComponent("voices.caf"), progress: { _ in })
        let both = try rms(overlapAudio, at: 0.1)
        let remaining = try rms(overlapAudio, at: 1.8, duration: 0.15)
        let stopped = try rms(overlapAudio, at: 2.7)
        // A sampler's phase/envelope may vary across instances. The ownership
        // invariant is retained signal after the short note's release, followed
        // by silence after the long note, rather than a fixed amplitude ratio.
        guard baselineEarly > 0.001, baselineLate > 0.0001, both > 0.001, remaining > 0.0001, stopped < remaining * 0.02 else { throw ScoreError.invalid("同音声部释放的实际波形未通过：\(both)、\(remaining)、\(stopped)") }

        let note = "<note id='pedal-note'>\(c)<duration>1</duration><voice>1</voice><type>quarter</type></note>"
        let pedal = try project("<sound damper-pedal='yes'/>" + note + "<sound damper-pedal='no'><offset>1</offset></sound><note><rest/><duration>3</duration><voice>1</voice><type>half</type><dot/></note>", label: "pedal", folder: folder)
        let pedalAudio = try await sustained.render(plan: PerformanceCompiler.compile(pedal), project: pedal, to: folder.appendingPathComponent("pedal.caf"), progress: { _ in })
        let held = try rms(pedalAudio, at: 1.8, duration: 0.15); let released = try rms(pedalAudio, at: 2.7)
        guard held > 0.0001, released < held * 0.02 else { throw ScoreError.invalid("踏板释放的实际波形未通过：\(held)、\(released)") }

        let grandStaff = try project("<attributes><staves>2</staves></attributes><direction><direction-type><pedal type='start'/></direction-type><staff>2</staff></direction>" + note + "<direction><direction-type><pedal type='stop'/></direction-type><offset>1</offset><staff>2</staff></direction><note><rest/><duration>3</duration><voice>1</voice><type>half</type><dot/></note><backup><duration>4</duration></backup><note><rest/><duration>4</duration><voice>2</voice><type>whole</type><staff>2</staff></note>", label: "grand-staff-pedal", folder: folder)
        let grandAudio = try await sustained.render(plan: PerformanceCompiler.compile(grandStaff), project: grandStaff, to: folder.appendingPathComponent("grand-staff-pedal.caf"), progress: { _ in })
        let upperHeld = try rms(grandAudio, at: 1.8, duration: 0.15); let upperReleased = try rms(grandAudio, at: 2.7)
        guard upperHeld > 0.0001, upperReleased < upperHeld * 0.02 else { throw ScoreError.invalid("低音谱表上的踏板没有正确作用于同一钢琴的高音谱表。") }

        let tied = try project("<note id='tie-a'>\(c)<duration>1</duration><tie type='start'/><voice>1</voice><type>quarter</type><notations><tied type='start'/></notations></note><note id='tie-b'>\(c)<duration>1</duration><tie type='stop'/><voice>1</voice><type>quarter</type><notations><tied type='stop'/></notations></note>", label: "tie", folder: folder)
        let tiedAudio = try await transient.render(plan: PerformanceCompiler.compile(tied), project: tied, to: folder.appendingPathComponent("tie.caf"), progress: { _ in })
        let onset = try rms(tiedAudio, at: 0, duration: 0.03)
        let continuation = try rms(tiedAudio, at: 0.98, duration: 0.06)
        guard onset > 0.002, continuation < onset * 0.01 else { throw ScoreError.invalid("延音链出现了第二次起音。") }

        var routed = try project(first + first.replacingOccurrences(of: "id='one'", with: "id='after-boundary'"), label: "route-boundary", folder: folder)
        routed.settings.routes = [InstrumentRoute(selector: NoteSelector(partId: "P1"), range: ScoreRange(from: ScorePosition(measureId: "m1", beat: try Beat(1)), to: ScorePosition(measureId: "m1", beat: try Beat(4))), instrumentId: "violin")]
        let routedPlan = try PerformanceCompiler.compile(routed)
        let routedAudio = try await sustained.render(plan: routedPlan, project: routed, to: folder.appendingPathComponent("routing.caf"), progress: { _ in })
        let before = try rms(routedAudio, at: 0.5); let after = try rms(routedAudio, at: 1.8, duration: 0.15)
        guard before > 0.0001, after > 0.0001, routedPlan.notes.map(\.instrument.id) == ["piano","violin"] else { throw ScoreError.invalid("配器边界截断了原乐器长音。") }
        let report: [String: Any] = ["singleVoiceBaseline": ["earlyRMS":baselineEarly,"lateRMS":baselineLate],"samePitchVoices": ["bothRMS": both,"remainingRMS":remaining,"stoppedRMS":stopped,"passed":true],"pedal": ["heldRMS":held,"releasedRMS":released,"passed":true],"grandStaffPedal": ["upperHeldRMS":upperHeld,"releasedRMS":upperReleased,"passed":true],"tie": ["onsetRMS":onset,"continuationRMS":continuation,"passed":true],"routingBoundary": ["beforeRMS":before,"afterRMS":after,"instruments":routedPlan.notes.map(\.instrument.id),"passed":true],"scope":"Actual AVAudioUnitSampler offline PCM, using controlled long-tone and transient samples and an independent same-time single-voice baseline"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("audio-ownership.json"))
        #else
        throw ScoreError.unsupported("音频诊断需要开发构建。")
        #endif
    }

    private static func project(_ content: String, label: String, folder: URL) throws -> ProjectFile {
        let xml = "<score-partwise version='4.0'><part-list><score-part id='P1'><part-name>Piano</part-name><score-instrument id='I1'><instrument-name>Piano</instrument-name></score-instrument><midi-instrument id='I1'><midi-program>1</midi-program></midi-instrument></score-part></part-list><part id='P1'><measure id='m1' number='1'><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes><sound tempo='60'/>\(content)</measure></part></score-partwise>"
        let url = folder.appendingPathComponent(label + ".musicxml")
        try Data(xml.utf8).write(to: url)
        var project = try ProjectFile.load(url)
        project.settings.performance.reverbWetDryMix = 0
        return project
    }
    private static func sample(to url: URL, pulse: Bool) throws {
        let count = pulse ? 2400 : 192000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let channels = buffer.floatChannelData else { throw ScoreError.invalid("无法创建波形语料。") }
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count {
            let value = Float(pulse ? exp(-Double(i) / 90) * cos(Double(i) * 0.65) * 0.8 : sin(Double(i) * 2 * .pi * 261.625565 / 48000) * 0.2)
            channels[0][i] = value; channels[1][i] = value
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    private static func rms(_ audio: RenderedAudio, at time: Double, duration: Double = 0.1) throws -> Double {
        let file = try AVAudioFile(forReading: audio.url)
        let count = AVAudioFrameCount(duration * audio.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw ScoreError.invalid("无法读取验证波形。") }
        file.framePosition = Int64(time * audio.sampleRate)
        try file.read(into: buffer, frameCount: count)
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { throw ScoreError.invalid("验证波形为空。") }
        var sum = 0.0
        for i in 0..<Int(buffer.frameLength) { sum += Double(channel[i]) * Double(channel[i]) }
        return sqrt(sum / Double(buffer.frameLength))
    }
}
