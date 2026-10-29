import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses musical time independently of the engraving engine. The original bytes stay untouched.
public enum MusicXMLReader {
    public static func read(_ data: Data) throws -> ScoreDocument {
        guard data.count <= 100 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw ScoreError.invalid("曲谱不是有效的 UTF-8 文件，或超过 100 MB。")
        }
        guard text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw ScoreError.invalid("曲谱不允许声明 XML 实体。")
        }
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw ScoreError.invalid(builder.failure ?? parser.parserError?.localizedDescription ?? "XML 结构不完整。")
        }
        guard root.name == "score-partwise" else {
            throw ScoreError.unsupported("目前需要 score-partwise 格式的 MusicXML。请在制谱软件中重新导出。")
        }
        return try ScoreReader(root: root, original: data).read()
    }
}

private final class XMLNode {
    let name: String
    var attributes: [String: String]
    var children: [XMLNode] = []
    var text = ""
    init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }
    func value(_ name: String) -> String? { child(name)?.content }
    var content: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    func descendants(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
    var xml: String {
        let attrs = attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(Self.escape($0.value))\"" }.joined()
        return "<\(name)\(attrs)>\(Self.escape(text))\(children.map(\.xml).joined())</\(name)>"
    }
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var stack: [XMLNode] = []
    var count = 0
    var failure: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard count <= 500_000, stack.count < 96 else { failure = "曲谱节点过多或嵌套过深。"; parser.abortParsing(); return }
        let node = XMLNode(elementName, attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}

private final class ScoreReader {
    let root: XMLNode
    let original: Data
    var diagnostics: [ScoreDiagnostic] = []
    var ids: Set<String> = []
    var groups: [SlurGroup] = []
    init(root: XMLNode, original: Data) { self.root = root; self.original = original }

    func read() throws -> ScoreDocument {
        let declarations = root.child("part-list")?.all("score-part") ?? []
        var parts: [ScorePart] = []
        for (partIndex, node) in root.all("part").enumerated() {
            let partID = node.attributes["id"] ?? "P\(partIndex + 1)"
            guard !parts.contains(where: { $0.id == partID }) else { throw ScoreError.invalid("重复的 part ID：\(partID)") }
            let declaration = declarations.first { $0.attributes["id"] == partID }
            let instruments = try (declaration?.all("score-instrument") ?? []).map { instrument in
                let id = instrument.attributes["id"] ?? "\(partID)-instrument"
                let midi = declaration?.all("midi-instrument").first { $0.attributes["id"] == id }
                let program: Int?
                if let text = midi?.value("midi-program") {
                    guard let value = Int(text), (1...128).contains(value) else { throw ScoreError.invalid("曲谱 MIDI program 需要在 1 至 128 之间。") }
                    program = value - 1
                } else { program = nil }
                return ScoreInstrument(id: id, name: instrument.value("instrument-name") ?? "乐器", program: program)
            }
            if instruments.isEmpty || instruments.contains(where: { $0.program == nil }) {
                diagnostics.append(ScoreDiagnostic("\(declaration?.value("part-name") ?? partID) 的原谱未指定完整的 GM 音源；该声部需要使用工程中的配器设置，未映射的声音不会自动替换。"))
            }
            let measures = try readPart(node, id: partID)
            parts.append(ScorePart(id: partID, name: declaration?.value("part-name") ?? partID, instruments: instruments, measures: measures))
        }
        guard !parts.isEmpty, parts.contains(where: { $0.measures.contains { !$0.notes.isEmpty } }) else { throw ScoreError.invalid("曲谱没有可读取的音符。") }
        let reference = parts[0].measures
        for part in parts.dropFirst() {
            if part.measures.count != reference.count || zip(part.measures, reference).contains(where: { $0.length != $1.length }) {
                diagnostics.append(ScoreDiagnostic("\(part.name) 与参考声部的小节长度不一致，需要先修正或规范化曲谱。", blocking: true))
            }
        }
        let ornamentNames = Set(root.descendants("ornaments").flatMap { $0.children.map(\.name) }).subtracting(["accidental-mark"])
        let unsupported = Set(["grace", "cue", "trill-mark", "tremolo", "turn", "mordent", "glissando", "slide", "swing", "arpeggiate", "non-arpeggiate", "scordatura", "senza-misura"]).union(ornamentNames)
        for tag in unsupported.sorted() where !root.descendants(tag).isEmpty {
            diagnostics.append(ScoreDiagnostic("此曲谱含 \(tag)，该演奏解释尚未验证；已保留原谱，暂不允许导出不完整的演奏。", blocking: true))
        }
        for sound in root.descendants("sound") where ["dacapo", "dalsegno", "tocoda", "fine"].contains(where: { sound.attributes[$0] != nil }) {
            diagnostics.append(ScoreDiagnostic("曲谱含 D.C.／D.S.／Coda 跳转，需要完成跳转语料验证后演奏。", blocking: true))
        }
        let title = root.child("work")?.value("work-title") ?? root.value("movement-title") ?? "未命名曲谱"
        let composer = root.child("identification")?.all("creator").first { $0.attributes["type"] == "composer" }?.content ?? ""
        return ScoreDocument(title: title, composer: composer, originalXML: original, normalizedXML: root.xml, parts: parts, slurs: groups, diagnostics: diagnostics)
    }

