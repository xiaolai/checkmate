import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-013: training entries link their lessons. Reading a linked lesson keeps the course bookmark where it was (the
/// lesson's own reading position is kept), the way back leads to training, and an unfinished exercise stays saved.
@MainActor final class TrainingLessonLinkTests:XCTestCase {
    // Increment B is gated behind its preview flags; these tests exercise it as development does.
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    private func fixture()throws -> (GameSession,LearningPlayer,TrainingController,WorkspaceTransitionCoordinator) {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        let training=TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider.bundled())
        let coordinator=WorkspaceTransitionCoordinator(session:session,learning:player,review:ReviewController());coordinator.training=training
        return (session,player,training,coordinator)
    }
    private func go(_ coordinator:WorkspaceTransitionCoordinator,_ session:GameSession,_ next:WorkspaceNavigation)throws {
        let prepared=try coordinator.prepare(next);try coordinator.enter(prepared:prepared,from:session.activity.place,wasReviewing:session.activity.review != nil)
    }
    func testEveryLinkNamesARealLesson()throws {
        let (_,player,training,_)=try fixture();defer{player.shutdown()}
        let lessons=Set(player.library.lessons.map(\.id))
        for entry in try XCTUnwrap(training.catalog).entries {XCTAssertTrue(Set(entry.lessonLinks).isSubset(of:lessons),"\(entry.id) links an unknown lesson")}
    }
    func testReadingALinkedLessonKeepsTheCourseBookmarkAndReturnsToTraining()throws {
        let (session,player,training,coordinator)=try fixture();defer{player.shutdown()}
        // The learner's own place in the course, and an unfinished exercise.
        player.openLesson(index:2);player.seek(step:1)
        let bookmark=(session.state.course.lessonID,session.state.course.step)
        try go(coordinator,session,.trainingExercise(entry:"mate-in-one"))
        let active=try XCTUnwrap(session.state.training?.active?.id)
        try go(coordinator,session,.trainingLesson(id:"fork"))
        let fork=try XCTUnwrap(player.library.lessons.firstIndex{$0.id=="fork"})
        XCTAssertEqual(session.activity.place,.lesson(index:fork,fromTraining:true));XCTAssertTrue(player.readingFromTraining)
        player.seek(step:1)
        XCTAssertEqual(session.state.course.lessonID,bookmark.0,"reading a linked lesson does not move the course bookmark");XCTAssertEqual(session.state.course.step,bookmark.1)
        XCTAssertNotNil(session.state.course.positions?["fork"],"the linked lesson remembers its own reading position")
        try go(coordinator,session,.trainingLibrary)
        XCTAssertEqual(session.activity.place,.trainingLibrary);XCTAssertEqual(session.state.training?.active?.id,active,"the unfinished exercise is still there to continue")
        // Opening the course normally moves the bookmark as before.
        try go(coordinator,session,.lesson(fork))
        XCTAssertEqual(session.activity.place,.lesson(index:fork));XCTAssertEqual(session.state.course.lessonID,"fork")
    }
    func testAnUnknownLessonChangesNothing()throws {
        let (session,player,_,coordinator)=try fixture();defer{player.shutdown()}
        let before=session.activity
        XCTAssertThrowsError(try coordinator.prepare(.trainingLesson(id:"no-such-lesson")))
        XCTAssertEqual(session.activity,before)
    }
}
