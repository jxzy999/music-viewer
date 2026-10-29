import Foundation

public struct ProjectSettings: Codable, Sendable {
    public var version = "1.0.0"
    public var scoreAxis: ScoreAxis
    public var performance = PerformanceSettings()
    public var instruments = [Instrument.piano, Instrument.violin]
    public var partInstruments: [String: String] = [:]
    public var routes: [InstrumentRoute] = []
    public var layout = LayoutSettings()
    public var visual = VisualSettings()
    public var camera = CameraSettings()
    public var export = ExportSettings()

    public init(referencePartID: String) { scoreAxis = ScoreAxis(referencePartId: referencePartID) }
    public struct ScoreAxis: Codable, Sendable { public var referencePartId: String }

    public static func defaults(for score: ScoreDocument) -> Self {
        var settings = Self(referencePartID: score.parts.first?.id ?? "P1")
        settings.camera.focusPartIds = score.parts.map(\.id)
        let colors = ["#6EDBFFFF", "#F6BF73FF", "#BAA3FFFF", "#F397BAFF", "#89D9A4FF"]
        for part in score.parts {
            for voice in part.voices {
                settings.visual.voiceColors.append(VoiceColor(selector: NoteSelector(partId: part.id, voiceId: voice), color: colors[settings.visual.voiceColors.count % colors.count]))
            }
        }
        return settings
    }
}

public struct PerformanceSettings: Codable, Sendable {
    public var defaultTempoQPM = 96.0
    public var tempoScale = 1.0
    public var fermataMultiplier = 1.5
    public var humanize = HumanizeSettings()
    public var tempoOverrides: [TempoOverride]?
    public var mutedPartIds: [String]?
    public var soloPartIds: [String]?
    public var reverbWetDryMix: Double? = 12
}
public struct HumanizeSettings: Codable, Sendable {
    public var seed: UInt32 = 7
    public var timingJitterMS = 0.0
    public var velocityJitter = 0
}
public struct TempoOverride: Codable, Sendable {
    public var position: ScorePosition
    public var qpm: Double
    public var interpolation: String
}
public struct ScorePosition: Codable, Sendable {
    public var measureId: String
    public var beat: Beat
    public init(measureId: String, beat: Beat) { self.measureId = measureId; self.beat = beat }
}
public struct ScoreRange: Codable, Sendable {
    public var from: ScorePosition
    public var to: ScorePosition
    public init(from: ScorePosition, to: ScorePosition) { self.from = from; self.to = to }
}
public struct NoteSelector: Codable, Sendable {
    public var partId: String
    public var voiceId: String?
    public var staff: Int?
    public init(partId: String, voiceId: String? = nil, staff: Int? = nil) {
        self.partId = partId; self.voiceId = voiceId; self.staff = staff
    }
    public func matches(_ note: ScoreNote) -> Bool {
        partId == note.partID && (voiceId == nil || voiceId == note.voice) && (staff == nil || staff == note.staff)
    }
}
public struct InstrumentRoute: Identifiable, Codable, Sendable {
    public var id: String
    public var selector: NoteSelector
    public var range: ScoreRange
    public var instrumentId: String
    public var priority: Int
    public init(id: String = UUID().uuidString, selector: NoteSelector, range: ScoreRange, instrumentId: String, priority: Int = 100) {
        self.id = id; self.selector = selector; self.range = range; self.instrumentId = instrumentId; self.priority = priority
    }
}
public struct Instrument: Identifiable, Codable, Sendable {
    public var id: String
    public var displayName: String
    public var bank: Bank
    public var program: Int
    public var bankMSB: Int
    public var bankLSB: Int
    public var gainDB: Double
    public var pan: Double
    public struct Bank: Codable, Sendable {
        public var kind: String
        public var key: String?
        public var path: String?
        public var sha256: String?
        public var attribution: String?
        public var licensePath: String?
    }
    public static let piano = Instrument(id: "piano", displayName: "钢琴", bank: Bank(kind: "builtin", key: "piano-v1"), program: 0, bankMSB: 121, bankLSB: 0, gainDB: -6, pan: 0)
    public static let violin = Instrument(id: "violin", displayName: "小提琴", bank: Bank(kind: "builtin", key: "violin-v1"), program: 40, bankMSB: 121, bankLSB: 0, gainDB: -8, pan: 0)
}
public struct LayoutSettings: Codable, Sendable {
    public var paper = "a4"
    public var orientation = "portrait"
    public var staffScale = 1.0
    public var preserveSourceBreaks = true
}
public struct VisualSettings: Codable, Sendable {
    public var preset = "cinematic-paper"
    public var voiceColors: [VoiceColor] = []
    public var effects = EffectSettings()
    public var noteOverrides: [NoteVisualOverride]?
}
public struct VoiceColor: Codable, Sendable {
    public var selector: NoteSelector
    public var color: String
    public init(selector: NoteSelector, color: String) { self.selector = selector; self.color = color }
}
public struct EffectSettings: Codable, Sendable {
    public var trailMode = "auto"
    public var trailHistoryMS = 220.0
    public var maxTrailLanes = 4
    public var sustainMode = "pulse"
    public var repeatNoteMode = "pulse"
}
public struct NoteVisualOverride: Codable, Sendable {
    public var noteId: String
    public var trail: String
}
public struct CameraSettings: Codable, Sendable {
    public var preset = "cinematicFollow"
    public var focusPartIds: [String] = []
    public var lookAheadSeconds = 1.2
    public var motionIntensity = 0.35
}
public struct ExportSettings: Codable, Sendable {
    public var width = 1920
    public var height = 1080
    public var fps = FrameRate(n: 60, d: 1)
    public var container = "mp4"
    public var videoCodec = "h264"
    public var audioSampleRate = 48000
    public var audioChannels = 2
    public var tailSeconds = 2.0
    public var colorSpace = "rec709"
}
public struct FrameRate: Codable, Sendable {
    public var n: Int
    public var d: Int
    public var value: Double { Double(n) / Double(d) }
}
