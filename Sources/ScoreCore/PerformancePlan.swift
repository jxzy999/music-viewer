import Foundation

public struct PlaybackNote: Identifiable, Sendable {
    public let id: String
    public var sourceIDs: [String]
    public let partID: String
    public let voice: String
    public let staff: Int
    public let pitch: Int
    public let velocity: Int
    public let instrument: Instrument
    public var instanceID: String
    public let start: Double
    public var end: Double
}

public struct NoteAnchorEvent: Identifiable, Sendable {
    public let id: String
    public let sourceID: String
    public let note: ScoreNote
    public let epoch: Int
    public let visit: Int
    public let start: Double
    public let end: Double
    public let soundID: String?
}

public struct PerformanceVisit: Sendable {
    public let index: Int
    public let serial: Int
    public let epoch: Int
    public let startBeat: Double
    public let lengthBeat: Double
}

public struct TempoSegment: Sendable {
    public let beat: Double
    public let qpm: Double
    public let linearToNext: Bool
    public var endQPM: Double? = nil
}

public struct TempoMap: Sendable {
    public let points: [TempoSegment]
    public var holds: [TempoHold] = []
    public func seconds(at beat: Double) -> Double {
        var seconds = holds.filter { $0.beat <= beat + 1e-10 }.reduce(0) { $0 + $1.seconds }
        for (i, point) in points.enumerated() {
            guard beat > point.beat else { break }
            let next = i + 1 < points.count ? points[i + 1] : nil
            let to = min(beat, next?.beat ?? beat)
            let length = to - point.beat
            if let next, point.linearToNext, next.beat > point.beat {
                let slope = ((point.endQPM ?? next.qpm) - point.qpm) / (next.beat - point.beat)
                if abs(slope) > 1e-10 { seconds += 60 / slope * log((point.qpm + slope * length) / point.qpm) }
                else { seconds += 60 * length / point.qpm }
            } else { seconds += 60 * length / point.qpm }
        }
        return seconds
    }
}

public struct TempoHold: Sendable { public let beat: Double; public let seconds: Double }

public struct PlaybackControl: Sendable {
    public let partID: String
    public let staff: Int?
    public let time: Double
    public let pedalDown: Bool
}

public struct TrailConnection: Identifiable, Sendable {
    public enum Kind: String, Sendable { case slur, tie }
    public let id: String
    public let kind: Kind
    public let fromID: String
    public let toID: String
    public let start: Double
    public let arrival: Double
    public let holdUntil: Double
}

public struct PerformancePlan: Sendable {
    public let notes: [PlaybackNote]
    public let anchors: [NoteAnchorEvent]
    public let controls: [PlaybackControl]
    public let trails: [TrailConnection]
    public let visits: [PerformanceVisit]
    public let tempo: TempoMap
    public let duration: Double
}
