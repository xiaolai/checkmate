import CheckmateAssets
import Foundation
/// What the learner did in an attempt, in order. Replaying these on the concrete scenario rebuilds the attempt exactly.
public enum TrainingAction:Codable,Equatable {
    case move(from:String,to:String,promotion:String?)
    case submit(squares:[String])
    case choose(String)
    case hint(level:Int)
    case reveal
    /// Takes back the last movement-drill step.
    case undo
    /// The opponent's move shown in a multi-move objective (a testing reply or a refutation), or the practice
    /// defender's move in a playable game. Persisted so a resumed attempt replays exactly.
    case reply(String)
    /// A draw claimed by the learner in a playable game (threefold repetition or the 50-move rule).
    case claim(String)
}
/// How a finished attempt ended. A reveal or an abandoned attempt is never a success.
public enum TrainingOutcome:String,Codable {case correct,incorrect,revealed,abandoned}
/// An attempt in progress, saved so the library can offer Continue (plan rule 11). It holds the concrete scenario, so
/// a later generator or content change can never rewrite it; it resumes only after replay validation.
public struct TrainingSessionSnapshot:Codable,Equatable {
    public var id:String,entry:String,scenario:TrainingScenario,freshness:String
    public var revision:Int,startedAt:Date
    public var actions:[TrainingAction]
    /// In-app help (a hint, reveal, undo or an agent's submission) was recorded during this attempt.
    public var recordedHelp:Bool
    /// The learner has attempted this exact position before: this attempt is practice, not first-try evidence.
    public var retry:Bool
    /// A playable game's opponent, frozen when the attempt started (mini-game plan D4); read it through `boundOpponent`.
    /// Absent from attempts saved before levels existed, and from every attempt while position games are off.
    public var opponent:TrainingOpponentConfiguration?
    public init(id:String,entry:String,scenario:TrainingScenario,freshness:String,revision:Int=0,startedAt:Date,actions:[TrainingAction]=[],recordedHelp:Bool=false,retry:Bool=false,opponent:TrainingOpponentConfiguration?=nil){self.id=id;self.entry=entry;self.scenario=scenario;self.freshness=freshness;self.revision=revision;self.startedAt=startedAt;self.actions=actions;self.recordedHelp=recordedHelp;self.retry=retry;self.opponent=opponent}
}
/// One finished attempt, kept (bounded) for descriptive progress and the retry queue.
public struct TrainingAttempt:Codable,Equatable,Identifiable {
    public let id:String,entry:String,scenarioID:String,cluster:String,tier:Int,learner:String
    public let startedAt:Date,finishedAt:Date,outcome:TrainingOutcome
    /// The first attempt at this exact position, with no recorded in-app help: the only results shown as
    /// "first try · no recorded help". External help is unobservable, so this never means unassisted.
    public let firstTryNoRecordedHelp:Bool
    public let recordedHelp:Bool,retry:Bool,freshness:String
    /// A playable game's opponent level and the search policy it names (`TrainingOpponentConfiguration.policy`),
    /// copied from the attempt's frozen opponent. Absent when it had none, and from attempts an older build saved:
    /// it re-encodes attempts without them, so after a downgrade-and-save the level is not recorded (`levelLabel`).
    public let level:String?,levelPolicy:String?
    public init(id:String,entry:String,scenarioID:String,cluster:String,tier:Int,learner:String,startedAt:Date,finishedAt:Date,outcome:TrainingOutcome,firstTryNoRecordedHelp:Bool,recordedHelp:Bool,retry:Bool,freshness:String,opponent:TrainingOpponentConfiguration?=nil){self.id=id;self.entry=entry;self.scenarioID=scenarioID;self.cluster=cluster;self.tier=tier;self.learner=learner;self.startedAt=startedAt;self.finishedAt=finishedAt;self.outcome=outcome;self.firstTryNoRecordedHelp=firstTryNoRecordedHelp;self.recordedHelp=recordedHelp;self.retry=retry;self.freshness=freshness;level=opponent?.profile;levelPolicy=opponent?.policy}
}
/// A finished existing mini-game, observed as it finished (never inferred from a loaded board). `winner` is the side
/// that won, or nil for a draw; `computer` says whether the learner played the computer.
/// Against the computer, `level` and `levelPolicy` are the run's frozen level and the search policy it names, and
/// `levelExact` is false when an older build moved the run's board (the level is not exact). All three are absent
/// from a two-player or solo game, and from events an older build saved: it re-encodes events without them, so after
/// a downgrade-and-save the level is not recorded.
public struct TrainingCompletionEvent:Codable,Equatable,Identifiable {
    public let id:String,kind:String,run:String,winner:String?,drawReason:String?,computer:Bool,origin:String,at:Date
    public let level:String?,levelPolicy:String?,levelExact:Bool?
    public init(id:String,kind:String,run:String,winner:String?,drawReason:String?,computer:Bool,origin:String,at:Date,level:MiniGameLevel?=nil){self.id=id;self.kind=kind;self.run=run;self.winner=winner;self.drawReason=drawReason;self.computer=computer;self.origin=origin;self.at=at;self.level=level?.profile;levelPolicy=level.flatMap{level in MiniGameKind(rawValue:kind).map{level.policy($0)}};levelExact=level?.exact}
}
/// Descriptive per-entry counters. They are never pruned; the bounded event and attempt lists behind them are.
public struct TrainingEntrySummary:Codable,Equatable {
    public var attempts=0,firstTryNoRecordedHelp=0,assistedCompletions=0,practiceCompletions=0,incorrect=0,revealed=0,abandoned=0
    /// Finished legacy mini-games; the meaning depends on the kind. Against the computer: results from the learner's
    /// side, White or Black. Two-player: only `twoPlayerFinishes`. Solo (Knight Corners): `legacyWins` counts completed routes,
    /// the only way a solo game finishes, and its losses and draws stay zero and are never read.
    public var legacyWins=0,legacyLosses=0,legacyDraws=0,twoPlayerFinishes=0
    /// Distinct novelty clusters practised and local calendar days with practice (both bounded, newest kept).
    public var clusters:[String]=[],days:[String]=[]
    public init(){}
}
/// An item suggested for repeat practice. It holds the concrete scenario and becomes due only after three other items
/// and on or after the local day after `addedAt`; suggestions never lock anything (plan rule 10). `notBefore` records
/// that day as it was when queued; scheduling re-derives it from `addedAt`, so a day saved under another calendar never misleads.
public struct TrainingRetryItem:Codable,Equatable,Identifiable {
    public let id:String,entry:String,scenario:TrainingScenario,reason:String,addedAt:Date,notBefore:String
    /// The count of finished, non-abandoned attempts when it was added; it is due once three more have finished.
    public let afterAttempt:Int
    public init(id:String,entry:String,scenario:TrainingScenario,reason:String,addedAt:Date,notBefore:String,afterAttempt:Int){self.id=id;self.entry=entry;self.scenario=scenario;self.reason=reason;self.addedAt=addedAt;self.notBefore=notBefore;self.afterAttempt=afterAttempt}
}
/// The optional `training` object in the global saved state, with its own envelope version (plan: Data Model).
/// It never holds a second copy of a legacy mini-game board.
///
/// Records from a newer version (WI-026). The persisted records that embed a scenario or an opponent configuration are:
/// - `active` (`TrainingSessionSnapshot.scenario`, and beside it the frozen `opponent`, which WI-026 kept by path);
/// - each `retryQueue` item (`TrainingRetryItem.scenario`);
/// - outside this object, `miniGames` (a later build's per-run level), which this build never decodes: it is kept by
///   path as an unknown field (`ApplicationState.unknownNestedFields`), so it cannot fail a load.
/// `attempts` and `events` hold no scenario (a scenario id, a kind and a run); fields a later build adds to them are
/// unknown fields of array items, dropped when this build rewrites them, as the plan accepts. An event or credited run
/// of an unknown mini-game kind is damage here, not a newer record (no later build adds a kind, plan D2), and keeps the
/// whole object raw.
/// Each scenario-bearing record is read on its own. One this build cannot decode, or whose scenario (or actions, or,
/// for a retry item, any part) carries a field this build does not know, is set aside as from a newer version: kept
/// raw where it was read and written back unchanged through every later save, counted in the bounds and the byte
/// budget, never resumed and never scheduled. The rest of training stays writable. Unknown fields beside an active
/// attempt's scenario are tolerated: they are kept by path, and that attempt resumes here. A record without a string
/// `id`, a string `entry` and a `scenario` object is damage: the whole object is kept raw, as before.
public struct TrainingState:Codable,Equatable {
    public static let version=1
    /// Bounds: the newest events and attempts are kept; the whole object stays within its share of the 4 MiB save.
    public static let maximumEvents=200,maximumAttempts=200,maximumRetries=50,maximumClusters=512,maximumDays=366,maximumPositions=2000,maximumBytes=512*1024
    /// The most actions an attempt in progress may hold and still be saved.
    public static let maximumActions=512
    /// A ceiling on every saved counter and revision, far above any real use and far below overflow, so a loaded
    /// record can always be incremented.
    public static let maximumCount=1_000_000_000
    /// A local calendar day, `yyyy-MM-dd`, as retry items store it.
    public static let dayPattern="\\A[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])\\z"
    public var version=TrainingState.version
    /// The attempt in progress this build can resume. Nil while `newerActive` holds the slot.
    public var active:TrainingSessionSnapshot?
    /// An attempt in progress from a newer version, kept raw in `active`'s place. This build never resumes, replaces or
    /// abandons it, so an attempt started here is not saved for Continue while it is held.
    public private(set) var newerActive:JSONValue?
    public var attempts:[TrainingAttempt]=[]
    public var events:[TrainingCompletionEvent]=[]
    public var summaries:[String:TrainingEntrySummary]=[:]
    /// One place in the saved retry queue: an item this build uses, or one from a newer version, kept raw.
    enum RetrySlot:Equatable {case item(TrainingRetryItem),newer(JSONValue)}
    /// The saved retry queue in order, newer-version items in place.
    private var retrySlots:[RetrySlot]=[]
    /// The retry items this build can schedule, in order. Setting it keeps every newer-version item where it was:
    /// before the item that followed it and is still queued, else after the last surviving item and ahead of new ones.
    public var retryQueue:[TrainingRetryItem] {
        get{retrySlots.compactMap{if case .item(let item)=$0{return item};return nil}}
        set{retrySlots=Self.reconciled(retrySlots,with:newValue)}
    }
    /// Retry items from a newer version: they hold places in `maximumRetries`, and are never pruned here.
    public var newerRetryCount:Int {retrySlots.count-retryQueue.count}
    /// Fingerprints of positions already attempted, so a retry is never counted as a first try (bounded, newest kept).
    public var attemptedPositions:[String]=[]
    /// The legacy run already credited with a completion, per mini-game: undo and replay within that run never
    /// add another event; a restarted game is a new run.
    public var creditedRuns:[String:String]=[:]
    /// Finished attempts other than abandoned ones, including pruned ones (the retry queue counts from this).
    public var finishedAttempts=0
    public init(){}
    private enum CodingKeys:String,CodingKey {case version,active,attempts,events,summaries,retryQueue,attemptedPositions,creditedRuns,finishedAttempts}
    /// As the synthesised decoder read it (every key but `active` required), except that `active` and each retry item
    /// are read on their own: a newer version's record is set aside raw, and a damaged one fails the whole object.
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        version=try c.decode(Int.self,forKey:.version);attempts=try c.decode([TrainingAttempt].self,forKey:.attempts);events=try c.decode([TrainingCompletionEvent].self,forKey:.events)
        summaries=try c.decode([String:TrainingEntrySummary].self,forKey:.summaries);attemptedPositions=try c.decode([String].self,forKey:.attemptedPositions);creditedRuns=try c.decode([String:String].self,forKey:.creditedRuns);finishedAttempts=try c.decode(Int.self,forKey:.finishedAttempts)
        if let raw=try c.decodeIfPresent(JSONValue.self,forKey:.active) {
            if let snapshot=try Self.readable(raw,as:TrainingSessionSnapshot.self,whole:false){active=snapshot}else{newerActive=raw}
        }
        retrySlots=try c.decode([JSONValue].self,forKey:.retryQueue).map{raw in try Self.readable(raw,as:TrainingRetryItem.self,whole:true).map(RetrySlot.item) ?? .newer(raw)}
    }
    /// Newer-version records are written back exactly as read, in place. A state holding both an active attempt and a
    /// newer one in its place cannot be written.
    public func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        guard active==nil || newerActive==nil else{throw EncodingError.invalidValue(self,.init(codingPath:c.codingPath+[CodingKeys.active],debugDescription:"An active attempt cannot replace one from a newer version."))}
        try c.encode(version,forKey:.version);try c.encodeIfPresent(active,forKey:.active);try c.encodeIfPresent(newerActive,forKey:.active);try c.encode(attempts,forKey:.attempts);try c.encode(events,forKey:.events);try c.encode(summaries,forKey:.summaries)
        var queue=c.nestedUnkeyedContainer(forKey:.retryQueue)
        for slot in retrySlots {switch slot {case .item(let item):try queue.encode(item);case .newer(let raw):try queue.encode(raw)}}
        try c.encode(attemptedPositions,forKey:.attemptedPositions);try c.encode(creditedRuns,forKey:.creditedRuns);try c.encode(finishedAttempts,forKey:.finishedAttempts)
    }
    /// A scenario-bearing record as this build reads it: the record, or nil when it is from a newer version (it does not
    /// decode, or carries a field this build does not know: anywhere when `whole`, else in its scenario and actions).
    /// Throws when it is damaged: not an object with a string `id`, a string `entry` and a `scenario` object.
    static func readable<Record:Codable>(_ raw:JSONValue,as type:Record.Type,whole:Bool)throws -> Record? {
        guard case .object(let fields)=raw,case .string?=fields["id"],case .string?=fields["entry"],case .object?=fields["scenario"] else{throw CheckmateError.invalid(String(localized:"Training record: a damaged \(String(describing:Record.self))",bundle:.checkmate))}
        guard let record=try? JSONDecoder().decode(Record.self,from:JSONEncoder().encode(raw)),case .object(let written)=try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(record)) else{return nil}
        let compared=whole ? fields:fields.filter{written[$0.key] != nil}
        return compared.contains(where:{key,value in Self.unknown(value,beyond:written[key])}) ? nil:record
    }
    /// Whether `raw` holds a field `written` (this build's encoding of what it decoded from `raw`) lacks. A null is no field.
    static func unknown(_ raw:JSONValue,beyond written:JSONValue?)->Bool {
        guard raw != .null else{return false}
        switch (raw,written) {
        case (_,nil):return true
        case (.object(let fields),.object(let mine)?):return fields.contains{unknown($0.value,beyond:mine[$0.key])}
        case (.array(let items),.array(let mine)?):return items.count != mine.count || zip(items,mine).contains{unknown($0,beyond:$1)}
        default:return false
        }
    }
    /// `slots` with this build's items replaced by `items`, each newer-version slot kept before the item that followed it
    /// and survives, else after the last surviving item and ahead of any item `slots` did not hold.
    static func reconciled(_ slots:[RetrySlot],with items:[TrainingRetryItem])->[RetrySlot] {
        let kept=Set(items.map(\.id));var waiting:[RetrySlot]=[],before:[String:[RetrySlot]]=[:],held:Set<String>=[]
        for slot in slots {
            switch slot {
            case .newer:waiting.append(slot)
            case .item(let item):held.insert(item.id);if kept.contains(item.id){before[item.id,default:[]]+=waiting;waiting=[]}
            }
        }
        var out:[RetrySlot]=[],tailPlaced=false
        for item in items {
            if !tailPlaced,!held.contains(item.id){out+=waiting;tailPlaced=true}
            out+=before.removeValue(forKey:item.id) ?? [];out.append(.item(item))
        }
        return tailPlaced ? out:out+waiting
    }
    /// Fails on any record this build could not have written: an unreadable record is preserved raw instead.
    public func validate()throws {
        func fail(_ reason:String)throws -> Never {throw CheckmateError.invalid(String(localized:"Training record: \(reason)",bundle:.checkmate))}
        guard version==Self.version else{try fail(String(localized:"unsupported version \(version)",bundle:.checkmate,comment:"Why a saved training record cannot be read"))}
        guard attempts.count<=Self.maximumAttempts,events.count<=Self.maximumEvents,retrySlots.count<=Self.maximumRetries,attemptedPositions.count<=Self.maximumPositions,(0...Self.maximumCount).contains(finishedAttempts) else{try fail(String(localized:"exceeds its bounds",bundle:.checkmate))}
        // A newer-version item's identifier is read from its raw record; `readable` admitted only string identifiers.
        let retryIDs=retrySlots.map{slot->String in switch slot {case .item(let item):return item.id;case .newer(.object(let fields)):if case .string(let id)?=fields["id"]{return id};return "";case .newer:return ""}}
        guard Set(attempts.map(\.id)).count==attempts.count,Set(events.map(\.id)).count==events.count,Set(retryIDs).count==retryIDs.count else{try fail(String(localized:"duplicate identifiers",bundle:.checkmate,comment:"Why a saved training record cannot be read"))}
        guard active==nil || newerActive==nil else{try fail(String(localized:"two active attempts",bundle:.checkmate))}
        guard creditedRuns.keys.allSatisfy({MiniGameKind(rawValue:$0) != nil}),events.allSatisfy({MiniGameKind(rawValue:$0.kind) != nil}) else{try fail(String(localized:"unknown mini-game",bundle:.checkmate,comment:"Why a saved training record cannot be read"))}
        for summary in summaries.values {
            let outcomes=[summary.firstTryNoRecordedHelp,summary.assistedCompletions,summary.practiceCompletions,summary.incorrect,summary.revealed,summary.abandoned]
            guard ([summary.attempts,summary.legacyWins,summary.legacyLosses,summary.legacyDraws,summary.twoPlayerFinishes]+outcomes).allSatisfy({(0...Self.maximumCount).contains($0)}),summary.clusters.count<=Self.maximumClusters,summary.days.count<=Self.maximumDays else{try fail(String(localized:"invalid summary",bundle:.checkmate,comment:"Why a saved training record cannot be read"))}
            // Every attempt adds exactly one outcome, so they total the attempts (both capped alike at the ceiling).
            guard min(outcomes.reduce(0,+),Self.maximumCount)==summary.attempts,Set(summary.clusters).count==summary.clusters.count,Set(summary.days).count==summary.days.count else{try fail(String(localized:"inconsistent summary",bundle:.checkmate,comment:"Why a saved training record cannot be read"))}
        }
        // A retry counts from the finished attempts when it was queued, which can only have grown since.
        // `notBefore` is a `yyyy-MM-dd` record of the day computed when queued (scheduling re-derives it from `addedAt`).
        guard retryQueue.allSatisfy({(0...finishedAttempts).contains($0.afterAttempt) && $0.notBefore.range(of:Self.dayPattern,options:.regularExpression) != nil}) else{try fail(String(localized:"invalid retry item",bundle:.checkmate))}
        if let active {
            guard (0...Self.maximumCount).contains(active.revision),active.actions.count<=Self.maximumActions else{try fail(String(localized:"invalid active attempt",bundle:.checkmate))}
            // Every hint, reveal and undo records help as it is taken, so one without the flag was not written by this build.
            let helped=active.actions.contains{if case .hint=$0{return true};return $0 == .reveal || $0 == .undo}
            guard active.recordedHelp || !helped else{try fail(String(localized:"help taken but not recorded",bundle:.checkmate))}
        }
    }
}
