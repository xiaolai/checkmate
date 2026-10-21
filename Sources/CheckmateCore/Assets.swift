import Foundation
public enum NativeResources {
    public static var root: URL { { let packaged=Bundle.main.resourceURL!.appendingPathComponent("Checkmate_CheckmateAssets.bundle/Contents/Resources/Resources"); if FileManager.default.fileExists(atPath:packaged.appendingPathComponent("chess.js").path){return packaged}; return Bundle.module.resourceURL!.appendingPathComponent("Resources") }() }
    public static func url(_ path:String) -> URL {root.appendingPathComponent(path)}
}
public extension Bundle {
    /// The one String Catalog (Localizable.xcstrings) the whole app localizes through: `String(localized:…,bundle:.checkmate)`.
    /// The packaged copy inside the app when there is one, else SwiftPM's (tests and command-line tools). build.sh also
    /// copies its localizations into the app itself, where SwiftUI's `Text("…")` and AppKit look by default.
    static let checkmate:Bundle = {Bundle.main.resourceURL.flatMap{Bundle(url:$0.appendingPathComponent("Checkmate_CheckmateAssets.bundle"))} ?? .module}()
}
/// Localized interpolation formats a number with `%lf`, so 1.5 shows as "1.500000". Shown numbers are formatted into
/// text first, so their digits are chosen on purpose; with warnings as errors these overloads stop the build.
public extension String.LocalizationValue.StringInterpolation {
    @available(*,deprecated,message:"Format the number into text first: localized interpolation shows 1.5 as 1.500000")
    mutating func appendInterpolation(_ value:Double) {appendInterpolation(String(describing:value))}
    @available(*,deprecated,message:"Format the number into text first: localized interpolation shows 1.5 as 1.500000")
    mutating func appendInterpolation(_ value:Float) {appendInterpolation(String(describing:value))}
}
