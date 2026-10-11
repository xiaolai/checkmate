import Foundation
import CheckmateDomain
import CheckmateRules
import CheckmateEngine
/// Explicitly position-only test doubles. Production engines must implement the full history contract.
@MainActor public protocol TestEngineService:EngineService {}
public extension TestEngineService {
    var binaryIdentity:String {"test-engine"}
    var capabilities:EngineCapabilities {EngineCapabilities()}
    func prepare()async throws {}
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis {
        let position=try ChessRules(fen:startFEN);for move in moves{try position.move(uci:move)}
        return try await analyze(fen:position.fen,skill:profile.mode=="skill" ? profile.value:0,budget:budget,multiPv:multiPv)
    }
}
