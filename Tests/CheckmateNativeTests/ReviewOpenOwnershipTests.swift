import CheckmateTestSupport
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
    /// A deleted review's engine analysis stays while the review is in the Trash, so Undo brings both back; it is
    /// forgotten when the Trash entry is purged.
    func testADeletedReviewKeepsItsAnalysisUntilTheTrashIsPurged()async throws {
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        do {
            let model=try NativeModel();defer{model.shutdown()}
            model.openReview(document);XCTAssertTrue(model.returnToGame())
            try await settle("the library to list it"){model.reviews.map(\.id)==[document.id]}
            let cache=ReviewAnalysisCache(directory:model.store.directory.appendingPathComponent("ReviewAnalysis"))
            try cache.save(ReviewEvidence(schemaVersion:1,documentID:document.id,documentHash:"document",nodeID:1,historyHash:"history",revision:1,engineVersion:"test",options:[:],budgetMs:500,createdAt:Date(),root:EngineAnalysis(),played:nil,quality:"provisional",provisional:true),key:"analysis")
            model.deleteReview(document.id);try await settle("the deletion"){model.deletingReviewID==nil && model.reviews.isEmpty}
            try await Task.sleep(for:.milliseconds(200))
            XCTAssertEqual(cache.load("analysis")?.documentID,document.id,"the analysis of a review in the Trash is kept")
            model.restoreDeletedReview(document.id);try await settle("the restored review"){model.reviews.map(\.id)==[document.id]}
            XCTAssertEqual(cache.load("analysis")?.documentID,document.id,"the restored review has its analysis")
            model.deleteReview(document.id);try await settle("the second deletion"){model.deletingReviewID==nil && model.reviews.isEmpty}
        }
        // Thirty-one days later the next launch purges the Trash entry, and its analysis with it.
        let folder=directory.appendingPathComponent("Reviews/Trash").appendingPathComponent(document.id.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.path),"the deletion is in the Trash")
        try FileManager.default.setAttributes([.creationDate:Date().addingTimeInterval(-31*24*3600)],ofItemAtPath:folder.path)
        let model=try NativeModel();defer{model.shutdown()}
        let cache=ReviewAnalysisCache(directory:model.store.directory.appendingPathComponent("ReviewAnalysis"))
        try await settle("the purged review's analysis to be forgotten"){cache.load("analysis")==nil}
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path))
    }
    /// R-12: right after a saved review is deleted, from the library list or from the open review, Edit ▸ Undo is
    /// "Undo Delete Review" and puts it back; the game's own Undo is untouched. Once the learner does anything else Undo
    /// owns (a move, a take back, another review or mode), the restore is dropped for good, even if they come back.
    func testUndoRightAfterADeletionPutsTheReviewBackAndNothingLater()async throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        let item=NSMenuItem(title:"Undo",action:NSSelectorFromString("undo:"),keyEquivalent:"z")
        func learnerMoves()->Int {model.session.rules.records.filter{$0.color==model.session.humanSide}.count}
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],other=try PGNImporter.parse(Data("1. c4 *".utf8))[0]
        for shown in [other,document]{model.openReview(shown);XCTAssertTrue(model.returnToGame())}
        try await settle("the library to list both"){model.reviews.count==2}
        try model.session.playWhite(from:"d2",to:"d4");XCTAssertEqual(learnerMoves(),1)
        XCTAssertEqual(model.undoAction,.game,"with no deletion Undo is the game's")
        // From the library list during practice: Undo restores the review, and the practice move stays.
        model.deleteReview(document.id);try await settle("the deletion"){model.deletingReviewID==nil && model.reviews.count==1}
        XCTAssertEqual(model.undoAction,.restoreReview(document.id))
        XCTAssertTrue(game.validateMenuItem(item));XCTAssertEqual(item.title,"Undo Delete Review")
        game.undo(nil);try await settle("the restored review"){model.reviews.count==2}
        XCTAssertEqual(learnerMoves(),1,"Undo took back a practice move instead");XCTAssertEqual(model.undoAction,.game,"a restore is used once")
        XCTAssertEqual(try model.reviewStore.load(document.id).document.id,document.id);XCTAssertNil(model.storageError)
        // A take back after the deletion is the learner's newer action: Undo no longer restores the review.
        model.deleteReview(document.id);try await settle("the deletion"){model.deletingReviewID==nil && model.reviews.count==1}
        model.session.undo();XCTAssertEqual(learnerMoves(),0)
        XCTAssertEqual(model.undoAction,.game);_ = game.validateMenuItem(item);XCTAssertEqual(item.title,"Undo")
        try model.session.playWhite(from:"d2",to:"d4");XCTAssertEqual(model.undoAction,.game,"a dropped restore never returns")
        // Going elsewhere and back drops it too, though the board then looks as it did.
        model.restoreDeletedReview(document.id);try await settle("the restored review"){model.reviews.count==2}
        model.deleteReview(document.id);try await settle("the deletion"){model.deletingReviewID==nil && model.reviews.count==1}
        XCTAssertEqual(model.undoAction,.restoreReview(document.id))
        model.lesson(0);try await Task.sleep(for:.milliseconds(50));model.practice();try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(model.undoAction,.game,"switching mode dropped the restore")
        // Deleting the open review returns to the game; Undo there still restores it.
        model.restoreDeletedReview(document.id);try await settle("the restored review"){model.reviews.count==2}
        model.openReview(document);XCTAssertTrue(model.review.active);XCTAssertEqual(model.undoAction,.nothing,"a review has nothing else to undo")
        XCTAssertFalse(game.validateMenuItem(item))
        model.deleteReview(document.id);try await settle("the deletion"){model.deletingReviewID==nil && model.reviews.count==1 && !model.review.active}
        XCTAssertEqual(model.undoAction,.restoreReview(document.id));XCTAssertTrue(game.validateMenuItem(item));XCTAssertEqual(item.title,"Undo Delete Review")
        game.undo(nil);try await settle("the restored review"){model.reviews.count==2}
        XCTAssertEqual(learnerMoves(),1,"the practice move is kept")
    }
}

