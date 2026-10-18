import Foundation
/// The rows of a position game's closed outcome matrix (mini-game plan D3), in precedence order: after each ply the
/// first row that matches decides the game; none matching, it goes on. `claimedDraw` is the learner's claim, which
/// ends the game where it is made.
public enum PositionGameRow:String,Codable,CaseIterable {
    case learnerGaveMate,learnerMated,stalemate,automaticDraw,claimedDraw,keptPieceLost,pawnCaptured,promotedPieceCaptured,promotedPieceHeld
    public var success:Bool {self == .learnerGaveMate || self == .promotedPieceHeld}
}
/// Where the learner's one pawn of a `promoteAndHold` game is, followed move by move from its square at the start
/// (plan D3: content has exactly one learner pawn there). Any promotion piece counts as the promoted piece.
public enum PositionGamePawn:Equatable {
    case pawn(String),promoted(String),pawnCaptured,promotedCaptured
    /// The tracked pawn or piece after `move`, played by `move.color`. An opponent's capture on its square, en passant
    /// included, takes it; the learner's own move from its square carries it along (a promotion makes it the new piece).
    public func after(_ move:MoveOutcome,learner:String)->Self {
        switch self {
        case .pawn(let square),.promoted(let square):
            let promoted:Bool={if case .promoted=self{return true};return false}()
            if move.color==learner {
                guard move.from==square else{return self}
                return promoted || move.promotion != nil ? .promoted(move.to):.pawn(move.to)
            }
            // En passant takes the pawn beside the capturing pawn's destination: its file, the capturing pawn's rank.
            let taken=move.flags.contains("e") ? String(move.to.prefix(1))+String(move.from.suffix(1)):move.to
            return move.captured != nil && taken==square ? (promoted ? .promotedCaptured:.pawnCaptured):self
        case .pawnCaptured,.promotedCaptured:return self
        }
    }
}
public enum PositionGameReferee {
    /// The piece types a game may keep: never the king, whose loss is not a capture.
    public static let keepable=["q","r","b","n","p"]
    static let names=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen"]
    /// The first matching row after a ply `mover` just played (plan D3), or nil while the game goes on. `checkmate`,
    /// `stalemate` and `automaticDraw` describe the position reached; `board` is it; `pawn` is the tracked pawn of a
    /// `promoteAndHold` game. The learner's claim is not a ply: it is `claimedDraw`, decided where it is made.
    public static func judge(goal:TrainingGoal.Kind,keep:[String],learner:String,mover:String,checkmate:Bool,stalemate:Bool,automaticDraw:String?,board:Position,pawn:PositionGamePawn?)->PositionGameRow? {
        if checkmate{return mover==learner ? .learnerGaveMate:.learnerMated}
        if stalemate{return .stalemate}
        if automaticDraw != nil{return .automaticDraw}
        if lostKeep(keep,learner:learner,board:board) != nil{return .keptPieceLost}
        guard goal == .promoteAndHold,let pawn else{return nil}
        switch pawn {
        case .pawnCaptured:return .pawnCaptured
        case .promotedCaptured:return .promotedPieceCaptured
        case .promoted:return mover==learner ? nil:.promotedPieceHeld
        case .pawn:return nil
        }
    }
    /// The first kept piece type the learner no longer has on `board`.
    public static func lostKeep(_ keep:[String],learner:String,board:Position)->String? {keep.first{!board.values.contains(learner+$0)}}
    /// What the learner reads when a row ends the game. `mover` played the last ply; `explanation` follows a success.
    public static func message(_ row:PositionGameRow,mover:String,learner:String,explanation:String,keep:[String]=[],board:Position=[:],reason:String?=nil)->String {
        switch row {
        case .learnerGaveMate:return "Checkmate! "+explanation
        case .promotedPieceHeld:return "You promoted the pawn and kept the new piece. "+explanation
        case .learnerMated:return "You were checkmated."
        case .stalemate:return mover==learner ? "Stalemate: your opponent has no legal move and is not in check, so the game is a draw.":"Stalemate: you have no legal move and are not in check, so the game is a draw."
        case .automaticDraw:return "The game is drawn: \(reason ?? "it cannot go on")."
        case .claimedDraw:return "Draw claimed by \(reason ?? "the rules"). That is a draw, so this one is not solved."
        case .keptPieceLost:let name=lostKeep(keep,learner:learner,board:board).flatMap{names[$0]} ?? "piece";return "You lost your last \(name), and this game cannot be won without it. Keep it protected, or out of reach."
        case .pawnCaptured:return "Your pawn was captured before it could promote."
        case .promotedPieceCaptured:return "Your opponent captured the new piece at once. Promote where it is safe, or protect the square first."
        }
    }
}
/// The opponent levels of standard-rule training games (plan D4), shown by name, never as an Elo number: `UCI_Elo` is
/// calibrated on full games, not on small endings.
public enum TrainingOpponentLevel:String,Codable,CaseIterable {
    case gentle,steady,strong
    public var title:String {switch self{case .gentle:return "Gentle";case .steady:return "Steady";case .strong:return "Strong"}}
}
/// How far each level searches (plan D4): every search is node-limited, so a level is the same work on every Mac, as
/// network hints already are (assistance plan A5). Not yet calibrated (WI-016); a change bumps `version`.
public enum TrainingOpponentPolicy {
    public static let version=1
    /// Gentle is the regret-bounded beginner opponent: each of its searches has this many nodes, and a decision (the
    /// root and at most `BeginnerPolicy.explorationCount` constrained searches) at most `gentleDecisionNodes`.
    public static let gentleSearchNodes=60_000
    public static var gentleDecisionNodes:Int {gentleSearchNodes*(1+BeginnerPolicy.explorationCount)}
    /// Steady (skill 3) and Strong (skill 20) make one search of this many nodes.
    public static let engineNodes=250_000
    /// The search an attempt saved before levels existed finishes with: today's, at its coded strength.
    public static let legacyMilliseconds=300
    public static func skill(_ level:TrainingOpponentLevel)->Int? {switch level{case .gentle:return nil;case .steady:return 3;case .strong:return 20}}
}
/// A search limit as saved: `{"nodes": n}` or `{"movetime": ms}`.
extension EngineSearchLimit:Codable {
    private enum CodingKeys:String,CodingKey {case nodes,movetime}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        guard c.allKeys.count==1 else{throw DecodingError.dataCorrupted(.init(codingPath:c.codingPath,debugDescription:"A search limit names nodes or a time."))}
        if let nodes=try c.decodeIfPresent(Int.self,forKey:.nodes){self = .nodes(nodes)}else{self = .movetime(try c.decode(Int.self,forKey:.movetime))}
    }
    public func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        switch self {case .nodes(let nodes):try c.encode(nodes,forKey:.nodes);case .movetime(let milliseconds):try c.encode(milliseconds,forKey:.movetime)}
    }
}
/// The opponent an attempt at a standard-rule game froze when it started (plan D4), saved beside its scenario. No
/// setting changes it afterwards.
/// - `attempt` is the attempt's id: a configuration naming another attempt (an older build replaced the attempt and
///   wrote the unknown field back by path) is ignored, and that attempt plays as one saved before levels.
/// - `witness` is the attempt's revision at this build's last save. An older build that continued the attempt advanced
///   the revision without it, so the attempt is then marked `mixed` for good; it keeps playing at its level.
/// - `legacy` is an attempt saved before levels existed: it finishes with exactly the search it began with.
/// - `severeStreak` is Gentle's run of severe mistakes, so a resumed attempt continues it.
public struct TrainingOpponentConfiguration:Codable,Equatable {
    public enum Strategy:String,Codable {case beginner,engine,legacy}
    public var attempt:String,strategy:Strategy,profile:String,limit:EngineSearchLimit,seed:String,policyVersion:Int,severeStreak:Int,witness:Int
    /// An older build moved this attempt's board; absent when it has not.
    public var mixed:Bool?
    public init(attempt:String,strategy:Strategy,profile:String,limit:EngineSearchLimit,seed:String,policyVersion:Int=TrainingOpponentPolicy.version,severeStreak:Int=0,witness:Int,mixed:Bool?=nil){self.attempt=attempt;self.strategy=strategy;self.profile=profile;self.limit=limit;self.seed=seed;self.policyVersion=policyVersion;self.severeStreak=severeStreak;self.witness=witness;self.mixed=mixed}
    /// A new attempt's opponent at `level`.
    public static func frozen(_ level:TrainingOpponentLevel,attempt:String,seed:UInt64,revision:Int=0)->Self {
        level == .gentle ? Self(attempt:attempt,strategy:.beginner,profile:level.rawValue,limit:.nodes(TrainingOpponentPolicy.gentleSearchNodes),seed:String(seed,radix:16),witness:revision)
            :Self(attempt:attempt,strategy:.engine,profile:level.rawValue,limit:.nodes(TrainingOpponentPolicy.engineNodes),seed:String(seed,radix:16),witness:revision)
    }
    /// An attempt saved before levels existed: today's search to the end.
    public static func legacy(attempt:String,revision:Int)->Self {Self(attempt:attempt,strategy:.legacy,profile:"legacy",limit:.movetime(TrainingOpponentPolicy.legacyMilliseconds),seed:"",witness:revision)}
    public var level:TrainingOpponentLevel? {TrainingOpponentLevel(rawValue:profile)}
    /// Whether this build can play it exactly as frozen; one it cannot is ignored, never guessed at.
    public var valid:Bool {
        guard (1...64).contains(attempt.count),(0...BeginnerPolicy.maximumConsecutiveSevereErrors).contains(severeStreak),(0...TrainingState.maximumCount).contains(witness),policyVersion>=1,seed.count<=16,seed.isEmpty || UInt64(seed,radix:16) != nil else{return false}
        switch (strategy,limit) {
        case (.beginner,.nodes(let nodes)):return level == .gentle && nodes>0 && !seed.isEmpty
        case (.engine,.nodes(let nodes)):return (level == .steady || level == .strong) && nodes>0
        case (.legacy,.movetime(let milliseconds)):return profile=="legacy" && milliseconds==TrainingOpponentPolicy.legacyMilliseconds
        default:return false
        }
    }
    /// The search policy a record names: `mixed` when an older build played part of the attempt, else the search
    /// every reply ran, so no policy is attributed to a search it did not run.
    public var policy:String {
        if mixed==true{return "mixed"}
        switch (strategy,limit) {
        case (.beginner,.nodes(let nodes)):return "beginner-v\(BeginnerPolicy.version)-nodes-\(nodes)x\(1+BeginnerPolicy.explorationCount)"
        case (.engine,.nodes(let nodes)):return "skill-\(level.flatMap(TrainingOpponentPolicy.skill) ?? 20)-nodes-\(nodes)"
        default:return "legacy"
        }
    }
}
public extension TrainingSessionSnapshot {
    /// The frozen opponent this build trusts for the attempt: nil when there is none, it names another attempt or it
    /// cannot be played as frozen; marked `mixed` when the attempt was saved since without it (its witness is behind).
    var boundOpponent:TrainingOpponentConfiguration? {
        guard var own=opponent,own.attempt==id,own.valid else{return nil}
        if own.witness != revision{own.mixed=true}
        return own
    }
    /// The opponent a saved attempt resumes, and is recorded, with: its own (`boundOpponent`). None means it began
    /// before levels (or an older build began it): with position games on it continues as legacy, so its record says
    /// so; with them off it plays today's search and nothing new is written.
    var settledOpponent:TrainingOpponentConfiguration? {
        if let own=boundOpponent{return own}
        guard TrainingRolloutPolicy.positionGamesEnabled,scenario.check?.task == .game else{return nil}
        return .legacy(attempt:id,revision:revision)
    }
}
public extension TrainingAttempt {
    /// How a finished attempt's opponent is described: its level, "legacy strength" for an attempt begun before levels,
    /// mixed when an older build played part of it, "level not recorded" when the record has none (a game without an
    /// opponent level, or one an older build saved again without the field).
    var levelLabel:String {TrainingOpponentConfiguration.label(level:level,policy:levelPolicy)}
}
public extension TrainingOpponentConfiguration {
    /// The label of a level and the policy a record names (`TrainingAttempt.levelLabel`).
    static func label(level:String?,policy:String?)->String {
        guard let level else{return "Level not recorded"}
        let title=TrainingOpponentLevel(rawValue:level)?.title ?? (level=="legacy" ? "Legacy strength":level)
        return policy=="mixed" ? title+", mixed: an older version of Checkmate played part of this game":title
    }
    /// This opponent as its record will describe it.
    var label:String {Self.label(level:profile,policy:policy)}
}
