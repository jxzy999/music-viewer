import Foundation

public enum PerformanceCompiler {
    public static func compile(_ project: ProjectFile) throws -> PerformancePlan {
        try ProjectFile.validate(project.settings, score: project.score)
        guard project.score.canPerform else { throw ScoreError.unsupported(project.score.diagnostics.filter { $0.severity == .blocking }.map(\.message).joined(separator: "\n")) }
        guard let reference = project.score.parts.first(where: { $0.id == project.settings.scoreAxis.referencePartId }) else { throw ScoreError.invalid("参考声部不存在。") }
        var structure = reference.measures
        for part in project.score.parts {
            for measure in part.measures {
                let i = measure.index
                structure[i].repeatStart = structure[i].repeatStart || measure.repeatStart
                if let count = measure.repeatCount {
                    guard structure[i].repeatCount == nil || structure[i].repeatCount == count else { throw ScoreError.invalid("各声部反复次数不一致。") }
                    structure[i].repeatCount = count
                }
                if !measure.endings.isEmpty {
                    guard structure[i].endings.isEmpty || structure[i].endings == measure.endings else { throw ScoreError.invalid("各声部的结尾编号不一致。") }
                    structure[i].endings = measure.endings
                }
            }
        }
        let visits = try expand(structure)
        let anchorCount = visits.reduce(0) { total, visit in total + project.score.parts.reduce(0) { $0 + $1.measures[visit.index].notes.count } }
        guard anchorCount <= 500_000 else { throw ScoreError.invalid("反复展开后的音符事件超过 500000 个。") }
        let tempo = try tempoMap(project, reference: reference, visits: visits)
        var notes: [PlaybackNote] = []
        var anchors: [NoteAnchorEvent] = []
        var controls: [PlaybackControl] = []
        var voiceVolumes: [String: [String: Double]] = [:]
        for item in project.settings.performance.voiceVolumes ?? [] { voiceVolumes[item.partId, default: [:]][item.voiceId] = item.volume }
        var pending: [String: (index: Int, lastAnchor: String, shift: Double)] = [:]
        var tiePairs: [(String, String)] = []
        var oldEpoch = -1

        for visit in visits {
            if visit.epoch != oldEpoch {
                guard pending.isEmpty else { throw ScoreError.unsupported("延音跨越反复或跳转边界，配对尚未验证。") }
                oldEpoch = visit.epoch
            }
            for part in project.score.parts {
                let measure = part.measures[visit.index]
                for control in measure.controls {
                    controls.append(PlaybackControl(partID: part.id, staff: control.staff, time: tempo.seconds(at: visit.startBeat + control.offset.value), pedalDown: control.pedalDown))
                }
                for note in measure.notes {
                    let id = "\(visit.serial):\(note.id)"
                    let nominalOn = tempo.seconds(at: visit.startBeat + note.offset.value)
                    let nominalEnd = tempo.seconds(at: visit.startBeat + note.offset.value + note.duration.value)
                    let seedKey = "\(visit.serial)|\(part.id)|\(note.voice)|\(note.offset.n)/\(note.offset.d)"
                    let humanize = project.settings.performance.humanize
                    let jitter = max(-nominalOn, (random(seedKey, seed: humanize.seed) * 2 - 1) * min(humanize.timingJitterMS / 1000, (nominalEnd - nominalOn) * 0.1))
                    var on = nominalOn + jitter; var end = nominalEnd + jitter
                    var soundID: String?
                    if let pitch = note.midiPitch {
                        let key = "\(part.id)|\(note.voice)|\(pitch)"
                        if note.tieStop, let p = pending[key], abs(notes[p.index].end - p.shift - nominalOn) < 0.0001 {
                            on = nominalOn + p.shift; end = nominalEnd + p.shift
                            notes[p.index].sourceIDs.append(note.id)
                            notes[p.index].end = end
                            soundID = notes[p.index].id
                            tiePairs.append((p.lastAnchor, id))
                            pending.removeValue(forKey: key)
                            if note.tieStart { pending[key] = (p.index, id, p.shift) }
                        } else {
                            if note.tieStop { throw ScoreError.invalid("\(note.id) 的延音结束没有连续的同音起点。") }
                            let instrument = try instrument(for: note, part: part, project: project, reference: reference)
                            let gate = note.staccato && !note.tieStart ? on + (end - on) * 0.5 : end
                            let velocityShift = Int(((random(seedKey + "v", seed: humanize.seed) * 2 - 1) * Double(humanize.velocityJitter)).rounded())
                            let velocity = max(1, min(127, note.velocity + (note.accented ? 10 : 0) + velocityShift))
                            let instance = "\(part.id)|\(note.voice)|\(note.staff)|\(instrument.id)"
                            notes.append(PlaybackNote(id: id, sourceIDs: [note.id], partID: part.id, voice: note.voice, staff: note.staff, pitch: pitch, velocity: velocity, volume: voiceVolumes[part.id]?[note.voice] ?? 1, instrument: instrument, instanceID: instance, start: on, end: gate))
                            soundID = id
                            if note.tieStart {
                                guard pending[key] == nil else { throw ScoreError.unsupported("同一声部存在重叠的同音延音，配对不明确。") }
                                pending[key] = (notes.count - 1, id, jitter)
                            }
                        }
                    }
                    anchors.append(NoteAnchorEvent(id: id, sourceID: note.id, note: note, epoch: visit.epoch, visit: visit.serial, start: on, end: end, soundID: soundID))
                }
            }
        }
        guard pending.isEmpty else { throw ScoreError.invalid("曲谱末尾存在尚未结束的延音链。") }
        guard notes.count <= 500_000 else { throw ScoreError.invalid("展开后的演奏音符过多。") }
        // Same-pitch overlapping notes must not share a sampler's note-off identity.
        var laneEnds: [String: [Double]] = [:]
        for i in notes.indices.sorted(by: { notes[$0].start < notes[$1].start }) {
            let key = notes[i].instanceID + "|\(notes[i].pitch)"
            var ends = laneEnds[key] ?? []
            let lane: Int
            if let free = ends.firstIndex(where: { $0 <= notes[i].start + 1e-9 }) { lane = free; ends[free] = notes[i].end }
            else { lane = ends.count; ends.append(notes[i].end) }
            laneEnds[key] = ends
            notes[i].instanceID += "|lane\(lane)"
        }
        let duration = max(tempo.seconds(at: (visits.last?.startBeat ?? 0) + (visits.last?.lengthBeat ?? 0)), notes.map(\.end).max() ?? 0)
        guard duration.isFinite, duration > 0, duration <= 14_400 else { throw ScoreError.unsupported("首版单段演奏需要在 4 小时以内，请拆分曲谱或检查速度。") }
        let trails = makeTrails(anchors: anchors, ties: tiePairs, sounds: notes, settings: project.settings)
        let muted = Set(project.settings.performance.mutedPartIds ?? [])
        let solo = Set(project.settings.performance.soloPartIds ?? [])
        let sounding = notes.filter { !muted.contains($0.partID) && (solo.isEmpty || solo.contains($0.partID)) }
        return PerformancePlan(notes: sounding.sorted { $0.start < $1.start }, anchors: anchors, controls: controls, trails: trails, visits: visits, tempo: tempo, duration: duration)
    }

