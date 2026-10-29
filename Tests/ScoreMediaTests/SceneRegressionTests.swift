import XCTest
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import simd
import ScoreCore
@testable import ScoreMedia

final class SceneRegressionTests: XCTestCase {
    private func project(relation: String) throws -> ProjectFile {
        var notes = ""
        for (i, id) in ["a","b","c"].enumerated() {
            let tie = relation == "tie" ? (i == 0 ? "<tie type='start'/>" : i == 2 ? "<tie type='stop'/>" : "<tie type='stop'/><tie type='start'/>") : ""
            let slur = relation == "slur" ? (i == 0 ? "<notations><slur type='start'/></notations>" : i == 2 ? "<notations><slur type='stop'/></notations>" : "") : ""
            notes += "<note id='\(id)'><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration>\(tie)<voice>1</voice><type>quarter</type>\(slur)</note>"
        }
        let xml = "<score-partwise version='4.0'><part-list><score-part id='P1'><part-name>Test</part-name><score-instrument id='I1'><instrument-name>Piano</instrument-name></score-instrument><midi-instrument id='I1'><midi-program>1</midi-program></midi-instrument></score-part></part-list><part id='P1'><measure id='m1' number='1'><attributes><divisions>1</divisions><time><beats>3</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>\(notes)</measure></part></score-partwise>"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".musicxml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(xml.utf8).write(to: url)
        var result = try ProjectFile.load(url)
        result.settings.performance.defaultTempoQPM = 60
        result.settings.visual.preset = "clear-score"
        result.settings.camera.preset = "locked"
        return result
    }

