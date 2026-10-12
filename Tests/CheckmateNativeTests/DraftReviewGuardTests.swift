import XCTest
@testable import CheckmateNative
import CheckmateCore

/// A draft review holding the learner's imagined lines is never closed without an answer: Save keeps it,
/// Don't Save discards it after asking once, Cancel keeps the learner where they are.
@MainActor final class DraftReviewGuardTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func draftWithIdea(_ model:NativeModel)throws -> GameDocument {
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        model.openReview(document,draft:true);try model.review.select(1);try model.review.beginBranch();try model.review.playBranch("c7c5")
        return document
    }
    func testCancelKeepsTheDraftOpenOnEveryExit()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let document=try draftWithIdea(model);var asked=0;model.askAboutDraft={_ in asked+=1;return .cancel}
        XCTAssertFalse(model.returnToGame());model.lesson(0);model.puzzles();model.practice();model.showReviewWorkspace()
        model.openReview(try PGNImporter.parse(Data("1. d4 *".utf8))[0],draft:true)
        XCTAssertEqual(asked,6);XCTAssertEqual(model.review.document?.id,document.id);XCTAssertEqual(model.review.branchesForSaving.count,1)
        XCTAssertFalse(model.resolveDraftBeforeLeaving())  // what Quit and closing the window ask
    }
    func testSaveKeepsTheDraftWithItsIdeas()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let document=try draftWithIdea(model);model.askAboutDraft={_ in .save}
        XCTAssertTrue(model.returnToGame());XCTAssertFalse(model.review.active)
        XCTAssertEqual(try model.reviewStore.load(document.id).branches.map(\.moves),[["c7c5"]])
    }
    func testDontSaveAsksOnceAndKeepsNothing()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let document=try draftWithIdea(model);var asked=0;model.askAboutDraft={_ in asked+=1;return .discard}
        model.openReview(try PGNImporter.parse(Data("1. d4 *".utf8))[0],draft:true)
        XCTAssertEqual(asked,1);XCTAssertNotEqual(model.review.document?.id,document.id);XCTAssertFalse(try model.reviewStore.list().contains{$0.id==document.id})
    }
    /// #50: a navigation made while the question is up (an agent's call runs during the modal) overtakes the exit that
    /// asked. "Save" given about it is not applied, and the draft as it now stands is asked about again.
    func testSaveAnsweredAboutAnOvertakenNavigationIsNotAppliedAndAsksAgain()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let document=try draftWithIdea(model);var answers:[NativeModel.DraftDisposal]=[]
        model.askAboutDraft={_ in answers.append(answers.isEmpty ? .save:.cancel);if answers.count==1{model.supersedeReviewOpen()};return answers.last!}
        XCTAssertFalse(model.returnToGame(),"the overtaken exit must not complete")
        XCTAssertEqual(answers,[.save,.cancel],"the draft as it now stands was not asked about again")
        XCTAssertTrue(model.review.active);XCTAssertTrue(model.reviewDraft,"the stale Save still saved the draft");XCTAssertEqual(model.review.document?.id,document.id)
        XCTAssertFalse(try model.reviewStore.list().contains{$0.id==document.id},"the stale Save wrote the draft to the library")
    }
    /// The same for Don't Save on Quit: an approval given before an overtaking navigation never lets the draft go.
    func testDontSaveAnsweredAboutAnOvertakenNavigationIsNotApproved()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let document=try draftWithIdea(model);var asked=0
        model.askAboutDraft={_ in asked+=1;if asked==1{model.supersedeReviewOpen();return .discard};return .cancel}
        XCTAssertFalse(model.resolveDraftBeforeLeaving(),"a Don't Save given before the navigation changed was applied")
        XCTAssertEqual(asked,2);XCTAssertEqual(model.review.document?.id,document.id);XCTAssertEqual(model.review.branchesForSaving.count,1)
        // The answer given about the draft as it now stands is applied as usual.
        model.askAboutDraft={_ in asked+=1;return .discard};XCTAssertTrue(model.resolveDraftBeforeLeaving());XCTAssertEqual(asked,3)
    }
    func testADraftWithoutIdeasClosesWithoutAsking()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.openReview(try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],draft:true)
        model.askAboutDraft={_ in XCTFail("Nothing of the learner's would be lost");return .cancel}
        XCTAssertTrue(model.returnToGame());XCTAssertFalse(model.review.active)
    }
}

/// Already in practice, Resume game after a failed saved-review restore must still release the held reply:
/// practice() keeps the position and presentation there, so it releases the hold explicitly.
@MainActor final class FailedRestoreResumeTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    func testResumeReleasesTheHeldReplyWithoutResettingThePosition()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.session.newGame(side:"w");try model.session.rules.restore("1. e4 *")
        XCTAssertEqual(model.session.mode,.practice);XCTAssertTrue(model.session.requireExplicitResume());XCTAssertTrue(model.restoreResumePending)
        let position=model.session.positionId;model.storageError=NativeModel.failedRestorePausedMessage
        model.resumeAfterFailedRestore()
        XCTAssertFalse(model.restoreResumePending,"Resume game left the reply held");XCTAssertNil(model.storageError)
        XCTAssertEqual(model.session.positionId,position,"Resuming must not reset the position");XCTAssertEqual(model.session.rules.history,["e4"])
        model.session.cancelWork()
    }
}

/// A resigned game that New Game set aside keeps its result when it is reviewed as the previous game.
@MainActor final class PreviousGameReviewResultTests:XCTestCase {
    func testAResignedPreviousGameIsReviewedAsDecided()throws {
        let session=try GameSession(engine:nil);session.newGame(side:"w");try session.rules.restore("1. e4 e5 *");session.resign()
        let result=try XCTUnwrap(session.state.practice.ending?.result);XCTAssertNotEqual(result,"*")
        session.newGame(side:"w");XCTAssertEqual(session.state.practice.previousEnding?.result,result)
        let data=try ReviewRecordSource.data(previousGame:session.state.practice.previousGame,result:session.state.practice.previousEnding?.result)
        XCTAssertEqual(try PGNImporter.parse(data).first?.result,result,"The review shows the resignation, not an unfinished game")
        XCTAssertEqual(try PGNImporter.parse(ReviewRecordSource.data(previousGame:session.state.practice.previousGame)).first?.result,"*","Without the result the record reads unfinished")
    }
}

/// Leaving a review saves it once: the state that closing re-queues is the one just written, so nothing stays pending
/// (a stranded snapshot outranked the review's file when it was reopened and was never written by itself).
@MainActor final class FlushedReviewTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    func testLeavingAReviewLeavesNothingPending()throws {
        let model=try NativeModel();defer{model.shutdown()}
        for leave in [{model.returnToGame()},{model.lesson(0);model.practice();return true}] as [()->Bool] {
            let document=try PGNImporter.parse(Data("[Event \"Leave\"]\n1. e4 e5 *".utf8))[0]
            model.openReview(document);try model.review.select(1);model.saveReview()
            XCTAssertTrue(leave());XCTAssertFalse(model.review.active)
            XCTAssertFalse(model.reviewSavePending(document.id),"The state written on leaving stayed queued with no save scheduled")
            XCTAssertEqual(try model.reviewStore.load(document.id).cursor,1)
        }
    }
}
