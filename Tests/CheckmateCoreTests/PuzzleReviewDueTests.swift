import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateApplication

/// Puzzles come back for review on their Leitner schedule (L-11), read against the player's clock.
final class PuzzleReviewDueTests:XCTestCase {
    private var calendar:Calendar {var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:"UTC")!;return c}
    private func day(_ n:Int)->Date {calendar.date(from:DateComponents(year:2026,month:3,day:n,hour:10))!}
    @MainActor func testAMissComesBackTomorrowAndACleanSolveLater()throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);defer{p.shutdown()}
        var clock=day(1);p.now={clock};p.calendar=calendar
        XCTAssertEqual(p.dueCount,0,"nothing tried, nothing due")
        p.openPuzzle(id:"course:intro:1");p.choose("Black");p.choose("White")
        p.openPuzzle(id:"extra-1");p.click("f3");p.click("h4");XCTAssertTrue(p.passed)
        XCTAssertEqual(s.state.puzzles["course:intro:1"]?.lastAttempt,day(1));XCTAssertEqual(s.state.puzzles["course:intro:1"]?.box,1)
        XCTAssertEqual(s.state.puzzles["extra-1"]?.box,2)
        XCTAssertEqual(p.dueCount,0,"nothing is due the same day")
        clock=day(2);XCTAssertEqual(p.dueCount,1,"the miss is due tomorrow")
        p.filter = .due;XCTAssertEqual(p.filteredPuzzles.map(\.id),["course:intro:1"]);p.filter = .all
        clock=day(4);XCTAssertEqual(p.dueCount,2,"the clean solve is due after 3 days")
        p.reviewDue();XCTAssertEqual(p.filter,.due);XCTAssertEqual(p.activePuzzle?.id,p.filteredPuzzles.first?.id);XCTAssertNotNil(p.activePuzzle)
        p.openPuzzle(id:"course:intro:1");p.choose("White");XCTAssertEqual(s.state.puzzles["course:intro:1"]?.box,2,"solved clean when due: one box up");XCTAssertEqual(p.dueCount,1)
        XCTAssertEqual(PuzzleStatusFilter(stored:"due"),.due)
    }
    /// The saved state without its save time, whose keys are sorted so equal states compare equal.
    @MainActor private func snapshot(_ s:GameSession)throws -> Data {var state=s.state;state.savedAt=Date(timeIntervalSince1970:0);let e=JSONEncoder();e.outputFormatting = .sortedKeys;return try e.encode(state)}
    /// Today's Mix (L-29) plays its puzzles in order, ends with its summary, and saves nothing of its own.
    @MainActor func testTodaysMixPlaysItsSetAndSavesNothingOfItsOwn()throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);defer{p.shutdown()}
        var clock=day(1);p.now={clock};p.calendar=calendar
        p.openPuzzle(id:"course:intro:1");p.choose("Black");clock=day(3)
        let filters=s.state.puzzleFilters,expected=TodayMix.compose(p.library.puzzles,progress:s.state.puzzles,explored:Set(s.state.course.completed),at:clock)
        XCTAssertEqual(p.todayMix,expected);XCTAssertEqual(expected.first,"course:intro:1");XCTAssertEqual(expected.count,TodayMix.size)
        let saved=try snapshot(s);p.startTodayMix();XCTAssertEqual(p.activePuzzle?.id,"course:intro:1")
        for id in expected.dropFirst() {p.skip();XCTAssertEqual(p.activePuzzle?.id,id,"the mix goes in its own order")}
        p.skip();XCTAssertNil(p.activePuzzle,"after its last puzzle the mix ends in the library");XCTAssertEqual(p.setSummary?.total,TodayMix.size);XCTAssertTrue(p.mixFinished)
        XCTAssertEqual(s.state.puzzleFilters,filters,"the mix changes no filter")
        XCTAssertEqual(try snapshot(s),saved,"skipping through the mix saves nothing: no daily record, no streak")
        p.openPuzzle(id:"course:intro:2");XCTAssertFalse(p.mixFinished)
    }
    func testABoxOutsideTheLadderIsRefused()throws {
        var state=ApplicationState(),p=PuzzleProgress();p.record(correct:true);p.box=PuzzleProgress.maximumBox+1;state.puzzles["extra-1"]=p
        XCTAssertThrowsError(try StateStore.validate(state))
        p.box=0;state.puzzles["extra-1"]=p;XCTAssertThrowsError(try StateStore.validate(state))
        p.box=PuzzleProgress.maximumBox;state.puzzles["extra-1"]=p;XCTAssertNoThrow(try StateStore.validate(state))
    }
}
