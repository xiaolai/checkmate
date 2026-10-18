import Foundation

/// One proved statement about a finished mini-game, shown as text after it (plan D5). Nothing is assessed: the game is
/// over, and every fact comes from an exact `MiniGameProof` answer with a line the referee replays.
public struct MiniGameFact:Equatable {
    public enum Kind:String {case forcedWin,allowedWin}
    public let kind:Kind
    /// The position the fact is about is the game's position before its move at `ply` (0 is the start); `side` moved
    /// there. `plies` is the proved distance: the side's own win (`forcedWin`), or the opponent's after that move.
    public let ply:Int,side:String,plies:Int
    /// `forcedWin`: the proof's line from that position. `allowedWin`: the move played, then the opponent's line.
    public let line:[MiniGameMove]
    public let text:String,squares:[String]
}
/// The post-game review of one finished mini-game: a proof per position, searched from the end backwards within the
/// review's CPU budget, and the facts they prove for the learner (White against the computer; both sides otherwise).
public struct MiniGameReview:Equatable {
    public let kind:MiniGameKind
    /// The reviewed game's run (its opponent seed) and ply count, so a result is shown only for that game.
    public let run:String?,plies:Int
    /// Answers by ply; a ply with none was not reached within the budget.
    public let answers:[Int:MiniGameProofAnswer]
    public let facts:[MiniGameFact]
    public let nodes:Int,entries:Int
    /// Every position was searched: no budget or stop ended the review first.
    public let complete:Bool
    /// The saved history replays move by move under the referee. A review of one that does not proves nothing.
    public let consistent:Bool

    /// Every position of `game` from its earliest kept one, each with the history before it; nil when a recorded move
    /// does not lead from one position to the next.
    public static func positions(of game:MiniGameState)->[MiniGameState]? {
        let snapshots=game.history+[game.snapshot];var result:[MiniGameState]=[]
        for (index,snapshot) in snapshots.enumerated() {
            var state=game;state.snapshot=snapshot;state.history=Array(snapshots[..<index])
            if index>0 {var replay=result[index-1];guard let move=snapshot.lastMove,replay.play(move),replay.snapshot==snapshot else{return nil}}
            result.append(state)
        }
        return result
    }
    /// Reviews a finished game. `cpuSeconds` reads the CPU time the review has used so far (its owner's thread clock);
    /// `stop` is the owner's cancellation. Both are polled during each search.
    public static func run(_ game:MiniGameState,budget:Double=MiniGameProofBudget.reviewCPUSeconds,cpuSeconds:@escaping ()->Double,stop:@escaping ()->Bool)->MiniGameReview {
        guard !game.kind.solo,let positions=positions(of:game) else{return MiniGameReview(kind:game.kind,run:game.opponentSeed,plies:game.history.count,answers:[:],facts:[],nodes:0,entries:0,complete:false,consistent:false)}
        let complete=game.history.count<MiniGameState.maximumHistory,started=cpuSeconds()
        let over={stop() || cpuSeconds()-started>=budget}
        var proof=MiniGameProof(kind:game.kind),answers:[Int:MiniGameProofAnswer]=[:],finished=true
        for ply in positions.indices.reversed() {
            if over(){finished=false;break}
            let answer=proof.prove(positions[ply],historyComplete:complete,stop:over)
            if answer.exhausted && over(){finished=false;break}
            answers[ply]=answer
        }
        return MiniGameReview(kind:game.kind,run:game.opponentSeed,plies:game.history.count,answers:answers,facts:facts(positions,answers:answers,computer:game.computer),nodes:proof.nodes,entries:proof.entryCount,complete:finished,consistent:true)
    }
    static func facts(_ positions:[MiniGameState],answers:[Int:MiniGameProofAnswer],computer:Bool)->[MiniGameFact] {
        func name(_ side:String)->String {side=="w" ? "White":"Black"}
        func moves(_ plies:Int)->String {let count=(plies+1)/2;return "\(count) \(count==1 ? "move":"moves")"}
        var facts:[MiniGameFact]=[]
        for ply in positions.indices.dropLast() {
            let side=positions[ply].turn,number=ply/2+1
            guard !computer || side=="w",let before=answers[ply],let played=positions[ply+1].snapshot.lastMove else{continue}
            // A win the side already had two plies earlier is the same run: it is stated once, where it was first proved.
            if case .win(let plies)=before.result,plies>0,let line=before.line {
                var continuing=false;if ply>=2,case .win(_)?=answers[ply-2]?.result{continuing=true}
                if !continuing {
                    let text=computer ? "Move \(number): you had a forced win in \(moves(plies)) here.":"Move \(number): \(name(side)) had a forced win in \(moves(plies)) here."
                    facts.append(MiniGameFact(kind:.forcedWin,ply:ply,side:side,plies:plies,line:line,text:text,squares:line.first.map{[$0.from,$0.to]} ?? []))
                }
            }
            // The move let the opponent force a win only if, before it, the side was not already lost that quickly.
            guard let after=answers[ply+1],case .win(let plies)=after.result,plies>0,let line=after.line else{continue}
            let safeBefore:Bool
            switch before.result {case .win,.draw:safeBefore=true;case .loss:safeBefore=false;case .unknown:safeBefore=before.clearPlies>=plies+1}
            guard safeBefore else{continue}
            let opponent=side=="w" ? "b":"w",text=computer ? "Move \(number), \(played.from)–\(played.to): this move let the opponent force a win in \(moves(plies)).":"Move \(number), \(played.from)–\(played.to): this move let \(name(opponent)) force a win in \(moves(plies))."
            facts.append(MiniGameFact(kind:.allowedWin,ply:ply,side:side,plies:plies,line:[played]+line,text:text,squares:[played.from,played.to]+(line.first.map{[$0.from,$0.to]} ?? [])))
        }
        return facts
    }
}
