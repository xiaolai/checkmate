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
        let position=try ChessRules.reached(startFEN,moves)
        return try await analyze(fen:position.fen,skill:profile.mode=="skill" ? profile.value:0,budget:budget,multiPv:multiPv)
    }
}
/// An engine that holds every search until the test finishes it, recording the skill each search asked for.
@MainActor public final class ContinuationEngine:TestEngineService {
    public var continuations:[CheckedContinuation<EngineAnalysis,Error>]=[]
    public var skills:[Int]=[]
    public init(){}
    public func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {skills.append(skill);return try await withCheckedThrowingContinuation{continuations.append($0)}}
    public func finish(at index:Int,_ move:String){continuations[index].resume(returning:EngineAnalysis(bestMove:move))}
}
/// An engine whose first search after `hold` is set waits until the test releases it.
@MainActor public final class HoldOnceEngine:TestEngineService {
    public var hold=false,waiting:CheckedContinuation<Void,Never>?
    public init(){}
    public func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {if hold{hold=false;await withCheckedContinuation{waiting=$0}};return EngineAnalysis(bestMove:try ChessRules(fen:fen).moves().first?.uci)}
    public func release(){waiting?.resume();waiting=nil}
}
/// An engine that counts searches and their overlap; while `gated`, each search waits until the test releases it.
@MainActor public final class GatedCountingEngine:TestEngineService {
    public var active=0,peak=0,calls=0,gated:Bool,waiting:[CheckedContinuation<Void,Never>]=[]
    public init(gated:Bool=false){self.gated=gated}
    public func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {
        calls+=1;active+=1;peak=max(peak,active);defer{active-=1}
        if gated{await withCheckedContinuation{waiting.append($0)}}
        let move=try ChessRules(fen:fen).moves().first!;return EngineAnalysis(bestMove:move.uci,lines:[AnalysisLine(depth:1,multiPv:1,score:AnalysisScore(kind:"cp",value:0),pv:[move.uci],san:[])])
    }
    public func releaseAll(){let all=waiting;waiting=[];all.forEach{$0.resume()}}
}
