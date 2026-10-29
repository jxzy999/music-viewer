import Foundation

public enum ScoreError: LocalizedError, Sendable {
    case invalid(String)
    case unsupported(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .unsupported(let s): s }
    }
}

public struct ScoreDiagnostic: Identifiable, Sendable {
    public enum Severity: String, Sendable { case warning, blocking }
    public let id: String
    public let severity: Severity
    public let message: String
    public init(_ message: String, blocking: Bool = false, id: String = UUID().uuidString) {
        self.id = id; self.severity = blocking ? .blocking : .warning; self.message = message
    }
}

public struct ScoreInstrument: Sendable {
    public let id: String
    public let name: String
    public let program: Int?
}

public struct ScorePart: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let instruments: [ScoreInstrument]
    public var measures: [ScoreMeasure]
    public var voices: [String] { Array(Set(measures.flatMap(\.notes).map(\.voice))).sorted() }
}

public struct ScoreMeasure: Identifiable, Sendable {
    public let id: String
    public let number: String
    public let index: Int
    public let start: Beat
    public let length: Beat
    public var notes: [ScoreNote]
    public let tempos: [ScoreTempo]
    public let controls: [ScoreControl]
    public var repeatStart: Bool
    public var repeatCount: Int?
    public var endings: Set<Int>
}

public struct ScoreNote: Identifiable, Sendable {
    public let id: String
    public let partID: String
    public let measureIndex: Int
    public let voice: String
    public let staff: Int
    public let offset: Beat
    public let duration: Beat
    public let midiPitch: Int?
    public let instrumentID: String?
    public var velocity: Int
    public let staccato: Bool
    public let accented: Bool
    public let fermata: Bool
    public let tieStart: Bool
    public let tieStop: Bool
    public var slurIDs: [String]
    public let chord: Bool
    public var isRest: Bool { midiPitch == nil }
}

public struct ScoreTempo: Sendable {
    public let offset: Beat
    public let qpm: Double
}

public struct ScoreControl: Sendable {
    public let offset: Beat
    public let staff: Int?
    public let pedalDown: Bool
}

public struct SlurGroup: Identifiable, Sendable {
    public let id: String
    public let noteIDs: [String]
}

public struct ScoreDocument: Sendable {
    public let title: String
    public let composer: String
    public let originalXML: Data
    public let normalizedXML: String
    public let parts: [ScorePart]
    public let slurs: [SlurGroup]
    public var diagnostics: [ScoreDiagnostic]
    public var noteCount: Int { parts.flatMap(\.measures).flatMap(\.notes).filter { !$0.isRest }.count }
    public var canPerform: Bool { !diagnostics.contains { $0.severity == .blocking } }
    public var notes: [ScoreNote] { parts.flatMap(\.measures).flatMap(\.notes) }
}
