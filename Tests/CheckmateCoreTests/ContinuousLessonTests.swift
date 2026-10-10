import XCTest
@testable import CheckmateCore
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
        XCTAssertEqual(count,864);XCTAssertEqual(session.state.course.completed.count,40)
        XCTAssertFalse(player.playing);player.shutdown()
    }
    @MainActor func testBoardClickCannotInterruptLessonNarration() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        p.openLesson(index:0);p.seek(step:p.current.beats.firstIndex{$0.id=="intro:18"}!);p.play()
        p.click("e1");p.click("a1")
        XCTAssertTrue(p.playing);XCTAssertTrue(p.picked.isEmpty);XCTAssertTrue(p.feedback.isEmpty)
        XCTAssertNil(p.exercise);p.shutdown()
    }
    @MainActor func testSavedQuestionResumesAtFollowingExplanation() throws {
        var state=ApplicationState();state.course.lessonID="intro";state.course.step=17
        state.course.answered=["intro:17"]
        let s=try GameSession(engine:nil,state:state),p=try LearningPlayer(session:s)
        p.openLesson(index:0);XCTAssertEqual(p.key,"intro:18");XCTAssertEqual(p.step,17)
        XCTAssertEqual(s.state.course.segmentID,"intro:18");XCTAssertEqual(s.state.course.answered,["intro:17"])
        p.play();p.advance(by:p.duration);XCTAssertEqual(p.key,"intro:20");p.shutdown()
    }
    @MainActor func testNewSavedSegmentDoesNotGetMigratedTwice() throws {
        var state=ApplicationState();state.course.lessonID="intro";state.course.step=18;state.course.segmentID="intro:20"
        let s=try GameSession(engine:nil,state:state),p=try LearningPlayer(session:s)
        p.openLesson(index:0);XCTAssertEqual(p.key,"intro:20");XCTAssertEqual(p.step,18)
        let data=try JSONEncoder().encode(s.state);var restored=ApplicationState()
        try LegacyImporter.apply(data,to:&restored,course:p.library)
        let reopened=try LearningPlayer(session:GameSession(engine:nil,state:restored))
        XCTAssertEqual(reopened.key,"intro:20");p.shutdown();reopened.shutdown()
    }
    func testEveryRetiredQuestionMapsForwardWithinItsLesson() throws {
        let c=try CourseLibrary()
        for id in c.retiredExerciseIDs ?? [] {
            let parts=id.split(separator:":"),lesson=try XCTUnwrap(c.lessons.first{$0.id==String(parts[0])})
            var progress=CourseProgress();progress.lessonID=lesson.id;progress.step=Int(parts[1])!
            let expected=lesson.beats.firstIndex{Int($0.id!.split(separator:":")[1])!>progress.step} ?? lesson.beats.count-1
            XCTAssertEqual(c.resumeStep(in:lesson,progress:progress),expected,id)
        }
        XCTAssertEqual(c.retiredExerciseIDs?.count,83)
    }
    @MainActor func testAutomaticContinuationPreferenceStillApplies() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);s.state.settings.autoAdvance=false
        p.openLesson(index:0);p.seek(step:p.current.beats.firstIndex{$0.id=="intro:18"}!);p.play();p.advance(by:p.duration)
        XCTAssertEqual(p.key,"intro:18");XCTAssertFalse(p.playing)
        p.next();XCTAssertEqual(p.key,"intro:20");XCTAssertFalse(p.playing);p.shutdown()
    }
    @MainActor func testStandalonePuzzleStillRequiresAndAcceptsAnswer() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s)
        p.openPuzzle(id:"rook");XCTAssertNotNil(p.exercise);p.click("d2");p.click("d5")
        XCTAssertTrue(p.passed);XCTAssertTrue(p.feedback.contains(p.activePuzzle!.explanation));XCTAssertFalse(p.playing)
        p.shutdown()
    }
}
