import CheckmateAssets
import Foundation
/// History, strength and constrained searches belong to the engine contract, not a concrete implementation.
@MainActor public protocol EngineService:AnyObject {
    var binaryIdentity:String {get}
    /// The identity `binaryIdentity` holds once prepared, read without starting the engine: stored review evidence is
    /// keyed by it, so a review shows its stored analysis with no engine running.
    func identity()async throws -> String
    var capabilities:EngineCapabilities {get}
    func prepare()async throws
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis
    /// A search with an explicit limit (A5). An engine that cannot count nodes refuses `nodes` rather than search for a time.
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,limit:EngineSearchLimit,multiPv:Int)async throws -> EngineAnalysis
    /// A search with an explicit limit that may also be constrained to `searchMoves` (mini-game plan D4), so a level's
    /// every search, the beginner opponent's candidate searches included, is node-limited.
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,limit:EngineSearchLimit,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis
    /// A budgeted search that may use `resources` in place of the analysis policy's threads and hash (R-5).
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String],resources:EngineResources)async throws -> EngineAnalysis
}
public extension EngineService {
    /// An engine that cannot tell its identity before preparing reports it as it stands.
    func identity()async throws -> String {binaryIdentity}
    /// An engine without adjustable resources searches as it always does.
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String],resources:EngineResources)async throws -> EngineAnalysis {
        try await analyzeHistory(startFEN:startFEN,moves:moves,profile:profile,budget:budget,multiPv:multiPv,searchMoves:searchMoves)
    }
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int)async throws -> EngineAnalysis {
        try await analyzeHistory(startFEN:startFEN,moves:moves,profile:profile,budget:budget,multiPv:multiPv,searchMoves:[])
    }
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,limit:EngineSearchLimit,multiPv:Int)async throws -> EngineAnalysis {
        guard case .movetime(let budget)=limit else{throw CheckmateError.unavailable(String(localized:"This engine cannot search a fixed number of nodes.",bundle:.checkmate))}
        return try await analyzeHistory(startFEN:startFEN,moves:moves,profile:profile,budget:budget,multiPv:multiPv,searchMoves:[])
    }
    /// A time is the budgeted search, constrained or not; a node count without constraints is the limit search above.
    /// An engine that cannot constrain a node search refuses it rather than search unconstrained or for a time.
    func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,limit:EngineSearchLimit,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis {
        switch limit {
        case .movetime(let budget):return try await analyzeHistory(startFEN:startFEN,moves:moves,profile:profile,budget:budget,multiPv:multiPv,searchMoves:searchMoves)
        case .nodes:
            guard searchMoves.isEmpty else{throw CheckmateError.unavailable(String(localized:"This engine cannot constrain a search of a fixed number of nodes.",bundle:.checkmate))}
            return try await analyzeHistory(startFEN:startFEN,moves:moves,profile:profile,limit:limit,multiPv:multiPv)
        }
    }
}
