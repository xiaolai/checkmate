import XCTest
import CheckmateDomain
/// Puzzle review follows Leitner boxes (L-11): a clean solve when due moves a puzzle up one box and further out, any miss,
/// hint or reveal sends it back to box 1 for tomorrow, and older records without a schedule still load.
final class PuzzleScheduleTests:XCTestCase {
    private var calendar:Calendar {var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:"UTC")!;return c}
    private func day(_ n:Int,hour:Int=10)->Date {calendar.date(from:DateComponents(year:2026,month:3,day:n,hour:hour))!}
    private func midnight(_ n:Int)->Date {day(n,hour:0)}
    func testACleanSolveMovesUpOneBoxAndAMissStartsAgain(){
        var p=PuzzleProgress();XCTAssertNil(p.box);XCTAssertNil(p.dueAt);XCTAssertNil(p.lastAttempt);XCTAssertFalse(p.isDue(at:day(1)),"a puzzle never tried is not due for review")
        p.record(correct:true,at:day(1),calendar:calendar)
        XCTAssertEqual(p.box,2);XCTAssertEqual(p.dueAt,midnight(4),"box 2 comes back after 3 days");XCTAssertEqual(p.lastAttempt,day(1))
        XCTAssertFalse(p.isDue(at:day(3,hour:23)));XCTAssertTrue(p.isDue(at:midnight(4)))
        p.record(correct:true,at:day(2),calendar:calendar);XCTAssertEqual(p.box,2,"a solve before it is due leaves the schedule alone");XCTAssertEqual(p.dueAt,midnight(4));XCTAssertEqual(p.lastAttempt,day(2))
        p.record(correct:true,at:day(5),calendar:calendar);XCTAssertEqual(p.box,3);XCTAssertEqual(p.dueAt,midnight(12))
        p.record(correct:false,at:day(12),calendar:calendar);XCTAssertEqual(p.box,1,"a miss starts again");XCTAssertEqual(p.dueAt,midnight(13),"and comes back tomorrow")
        p.record(correct:true,afterMistake:true,at:day(12),calendar:calendar);XCTAssertEqual(p.box,1,"a solve after a miss in the same visit is not clean");XCTAssertEqual(p.dueAt,midnight(13))
        var hinted=PuzzleProgress();hinted.record(correct:true,hints:1,at:day(1),calendar:calendar);XCTAssertEqual(hinted.box,1);XCTAssertEqual(hinted.dueAt,midnight(2))
        var revealed=PuzzleProgress();revealed.record(correct:false,revealed:true,at:day(1),calendar:calendar);XCTAssertEqual(revealed.box,1);XCTAssertEqual(revealed.dueAt,midnight(2))
    }
    func testTheTopBoxStaysTheTopBox(){
        var p=PuzzleProgress();var now=day(1)
        for _ in 0..<8 {p.record(correct:true,at:now,calendar:calendar);now=p.dueAt!}
        XCTAssertEqual(p.box,PuzzleProgress.maximumBox);XCTAssertEqual(PuzzleProgress.boxDays.count,PuzzleProgress.maximumBox)
        let last=p.lastAttempt!;XCTAssertEqual(calendar.dateComponents([.day],from:calendar.startOfDay(for:last),to:p.dueAt!).day,PuzzleProgress.boxDays.last)
    }
    /// A record saved before the schedule existed loads without one; it is due exactly when it was queued for review.
    func testAnOlderRecordLoadsWithoutASchedule()throws {
        let queued=try JSONDecoder().decode(PuzzleProgress.self,from:Data(#"{"solved":false,"review":true,"attempts":1}"#.utf8))
        XCTAssertNil(queued.box);XCTAssertNil(queued.dueAt);XCTAssertNil(queued.lastAttempt);XCTAssertTrue(queued.isDue(at:day(1)))
        let solved=try JSONDecoder().decode(PuzzleProgress.self,from:Data(#"{"solved":true,"review":false,"attempts":1}"#.utf8))
        XCTAssertFalse(solved.isDue(at:day(1)))
        var p=PuzzleProgress();p.record(correct:true,at:day(1),calendar:calendar);var state=ApplicationState();state.puzzles["one"]=p
        let again=try JSONDecoder().decode(ApplicationState.self,from:JSONEncoder().encode(state))
        XCTAssertEqual(again.puzzles["one"],p);XCTAssertTrue(again.unknownFields.isEmpty);XCTAssertTrue(again.unknownNestedFields.isEmpty)
    }
}
