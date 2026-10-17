import Foundation
/// History, strength and constrained searches belong to the engine contract, not a concrete implementation.
@MainActor public protocol EngineService:AnyObject {
    var binaryIdentity:String {get}
    var capabilities:EngineCapabilities {get}
    func prepare()async throws
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis
    /// A search with an explicit limit (A5). An engine that cannot count nodes refuses `nodes` rather than search for a time.
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,limit:EngineSearchLimit,multiPv:Int)async throws -> EngineAnalysis
}
public extension EngineService {
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int)async throws -> EngineAnalysis {
        try await analyzeHistory(startFEN:startFEN,moves:moves,profile:profile,budget:budget,multiPv:multiPv,searchMoves:[])
    }
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,limit:EngineSearchLimit,multiPv:Int)async throws -> EngineAnalysis {
        guard case .movetime(let budget)=limit else{throw CheckmateError.unavailable("This engine cannot search a fixed number of nodes.")}
        return try await analyzeHistory(startFEN:startFEN,moves:moves,profile:profile,budget:budget,multiPv:multiPv,searchMoves:[])
    }
}
