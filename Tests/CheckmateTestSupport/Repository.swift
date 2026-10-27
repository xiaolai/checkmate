import Foundation

/// The repository's own directories, for tests that read its sources and fixtures.
public enum Repository {
    public static let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    public static let tests=root.appendingPathComponent("Tests")
    public static func url(_ path:String)->URL {root.appendingPathComponent(path)}
}
