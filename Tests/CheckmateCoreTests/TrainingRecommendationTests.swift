import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-006: descriptive progress and the simple retry queue, with an injected clock and time zone. A retry is due only
/// after three other exercises and on or after the next local day; nothing locks, and a repeat is never new evidence.
@MainActor final class TrainingRecommendationTests:XCTestCase {
    private func calendar(_ zone:String="UTC")->Calendar {var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:zone)!;return c}
    private let monday=ISO8601DateFormatter().date(from:"2027-03-01T10:00:00Z")!
    private func scenario(_ n:Int,cluster:String="c")->TrainingScenario {
        TrainingScenario(id:"t\(n)",entry:"reach-target",variant:"rook",tier:1,cluster:cluster,learner:"w",prompt:"Reach h8.",explanation:"x",hints:["h"],drill:MovementDrill(piece:"wr",start:"a\(n)",target:"h8",pieces:[:]),budget:2)
    }
    private func finish(_ n:Int,_ outcome:TrainingOutcome,help:Bool=false,cluster:String="c",in state:inout ApplicationState,at date:Date,calendar:Calendar)throws {
        let snapshot=TrainingSessionSnapshot(id:"s\(n)-\(date.timeIntervalSince1970)",entry:"reach-target",scenario:scenario(n,cluster:cluster),freshness:"new",startedAt:date,recordedHelp:help,retry:TrainingStore.attempted(scenario(n,cluster:cluster),in:state.training ?? TrainingState()))
        try TrainingStore.finish(snapshot,outcome:outcome,in:&state,now:date,calendar:calendar)
    }
    func testARetryWaitsForThreeOtherItemsAndTheNextLocalDay()throws {
        var state=ApplicationState();let utc=calendar()
        try finish(1,.incorrect,in:&state,at:monday,calendar:utc)
        var suggestion=try XCTUnwrap(TrainingRecommendation.suggestions(in:state.training!,now:monday,calendar:utc).first)
        XCTAssertFalse(suggestion.due);XCTAssertEqual(suggestion.explanation,"Not solved last time. Ready tomorrow, after 3 more exercises.")
        for n in 2...4 {try finish(n,.correct,in:&state,at:monday,calendar:utc)}
        suggestion=try XCTUnwrap(TrainingRecommendation.suggestions(in:state.training!,now:monday,calendar:utc).first)
        XCTAssertFalse(suggestion.due,"three items are not enough on the same day");XCTAssertEqual(suggestion.explanation,"Not solved last time. Ready tomorrow.")
        let tuesday=monday.addingTimeInterval(86_400)
        XCTAssertTrue(try XCTUnwrap(TrainingRecommendation.suggestions(in:state.training!,now:tuesday,calendar:utc).first).due)
        // The next day alone is not enough either.
        var other=ApplicationState();try finish(1,.revealed,in:&other,at:monday,calendar:utc)
        let waiting=try XCTUnwrap(TrainingRecommendation.suggestions(in:other.training!,now:tuesday,calendar:utc).first)
        XCTAssertFalse(waiting.due);XCTAssertEqual(waiting.explanation,"The answer was shown last time. Ready after 3 more exercises.")
    }
    func testTheNextDayIsTheLearnersLocalDay()throws {
        // 23:30 in Tokyo is 14:30 UTC: thirty-one minutes later it is already the next day in Tokyo, not in UTC.
        let late=ISO8601DateFormatter().date(from:"2027-03-01T14:30:00Z")!,soon=late.addingTimeInterval(31*60)
        for (zone,dueSoon) in [("Asia/Tokyo",true),("UTC",false)] {
            var state=ApplicationState();let local=calendar(zone)
            try finish(1,.incorrect,in:&state,at:late,calendar:local);for n in 2...4{try finish(n,.correct,in:&state,at:late,calendar:local)}
            XCTAssertEqual(TrainingRecommendation.suggestions(in:state.training!,now:soon,calendar:local).first?.due,dueSoon,zone)
        }
    }
    func testOnlyBoardsWorthRepeatingAreQueued()throws {
        var state=ApplicationState();let utc=calendar()
        try finish(1,.correct,in:&state,at:monday,calendar:utc);try finish(2,.abandoned,in:&state,at:monday,calendar:utc)
        XCTAssertEqual(state.training?.retryQueue.count,0,"a clean first try and an abandoned board are not suggested")
        try finish(3,.correct,help:true,in:&state,at:monday,calendar:utc)
        XCTAssertEqual(state.training?.retryQueue.map(\.reason),["Solved with help last time."])
        XCTAssertEqual(state.training?.summaries["reach-target"]?.assistedCompletions,1);XCTAssertEqual(state.training?.summaries["reach-target"]?.firstTryNoRecordedHelp,1)
        // The same board again replaces its own item rather than queueing a second.
        try finish(3,.incorrect,in:&state,at:monday,calendar:utc);XCTAssertEqual(state.training?.retryQueue.map(\.reason),["Not solved last time."])
        // Bounded: the oldest suggestions are dropped first.
        for n in 10..<(10+TrainingState.maximumRetries+5){try finish(n,.incorrect,in:&state,at:monday,calendar:utc)}
        XCTAssertEqual(state.training?.retryQueue.count,TrainingState.maximumRetries);XCTAssertNoThrow(try state.training?.validate())
    }
    func testARetriedBoardIsPracticeAndLeavesTheQueue()throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session);defer{player.shutdown()}
        let controller=TrainingController(session:session,learning:player);controller.now={[monday] in monday};controller.calendar=calendar()
        controller.begin(try controller.prepare(entry:"mate-in-one"));controller.reveal()
        let item=try XCTUnwrap(session.state.training?.retryQueue.first)
        XCTAssertThrowsError(try controller.prepareRetry(id:"missing"))
        // Not due yet, and still available: suggestions never lock.
        XCTAssertFalse(try XCTUnwrap(controller.suggestions.first).due)
        controller.begin(try controller.prepareRetry(id:item.id))
        XCTAssertEqual(controller.exercise?.scenario,item.scenario);XCTAssertTrue(controller.exercise?.snapshot.retry ?? false);XCTAssertEqual(controller.exercise?.snapshot.freshness,"repeat")
        let move=try XCTUnwrap(item.scenario.expected?.moves?.first)
        controller.attempt(from:String(move.prefix(2)),to:String(move.dropFirst(2).prefix(2)),promotion:move.count==5 ? String(move.suffix(1)):nil)
        XCTAssertEqual(controller.exercise?.status,.correct)
        let summary=try XCTUnwrap(session.state.training?.summaries["mate-in-one"])
        XCTAssertEqual(summary.firstTryNoRecordedHelp,0,"a repeated board is never another first try");XCTAssertEqual(summary.practiceCompletions,1)
        XCTAssertTrue(session.state.training?.retryQueue.isEmpty ?? false,"a clean retry leaves the queue")
        XCTAssertEqual(summary.clusters.count,1,"the same pattern twice is one practised pattern")
    }
    func testAnExhaustedPoolSaysItRepeats()throws {
        let bundled=try TrainingScenarioProvider.bundled()
        let one=try XCTUnwrap(bundled.scenarios(for:"mate-in-one").first{$0.reserve != true}),reserved=try XCTUnwrap(bundled.scenarios(for:"mate-in-one").first{$0.reserve==true})
        let provider=try TrainingScenarioProvider(catalog:bundled.catalog,scenarios:[one,reserved]),definition=try XCTUnwrap(bundled.catalog.entry("mate-in-one"))
        guard case .scenario(let first,let fresh)=provider.next(for:definition,seen:[],seed:1) else{return XCTFail("no board")}
        XCTAssertEqual(first.id,one.id);XCTAssertEqual(fresh,.new);XCTAssertNil(TrainingRecommendation.freshnessLabel(fresh.rawValue))
        guard case .scenario(let second,let held)=provider.next(for:definition,seen:[one.cluster],seed:1) else{return XCTFail("no board")}
        XCTAssertEqual(second.id,reserved.id);XCTAssertEqual(held,.reserve);XCTAssertNotNil(TrainingRecommendation.freshnessLabel(held.rawValue))
        guard case .scenario(_,let again)=provider.next(for:definition,seen:[one.cluster,reserved.cluster],seed:1) else{return XCTFail("a tiny pool still offers a labelled repeat")}
        XCTAssertEqual(again,.repeat);XCTAssertEqual(TrainingRecommendation.freshnessLabel(again.rawValue),"This board repeats a pattern you have seen.")
    }
    func testPrunedHistoryNeverMakesAnOldBoardLookNew()throws {
        var state=ApplicationState();let utc=calendar()
        try finish(1,.incorrect,in:&state,at:monday,calendar:utc)
        for n in 2...(TrainingState.maximumAttempts+20){try finish(n,.correct,cluster:"c\(n)",in:&state,at:monday,calendar:utc)}
        XCTAssertFalse(state.training!.attempts.contains{$0.scenarioID=="t1"},"fixture: the first attempt was pruned")
        XCTAssertTrue(TrainingStore.attempted(scenario(1),in:state.training!),"the position is still known as attempted")
        XCTAssertTrue(state.training!.retryQueue.contains{$0.scenario.id=="t1"},"its retry item survives pruning")
        XCTAssertEqual(state.training!.summaries["reach-target"]?.clusters.count,TrainingState.maximumAttempts+20,"distinct patterns are counted once each")
    }
    func testProgressKeepsGameResultsApartFromExerciseResults()throws {
        var training=TrainingState();var summary=TrainingEntrySummary();summary.firstTryNoRecordedHelp=2;summary.assistedCompletions=1;summary.clusters=["a","b"];summary.days=["2027-03-01"]
        training.summaries["mate-in-one"]=summary
        var games=TrainingEntrySummary();games.legacyWins=3;games.legacyLosses=1;games.twoPlayerFinishes=2;training.summaries["pawn-duel"]=games
        XCTAssertEqual(TrainingRecommendation.progress("mate-in-one",in:training).lines,["Solved on the first try with no recorded help: 2","Solved with recorded help: 1","Board patterns practised: 2 · Days practised: 1"])
        XCTAssertEqual(TrainingRecommendation.progress("pawn-duel",in:training).lines,["Games against the computer: won 3, lost 1, drawn 0","Two-player games finished: 2"])
        XCTAssertEqual(TrainingRecommendation.progress("escape-check",in:training).lines,[])
        let words=(TrainingRecommendation.progress("mate-in-one",in:training).lines+TrainingRecommendation.progress("pawn-duel",in:training).lines).joined(separator:" ").lowercased()
        for claim in ["master","rating","level","unassisted","transfer"]{XCTAssertFalse(words.contains(claim),claim)}
    }
    func testAnAbandonedRetryStaysQueuedAndIsNotCounted()throws {
        var state=ApplicationState();let utc=calendar()
        try finish(1,.incorrect,in:&state,at:monday,calendar:utc)
        let counted=state.training!.finishedAttempts
        try finish(1,.abandoned,in:&state,at:monday,calendar:utc)
        XCTAssertTrue(state.training!.retryQueue.contains{$0.scenario.id=="t1"},"leaving a retry does not drop it")
        XCTAssertEqual(state.training!.finishedAttempts,counted,"an abandoned attempt does not advance retry spacing")
    }
    func testACounterAtItsLimitRefusesToRecordInsteadOfCapping()throws {
        var state=ApplicationState();let utc=calendar()
        var full=TrainingState();full.finishedAttempts=TrainingState.maximumCount;XCTAssertNoThrow(try full.validate(),"fixture: a record at the limit loads")
        state.training=full
        XCTAssertThrowsError(try finish(1,.incorrect,in:&state,at:monday,calendar:utc),"one more would pass the bound")
        XCTAssertEqual(state.training,full,"nothing was recorded")
    }
}
