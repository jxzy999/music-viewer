import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFAudio
import ScoreCore
import ScoreMedia

/// Developer acceptance fixtures use the production parser, scheduler, sampler,
/// PCM cache, Metal renderer and MP4 exporter, with a controlled pulse sample.
@MainActor
enum MediaDiagnostics {
    static func run(to folder: URL, fps: Int = 60, progress: @escaping @Sendable (Double) -> Void) async throws {
        #if DEBUG
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var xml = "<score-partwise version='4.0'><work><work-title>ScoreFilm pulse synchronization fixture</work-title></work><part-list><score-part id='P1'><part-name>Pulse</part-name><score-instrument id='I1'><instrument-name>Piano</instrument-name></score-instrument><midi-instrument id='I1'><midi-program>1</midi-program></midi-instrument></score-part></part-list><part id='P1'>"
        for bar in 0..<140 {
            xml += "<measure id='m\(bar)' number='\(bar+1)'>"
            if bar == 0 {
                xml += "<attributes><divisions>2</divisions><time><beats>7</beats><beat-type>8</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes><direction><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>96</per-minute></metronome></direction-type><sound tempo='96'/></direction>"
            }
            xml += "<note id='pulse\(bar)'><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>eighth</type></note><note id='rest\(bar)'><rest/><duration>6</duration><voice>1</voice><type>half</type><dot/></note></measure>"
        }
        xml += "</part></score-partwise>"
        let sourceURL = folder.appendingPathComponent("pulse.musicxml")
        try Data(xml.utf8).write(to: sourceURL)
        var project = try ProjectFile.load(sourceURL)
        project.settings.export.fps.n = fps
        project.settings.visual.preset = "clear-score"; project.settings.camera.preset = "locked"
        project.settings.performance.defaultTempoQPM = 96
        project.settings.performance.reverbWetDryMix = 0
        let performance = try PerformanceCompiler.compile(project)
        let png = try fixturePage()
        let anchors = Dictionary(uniqueKeysWithValues: project.score.notes.filter { !$0.isRest }.map { ($0.id, LayoutAnchor(sourceID: $0.id, page: 0, x: 500, y: 300, radius: 5, system: "fixture-system")) })
        let layout = LayoutSnapshot(pages: [LayoutPage(index: 0, width: 1000, height: 600, png: png)], anchors: anchors, missingNoteIDs: [])
        let scene = ScenePlan(layout: layout, performance: performance, settings: project.settings)
        let pulseURL = folder.appendingPathComponent("C4.wav")
        try makePulse(to: pulseURL)
        let renderer = OfflineAudioRenderer(validationInstrument: pulseURL)
        let audio = try await renderer.render(plan: performance, project: project, to: folder.appendingPathComponent("pulse.caf"), progress: { progress($0 * 0.12) })
        let frames = try MetalSceneRenderer(scene: scene)
        let sampleTime = 131.25
        let direct = try frames.capture(time: sampleTime, width: 1920, height: 1080)
        for t in [0.0, 40, 300, 1, 200, 90] { _ = try frames.capture(time: t, width: 1920, height: 1080) }
        let afterSeeking = try frames.capture(time: sampleTime, width: 1920, height: 1080)
        let fresh = try MetalSceneRenderer(scene: scene).capture(time: sampleTime, width: 1920, height: 1080)
        guard direct.bgra == afterSeeking.bgra, direct.bgra == fresh.bgra else { throw ScoreError.invalid("定位和直接取帧的几何结果不一致。") }
        try direct.png().write(to: folder.appendingPathComponent("pulse-frame.png"))
        let expected: [[String: Any]] = performance.notes.map { ["id": $0.id, "start": $0.start, "end": $0.end, "sample": Int64(($0.start * audio.sampleRate).rounded())] }
        let report: [String: Any] = ["duration": performance.duration, "sampleRate": audio.sampleRate, "events": expected, "frameHash": ProjectFile.digest(direct.bgra), "deterministicAfterSeeking": true, "deterministicAcrossRenderers": true, "pixelCenterX": 960, "pixelCenterY": 540, "geometryScope": "Controlled single-page anchor fixture; real MusicXML engraving mapping is tested separately"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("expected.json"))
        _ = try await VideoExporter().export(scene: scene, audio: audio, to: folder.appendingPathComponent("pulse.mp4"), progress: { progress(0.12 + $0 * 0.88) })
        #else
        throw ScoreError.unsupported("媒体诊断需要开发构建。")
        #endif
    }

    private static func makePulse(to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400), let channels = buffer.floatChannelData else { throw ScoreError.invalid("无法创建测试脉冲。") }
        buffer.frameLength = 2400
        for i in 0..<2400 {
            let value = Float(exp(-Double(i) / 90) * cos(Double(i) * 0.65) * 0.8)
            channels[0][i] = value; channels[1][i] = value
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func fixturePage() throws -> Data {
        guard let context = CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScoreError.invalid("无法创建验证页面。") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fillEllipse(in: CGRect(x: 495, y: 295, width: 10, height: 10))
        guard let image = context.makeImage() else { throw ScoreError.invalid("验证页面不完整。") }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ScoreError.invalid("无法生成验证页面。") }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw ScoreError.invalid("无法写入验证页面。") }
        return data as Data
    }
}
