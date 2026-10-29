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
            XCTAssertFalse(plan.trails.isEmpty, filename)
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

    func testTrashRestoreAndLateAutosaveKeepProjectDataSafe() async throws {
        let templateURL = root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples/FurElise.scorefilm")
        let templateBytes = try Data(contentsOf: templateURL)
        let copy = try ProjectFile.load(templateURL).userCopy()
        let other = copy.userCopy()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTrash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = UserProjectLibrary(root: folder)
        let url = try await library.save(copy)
        let otherURL = try await library.save(other)
        let originalBytes = try Data(contentsOf: url)
        let otherBytes = try Data(contentsOf: otherURL)
        let summaries = try await library.projects()
        let summary = try XCTUnwrap(summaries.first { $0.id == copy.id })
        let destination = try await library.moveToTrash(summary)
        let trashed = try XCTUnwrap(destination)
        defer {
            if FileManager.default.fileExists(atPath: trashed.path), !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.moveItem(at: trashed, to: url)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(copy.id.uuidString + ".json").path))
        XCTAssertEqual(try Data(contentsOf: trashed), originalBytes)
        XCTAssertEqual(try Data(contentsOf: otherURL), otherBytes)
        XCTAssertEqual(try Data(contentsOf: templateURL), templateBytes)
        let afterTrash = try await library.projects()
        XCTAssertEqual(afterTrash.map(\.id), [other.id])
        do { _ = try await library.save(copy); XCTFail("A late autosave must not recreate a trashed project") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.moveItem(at: trashed, to: url)
        let restored = try await library.projects()
        XCTAssertEqual(Set(restored.map(\.id)), [copy.id, other.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(copy.id.uuidString + ".json").path))
        let savedAgain = try await library.save(copy)
        XCTAssertEqual(savedAgain, url)
        XCTAssertEqual(try ProjectFile.load(savedAgain).score.originalXML, copy.score.originalXML)
    }

    func testChangedOrMismatchedProjectCannotBeTrashedFromAStaleRow() async throws {
        let copy = try ProjectFile.load(root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples/OdeToJoy.scorefilm")).userCopy()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTrashGuard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = UserProjectLibrary(root: folder)
        let url = try await library.save(copy)
        let entries = try await library.projects()
        let summary = try XCTUnwrap(entries.first)
        let bytes = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.modificationDate: summary.modified.addingTimeInterval(10)], ofItemAtPath: url.path)
        do { _ = try await library.moveToTrash(summary); XCTFail("Changed project needs a fresh confirmation") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)

        let foreignBytes = try copy.userCopy().archive()
        try foreignBytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: summary.modified], ofItemAtPath: url.path)
        do { _ = try await library.moveToTrash(summary); XCTFail("File identity mismatch must be rejected") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), foreignBytes)
    }

    func testSymbolicLinkCannotTrashAnExternalProject() async throws {
        let copy = try ProjectFile.load(root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples/FurElise.scorefilm")).userCopy()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTrashLink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = UserProjectLibrary(root: folder.appendingPathComponent("Projects", isDirectory: true))
        let url = try await library.save(copy)
        let rows = try await library.projects()
        let summary = try XCTUnwrap(rows.first)
        let external = folder.appendingPathComponent("original.scorefilm")
        try FileManager.default.moveItem(at: url, to: external)
        let original = try Data(contentsOf: external)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: external)
        do { _ = try await library.moveToTrash(summary); XCTFail("A symbolic link must not be followed") } catch {}
        XCTAssertEqual(try Data(contentsOf: external), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
