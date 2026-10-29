import Foundation

public struct LayoutAnchor: Codable, Sendable {
    public let sourceID: String
    public let page: Int
    public let x: Double
    public let y: Double
    public let radius: Double
    public let system: String
    public init(sourceID: String, page: Int, x: Double, y: Double, radius: Double, system: String) {
        self.sourceID = sourceID; self.page = page; self.x = x; self.y = y; self.radius = radius; self.system = system
    }
}
public struct LayoutPage: Sendable {
    public let index: Int
    public let width: Double
    public let height: Double
    public let png: Data
    public init(index: Int, width: Double, height: Double, png: Data) { self.index = index; self.width = width; self.height = height; self.png = png }
}
public struct LayoutSnapshot: Sendable {
    public let pages: [LayoutPage]
    public let anchors: [String: LayoutAnchor]
    public let missingNoteIDs: [String]
    public var mappingIssues: [String] = []
    public init(pages: [LayoutPage], anchors: [String: LayoutAnchor], missingNoteIDs: [String], mappingIssues: [String] = []) {
        self.pages = pages; self.anchors = anchors; self.missingNoteIDs = missingNoteIDs; self.mappingIssues = mappingIssues
    }
}