    private static func expand(_ measures: [ScoreMeasure]) throws -> [PerformanceVisit] {
        var starts: [Int] = []
        var repeats: [Int: (start: Int, count: Int)] = [:]
        for measure in measures {
            if measure.repeatStart { starts.append(measure.index) }
            if let count = measure.repeatCount { repeats[measure.index] = (starts.popLast() ?? 0, count) }
        }
        guard starts.isEmpty else { throw ScoreError.invalid("反复开始标记没有对应的结束标记。") }
        var passes: [Int: Int] = [:]
        var index = 0; var beat = 0.0; var epoch = 0; var previous = -1; var steps = 0; var lastPass = 1
        var visits: [PerformanceVisit] = []
        while index < measures.count {
            steps += 1
            guard steps <= 10_000 else { throw ScoreError.invalid("反复展开超过安全上限。") }
            let m = measures[index]
            let enclosing = repeats.filter { $0.value.start <= index && index <= $0.key }.min { ($0.key - $0.value.start) < ($1.key - $1.value.start) }
            let pass = enclosing.map { passes[$0.key] ?? 1 } ?? lastPass
            if m.endings.isEmpty || m.endings.contains(pass) {
                if previous >= 0, index != previous + 1 { epoch += 1 }
                visits.append(PerformanceVisit(index: index, serial: visits.count, epoch: epoch, startBeat: beat, lengthBeat: m.length.value))
                beat += m.length.value; previous = index
            }
            if let r = repeats[index] {
                let current = passes[index] ?? 1
                if current < r.count {
                    passes[index] = current + 1
                    for key in repeats.keys where key < index && key >= r.start { passes.removeValue(forKey: key) }
                    index = r.start; continue
                }
                lastPass = current
            }
            index += 1
        }
        return visits
    }

