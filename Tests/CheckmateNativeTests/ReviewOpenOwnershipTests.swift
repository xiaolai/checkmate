import XCTest
import AppKit
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

@testable import CheckmateNative

/// A re-read saved review attaches its cursor and ideas only to the positions they were made at.
final class ReviewStoreStartPositionTests:XCTestCase {
    func testTheSameMovesFromAnotherStartPositionAreRefusedNotReattached()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let text=try PGNImporter.parse(Data("1. e4 *".utf8))[0]
        // The stored tree was read from another start (Black without the b8 knight); 1. e4 …d5 is legal from both.
        let other=try PGNImporter.parse(Data("[SetUp \"1\"]\n[FEN \"r1bqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1\"]\n1. e4 *".utf8))[0]
        let stored=GameDocument(schemaVersion:1,id:text.id,contentHash:text.contentHash,importedAt:text.importedAt,provenance:text.provenance,original:text.original,headers:text.headers,startingFEN:other.startingFEN,result:text.result,termination:text.termination,historyAvailable:true,nodes:other.nodes)
        let e4=try XCTUnwrap(other.nodes.firstIndex{$0.uci=="e2e4"});XCTAssertNotEqual(stored,text)
        var idea=ReviewBranch(root:e4);idea.moves=["d7d5"]
        let url=root.appendingPathComponent(text.id.uuidString+".json"),data=try JSONEncoder().encode(SavedReview(schemaVersion:1,document:stored,cursor:e4,branches:[idea],updatedAt:Date()))
        try data.write(to:url)
        XCTAssertThrowsError(try ReviewStore(directory:root).load(text.id),"the cursor and idea were moved to a position they were not made at")
        XCTAssertEqual(try Data(contentsOf:url),data,"the record must stay untouched")
    }
}

/// Reopening the idea already open keeps its latest moves.
@MainActor final class ReviewReopenIdeaTests:XCTestCase {
    func testReopeningTheOpenIdeaKeepsItsEdit()throws {
        let session=try GameSession(engine:nil),review=ReviewController(),document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        review.open(document,practice:session);try review.select(1);try review.beginBranch();try review.playBranch("c7c5");review.clearBranch()
        let id=try XCTUnwrap(review.authoredBranches.first?.id)
        try review.openSavedBranch(id);review.seekBranch(1);try review.playBranch("g1f3")
        XCTAssertEqual(review.branch?.moves,["c7c5","g1f3"])
        try review.openSavedBranch(id)
        XCTAssertEqual(review.branch?.moves,["c7c5","g1f3"],"reopening the open idea reinstalled its copy from before the edit")
        XCTAssertEqual(review.branchesForSaving.map(\.moves),[["c7c5","g1f3"]])
        XCTAssertThrowsError(try review.openSavedBranch(UUID()))
    }
}