    private func readPart(_ node: XMLNode, id partID: String) throws -> [ScoreMeasure] {
        var measures: [ScoreMeasure] = []
        var divisions: Int64 = 1
        var nominal = try Beat(4)
        var transpose = 0
        var start = Beat.zero
        var velocity = 76
        var dynamics: [(position: Beat, staff: Int?, voice: String?, value: Int)] = []
        var noteDynamics: [String: Int] = [:]
        var activeSlurs: [String: (id: String, start: Beat)] = [:]
        var completedSlurs: [(id: String, voice: String, from: Beat, to: Beat)] = []
        var activeEndings = Set<Int>()

        for (measureIndex, m) in node.all("measure").enumerated() {
            let measureID = try stableID(m, fallback: "\(partID)-m\(measureIndex + 1)")
            var cursor = Beat.zero
            var previous = Beat.zero
            var length = Beat.zero
            var notes: [ScoreNote] = []
            var tempos: [ScoreTempo] = []
            var controls: [ScoreControl] = []
            var repeatStart = false
            var repeatCount: Int?
            var endings = activeEndings
            func sound(_ sound: XMLNode, base: Beat, staff: Int?, voice: String?) throws {
                guard let ticks = Int64(sound.value("offset") ?? "0") else { throw ScoreError.invalid("声音标记的偏移无效。") }
                let local = try base.adding(Beat(ticks, divisions))
                if let text = sound.attributes["tempo"] {
                    guard let q = Double(text), q.isFinite, q > 0, q <= 1000 else { throw ScoreError.invalid("曲谱速度无效。") }
                    tempos.append(ScoreTempo(offset: local, qpm: q))
                }
                if let text = sound.attributes["dynamics"] {
                    guard let d = Double(text), d.isFinite, (0...200).contains(d) else { throw ScoreError.invalid("曲谱力度无效。") }
                    velocity = min(127, max(1, Int((d * 0.9).rounded())))
                    dynamics.append((try start.adding(local), staff, voice, velocity))
                }
                if let pedal = sound.attributes["damper-pedal"] {
                    if pedal == "yes" || pedal == "100" { controls.append(ScoreControl(offset: local, staff: staff, pedalDown: true)) }
                    else if pedal == "no" || pedal == "0" { controls.append(ScoreControl(offset: local, staff: staff, pedalDown: false)) }
                    else { diagnostics.append(ScoreDiagnostic("半踏板尚未验证，已保留原谱并阻止不完整的演奏。", blocking: true)) }
                }
                if sound.attributes["forward-repeat"] == "yes" { repeatStart = true }
                if sound.attributes["time-only"] != nil || sound.attributes["pizzicato"] == "yes" || sound.attributes["soft-pedal"] == "yes" || sound.attributes["sostenuto-pedal"] == "yes" || !sound.all("midi-instrument").isEmpty || !sound.all("instrument-change").isEmpty {
                    diagnostics.append(ScoreDiagnostic("曲谱含尚未验证的声音切换、条件演奏或特殊奏法，已保留并阻止不完整的演奏。", blocking: true))
                }
            }
            for child in m.children {
                switch child.name {
                case "attributes":
                    if let s = child.value("divisions") { divisions = try positiveInteger(s, "divisions") }
                    if let time = child.child("time"), let beats = time.value("beats"), let unit = time.value("beat-type") {
                        var count: Int64 = 0
                        for value in beats.split(separator: "+", omittingEmptySubsequences: false) { count += try positiveInteger(String(value), "拍号") }
                        guard count <= 1_000_000 else { throw ScoreError.invalid("拍号过大。") }
                        nominal = try Beat(count * 4, positiveInteger(unit, "拍号"))
                    }
                    if let t = child.child("transpose") {
                        guard let chromatic = Int(t.value("chromatic") ?? "0"), (-127...127).contains(chromatic), let octave = Int(t.value("octave-change") ?? "0"), (-10...10).contains(octave) else { throw ScoreError.invalid("乐器移调超出范围。") }
                        transpose = chromatic + 12 * octave
                    }
                case "backup", "forward":
                    let delta = try Beat(positiveInteger(child.value("duration") ?? "0", "游标时值"), divisions)
                    cursor = try child.name == "backup" ? cursor.subtracting(delta) : cursor.adding(delta)
                    guard cursor >= .zero else { throw ScoreError.invalid("\(partID) 第 \(measureIndex + 1) 小节的 backup 越过小节起点。") }
                    length = max(length, cursor)
                case "direction":
                    guard let ticks = Int64(child.value("offset") ?? "0") else { throw ScoreError.invalid("方向标记的偏移无效。") }
                    let offset = try Beat(ticks, divisions)
                    let position = try cursor.adding(offset)
                    let staff = child.value("staff").flatMap(Int.init); let voice = child.value("voice")
                    if let element = child.child("sound") { try sound(element, base: element.child("offset") == nil ? position : cursor, staff: staff, voice: voice) }
                    for type in child.all("direction-type") {
                        // MusicXML pitch already contains the performed octave;
                        // octave-shift changes notation placement, not playback.
                        // Marks can be out of order in polyphonic XML, so their
                        // document order is not used to infer an audio shift.
                        for shift in type.all("octave-shift") {
                            guard let kind = shift.attributes["type"], ["up", "down", "stop", "continue"].contains(kind),
                                  let size = Int(shift.attributes["size"] ?? "8"), [8, 15, 22].contains(size),
                                  let number = Int(shift.attributes["number"] ?? "1"), (1...16).contains(number),
                                  let staff = Int(child.value("staff") ?? "1"), (1...32).contains(staff) else {
                                diagnostics.append(ScoreDiagnostic("八度线的显示类型、尺寸或编号无效或尚未支持，已保留原谱并阻止演奏。", blocking: true))
                                continue
                            }
                        }
                        if child.child("sound")?.attributes["dynamics"] == nil, let dynamic = type.child("dynamics")?.children.first?.name {
                            velocity = ["ppp": 20, "pp": 32, "p": 48, "mp": 60, "mf": 76, "f": 92, "ff": 108, "fff": 120][dynamic] ?? velocity
                            dynamics.append((try start.adding(position), staff, voice, velocity))
                        }
                        if child.child("sound")?.attributes["tempo"] == nil, let metronome = type.child("metronome"), let q = metronome.value("per-minute").flatMap(Double.init), q > 0, q <= 1000, q.isFinite {
                            let units = ["whole": 4.0, "half": 2, "quarter": 1, "eighth": 0.5, "16th": 0.25]
                            let dots = metronome.all("beat-unit-dot").count
                            let multiplier = (units[metronome.value("beat-unit") ?? "quarter"] ?? 1) * (2 - pow(0.5, Double(dots)))
                            tempos.append(ScoreTempo(offset: position, qpm: q * multiplier))
                        }
                        if let pedal = type.child("pedal"), let kind = pedal.attributes["type"] {
                            let staff = child.value("staff").flatMap(Int.init)
                            if kind == "change" { controls.append(ScoreControl(offset: position, staff: staff, pedalDown: false)) }
                            controls.append(ScoreControl(offset: position, staff: staff, pedalDown: kind == "start" || kind == "resume" || kind == "change"))
                        }
                    }
                case "sound":
                    try sound(child, base: cursor, staff: nil, voice: nil)
                case "note":
                    let noteID = try stableID(child, fallback: "\(partID)-m\(measureIndex + 1)-n\(notes.count + 1)")
                    if let text = child.attributes["dynamics"] {
                        guard let value = Double(text), value.isFinite, (0...200).contains(value) else { throw ScoreError.invalid("音符力度无效。") }
                        noteDynamics[noteID] = max(1, min(127, Int((value * 0.9).rounded())))
                    }
                    let chord = child.child("chord") != nil
                    let offset = chord ? previous : cursor
                    let ticks: Int64
                    if child.child("grace") != nil { ticks = 0 }
                    else { ticks = try positiveInteger(child.value("duration") ?? "0", "音符时值") }
                    let duration = try Beat(ticks, divisions)
                    guard duration >= .zero else { throw ScoreError.invalid("负数音符时值。") }
                    let voice = child.value("voice") ?? "1"
                    let absolute = try start.adding(offset)
                    var pitch: Int?
                    if let p = child.child("pitch") {
                        guard let step = p.value("step"), let semi = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][step], let octave = p.value("octave").flatMap(Int.init) else { throw ScoreError.invalid("\(noteID) 的音高不完整。") }
                        guard let alteration = Double(p.value("alter") ?? "0"), alteration.isFinite, abs(alteration) <= 24, (-1...9).contains(octave) else { throw ScoreError.invalid("音高超出范围或升降音值无效。") }
                        if alteration.rounded() != alteration { diagnostics.append(ScoreDiagnostic("\(noteID) 含微分音，当前采样播放尚不支持。", blocking: true)) }
                        let actual = (octave + 1) * 12 + semi + Int(alteration.rounded()) + transpose
                        guard (0...127).contains(actual) else { throw ScoreError.invalid("\(noteID) 的实际音高超出 MIDI 范围。") }
                        pitch = actual
                    } else if child.child("unpitched") != nil {
                        diagnostics.append(ScoreDiagnostic("\(noteID) 的无固定音高打击乐尚未映射。", blocking: true))
                    } else if child.child("rest") == nil { throw ScoreError.invalid("\(noteID) 缺少音高或休止标记。") }
                    let notations = child.child("notations")
                    for mark in notations?.all("slur") ?? [] {
                        let key = voice + ":" + (mark.attributes["number"] ?? "1")
                        if mark.attributes["type"] == "start" {
                            if activeSlurs[key] != nil { diagnostics.append(ScoreDiagnostic("\(noteID) 的连奏组重复开始，相关轨迹将忽略。")) }
                            activeSlurs[key] = ("slur-\(noteID)-\(key)", absolute)
                        }
                        if mark.attributes["type"] == "stop" {
                            if let active = activeSlurs.removeValue(forKey: key) { completedSlurs.append((active.id, voice, active.start, absolute)) }
                            else { diagnostics.append(ScoreDiagnostic("\(noteID) 的连奏结束缺少起点。")) }
                        }
                    }
                    let tieTypes = Set(child.all("tie").compactMap { $0.attributes["type"] })
                    guard let staff = Int(child.value("staff") ?? "1"), (1...32).contains(staff) else { throw ScoreError.invalid("谱表编号无效。") }
                    notes.append(ScoreNote(id: noteID, partID: partID, measureIndex: measureIndex, voice: voice, staff: staff, offset: offset, duration: duration, midiPitch: pitch, instrumentID: child.child("instrument")?.attributes["id"], velocity: velocity, staccato: notations?.child("articulations")?.child("staccato") != nil, accented: notations?.child("articulations")?.child("accent") != nil, fermata: notations?.child("fermata") != nil, tieStart: tieTypes.contains("start"), tieStop: tieTypes.contains("stop"), slurIDs: [], chord: chord))
                    let end = try offset.adding(duration)
                    length = max(length, end)
                    if !chord { previous = cursor; cursor = end }
                case "barline":
                    if let r = child.child("repeat") {
                        if r.attributes["direction"] == "forward" { repeatStart = true }
                        else {
                            guard r.attributes["direction"] == "backward", let count = Int(r.attributes["times"] ?? "2"), (2...16).contains(count) else { throw ScoreError.invalid("反复方向或次数无效；支持 2 至 16 次。") }
                            repeatCount = count
                        }
                    }
                    if let e = child.child("ending") {
                        let values = Set((e.attributes["number"] ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
                        if e.attributes["type"] == "start" { activeEndings = values; endings = values }
                        else { endings.formUnion(activeEndings); activeEndings = [] }
                    }
                default: break
                }
            }
            if m.attributes["implicit"] != "yes" { length = max(length, nominal) }
            if length == .zero { length = nominal }
            measures.append(ScoreMeasure(id: measureID, number: m.attributes["number"] ?? String(measureIndex + 1), index: measureIndex, start: start, length: length, notes: notes, tempos: tempos, controls: controls, repeatStart: repeatStart, repeatCount: repeatCount, endings: endings))
            start = try start.adding(length)
        }
        dynamics.sort { a, b in
            if a.position != b.position { return a.position < b.position }
            return (a.staff == nil ? 0 : 1) + (a.voice == nil ? 0 : 1) < (b.staff == nil ? 0 : 1) + (b.voice == nil ? 0 : 1)
        }
        for mi in measures.indices {
            for ni in measures[mi].notes.indices {
                let note = measures[mi].notes[ni]
                let absolute = try measures[mi].start.adding(note.offset)
                measures[mi].notes[ni].velocity = noteDynamics[note.id] ?? dynamics.last { $0.position <= absolute && ($0.staff == nil || $0.staff == note.staff) && ($0.voice == nil || $0.voice == note.voice) }?.value ?? 76
            }
        }
        for (_, active) in activeSlurs { diagnostics.append(ScoreDiagnostic("连奏组 \(active.id) 没有结束点，相关轨迹将忽略。")) }
        for group in completedSlurs {
            var noteIDs: [String] = []
            for mi in measures.indices {
                for ni in measures[mi].notes.indices where measures[mi].notes[ni].voice == group.voice {
                    let position = try measures[mi].start.adding(measures[mi].notes[ni].offset)
                    if position >= group.from, position <= group.to {
                        measures[mi].notes[ni].slurIDs.append(group.id)
                        noteIDs.append(measures[mi].notes[ni].id)
                    }
                }
            }
            groups.append(SlurGroup(id: group.id, noteIDs: noteIDs))
        }
        return measures
    }

    private func stableID(_ node: XMLNode, fallback: String) throws -> String {
        let id = node.attributes["id"] ?? fallback
        guard !id.isEmpty, id.count <= 256, ids.insert(id).inserted else { throw ScoreError.invalid("重复或无效的曲谱 ID：\(id)") }
        node.attributes["id"] = id
        return id
    }

    private func positiveInteger(_ text: String, _ name: String) throws -> Int64 {
        guard let value = Int64(text), value > 0, value <= 1_000_000_000 else { throw ScoreError.invalid("\(name) 超出范围。") }
        return value
    }
}
