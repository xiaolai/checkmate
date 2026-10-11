import XCTest
import AppKit
@testable import CheckmateCore
@testable import CheckmateNative

/// A refused idea change leaves the shown board, the open preview and the kept ideas exactly as they were.
@MainActor final class ReviewIdeaRefusalTests:XCTestCase {
    private func atIdeaLimit()throws -> (ReviewController,GameSession,[ReviewBranch]) {
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],review=ReviewController(),session=try GameSession(engine:nil)
        review.open(document,practice:session);try review.select(1)
        var ideas:[ReviewBranch]=[];let start=try document.snapshotRules(at:1)
        outer: for black in start.moves() {let after=try start.copy();try after.move(uci:black.uci)
            for white in after.moves() {var idea=ReviewBranch(root:1);idea.moves=[black.uci,white.uci];ideas.append(idea);if ideas.count==ReviewPolicy.maximumBranches{break outer}}}
        try review.restoreSaved(cursor:1,branches:ideas);return (review,session,ideas)
    }
    func testARefusedMoveInAPreviewLeavesTheBoardWhereItWas()throws {
        let (review,_,ideas)=try atIdeaLimit()
        try review.previewLine(["c7c5"]);review.seekBranch(0);let shown=try XCTUnwrap(review.displayFEN),revision=review.revision
        XCTAssertThrowsError(try review.playBranch("d7d5"))
        XCTAssertEqual(review.displayFEN,shown,"the refused move advanced the shown board");XCTAssertEqual(review.branchPly,0);XCTAssertEqual(review.revision,revision)
        XCTAssertEqual(review.branch?.moves,["c7c5"]);XCTAssertEqual(review.branchesForSaving,ideas)
    }
    func testARefusedNewIdeaKeepsThePreviewAPreview()throws {
        let (review,_,ideas)=try atIdeaLimit()
        try review.previewLine(["c7c5"]);let preview=try XCTUnwrap(review.previewBranchID)
        XCTAssertThrowsError(try review.beginBranch()){XCTAssertEqual(userFacingMessage($0,fallback:""),ReviewController.ideaLimitMessage)}
        XCTAssertEqual(review.previewBranchID,preview,"a refused new idea turned the preview into a kept idea");XCTAssertEqual(review.branchesForSaving,ideas)
        review.clearBranch();XCTAssertEqual(review.authoredBranches,ideas,"leaving the preview evicted the oldest idea")
    }
    func testUndoingAnEditedPreviewAfterReopeningItKeepsNothing()throws {
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],review=ReviewController(),session=try GameSession(engine:nil)
        review.open(document,practice:session);try review.select(1)
        try review.previewLine(["c7c5","g1f3"]);let id=try XCTUnwrap(review.branch?.id);review.seekBranch(1);try review.playBranch("b1c3")
        try review.select(1);XCTAssertEqual(review.authoredBranches.map(\.moves),[["c7c5","b1c3"]])
        try review.openSavedBranch(id);try review.undoIdeaChange()
        XCTAssertEqual(review.previewBranchID,id);XCTAssertTrue(review.branchesForSaving.isEmpty,"the undone edit is still kept")
        review.clearBranch();XCTAssertTrue(review.authoredBranches.isEmpty)
    }
}

