import Foundation
/// Who wrote and who checked a curated scenario, and which validator accepted it. `reviewer` stays nil until an
/// editor has actually reviewed the content; machine validation is recorded separately as `validatorVersion`.
public struct TrainingReview:Codable,Equatable {
    public let author:String,reviewer:String?,validatorVersion:Int
    public init(author:String,reviewer:String?,validatorVersion:Int){self.author=author;self.reviewer=reviewer;self.validatorVersion=validatorVersion}
}
/// How a generated scenario was made, so the same concrete board can be stored and replayed (plan rule 5).
public struct TrainingGeneration:Codable,Equatable {
    public let generator:String,version:Int,seed:String,candidates:Int
    public init(generator:String,version:Int,seed:String,candidates:Int){self.generator=generator;self.version=version;self.seed=seed;self.candidates=candidates}
}
/// The authored oracle: what the author says is correct. Validation re-derives it with the exact evaluator and
/// rejects the scenario on any difference. It is never projected to agents or shown before an answer.
public struct TrainingExpected:Codable,Equatable {
    public var squares:[String]?,moves:[String]?,choice:String?,distance:Int?
    /// Every genuine answer when more than one choice is right (a diagnosis may have several genuine concerns).
    public var choices:[String]?
    /// Plausible attempts the author asserts are wrong (for example a pinned piece's move in Escape Check).
    public var wrong:[String]?
    public init(squares:[String]?=nil,moves:[String]?=nil,choice:String?=nil,distance:Int?=nil,wrong:[String]?=nil,choices:[String]?=nil){self.squares=squares;self.moves=moves;self.choice=choice;self.distance=distance;self.wrong=wrong;self.choices=choices}
}
/// The exact evaluator that grades an Increment B scenario (plan: Increment B objective contracts). Focused entries
/// fix it per variant; a mixed case names the evaluator of the position it reuses, under the unified predicate.
public enum TrainingCheck:String,Codable,CaseIterable {
    /// Keep the target piece through a bounded search (Save Your Piece).
    case defense
    /// Reach a material threshold through a bounded search; mate and draws by their own precedence.
    case material
    /// The sign of a stated line's resolved material change, as a choice.
    case exchange
    /// Castle (every legal castling move is accepted), or say why castling is not allowed.
    case castle,castleReason
    /// Promote a pawn (every legal promotion piece is accepted).
    case promotion
    /// Capture en passant, or say whether and why it is not allowed now.
    case enPassant,enPassantChoice
    /// Select every forking or every pinned piece of the asked colour.
    case forks,pins
    /// Make a move after which you threaten mate in one; make a move after which the opponent has none.
    case mateThreatCreate,mateThreatPrevent
    /// Increment A evaluators, reused by mixed cases with their own question format.
    case kingSquares,status
    /// Name a genuine concern in an unlabelled position, then meet a material objective.
    case diagnosis
    /// A playable game against the practice defender: a mating ending, or a guided game from a reviewed start.
    case ending,guidedGame
    /// A moment from the learner's own guided game, retried against exact mate-in-one detectors: find the mate that
    /// was missed, or play a move that does not allow one.
    case moment
    /// How the learner answers.
    public var task:TrainingTask {switch self {
        case .forks,.pins,.kingSquares:return .select
        case .exchange,.castleReason,.enPassantChoice,.status,.diagnosis:return .choose
        case .ending,.guidedGame:return .game
        default:return .move
    }}
}
public enum TrainingTask:String,Codable {case move,select,choose,game}
public extension MiniGameKind {
    /// Existing games grouped by the simplified rule they share, each family bridged by one normal-chess case:
    /// pawns that stay pawns (no promotion, no en passant), piece hunts where nothing captures back, the knight
    /// game, and the fixed knight route.
    var bridgeFamily:MiniGameKind {switch self {
        case .pawnDuel,.rooksAndPawns,.bishopsAndPawns,.queenVsPawns:return .pawnDuel
        case .rookSweep,.bishopSweep:return .rookSweep
        case .knightCapture:return .knightCapture
        case .knightCorners:return .knightCorners
    }}
}
public extension TrainingCheck {
    /// The evaluator a focused Increment B entry uses for each variant; nil for mixed practice, whose cases name it.
    static func focused(_ objective:TrainingObjectiveKind,variant:String)->TrainingCheck? {
        switch (objective,variant) {
        case (.saveYourPiece,_):return .defense
        case (.captureWisely,"compare-exchange"):return .exchange
        case (.captureWisely,_):return .material
        case (.specialMoves,"castle-legal"):return .castle
        case (.specialMoves,"castle-unavailable"):return .castleReason
        case (.specialMoves,"promotion"):return .promotion
        case (.specialMoves,"en-passant-available"):return .enPassant
        case (.specialMoves,"en-passant-unavailable"):return .enPassantChoice
        case (.simpleTactics,"fork-recognize"):return .forks
        case (.simpleTactics,"pin-recognize"):return .pins
        case (.simpleTactics,"mate-threat-create"):return .mateThreatCreate
        case (.simpleTactics,"mate-threat-prevent"):return .mateThreatPrevent
        case (.simpleTactics,_):return .material
        case (.finishTheGame,_):return .ending
        case (.guidedGame,"mate-find"),(.guidedGame,"mate-avoid"):return .moment
        case (.guidedGame,_):return .guidedGame
        default:return nil
        }
    }
    /// Evaluators a mixed case may use: one unified material predicate for moves, explicit questions otherwise.
    static let mixed:Set<TrainingCheck>=[.material,.exchange,.castleReason,.enPassantChoice,.forks,.pins,.kingSquares,.status,.diagnosis]
    /// Searched objectives: the published teaching graph is certified by the bounded search.
    var searched:Bool {[.defense,.material,.diagnosis].contains(self)}
}
/// A bounded outcome objective (plan: value/predicates). Material delta is the learner's advantage at the resolved
/// leaf minus that at the root (1/3/3/5/9). Mate takes precedence; a draw satisfies the goal only when `drawOK`.
public struct TrainingGoal:Codable,Equatable {
    public enum Kind:String,Codable {
        /// The tracked target is still on the board and delta >= threshold (normally 0).
        case survive
        /// Delta >= threshold, threshold > 0.
        case gain
        /// Delta >= threshold, threshold <= 0: give nothing away (the declined-capture objective).
        case hold
    }
    public let kind:Kind,threshold:Int
    /// The piece to keep, by its square at the root (survival goals only).
    public let target:String?
    public let drawOK:Bool?
    public init(kind:Kind,threshold:Int,target:String?=nil,drawOK:Bool?=nil){self.kind=kind;self.threshold=threshold;self.target=target;self.drawOK=drawOK}
}
/// One position in which the learner decides (plan: multi-move runtime). Ships the small validated teaching graph,
/// never the search tree; never projected to agents.
public struct TrainingTeachingNode:Codable,Equatable {
    /// Board, side to move, castling and en-passant fields of the position: a mismatch suspends the scenario.
    public let fingerprint:String
    /// Every learner move that meets the objective from here.
    public let accepted:[String]
    /// The opponent move shown after a learner move: a testing reply after an accepted move, the refutation after a
    /// rejected one. Missing when the move ends the game or no reply needs showing.
    public let replies:[String:String]
    /// For accepted moves that continue: the index of the node reached after the reply.
    public let next:[String:Int]?
    public init(fingerprint:String,accepted:[String],replies:[String:String],next:[String:Int]?=nil){self.fingerprint=fingerprint;self.accepted=accepted;self.replies=replies;self.next=next}
}
/// One concrete exercise. Positions are stored concretely, so a later generator change can never rewrite an old attempt.
public struct TrainingScenario:Codable,Equatable,Identifiable {
    public let id:String,entry:String,variant:String,tier:Int,cluster:String
    /// The side the learner acts for (and, in recognition, the colour asked about).
    public let learner:String
    public let prompt:String,explanation:String,hints:[String]
    /// Standard chess: a complete FEN, optional context moves played before the position is shown.
    public let fen:String?,prelude:[String]?
    /// Movement and recognition diagrams.
    public let diagram:Position?,target:String?,drill:MovementDrill?,budget:Int?,shortest:Bool?
    public let choices:[String]?
    public let expected:TrainingExpected?
    /// An intentional case where no capture, special move or tactic is the correct answer.
    public let noAction:Bool?
    /// Held back from the practice pool and offered as fresh material once the pool's clusters are all seen.
    public let reserve:Bool?
    public let review:TrainingReview?,generation:TrainingGeneration?
    // Increment B. `check` names the exact evaluator; `goal`, `plies` and `nodes` define a bounded move objective.
    public let check:TrainingCheck?,goal:TrainingGoal?,plies:Int?,nodes:[TrainingTeachingNode]?
    /// An exchange line to judge, from the presented position (learner first).
    public let stated:[String]?
    /// The colour a recognition question asks about (the forking or the pinned side).
    public let askColor:String?
    /// Squares shown by the second hint: the relevant pieces, never the answer move.
    public let focus:[String]?
    /// Mixed practice: the skill rows a case exercises, the one it is primarily about, and the focused case it reuses.
    public let skills:[TrainingSkill]?,primarySkill:TrainingSkill?,source:String?
    /// The existing mini-game whose simplified rules this normal-chess case contrasts with.
    public let bridge:MiniGameKind?
    /// A playable workflow this start belongs to (guided games).
    public let workflow:String?
    public init(id:String,entry:String,variant:String,tier:Int,cluster:String,learner:String,prompt:String,explanation:String,hints:[String],fen:String?=nil,prelude:[String]?=nil,diagram:Position?=nil,target:String?=nil,drill:MovementDrill?=nil,budget:Int?=nil,shortest:Bool?=nil,choices:[String]?=nil,expected:TrainingExpected?=nil,noAction:Bool?=nil,reserve:Bool?=nil,review:TrainingReview?=nil,generation:TrainingGeneration?=nil,check:TrainingCheck?=nil,goal:TrainingGoal?=nil,plies:Int?=nil,nodes:[TrainingTeachingNode]?=nil,stated:[String]?=nil,askColor:String?=nil,focus:[String]?=nil,skills:[TrainingSkill]?=nil,primarySkill:TrainingSkill?=nil,source:String?=nil,bridge:MiniGameKind?=nil,workflow:String?=nil){
        self.id=id;self.entry=entry;self.variant=variant;self.tier=tier;self.cluster=cluster;self.learner=learner;self.prompt=prompt;self.explanation=explanation;self.hints=hints
        self.fen=fen;self.prelude=prelude;self.diagram=diagram;self.target=target;self.drill=drill;self.budget=budget;self.shortest=shortest;self.choices=choices;self.expected=expected;self.noAction=noAction;self.reserve=reserve;self.review=review;self.generation=generation
        self.check=check;self.goal=goal;self.plies=plies;self.nodes=nodes;self.stated=stated;self.askColor=askColor;self.focus=focus;self.skills=skills;self.primarySkill=primarySkill;self.source=source;self.bridge=bridge;self.workflow=workflow
    }
    /// Structural checks every scenario passes before any evaluator sees it. Legality is checked in Rules/Application.
    public func validateStructure(for definition:TrainingEntryDefinition)throws {
        guard id.count<=96,id.range(of:"\\A[a-z0-9]+([:-][a-z0-9]+)*\\z",options:.regularExpression) != nil else{try fail("invalid identifier")}
        guard entry==definition.id,definition.variants.contains(variant),(1...definition.tiers).contains(tier),!cluster.isEmpty else{try fail("entry, variant, tier or cluster does not match the catalog")}
        guard ["w","b"].contains(learner),!prompt.isEmpty,!explanation.isEmpty,!hints.isEmpty else{try fail("learner, prompt, explanation and hints are required")}
        guard (review != nil) != (generation != nil) else{try fail("a scenario is either curated (reviewed) or generated, not both")}
        let squares=[target].compactMap{$0}+(diagram.map{Array($0.keys)} ?? [])+(expected?.squares ?? [])
        guard squares.allSatisfy(ChessNotation.validSquare),diagram?.values.allSatisfy(Self.validPiece) ?? true,((expected?.moves ?? [])+(expected?.wrong ?? [])+(prelude ?? [])).allSatisfy(ChessNotation.validUCI) else{try fail("invalid square, piece or move")}
        try validateRuleMode(definition.ruleMode)
        guard (focus ?? []).allSatisfy(ChessNotation.validSquare),(stated ?? []).allSatisfy(ChessNotation.validUCI),askColor.map({["w","b"].contains($0)}) ?? true else{try fail("invalid focus square, stated move or asked colour")}
        guard definition.increment == .beginner else {
            guard check==nil,goal==nil,plies==nil,nodes==nil,stated==nil,askColor==nil,skills==nil,primarySkill==nil,source==nil,bridge==nil,workflow==nil else{try fail("Increment B fields on an Increment A scenario")}
            return
        }
        try validateBeginner(definition)
    }
    private func fail(_ reason:String)throws -> Never {throw CheckmateError.invalid("Training scenario \(id): \(reason)")}
    /// A colour and a piece letter, such as `wn`.
    private static func validPiece(_ piece:String)->Bool {piece.count==2 && piece.first.map{"wb".contains($0)}==true && piece.last.map{"pnbrqk".contains($0)}==true}
    /// The payload the entry's rule mode reads, and nothing it does not.
    private func validateRuleMode(_ mode:TrainingRuleMode)throws {
        switch mode {
        case .standardChess:guard fen != nil,diagram==nil,drill==nil else{try fail("standard chess needs a FEN and no diagram")}
        case .recognitionDiagram:guard let diagram,fen==nil,drill==nil,let target,!diagram.isEmpty,diagram.count<=32 else{try fail("a recognition diagram needs pieces and a marked square, and no drill")};_ = target
        case .movementDrill:
            guard let drill,let budget,budget>=1,fen==nil else{try fail("a movement drill needs its piece and a move budget")}
            // The drill's own encoding first: its colour and every move it allows are derived from these.
            guard Self.validPiece(drill.piece),ChessNotation.validSquare(drill.start),ChessNotation.validSquare(drill.target),drill.pieces[drill.start]==nil,
                  drill.pieces.allSatisfy({ChessNotation.validSquare($0.key) && Self.validPiece($0.value)}) else{try fail("invalid drill piece, square or fixed piece")}
            guard drill.color==Character(learner) else{try fail("the drill's piece is not the learner's")}
            guard drill.pieces.values.filter({$0.first != drill.color}).count<=MovementDrill.maximumEnemies else{try fail("too many enemy pieces for an exact route search")}
        case .simplifiedVariant:try fail("existing games have no scenarios")
        }
    }
    /// Increment B: the evaluator, its goal and horizon, its teaching graph and its question format.
    private func validateBeginner(_ definition:TrainingEntryDefinition)throws {
        guard let check else{try fail("an Increment B scenario names its evaluator")}
        if definition.objective == .mixedPractice {
            guard TrainingCheck.mixed.contains(check) else{try fail("\(check.rawValue) is not a mixed-practice evaluator")}
            guard let skills,!skills.isEmpty,let primarySkill,skills.contains(primarySkill) else{try fail("a mixed case lists its skills and primary skill")}
        } else {
            guard check==TrainingCheck.focused(definition.objective,variant:variant) else{try fail("variant \(variant) is graded by another evaluator")}
            guard skills==nil,primarySkill==nil,source==nil else{try fail("only mixed cases carry skill rows")}
        }
        if check.searched {
            guard let goal,let plies,(1...5).contains(plies),plies % 2==1 else{try fail("a searched objective needs a goal and an odd horizon of one to five plies")}
            switch goal.kind {
            case .survive:guard let target=goal.target,ChessNotation.validSquare(target),check == .defense else{try fail("a survival goal names its target and belongs to Save Your Piece")}
            case .gain:guard goal.target==nil,goal.threshold>0,check != .defense else{try fail("a gain goal has a positive threshold and no target")}
            case .hold:guard goal.target==nil,goal.threshold<=0,check != .defense else{try fail("a hold goal has a threshold of zero or less and no target")}
            }
        } else {guard goal==nil,plies==nil else{try fail("only searched objectives have a goal and horizon")}}
        try validateTeachingGraph(check)
        if check.task == .choose{guard let choices,choices.count>=2,Set(choices).count==choices.count else{try fail("a choice needs at least two distinct options")}}
        else{guard choices==nil else{try fail("only choice questions have options")}}
        guard (check == .exchange)==(stated != nil) else{try fail("an exchange question states its line, and only it does")}
        guard [.forks,.pins].contains(check)==(askColor != nil) else{try fail("a recognition question names the asked colour, and only it does")}
    }
    /// Move objectives (and diagnosis) ship a small teaching graph whose links stay inside it; nothing else has one.
    private func validateTeachingGraph(_ check:TrainingCheck)throws {
        switch check.task {
        case .move,.choose where check == .diagnosis:
            guard let nodes,!nodes.isEmpty,nodes.count<=64 else{try fail("a move objective ships its teaching graph")}
            for node in nodes {
                let moves=node.accepted+Array(node.replies.keys)+Array(node.replies.values)+Array((node.next ?? [:]).keys)
                guard moves.allSatisfy(ChessNotation.validUCI),(node.next ?? [:]).values.allSatisfy({(1..<nodes.count).contains($0)}),Set((node.next ?? [:]).keys).isSubset(of:node.accepted) else{try fail("invalid teaching node")}
            }
        default:guard nodes==nil else{try fail("only move objectives have a teaching graph")}
        }
    }
}
/// Deterministic SplitMix64, so a seed and generator version always give the same board on every platform.
public struct TrainingRandom {
    private var state:UInt64
    public init(seed:UInt64){state=seed}
    public mutating func next()->UInt64 {state &+= 0x9E3779B97F4A7C15;var z=state;z=(z^(z>>30)) &* 0xBF58476D1CE4E5B9;z=(z^(z>>27)) &* 0x94D049BB133111EB;return z^(z>>31)}
    /// The width is taken in unsigned arithmetic, so any range works, the whole of `Int` included.
    public mutating func int(_ range:ClosedRange<Int>)->Int {let span=UInt64(UInt(bitPattern:range.upperBound &- range.lowerBound)),value=next();return range.lowerBound &+ Int(truncatingIfNeeded:span == .max ? value:value % (span+1))}
    public mutating func pick<T>(_ items:[T])->T {items[int(0...items.count-1)]}
    public mutating func chance(_ numerator:Int,in denominator:Int)->Bool {int(1...denominator)<=numerator}
}
