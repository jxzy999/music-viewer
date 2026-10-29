import Foundation

public enum MediaResources {
    public static var root: URL { (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Resources", isDirectory: true) }
    public static var soundBank: URL { root.appendingPathComponent("GeneralUser-GS.sf2") }
    public static var notationRoot: URL { root.appendingPathComponent("Notation", isDirectory: true) }
}
