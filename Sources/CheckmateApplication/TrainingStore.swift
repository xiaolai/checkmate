import CheckmateDomain
import Foundation
/// Writes descriptive training records into the global state. Every change here is saved by the same atomic state
/// write as the board change it accompanies (plan rule 11); nothing is written while the record is kept raw.
public enum TrainingStore {
    /// The learner's local calendar day, for days practised and the next-day retry rule. Always Gregorian in the
    /// learner's time zone, so a saved day keeps its meaning when the system calendar changes.
    public static func day(_ date:Date,calendar:Calendar)->String {let c=gregorian(calendar).dateComponents([.year,.month,.day],from:date);return String(format:"%04d-%02d-%02d",c.year ?? 0,c.month ?? 0,c.day ?? 0)}
    /// The Gregorian calendar in `calendar`'s time zone: local days, independent of the chosen calendar system.
    static func gregorian(_ calendar:Calendar)->Calendar {var fixed=Calendar(identifier:.gregorian);fixed.timeZone=calendar.timeZone;return fixed}
    /// A fingerprint of a concrete position, so a retry of the same board is recognised after its attempt is pruned.
    public static func positionKey(_ scenario:TrainingScenario)->String {
        var hash:UInt64=0xcbf29ce484222325
        let text=[scenario.entry,scenario.fen ?? "",(scenario.prelude ?? []).joined(separator:","),scenario.target ?? "",scenario.learner,scenario.drill.map{$0.piece+$0.start+$0.target} ?? "",(scenario.diagram ?? scenario.drill?.pieces ?? [:]).sorted{$0.key<$1.key}.map{$0.key+$0.value}.joined()].joined(separator:"|")
        for byte in text.utf8{hash=(hash ^ UInt64(byte)) &* 0x100000001b3}
        return String(hash,radix:16)
    }
    /// Whether this exact position was attempted before. A queued retry counts too: its board stays queued after the
    /// bounded fingerprint list has dropped it.
    public static func attempted(_ scenario:TrainingScenario,in training:TrainingState)->Bool {
        let key=positionKey(scenario)
        return training.attemptedPositions.contains(key) || training.retryQueue.contains{positionKey($0.scenario)==key}
    }
    /// Records a finished attempt and updates its entry's counters. Returns the attempt recorded.
    @discardableResult public static func finish(_ snapshot:TrainingSessionSnapshot,outcome:TrainingOutcome,in state:inout ApplicationState,now:Date,calendar:Calendar)throws -> TrainingAttempt {
        guard state.trainingWritable else{throw CheckmateError.unavailable("Training progress is read-only until its saved record is recovered.")}
        var training=state.training ?? TrainingState()
        let scenario=snapshot.scenario,firstTry=outcome == .correct && !snapshot.retry && !snapshot.recordedHelp
        // A game records the level it was played at (mini-game plan D4), settled as a resume settles it: an attempt
        // left unopened since an older build played on is mixed, and one begun before levels is legacy.
        let opponent=snapshot.settledOpponent
        let attempt=TrainingAttempt(id:UUID().uuidString,entry:snapshot.entry,scenarioID:scenario.id,cluster:scenario.cluster,tier:scenario.tier,learner:scenario.learner,startedAt:snapshot.startedAt,finishedAt:now,outcome:outcome,firstTryNoRecordedHelp:firstTry,recordedHelp:snapshot.recordedHelp,retry:snapshot.retry,freshness:snapshot.freshness,opponent:opponent)
        // Retry spacing counts exercises actually done, so opening and leaving boards never makes a retry due.
        training.attempts.append(attempt);if outcome != .abandoned{training.finishedAttempts=training.finishedAttempts+1}
        var summary=training.summaries[snapshot.entry] ?? TrainingEntrySummary()
        summary.attempts=summary.attempts+1
        switch outcome {
        case .correct:if firstTry{summary.firstTryNoRecordedHelp=summary.firstTryNoRecordedHelp+1}else if snapshot.recordedHelp{summary.assistedCompletions=summary.assistedCompletions+1}else{summary.practiceCompletions=summary.practiceCompletions+1}
        case .incorrect:summary.incorrect=summary.incorrect+1
        case .revealed:summary.revealed=summary.revealed+1
        case .abandoned:summary.abandoned=summary.abandoned+1
        }
        if outcome != .abandoned {
            // Moved to the end when practised again, so pruning from the front drops the least recent first.
            summary.clusters.removeAll{$0==scenario.cluster};summary.clusters.append(scenario.cluster)
            let today=day(now,calendar:calendar);if !summary.days.contains(today){summary.days.append(today)}
            let key=positionKey(scenario);training.attemptedPositions.removeAll{$0==key};training.attemptedPositions.append(key)
        }
        training.summaries[snapshot.entry]=summary
        if training.active?.id==snapshot.id{training.active=nil}
        TrainingRecommendation.record(snapshot,outcome:outcome,in:&training,now:now,calendar:calendar)
        prune(&training)
        guard withinBudget(training) else{throw CheckmateError.unavailable("Training progress is full: its retained records no longer fit. Nothing was recorded.")}
        // Counters are bounded on load; a record that would pass a bound is refused rather than silently capped.
        guard (try? training.validate()) != nil else{throw CheckmateError.unavailable("Training progress has reached its limits. Nothing was recorded.")}
        state.training=training;return attempt
    }
    /// The explicit recovery for an unreadable training record: training starts afresh. The rolling save backup still
    /// holds the old record, and an export taken first keeps it verbatim. A newer version's record is never replaced.
    public static func resetUnreadable(in state:inout ApplicationState)throws {
        guard state.trainingRaw != nil,state.trainingIssue != "future" else{throw CheckmateError.invalid(state.trainingIssue=="future" ? "This training progress was saved by a newer version of Checkmate and is kept unchanged.":"Training progress is readable; there is nothing to reset.")}
        state.trainingRaw=nil;state.trainingIssue=nil;state.training=TrainingState()
    }
    /// Records a legacy mini-game that has just finished, unless this run was already credited (undo and replay within
    /// a run never add another event). Old saves without an opponent seed form one run until the game restarts.
    /// Nothing is recorded when the retained records would no longer fit the training budget. A game against the
    /// computer records its run's level and whether it is exact.
    @discardableResult public static func recordLegacyCompletion(_ game:MiniGameState,origin:String,in state:inout ApplicationState,now:Date,calendar:Calendar)->TrainingCompletionEvent? {
        guard state.trainingWritable,game.isFinished else{return nil}
        var training=state.training ?? TrainingState()
        let run=game.run
        guard training.creditedRuns[game.kind.rawValue] != run else{return nil}
        let winner=game.winner,event=TrainingCompletionEvent(id:UUID().uuidString,kind:game.kind.rawValue,run:run,winner:winner,drawReason:game.drawReason,computer:game.computer,origin:origin,at:now,level:game.computer ? game.runLevel:nil)
        training.events.append(event);training.creditedRuns[game.kind.rawValue]=run
        var summary=training.summaries[game.kind.rawValue] ?? TrainingEntrySummary()
        // A solo game finishes only by completing its route, which counts in `legacyWins` (see TrainingEntrySummary).
        if game.kind.solo{summary.legacyWins=summary.legacyWins+1}else if !game.computer{summary.twoPlayerFinishes=summary.twoPlayerFinishes+1}else if winner=="w"{summary.legacyWins=summary.legacyWins+1}else if winner=="b"{summary.legacyLosses=summary.legacyLosses+1}else{summary.legacyDraws=summary.legacyDraws+1}
        let today=day(now,calendar:calendar);if !summary.days.contains(today){summary.days.append(today)}
        training.summaries[game.kind.rawValue]=summary
        prune(&training);guard withinBudget(training),(try? training.validate()) != nil else{return nil}
        state.training=training;return event
    }
    /// Keeps the newest bounded records. Counters, the active attempt and retry items (with their concrete
    /// positions) are never discarded by summary pruning.
    public static func prune(_ training:inout TrainingState){
        if training.events.count>TrainingState.maximumEvents{training.events.removeFirst(training.events.count-TrainingState.maximumEvents)}
        if training.attempts.count>TrainingState.maximumAttempts{training.attempts.removeFirst(training.attempts.count-TrainingState.maximumAttempts)}
        if training.attemptedPositions.count>TrainingState.maximumPositions{training.attemptedPositions.removeFirst(training.attemptedPositions.count-TrainingState.maximumPositions)}
        for (entry,var summary) in training.summaries {
            if summary.clusters.count>TrainingState.maximumClusters{summary.clusters.removeFirst(summary.clusters.count-TrainingState.maximumClusters)}
            if summary.days.count>TrainingState.maximumDays{summary.days.removeFirst(summary.days.count-TrainingState.maximumDays)}
            training.summaries[entry]=summary
        }
        // Over the byte budget, finished attempt records go first (oldest), then completion events.
        if !withinBudget(training){dropOldest(\.attempts,from:&training)}
        if !withinBudget(training){dropOldest(\.events,from:&training)}
    }
    /// Removes the fewest oldest records that bring the state within budget (all of them if none suffices). The
    /// encoded size only shrinks as records go, so bisection needs a few encodings instead of one per record.
    private static func dropOldest<Record>(_ records:WritableKeyPath<TrainingState,[Record]>,from training:inout TrainingState){
        var low=0,high=training[keyPath:records].count
        while low<high {
            let mid=(low+high)/2;var trial=training;trial[keyPath:records].removeFirst(mid)
            if withinBudget(trial){high=mid}else{low=mid+1}
        }
        training[keyPath:records].removeFirst(low)
    }
    /// Whether `snapshot` can be saved as the active attempt within the training budget, after pruning disposable
    /// records. Never makes room by touching the real practice game. While a newer version's attempt holds the slot,
    /// `snapshot` is never saved (`TrainingController.save`), so only the record as it stands must fit.
    public static func fits(_ snapshot:TrainingSessionSnapshot,in training:TrainingState)->Bool {
        var trial=training;if trial.newerActive==nil{trial.active=snapshot};prune(&trial)
        return withinBudget(trial)
    }
    /// Whether the record encodes within its byte budget; a record that cannot be encoded does not fit.
    static func withinBudget(_ training:TrainingState)->Bool {((try? JSONEncoder().encode(training).count) ?? Int.max)<=TrainingState.maximumBytes}
}
