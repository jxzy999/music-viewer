import Foundation
import CryptoKit
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct ProjectFile: Sendable {
    public let id: UUID
    public var score: ScoreDocument
    public var settings: ProjectSettings
    public var sourceURL: URL?
    public let entries: [String: Data]
    public let notationPath: String
    public let settingsPath: String
    private let originalSettings: Data?
    private let originalManifest: Data?

    public static func load(_ url: URL) throws -> Self {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let ext = url.pathExtension.lowercased()
        if ext == "scorefilm" { return try loadArchive(bytes, sourceURL: url) }
        if ext == "mxl" {
            let entries = try ZIPArchive.read(bytes)
            guard let container = entries["META-INF/container.xml"] else { throw ScoreError.invalid("MXL 缺少 container.xml。") }
            guard container.count <= 1_048_576, let text = String(data: container, encoding: .utf8), text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw ScoreError.invalid("MXL 入口描述过大或包含实体声明。") }
            let reader = MXLRootReader()
            let parser = XMLParser(data: container); parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never; parser.delegate = reader
            guard parser.parse(), let path = reader.path, ZIPArchive.validPath(path), let xml = entries[path] else { throw ScoreError.invalid("MXL 乐谱入口不存在。") }
            guard entries["manifest.json"] == nil, entries["project.json"] == nil else { throw ScoreError.invalid("MXL 包含工程保留文件名，无法无损转换。") }
            let score = try MusicXMLReader.read(xml)
            return Self(id: UUID(), score: score, settings: .defaults(for: score), sourceURL: url, entries: entries, notationPath: path, settingsPath: "project.json", originalSettings: nil, originalManifest: nil)
        }
        guard ext == "xml" || ext == "musicxml" else { throw ScoreError.unsupported("请选择 MusicXML、MXL 或 ScoreFilm 文件。") }
        let score = try MusicXMLReader.read(bytes)
        return Self(id: UUID(), score: score, settings: .defaults(for: score), sourceURL: url, entries: ["score.musicxml": bytes], notationPath: "score.musicxml", settingsPath: "project.json", originalSettings: nil, originalManifest: nil)
    }

    public static func loadArchive(_ data: Data, sourceURL: URL? = nil) throws -> Self {
        let entries = try ZIPArchive.read(data)
        guard let manifestData = entries["manifest.json"], let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any], manifest["format"] as? String == "scorefilm", let version = manifest["version"] as? String, version.split(separator: ".").first == "1" else { throw ScoreError.unsupported("工程格式或主版本不受支持。") }
        guard let files = manifest["files"] as? [String: String], let notation = files["notation"], let settingsPath = files["settings"], notation != settingsPath, notation != "manifest.json", settingsPath != "manifest.json", let xml = entries[notation], let json = entries[settingsPath], let hashes = manifest["integrity"] as? [String: String] else { throw ScoreError.invalid("工程入口或校验信息不完整。") }
        guard hashes[notation] != nil, hashes[settingsPath] != nil else { throw ScoreError.invalid("工程入口缺少校验值。") }
        for (path, hash) in hashes {
            guard let contents = entries[path], digest(contents) == hash else { throw ScoreError.invalid("工程内容校验失败：\(path)") }
        }
        var score = try MusicXMLReader.read(xml)
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: json)
        guard settings.version.split(separator: ".").first == "1" else { throw ScoreError.unsupported("项目设置版本不受支持。") }
        let known = Set(["notation.musicxml4", "routing.segment", "visual.trails.v1", "export.mp4"])
        for capability in manifest["requiredCapabilities"] as? [String] ?? [] where !known.contains(capability) {
            score.diagnostics.append(ScoreDiagnostic("工程要求未知能力：\(capability)", blocking: true))
        }
        try validate(settings, score: score)
        for instrument in settings.instruments where instrument.bank.kind == "embedded" {
            guard let path = instrument.bank.path, let data = entries[path], let hash = instrument.bank.sha256, digest(data) == hash, let license = instrument.bank.licensePath, let licenseData = entries[license], !licenseData.isEmpty, !(instrument.bank.attribution ?? "").isEmpty else { throw ScoreError.invalid("内嵌音源的内容、校验或许可不完整。") }
        }
        return Self(id: (manifest["projectId"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(), score: score, settings: settings, sourceURL: sourceURL, entries: entries, notationPath: notation, settingsPath: settingsPath, originalSettings: json, originalManifest: manifestData)
    }

    public func archive() throws -> Data {
        try Self.validate(settings, score: score)
        var contents = entries
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let typed = try JSONSerialization.jsonObject(with: encoder.encode(settings))
        let original: Any = try originalSettings.map { try JSONSerialization.jsonObject(with: $0) } ?? [:]
        contents[settingsPath] = try JSONSerialization.data(withJSONObject: Self.merge(original, typed), options: [.prettyPrinted, .sortedKeys])
        contents[notationPath] = score.originalXML
        var manifest = try originalManifest.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        manifest["format"] = "scorefilm"
        if manifest["version"] == nil { manifest["version"] = "1.0.0" }
        if manifest["profile"] == nil { manifest["profile"] = "scorefilm-mac-v1" }
        manifest["projectId"] = id.uuidString; manifest["title"] = score.title
        var files = manifest["files"] as? [String: String] ?? [:]
        files["notation"] = notationPath; files["settings"] = settingsPath; manifest["files"] = files
        if manifest["requiredCapabilities"] == nil { manifest["requiredCapabilities"] = ["notation.musicxml4", "routing.segment", "visual.trails.v1", "export.mp4"] }
        manifest["integrity"] = contents.filter { $0.key != "manifest.json" }.mapValues(Self.digest)
        contents["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        return try ZIPArchive.write(contents)
    }

    public func save(to url: URL) throws {
        let bytes = try archive()
        _ = try Self.loadArchive(bytes)
        try bytes.write(to: url, options: .atomic)
    }

    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public static func validate(_ settings: ProjectSettings, score: ScoreDocument) throws {
        guard ["a4", "letter"].contains(settings.layout.paper), ["portrait", "landscape"].contains(settings.layout.orientation), (0.5...2).contains(settings.layout.staffScale) else { throw ScoreError.invalid("版面设置超出支持范围。") }
        let video = settings.export
        guard [(1920,1080),(1080,1920)].contains(where: { $0.0 == video.width && $0.1 == video.height }), [30,60].contains(video.fps.n), video.fps.d == 1, video.audioSampleRate == 48000, video.audioChannels == 2, video.container == "mp4", video.videoCodec == "h264", video.colorSpace == "rec709", (0...30).contains(video.tailSeconds) else { throw ScoreError.invalid("影片格式需要为 1080p、30／60 fps、H.264＋AAC、48 kHz 立体声。") }
        guard (0...50).contains(settings.performance.humanize.timingJitterMS), (0...20).contains(settings.performance.humanize.velocityJitter) else { throw ScoreError.invalid("演奏微调参数超出范围。") }
        guard (0...100).contains(settings.performance.reverbWetDryMix ?? 12) else { throw ScoreError.invalid("混响比例需要在 0 至 100 之间。") }
        guard score.parts.contains(where: { $0.id == settings.scoreAxis.referencePartId }), settings.performance.defaultTempoQPM > 0, settings.performance.defaultTempoQPM <= 1000, (0.1...4).contains(settings.performance.tempoScale), (1...10).contains(settings.performance.fermataMultiplier) else { throw ScoreError.invalid("参考声部或速度设置不合法。") }
        guard ["off", "auto", "travel"].contains(settings.visual.effects.trailMode), (0...1000).contains(settings.visual.effects.trailHistoryMS), (1...16).contains(settings.visual.effects.maxTrailLanes), ["none", "pulse"].contains(settings.visual.effects.sustainMode), ["pulse", "loop"].contains(settings.visual.effects.repeatNoteMode) else { throw ScoreError.invalid("轨迹设置不合法。") }
        guard ["clear-score", "cinematic-paper"].contains(settings.visual.preset), ["flatFollow", "cinematicFollow", "locked"].contains(settings.camera.preset), (0...5).contains(settings.camera.lookAheadSeconds), (0...1).contains(settings.camera.motionIntensity) else { throw ScoreError.invalid("视觉或运镜预设不合法。") }
        guard !settings.instruments.isEmpty, settings.instruments.count <= 128, Set(settings.instruments.map(\.id)).count == settings.instruments.count else { throw ScoreError.invalid("乐器列表为空、过多或 ID 重复。") }
        for instrument in settings.instruments {
            guard (0...127).contains(instrument.program), (0...127).contains(instrument.bankMSB), (0...127).contains(instrument.bankLSB), (-96...12).contains(instrument.gainDB), (-1...1).contains(instrument.pan) else { throw ScoreError.invalid("\(instrument.displayName) 的参数超出范围。") }
            guard instrument.bank.kind == "builtin" || (instrument.bank.kind == "embedded" && instrument.bank.path.map(ZIPArchive.validPath) == true) else { throw ScoreError.invalid("音源引用不合法。") }
            if instrument.bank.kind == "builtin", !["piano-v1", "violin-v1", "gm-v1"].contains(instrument.bank.key ?? "") { throw ScoreError.unsupported("内置音源版本未知：\(instrument.bank.key ?? "")") }
        }
        let parts = Set(score.parts.map(\.id)); let instruments = Set(settings.instruments.map(\.id))
        guard (settings.performance.mutedPartIds ?? []).allSatisfy(parts.contains), (settings.performance.soloPartIds ?? []).allSatisfy(parts.contains) else { throw ScoreError.invalid("静音或独奏的声部不存在。") }
        for (part, instrument) in settings.partInstruments where !parts.contains(part) || !instruments.contains(instrument) { throw ScoreError.invalid("配器引用不存在：\(part)") }
        for route in settings.routes where !parts.contains(route.selector.partId) || !instruments.contains(route.instrumentId) { throw ScoreError.invalid("段落配器引用不存在：\(route.id)") }
        guard settings.camera.focusPartIds.allSatisfy(parts.contains), Set(settings.routes.map(\.id)).count == settings.routes.count else { throw ScoreError.invalid("关注声部不存在或配器段落 ID 重复。") }
        if let reference = score.parts.first(where: { $0.id == settings.scoreAxis.referencePartId }) {
            func position(_ value: ScorePosition) throws -> Beat {
                guard let measure = reference.measures.first(where: { $0.id == value.measureId }), value.beat >= .zero, value.beat <= measure.length else { throw ScoreError.invalid("小节位置不存在或拍值越界。") }
                return try measure.start.adding(value.beat)
            }
            for route in settings.routes {
                guard try position(route.range.from) < position(route.range.to) else { throw ScoreError.invalid("配器起点必须早于终点。") }
                guard let part = score.parts.first(where: { $0.id == route.selector.partId }), route.selector.voiceId.map(part.voices.contains) ?? true, route.selector.staff.map({ $0 > 0 && $0 <= 32 }) ?? true else { throw ScoreError.invalid("配器声部或谱表不存在。") }
            }
            for (i, a) in settings.routes.enumerated() {
                for b in settings.routes.dropFirst(i + 1) where a.priority == b.priority && a.selector.partId == b.selector.partId && (a.selector.voiceId == nil || b.selector.voiceId == nil || a.selector.voiceId == b.selector.voiceId) && (a.selector.staff == nil || b.selector.staff == nil || a.selector.staff == b.selector.staff) {
                    if try max(position(a.range.from), position(b.range.from)) < min(position(a.range.to), position(b.range.to)) { throw ScoreError.invalid("同优先级配器范围重叠：\(a.id) 与 \(b.id)") }
                }
            }
            for tempo in settings.performance.tempoOverrides ?? [] {
                _ = try position(tempo.position)
                guard tempo.qpm.isFinite, tempo.qpm > 0, tempo.qpm <= 1000, ["step", "linearQPM"].contains(tempo.interpolation) else { throw ScoreError.invalid("速度覆盖不合法。") }
            }
        }
        let noteIDs = Set(score.notes.map(\.id))
        guard Set((settings.visual.noteOverrides ?? []).map(\.noteId)).count == (settings.visual.noteOverrides ?? []).count else { throw ScoreError.invalid("音符视觉覆盖重复。") }
        for color in settings.visual.voiceColors {
            guard parts.contains(color.selector.partId), color.color.count == 9, color.color.hasPrefix("#"), UInt32(color.color.dropFirst(), radix: 16) != nil else { throw ScoreError.invalid("声部颜色或引用不合法。") }
        }
        for (index, a) in settings.visual.voiceColors.enumerated() {
            for b in settings.visual.voiceColors.dropFirst(index + 1) where a.selector.partId == b.selector.partId && a.color != b.color {
                let sameRank = (a.selector.voiceId == nil ? 0 : 1) + (a.selector.staff == nil ? 0 : 1) == (b.selector.voiceId == nil ? 0 : 1) + (b.selector.staff == nil ? 0 : 1)
                let overlap = (a.selector.voiceId == nil || b.selector.voiceId == nil || a.selector.voiceId == b.selector.voiceId) && (a.selector.staff == nil || b.selector.staff == nil || a.selector.staff == b.selector.staff)
                if sameRank && overlap { throw ScoreError.invalid("同等优先级的声部颜色设置冲突。") }
            }
        }
        for item in settings.visual.noteOverrides ?? [] where !noteIDs.contains(item.noteId) || !["off", "auto", "travel"].contains(item.trail) { throw ScoreError.invalid("音符视觉覆盖不合法：\(item.noteId)") }
    }

    private static func merge(_ old: Any, _ new: Any, path: [String] = []) -> Any {
        if let a = old as? [String: Any], let b = new as? [String: Any] {
            var result = a
            let optional: [String]
            switch path.last {
            case "performance": optional = ["tempoOverrides", "mutedPartIds", "soloPartIds", "reverbWetDryMix"]
            case "visual": optional = ["noteOverrides"]
            case "selector": optional = ["voiceId", "staff"]
            case "bank": optional = ["key", "path", "sha256", "attribution", "licensePath"]
            default: optional = []
            }
            for key in optional where b[key] == nil { result.removeValue(forKey: key) }
            for (key, value) in b { result[key] = Self.merge(a[key] ?? NSNull(), value, path: path + [key]) }
            return result
        }
        if let a = old as? [[String: Any]], let b = new as? [[String: Any]] {
            return b.enumerated().map { index, item in
                let match: [String: Any]?
                if let id = item["id"] as? String { match = a.first { $0["id"] as? String == id } }
                else if let id = item["noteId"] as? String { match = a.first { $0["noteId"] as? String == id } }
                else { match = index < a.count ? a[index] : nil }
                return Self.merge(match ?? [:], item, path: path + ["*"])
            }
        }
        return new
    }
}

private final class MXLRootReader: NSObject, XMLParserDelegate {
    var path: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "rootfile", path == nil, attributes["media-type"] == "application/vnd.recordare.musicxml+xml" || attributes["media-type"] == nil { path = attributes["full-path"] }
    }
}
