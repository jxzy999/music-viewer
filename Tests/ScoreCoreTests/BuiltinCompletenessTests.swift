import XCTest
@testable import ScoreCore

final class BuiltinCompletenessTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testFurEliseContainsAllSectionsAndOriginalEndings() throws {
        let project = try ProjectFile.load(root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples/FurElise.scorefilm"))
        let plan = try PerformanceCompiler.compile(project)
        XCTAssertEqual(project.score.parts[0].measures.count, 106)
        XCTAssertEqual(plan.visits.count, 127)
        XCTAssertEqual(plan.notes.count, 1020)
        XCTAssertEqual(plan.duration, 156.25, accuracy: 0.00001)
        XCTAssertEqual(Set(plan.visits.map(\.index)), Set(0..<106))
        XCTAssertTrue(plan.notes.contains { $0.pitch == 100 }) // Original high E7, not another octave higher.
        XCTAssertTrue(plan.notes.allSatisfy { (0...127).contains($0.pitch) && $0.end > $0.start })
        XCTAssertFalse(plan.trails.isEmpty)
        XCTAssertNotNil(project.entries["Metadata/completeness.json"])
    }

    func testBachContainsAllEpisodesAndFinalRondoReturn() throws {
        let project = try ProjectFile.load(root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples/BachGavotte.scorefilm"))
        let plan = try PerformanceCompiler.compile(project)
        XCTAssertEqual(project.score.parts[0].measures.count, 102)
        XCTAssertEqual(plan.visits.count, 111)
        XCTAssertEqual(plan.notes.count, 872)
        XCTAssertEqual(plan.duration, 432 * 60 / 110, accuracy: 0.00001)
        XCTAssertEqual(Set(plan.visits.map(\.index)), Set(0..<102))
        // Every non-opening rondo episode is visited once; only the opening
        // source volta repeats. This catches a theme-only two-pass replacement.
        for index in 9..<102 { XCTAssertEqual(plan.visits.filter { $0.index == index }.count, 1) }
        XCTAssertEqual(Set(plan.notes.map { $0.instrument.id }), ["violin"])
        XCTAssertEqual(Set(project.score.parts[0].voices), ["1", "2"])
    }
    func testGreensleevesContainsAllFifteenSourceDivisions() throws {
        let project = try ProjectFile.load(root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples/Greensleeves.scorefilm"))
        let plan = try PerformanceCompiler.compile(project)
        XCTAssertEqual(project.score.parts.map { $0.measures.count }, [120, 120])
        XCTAssertEqual(plan.visits.count, 240)
        XCTAssertEqual(plan.notes.count, 2076)
        XCTAssertEqual(plan.duration, 540, accuracy: 0.00001)
        XCTAssertEqual(Set(plan.visits.map(\.index)), Set(0..<120))
        for index in 0..<120 { XCTAssertEqual(plan.visits.filter { $0.index == index }.count, 2) }
        // Each source division has different melody material above the ground.
        let melody = project.score.parts[0].measures
        let divisions = stride(from: 0, to: 120, by: 8).map { start in
            melody[start..<(start + 8)].flatMap { $0.notes.compactMap(\.midiPitch) }
        }
        XCTAssertEqual(Set(divisions).count, 15)
        XCTAssertEqual(Set(plan.notes.map { $0.instrument.id }), ["violin", "piano"])
    }

    func testCompleteDuetArrangementsRetainBothWholeThemePresentations() throws {
        for (name, fixture, bars, seconds, themeCount, returnStart, transpose) in [
            ("OdeToJoy", "OdeToJoyTheme", 56, 143.95382395382396, 16, 20, 0),
            ("AmazingGrace", "AmazingGraceTheme", 50, 165.86913086913086, 17, 29, -12)
        ] {
            let project = try ProjectFile.load(root.appendingPathComponent("Sources/ScoreFilm/Resources/Examples/\(name).scorefilm"))
            let theme = try ProjectFile.load(root.appendingPathComponent("Tests/Fixtures/\(fixture).musicxml"))
            let plan = try PerformanceCompiler.compile(project)
            XCTAssertEqual(project.score.parts.map { $0.measures.count }, [bars, bars])
            XCTAssertEqual(plan.visits.count, bars) // No whole-score repeat added.
            XCTAssertEqual(plan.duration, seconds, accuracy: 0.00001)
            XCTAssertEqual(Set(plan.notes.map { $0.instrument.id }), ["violin", "piano"])
            for index in 0..<themeCount {
                let original = theme.score.parts[0].measures[index].notes
                let violin = project.score.parts[0].measures[index + 4].notes
                let piano = project.score.parts[1].measures[index + returnStart].notes.filter { $0.voice == "1" }
                XCTAssertEqual(violin.map(\.midiPitch), original.map(\.midiPitch))
                XCTAssertEqual(violin.map(\.duration), original.map(\.duration))
                XCTAssertEqual(violin.map(\.offset), original.map(\.offset))
                XCTAssertEqual(piano.map(\.midiPitch), original.map { $0.midiPitch.map { $0 + transpose } })
                XCTAssertEqual(piano.map(\.duration), original.map(\.duration))
                XCTAssertEqual(piano.map(\.offset), original.map(\.offset))
            }
            XCTAssertNotNil(project.entries["Metadata/completeness.json"])
        }
    }

}
