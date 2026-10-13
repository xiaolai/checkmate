import Foundation
/// A lesson's own exercise: the position its invitation step ("Now try it yourself") shows, played on that step's
/// board against the computer. Authored with the lesson in the course content (`practice`), where the content check
/// (Tools/prepare-lesson-scripts.py) and the independent audit (Tools/audit-lesson-rules.py) verify it.
public struct LessonPractice:Codable,Equatable {
    public let fen:String,goal:String
    /// The invitation beat whose board is this position.
    public let beat:String?
    /// An optional forced opening: the moves that follow the taught idea, with the computer's authored answers.
    public let teaching:[LessonTeachingNode]?
    /// What counts as doing it, in any order (an authored opening comes first by construction).
    public let checkpoints:[LessonCheckpoint]?
    /// Who answers outside the authored opening before the exercise is done.
    public let opponent:LessonOpponent?
    /// Two hints in words; the third stage shows a move.
    public let hints:[String]?
    /// Feedback for a legal move that leaves the taught idea.
    public let offTrack:String?
    /// Feedback for particular wrong or impossible moves, by UCI.
    public let mistakes:[String:String]?
    public let success:String?
    public init(fen:String,goal:String,beat:String?=nil,teaching:[LessonTeachingNode]?=nil,checkpoints:[LessonCheckpoint]?=nil,opponent:LessonOpponent?=nil,hints:[String]?=nil,offTrack:String?=nil,mistakes:[String:String]?=nil,success:String?=nil){self.fen=fen;self.goal=goal;self.beat=beat;self.teaching=teaching;self.checkpoints=checkpoints;self.opponent=opponent;self.hints=hints;self.offTrack=offTrack;self.mistakes=mistakes;self.success=success}
    /// Whether the invitation step can be played: it names its beat and says what counts as doing it.
    public var playable:Bool {beat != nil && !(checkpoints ?? []).isEmpty}
    /// Identifies what an attempt was judged against: the position, the opening and the checkpoints. Wording may change
    /// without restarting a saved attempt; a change to any of these starts it again.
    public var definitionID:String {
        struct Rules:Encodable {let fen:String,teaching:[LessonTeachingNode],checkpoints:[LessonCheckpoint.Kind],opponent:LessonOpponent}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=(try? encoder.encode(Rules(fen:fen,teaching:teaching ?? [],checkpoints:(checkpoints ?? []).map(\.kind),opponent:opponent ?? .beginner))) ?? Data()
        return ProgressMigration.digest(String(decoding:data,as:UTF8.self))
    }
}
/// One position of the authored opening, White to move. A learner move in `accepted` follows the idea; its reply (if
/// any) is the computer's answer and `next` the node after it; an accepted move without `next` completes the opening.
/// A move not accepted is off track; a reply for it, if authored, shows why before the learner undoes it.
public struct LessonTeachingNode:Codable,Equatable {
    /// Piece placement and side to move (the first two FEN fields) of this node's position.
    public let fingerprint:String
    public let accepted:[String]
    public let replies:[String:String]?
    public let next:[String:Int]?
    public init(fingerprint:String,accepted:[String],replies:[String:String]?=nil,next:[String:Int]?=nil){self.fingerprint=fingerprint;self.accepted=accepted;self.replies=replies;self.next=next}
}
public struct LessonCheckpoint:Codable,Equatable {
    public enum Kind:String,Codable,CaseIterable {case graph,castle,enPassant,promote,pawnAdvance,pawnCapture,attackQueen,mate}
    public let kind:Kind,label:String
    /// For a tactic's opening: the tactic and the material it must win. Read by the content audit only.
    public let tactic:String?,gain:Int?
    public init(kind:Kind,label:String,tactic:String?=nil,gain:Int?=nil){self.kind=kind;self.label=label;self.tactic=tactic;self.gain=gain}
}
public enum LessonOpponent:String,Codable {
    /// Stockfish choosing among reasonable moves with beginner-sized mistakes (`BeginnerOpponent`).
    case beginner
    /// Stockfish at full strength with a short think: it resists a mate instead of walking into one.
    case defender
}
/// A saved lesson attempt. Only what the learner did is stored; where it stands (checkpoints, success, the opening
/// node) is worked out again by replaying it, so a saved flag can never claim more than the moves show.
public struct LessonAttemptRecord:Codable,Equatable {
    public static let maximumMoves=600
    /// The `LessonPractice.definitionID` the moves were played against.
    public var definition:String
    /// Identifies this attempt across restarts, for replies and promotion choices bound to it.
    public var id:String
    /// Every move from the practice position, both sides, in UCI.
    public var moves:[String]
    /// Whether the learner chose to play on after doing the exercise.
    public var playOn:Bool
    /// Hint stages shown during this attempt (0–3); 3 means a move was shown.
    public var hints:Int
    public init(definition:String,id:String=UUID().uuidString,moves:[String]=[],playOn:Bool=false,hints:Int=0){self.definition=definition;self.id=id;self.moves=moves;self.playOn=playOn;self.hints=hints}
}
