import CheckmateDomain
import CheckmateRules
import Foundation
/// Explore measured legal non-leading moves as well as strong candidates. No rating is implied.
@MainActor public enum BeginnerOpponent {
    public static let maximumRegretCp=BeginnerPolicy.maximumRegretCp,candidateCount=BeginnerPolicy.candidateCount,budgetMs=BeginnerPolicy.budgetMs
    public static func nextSevereStreak(_ result:EngineAnalysis,mover:String,current:Int)->Int {if let decision=result.opponentDecision{return (decision.estimatedRegretCp ?? 0)>=BeginnerPolicy.severeRegretCp ? min(BeginnerPolicy.maximumConsecutiveSevereErrors,current+1):0};guard let best=result.lines.first?.score,let chosen=result.lines.first(where:{$0.pv.first==result.bestMove})?.score,best.kind=="cp",chosen.kind=="cp",best.bound==nil,chosen.bound==nil else{return 0};let regret=max(0,(best.value-chosen.value)*(mover=="w" ? 1:-1));return regret>=BeginnerPolicy.severeRegretCp ? min(BeginnerPolicy.maximumConsecutiveSevereErrors,current+1):0}
    /// A White-perspective score on one scale: mate in n is worth slightly less than 10000 for each extra move.
    static func centipawns(_ score:AnalysisScore)->Int {score.kind=="mate" ? (score.value>0 ? 10000-score.value:-10000-score.value):score.value}
    /// Reached only through callers that check `fairness` themselves (native `reply` and MCP `play_move`, both through
    /// `GameSession.chooseOpponentMove`, and the lesson exercise's defender). It checks again before each further search
    /// after an `await`, so a choice in flight when a network game begins makes no more engine calls (LAN-play plan D8).
    /// Practice searches for `budgetMs` each. `limit` replaces that for every search, the root and each constrained
    /// one alike (a training game's Gentle searches a fixed number of nodes, mini-game plan D4); with a node limit,
    /// `decisionNodes` caps the whole decision, so a constrained search that would pass it is not made.
    public static func choose(rules:ChessRules,engine:any EngineService,seed:UInt64,severeStreak:Int=0,fairness:FairnessPolicy?=nil,limit:EngineSearchLimit?=nil,decisionNodes:Int?=nil)async throws -> EngineAnalysis {
        let fairness=fairness ?? FairnessPolicy();try fairness.requireEngineHelp()
        let position=try rules.copy(),legal=position.moves();guard !legal.isEmpty else{return EngineAnalysis()}
        let start=position.records.first?.before ?? position.fen,history=position.records.map(\.uci),sign=position.turn=="w" ? 1:-1
        let search=limit ?? .movetime(budgetMs),cost:Int={if case .nodes(let nodes)=search{return nodes};return 0}()
        let root=try await engine.analyzeHistory(startFEN:start,moves:history,profile:.skill(20),limit:search,multiPv:min(candidateCount,legal.count),searchMoves:[])
        var rng=SeededReviewRandom(seed:seed),measured=root.lines,spent=cost
        let leading=Set(measured.compactMap{$0.pv.first}),others=legal.filter{!leading.contains($0.uci)}.shuffled(using:&rng)
        for move in others.prefix(BeginnerPolicy.explorationCount) {
            if let decisionNodes,spent+cost>decisionNodes{break}
            try Task.checkCancellation();try fairness.requireEngineHelp()
            let constrained=try await engine.analyzeHistory(startFEN:start,moves:history,profile:.skill(20),limit:search,multiPv:1,searchMoves:[move.uci])
            spent+=cost
            if let line=constrained.lines.first{measured.append(line)}
        }
        let best=root.lines.first?.score
        var eligible:[(String,Int)]=[]
        for line in measured {
            guard let uci=line.pv.first,let move=legal.first(where:{$0.uci==uci}),line.score.bound==nil else{continue}
            var regret=0
            if let best=best {
                if line.score.kind=="mate",line.score.value*sign<0,best.kind != "mate" || best.value*sign>=0 {continue}
                // Mates count as decisive centipawns, so passing up a forced mate is a large regret and the caps still apply.
                if best.bound==nil{regret=max(0,(Self.centipawns(best)-Self.centipawns(line.score))*sign);guard regret<=BeginnerPolicy.maximumRegretCp,severeStreak<BeginnerPolicy.maximumConsecutiveSevereErrors || regret<BeginnerPolicy.severeRegretCp else{continue}}
            }
            let after=try ChessRules(fen:position.fen);try after.move(uci:uci)
            if after.moves().contains(where:{$0.captured=="q"}),move.captured != "q"{continue}
            eligible.append((uci,regret))
        }
        let mistakes=eligible.filter{$0.1>=BeginnerPolicy.minorRegretCp}
        let pool=(rng.next()%100<UInt64(BeginnerPolicy.mistakePercent) && !mistakes.isEmpty) ? mistakes:eligible
        let ordered=pool.sorted{$0.0<$1.0}
        let choice=ordered.isEmpty ? (root.bestMove ?? legal[0].uci):ordered[Int(rng.next()%UInt64(ordered.count))].0
        // Every score retains its own depth/budget; these are candidate measurements, not a coherent review MultiPV snapshot.
        let chosenScore=measured.first(where:{$0.pv.first==choice})?.score;let estimatedRegret=(best?.kind=="cp" && chosenScore?.kind=="cp" && best?.bound==nil && chosenScore?.bound==nil) ? eligible.first(where:{$0.0==choice})?.1:nil
        var result=EngineAnalysis(bestMove:choice,budgetMs:budgetMs,lines:measured);result.opponentDecision=OpponentDecision(policyVersion:BeginnerPolicy.version,estimatedRegretCp:estimatedRegret,fallback:ordered.isEmpty,priorSevereStreak:severeStreak);return result
    }
}
