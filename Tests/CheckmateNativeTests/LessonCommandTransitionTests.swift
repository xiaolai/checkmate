import XCTest
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// The lesson remediation's Continue and "Try it against the computer" commands, routed through the one activity
/// transition: each leaves a review the same way every navigation does, and a draft question answered Cancel stays.
@MainActor final class LessonCommandTransitionTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func index(_ model:NativeModel,_ id:String)throws -> Int {try XCTUnwrap(model.learning.library.lessons.firstIndex{$0.id==id})}
    private func draftWithIdea(_ model:NativeModel)throws {
        model.openReview(try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],draft:true);try model.review.select(1);try model.review.beginBranch();try model.review.playBranch("c7c5")
    }

    /// Continue opens the next lesson from its start, even when that lesson has a saved position further on.
    func testContinueOpensTheNextLessonFromItsStart()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let next=1;model.lesson(next);XCTAssertGreaterThan(model.learning.current.beats.count,1,"fixture: the next lesson needs a later beat")
        model.learning.seek(step:1);model.lesson(0);XCTAssertEqual(model.session.activity.place,.lesson(index:0))
        model.continueLesson()
        XCTAssertEqual(model.session.activity.place,.lesson(index:next));XCTAssertEqual(model.learning.lessonIndex,next)
        XCTAssertEqual(model.learning.step,0,"Continue resumed the next lesson's saved position instead of its start")
    }
    /// From a review over a lesson, Continue leaves the review like any navigation.
    func testContinueFromAReviewLeavesIt()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.lesson(0);model.openReview(try PGNImporter.parse(Data("1. d4 d5 *".utf8))[0]);XCTAssertTrue(model.review.active)
        model.continueLesson()
        XCTAssertFalse(model.review.active);XCTAssertNil(model.session.activity.review);XCTAssertEqual(model.session.activity.place,.lesson(index:1))
    }
    /// The lesson's practice position becomes a separate practice game, as White, keeping the earlier game.
    func testPracticeLessonStartsTheLessonPositionAsAPracticeGame()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let preset=try XCTUnwrap(model.learning.library.lessons.first{$0.id=="fork"}?.practice)
        model.practice();try model.session.rules.restore("1. e4 e5 *");model.lesson(try index(model,"fork"))
        model.practiceLesson()
        XCTAssertEqual(model.session.activity.place,.practice);XCTAssertNil(model.session.activity.review)
        XCTAssertEqual(model.session.rules.fen,preset.fen);XCTAssertEqual(model.session.humanSide,"w")
        XCTAssertTrue(model.session.state.practice.previousGame.contains("e4"),"the earlier game was not kept as the previous game")
    }
    /// A draft review with an idea asks first; Cancel keeps the draft and starts nothing.
    func testPracticeLessonFromADraftCancelledKeepsTheDraft()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.lesson(try index(model,"fork"));try draftWithIdea(model);let fen=model.session.rules.fen;var asked=0;model.askAboutDraft={_ in asked+=1;return .cancel}
        model.practiceLesson();model.continueLesson()
        XCTAssertEqual(asked,2);XCTAssertTrue(model.review.active,"Cancel on the draft question still left the review")
        XCTAssertEqual(model.session.rules.fen,fen,"Cancel on the draft question still started the practice position")
    }

    /// Practice activities are off the main path: Continue from a piece lesson, or from its activity, goes to the next
    /// piece lesson. Practise opens the activity from its start, through the same transition.
    func testContinueSkipsPracticeAndPractiseOpensIt()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let pawn=try index(model,"pawn"),pawnDuel=try index(model,"pawn-duel"),rook=try index(model,"rook")
        XCTAssertEqual(model.learning.library.practice(for:pawn),[pawnDuel])
        model.lesson(pawn);model.continueLesson()
        XCTAssertEqual(model.session.activity.place,.lesson(index:rook),"Continue went into the practice activity")
        model.lesson(pawnDuel);model.learning.seek(step:2);model.lesson(pawn)
        model.openPractice(pawnDuel)
        XCTAssertEqual(model.session.activity.place,.lesson(index:pawnDuel));XCTAssertEqual(model.learning.step,0);XCTAssertEqual(model.session.state.course.lessonID,"pawn-duel")
        model.learning.pause();model.continueLesson()
        XCTAssertEqual(model.session.activity.place,.lesson(index:rook),"Continue from an activity returns to the main path")
        // Only this lesson's own activities can be opened as its practice.
        model.lesson(rook);model.openPractice(pawnDuel)
        XCTAssertEqual(model.session.activity.place,.lesson(index:rook))
    }
    /// Practise asks about a draft review like any navigation; Cancel keeps the draft and opens nothing.
    func testPractiseFromADraftCancelledKeepsTheDraft()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let pawn=try index(model,"pawn"),pawnDuel=try index(model,"pawn-duel")
        model.lesson(pawn);try draftWithIdea(model);let fen=model.session.rules.fen;var asked=0;model.askAboutDraft={_ in asked+=1;return .cancel}
        model.openPractice(pawnDuel)
        XCTAssertEqual(asked,1);XCTAssertTrue(model.review.active,"Cancel on the draft question still left the review")
        XCTAssertEqual(model.session.rules.fen,fen);XCTAssertNotEqual(model.session.activity.place,.lesson(index:pawnDuel))
    }
    /// A lesson read from a training link opens its activity, the activity's game, and Continue as training links too:
    /// the course bookmark, other lessons' reading positions and the unfinished exercise all survive the whole chain.
    func testPractiseFromATrainingLinkKeepsTheCourseBookmark()throws {
        setenv("CHECKMATE_TRAINING_ENABLED","1",1);defer{unsetenv("CHECKMATE_TRAINING_ENABLED")}
        let model=try NativeModel();defer{model.shutdown()}
        let pawnDuel=try index(model,"pawn-duel"),rook=try index(model,"rook"),fork=try index(model,"fork")
        model.lesson(fork);model.learning.seek(step:1)
        model.startTraining("find-attackers");let attempt=try XCTUnwrap(model.session.state.training?.active)
        let course=model.session.state.course,bookmark=(course.lessonID,course.step,course.segmentID),positions=course.positions ?? [:]
        model.openTrainingLesson("pawn");XCTAssertTrue(model.learning.readingFromTraining)
        model.openPractice(pawnDuel)
        XCTAssertEqual(model.session.activity.place,.lesson(index:pawnDuel,fromTraining:true))
        model.learning.startMini(.pawnDuel,computer:false)
        XCTAssertEqual(model.session.activity.place,.miniGame(lessonIndex:pawnDuel,kind:.pawnDuel,fromTraining:true))
        model.learning.leaveMini()
        XCTAssertEqual(model.session.activity.place,.lesson(index:pawnDuel,fromTraining:true),"leaving the game lost the training link")
        model.learning.pause();model.continueLesson()
        XCTAssertEqual(model.session.activity.place,.lesson(index:rook,fromTraining:true))
        model.trainingLibrary()
        let after=model.session.state.course
        XCTAssertEqual(after.lessonID,bookmark.0,"a training link moved the course bookmark");XCTAssertEqual(after.step,bookmark.1);XCTAssertEqual(after.segmentID,bookmark.2)
        for (lesson,position) in positions {XCTAssertEqual(after.positions?[lesson],position,"\(lesson) lost its reading position")}
        XCTAssertEqual(model.session.state.training?.active?.id,attempt.id,"the unfinished exercise did not survive");XCTAssertNotNil(model.training?.resumable)
        model.resumeTraining();XCTAssertEqual(model.session.activity,.at(.training(entry:"find-attackers")))
    }
}
