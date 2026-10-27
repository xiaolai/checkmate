import Foundation
import CheckmateSupport

/// The protocol error code an error carries, as a client reads it.
public func protocolCode(_ error:Error)->String? {(ProtocolErrors.failure(error)["error"] as? [String:Any])?["code"] as? String}
/// The protocol error code `body` fails with; nil when it succeeds.
@MainActor public func protocolCode(_ body:()async throws -> Any)async -> String? {do{_ = try await body();return nil}catch{return protocolCode(error)}}
