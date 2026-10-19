import CheckmateAssets
import Foundation
/// Training stays default-off for ordinary users until its public projection, tool and voice gates are verified
/// (plan rule 12). Automation and development enable it explicitly.
public enum TrainingRolloutPolicy {
    public static var enabled:Bool {ProcessInfo.processInfo.environment["CHECKMATE_TRAINING_ENABLED"] == "1"}
    /// Increment B stays off for users until its content has editorial review and B coverage is verified (plan:
    /// rollout); development and automation enable it separately.
    public static var beginnerEnabled:Bool {enabled && ProcessInfo.processInfo.environment["CHECKMATE_TRAINING_B"] == "1"}
    /// Position games and the opponent levels of standard-rule games (mini-game plan WI-017) stay off until their
    /// content has editorial review and a beginner observation, and until a release that reads their records has
    /// shipped (plan D8): `CHECKMATE_POSITION_GAMES=1`, on top of Increment B, turns them on. While it is off nothing
    /// writes their values: no position-game entry is offered and no attempt freezes an opponent level.
    public static var positionGamesEnabled:Bool {beginnerEnabled && ProcessInfo.processInfo.environment["CHECKMATE_POSITION_GAMES"] == "1"}
    /// The voice coach in a standard-rule training game (mini-game plan WI-021), through its own adapter and only after
    /// the attempt's help is recorded: `CHECKMATE_TRAINING_VOICE=1`, on top of training. While it is off the coach
    /// cannot connect in training at all, as before.
    public static var trainingVoiceEnabled:Bool {enabled && ProcessInfo.processInfo.environment["CHECKMATE_TRAINING_VOICE"] == "1"}
    /// Whether an entry is offered: Increment A always, Increment B only with its preview enabled, position games only
    /// with theirs.
    public static func offered(_ definition:TrainingEntryDefinition)->Bool {definition.objective == .positionGame ? positionGamesEnabled:definition.increment == .foundations || beginnerEnabled}
    /// Whether the library lists an entry under its preview heading, labelled machine-checked but not yet reviewed: an
    /// offered Increment B entry. A position game needs its own flag on top of Increment B's.
    public static func preview(_ definition:TrainingEntryDefinition)->Bool {definition.increment == .beginner && offered(definition)}
}
/// How an entry's moves are judged. Every entry declares one and shows its plain rules (plan rule 2).
public enum TrainingRuleMode:String,Codable,CaseIterable {
    /// A single piece moves by its own geometry among fixed pieces; no check or turn rules.
    case movementDrill
    /// An existing mini-game with its own simplified rules.
    case simplifiedVariant
    /// A diagram read for geometry only (attacks and protection); it need not be a legal game position.
    case recognitionDiagram
    /// A validated legal chess position with complete turn, castling and en-passant context.
    case standardChess
}
/// What a syntactically valid but illegal chess attempt means for an objective (plan rule 3). Never mixed silently.
public enum TrainingIllegalInputPolicy:String,Codable {
    /// Graded as a wrong submission with an explanation; the board never changes (check evasion, special moves).
    case ruleError
    /// Ignored as a selection correction; it is not a submitted answer.
    case selectionCorrection
    /// The objective has no move input.
    case notApplicable
}
public enum TrainingActionKind:String,Codable,CaseIterable {case selectSquares,chooseOption,playMove}
public enum TrainingIncrement:String,Codable,CaseIterable {case foundations="A",beginner="B"}
public enum TrainingDelivery:String,Codable,CaseIterable {case pilot,release}
public enum TrainingOrigin:String,Codable,CaseIterable {case existing,new}
/// The rows of the plan's skill coverage matrix.
public enum TrainingSkill:String,Codable,CaseIterable {
    case movement,attackProtection,threatResponse,captureExchange,checkMateDraw,specialRules,elementaryTactics,convertingWin,gameHabits,diagnosis
}
/// The finite set of objectives. There is no executable content language: each case has its own exact evaluator.
public enum TrainingObjectiveKind:String,Codable,CaseIterable {
    case reachTarget,findAttackers,findDefenders,kingSafeSquares,mateInOne,escapeCheck,classifyStatus
    /// An existing mini-game, played with its original rules through the legacy controller.
    case legacyGame
    case saveYourPiece,captureWisely,specialMoves,simpleTactics,finishTheGame,mixedPractice
    /// A legal game from a reviewed start against the practice defender, with review moments afterwards.
    case guidedGame
    /// A standard-chess game from a position against the practice defender, to a declared goal (checkmate, or promote
    /// and hold) under a closed outcome matrix (mini-game plan D3).
    case positionGame
    /// The increment whose evaluators grade this objective; a catalog entry belongs to exactly this one.
    public var increment:TrainingIncrement {switch self {
        case .reachTarget,.findAttackers,.findDefenders,.kingSafeSquares,.mateInOne,.escapeCheck,.classifyStatus,.legacyGame:return .foundations
        case .saveYourPiece,.captureWisely,.specialMoves,.simpleTactics,.finishTheGame,.mixedPractice,.guidedGame,.positionGame:return .beginner
    }}
    public var ruleMode:TrainingRuleMode {switch self {
        case .reachTarget:return .movementDrill
        case .findAttackers,.findDefenders:return .recognitionDiagram
        case .legacyGame:return .simplifiedVariant
        default:return .standardChess
    }}
    public var actions:[TrainingActionKind] {switch self {
        case .findAttackers,.findDefenders,.kingSafeSquares:return [.selectSquares]
        case .classifyStatus:return [.chooseOption]
        case .reachTarget,.mateInOne,.escapeCheck,.legacyGame,.saveYourPiece,.finishTheGame,.guidedGame,.positionGame:return [.playMove]
        case .captureWisely,.specialMoves,.simpleTactics,.mixedPractice:return [.playMove,.chooseOption,.selectSquares]
    }}
    /// Special moves and check evasion grade a raw illegal attempt as a rule error; everything else ignores it.
    public var illegalInput:TrainingIllegalInputPolicy {switch self {
        case .escapeCheck,.specialMoves:return .ruleError
        case .findAttackers,.findDefenders,.kingSafeSquares,.classifyStatus:return .notApplicable
        default:return .selectionCorrection
    }}
}
/// One library entry. Existing games keep their kind, side and rules; new exercises carry their own objective.
public struct TrainingEntryDefinition:Codable,Equatable,Identifiable {
    public let id:String,title:String,summary:String,rules:[String]
    public let objective:TrainingObjectiveKind,legacyKind:MiniGameKind?
    public let ruleMode:TrainingRuleMode,illegalInput:TrainingIllegalInputPolicy,actions:[TrainingActionKind]
    public let increment:TrainingIncrement,delivery:TrainingDelivery,origin:TrainingOrigin
    public let skills:[TrainingSkill]
    /// Subskills practised inside the entry (a B group's variants); each has its own content minimum.
    public let variants:[String]
    /// Current lesson IDs offered as optional explanations; watching one is never counted as practice.
    public let lessonLinks:[String]
    /// The number of authored constraint tiers (isolated, distractors or a reply, unfamiliar context).
    public let tiers:Int
    public init(id:String,title:String,summary:String,rules:[String],objective:TrainingObjectiveKind,legacyKind:MiniGameKind?=nil,increment:TrainingIncrement,delivery:TrainingDelivery,origin:TrainingOrigin,skills:[TrainingSkill],variants:[String],lessonLinks:[String],tiers:Int){
        self.id=id;self.title=title;self.summary=summary;self.rules=rules;self.objective=objective;self.legacyKind=legacyKind;ruleMode=objective.ruleMode;illegalInput=objective.illegalInput;actions=objective.actions
        self.increment=increment;self.delivery=delivery;self.origin=origin;self.skills=skills;self.variants=variants;self.lessonLinks=lessonLinks;self.tiers=tiers
    }
    /// `\A` and `\z` anchor the whole string: `$` would also match before a trailing newline.
    public static let idPattern="\\A[a-z0-9]+(-[a-z0-9]+)*\\z"
    /// Fails loudly on any definition this build cannot honour exactly.
    public func validate()throws {
        func fail(_ reason:String)throws -> Never {throw CheckmateError.invalid("Training entry \(id): \(reason)")}
        guard id.count<=48,id.range(of:Self.idPattern,options:.regularExpression) != nil else{try fail("invalid identifier")}
        guard !title.isEmpty,title.count<=60,!summary.isEmpty,summary.count<=300 else{try fail("invalid title or summary")}
        guard !rules.isEmpty,rules.allSatisfy({!$0.isEmpty && $0.count<=400}) else{try fail("plain rules are required")}
        guard ruleMode==objective.ruleMode,illegalInput==objective.illegalInput,actions==objective.actions else{try fail("rule mode, input policy and actions must match the objective")}
        guard (objective == .legacyGame)==(legacyKind != nil) else{try fail("a legacy game names exactly one mini-game")}
        // Legacy progress is stored under the mini-game's own key, so the entry carries that key as its identifier.
        guard legacyKind.map({$0.rawValue==id}) ?? true else{try fail("a legacy game's identifier is its mini-game's")}
        guard origin==(objective == .legacyGame ? .existing:.new) else{try fail("only legacy games are existing entries")}
        guard !skills.isEmpty,Set(skills).count==skills.count else{try fail("skills must be listed once each")}
        guard Set(variants).count==variants.count,variants.allSatisfy({$0.range(of:Self.idPattern,options:.regularExpression) != nil}) else{try fail("invalid variants")}
        // Every scenario of a new exercise names one of its variants, so an entry without any could never be played.
        guard objective == .legacyGame || !variants.isEmpty else{try fail("a new exercise lists its variants")}
        guard (1...3).contains(tiers) else{try fail("one to three tiers")}
        guard increment==objective.increment else{try fail("this objective belongs to increment \(objective.increment.rawValue)")}
    }
}
/// The published library: entries in display order plus their schema version.
public struct TrainingCatalog:Codable,Equatable {
    public static let schemaVersion=1
    public let schemaVersion:Int,contentVersion:Int,entries:[TrainingEntryDefinition]
    public init(schemaVersion:Int=TrainingCatalog.schemaVersion,contentVersion:Int,entries:[TrainingEntryDefinition]){self.schemaVersion=schemaVersion;self.contentVersion=contentVersion;self.entries=entries}
    public func entry(_ id:String)->TrainingEntryDefinition? {entries.first{$0.id==id}}
    public func entries(in increment:TrainingIncrement)->[TrainingEntryDefinition] {entries.filter{$0.increment==increment}}
    public func validate()throws {
        guard schemaVersion==Self.schemaVersion else{throw CheckmateError.invalid("Unsupported training catalog version.")}
        guard contentVersion>=1 else{throw CheckmateError.invalid("Training content version must be positive.")}
        for entry in entries{try entry.validate()}
        // A legacy entry's identifier is its mini-game's (entry validation), so unique identifiers also mean each mini-game appears once.
        guard Set(entries.map(\.id)).count==entries.count else{throw CheckmateError.invalid("Duplicate training entry identifiers.")}
    }
    /// The published catalog from the asset bundle, validated before use.
    public static func bundled()throws -> TrainingCatalog {
        let catalog=try JSONDecoder().decode(TrainingCatalog.self,from:Data(contentsOf:NativeResources.url("training/catalog.json")))
        try catalog.validate();return catalog
    }
}
