import XCTest
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateApplication

/// What the puzzle library rows and the course-complete card show and read to VoiceOver; the views draw these values.
@MainActor final class LearningPresentationTests:XCTestCase {
    private func puzzle(_ id:String)throws -> Puzzle {try XCTUnwrap(CourseLibrary().puzzles.first{$0.id==id})}

    /// A row shows its topic and level, a review marker when it is queued for review, and a solved or solved-with-help
    /// mark; VoiceOver reads its standing, the review marker and its level.
    func testAPuzzleRowShowsAndReadsItsStandingReviewMarkerAndLevel()throws {
        let p=try puzzle("extra-1")
        let fresh=PuzzleRowFormat(p,record:PuzzleProgress())
        XCTAssertEqual(fresh.title,p.title);XCTAssertEqual(fresh.detail,"\(p.topic) · \(p.level)");XCTAssertFalse(fresh.review);XCTAssertNil(fresh.mark)
        XCTAssertEqual(fresh.accessibilityValue,"Not tried, \(p.level)")
        var missed=PuzzleProgress();missed.record(correct:false)
        let wrong=PuzzleRowFormat(p,record:missed);XCTAssertTrue(wrong.review);XCTAssertNil(wrong.mark);XCTAssertEqual(wrong.accessibilityValue,"Not solved yet, to review, \(p.level)")
        var hinted=PuzzleProgress();hinted.record(correct:true,hints:1)
        let helped=PuzzleRowFormat(p,record:hinted);XCTAssertTrue(helped.review);XCTAssertEqual(helped.mark,.notFirstTry)
        XCTAssertEqual(helped.accessibilityValue,"Solved with hints, to review, \(p.level)")
        var corrected=PuzzleProgress();corrected.record(correct:false);corrected.record(correct:true,afterMistake:true)
        let later=PuzzleRowFormat(p,record:corrected);XCTAssertTrue(later.review);XCTAssertEqual(later.mark,.notFirstTry);XCTAssertEqual(later.markHelp,"Solved on a later try")
        XCTAssertEqual(later.accessibilityValue,"Solved on a later try, to review, \(p.level)");XCTAssertEqual(helped.markHelp,"Solved with hints")
        var alone=PuzzleProgress();alone.record(correct:true)
        let solved=PuzzleRowFormat(p,record:alone);XCTAssertEqual(solved.markHelp,"Solved");XCTAssertFalse(solved.review);XCTAssertEqual(solved.mark,.solved);XCTAssertEqual(solved.accessibilityValue,"Solved, \(p.level)")
        XCTAssertEqual(PuzzleRowFormat.Mark.solved.symbol.rawValue,"checkmark.circle.fill");XCTAssertEqual(PuzzleRowFormat.Mark.notFirstTry.symbol.rawValue,"checkmark.circle","a solve that was not first try is told apart from mastery")
    }
    /// The library heading counts assisted and later solves as solved, and still counts them to review.
    func testTheLibraryHeadingCountsAssistedSolves(){
        var hinted=PuzzleProgress();hinted.record(correct:true,hints:1);var alone=PuzzleProgress();alone.record(correct:true);var missed=PuzzleProgress();missed.record(correct:false)
        var later=PuzzleProgress();later.record(correct:false);later.record(correct:true,afterMistake:true)
        XCTAssertEqual(PuzzleRowFormat.heading(["a":hinted,"b":alone,"c":missed,"d":later]),"3 solved · 3 to review")
    }
    /// The course-complete card appears on the last main lesson once every main lesson is explored, and offers next steps.
    func testTheCourseCompleteCardAppearsAtTheEndOfAFinishedCourse()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let lessons=model.learning.library.lessons,main=lessons.filter{!$0.isPractice}.map(\.id),last=try XCTUnwrap(lessons.lastIndex{!$0.isPractice})
        // The model's saved progress may hold other tests' lessons, so the starting point is set, not assumed.
        model.lesson(last);model.learning.pause();model.session.state.course.completed=Array(main.dropLast())
        XCTAssertFalse(CourseCompleteCard.shown(model.learning),"the course is not finished yet")
        model.session.state.course.completed=main;XCTAssertTrue(CourseCompleteCard.shown(model.learning))
        model.lesson(0);model.learning.pause();XCTAssertFalse(CourseCompleteCard.shown(model.learning),"an earlier lesson continues to the next one instead")
        XCTAssertEqual(CourseCompleteCard.title,"You Explored the Whole Course")
        XCTAssertEqual(CourseCompleteCard.actions(trainingAvailable:true).map(\.title),["Quick Puzzles","Training","Play a Game"])
        XCTAssertEqual(CourseCompleteCard.actions(trainingAvailable:false).map(\.title),["Quick Puzzles","Play a Game"])
        XCTAssertEqual(CourseCompleteCard.message(trainingAvailable:true),"Keep your skills sharp with puzzles, training or a game.")
        XCTAssertEqual(CourseCompleteCard.message(trainingAvailable:false),"Keep your skills sharp with puzzles or a game.")
    }
}
