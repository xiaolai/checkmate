import CheckmateDomain
import CheckmateAssets
import Foundation
public enum ProtocolErrors {
    public static func failure(_ error:Error)->[String:Any] {if let e=error as? ProtocolFailure{return e.result};if error is CancellationError{return ProtocolFailure("CANCELLED").result};if let e=error as? CheckmateError {switch e{case .stale:return ProtocolFailure("STALE_STATE").result;case .cancelled:return ProtocolFailure("CANCELLED").result;case .invalid(let code):return ProtocolFailure(code.contains(" ") ? "INVALID_MOVE":code).result;case .unavailable(let code):return ProtocolFailure(code.contains(" ") ? "ENGINE_UNAVAILABLE":code).result}};return ProtocolFailure("INTERNAL_ERROR","The request failed. Read the current session and try again.").result}
}