/// R-12 in every activity: only what the learner does drops a pending Undo Delete Review. A reply that lands after the
/// deletion (a lesson's, a mini-game's, the training defender's) keeps it, and the learner's next move or take back
/// drops it. A Trash purge of the review drops it too, since it can no longer come back.
@MainActor final class ReviewUndoAfterReplyTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1);setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B");try? FileManager.default.removeItem(at:directory)}
    private func settle(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<500{if condition(){return};try await Task.sleep(for:.milliseconds(10))};XCTFail("timed out waiting for \(what)")}
    /// A model with one saved review in the library, back in Practice.
    private func modelWithReview()async throws -> (NativeModel,GameDocument) {
        let model=try NativeModel(),document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        model.openReview(document);XCTAssertTrue(model.returnToGame());try await settle("the library to list it"){model.reviews.map(\.id)==[document.id]}
        return (model,document)
    }
    private func delete(_ model:NativeModel,_ document:GameDocument)async throws {model.deleteReview(document.id);try await settle("the deletion"){model.deletingReviewID==nil && model.reviews.isEmpty}}
    /// The learner's move in a lesson exercise, then the deletion while its authored reply is pending.
    func testALessonReplyKeepsTheRestore()async throws {
        let (model,document)=try await modelWithReview();defer{model.shutdown()}
        let fen="4k3/8/8/8/8/8/4P3/4K3 w - - 0 1",print={(moves:[String])throws -> String in let rules=try ChessRules(fen:fen);for move in moves{try rules.move(uci:move)};return LessonAttemptJudge.fingerprint(rules.fen)}
        let practice=LessonPractice(fen:fen,goal:"Push.",beat:"test:0",teaching:[LessonTeachingNode(fingerprint:try print([]),accepted:["e2e4"],replies:["e2e4":"e8e7"],next:["e2e4":1]),LessonTeachingNode(fingerprint:try print(["e2e4","e8e7"]),accepted:["e4e5"])],checkpoints:[.init(kind:.graph,label:"Push twice")],opponent:.beginner,hints:["a","b"],offTrack:"Off track.",success:"Pushed.")
        let attempt:LessonAttemptController=model.learning.attempt;attempt.replyDelay={.milliseconds(1500)}
        attempt.open(lessonID:"undo-line",practice:practice);attempt.click("e2");attempt.click("e4")
        XCTAssertEqual(attempt.record?.moves,["e2e4"]);XCTAssertTrue(attempt.thinking,"the reply is pending")
        try await delete(model,document);XCTAssertEqual(model.undoAction,.restoreReview(document.id))
        try await settle("the lesson's reply"){attempt.record?.moves.count==2 && !attempt.thinking}
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(model.undoAction,.restoreReview(document.id),"the lesson's reply is not the learner's action")
        attempt.undo();XCTAssertEqual(attempt.record?.moves,[]);XCTAssertEqual(model.undoAction,.game,"the learner's take back drops it")
    }
    /// The learner's mini-game move, then the deletion while the computer's reply is pending.
    func testAMiniGameReplyKeepsTheRestore()async throws {
        let (model,document)=try await modelWithReview();defer{model.shutdown()}
        model.learning.startMini(.pawnDuel,restart:true,computer:true,fromLibrary:true)
        let game=try XCTUnwrap(model.learning.miniGame),from=try XCTUnwrap(game.board.keys.sorted().first{!game.destinations(from:$0).isEmpty})
        model.learning.click(from);model.learning.click(try XCTUnwrap(game.destinations(from:from).first))
        XCTAssertEqual(model.learning.miniGame?.turn,"b");XCTAssertTrue(model.learning.miniThinking,"the reply is pending")
        try await delete(model,document);XCTAssertEqual(model.undoAction,.restoreReview(document.id))
        try await settle("the computer's reply"){model.learning.miniGame?.turn=="w" && !model.learning.miniThinking}
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(model.undoAction,.restoreReview(document.id),"the computer's reply is not the learner's action")
        let after=try XCTUnwrap(model.learning.miniGame),next=try XCTUnwrap(after.board.keys.sorted().first{!after.destinations(from:$0).isEmpty})
        model.learning.click(next);model.learning.click(try XCTUnwrap(after.destinations(from:next).first))
        XCTAssertEqual(model.undoAction,.game,"the learner's next move drops it")
    }
    /// The learner's move in a training ending, then the deletion while the defender thinks.
    func testATrainingDefenderReplyKeepsTheRestore()async throws {
        let (model,document)=try await modelWithReview();defer{model.shutdown()}
        let defender=ScriptedDefender();defender.holding=true;model.training?.games.engine=defender
        model.startTraining("finish-the-game",variant:"kqk")
        let training=try XCTUnwrap(model.training),exercise=try XCTUnwrap(training.exercise),legality=try XCTUnwrap(exercise.current)
        let move=try XCTUnwrap(try legality.outcomes().first{outcome in
            let after=try TrainingLegality(fen:exercise.scenario.fen!,prelude:[outcome.uci])
            return try after.status() == .neither && !after.outcomes().isEmpty
        })
        training.attempt(from:move.from,to:move.to,promotion:nil);XCTAssertTrue(training.games.thinking,"the defender is thinking")
        try await delete(model,document);XCTAssertEqual(model.undoAction,.restoreReview(document.id))
        defender.release();try await settle("the defender's reply"){!training.games.thinking && training.exercise?.line.count==2}
        try await Task.sleep(for:.milliseconds(50))
        XCTAssertEqual(model.undoAction,.restoreReview(document.id),"the defender's reply is not the learner's action")
        training.undo();XCTAssertEqual(model.undoAction,.game,"the learner's take back drops it")
    }
    /// The Trash letting the deleted review go (to make room, or after thirty days) means Undo can no longer put it back.
    func testAPurgeOfThePendingReviewDropsTheRestore()async throws {
        let (model,document)=try await modelWithReview();defer{model.shutdown()}
        let game=GameWindow(model:model);defer{game.window?.delegate=nil}
        let item=NSMenuItem(title:"Undo",action:NSSelectorFromString("undo:"),keyEquivalent:"z")
        try await delete(model,document);XCTAssertEqual(model.undoAction,.restoreReview(document.id))
        model.reviewStore.onPurge?(UUID());try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(model.undoAction,.restoreReview(document.id),"another review's purge leaves it")
        model.reviewStore.onPurge?(document.id);try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(model.undoAction,.game,"a purged review is not offered back");_ = game.validateMenuItem(item);XCTAssertEqual(item.title,"Undo")
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
