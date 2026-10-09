import Foundation
public struct SeededReviewRandom:RandomNumberGenerator {private var state:UInt64;public init(seed:UInt64){state=seed == 0 ? 1:seed};public mutating func next()->UInt64 {state = state &* 6364136223846793005 &+ 1442695040888963407;return state}}
public enum BeginnerPolicy {
    public static let version=3,severeRegretCp=300,maximumConsecutiveSevereErrors=2,maximumRegretCp=700,minorRegretCp=100,candidateCount=6,explorationCount=4,budgetMs=180,mistakePercent=65
}
/// Explore measured legal non-leading moves as well as strong candidates. No rating is implied.
@MainActor public enum BeginnerOpponent {
    public static let maximumRegretCp=BeginnerPolicy.maximumRegretCp,candidateCount=BeginnerPolicy.candidateCount,budgetMs=BeginnerPolicy.budgetMs
    public static func nextSevereStreak(_ result:EngineAnalysis,mover:String,current:Int)->Int {if let decision=result.opponentDecision{return (decision.estimatedRegretCp ?? 0)>=BeginnerPolicy.severeRegretCp ? min(BeginnerPolicy.maximumConsecutiveSevereErrors,current+1):0};guard let best=result.lines.first?.score,let chosen=result.lines.first(where:{$0.pv.first==result.bestMove})?.score,best.kind=="cp",chosen.kind=="cp",best.bound==nil,chosen.bound==nil else{return 0};let regret=max(0,(best.value-chosen.value)*(mover=="w" ? 1:-1));return regret>=BeginnerPolicy.severeRegretCp ? min(BeginnerPolicy.maximumConsecutiveSevereErrors,current+1):0}
    public static func choose(rules:ChessRules,engine:NativeEngine,seed:UInt64,severeStreak:Int=0)async throws -> EngineAnalysis {
        let position=try rules.copy(),legal=position.moves();guard !legal.isEmpty else{return EngineAnalysis()}
        let start=position.records.first?.before ?? position.fen,history=position.records.map(\.uci),sign=position.turn=="w" ? 1:-1
        let root=try await engine.analyzeHistory(startFEN:start,moves:history,profile:.skill(20),budget:budgetMs,multiPv:min(candidateCount,legal.count))
        var rng=SeededReviewRandom(seed:seed),measured=root.lines
        let leading=Set(measured.compactMap{$0.pv.first}),others=legal.filter{!leading.contains($0.uci)}.shuffled(using:&rng)
        for move in others.prefix(BeginnerPolicy.explorationCount) {
            try Task.checkCancellation()
            let constrained=try await engine.analyzeHistory(startFEN:start,moves:history,profile:.skill(20),budget:budgetMs,multiPv:1,searchMoves:[move.uci])
            if let line=constrained.lines.first{measured.append(line)}
        }
        let best=root.lines.first?.score
        var eligible:[(String,Int)]=[]
        for line in measured {
            guard let uci=line.pv.first,let move=legal.first(where:{$0.uci==uci}),line.score.bound==nil else{continue}
            var regret=0
            if let best=best {
                if line.score.kind=="mate",line.score.value*sign<0,best.kind != "mate" || best.value*sign>=0 {continue}
                if best.kind=="cp",line.score.kind=="cp"{regret=max(0,(best.value-line.score.value)*sign);guard regret<=BeginnerPolicy.maximumRegretCp,severeStreak<BeginnerPolicy.maximumConsecutiveSevereErrors || regret<BeginnerPolicy.severeRegretCp else{continue}}
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
