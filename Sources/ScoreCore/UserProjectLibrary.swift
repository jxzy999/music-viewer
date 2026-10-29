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
    private var trashedIDs: Set<UUID> = []

    public init(root: URL) { self.root = root }

    public nonisolated func projectURL(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString + ".scorefilm")
    }

    @discardableResult
    public func save(_ project: ProjectFile) throws -> URL {
        try Task.checkCancellation()
        guard !trashedIDs.contains(project.id) else { throw ScoreError.invalid("此工程已移到废纸篓，请恢复后重新打开。") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = projectURL(for: project.id)
        try project.save(to: url)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
        let summary = UserProjectSummary(id: project.id, title: project.score.title, modified: modified, partCount: project.score.parts.count, noteCount: project.score.noteCount)
        try writeMetadata(summary)
        return url
    }

    @discardableResult
    public func moveToTrash(_ summary: UserProjectSummary) throws -> URL? {
        try Task.checkCancellation()
        let url = projectURL(for: summary.id)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ScoreError.invalid("工程路径已变化，请刷新列表后重试。")
        }
        guard values.contentModificationDate == summary.modified else { throw ScoreError.invalid("工程刚刚更新，请刷新列表后再确认。") }
        let project = try ProjectFile.load(url)
        guard project.id == summary.id else { throw ScoreError.invalid("工程身份与文件名不一致，已停止删除。") }
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        trashedIDs.insert(summary.id)
        // This is a derived index; a restored project rebuilds it automatically.
        try? FileManager.default.removeItem(at: root.appendingPathComponent(summary.id.uuidString + ".json"))
        return destination as URL?
    }

    public func projects() throws -> [UserProjectSummary] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        var result: [UserProjectSummary] = []
        for url in files where url.pathExtension == "scorefilm" {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let restored = trashedIDs.contains(id) ? try ProjectFile.load(url) : nil
            if let restored, restored.id != id { throw ScoreError.invalid("恢复的工程身份与文件名不一致。") }
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let metadata = root.appendingPathComponent(id.uuidString + ".json")
            if restored == nil, let data = try? Data(contentsOf: metadata), let saved = try? JSONDecoder().decode(UserProjectSummary.self, from: data), saved.id == id, saved.modified == modified {
                result.append(saved)
            } else {
                let project = try restored ?? ProjectFile.load(url)
                guard project.id == id else { throw ScoreError.invalid("我的工程文件身份与文件名不一致。") }
                let saved = UserProjectSummary(id: id, title: project.score.title, modified: modified, partCount: project.score.parts.count, noteCount: project.score.noteCount)
                try writeMetadata(saved); result.append(saved)
            }
            trashedIDs.remove(id)
        }
        return result.sorted { $0.modified > $1.modified }
    }

    private func writeMetadata(_ summary: UserProjectSummary) throws {
        let data = try JSONEncoder().encode(summary)
        try data.write(to: root.appendingPathComponent(summary.id.uuidString + ".json"), options: .atomic)
    }
}
