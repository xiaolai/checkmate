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
        let (session,player,_,coordinator)=try fixture();defer{player.shutdown()}
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
    /// Finding #54: the mini-game place carries its lesson's training origin, so every hop (into the game, a review
    /// over it and back, a restart, back to the lesson) keeps it with no copy outside the activity.
    func testALinkedLessonsMiniGameKeepsItsTrainingOriginAtEveryHop()throws {
        let (session,player,_,coordinator)=try fixture();defer{player.shutdown()}
        player.openLesson(index:2);player.seek(step:1)
        let bookmark=(session.state.course.lessonID,session.state.course.step)
        try go(coordinator,session,.trainingLesson(id:"fork"))
        let fork=try XCTUnwrap(player.library.lessons.firstIndex{$0.id=="fork"})
        XCTAssertTrue(player.readingFromTraining,"the linked lesson offers Back to training")
        let game=Place.miniGame(lessonIndex:fork,kind:.pawnDuel,fromTraining:true)
        player.startMini(.pawnDuel,computer:false)
        XCTAssertEqual(session.activity,.at(game),"the game opened from a linked lesson carries that origin");XCTAssertEqual(session.mode,.lesson)
        XCTAssertFalse(player.miniFromLibrary,"the game leads back to its lesson, not to the library");XCTAssertFalse(player.readingFromTraining)
        try go(coordinator,session,.reviewWorkspace)
        XCTAssertEqual(session.activity,.reviewing(ReviewVisit(document:nil,draft:false,returnTo:game)),"a review over the game returns to the same origin")
        try go(coordinator,session,.returnToGame);XCTAssertEqual(session.activity,.at(game))
        player.restartMini();XCTAssertEqual(session.activity,.at(game),"a restart keeps the training origin")
        player.leaveMini()
        XCTAssertEqual(session.activity,.at(.lesson(index:fork,fromTraining:true)),"back in the lesson, still as a training link");XCTAssertTrue(player.readingFromTraining)
        player.seek(step:0)
        XCTAssertEqual(session.state.course.lessonID,bookmark.0,"the game and the way back never move the course bookmark");XCTAssertEqual(session.state.course.step,bookmark.1)
        // A lesson step chosen while the game is shown also returns to the lesson as a training link.
        player.startMini(.pawnDuel,computer:false);XCTAssertEqual(session.activity,.at(game));player.seek(step:0)
        XCTAssertEqual(session.activity,.at(.lesson(index:fork,fromTraining:true)));XCTAssertEqual(session.state.course.lessonID,bookmark.0)
        try go(coordinator,session,.trainingLibrary);XCTAssertEqual(session.activity,.at(.trainingLibrary))
    }
    func testAnOrdinaryLessonsMiniGameNeverLeadsBackToTraining()throws {
        let (session,player,_,coordinator)=try fixture();defer{player.shutdown()}
        let fork=try XCTUnwrap(player.library.lessons.firstIndex{$0.id=="fork"})
        try go(coordinator,session,.lesson(fork));XCTAssertFalse(player.readingFromTraining)
        let game=Place.miniGame(lessonIndex:fork,kind:.pawnDuel)
        player.startMini(.pawnDuel,computer:false);XCTAssertEqual(session.activity,.at(game))
        XCTAssertNotEqual(session.activity,.at(.miniGame(lessonIndex:fork,kind:.pawnDuel,fromTraining:true)),"an ordinary lesson is not a training link")
        try go(coordinator,session,.reviewWorkspace);try go(coordinator,session,.returnToGame);XCTAssertEqual(session.activity,.at(game))
        player.restartMini();XCTAssertEqual(session.activity,.at(game))
        player.leaveMini();XCTAssertEqual(session.activity,.at(.lesson(index:fork)));XCTAssertFalse(player.readingFromTraining,"no Back to training")
        player.seek(step:1);XCTAssertEqual(session.state.course.lessonID,"fork");XCTAssertEqual(session.state.course.step,1,"after the game, reading an ordinary lesson still moves the course bookmark")
    }
    func testAnUnknownLessonChangesNothing()throws {
        let (session,player,_,coordinator)=try fixture();defer{player.shutdown()}
        let before=session.activity
        XCTAssertThrowsError(try coordinator.prepare(.trainingLesson(id:"no-such-lesson")))
        XCTAssertEqual(session.activity,before)
    }
}
