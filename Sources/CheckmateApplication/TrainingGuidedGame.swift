import CheckmateAssets
import CheckmateDomain
import CheckmateRules
/// A moment from the learner's own guided game that exact detectors found (plan: guided games/review): a mate in
/// one that was missed, or a move that allowed one. Positions from a full game were never certified offline, so only
/// these exact mate-in-one detectors score a retry; nothing else is graded.
public struct TrainingMoment:Equatable {
    public enum Kind:String {case mateFind="mate-find",mateAvoid="mate-avoid"}
    /// `ply`: the index in the game line of the learner's move; `fen`: the position before it; `played`: its SAN.
    public let kind:Kind,ply:Int,fen:String,played:String
    /// The move number is the position's own (its FEN's fullmove field): a game may start after move one.
    public var label:String {
        let move=Self.moveNumber(fen:fen,ply:ply)
        switch kind {
        case .mateFind:return String(localized:"At move \(move) you had a checkmate, and played \(played).",bundle:.checkmate)
        case .mateAvoid:return String(localized:"At move \(move), after \(played), your opponent could checkmate at once.",bundle:.checkmate)
        }
    }
    /// The move number of the position `fen` (its fullmove field), or one counted from `ply` when the field is missing.
    static func moveNumber(fen:String,ply:Int)->Int {fen.split(separator:" ").dropFirst(5).first.flatMap{Int($0)} ?? ply/2+1}
}
/// Guided games (plan: guided games/review): ordinary legal chess from a reviewed start against a gentle practice
/// opponent. Habits are noted after the learner's move as things worth reviewing, never as wrong moves; up to two
/// exact moments are kept for retrying after the game.
@MainActor enum TrainingGuidedGame {
    static let maximumMoments=2
    /// A heuristic note on the learner's move, or nil. Development, castling rights and a piece left where it can be
    /// taken are worth reviewing; none of them makes the move wrong, and many sound moves will draw no note.
    /// `takers`: the opponent's pieces that can legally capture the moved piece now (pinned pieces and a king that
    /// would step into check cannot). `defended`: every such capture can be legally taken back where it lands.
    static func habit(before:Position,after:Position,played:MoveOutcome,beforeFEN:String,afterFEN:String,learner:String,ply:Int,takers:Set<String>,defended:Bool)->String? {
        let mine=Character(learner)
        let rights:(String)->Bool={fen in let field=fen.split(separator:" ").dropFirst(2).first.map(String.init) ?? "-";return field.contains{$0 != "-" && ($0.isUppercase == (learner=="w"))}}
        let castled=played.from==(learner=="w" ? "e1":"e8") && ["c","g"].contains(played.to.first) && before[played.from]==learner+"k"
        if rights(beforeFEN),!rights(afterFEN),!castled{return String(localized:"Worth reviewing: your king can no longer castle. Castling is often the quickest way to a safe king.",bundle:.checkmate)}
        if let piece=after[played.to],piece.last != "k" {
            if !takers.isEmpty,!defended || takers.contains(where:{TrainingMaterial.value(after[$0]!)<TrainingMaterial.value(piece)}) {
                return String(localized:"Worth reviewing: your \(PieceName.of(String(piece.last!))) on \(played.to) can be taken. Is it protected well enough?",bundle:.checkmate)
            }
        }
        let home:[String]=learner=="w" ? ["b1","g1","c1","f1"]:["b8","g8","c8","f8"]
        let undeveloped=home.filter{square in after[square].map{$0.first==mine && "nb".contains($0.last!)} ?? false}.count
        // Early in the game by the position's own move number: a game may start after move one.
        if TrainingMoment.moveNumber(fen:beforeFEN,ply:ply)<=6,undeveloped>=2,before[played.from]==learner+"q" {return String(localized:"Worth reviewing: early in the game, bringing out knights and bishops before the queen usually helps.",bundle:.checkmate)}
        return nil
    }
    /// The retry for a moment: find a checkmate (every mating move is accepted), or play a move after which the
    /// opponent has no mate in one (every such move is accepted; each other move shows its mating reply).
    static func scenario(_ moment:TrainingMoment,source:TrainingScenario,attempt:String,runtimeFactory:(() throws -> any ChessScriptRuntime)?)throws -> TrainingScenario {
        let legality=try TrainingLegality(fen:moment.fen,runtimeFactory:runtimeFactory),learner=try legality.turn(),fingerprint=try legality.fingerprint()
        // Made at runtime from the learner's own game by an exact detector: generated, not reviewed content.
        let generation=TrainingGeneration(generator:"guided-moment",version:1,seed:"\(attempt):\(moment.ply)",candidates:1)
        let base=TrainingScenario(id:"moment-\(attempt.lowercased())-\(moment.ply)",entry:source.entry,variant:moment.kind.rawValue,tier:1,cluster:"moment-"+fingerprint,learner:learner,prompt:"",explanation:"",hints:[],fen:moment.fen,check:.moment)
        let accepted:[String],replies:[String:String]
        switch moment.kind {
        case .mateFind:accepted=try legality.matingMoves().sorted();replies=[:]
        case .mateAvoid:let found=try TrainingContinuationValidator(runtimeFactory:runtimeFactory).threat(base,create:false);accepted=found.accepted.sorted();replies=found.replies
        }
        let find=moment.kind == .mateFind
        return TrainingScenario(id:base.id,entry:base.entry,variant:base.variant,tier:1,cluster:base.cluster,learner:learner,
            prompt:find ? String(localized:"From your game: a checkmate was possible here. Find it.",bundle:.checkmate):String(localized:"From your game: play a move that does not allow checkmate next move.",bundle:.checkmate),
            explanation:find ? String(localized:"Before any other move, look at every check you can give: one of them may end the game.",bundle:.checkmate):String(localized:"Before you move, look at every check your opponent could give after it.",bundle:.checkmate),
            hints:find ? [String(localized:"Look at every check you can give.",bundle:.checkmate),String(localized:"Which check leaves the king no square, no block and no capture?",bundle:.checkmate)]:[String(localized:"Which of your opponent's checks would be mate?",bundle:.checkmate),String(localized:"Cover that square, give the king room, or stop the checking piece.",bundle:.checkmate)],
            fen:moment.fen,generation:generation,check:.moment,nodes:[TrainingTeachingNode(fingerprint:fingerprint,accepted:accepted,replies:replies)])
    }
}
extension TrainingController {
    /// Notes the learner's move in a guided game: a habit worth reviewing, and an exact moment while there is room.
    func noteGuided(_ state:inout Exercise,before:TrainingLegality,played:MoveOutcome,after:TrainingLegality)throws {
        guard state.scenario.check == .guidedGame else{return}
        let ply=state.line.count-1
        if state.moments.count<TrainingGuidedGame.maximumMoments {
            if !played.checkmate,!(try before.matingMoves()).isEmpty{state.moments.append(TrainingMoment(kind:.mateFind,ply:ply,fen:before.fen,played:played.san))}
            // Only when some move would have prevented the mate: otherwise the retry has no answer.
            else if !played.checkmate,try after.automaticDraw()==nil,!(try after.matingMoves()).isEmpty,try before.outcomes().contains(where:{try TrainingLegality(fen:$0.after,runtimeFactory:runtimeFactory).matingMoves().isEmpty}){state.moments.append(TrainingMoment(kind:.mateAvoid,ply:ply,fen:before.fen,played:played.san))}
        }
        let captures=try after.outcomes().filter{$0.captured != nil && ($0.to==played.to || $0.flags.contains("e"))}
        // A recapture must be legal, and lands where the capture did (en passant does not land on the moved pawn).
        let defended=try captures.allSatisfy{capture in try TrainingLegality(fen:capture.after,runtimeFactory:runtimeFactory).outcomes().contains{$0.to==capture.to && $0.captured != nil}}
        state.habit=TrainingGuidedGame.habit(before:try before.board(),after:try after.board(),played:played,beforeFEN:before.fen,afterFEN:after.fen,learner:state.scenario.learner,ply:ply,takers:Set(captures.map(\.from)),defended:defended)
    }
    /// Ends a guided game by choice: nothing is won or lost, and its moments can be reviewed.
    public func endGuidedGame(){
        guard interactive,var state=exercise,state.scenario.check == .guidedGame,!state.finished else{return}
        games.cancel();state.habit=nil
        state.feedback=state.moments.isEmpty ? String(localized:"Game ended. No moments to retry were found.",bundle:.checkmate):String(localized:"Game ended. Review a moment below and try it again.",bundle:.checkmate)
        // Not recorded: the game goes on, and a reply cancelled above is asked for again.
        if !finish(state,.abandoned){requestReply()}
    }
    /// Retries a moment from the finished guided game as its own exercise: practice from the learner's own game. The
    /// finished game is kept as `guidedReview`, so its other moments stay reachable.
    public func retryMoment(_ index:Int){
        guard interactive,let state=exercise,state.finished,state.moments.indices.contains(index) else{return}
        do {
            let scenario=try TrainingGuidedGame.scenario(state.moments[index],source:state.scenario,attempt:state.snapshot.id,runtimeFactory:runtimeFactory)
            try TrainingValidationService.validate(scenario,definition:state.definition,runtimeFactory:runtimeFactory)
            let prepared=PreparedTrainingExercise(definition:state.definition,scenario:scenario,freshness:.repeat,legality:try TrainingLegality(fen:state.moments[index].fen,runtimeFactory:runtimeFactory),resumed:nil,retry:true)
            guidedReview=state;begin(prepared)
        }catch{var shown=state;shown.feedback=String(localized:"This moment could not be prepared: \(userFacing(error))",bundle:.checkmate);exercise=shown;publish()}
    }
    /// Back from a moment's retry to the finished guided game it came from. An unfinished retry stays saved for Continue.
    public func returnToGuidedGame(){
        guard interactive,let review=guidedReview,exercise?.scenario.check == .moment else{return}
        games.cancel();exercise=review;go(.training(entry:review.definition.id));publish()
    }
}
