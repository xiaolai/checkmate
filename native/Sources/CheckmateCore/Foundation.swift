import Foundation
import OSLog
public enum NativeResources {
    public static var root: URL { { let packaged=Bundle.main.resourceURL!.appendingPathComponent("Checkmate_CheckmateCore.bundle/Contents/Resources/Resources"); if FileManager.default.fileExists(atPath:packaged.appendingPathComponent("chess.js").path){return packaged}; return Bundle.module.resourceURL!.appendingPathComponent("Resources") }() }
    public static func url(_ path:String) -> URL {root.appendingPathComponent(path)}
}
public enum CheckmateError: Error, CustomStringConvertible {
    case invalid(String), unavailable(String), stale, cancelled
    public var description:String {switch self {case .invalid(let s),.unavailable(let s):return s;case .stale:return "STALE_STATE";case .cancelled:return "CANCELLED"}}
}
/// User-visible error text: located import errors and app errors only; system errors use the
/// caller's fallback so file paths and type dumps never reach the window.
public func userFacingMessage(_ error:Error,fallback:String)->String {
    if let located=error as? ReviewImportError {return located.errorDescription ?? fallback}
    if let app=error as? CheckmateError {switch app{case .invalid(let text),.unavailable(let text):return text;case .stale:return "The position changed; try again.";case .cancelled:return "The operation was cancelled."}}
    return fallback
}
public enum NativeMode:String,Codable {case practice,lesson,puzzles}
public enum NativePolicy {
    public static var silent:Bool {ProcessInfo.processInfo.environment["CHECKMATE_AUTOMATION"] == "1" || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || CommandLine.arguments.contains("--automation")}
}

public enum NativeLog {public static let lifecycle=Logger(subsystem:"ai.xiaolai.checkmate",category:"lifecycle");public static let engine=Logger(subsystem:"ai.xiaolai.checkmate",category:"engine");public static let course=Logger(subsystem:"ai.xiaolai.checkmate",category:"course");public static let companion=Logger(subsystem:"ai.xiaolai.checkmate",category:"companion");public static let voice=Logger(subsystem:"ai.xiaolai.checkmate",category:"voice");public static let storage=Logger(subsystem:"ai.xiaolai.checkmate",category:"storage")}
