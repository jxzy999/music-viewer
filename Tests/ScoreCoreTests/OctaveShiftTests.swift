import XCTest
@testable import ScoreCore

final class OctaveShiftTests: XCTestCase {
    private let note = "<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type></note>"

    private func shift(_ attributes: String, staff: String = "1") -> String {
        "<direction><direction-type><octave-shift \(attributes)/></direction-type><staff>\(staff)</staff></direction>"
    }

    private func loadProject(_ body: String) throws -> (ProjectFile, Data) {
        let xml = "<score-partwise version='4.0'><part-list><score-part id='P1'><part-name>Piano</part-name><score-instrument id='I1'><instrument-name>Piano</instrument-name></score-instrument><midi-instrument id='I1'><midi-program>1</midi-program></midi-instrument></score-part></part-list><part id='P1'><measure number='1'><attributes><divisions>1</divisions><time><beats>2</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>\(body)</measure></part></score-partwise>"
        let data = Data(xml.utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OctaveShift-\(UUID().uuidString).musicxml")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return (try ProjectFile.load(url), data)
    }

    func testDisplayShiftsPreservePerformedPitchAndSourceXML() throws {
        for kind in ["down", "up"] {
            for size in [8, 15, 22] {
                let body = shift("type='\(kind)' size='\(size)' number='1'") + note
                    + shift("type='continue' size='\(size)' number='1'") + note
                    + shift("type='stop' number='1'")
                let (project, original) = try loadProject(body)
                XCTAssertTrue(project.score.canPerform, "\(kind) \(size)")
                XCTAssertEqual(project.score.originalXML, original)
                XCTAssertTrue(project.score.normalizedXML.contains("octave-shift"))
                XCTAssertEqual(project.score.notes.compactMap(\.midiPitch), [60, 60])
                XCTAssertEqual(try PerformanceCompiler.compile(project).notes.map(\.pitch), [60, 60])
            }
        }
        let (defaultSize, _) = try loadProject(shift("type='down'") + note + note + shift("type='stop'"))
        XCTAssertTrue(defaultSize.score.canPerform)
        XCTAssertEqual(try PerformanceCompiler.compile(defaultSize).notes.map(\.pitch), [60, 60])
    }

    func testPolyphonicDocumentOrderDoesNotImplyAnAudioShift() throws {
        // The stop at beat 2 precedes a backup and the start at beat 0 in
        // document order. MusicXML permits this ordering in polyphonic parts.
        let first = note.replacingOccurrences(of: "<duration>1</duration>", with: "<duration>2</duration>")
            .replacingOccurrences(of: "<type>quarter</type>", with: "<type>half</type>")
        let second = first.replacingOccurrences(of: "<voice>1</voice>", with: "<voice>2</voice>")
            .replacingOccurrences(of: "<octave>4</octave>", with: "<octave>5</octave>")
        let body = first + shift("type='stop' number='1'") + "<backup><duration>2</duration></backup>"
            + shift("type='down' size='8' number='1'") + second
        let (project, original) = try loadProject(body)
        XCTAssertTrue(project.score.canPerform)
        XCTAssertEqual(project.score.originalXML, original)
        let plan = try PerformanceCompiler.compile(project)
        XCTAssertEqual(Set(plan.notes.map(\.pitch)), [60, 72])
        XCTAssertTrue(plan.notes.allSatisfy { $0.start == 0 })
    }

    func testUnsupportedDisplayAttributesRemainBlocked() throws {
        let invalid = ["type='sideways'", "size='8'", "type='down' size='0'", "type='down' size='bad'",
                       "type='down' size='9'", "type='down' number='0'", "type='down' number='17'"]
        for attributes in invalid {
            let (project, original) = try loadProject(shift(attributes) + note + note)
            XCTAssertFalse(project.score.canPerform, attributes)
            XCTAssertEqual(project.score.originalXML, original)
            XCTAssertThrowsError(try PerformanceCompiler.compile(project), attributes)
        }
        for staff in ["0", "33", "bad"] {
            let (project, _) = try loadProject(shift("type='down'", staff: staff) + note + note)
            XCTAssertFalse(project.score.canPerform, staff)
        }
    }

    func testGraceAndTremoloStillRequireAnExplicitPlaybackInterpretation() throws {
        for markedNote in [note.replacingOccurrences(of: "<note>", with: "<note><grace/>"),
                           note.replacingOccurrences(of: "</note>", with: "<notations><ornaments><tremolo type='single'>2</tremolo></ornaments></notations></note>")] {
            let (project, _) = try loadProject(shift("type='down'") + markedNote + note + shift("type='stop'"))
            XCTAssertFalse(project.score.canPerform)
            XCTAssertThrowsError(try PerformanceCompiler.compile(project))
        }
    }
}
