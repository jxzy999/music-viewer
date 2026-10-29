import XCTest
@testable import ScoreCore

final class PerformanceRegressionTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let note = "<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice><type>quarter</type></note>"
    private func project(_ bars: [String], declaration: String = "<score-instrument id='I1'><instrument-name>Piano</instrument-name></score-instrument><midi-instrument id='I1'><midi-program>1</midi-program></midi-instrument>") throws -> ProjectFile {
        let measures = bars.enumerated().map { index, content in
            "<measure id='m\(index+1)' number='\(index+1)'>" + (index == 0 ? "<attributes><divisions>1</divisions><time><beats>1</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>" : "") + content + "</measure>"
        }.joined()
        let xml = "<score-partwise version='4.0'><part-list><score-part id='P1'><part-name>Piano</part-name>\(declaration)</score-part></part-list><part id='P1'>\(measures)</part></score-partwise>"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".musicxml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(xml.utf8).write(to: url)
        return try ProjectFile.load(url)
    }

    func testRepeatRestoresTempoAtEntry() throws {
        let tempo120 = "<direction><sound tempo='120'/></direction>"
        let tempo60 = "<direction><sound tempo='60'/></direction>"
        let start = "<barline location='left'><repeat direction='forward'/></barline>"
        let end = "<barline location='right'><repeat direction='backward'/></barline>"
        let p = try project([tempo120 + note, start + note, tempo60 + note + end])
        let plan = try PerformanceCompiler.compile(p)
        XCTAssertEqual(plan.visits.map(\.index), [0,1,2,1,2])
        XCTAssertEqual(plan.notes.map(\.start), [0,0.5,1,2,2.5])
        XCTAssertEqual(plan.duration, 3.5, accuracy: 1e-10)
    }

    func testNestedRepeatAndAlternateEndingsTerminate() throws {
        let start = "<barline location='left'><repeat direction='forward'/></barline>"
        let end = "<barline location='right'><repeat direction='backward'/></barline>"
        let nested = try PerformanceCompiler.compile(project([start + note, start + note, note + end, note + end]))
        XCTAssertEqual(nested.visits.map(\.index), [0,1,2,1,2,3,0,1,2,1,2,3])
        let ending1 = "<barline location='left'><ending number='1' type='start'/></barline>" + note + "<barline location='right'><ending number='1' type='stop'/><repeat direction='backward'/></barline>"
        let ending2 = "<barline location='left'><ending number='2' type='start'/></barline>" + note + "<barline location='right'><ending number='2' type='stop'/></barline>"
        let alternate = try PerformanceCompiler.compile(project([start + note, ending1, ending2]))
        XCTAssertEqual(alternate.visits.map(\.index), [0,1,0,2])
    }

    func testLinearTempoIntegralAndFermataShareOneAxis() throws {
        var p = try project([note, note])
        p.settings.performance.tempoOverrides = [TempoOverride(position: ScorePosition(measureId: "m1", beat: .zero), qpm: 120, interpolation: "linearQPM"), TempoOverride(position: ScorePosition(measureId: "m2", beat: try Beat(1)), qpm: 60, interpolation: "step")]
        let plan = try PerformanceCompiler.compile(p)
        XCTAssertEqual(plan.duration, 2 * log(2), accuracy: 1e-9)
        let fermataNote = note.replacingOccurrences(of: "</note>", with: "<notations><fermata/></notations></note>")
        var held = try project([fermataNote, note]); held.settings.performance.defaultTempoQPM = 60; held.settings.performance.fermataMultiplier = 2
        let fermata = try PerformanceCompiler.compile(held)
        XCTAssertEqual(fermata.notes[0].end, 2, accuracy: 1e-10)
        XCTAssertEqual(fermata.notes[1].start, 2, accuracy: 1e-10)
        XCTAssertEqual(fermata.duration, 3, accuracy: 1e-10)
    }

    func testMutedPartsDoNotCompressTimeOrInventTrails() throws {
        var p = try ProjectFile.load(root.appendingPathComponent("Docs/Examples/Duet.scorefilm"))
        let baseline = try PerformanceCompiler.compile(p)
        p.settings.performance.mutedPartIds = ["P1"]
        let muted = try PerformanceCompiler.compile(p)
        XCTAssertTrue(muted.notes.allSatisfy { $0.partID == "P2" })
        XCTAssertEqual(muted.duration, baseline.duration)
        XCTAssertEqual(muted.trails.map(\.id), baseline.trails.map(\.id))
        p.settings.performance.soloPartIds = ["P1"]
        XCTAssertTrue(try PerformanceCompiler.compile(p).notes.isEmpty)
    }

    func testHumanizationIsDeterministicAndRetainsTieIdentity() throws {
        var p = try ProjectFile.load(root.appendingPathComponent("Docs/Examples/Duet.scorefilm"))
        p.settings.performance.humanize.timingJitterMS = 20; p.settings.performance.humanize.velocityJitter = 8
        let a = try PerformanceCompiler.compile(p); let b = try PerformanceCompiler.compile(p)
        XCTAssertEqual(a.notes.map(\.start), b.notes.map(\.start))
        XCTAssertEqual(a.notes.map(\.velocity), b.notes.map(\.velocity))
        let tie = try XCTUnwrap(a.notes.first { $0.sourceIDs.count == 2 })
        XCTAssertEqual(a.anchors.filter { $0.soundID == tie.id }.count, 2)
        XCTAssertTrue(a.notes.allSatisfy { $0.start >= 0 && $0.end > $0.start })
    }

    func testSamePitchVoicesAndRoutingBoundaryHaveIndependentOwnership() throws {
        let twoVoices = note + "<backup><duration>1</duration></backup>" + note.replacingOccurrences(of: "<voice>1</voice>", with: "<voice>2</voice>")
        var p = try project([twoVoices, note])
        p.settings.routes = [InstrumentRoute(selector: NoteSelector(partId: "P1"), range: ScoreRange(from: ScorePosition(measureId: "m2", beat: .zero), to: ScorePosition(measureId: "m2", beat: try Beat(1))), instrumentId: "violin")]
        let a = try PerformanceCompiler.compile(p)
        XCTAssertEqual(Set(a.notes.filter { $0.start == 0 }.map(\.instanceID)).count, 2)
        XCTAssertEqual(a.notes.first { $0.sourceIDs.contains("P1-m2-n1") }?.instrument.id, "violin")
        p.settings.routes.append(p.settings.routes[0])
        XCTAssertThrowsError(try PerformanceCompiler.compile(p))
    }

    func testMalformedNumericInputThrowsInsteadOfSilentlyDroppingTime() {
        for malformed in [note.replacingOccurrences(of: "<duration>1</duration>", with: "<duration>bad</duration>"), note.replacingOccurrences(of: "<duration>1</duration>", with: "<duration>9223372036854775807</duration>"), "<direction><sound tempo='inf'/></direction>" + note] {
            XCTAssertThrowsError(try project([malformed]))
        }
    }

    func testCrossStaffAndCrossBarStudyHasExplicitTiesOnly() throws {
        let p = try ProjectFile.load(root.appendingPathComponent("Sources/ScoreFilm/Resources/PaperAndLight.scorefilm"))
        let a = try PerformanceCompiler.compile(p)
        XCTAssertEqual(p.score.noteCount, 113); XCTAssertEqual(a.notes.count, 107)
        XCTAssertEqual(a.trails.filter { $0.kind == .tie }.count, 6)
        XCTAssertEqual(a.duration, 300.0 / 7, accuracy: 1e-9)
        XCTAssertFalse(a.trails.contains { $0.fromID.contains("p2") })
    }

    func testExplicitSoundAndNoteDynamicsOverridePrintedMarks() throws {
        let mf = "<direction><direction-type><dynamics><mf/></dynamics></direction-type><sound tempo='60' dynamics='69'/></direction>"
        let ff = "<direction><direction-type><dynamics><ff/></dynamics></direction-type><sound dynamics='100'/></direction>"
        let p = try project([mf + note, ff + note.replacingOccurrences(of: "<note>", with: "<note dynamics='50'>")])
        XCTAssertEqual(p.score.notes.map(\.velocity), [62,45])
        let plan = try PerformanceCompiler.compile(p)
        XCTAssertEqual(plan.duration, 2, accuracy: 1e-10)
    }

    func testDynamicsAtFutureOffsetDoNotApplyToEarlierNotes() throws {
        let direction = "<direction><direction-type><dynamics><ff/></dynamics></direction-type><offset>1</offset></direction>"
        let p = try project([direction + note + note])
        XCTAssertEqual(p.score.notes.map(\.velocity), [76,108])
    }

    func testTupletsAndChangedDivisionsKeepExactDurations() throws {
        let triplet = note.replacingOccurrences(of: "<duration>1</duration>", with: "<duration>160</duration>")
            .replacingOccurrences(of: "<type>quarter</type>", with: "<type>eighth</type><time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>")
        let quintuplet = note.replacingOccurrences(of: "<duration>1</duration>", with: "<duration>30</duration>")
            .replacingOccurrences(of: "<type>quarter</type>", with: "<type>16th</type><time-modification><actual-notes>5</actual-notes><normal-notes>4</normal-notes></time-modification>")
        let dotted = note.replacingOccurrences(of: "<duration>1</duration>", with: "<duration>225</duration>").replacingOccurrences(of: "</type>", with: "</type><dot/>")
        var p = try project(["<attributes><divisions>480</divisions></attributes>" + String(repeating: triplet, count: 3) + "<attributes><divisions>150</divisions></attributes>" + String(repeating: quintuplet, count: 5) + dotted])
        XCTAssertEqual(p.score.notes.prefix(3).map(\.duration), Array(repeating: try Beat(1,3), count: 3))
        XCTAssertEqual(p.score.notes.dropFirst(3).prefix(5).map(\.duration), Array(repeating: try Beat(1,5), count: 5))
        XCTAssertEqual(p.score.parts[0].measures[0].length, try Beat(7,2))
        p.settings.performance.defaultTempoQPM = 60
        let plan = try PerformanceCompiler.compile(p)
        XCTAssertEqual(plan.duration, 3.5, accuracy: 1e-12)
        XCTAssertEqual(plan.notes.last?.start, 2)
    }

    func testWrittenTransposeAndGMProgramsAreIndependent() throws {
        for program in [1,41] {
            let declaration = "<score-instrument id='I1'><instrument-name>Test</instrument-name></score-instrument><midi-instrument id='I1'><midi-program>\(program)</midi-program></midi-instrument>"
            let p = try project(["<attributes><transpose><diatonic>-1</diatonic><chromatic>-2</chromatic><octave-change>1</octave-change></transpose></attributes>" + note], declaration: declaration)
            XCTAssertTrue(String(decoding: p.score.originalXML, as: UTF8.self).contains("<step>C</step><octave>4</octave>"))
            let plan = try PerformanceCompiler.compile(p)
            XCTAssertEqual(plan.notes.first?.pitch, 70)
            XCTAssertEqual(plan.notes.first?.instrument.program, program - 1)
        }
    }

    func testSeparateSlurGroupsAndRestsCannotBeBridged() throws {
        func marked(_ type: String, _ number: Int) -> String { note.replacingOccurrences(of: "</note>", with: "<notations><slur type='\(type)' number='\(number)'/></notations></note>") }
        let rest = "<note><rest/><duration>1</duration><voice>1</voice><type>quarter</type></note>"
        var p = try project([marked("start",1) + marked("stop",1) + marked("start",2) + marked("stop",2) + note, marked("start",3) + rest + marked("stop",3)])
        var plan = try PerformanceCompiler.compile(p)
        XCTAssertEqual(plan.trails.count, 2)
        XCTAssertTrue(plan.trails.contains { $0.fromID.hasSuffix("n1") && $0.toID.hasSuffix("n2") })
        XCTAssertTrue(plan.trails.contains { $0.fromID.hasSuffix("n3") && $0.toID.hasSuffix("n4") })
        p.settings.visual.noteOverrides = [NoteVisualOverride(noteId: "P1-m1-n1", trail: "off")]
        plan = try PerformanceCompiler.compile(p)
        XCTAssertEqual(plan.trails.count, 1)
        XCTAssertTrue(plan.trails[0].fromID.hasSuffix("n3"))
    }

    func testUnknownOrnamentsArePreservedAndBlockIncompletePlayback() throws {
        let marked = note.replacingOccurrences(of: "</note>", with: "<notations><ornaments><inverted-mordent/></ornaments></notations></note>")
        let p = try project([marked])
        XCTAssertTrue(String(decoding: p.score.originalXML, as: UTF8.self).contains("inverted-mordent"))
        XCTAssertFalse(p.score.canPerform)
        XCTAssertThrowsError(try PerformanceCompiler.compile(p))
        XCTAssertThrowsError(try project([note.replacingOccurrences(of: "</step>", with: "</step><alter>bad</alter>")]))
    }

    func testUnknownInstrumentRequiresAnExplicitAssignment() throws {
        var p = try project([note], declaration: "")
        XCTAssertThrowsError(try PerformanceCompiler.compile(p))
        p.settings.partInstruments["P1"] = "violin"
        XCTAssertEqual(try PerformanceCompiler.compile(p).notes.first?.instrument.id, "violin")
        let invalidReference = note.replacingOccurrences(of: "<voice>", with: "<instrument id='missing'/><voice>")
        XCTAssertThrowsError(try PerformanceCompiler.compile(project([invalidReference])))
    }
}
