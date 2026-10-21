import CheckmateAssets
import CheckmateDomain
import CheckmateRules
import Foundation
/// Where a lesson attempt stands, worked out by replaying its moves against the lesson's practice definition. Nothing
/// here is saved: a record holds only moves, so success can never be claimed beyond what they show.
public struct LessonAttemptJudgement:Equatable {
    public enum Phase:String,Equatable {
        /// White to move, the exercise not yet done.
        case yourTurn
        /// Black to move, the exercise not yet done: the computer answers.
        case computerTurn
        /// The learner's last move left the taught idea; it is undone to go on.
        case offTrack
        /// The exercise can no longer be done in this game (it ended, or a needed move became impossible).
        case failed
        /// Every checkpoint is done. The game waits until the learner chooses to play on.
        case achieved
        /// After success, the game continues against the beginner opponent.
        case playingOn
        /// After success, the game is over.
        case finished
    }
    public var phase:Phase
    /// Which checkpoints are done, in the definition's order.
    public var done:[Bool]
    /// What the learner should read now: the off-track or failure reason, or the success text.
    public var feedback:String?
    /// The authored-opening node the next White move is judged at, nil once the opening is over (or there is none).
    public var node:Int?
    /// The computer's authored answer due now (Black to move inside the opening, or a refutation of an off-track move).
    public var authoredReply:String?
    /// Whether the exercise was done at some point of these moves (success stays, even after a later loss).
    public var achieved:Bool
    /// The game's ending, if it is over.
    public var ending:(result:String,reason:String)?
    public static func == (a:Self,b:Self)->Bool {a.phase==b.phase && a.done==b.done && a.feedback==b.feedback && a.node==b.node && a.authoredReply==b.authoredReply && a.achieved==b.achieved && a.ending?.result==b.ending?.result && a.ending?.reason==b.ending?.reason}
}
public enum LessonAttemptJudge {
    /// The FEN fields an opening node is identified by: piece placement and side to move.
    /// Authored `mistakes`, `offTrack` and word hints describe the starting position; later decisions get these.
    static let genericOffTrack=String(localized:"That move is legal, but it leaves the idea of this exercise. Undo it and try again.",bundle:.checkmate)
    static let laterOffTrack=String(localized:"That move is legal, but it misses the follow-up. Undo it and look again, or ask for a hint.",bundle:.checkmate)
    public static func fingerprint(_ fen:String)->String {fen.split(separator:" ").prefix(2).joined(separator:" ")}
    /// Replays `moves` from the practice position. Throws when a move is illegal or contradicts an authored reply: such a
    /// record was not produced by this definition and must not be judged.
    public static func judge(_ practice:LessonPractice,moves:[String],playOn:Bool,rules:ChessRules)throws -> LessonAttemptJudgement {
        try rules.load(practice.fen)
        let teaching=practice.teaching ?? [],checkpoints=practice.checkpoints ?? []
        var node:Int?=teaching.isEmpty ? nil:0,openingDone=teaching.isEmpty,pendingNext:Int?,pendingReply:String?
        var done=[Bool](repeating:false,count:checkpoints.count),achieved=false
        var offTrack:(index:Int,text:String,refutation:String?)?
        var failure:String?
        for (index,uci) in moves.enumerated() {
            guard offTrack==nil || offTrack!.refutation != nil && index==offTrack!.index+1 && uci==offTrack!.refutation else{throw CheckmateError.invalid(String(localized:"The saved attempt continues past a move that left the exercise.",bundle:.checkmate))}
            guard failure==nil || achieved else{throw CheckmateError.invalid(String(localized:"The saved attempt continues after the exercise ended.",bundle:.checkmate))}
            let white=rules.turn=="w"
            if !white,let expected=pendingReply {guard uci==expected else{throw CheckmateError.invalid(String(localized:"The saved attempt does not follow the authored reply.",bundle:.checkmate))}}
            // The opening is judged only where it was authored: a position that differs means the content and this
            // record do not belong together, and no success is invented from it.
            if white,!openingDone,offTrack==nil,let current=node {guard fingerprint(rules.fen)==teaching[current].fingerprint else{throw CheckmateError.invalid(String(localized:"The authored opening does not match the position at node \(current).",bundle:.checkmate))}}
            let record=try rules.move(uci:uci)
            if offTrack != nil{continue}
            if white {
                if let current=node,!openingDone {
                    let position=teaching[current]
                    if position.accepted.contains(uci) {
                        if let following=position.next?[uci] {pendingNext=following;pendingReply=position.replies?[uci]}else{openingDone=true;node=nil;pendingNext=nil;pendingReply=nil}
                    } else {
                        offTrack=(index,index==0 ? practice.mistakes?[uci] ?? practice.offTrack ?? genericOffTrack:laterOffTrack,position.replies?[uci]);continue
                    }
                }
                // Checkpoints may be done in any order; the authored opening, when there is one, comes first by construction.
                if !achieved {
                    for (i,checkpoint) in checkpoints.enumerated() where !done[i] && satisfied(checkpoint.kind,record:record,openingDone:openingDone,rules:rules){done[i]=true}
                    if !checkpoints.isEmpty && !done.contains(false) {achieved=true}
                }
            } else {
                pendingReply=nil;if let following=pendingNext{node=following;pendingNext=nil}
            }
            if !achieved,failure==nil {
                if rules.over {failure=endingText(rules,stalemateFails:checkpoints.contains{$0.kind == .mate})}
                else if let impossible=checkpoints.indices.lazy.filter({!done[$0]}).compactMap({impossible(checkpoints[$0].kind,rules:rules,afterWhite:white)}).first {failure=impossible}
            }
        }
        if offTrack==nil,!openingDone,rules.turn=="w",let current=node {guard fingerprint(rules.fen)==teaching[current].fingerprint else{throw CheckmateError.invalid(String(localized:"The authored opening does not match the position at node \(current).",bundle:.checkmate))}}
        let over=rules.over,ending=over ? rules.ending:nil
        var judgement=LessonAttemptJudgement(phase:.yourTurn,done:done,feedback:nil,node:openingDone ? nil:node,authoredReply:nil,achieved:achieved,ending:ending)
        if let offTrack {
            judgement.phase = .offTrack;judgement.feedback=offTrack.text
            // A refutation that ends the game says so: the real result, not only that the move left the idea.
            if over{judgement.phase = .failed;judgement.feedback=offTrack.text+" "+endingText(rules,stalemateFails:checkpoints.contains{$0.kind == .mate});return judgement}
            // The refutation is shown once: due while Black is to move right after the off-track move.
            if let reply=offTrack.refutation,moves.count==offTrack.index+1{judgement.authoredReply=reply}
            return judgement
        }
        if achieved {
            judgement.feedback=practice.success
            judgement.phase=over ? (playOn ? .finished:.achieved):playOn ? .playingOn:.achieved
            if over,playOn{judgement.feedback=endingText(rules,stalemateFails:false)}
            return judgement
        }
        if let failure {judgement.phase = .failed;judgement.feedback=failure;return judgement}
        judgement.phase=rules.turn=="w" ? .yourTurn:.computerTurn
        if rules.turn=="b"{judgement.authoredReply=pendingReply}
        return judgement
    }
    static func satisfied(_ kind:LessonCheckpoint.Kind,record:MoveRecord,openingDone:Bool,rules:ChessRules)->Bool {
        switch kind {
        case .graph:return openingDone
        case .castle:return record.flags.contains("k") || record.flags.contains("q")
        case .enPassant:return record.flags.contains("e")
        case .promote:return record.promotion != nil
        case .pawnAdvance:return record.piece=="p" && record.captured==nil
        case .pawnCapture:return record.piece=="p" && record.captured != nil
        case .attackQueen:guard let queen=rules.board.first(where:{$0.value=="bq"})?.key else{return true};return !rules.attackers(queen,"w").isEmpty
        case .mate:return rules.checkmate
        }
    }
    /// Why the next checkpoint can no longer be reached in this game, if it cannot.
    static func impossible(_ kind:LessonCheckpoint.Kind,rules:ChessRules,afterWhite:Bool)->String? {
        let fields=rules.fen.split(separator:" "),castling=fields.count>2 ? String(fields[2]):"-",whitePawns=rules.board.values.contains("wp")
        switch kind {
        case .castle:return castling.contains("K") || castling.contains("Q") ? nil:String(localized:"Your king or rook has moved, so White can no longer castle in this game. Undo your moves or start again.",bundle:.checkmate)
        case .enPassant:return afterWhite ? String(localized:"An en passant capture is only possible on the move straight after the double step. Undo and capture en passant now.",bundle:.checkmate):nil
        case .promote,.pawnCapture:return whitePawns ? nil:String(localized:"White has no pawns left, so this can no longer happen in this game. Undo your moves or start again.",bundle:.checkmate)
        default:return nil
        }
    }
    static func endingText(_ rules:ChessRules,stalemateFails:Bool)->String {
        if rules.checkmate {return rules.turn=="b" ? String(localized:"Checkmate. You win!",bundle:.checkmate):String(localized:"Checkmate. The computer won this game. Undo your moves or start again.",bundle:.checkmate)}
        if rules.stalemate {return stalemateFails ? String(localized:"Stalemate: Black has no legal move, but the king is not in check, so the game is a draw. Undo your last move and leave the king a square.",bundle:.checkmate):String(localized:"Stalemate: the side to move has no legal move but is not in check. The game is a draw.",bundle:.checkmate)}
        if rules.insufficientMaterial {return String(localized:"Draw: neither side has enough pieces left to checkmate.",bundle:.checkmate)}
        return rules.ending.map{String(localized:"Draw: \($0.reason)",bundle:.checkmate,comment:"The reason is a phrase, such as threefold repetition")} ?? String(localized:"Draw: the game cannot go on.",bundle:.checkmate)
    }
}
