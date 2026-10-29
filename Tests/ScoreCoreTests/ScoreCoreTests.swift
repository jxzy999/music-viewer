import XCTest
@testable import ScoreCore

final class ScoreCoreTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func example() throws -> ProjectFile { try ProjectFile.load(root.appendingPathComponent("Docs/Examples/Duet.scorefilm")) }

    func testExactBeatAndOverflow() throws {
        let third = try Beat(1, 3)
        XCTAssertEqual(try third.adding(third).adding(third), try Beat(1))
        XCTAssertEqual(try Beat(2, 6), third)
        XCTAssertThrowsError(try Beat(1, 0))
        XCTAssertThrowsError(try Beat(Int64.max).adding(Beat(1)))
        XCTAssertTrue(try Beat(Int64.max, 2) < Beat(Int64.max))
    }

    func testPolyphonyAndSourcePreservation() throws {
        let project = try example()
        XCTAssertEqual(project.score.parts.count, 2)
        XCTAssertEqual(project.score.noteCount, 28)
        XCTAssertEqual(project.score.slurs.count, 2)
        let chord = project.score.parts[1].measures[0].notes.filter { !$0.isRest }
        XCTAssertEqual(chord.count, 4)
        XCTAssertTrue(chord.allSatisfy { $0.offset == .zero })
        let saved = try ProjectFile.loadArchive(project.archive())
        XCTAssertEqual(saved.score.originalXML, project.score.originalXML)
        XCTAssertEqual(saved.settings.routes.first?.instrumentId, "violin")
    }

    func testTimingTieAndInstrumentRouting() throws {
        let plan = try PerformanceCompiler.compile(example())
        XCTAssertEqual(plan.duration, 75.0 / 7.0, accuracy: 1e-10)
        XCTAssertEqual(plan.notes.count, 27)
        let tied = try XCTUnwrap(plan.notes.first { $0.sourceIDs.contains("p1m2n1") })
        XCTAssertEqual(tied.sourceIDs, ["p1m2n1", "p1m2n2"])
        XCTAssertEqual(tied.end - tied.start, 1.875, accuracy: 1e-10)
        XCTAssertTrue(plan.notes.filter { $0.partID == "P1" && $0.start >= 5 }.allSatisfy { $0.instrument.id == "violin" })
        XCTAssertTrue(plan.notes.filter { $0.partID == "P2" }.allSatisfy { $0.instrument.id == "piano" })
    }

    func testTrailsRequireExplicitMusicalRelationships() throws {
        let plan = try PerformanceCompiler.compile(example())
        XCTAssertEqual(plan.trails.filter { $0.kind == .slur }.count, 6)
        XCTAssertEqual(plan.trails.filter { $0.kind == .tie }.count, 1)
        XCTAssertFalse(plan.trails.contains { $0.fromID.hasSuffix("p1m1n3") && $0.toID.hasSuffix("p1m1n4") })
        XCTAssertFalse(plan.trails.contains { $0.fromID.contains("p2") })
        let tie = try XCTUnwrap(plan.trails.first { $0.kind == .tie })
        XCTAssertGreaterThan(tie.holdUntil - tie.arrival, 0.22)
    }

    func testGlobalOffCannotBeOverriddenAndTravelDoesNotInventLinks() throws {
        var project = try example()
        project.settings.visual.effects.trailMode = "travel"
        let travel = try PerformanceCompiler.compile(project)
        XCTAssertEqual(travel.trails.count, 7)
        project.settings.visual.effects.trailMode = "off"
        project.settings.visual.noteOverrides = [NoteVisualOverride(noteId: "p1m1n1", trail: "travel")]
        XCTAssertTrue(try PerformanceCompiler.compile(project).trails.isEmpty)
    }

    func testZIPIntegrityAndUnsafePaths() throws {
        let data = try ZIPArchive.write(["score.musicxml": Data("hello".utf8), "Assets/license.txt": Data()])
        XCTAssertEqual(try ZIPArchive.read(data)["score.musicxml"], Data("hello".utf8))
        for path in ["../a", "/tmp/a", "a/../b", "a\\b", "a//b", "C:/a"] {
            XCTAssertFalse(ZIPArchive.validPath(path), path)
            XCTAssertThrowsError(try ZIPArchive.write([path: Data()]))
        }
        var broken = try ZIPArchive.write(["score.musicxml": Data("hello".utf8)])
        broken[30 + "score.musicxml".utf8.count] ^= 0xff
        XCTAssertThrowsError(try ZIPArchive.read(broken))
    }

    func testUnknownSettingsFieldsSurviveSaving() throws {
        var entries = try ZIPArchive.read(Data(contentsOf: root.appendingPathComponent("Docs/Examples/Duet.scorefilm")))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: entries["project.json"]!) as? [String: Any])
        json["extensions"] = ["example.vendor": ["value": "preserve me"]]
        entries["project.json"] = try JSONSerialization.data(withJSONObject: json)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: entries["manifest.json"]!) as? [String: Any])
        var hashes = try XCTUnwrap(manifest["integrity"] as? [String: String])
        hashes["project.json"] = ProjectFile.digest(entries["project.json"]!)
        manifest["integrity"] = hashes
        entries["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest)
        let loaded = try ProjectFile.loadArchive(ZIPArchive.write(entries))
        let saved = try ZIPArchive.read(loaded.archive())
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: saved["project.json"]!) as? [String: Any])
        XCTAssertNotNil(settings["extensions"])
    }

    func testEntityDeclarationRejected() {
        let xml = "<!DOCTYPE score-partwise [<!ENTITY a 'x'>]><score-partwise/>"
        XCTAssertThrowsError(try MusicXMLReader.read(Data(xml.utf8)))
    }

    func testClearingOptionalSelectorIsPreservedOnSave() throws {
        var project = try ProjectFile.load(root.appendingPathComponent("Docs/Examples/Duet.scorefilm"))
        XCTAssertNotNil(project.settings.routes[0].selector.voiceId)
        project.settings.routes[0].selector.voiceId = nil
        let loaded = try ProjectFile.loadArchive(project.archive())
        XCTAssertNil(loaded.settings.routes[0].selector.voiceId)
    }
}
