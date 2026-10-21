import CheckmateDomain
import Foundation
import OSLog
/// User-visible error text: located import errors and app errors only; system errors use the
/// caller's fallback so file paths and type dumps never reach the window.
/// An error that carries its own plain-language message for the learner.
public protocol UserFacingError:Error {var userFacingMessage:String {get}}
public func userFacingMessage(_ error:Error,fallback:String)->String {
    if let described=error as? UserFacingError {return described.userFacingMessage}
    if let located=error as? ReviewImportError {return located.errorDescription ?? fallback}
    if let app=error as? CheckmateError {switch app{case .invalid(let text),.unavailable(let text):return text;case .stale:return "The position changed; try again.";case .cancelled:return "The operation was canceled."}}
    return fallback
}
public enum NativePolicy {
    /// Silent: no live voice, Codex, microphone or audible output. Any process with XCTest loaded is silent, so a
    /// bare `swift test` can never reach live services, whatever its environment.
    public static var silent:Bool {ProcessInfo.processInfo.environment["CHECKMATE_AUTOMATION"] == "1" || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || CommandLine.arguments.contains("--automation") || NSClassFromString("XCTestCase") != nil}
}

public enum NativeLog {public static let lifecycle=Logger(subsystem:"ai.xiaolai.checkmate",category:"lifecycle");public static let engine=Logger(subsystem:"ai.xiaolai.checkmate",category:"engine");public static let course=Logger(subsystem:"ai.xiaolai.checkmate",category:"course");public static let companion=Logger(subsystem:"ai.xiaolai.checkmate",category:"companion");public static let voice=Logger(subsystem:"ai.xiaolai.checkmate",category:"voice");public static let storage=Logger(subsystem:"ai.xiaolai.checkmate",category:"storage")}
