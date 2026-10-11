import Foundation
/// History, strength and constrained searches belong to the engine contract, not a concrete implementation.
@MainActor public protocol EngineService:AnyObject {
    var binaryIdentity:String {get}
    var capabilities:EngineCapabilities {get}
    func prepare()async throws
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis
}
public extension EngineService {
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int)async throws -> EngineAnalysis {
        try await analyzeHistory(startFEN:startFEN,moves:moves,profile:profile,budget:budget,multiPv:multiPv,searchMoves:[])
    }
}
