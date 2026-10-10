import Foundation
import Darwin
import Combine
public struct AnalysisScore:Codable,Equatable {public var kind:String,value:Int,perspective="white",bound:String?;public init(kind:String,value:Int,bound:String?=nil){self.kind=kind;self.value=value;self.bound=bound}}
public struct AnalysisLine:Codable,Equatable {public var depth:Int,multiPv:Int,score:AnalysisScore,pv:[String],san:[String];public var nodes:Int?=nil,timeMs:Int?=nil,wdl:[Int]?=nil}
public struct OpponentDecision:Codable {public let policyVersion:Int,estimatedRegretCp:Int?,fallback:Bool,priorSevereStreak:Int}
public struct EngineAnalysis:Codable {public var opponentDecision:OpponentDecision?=nil;public var bestMove:String?,budgetMs:Int,lines:[AnalysisLine];public init(bestMove:String?=nil,budgetMs:Int=350,lines:[AnalysisLine]=[]){self.bestMove=bestMove;self.budgetMs=budgetMs;self.lines=lines}}
@MainActor public protocol EngineService:AnyObject {func analyze(fen:String,skill:Int,budget:Int,multiPv:Int) async throws -> EngineAnalysis}
@MainActor public final class NativeEngine:EngineService,ObservableObject {
    private let worker:UCIWorker
    public let executable:URL
    public private(set) var binaryIdentity=""
    private let identityTask:Task<String,Error>
    @Published public private(set) var capabilities=EngineCapabilities()
    private var searching=false,waiting=0
    /// Start FEN, caller moves, replayed rules and their validated canonical UCI.
    private var validationCache:(String,[String],ChessRules,[String])?
    public init(executable:URL?=nil){self.executable=executable ?? NativeResources.url("stockfish");worker=UCIWorker(executable:self.executable);let file=self.executable;let bundled=executable==nil;identityTask=Task.detached{
            let binary=try reviewFileHash(file),network=file.deletingLastPathComponent().appendingPathComponent(EngineRuntimePolicy.networkFile)
            if FileManager.default.fileExists(atPath:network.path){let hash=try reviewFileHash(network);guard !bundled || hash==EngineRuntimePolicy.networkSHA256 else{throw CheckmateError.unavailable("The bundled engine network is invalid.")};return binary+":network:"+hash}
            guard !bundled else{throw CheckmateError.unavailable("The bundled engine network is missing.")};return binary
        }}
    public func prepare()async throws {
        if binaryIdentity.isEmpty{binaryIdentity=try await identityTask.value}
        guard capabilities.name=="Unknown engine" else{return}
        let worker=worker;capabilities=try await Task.detached{try worker.prepare()}.value
    }
    public func analyze(fen:String,skill:Int=20,budget:Int=350,multiPv:Int=3) async throws -> EngineAnalysis {
        try await analyzeHistory(startFEN:fen,moves:[],profile:.skill(max(0,min(20,skill))),budget:max(100,min(1000,budget)),multiPv:max(1,min(3,multiPv)))
    }
    public func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String]=[])async throws -> EngineAnalysis {
        if binaryIdentity.isEmpty{binaryIdentity=try await identityTask.value}
        guard waiting<8 else{throw CheckmateError.unavailable("BUSY")};waiting+=1;defer{waiting-=1}
        let deadline=Date().addingTimeInterval(4)
        while searching{guard Date()<deadline else{throw CheckmateError.unavailable("BUSY")};try Task.checkCancellation();try await Task.sleep(nanoseconds:10_000_000)}
        try Task.checkCancellation();searching=true;defer{searching=false}
        // Validate on the main actor and send the validated canonical moves: the bundled Stockfish 19
        // rejects a non-canonical token such as e7e8 ("CRITICAL ERROR ... Illegal move") and exits.
        let rules:ChessRules,canonical:[String]
        let previous=validationCache;validationCache=nil
        if let cached=previous,cached.0==startFEN,moves.starts(with:cached.1){rules=cached.2;var validated=cached.3;for move in moves.dropFirst(cached.1.count){validated.append(try rules.move(uci:move).uci)};canonical=validated}
        else{rules=try ChessRules(fen:startFEN);var validated:[String]=[];for move in moves{validated.append(try rules.move(uci:move).uci)};canonical=validated}
        validationCache=(startFEN,moves,rules,canonical)
        let legal=rules.moves()
        guard searchMoves.allSatisfy({uci in legal.contains{$0.uci==uci}}) else{throw CheckmateError.invalid("Illegal searchmoves constraint.")}
        let worker=worker,fen=rules.fen,epoch=worker.reserve(),lines=max(1,min(16,multiPv,max(1,searchMoves.isEmpty ? legal.count:searchMoves.count)))
        var result=try await withTaskCancellationHandler(operation:{try await Task.detached(priority:.userInitiated){try worker.search(startFEN:startFEN,moves:canonical,finalFEN:fen,profile:profile,budget:max(100,min(3000,budget)),multiPv:lines,searchMoves:searchMoves,epoch:epoch)}.value},onCancel:{worker.cancel(expected:epoch)})
        capabilities=worker.metadata()
        result.lines=try result.lines.compactMap{line in try autoreleasepool{var line=line;let replay=try ChessRules(fen:fen);do{line.san=try line.pv.map{try replay.move(uci:$0).san};return line}catch{return nil}}}
        return result
    }
}

/// Packaging/runtime memory controls; the Stockfish algorithm, NNUE and search budgets are unchanged.
public enum EngineRuntimePolicy {
    public static let networkFile="nn-1a298aa575a0.nnue"
    public static let networkSHA256="1a298aa575a085434d29027978dc36867fe9c5bcea9376654b7a8eba1e52dfc2"
    public static let environment=["MallocLargeCache":"0"]
}
