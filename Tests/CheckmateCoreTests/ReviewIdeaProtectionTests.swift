import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// The learner's imagined lines are their own work: replaying, previews, the idea limit and deletion must never
/// lose one silently.
@MainActor final class ReviewIdeaProtectionTests:XCTestCase {
    private func opened()throws -> (ReviewController,GameSession,GameDocument) {
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],review=ReviewController(),session=try GameSession(engine:nil)
        review.open(document,practice:session);try review.select(1);return (review,session,document)
    }
    private func savedIdea(_ review:ReviewController,_ moves:[String])throws -> UUID {
        try review.beginBranch();for move in moves{try review.playBranch(move)};let id=try XCTUnwrap(review.branch?.id);review.clearBranch();return id
    }
    func testReplayingTheIdeasOwnNextMoveStepsAlongIt()throws {
        let (review,_,_)=try opened(),id=try savedIdea(review,["c7c5","g1f3","b8c6"])
        try review.openSavedBranch(id);XCTAssertEqual(review.branchPly,0)
        try review.playBranch("c7c5");try review.playBranch("g1f3")
        XCTAssertEqual(review.branchPly,2);XCTAssertEqual(review.branch?.moves,["c7c5","g1f3","b8c6"]);XCTAssertFalse(review.canUndoIdeaChange)
    }
    func testReplacingAContinuationCanBeUndone()throws {
        let (review,_,_)=try opened(),id=try savedIdea(review,["c7c5","g1f3","b8c6"])
        try review.openSavedBranch(id);review.seekBranch(1);try review.playBranch("b1c3")
        XCTAssertEqual(review.branch?.moves,["c7c5","b1c3"]);XCTAssertTrue(review.canUndoIdeaChange)
        try review.undoIdeaChange()
        XCTAssertEqual(review.branch?.moves,["c7c5","g1f3","b8c6"]);XCTAssertEqual(review.branchPly,1);XCTAssertEqual(review.branchesForSaving.map(\.moves),[["c7c5","g1f3","b8c6"]])
    }
    func testPreviewsAreNeverKeptUntilTheLearnerChangesThem()throws {
        let (review,_,_)=try opened()
        try review.previewLine(["c7c5","g1f3"]);XCTAssertNotNil(review.previewBranchID);XCTAssertTrue(review.branchesForSaving.isEmpty)
        review.seekBranch(0);try review.playBranch("c7c5");XCTAssertTrue(review.branchesForSaving.isEmpty)  // stepping along keeps it a preview
        try review.playBranch("b1c3");XCTAssertNil(review.previewBranchID);XCTAssertEqual(review.branchesForSaving.map(\.moves),[["c7c5","b1c3"]])
        try review.undoIdeaChange();XCTAssertNotNil(review.previewBranchID);XCTAssertTrue(review.branchesForSaving.isEmpty)
        review.clearBranch();XCTAssertTrue(review.authoredBranches.isEmpty)
    }
    func testTheIdeaLimitRefusesANewIdeaInsteadOfDroppingTheOldest()throws {
        let (review,_,document)=try opened()
        var ideas:[ReviewBranch]=[];let start=try document.snapshotRules(at:1)
        outer: for black in start.moves() {let after=try start.copy();try after.move(uci:black.uci)
            for white in after.moves() {var idea=ReviewBranch(root:1);idea.moves=[black.uci,white.uci];ideas.append(idea);if ideas.count==ReviewPolicy.maximumBranches{break outer}}}
        XCTAssertEqual(ideas.count,ReviewPolicy.maximumBranches)
        try review.restoreSaved(cursor:1,branches:ideas)
        XCTAssertThrowsError(try review.beginBranch()){XCTAssertEqual(userFacingMessage($0,fallback:""),ReviewController.ideaLimitMessage)}
        XCTAssertEqual(review.authoredBranches,ideas)
        try review.previewLine(["c7c5"]);review.seekBranch(0)  // a preview still shows at the limit
        XCTAssertThrowsError(try review.playBranch("d7d5"));XCTAssertEqual(review.branchesForSaving,ideas)
        try review.deleteBranch(ideas[0].id);try review.beginBranch();try review.playBranch("d7d5")
        XCTAssertEqual(review.branchesForSaving.count,ReviewPolicy.maximumBranches);XCTAssertFalse(review.branchesForSaving.contains{$0.id==ideas[0].id})
    }
    func testDeletingTheOpenIdeaReturnsToTheOriginal()throws {
        let (review,_,_)=try opened(),keep=try savedIdea(review,["c7c5"]),drop=try savedIdea(review,["d7d5"])
        try review.openSavedBranch(drop);try review.deleteBranch(drop)
        XCTAssertNil(review.branch);XCTAssertEqual(review.authoredBranches.map(\.id),[keep])
    }
}

/// A save of one review must never replace another review's queued save.
final class ReviewSaveCoordinatorTests:XCTestCase {
    func testQueuedSavesOfDifferentReviewsAreAllWritten()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=ReviewStore(directory:root),coordinator=ReviewSaveCoordinator(store:store)
        let documents=try ["1. e4 *","1. d4 *","1. c4 *"].map{try PGNImporter.parse(Data($0.utf8),provenance:$0)[0]}
        let done=expectation(description:"queued saves");done.expectedFulfillmentCount=2
        coordinator.save(documents[0],cursor:0,branches:[]){if case .success=$0{done.fulfill()}}
        coordinator.save(documents[1],cursor:0,branches:[]){if case .success=$0{done.fulfill()}}
        _ = try coordinator.flush(documents[2],cursor:0,branches:[])
        wait(for:[done],timeout:10)
        XCTAssertEqual(Set(try store.list().map(\.id)),Set(documents.map(\.id)))
    }
}