    private static func position(_ p: ScorePosition, reference: ScorePart) throws -> Double {
        guard let m = reference.measures.first(where: { $0.id == p.measureId }), p.beat >= .zero, p.beat <= m.length else { throw ScoreError.invalid("配器或速度范围中的小节位置不合法。") }
        return m.start.value + p.beat.value
    }

    private static func tempoMap(_ project: ProjectFile, reference: ScorePart, visits: [PerformanceVisit]) throws -> TempoMap {
        var written: [Double: TempoSegment] = [:]
        for part in project.score.parts {
            for measure in part.measures {
                for tempo in measure.tempos {
                    guard tempo.offset >= .zero, tempo.offset <= measure.length, tempo.qpm > 0, tempo.qpm <= 1000, tempo.qpm.isFinite else { throw ScoreError.invalid("速度标记超出小节或速度范围。") }
                    let beat = measure.start.value + tempo.offset.value
                    if let old = written[beat], abs(old.qpm - tempo.qpm) > 1e-8 { throw ScoreError.invalid("同一位置的声部速度冲突。") }
                    written[beat] = TempoSegment(beat: beat, qpm: tempo.qpm, linearToNext: false)
                }
            }
        }
        if written[0] == nil { written[0] = TempoSegment(beat: 0, qpm: project.settings.performance.defaultTempoQPM, linearToNext: false) }
        for override in project.settings.performance.tempoOverrides ?? [] {
            let beat = try position(override.position, reference: reference)
            written[beat] = TempoSegment(beat: beat, qpm: override.qpm, linearToNext: override.interpolation == "linearQPM")
        }
        let source = written.values.sorted { $0.beat < $1.beat }
        func value(at beat: Double) -> (qpm: Double, linear: Bool) {
            let i = max(0, source.lastIndex(where: { $0.beat <= beat + 1e-10 }) ?? 0)
            let point = source[i]
            if point.linearToNext, i + 1 < source.count {
                let next = source[i + 1]
                let u = min(1, max(0, (beat - point.beat) / (next.beat - point.beat)))
                return (point.qpm + (next.qpm - point.qpm) * u, true)
            }
            return (point.qpm, false)
        }
        var expanded: [TempoSegment] = []
        let scale = project.settings.performance.tempoScale
        for visit in visits {
            let m = reference.measures[visit.index]
            let start = m.start.value; let end = start + m.length.value
            let cuts = [start] + source.map(\.beat).filter { $0 > start && $0 < end }
            for (i, beat) in cuts.enumerated() {
                let a = value(at: beat); let next = i + 1 < cuts.count ? cuts[i + 1] : end
                let b = value(at: next)
                expanded.append(TempoSegment(beat: visit.startBeat + beat - start, qpm: a.qpm * scale, linearToNext: a.linear, endQPM: a.linear ? b.qpm * scale : nil))
            }
        }
        if let last = visits.last { expanded.append(TempoSegment(beat: last.startBeat + last.lengthBeat, qpm: expanded.last?.qpm ?? 96, linearToNext: false)) }
        var map = TempoMap(points: expanded)
        var holds: [Double: Double] = [:]
        for visit in visits {
            for part in project.score.parts {
                for note in part.measures[visit.index].notes where note.fermata {
                    let start = visit.startBeat + note.offset.value; let end = start + note.duration.value
                    let extra = (map.seconds(at: end) - map.seconds(at: start)) * (project.settings.performance.fermataMultiplier - 1)
                    holds[end] = max(holds[end] ?? 0, extra)
                }
            }
        }
        map.holds = holds.map { TempoHold(beat: $0.key, seconds: $0.value) }.sorted { $0.beat < $1.beat }
        return map
    }

    private static func random(_ text: String, seed: UInt32) -> Double {
        var hash = UInt64(seed) ^ 14695981039346656037
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Double(hash >> 11) / Double(UInt64(1) << 53)
    }

