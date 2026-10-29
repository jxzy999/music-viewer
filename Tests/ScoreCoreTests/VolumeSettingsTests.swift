import XCTest
@testable import ScoreCore

final class VolumeSettingsTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func template(_ name: String = "FurElise") throws -> ProjectFile {
        try ProjectFile.load(root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples/\(name).scorefilm"))
    }

    func testVoiceVolumesPreserveNotationTimingAndVelocity() throws {
        var project = try template()
        let original = try PerformanceCompiler.compile(project)
        XCTAssertNil(project.settings.performance.voiceVolumes)
        XCTAssertEqual(project.settings.performance.masterVolume ?? 1, 1)
        project.settings.performance.voiceVolumes = [VoiceVolume(partId: "P1", voiceId: "1", volume: 4), VoiceVolume(partId: "P1", voiceId: "5", volume: 0)]
        let plan = try PerformanceCompiler.compile(project)
        XCTAssertEqual(plan.notes.count, 106)
        XCTAssertEqual(plan.notes.map(\.pitch), original.notes.map(\.pitch))
        XCTAssertEqual(plan.notes.map(\.velocity), original.notes.map(\.velocity))
        XCTAssertEqual(plan.notes.map(\.start), original.notes.map(\.start))
        XCTAssertEqual(plan.notes.map(\.end), original.notes.map(\.end))
        XCTAssertEqual(plan.anchors.map(\.id), original.anchors.map(\.id))
        XCTAssertTrue(plan.notes.filter { $0.voice == "1" }.allSatisfy { $0.volume == 4 })
        XCTAssertTrue(plan.notes.filter { $0.voice == "5" }.allSatisfy { $0.volume == 0 })
    }

    func testMatchingVoiceIDsInDifferentPartsRemainIndependent() throws {
        var project = try template("OdeToJoy")
        let first = try XCTUnwrap(project.score.parts.first)
        let second = project.score.parts[1]
        let voice = try XCTUnwrap(Set(first.voices).intersection(second.voices).first)
        project.settings.performance.voiceVolumes = [VoiceVolume(partId: first.id, voiceId: voice, volume: 0.25), VoiceVolume(partId: second.id, voiceId: voice, volume: 2)]
        let plan = try PerformanceCompiler.compile(project)
        XCTAssertEqual(Set(plan.notes.filter { $0.partID == first.id && $0.voice == voice }.map(\.volume)), [0.25])
        XCTAssertEqual(Set(plan.notes.filter { $0.partID == second.id && $0.voice == voice }.map(\.volume)), [2])
    }

    func testInvalidVolumeReferencesAndRangesAreRejected() throws {
        let original = try template()
        for item in [VoiceVolume(partId: "missing", voiceId: "1", volume: 1), VoiceVolume(partId: "P1", voiceId: "missing", volume: 1), VoiceVolume(partId: "P1", voiceId: "1", volume: -0.1), VoiceVolume(partId: "P1", voiceId: "1", volume: 4.1), VoiceVolume(partId: "P1", voiceId: "1", volume: .nan)] {
            var settings = original.settings; settings.performance.voiceVolumes = [item]
            XCTAssertThrowsError(try ProjectFile.validate(settings, score: original.score))
        }
        var settings = original.settings
        let item = VoiceVolume(partId: "P1", voiceId: "1", volume: 1)
        settings.performance.voiceVolumes = [item, item]
        XCTAssertThrowsError(try ProjectFile.validate(settings, score: original.score))
        for volume in [-0.1, 1.1, Double.nan] {
            settings = original.settings; settings.performance.masterVolume = volume
            XCTAssertThrowsError(try ProjectFile.validate(settings, score: original.score))
        }
    }

    func testVolumeSettingsRoundTripAndResetWithoutResurrectingOldValues() throws {
        var project = try template()
        project.settings.performance.masterVolume = 0.35
        project.settings.performance.voiceVolumes = [VoiceVolume(partId: "P1", voiceId: "1", volume: 3)]
        var reopened = try ProjectFile.loadArchive(project.archive())
        XCTAssertEqual(reopened.settings.performance.masterVolume, 0.35)
        XCTAssertEqual(reopened.settings.performance.voiceVolumes?.first?.volume, 3)
        XCTAssertEqual(reopened.score.originalXML, project.score.originalXML)
        reopened.settings.performance.masterVolume = nil; reopened.settings.performance.voiceVolumes = nil
        let reset = try ProjectFile.loadArchive(reopened.archive())
        XCTAssertNil(reset.settings.performance.masterVolume)
        XCTAssertNil(reset.settings.performance.voiceVolumes)
    }

    func testUnknownVoiceMixMetadataStaysWithItsOwnVoice() throws {
        var project = try template()
        project.settings.performance.voiceVolumes = [VoiceVolume(partId: "P1", voiceId: "1", volume: 2), VoiceVolume(partId: "P1", voiceId: "5", volume: 0.5)]
        var entries = try ZIPArchive.read(project.archive())
        var settings = try XCTUnwrap(JSONSerialization.jsonObject(with: entries[project.settingsPath]!) as? [String: Any])
        var performance = try XCTUnwrap(settings["performance"] as? [String: Any])
        var volumes = try XCTUnwrap(performance["voiceVolumes"] as? [[String: Any]])
        volumes[0]["futureMixLabel"] = "melody"; volumes[1]["futureMixLabel"] = "bass"
        performance["voiceVolumes"] = volumes; settings["performance"] = performance
        entries[project.settingsPath] = try JSONSerialization.data(withJSONObject: settings)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: entries["manifest.json"]!) as? [String: Any])
        manifest["integrity"] = entries.filter { $0.key != "manifest.json" }.mapValues(ProjectFile.digest)
        entries["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest)
        var reopened = try ProjectFile.loadArchive(ZIPArchive.write(entries))
        reopened.settings.performance.voiceVolumes?.removeAll { $0.voiceId == "1" }
        let saved = try ZIPArchive.read(reopened.archive())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved[project.settingsPath]!) as? [String: Any])
        let result = try XCTUnwrap((json["performance"] as? [String: Any])?["voiceVolumes"] as? [[String: Any]])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["voiceId"] as? String, "5")
        XCTAssertEqual(result[0]["futureMixLabel"] as? String, "bass")
    }
}
