import Foundation

public struct UserProjectSummary: Identifiable, Codable, Sendable {
    public let id: UUID
    public let title: String
    public let modified: Date
    public let partCount: Int
    public let noteCount: Int
}

/// Serializes the managed copies shared by all workspace windows. The project
/// is authoritative; a missing metadata sidecar can be rebuilt after a crash.
public actor UserProjectLibrary {
    public let root: URL

    public init(root: URL) { self.root = root }

    public nonisolated func projectURL(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString + ".scorefilm")
    }

    @discardableResult
    public func save(_ project: ProjectFile) throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = projectURL(for: project.id)
        try project.save(to: url)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
        let summary = UserProjectSummary(id: project.id, title: project.score.title, modified: modified, partCount: project.score.parts.count, noteCount: project.score.noteCount)
        try writeMetadata(summary)
        return url
    }

    public func projects() throws -> [UserProjectSummary] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        var result: [UserProjectSummary] = []
        for url in files where url.pathExtension == "scorefilm" {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let metadata = root.appendingPathComponent(id.uuidString + ".json")
            if let data = try? Data(contentsOf: metadata), let saved = try? JSONDecoder().decode(UserProjectSummary.self, from: data), saved.id == id, saved.modified == modified {
                result.append(saved)
            } else {
                let project = try ProjectFile.load(url)
                guard project.id == id else { throw ScoreError.invalid("我的工程文件身份与文件名不一致。") }
                let saved = UserProjectSummary(id: id, title: project.score.title, modified: modified, partCount: project.score.parts.count, noteCount: project.score.noteCount)
                try writeMetadata(saved); result.append(saved)
            }
        }
        return result.sorted { $0.modified > $1.modified }
    }

    private func writeMetadata(_ summary: UserProjectSummary) throws {
        let data = try JSONEncoder().encode(summary)
        try data.write(to: root.appendingPathComponent(summary.id.uuidString + ".json"), options: .atomic)
    }
}
