import CheckmateDomain
import Foundation
/// Descriptive progress and a simple retry queue (plan rule 10). Everything here reports what was observed; nothing
/// rates the learner, claims mastery or locks an entry.
public enum TrainingRecommendation {
    /// Other exercises that must finish before a retry is suggested.
    public static let interveningItems=3
    /// What one entry's progress shows. Legacy game results stay separate from exact-task results.
    public struct Progress:Equatable {
        public let firstTryNoRecordedHelp:Int,withRecordedHelp:Int,practice:Int,notSolved:Int,answerShown:Int,clusters:Int,days:Int
        public let gamesWon:Int,gamesLost:Int,gamesDrawn:Int,twoPlayerGames:Int
        /// Solo games (Knight Corners) have no opponent: a finished one is a completed route, never a game won.
        public let routesCompleted:Int
        /// Plain sentences for the library; empty when nothing has been recorded.
        public var lines:[String] {
            var out:[String]=[]
            if firstTryNoRecordedHelp+withRecordedHelp+practice+notSolved+answerShown>0 {
                out.append("Solved on the first try with no recorded help: \(firstTryNoRecordedHelp)")
                if withRecordedHelp>0{out.append("Solved with recorded help: \(withRecordedHelp)")}
                if practice>0{out.append("Solved again in practice: \(practice)")}
                // Both lists keep only their newest entries, so a count at the bound means at least that many.
                func atLeast(_ count:Int,_ bound:Int)->String {count>=bound ? "\(count)+":"\(count)"}
                out.append("Board patterns practised: \(atLeast(clusters,TrainingState.maximumClusters)) · Days practised: \(atLeast(days,TrainingState.maximumDays))")
            }
            if gamesWon+gamesLost+gamesDrawn>0{out.append("Games against the computer: won \(gamesWon), lost \(gamesLost), drawn \(gamesDrawn)")}
            if routesCompleted>0{out.append("Routes completed: \(routesCompleted)")}
            if twoPlayerGames>0{out.append("Two-player games finished: \(twoPlayerGames)")}
            return out
        }
    }
    public static func progress(_ entry:String,in training:TrainingState)->Progress {
        let s=training.summaries[entry] ?? TrainingEntrySummary(),solo=MiniGameKind(rawValue:entry)?.solo==true
        // A solo game records each finished route in `legacyWins`, its only result; its loss and draw counters carry
        // no meaning, so they are never shown or added in.
        return Progress(firstTryNoRecordedHelp:s.firstTryNoRecordedHelp,withRecordedHelp:s.assistedCompletions,practice:s.practiceCompletions,notSolved:s.incorrect,answerShown:s.revealed,clusters:s.clusters.count,days:s.days.count,gamesWon:solo ? 0:s.legacyWins,gamesLost:solo ? 0:s.legacyLosses,gamesDrawn:solo ? 0:s.legacyDraws,twoPlayerGames:s.twoPlayerFinishes,routesCompleted:solo ? s.legacyWins:0)
    }
    /// Why a finished attempt is worth repeating, or nil when it went cleanly. Abandoned attempts are not suggested.
    public static func reason(for outcome:TrainingOutcome,recordedHelp:Bool)->String? {
        switch outcome {
        case .incorrect:return "Not solved last time."
        case .revealed:return "The answer was shown last time."
        case .correct:return recordedHelp ? "Solved with help last time." :nil
        case .abandoned:return nil
        }
    }
    /// Queues the concrete board of a finished attempt that is worth repeating. One item per position; the oldest is
    /// dropped beyond the bound. A finished retry of a queued board removes it; abandoning one leaves it queued.
    /// Items from a newer version count toward the bound and stay: the oldest of this build's own items go instead.
    public static func record(_ snapshot:TrainingSessionSnapshot,outcome:TrainingOutcome,in training:inout TrainingState,now:Date,calendar:Calendar){
        guard outcome != .abandoned else{return}
        let key=TrainingStore.positionKey(snapshot.scenario)
        training.retryQueue.removeAll{TrainingStore.positionKey($0.scenario)==key}
        guard let reason=reason(for:outcome,recordedHelp:snapshot.recordedHelp) else{return}
        training.retryQueue.append(TrainingRetryItem(id:UUID().uuidString,entry:snapshot.entry,scenario:snapshot.scenario,reason:reason,addedAt:now,notBefore:notBefore(now,calendar:calendar),afterAttempt:training.finishedAttempts))
        let excess=training.retryQueue.count+training.newerRetryCount-TrainingState.maximumRetries
        if excess>0{training.retryQueue.removeFirst(min(excess,training.retryQueue.count))}
    }
    /// A queued board and when it becomes a suggestion.
    public struct Suggestion:Equatable {
        public let item:TrainingRetryItem
        /// Due now: at least three other exercises have finished since, and it is the next local day or later.
        public let due:Bool
        /// Why it is suggested, and when, in plain words.
        public let explanation:String
    }
    /// The local day after `added`, as a Gregorian day string.
    static func notBefore(_ added:Date,calendar:Calendar)->String {
        let fixed=TrainingStore.gregorian(calendar)
        return TrainingStore.day(fixed.date(byAdding:.day,value:1,to:fixed.startOfDay(for:added)) ?? added,calendar:calendar)
    }
    public static func suggestions(in training:TrainingState,now:Date,calendar:Calendar)->[Suggestion] {
        let today=TrainingStore.day(now,calendar:calendar)
        return training.retryQueue.map{item in
            // Re-derived from when the item was added, so a day saved under another calendar system never misleads.
            let remaining=max(0,interveningItems-(training.finishedAttempts-item.afterAttempt)),dayReached=today>=notBefore(item.addedAt,calendar:calendar)
            let when:String
            switch (remaining,dayReached) {
            case (0,true):when="Ready to try again."
            case (0,false):when="Ready tomorrow."
            case (let n,true):when="Ready after \(n) more exercise\(n==1 ? "":"s")."
            case (let n,false):when="Ready tomorrow, after \(n) more exercise\(n==1 ? "":"s")."
            }
            return Suggestion(item:item,due:remaining==0 && dayReached,explanation:item.reason+" "+when)
        }.sorted{($0.due ? 0:1,$0.item.addedAt)<($1.due ? 0:1,$1.item.addedAt)}
    }
    /// How a new board relates to what the learner has seen; a repeat says so instead of pretending to be new.
    public static func freshnessLabel(_ freshness:String)->String? {
        switch TrainingFreshness(rawValue:freshness) {
        case .reserve:return "A board pattern held back for fresh practice."
        case .repeat:return "This board repeats a pattern you have seen."
        default:return nil
        }
    }
}
