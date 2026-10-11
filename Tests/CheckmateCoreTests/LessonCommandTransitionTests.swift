import XCTest
@testable import CheckmateNative
@testable import CheckmateCore

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
        let preset=try XCTUnwrap(LessonPractice.forLesson("fork"))
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
}