    private static func instrument(for note: ScoreNote, part: ScorePart, project: ProjectFile, reference: ScorePart) throws -> Instrument {
        let sourceBeat = part.measures[note.measureIndex].start.value + note.offset.value
        var candidates: [InstrumentRoute] = []
        for route in project.settings.routes where route.selector.matches(note) {
            let from = try position(route.range.from, reference: reference)
            let to = try position(route.range.to, reference: reference)
            guard from < to else { throw ScoreError.invalid("段落配器的起点必须早于终点。") }
            if sourceBeat >= from, sourceBeat < to { candidates.append(route) }
        }
        let sorted = candidates.sorted { $0.priority > $1.priority }
        if sorted.count > 1, sorted[0].priority == sorted[1].priority { throw ScoreError.invalid("同优先级段落配器重叠：\(sorted[0].id)") }
        if let id = sorted.first?.instrumentId ?? project.settings.partInstruments[part.id] {
            guard let i = project.settings.instruments.first(where: { $0.id == id }) else { throw ScoreError.invalid("配器音源不存在：\(id)") }
            return i
        }
        let source: ScoreInstrument?
        if let id = note.instrumentID {
            guard let declared = part.instruments.first(where: { $0.id == id }) else { throw ScoreError.invalid("\(note.id) 引用的乐器不存在。请为该声部指定乐器。") }
            source = declared
        } else { source = part.instruments.first }
        guard let source, let program = source.program else { throw ScoreError.unsupported("\(part.name) 的声音尚未映射。请在声部选项中选择钢琴、小提琴或已有音源，再准备演奏。") }
        if let known = project.settings.instruments.first(where: { $0.program == program && $0.bank.kind == "builtin" }) { return known }
        var gm = Instrument.piano
        gm.id = "gm-\(program)"; gm.displayName = source.name; gm.program = program; gm.bank.key = "gm-v1"
        return gm
    }

    private static func makeTrails(anchors: [NoteAnchorEvent], ties: [(String, String)], sounds: [PlaybackNote], settings: ProjectSettings) -> [TrailConnection] {
        guard settings.visual.effects.trailMode != "off" else { return [] }
        let map = Dictionary(uniqueKeysWithValues: anchors.map { ($0.id, $0) })
        let overrides = Dictionary((settings.visual.noteOverrides ?? []).map { ($0.noteId, $0.trail) }, uniquingKeysWith: { _, new in new })
        var links: [TrailConnection] = []
        let tieSet = Set(ties.map { $0.0 + ">" + $0.1 })
        let soundEnds = Dictionary(uniqueKeysWithValues: sounds.map { ($0.id, $0.end) })
        for (fromID, toID) in ties {
            guard let from = map[fromID], let to = map[toID], overrides[from.sourceID] != "off" else { continue }
            links.append(TrailConnection(id: "tie:\(fromID)>\(toID)", kind: .tie, fromID: fromID, toID: toID, start: max(from.start, to.start - 0.8), arrival: to.start, holdUntil: from.soundID.flatMap { soundEnds[$0] } ?? to.end))
        }
        var groups: [String: [NoteAnchorEvent]] = [:]
        for anchor in anchors {
            for groupID in anchor.note.slurIDs { groups["\(anchor.epoch)|\(groupID)", default: []].append(anchor) }
        }
        for (groupID, members) in groups {
            let times = Dictionary(grouping: members, by: \.start).sorted { $0.key < $1.key }
            for i in times.indices.dropLast() {
                let a = times[i].value; let b = times[i + 1].value
                guard !a.contains(where: { $0.note.isRest }), !b.contains(where: { $0.note.isRest }) else { continue }
                let left = a.sorted { ($0.note.midiPitch ?? 0) < ($1.note.midiPitch ?? 0) }
                let right = b.sorted { ($0.note.midiPitch ?? 0) < ($1.note.midiPitch ?? 0) }
                for (from, to) in zip(left, right) {
                    guard overrides[from.sourceID] != "off", !tieSet.contains(from.id + ">" + to.id), to.start > from.start else { continue }
                    links.append(TrailConnection(id: "\(groupID):\(from.id)>\(to.id)", kind: .slur, fromID: from.id, toID: to.id, start: max(from.start, to.start - 0.65), arrival: to.start, holdUntil: to.start))
                }
            }
        }
        return links.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}
