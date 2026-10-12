import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class ContinuousLessonTests:XCTestCase {
    @MainActor func testEveryRetainedSegmentPlaysWithoutAnswers() throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        var count=0
        for (index,lesson) in player.library.lessons.enumerated() {
            player.openLesson(index:index);player.seek(step:0);player.play()
            for (step,beat) in lesson.beats.enumerated() {
                XCTAssertEqual(player.step,step);XCTAssertEqual(player.key,beat.id)
                XCTAssertNil(player.exercise);XCTAssertTrue(player.playing)
                XCTAssertEqual(session.lesson?.mode,"lesson")
                player.advance(by:player.duration);count+=1
            }
        }
        XCTAssertEqual(count,710);XCTAssertEqual(session.state.course.completed.count,39)
        XCTAssertFalse(player.playing);player.shutdown()
    }
    @MainActor func testBoardClickCannotInterruptLessonNarration() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        p.openLesson(index:0);p.seek(step:p.current.beats.firstIndex{$0.id=="intro:15"}!);p.play()
        p.click("e1");p.click("a1")
        XCTAssertTrue(p.playing);XCTAssertTrue(p.picked.isEmpty);XCTAssertTrue(p.feedback.isEmpty)
        XCTAssertNil(p.exercise);p.shutdown()
    }
    @MainActor func testSavedStepWithoutSegmentResumesThere() throws {
        var state=ApplicationState();state.course.lessonID="intro";state.course.step=5
        let s=try GameSession(engine:nil,state:state),p=try LearningPlayer(session:s)
        p.openLesson(index:0);XCTAssertEqual(p.key,"intro:5");XCTAssertEqual(p.step,5)
        XCTAssertEqual(s.state.course.segmentID,"intro:5")
        p.play();p.advance(by:p.duration);XCTAssertEqual(p.key,"intro:6");p.shutdown()
    }
    @MainActor func testSavedSegmentWinsOverStepAndSurvivesImport() throws {
        var state=ApplicationState();state.course.lessonID="intro";state.course.step=3;state.course.segmentID="intro:7"
        let s=try GameSession(engine:nil,state:state),p=try LearningPlayer(session:s)
        p.openLesson(index:0);XCTAssertEqual(p.key,"intro:7");XCTAssertEqual(p.step,7)
        let data=try JSONEncoder().encode(s.state);var restored=ApplicationState()
        try LegacyImporter.apply(data,to:&restored,course:p.library)
        let reopened=try LearningPlayer(session:GameSession(engine:nil,state:restored))
        XCTAssertEqual(reopened.key,"intro:7");p.shutdown();reopened.shutdown()
    }
    /// Lessons are continuous narration: every beat id is its lesson and its position, with no retired questions left.
    func testBeatIdentifiersAreConsecutive() throws {
        let c=try CourseLibrary()
        XCTAssertEqual(c.retiredExerciseIDs ?? [],[])
        for lesson in c.lessons {XCTAssertEqual(lesson.beats.map(\.id),lesson.beats.indices.map{"\(lesson.id):\($0)"})}
    }
    @MainActor func testAutomaticContinuationPreferenceStillApplies() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);s.state.settings.autoAdvance=false
        p.openLesson(index:0);p.seek(step:p.current.beats.firstIndex{$0.id=="intro:15"}!);p.play();p.advance(by:p.duration)
        XCTAssertEqual(p.key,"intro:15");XCTAssertFalse(p.playing)
        p.next();XCTAssertEqual(p.key,"intro:16");XCTAssertFalse(p.playing);p.shutdown()
    }
    @MainActor func testStandalonePuzzleStillRequiresAndAcceptsAnswer() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        p.openPuzzle(id:"extra-1");XCTAssertNotNil(p.exercise);p.click("f3");p.click("h4")
        XCTAssertTrue(p.passed);XCTAssertTrue(p.feedback.contains(p.activePuzzle!.explanation));XCTAssertFalse(p.playing)
        p.shutdown()
    }
}
