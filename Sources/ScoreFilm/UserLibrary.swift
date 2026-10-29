import Foundation
import ScoreCore

enum UserLibrary {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Music Viewer/Projects", isDirectory: true)
    static let store = UserProjectLibrary(root: root)

    static func contains(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath()
    }
}