    private func page() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        let data = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return data as Data
    }

    private func scene(_ project: ProjectFile, coincident: Bool = false, crossSystem: Bool = false) throws -> ScenePlan {
        let anchors = Dictionary(uniqueKeysWithValues: ["a","b","c"].enumerated().map { i, id in
            (id, LayoutAnchor(sourceID: id, page: 0, x: coincident ? 500 : 380 + Double(i) * 120, y: 300, radius: 5, system: crossSystem && i > 0 ? "second" : "first"))
        })
        let layout = LayoutSnapshot(pages: [LayoutPage(index: 0, width: 1000, height: 600, png: try page())], anchors: anchors, missingNoteIDs: [])
        return ScenePlan(layout: layout, performance: try PerformanceCompiler.compile(project), settings: project.settings)
    }

    private func frame(_ project: ProjectFile, time: Double, coincident: Bool = false, crossSystem: Bool = false) throws -> Data {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        return try MetalSceneRenderer(scene: scene(project, coincident: coincident, crossSystem: crossSystem)).capture(time: time, width: 960, height: 540).bgra
    }

    func testCoincidentLoopCannotInventMusicalConnections() throws {
        var ordinary = try project(relation: "none")
        let normalDots = try frame(ordinary, time: 0.65, coincident: true)
        ordinary.settings.visual.effects.repeatNoteMode = "loop"
        XCTAssertEqual(try frame(ordinary, time: 0.65, coincident: true), normalDots)
        var slur = try project(relation: "slur")
        let pulse = try frame(slur, time: 0.65, coincident: true)
        slur.settings.visual.effects.repeatNoteMode = "loop"
        XCTAssertNotEqual(try frame(slur, time: 0.65, coincident: true), pulse)
        slur.settings.visual.effects.trailMode = "off"
        XCTAssertEqual(try frame(slur, time: 0.65, coincident: true), normalDots)
    }

    func testTieRemainsVisibleBeyondShortTrailHistory() throws {
        var tied = try project(relation: "tie")
        XCTAssertEqual(try PerformanceCompiler.compile(tied).notes.count, 1)
        let held = try frame(tied, time: 2.5)
        tied.settings.visual.effects.trailMode = "off"
        XCTAssertNotEqual(try frame(tied, time: 2.5), held)
    }

    func testCrossSystemRelationDoesNotDrawAcrossThePage() throws {
        var slur = try project(relation: "slur")
        let suppressed = try frame(slur, time: 0.65, crossSystem: true)
        let connected = try frame(slur, time: 0.65)
        XCTAssertNotEqual(suppressed, connected)
        slur.settings.visual.effects.trailMode = "off"
        XCTAssertEqual(try frame(slur, time: 0.65, crossSystem: true), suppressed)
    }

    func testCinematicCameraHasPerspectiveAndKeepsFocusedHeadsVisible() throws {
        var p = try project(relation: "slur")
        p.settings.visual.preset = "cinematic-paper"; p.settings.camera.preset = "cinematicFollow"
        let planned = try scene(p)
        for aspect: Float in [16.0 / 9,9.0 / 16] {
            for time in [0.0,0.65,1.5,2.5] {
                let camera = planned.camera(at: time, aspect: aspect)
                for point in planned.positions.values {
                    let clip = camera * SIMD4(point, 1)
                    XCTAssertGreaterThan(clip.w, 0)
                    XCTAssertLessThan(abs(clip.x / clip.w), 0.95)
                    XCTAssertLessThan(abs(clip.y / clip.w), 0.95)
                }
                let near = camera * SIMD4<Float>(400,-250,0,1)
                let far = camera * SIMD4<Float>(400,-350,0,1)
                XCTAssertNotEqual(near.w, far.w)
            }
        }
    }

    func testPageTransitionKeepsOutgoingNotesAndLockedViewChangesPage() throws {
        let base = try project(relation: "none")
        let extra = "<measure id='m2' number='2'><note id='d'><pitch><step>C</step><octave>5</octave></pitch><duration>3</duration><voice>1</voice><type>half</type><dot/></note></measure>"
        let xml = String(decoding: base.score.originalXML, as: UTF8.self).replacingOccurrences(of: "</part>", with: extra + "</part>")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".musicxml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(xml.utf8).write(to: url)
        var p = try ProjectFile.load(url); p.settings.performance.defaultTempoQPM = 60
        let png = try page()
        let anchors = Dictionary(uniqueKeysWithValues: ["a","b","c","d"].map { id in
            (id, LayoutAnchor(sourceID: id, page: id == "d" ? 1 : 0, x: 500, y: 300, radius: 5, system: id == "d" ? "second" : "first"))
        })
        let layout = LayoutSnapshot(pages: [LayoutPage(index: 0, width: 1000, height: 600, png: png),LayoutPage(index: 1, width: 1000, height: 600, png: png)], anchors: anchors, missingNoteIDs: [])
        let performance = try PerformanceCompiler.compile(p)
        var planned = ScenePlan(layout: layout, performance: performance, settings: p.settings)
        for (time,id) in [(2.1,"c"),(2.8,"c"),(2.99,"c"),(3.0,"d"),(3.3,"d"),(3.8,"d")] {
            let clip = planned.camera(at: time, aspect: 16.0 / 9) * SIMD4(try XCTUnwrap(planned.positions[id]), 1)
            XCTAssertGreaterThan(clip.w, 0)
            XCTAssertLessThan(abs(clip.x / clip.w), 0.96)
            XCTAssertLessThan(abs(clip.y / clip.w), 0.96)
        }
        p.settings.camera.preset = "locked"
        planned = ScenePlan(layout: layout, performance: performance, settings: p.settings)
        let clip = planned.camera(at: 3.5, aspect: 16.0 / 9) * SIMD4(try XCTUnwrap(planned.positions["d"]), 1)
        XCTAssertEqual(clip.x / clip.w, 0, accuracy: 0.001)
        XCTAssertEqual(clip.y / clip.w, 0, accuracy: 0.001)

        // A wide view can legitimately reveal several short pages. The visible
        // set must survive between frames even when it exceeds the LRU floor.
        p.settings.camera.preset = "cinematicFollow"
        let spread = anchors.mapValues { a in LayoutAnchor(sourceID: a.sourceID, page: a.sourceID == "d" ? 5 : 0, x: a.x, y: 25, radius: a.radius, system: a.system) }
        let many = LayoutSnapshot(pages: (0..<6).map { LayoutPage(index: $0, width: 1000, height: 50, png: png) }, anchors: spread, missingNoteIDs: [])
        let renderer = try MetalSceneRenderer(scene: ScenePlan(layout: many, performance: performance, settings: p.settings))
        _ = try renderer.capture(time: 0.5, width: 960, height: 540)
        let loaded = renderer.textureLoadCount
        XCTAssertGreaterThan(loaded, 3)
        _ = try renderer.capture(time: 0.5, width: 960, height: 540)
        XCTAssertEqual(renderer.textureLoadCount, loaded)
    }

    @MainActor
    func testFailedOverwritePreservesExistingMovieAndCanRetry() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this host") }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("ScoreFilm-export-test-\(UUID().uuidString)", isDirectory: true)
        let locked = folder.appendingPathComponent("destination", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        defer { try? fm.setAttributes([.posixPermissions:0o755], ofItemAtPath: locked.path); try? fm.removeItem(at: folder) }
        let audioURL = folder.appendingPathComponent("audio.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)); buffer.frameLength = 144000
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<144000 { channels[0][i] = Float(sin(Double(i) * 0.04) * 0.05); channels[1][i] = channels[0][i] }
        var file: AVAudioFile? = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try file?.write(from: buffer); file = nil
        var p = try project(relation: "none"); p.settings.export.fps.n = 30
        let scene = try scene(p)
        let audio = RenderedAudio(url: audioURL, frameCount: 144000, sampleRate: 48000)
        let exporter = VideoExporter(); let target = locked.appendingPathComponent("existing.mp4")
        let first = try await exporter.export(scene: scene, audio: audio, to: target, progress: { _ in })
        XCTAssertEqual(first.frameCount, 90)
        let original = try Data(contentsOf: target)
        try fm.setAttributes([.posixPermissions:0o555], ofItemAtPath: locked.path)
        do {
            _ = try await exporter.export(scene: scene, audio: audio, to: target, progress: { _ in })
            XCTFail("A read-only destination must not be overwritten")
        } catch { XCTAssertEqual(try Data(contentsOf: target), original) }
        try fm.setAttributes([.posixPermissions:0o755], ofItemAtPath: locked.path)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: locked.path), ["existing.mp4"])
        let retry = try await exporter.export(scene: scene, audio: audio, to: target, progress: { _ in })
        XCTAssertEqual(retry.frameCount, 90)
        let duration = try await AVURLAsset(url: target).load(.duration)
        XCTAssertEqual(duration.seconds, 3, accuracy: 1.0 / 30)
    }

    @MainActor
    func testPlaybackSeekAndConfigurationChangeRetainPosition() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScoreFilm-transport-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)); buffer.frameLength = 144000
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<144000 { channels[0][i] = 0; channels[1][i] = 0 }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let transport = AudioTransport()
        defer { transport.shutdown(); try? FileManager.default.removeItem(at: url) }
        try transport.load(RenderedAudio(url: url, frameCount: 144000, sampleRate: 48000))
        transport.seek(to: 1)
        do { try transport.play() } catch { throw XCTSkip("No usable audio output on this host: \(error.localizedDescription)") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(transport.isPlaying)
        XCTAssertGreaterThanOrEqual(transport.time, 1)
        let changes = transport.deviceChangeCount
        // Exercises the production notification response; this does not claim
        // that a physical audio device was disconnected during the test.
        transport.handleDeviceConfigurationChange()
        XCTAssertFalse(transport.isPlaying)
        XCTAssertEqual(transport.deviceChangeCount, changes + 1)
        XCTAssertGreaterThanOrEqual(transport.position, 1)
        try transport.play(); transport.seek(to: 0.5)
        XCTAssertGreaterThanOrEqual(transport.time, 0.5)
        try await Task.sleep(for: .milliseconds(100))
        transport.pause()
        XCTAssertGreaterThanOrEqual(transport.position, 0.5)
        XCTAssertLessThan(transport.position, 1)
        transport.stop(); XCTAssertEqual(transport.position, 0)
        transport.unload()
        XCTAssertEqual(transport.duration, 0)
        XCTAssertFalse(transport.isPlaying)
        try transport.load(RenderedAudio(url: url, frameCount: 144000, sampleRate: 48000))
        try transport.play()
        XCTAssertTrue(transport.isPlaying)
        XCTAssertEqual(transport.duration, 3)
    }

    @MainActor
    func testGroupedAudioPreservesLateVoiceAndSharedPeakLimit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScoreFilm-stems-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let pulse = folder.appendingPathComponent("C4.wav")
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)); buffer.frameLength = 2400
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<2400 { for c in 0..<2 { channels[c][i] = Float(exp(-Double(i) / 300) * cos(Double(i) * 0.1) * 0.8) } }
        do { let file = try AVAudioFile(forWriting: pulse, settings: format.settings); try file.write(from: buffer) }
        let base = try project(relation: "none")
        var voices = ""
        for voice in 1...9 {
            if voice > 1 { voices += "<backup><duration>3</duration></backup>" }
            let rest = "<note><rest/><duration>2</duration><voice>\(voice)</voice><type>half</type></note>"
            let note = "<note id='pulse\(voice)'><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>\(voice)</voice><type>quarter</type></note>"
            voices += voice == 9 ? rest + note : note + rest
        }
        let original = String(decoding: base.score.originalXML, as: UTF8.self)
        let begin = try XCTUnwrap(original.range(of: "<note id='a'>"))
        let end = try XCTUnwrap(original.range(of: "</measure>"))
        let xml = String(original[..<begin.lowerBound]) + voices + String(original[end.lowerBound...])
        let scoreURL = folder.appendingPathComponent("voices.musicxml")
        try Data(xml.utf8).write(to: scoreURL)
        var p = try ProjectFile.load(scoreURL)
        p.settings.performance.defaultTempoQPM = 60; p.settings.performance.reverbWetDryMix = 0
        let plan = try PerformanceCompiler.compile(p)
        XCTAssertEqual(Set(plan.notes.map(\.instanceID)).count, 9)
        let rendered = try await OfflineAudioRenderer(validationInstrument: pulse).render(plan: plan, project: p, to: folder.appendingPathComponent("result.caf"), progress: { _ in })
        let file = try AVAudioFile(forReading: rendered.url)
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: samples)
        let data = try XCTUnwrap(samples.floatChannelData?[0])
        func peak(_ time: Double) -> Float {
            let first = Int(time * 48000)
            return (first..<min(first + 4800, Int(samples.frameLength))).reduce(0) { max($0, abs(data[$1])) }
        }
        XCTAssertGreaterThan(peak(0), 0.01)
        XCTAssertGreaterThan(peak(2), 0.001)
        XCTAssertEqual(peak(0) / peak(2), 8, accuracy: 0.05)
        XCTAssertEqual(peak(0.25), 0)
        XCTAssertEqual(peak(1.75), 0)
        let globalPeak = (0..<Int(samples.frameLength)).reduce(Float(0)) { max($0, abs(data[$1])) }
        XCTAssertLessThanOrEqual(globalPeak, 0.89126)
        XCTAssertGreaterThan(rendered.duration, 3)
        p.settings.performance.masterVolume = 0.5
        p.settings.performance.voiceVolumes = [VoiceVolume(partId: "P1", voiceId: "9", volume: 0.25)]
        let adjusted = try await OfflineAudioRenderer(validationInstrument: pulse).render(plan: PerformanceCompiler.compile(p), project: p, to: folder.appendingPathComponent("adjusted.caf"), progress: { _ in })
        let adjustedFile = try AVAudioFile(forReading: adjusted.url)
        let adjustedSamples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: adjustedFile.processingFormat, frameCapacity: AVAudioFrameCount(adjustedFile.length)))
        try adjustedFile.read(into: adjustedSamples)
        let adjustedData = try XCTUnwrap(adjustedSamples.floatChannelData?[0])
        let earlyPeak = (0..<4800).reduce(Float(0)) { max($0, abs(adjustedData[$1])) }
        let latePeak = (96000..<100800).reduce(Float(0)) { max($0, abs(adjustedData[$1])) }
        XCTAssertEqual(earlyPeak, peak(0) * 0.5, accuracy: 0.0001)
        XCTAssertEqual(latePeak, peak(2) * 0.125, accuracy: 0.0001)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("stem-") || $0.hasPrefix("mix-") || $0.hasPrefix("raw-") })
    }

    @MainActor
    func testOfflineSamplerBusReverbProducesAnActualTail() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScoreFilm-reverb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pulse = folder.appendingPathComponent("C4.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)); buffer.frameLength = 2400
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<2400 {
            channels[0][i] = Float(exp(-Double(i) / 90) * cos(Double(i) * 0.65) * 0.8)
            channels[1][i] = channels[0][i]
        }
        do { let file = try AVAudioFile(forWriting: pulse, settings: format.settings); try file.write(from: buffer) }
        var p = try project(relation: "none"); p.settings.performance.reverbWetDryMix = 0
        let renderer = OfflineAudioRenderer(validationInstrument: pulse)
        let dry = try await renderer.render(plan: PerformanceCompiler.compile(p), project: p, to: folder.appendingPathComponent("dry.caf"), progress: { _ in })
        p.settings.performance.reverbWetDryMix = 60
        let wet = try await renderer.render(plan: PerformanceCompiler.compile(p), project: p, to: folder.appendingPathComponent("wet.caf"), progress: { _ in })
        func rms(_ audio: RenderedAudio) throws -> Double {
            let file = try AVAudioFile(forReading: audio.url)
            file.framePosition = 12000
            let sample = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800))
            try file.read(into: sample, frameCount: 4800)
            let channel = try XCTUnwrap(sample.floatChannelData?[0])
            return sqrt((0..<Int(sample.frameLength)).reduce(0) { $0 + Double(channel[$1]) * Double(channel[$1]) } / Double(sample.frameLength))
        }
        XCTAssertEqual(try rms(dry), 0)
        XCTAssertGreaterThan(try rms(wet), 0.0000001)
    }
}