/// A saved review whose tree a newer reader numbers differently reopens at the same positions, found by their moves.
final class ReviewStoreRenumberingTests:XCTestCase {
    private struct CursorFile:Codable {let schemaVersion:Int,cursor:Int,updatedAt:Date}
    /// The same tree with two nodes' numbers exchanged, as another importer might write it.
    private func swapping(_ a:Int,_ b:Int,in document:GameDocument)->GameDocument {
        func map(_ i:Int)->Int {i==a ? b:i==b ? a:i}
        let nodes=document.nodes.indices.map{i->GameNode in let n=document.nodes[map(i)];return GameNode(id:i,parent:n.parent.map(map),children:n.children.map(map),uci:n.uci,san:n.san,beforeFEN:n.beforeFEN,afterFEN:n.afterFEN,ply:n.ply,fullmove:n.fullmove,side:n.side,commentsBefore:n.commentsBefore,commentsAfter:n.commentsAfter,nags:n.nags)}
        return GameDocument(schemaVersion:document.schemaVersion,id:document.id,contentHash:document.contentHash,importedAt:document.importedAt,provenance:document.provenance,original:document.original,headers:document.headers,startingFEN:document.startingFEN,result:document.result,termination:document.termination,historyAvailable:document.historyAvailable,nodes:nodes)
    }
    func testCursorAndIdeasFollowTheirMovesIntoARenumberedTree()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let document=try PGNImporter.parse(Data("1. e4 (1. d4) *".utf8))[0]
        let e4=try XCTUnwrap(document.nodes.firstIndex{$0.uci=="e2e4"}),d4=try XCTUnwrap(document.nodes.firstIndex{$0.uci=="d2d4"})
        let stored=swapping(e4,d4,in:document);XCTAssertNotEqual(stored,document);XCTAssertEqual(stored.nodes[e4].uci,"d2d4","fixture: the stored tree numbers d4 where the reader numbers e4")
        // The idea (…d5) is legal after both first moves, so only its recorded path tells them apart.
        var idea=ReviewBranch(root:e4);idea.moves=["d7d5"]
        let written=Date(timeIntervalSince1970:1_000_000)
        try JSONEncoder().encode(SavedReview(schemaVersion:1,document:stored,cursor:e4,branches:[idea],updatedAt:written)).write(to:root.appendingPathComponent(document.id.uuidString+".json"))
        let loaded=try ReviewStore(directory:root).load(document.id)
        XCTAssertEqual(loaded.document,document);XCTAssertEqual(loaded.cursor,d4,"the cursor moved to another position");XCTAssertEqual(loaded.branches.map(\.root),[d4],"the idea moved to another position")
        XCTAssertEqual(loaded.branches.map(\.id),[idea.id]);XCTAssertEqual(loaded.branches.map(\.moves),[["d7d5"]])
        // A later cursor file is numbered like the stored tree it sits beside.
        try JSONEncoder().encode(CursorFile(schemaVersion:1,cursor:d4,updatedAt:written.addingTimeInterval(60))).write(to:root.appendingPathComponent(document.id.uuidString+".cursor.json"))
        let store=ReviewStore(directory:root),reread=try store.load(document.id);XCTAssertEqual(reread.cursor,e4)
        // Saving the re-read record rewrites it whole in the new numbering, so its cursor file and tree agree again.
        try store.save(reread.document,cursor:reread.cursor,branches:reread.branches)
        let reopened=try ReviewStore(directory:root).load(document.id)
        XCTAssertEqual(reopened.document,document);XCTAssertEqual(reopened.cursor,e4);XCTAssertEqual(reopened.branches.map(\.root),[d4])
    }
    func testATreeThatNoLongerHoldsTheIdeaIsPreservedNotReattached()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let document=try PGNImporter.parse(Data("1. e4 (1. d4) *".utf8))[0]
        let e4=try XCTUnwrap(document.nodes.firstIndex{$0.uci=="e2e4"}),d4=try XCTUnwrap(document.nodes.firstIndex{$0.uci=="d2d4"})
        // The stored tree records 1. c4 where the text has 1. d4: no reading of the text holds that position.
        var stored=swapping(e4,d4,in:document);var nodes=stored.nodes;let n=nodes[e4]
        nodes[e4]=GameNode(id:n.id,parent:n.parent,children:n.children,uci:"c2c4",san:"c4",beforeFEN:n.beforeFEN,afterFEN:n.afterFEN,ply:n.ply,fullmove:n.fullmove,side:n.side,commentsBefore:n.commentsBefore,commentsAfter:n.commentsAfter,nags:n.nags)
        stored=GameDocument(schemaVersion:1,id:stored.id,contentHash:stored.contentHash,importedAt:stored.importedAt,provenance:stored.provenance,original:stored.original,headers:stored.headers,startingFEN:stored.startingFEN,result:stored.result,termination:stored.termination,historyAvailable:stored.historyAvailable,nodes:nodes)
        var idea=ReviewBranch(root:e4);idea.moves=["d7d5"]
        let url=root.appendingPathComponent(document.id.uuidString+".json"),data=try JSONEncoder().encode(SavedReview(schemaVersion:1,document:stored,cursor:0,branches:[idea],updatedAt:Date()))
        try data.write(to:url)
        XCTAssertThrowsError(try ReviewStore(directory:root).load(document.id),"an idea was attached to a position it was not made at")
        XCTAssertEqual(try Data(contentsOf:url),data,"the record must stay untouched")
    }
}

