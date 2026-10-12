import Foundation
import CheckmateDomain
import CheckmateRules
/// A deterministic practice defender for training-game tests: it answers each history request with the move its
/// `choose` closure picks, records every request, and can fail, return an illegal move, or hold its answer.
@MainActor public final class ScriptedDefender:EngineService {
    public struct Request:Equatable {public let startFEN:String,moves:[String],profile:OpponentProfile,budget:Int}
    public var binaryIdentity:String {"scripted-defender"}
    public var capabilities:EngineCapabilities {EngineCapabilities()}
    public private(set) var requests:[Request]=[]
    /// The reply for a position reached from `startFEN` by `moves`; nil means no move.
    public var choose:(ChessRules)throws -> String?
    public var failure:Error?
    /// While set, requests wait until `release()`.
    public var holding=false
    private var waiting:[CheckedContinuation<Void,Never>]=[]
    public init(choose:@escaping (ChessRules)throws -> String?={rules in rules.moves().map(\.uci).sorted().first}){self.choose=choose}
    public func prepare()async throws {}
    public func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {throw CheckmateError.unavailable("A training defender answers history requests only.")}
    public func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis {
        requests.append(Request(startFEN:startFEN,moves:moves,profile:profile,budget:budget))
        if holding{await withCheckedContinuation{waiting.append($0)}}
        if let failure{throw failure}
        let rules=try ChessRules(fen:startFEN);for move in moves{try rules.move(uci:move)}
        return EngineAnalysis(bestMove:try choose(rules))
    }
    public func release(){let pending=waiting;waiting=[];holding=false;pending.forEach{$0.resume()}}
    /// Captures the given piece when it can, otherwise plays the first legal move in coordinate order.
    public static func capturing(_ piece:String)->(ChessRules)throws -> String? {
        {rules in let moves=rules.moves();return (moves.first{$0.captured==piece} ?? moves.sorted{$0.uci<$1.uci}.first)?.uci}
    }
}
