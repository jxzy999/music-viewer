import XCTest
@testable import ScoreCore

final class UserLibraryTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    func testBuiltInScoresHaveExpectedInstrumentsAndUnambiguousPlans() throws {
        let folder = root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples")
        for filename in ["FurElise.scorefilm", "BachGavotte.scorefilm", "OdeToJoy.scorefilm", "Greensleeves.scorefilm", "AmazingGrace.scorefilm"] {
            let project = try ProjectFile.load(folder.appendingPathComponent(filename))
            XCTAssertTrue(project.score.canPerform, filename)
            let plan = try PerformanceCompiler.compile(project)
            XCTAssertGreaterThan(plan.duration, 20, filename)
            XCTAssertGreaterThan(plan.notes.count, 40, filename)
            if filename == "FurElise.scorefilm" {
                // The source theme has no explicit slur/tie relationships.
                XCTAssertTrue(plan.trails.isEmpty, filename)
            } else { XCTAssertFalse(plan.trails.isEmpty, filename) }
            if filename == "FurElise.scorefilm" {
                XCTAssertEqual(Set(plan.notes.map { $0.instrument.id }), ["piano"])
                XCTAssertEqual(project.score.parts.count, 1)
            } else if filename == "BachGavotte.scorefilm" {
                XCTAssertEqual(Set(plan.notes.map { $0.instrument.id }), ["violin"])
                XCTAssertEqual(project.score.parts.count, 1)
            } else {
                XCTAssertEqual(Set(plan.notes.map { $0.instrument.id }), ["violin", "piano"])
                XCTAssertEqual(project.score.parts.count, 2)
                XCTAssertTrue(plan.notes.filter { $0.partID == "P1" }.allSatisfy { $0.instrument.id == "violin" })
            }
            XCTAssertNotNil(project.entries["Licenses/score.txt"])
        }
    }

    func testIndependentCopiesKeepSourceAndExtensionsAndDoNotChangeTheTemplate() async throws {
        let templateURL = root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples/OdeToJoy.scorefilm")
        let original = try Data(contentsOf: templateURL)
        let template = try ProjectFile.load(templateURL)
        var first = template.userCopy()
        let second = template.userCopy()
        XCTAssertNotEqual(first.id, template.id)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNil(first.sourceURL)
        first.settings.partInstruments["P1"] = "piano"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = UserProjectLibrary(root: folder)
        let url = try await library.save(first)
        _ = try await library.save(second)
        let opened = try ProjectFile.load(url)
        XCTAssertEqual(opened.id, first.id)
        XCTAssertEqual(opened.settings.partInstruments["P1"], "piano")
        XCTAssertEqual(opened.score.originalXML, template.score.originalXML)
        XCTAssertEqual(opened.entries["Licenses/score.txt"], template.entries["Licenses/score.txt"])
        XCTAssertEqual(try Data(contentsOf: templateURL), original)
        XCTAssertEqual(template.settings.partInstruments["P1"], "violin")
        let summaries = try await library.projects()
        XCTAssertEqual(Set(summaries.map(\.id)), [first.id, second.id])
    }

    func testSavingExistingCopyKeepsItsIdentityAndRepairsMissingMetadata() async throws {
        var copy = try ProjectFile.load(root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples/Greensleeves.scorefilm")).userCopy()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = UserProjectLibrary(root: folder)
        let url = try await library.save(copy)
        copy.settings.performance.tempoScale = 0.75
        let same = try await library.save(copy)
        XCTAssertEqual(same, url)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(copy.id.uuidString + ".json"))
        let restored = try await library.projects()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, copy.id)
        XCTAssertEqual(try ProjectFile.load(url).settings.performance.tempoScale, 0.75)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(copy.id.uuidString + ".json").path))
    }
}
