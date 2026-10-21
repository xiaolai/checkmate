import CheckmateAssets
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
    /// Reviews a game known by every move from its kind's start (a network game, protocol 1.3), whatever ended it:
    /// each position at its absolute ply, with the positions back to its last capture or pawn move (and the one before,
    /// which marks the boundary) as its history, all taken from the complete replay rather than from the referee's
    /// 256-position memory. A move the referee refuses makes the review inconsistent. Positions are made one at a time,
    /// as the search reaches them, so a long game costs memory by its stretches, not its square.
    public static func run(kind:MiniGameKind,moves:[MiniGameMove],budget:Double=MiniGameProofBudget.reviewCPUSeconds,cpuSeconds:@escaping ()->Double,stop:@escaping ()->Bool)->MiniGameReview {
        guard let replay=Replay(kind:kind,moves:moves) else{return MiniGameReview(kind:kind,run:nil,plies:moves.count,answers:[:],facts:[],nodes:0,entries:0,complete:false,consistent:false)}
        let started=cpuSeconds(),over={stop() || cpuSeconds()-started>=budget}
        var proof=MiniGameProof(kind:kind),answers:[Int:MiniGameProofAnswer]=[:],finished=true
        for ply in replay.snapshots.indices.reversed() {
            if over(){finished=false;break}
            let answer=proof.prove(replay.position(ply),historyComplete:true,stop:over)
            if answer.exhausted && over(){finished=false;break}
            answers[ply]=answer
        }
        return MiniGameReview(kind:kind,run:nil,plies:moves.count,answers:answers,facts:facts(turns:replay.snapshots.map(\.turn),played:moves,answers:answers,computer:false),nodes:proof.nodes,entries:proof.entryCount,complete:finished,consistent:true)
    }
    /// Every position of a game from its kind's start, replayed by the referee, and each one's draw context.
    struct Replay {
        let snapshots:[MiniGameSnapshot]
        /// The first ply of each position's stretch: after the last move that changed the material or the pawns.
        let stretch:[Int]
        private let base:MiniGameState
        /// Nil for a solo kind, or when the referee refuses one of the moves. Remembered while replaying, so a move after
        /// a repetition or 80-ply draw is refused exactly as in the game.
        init?(kind:MiniGameKind,moves:[MiniGameMove]){
            guard !kind.solo else{return nil}
            var replay=MiniGameState(kind:kind,computer:false);replay.opponentSeed=nil
            var snapshots=[replay.snapshot]
            for move in moves {guard replay.play(move) else{return nil};snapshots.append(replay.snapshot)}
            var stretch=[0]
            for ply in snapshots.indices.dropFirst() {
                let a=snapshots[ply-1].board,b=snapshots[ply].board
                stretch.append(a.count==b.count && a.filter{$0.value.hasSuffix("p")}==b.filter{$0.value.hasSuffix("p")} ? stretch[ply-1]:ply)
            }
            self.snapshots=snapshots;self.stretch=stretch;base=replay
        }
        /// The position before the move at `ply` (0 is the start), with its stretch and the position before it, which
        /// marks the boundary, as its history: everything the referee and the proof's draw context read.
        func position(_ ply:Int)->MiniGameState {var state=base;state.snapshot=snapshots[ply];state.history=Array(snapshots[max(0,stretch[ply]-1)..<ply]);return state}
    }
    static func facts(_ positions:[MiniGameState],answers:[Int:MiniGameProofAnswer],computer:Bool)->[MiniGameFact] {
        facts(turns:positions.map(\.turn),played:positions.dropFirst().compactMap(\.snapshot.lastMove),answers:answers,computer:computer)
    }
    /// `turns[ply]` is the side to move at each position, `played[ply]` the move made there.
    static func facts(turns:[String],played made:[MiniGameMove],answers:[Int:MiniGameProofAnswer],computer:Bool)->[MiniGameFact] {
        func name(_ side:String)->String {side=="w" ? String(localized:"White",bundle:.checkmate):String(localized:"Black",bundle:.checkmate)}
        func moves(_ plies:Int)->Int {(plies+1)/2}
        var facts:[MiniGameFact]=[]
        for ply in turns.indices.dropLast() {
            let side=turns[ply],number=ply/2+1
            guard !computer || side=="w",let before=answers[ply],ply<made.count else{continue}
            let played=made[ply]
            // A win the side already had two plies earlier is the same run: it is stated once, where it was first proved.
            if case .win(let plies)=before.result,plies>0,let line=before.line {
                var continuing=false;if ply>=2,case .win(_)?=answers[ply-2]?.result{continuing=true}
                if !continuing {
                    let text=computer ? String(localized:"Move \(number): you had a forced win in \(moves(plies)) moves here.",bundle:.checkmate):String(localized:"Move \(number): \(name(side)) had a forced win in \(moves(plies)) moves here.",bundle:.checkmate,comment:"The second value is the side to move, such as White")
                    facts.append(MiniGameFact(kind:.forcedWin,ply:ply,side:side,plies:plies,line:line,text:text,squares:line.first.map{[$0.from,$0.to]} ?? []))
                }
            }
            // The move let the opponent force a win only if, before it, the side was not already lost that quickly.
            guard let after=answers[ply+1],case .win(let plies)=after.result,plies>0,let line=after.line else{continue}
            let safeBefore:Bool
            switch before.result {case .win,.draw:safeBefore=true;case .loss:safeBefore=false;case .unknown:safeBefore=before.clearPlies>=plies+1}
            guard safeBefore else{continue}
            let opponent=side=="w" ? "b":"w",text=computer ? String(localized:"Move \(number), \(played.from)–\(played.to): this move let the opponent force a win in \(moves(plies)) moves.",bundle:.checkmate,comment:"The second and third values are board squares, such as e2 and e4"):String(localized:"Move \(number), \(played.from)–\(played.to): this move let \(name(opponent)) force a win in \(moves(plies)) moves.",bundle:.checkmate,comment:"The second and third values are board squares; the fourth is a side, such as White")
            facts.append(MiniGameFact(kind:.allowedWin,ply:ply,side:side,plies:plies,line:[played]+line,text:text,squares:[played.from,played.to]+(line.first.map{[$0.from,$0.to]} ?? [])))
        }
        return facts
    }
}
