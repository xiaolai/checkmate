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
    public init(id:String,entry:String,scenario:TrainingScenario,freshness:String,revision:Int=0,startedAt:Date,actions:[TrainingAction]=[],recordedHelp:Bool=false,retry:Bool=false){self.id=id;self.entry=entry;self.scenario=scenario;self.freshness=freshness;self.revision=revision;self.startedAt=startedAt;self.actions=actions;self.recordedHelp=recordedHelp;self.retry=retry}
}
/// One finished attempt, kept (bounded) for descriptive progress and the retry queue.
public struct TrainingAttempt:Codable,Equatable,Identifiable {
    public let id:String,entry:String,scenarioID:String,cluster:String,tier:Int,learner:String
    public let startedAt:Date,finishedAt:Date,outcome:TrainingOutcome
    /// The first attempt at this exact position, with no recorded in-app help: the only results shown as
    /// "first try · no recorded help". External help is unobservable, so this never means unassisted.
    public let firstTryNoRecordedHelp:Bool
    public let recordedHelp:Bool,retry:Bool,freshness:String
    public init(id:String,entry:String,scenarioID:String,cluster:String,tier:Int,learner:String,startedAt:Date,finishedAt:Date,outcome:TrainingOutcome,firstTryNoRecordedHelp:Bool,recordedHelp:Bool,retry:Bool,freshness:String){self.id=id;self.entry=entry;self.scenarioID=scenarioID;self.cluster=cluster;self.tier=tier;self.learner=learner;self.startedAt=startedAt;self.finishedAt=finishedAt;self.outcome=outcome;self.firstTryNoRecordedHelp=firstTryNoRecordedHelp;self.recordedHelp=recordedHelp;self.retry=retry;self.freshness=freshness}
}
/// A finished existing mini-game, observed as it finished (never inferred from a loaded board). `winner` is the side
/// that won, or nil for a draw; `computer` says whether the learner played the computer as White.
public struct TrainingCompletionEvent:Codable,Equatable,Identifiable {
    public let id:String,kind:String,run:String,winner:String?,drawReason:String?,computer:Bool,origin:String,at:Date
    public init(id:String,kind:String,run:String,winner:String?,drawReason:String?,computer:Bool,origin:String,at:Date){self.id=id;self.kind=kind;self.run=run;self.winner=winner;self.drawReason=drawReason;self.computer=computer;self.origin=origin;self.at=at}
}
/// Descriptive per-entry counters. They are never pruned; the bounded event and attempt lists behind them are.
public struct TrainingEntrySummary:Codable,Equatable {
    public var attempts=0,firstTryNoRecordedHelp=0,assistedCompletions=0,practiceCompletions=0,incorrect=0,revealed=0,abandoned=0
    /// Finished legacy mini-games; the meaning depends on the kind. Against the computer: results from the learner's
    /// (White's) side. Two-player: only `twoPlayerFinishes`. Solo (Knight Corners): `legacyWins` counts completed routes,
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
    public var active:TrainingSessionSnapshot?
    public var attempts:[TrainingAttempt]=[]
    public var events:[TrainingCompletionEvent]=[]
    public var summaries:[String:TrainingEntrySummary]=[:]
    public var retryQueue:[TrainingRetryItem]=[]
    /// Fingerprints of positions already attempted, so a retry is never counted as a first try (bounded, newest kept).
    public var attemptedPositions:[String]=[]
    /// The legacy run already credited with a completion, per mini-game: undo and replay within that run never
    /// add another event; a restarted game is a new run.
    public var creditedRuns:[String:String]=[:]
    /// Finished attempts other than abandoned ones, including pruned ones (the retry queue counts from this).
    public var finishedAttempts=0
    public init(){}
    /// Fails on any record this build could not have written: an unreadable record is preserved raw instead.
    public func validate()throws {
        func fail(_ reason:String)throws -> Never {throw CheckmateError.invalid("Training record: \(reason)")}
        guard version==Self.version else{try fail("unsupported version \(version)")}
        guard attempts.count<=Self.maximumAttempts,events.count<=Self.maximumEvents,retryQueue.count<=Self.maximumRetries,attemptedPositions.count<=Self.maximumPositions,(0...Self.maximumCount).contains(finishedAttempts) else{try fail("exceeds its bounds")}
        guard Set(attempts.map(\.id)).count==attempts.count,Set(events.map(\.id)).count==events.count,Set(retryQueue.map(\.id)).count==retryQueue.count else{try fail("duplicate identifiers")}
        guard creditedRuns.keys.allSatisfy({MiniGameKind(rawValue:$0) != nil}),events.allSatisfy({MiniGameKind(rawValue:$0.kind) != nil}) else{try fail("unknown mini-game")}
        for summary in summaries.values {
            let outcomes=[summary.firstTryNoRecordedHelp,summary.assistedCompletions,summary.practiceCompletions,summary.incorrect,summary.revealed,summary.abandoned]
            guard ([summary.attempts,summary.legacyWins,summary.legacyLosses,summary.legacyDraws,summary.twoPlayerFinishes]+outcomes).allSatisfy({(0...Self.maximumCount).contains($0)}),summary.clusters.count<=Self.maximumClusters,summary.days.count<=Self.maximumDays else{try fail("invalid summary")}
            // Every attempt adds exactly one outcome, so they total the attempts (both capped alike at the ceiling).
            guard min(outcomes.reduce(0,+),Self.maximumCount)==summary.attempts,Set(summary.clusters).count==summary.clusters.count,Set(summary.days).count==summary.days.count else{try fail("inconsistent summary")}
        }
        // A retry counts from the finished attempts when it was queued, which can only have grown since.
        // `notBefore` is a `yyyy-MM-dd` record of the day computed when queued (scheduling re-derives it from `addedAt`).
        guard retryQueue.allSatisfy({(0...finishedAttempts).contains($0.afterAttempt) && $0.notBefore.range(of:Self.dayPattern,options:.regularExpression) != nil}) else{try fail("invalid retry item")}
        if let active {
            guard (0...Self.maximumCount).contains(active.revision),active.actions.count<=Self.maximumActions else{try fail("invalid active attempt")}
            // Every hint, reveal and undo records help as it is taken, so one without the flag was not written by this build.
            let helped=active.actions.contains{if case .hint=$0{return true};return $0 == .reveal || $0 == .undo}
            guard active.recordedHelp || !helped else{try fail("help taken but not recorded")}
        }
    }
}
