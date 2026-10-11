import Foundation
public enum NativeResources {
    public static var root: URL { { let packaged=Bundle.main.resourceURL!.appendingPathComponent("Checkmate_CheckmateAssets.bundle/Contents/Resources/Resources"); if FileManager.default.fileExists(atPath:packaged.appendingPathComponent("chess.js").path){return packaged}; return Bundle.module.resourceURL!.appendingPathComponent("Resources") }() }
    public static func url(_ path:String) -> URL {root.appendingPathComponent(path)}
}
