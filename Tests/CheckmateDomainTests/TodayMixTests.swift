import XCTest
import CheckmateDomain
/// Today's Mix (L-29) is a short optional set: a few puzzles due for review, then new ones from lessons the learner has
/// explored. It keeps no daily record, so a missed day costs nothing, and its words never scold.
final class TodayMixTests:XCTestCase {
    private var calendar:Calendar {var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:"UTC")!;return c}
    private func day(_ n:Int)->Date {calendar.date(from:DateComponents(year:2026,month:3,day:n,hour:10))!}
    private func missed(on n:Int)->PuzzleProgress {var p=PuzzleProgress();p.record(correct:false,at:day(n),calendar:calendar);return p}
    private func solved(on n:Int)->PuzzleProgress {var p=PuzzleProgress();p.record(correct:true,at:day(n),calendar:calendar);return p}
    func testDueReviewsComeFirstThenNewPuzzlesFromExploredLessons()throws {
        let puzzles=try CourseLibrary().puzzles
        var progress=["course:intro:1":missed(on:1),"course:intro:2":missed(on:1),"course:board:1":missed(on:1),"course:board:2":missed(on:1),"course:pawn:1":solved(on:4)]
        let mix=TodayMix.compose(puzzles,progress:progress,explored:["fork"],at:day(5))
        XCTAssertEqual(mix,["course:intro:1","course:intro:2","course:board:1","course:fork:1","course:fork:2"],"three reviews, then new puzzles from an explored lesson first")
        XCTAssertEqual(TodayMix.compose(puzzles,progress:progress,explored:[],at:day(1)),["course:pawn:2","course:pawn-duel:1","course:pawn-duel:2","course:rook:1","course:rook:2"],"nothing is due on the day it was missed")
        progress=Dictionary(uniqueKeysWithValues:puzzles.map{($0.id,solved(on:1))})
        XCTAssertEqual(TodayMix.compose(puzzles,progress:progress,explored:[],at:day(2)),[],"everything solved and nothing due: no mix")
        XCTAssertEqual(TodayMix.compose(puzzles,progress:progress,explored:[],at:day(4)).count,TodayMix.size,"with nothing new, more reviews fill the mix, never past its size")
    }
    /// The learners are children: the mix's words invite and never count days or warn about losing anything.
    func testTheWordsNeverScold(){
        let words=[TodayMix.title,TodayMix.detail,TodayMix.finished].joined(separator:" ").lowercased()
        for scold in ["streak","miss","lose","lost","behind","late","overdue","every day","don’t forget","don't forget","yesterday"] {XCTAssertFalse(words.contains(scold),scold)}
        XCTAssertEqual(TodayMix.title,"Today’s Mix")
    }
}