/// Unsaved review work survives reopening and quitting, and a "Don't Save" answer covers only the exit it was given for.
@MainActor final class NativeReviewPersistenceTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func settle(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<500{if condition(){return};try await Task.sleep(for:.milliseconds(10))};XCTFail("timed out waiting for \(what)")}
    /// A sparse file makes the library look full, so saves fail while loads still succeed.
    private func fillLibrary(_ model:NativeModel)throws -> URL {
        try FileManager.default.createDirectory(at:model.reviewStore.directory,withIntermediateDirectories:true);let filler=model.reviewStore.directory.appendingPathComponent("filler.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath:filler.path,contents:nil));let handle=try FileHandle(forWritingTo:filler);try handle.truncate(atOffset:UInt64(ReviewPolicy.maximumLibraryBytes));try handle.close();return filler
    }
    /// A saved review holding …c5, whose later idea …d5 failed to save and is only in memory.
    private func reviewWithUnsavedIdea(_ model:NativeModel)throws -> (GameDocument,URL) {
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        model.openReview(document);try model.review.select(1);try model.review.beginBranch();try model.review.playBranch("c7c5");model.saveCurrentReview()
        XCTAssertEqual(try model.reviewStore.load(document.id).branches.map(\.moves),[["c7c5"]])
        let filler=try fillLibrary(model);model.review.clearBranch();try model.review.beginBranch();try model.review.playBranch("d7d5");model.saveCurrentReview()
        XCTAssertNotNil(model.storageError,"fixture: the save must fail");return (document,filler)
    }
    private func savedReview(_ model:NativeModel)throws -> GameDocument {
        let document=try PGNImporter.parse(Data("1. d4 d5 *".utf8))[0];model.openReview(document);XCTAssertTrue(model.returnToGame());XCTAssertNoThrow(try model.reviewStore.load(document.id));return document
    }
    private func draftWithIdea(_ model:NativeModel)throws {
        model.openReview(try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],draft:true);try model.review.select(1);try model.review.beginBranch();try model.review.playBranch("c7c5")
    }
    func testCancellingASavedReviewsLoadOpensNothing()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let document=try savedReview(model)
        model.openSavedReview(document.id);model.cancelReviewImport()
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertFalse(model.review.active,"the cancelled load opened the review");XCTAssertNil(model.storageError)
        model.automationReviewLoadDelayMs=100;model.openSavedReview(document.id);model.cancelReviewImport()
        try await Task.sleep(for:.milliseconds(500))
        XCTAssertFalse(model.review.active);XCTAssertNil(model.storageError,"a cancelled load is not a failure")
    }
    func testReopeningAReviewWhoseSaveFailedKeepsItsUnsavedIdeas()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let (document,filler)=try reviewWithUnsavedIdea(model)
        XCTAssertTrue(model.returnToGame());XCTAssertFalse(model.review.active)
        model.openSavedReview(document.id);try await settle("the saved review to open"){model.review.active}
        XCTAssertEqual(Set(model.review.branchesForSaving.map(\.moves)),[["c7c5"],["d7d5"]],"the reopened review lost the unsaved idea")
        try FileManager.default.removeItem(at:filler);model.saveCurrentReview()
        XCTAssertEqual(Set(try model.reviewStore.load(document.id).branches.map(\.moves)),[["c7c5"],["d7d5"]],"the older file overwrote the unsaved idea")
    }
    func testQuitAsksBeforeLeavingAnyReviewUnsaved()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let (document,filler)=try reviewWithUnsavedIdea(model);XCTAssertTrue(model.returnToGame())
        var asked:[Int]=[];model.confirmQuitWithUnsavedReviews={asked.append($0);return false}
        XCTAssertFalse(model.mayQuitAfterSaving(),"quit was approved with a review unsaved");XCTAssertEqual(asked,[1])
        model.confirmQuitWithUnsavedReviews={asked.append($0);return true};XCTAssertTrue(model.mayQuitAfterSaving(),"Quit Anyway quits");XCTAssertEqual(asked,[1,1])
        try FileManager.default.removeItem(at:filler);model.confirmQuitWithUnsavedReviews={_ in XCTFail("nothing is unsaved");return false}
        XCTAssertTrue(model.mayQuitAfterSaving());XCTAssertEqual(Set(try model.reviewStore.load(document.id).branches.map(\.moves)),[["c7c5"],["d7d5"]],"quit must first flush the earlier failed save")
    }
    func testDontSaveIsAskedAgainAfterAFailedLoad()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        try draftWithIdea(model);var asked=0;model.askAboutDraft={_ in asked+=1;return .discard}
        model.openSavedReview(UUID());XCTAssertEqual(asked,1)
        try await settle("the load to fail"){model.storageError != nil};XCTAssertTrue(model.review.active);XCTAssertTrue(model.reviewDraft)
        XCTAssertTrue(model.returnToGame());XCTAssertEqual(asked,2,"the draft was discarded on an answer given for the failed load")
    }
    func testDontSaveIsAskedAgainAfterACancelledLoad()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let saved=try savedReview(model);try draftWithIdea(model);var asked=0;model.askAboutDraft={_ in asked+=1;return .discard}
        model.automationReviewLoadDelayMs=200;model.openSavedReview(saved.id);XCTAssertEqual(asked,1);model.cancelReviewImport()
        XCTAssertTrue(model.returnToGame());XCTAssertEqual(asked,2,"the draft was discarded on an answer given for the cancelled load")
    }
    func testDontSaveIsAskedAgainWhenTheDraftChanges()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        try draftWithIdea(model);var asked=0;model.askAboutDraft={_ in asked+=1;return .discard}
        // The learner keeps editing while the load is still running.
        model.automationReviewLoadDelayMs=200;model.openSavedReview(UUID());XCTAssertEqual(asked,1)
        try model.review.playBranch("g1f3");XCTAssertTrue(model.resolveDraftBeforeLeaving());XCTAssertEqual(asked,2,"a changed draft was discarded on an answer given before the change")
        model.cancelReviewImport()
    }
    func testDontSaveIsAskedAgainAfterACancelledQuit()throws {
        let model=try NativeModel();defer{model.shutdown()}
        _ = try reviewWithUnsavedIdea(model);XCTAssertTrue(model.returnToGame());model.confirmQuitWithUnsavedReviews={_ in false}
        try draftWithIdea(model);var asked=0;model.askAboutDraft={_ in asked+=1;return .discard}
        // What applicationShouldTerminate asks, in its order.
        XCTAssertTrue(model.resolveDraftBeforeLeaving());XCTAssertFalse(model.mayQuitAfterSaving())
        XCTAssertTrue(model.resolveDraftBeforeLeaving());XCTAssertEqual(asked,2,"a cancelled quit's Don't Save still covered the draft")
    }
}