/// The app decides once what an agent's open restores, and a refused open restores nothing.
@MainActor final class ReviewAgentOpenTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func settle(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<500{if condition(){return};try await Task.sleep(for:.milliseconds(10))};XCTFail("timed out waiting for \(what)")}
    private func tools(_ model:NativeModel)throws -> ReviewTools {try XCTUnwrap(model.companion.tools.reviewTools)}
    /// A saved review holding …c5, whose later idea …d5 failed to save and is only in memory.
    private func reviewWithUnsavedIdea(_ model:NativeModel)throws -> GameDocument {
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        model.openReview(document);try model.review.select(1);try model.review.beginBranch();try model.review.playBranch("c7c5");model.saveCurrentReview()
        try FileManager.default.createDirectory(at:model.reviewStore.directory,withIntermediateDirectories:true);let filler=model.reviewStore.directory.appendingPathComponent("filler.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath:filler.path,contents:nil));let handle=try FileHandle(forWritingTo:filler);try handle.truncate(atOffset:UInt64(ReviewPolicy.maximumLibraryBytes));try handle.close()
        model.review.clearBranch();try model.review.beginBranch();try model.review.playBranch("d7d5");model.saveCurrentReview()
        XCTAssertNotNil(model.storageError,"fixture: the save must fail");return document
    }
    func testAnAgentReopeningAReviewKeepsItsUnsavedIdeas()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let document=try reviewWithUnsavedIdea(model);XCTAssertTrue(model.returnToGame());XCTAssertFalse(model.review.active)
        _ = try await tools(model).call("open_review",args:["source":"saved","gameId":document.id.uuidString])
        XCTAssertEqual(Set(model.review.branchesForSaving.map(\.moves)),[["c7c5"],["d7d5"]],"the older file replaced the unsaved idea")
        // The same game pasted again reuses its record, through the same single decision.
        XCTAssertTrue(model.returnToGame());XCTAssertFalse(model.review.active)
        _ = try await tools(model).call("open_review",args:["source":"paste","text":"1. e4 e5 *"])
        XCTAssertEqual(model.review.document?.id,document.id)
        XCTAssertEqual(Set(model.review.branchesForSaving.map(\.moves)),[["c7c5"],["d7d5"]],"the duplicate import replaced the unsaved idea")
    }
    func testAnAgentOpenRefusedByTheLearnerRestoresNothingIntoTheDraft()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let saved=try PGNImporter.parse(Data("1. d4 d5 *".utf8))[0]
        model.openReview(saved);try model.review.select(2);try model.review.beginBranch();try model.review.playBranch("c2c4");model.review.clearBranch();XCTAssertTrue(model.returnToGame())
        XCTAssertEqual(try model.reviewStore.load(saved.id).branches.map(\.moves),[["c2c4"]])
        let draft=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        model.openReview(draft,draft:true);try model.review.select(1);try model.review.beginBranch();try model.review.playBranch("c7c5")
        var asked=0;model.askAboutDraft={_ in asked+=1;return .cancel}
        do{_ = try await tools(model).call("open_review",args:["source":"saved","gameId":saved.id.uuidString,"expectedReviewRevision":model.review.revision]);XCTFail("a refused open reported success")}
        catch let failure as ProtocolFailure{XCTAssertEqual(failure.code,"STALE_REVIEW")}
        XCTAssertEqual(asked,1);XCTAssertEqual(model.review.document?.id,draft.id);XCTAssertTrue(model.reviewDraft)
        XCTAssertEqual(model.review.nodeID,1,"the saved record's cursor moved the draft");XCTAssertEqual(model.review.branch?.moves,["c7c5"])
        XCTAssertEqual(model.review.branchesForSaving.map(\.moves),[["c7c5"]],"the saved record's ideas were added to the draft")
        // A new record staged for a refused open is removed again.
        let before=try model.reviewStore.list().count
        do{_ = try await tools(model).call("open_review",args:["source":"paste","text":"1. c4 *","expectedReviewRevision":model.review.revision]);XCTFail("a refused open reported success")}catch is ProtocolFailure{}
        XCTAssertEqual(try model.reviewStore.list().count,before,"a refused open left a library entry")
    }
    /// Deleting a review while another saved review loads abandons that load and its overlay.
    func testDeletingDuringASavedLoadClearsTheLoadingOverlay()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        var ids:[UUID]=[]
        for text in ["1. d4 *","1. c4 *"]{let document=try PGNImporter.parse(Data(text.utf8))[0];model.openReview(document);XCTAssertTrue(model.returnToGame());ids.append(document.id)}
        try await settle("the library to list both"){model.reviews.count==2}
        model.automationReviewLoadDelayMs=300;model.openSavedReview(ids[0]);XCTAssertTrue(model.importingReview)
        model.deleteReview(ids[1]);try await settle("the deletion"){model.deletingReviewID==nil}
        try await Task.sleep(for:.milliseconds(600))
        XCTAssertFalse(model.importingReview,"Loading review… stayed visible for an abandoned load");XCTAssertFalse(model.review.active)
        XCTAssertEqual(model.reviews.map(\.id),[ids[0]])
    }
    /// R-12: Edit ▸ Undo after deleting a saved review puts it back in the library.
    func testUndoPutsADeletedReviewBack()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0];model.openReview(document);XCTAssertTrue(model.returnToGame())
        try await settle("the library to list it"){model.reviews.map(\.id)==[document.id]}
        let undo=UndoManager();undo.groupsByEvent=false
        undo.beginUndoGrouping();model.deleteReview(document.id,undo:undo);try await settle("the deletion"){model.deletingReviewID==nil && model.reviews.isEmpty};undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo);XCTAssertEqual(undo.undoActionName,"Delete Review")
        undo.undo();try await settle("the restored review"){model.reviews.map(\.id)==[document.id]}
        XCTAssertEqual(try model.reviewStore.load(document.id).document.id,document.id);XCTAssertNil(model.storageError)
    }
}

/// A file read started later is never discarded because an earlier file's parse finished during it.
@MainActor final class ReviewFileReadOrderTests:XCTestCase {
    private var dir:URL!
    override func setUp(){dir=FileManager.default.temporaryDirectory.appendingPathComponent("read-order-"+UUID().uuidString);try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);setenv("CHECKMATE_DATA_DIR",dir.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:dir)}
    private func pgn(_ name:String,_ event:String)throws->URL {let url=dir.appendingPathComponent(name);try Data("[Event \"\(event)\"]\n1. e4 *".utf8).write(to:url);return url}
    func testAnEarlierFilesParseDoesNotDiscardALaterRead()async throws {
        let model=try NativeModel(),app=AppDelegate();app.model=model;defer{model.shutdown()}
        model.automationReviewImportDelayMs=300
        app.reviewFiles.read={url in if url.lastPathComponent=="later.pgn"{Thread.sleep(forTimeInterval:0.8)};return try Data(contentsOf:url)}
        app.application(NSApplication.shared,open:[try pgn("earlier.pgn","Earlier file")])
        for _ in 0..<250 where !model.importingReview{try await Task.sleep(for:.milliseconds(10))}
        XCTAssertTrue(model.importingReview,"fixture: the earlier file is parsing")
        app.application(NSApplication.shared,open:[try pgn("later.pgn","Later file")])
        for _ in 0..<300 where model.review.document?.title.contains("Later file") != true{try await Task.sleep(for:.milliseconds(10))}
        XCTAssertTrue(model.review.document?.title.contains("Later file")==true,"the later file was discarded: \(model.review.document?.title ?? "nil")")
        try await Task.sleep(for:.milliseconds(800))
        XCTAssertTrue(model.review.document?.title.contains("Later file")==true,"the earlier file replaced the later one")
    }
}
