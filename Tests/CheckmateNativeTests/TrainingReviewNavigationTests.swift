import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-025 (mini-games plan D6): Review this game, from a finished training game, opens a draft review of that game
/// through the one transition function, leaves the practice game as it was, and Return to game leads back to training.
@MainActor final class TrainingReviewNavigationTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1);setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B");try? FileManager.default.removeItem(at:directory)}
    private func practiceBytes(_ model:NativeModel)throws -> Data {let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(model.session.state.practice)}
    func testReviewThisGameOpensTheTrainingGameAndReturnsToTheEntry()async throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        let training=try XCTUnwrap(model.training);training.games.engine=ScriptedDefender()
        // A saved Black-to-move ending at move 37, one move from mate: Qb7 Kg8 played, Qb8 to come.
        let start="7K/8/6k1/8/8/8/8/1q6 b - - 0 37"
        let scenario=TrainingScenario(id:"ending-black-37",entry:"finish-the-game",variant:"kqk",tier:1,cluster:"ending-black-37",learner:"b",prompt:"Checkmate.",explanation:"Mate it.",hints:["Shrink the box."],fen:start,review:TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion),check:.ending)
        var record=TrainingState();record.active=TrainingSessionSnapshot(id:UUID().uuidString,entry:"finish-the-game",scenario:scenario,freshness:"new",revision:2,startedAt:Date(),actions:[.move(from:"b1",to:"b7",promotion:nil),.reply("h8g8")])
        model.session.state.training=record
        model.resumeTraining();game.refresh()
        XCTAssertEqual(training.exercise?.line,["b1b7","h8g8"])
        training.attempt(from:"b7",to:"b8",promotion:nil)
        let finished=try XCTUnwrap(training.exercise);XCTAssertEqual(finished.status,.correct);XCTAssertTrue(training.canReview(finished))
        let practice=try practiceBytes(model),practicePGN=model.session.rules.pgn
        model.reviewTraining()
        for _ in 0..<500 where model.review.document==nil{try await Task.sleep(for:.milliseconds(10))}
        let document=try XCTUnwrap(model.review.document);game.refresh()
        XCTAssertEqual(document.startingFEN,start);XCTAssertEqual(document.mainline.map{document.nodes[$0].uci},["b1b7","h8g8","b7b8"]);XCTAssertEqual(document.result,"0-1")
        XCTAssertEqual(document.nodes[document.mainline[0]].fullmove,37);XCTAssertEqual(document.provenance,"Training game")
        XCTAssertEqual(model.session.activity.review?.returnTo,.training(entry:"finish-the-game"));XCTAssertTrue(model.reviewDraft,"a draft, like a current-game review")
        XCTAssertEqual(try practiceBytes(model),practice,"the practice game is untouched");XCTAssertEqual(model.session.rules.pgn,practicePGN)
        XCTAssertTrue(model.returnToGame());game.refresh()
        XCTAssertEqual(model.session.activity,.at(.training(entry:"finish-the-game")));XCTAssertEqual(training.exercise?.snapshot,finished.snapshot,"the finished game is shown again")
        XCTAssertEqual(try practiceBytes(model),practice);XCTAssertEqual(model.session.rules.pgn,practicePGN)
    }
    func testAGameInPlayIsNotReviewed()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let training=try XCTUnwrap(model.training);training.games.engine=ScriptedDefender()
        model.startTraining("finish-the-game",variant:"kqk")
        let before=model.session.activity
        model.reviewTraining()
        XCTAssertNil(model.review.document);XCTAssertEqual(model.session.activity,before);XCTAssertNotNil(model.storageError,"the learner is told why")
    }
    /// File ▸ Review Current Game means the game on screen: a finished training game, never the practice game beside
    /// it (D6 covers the panel's button; this covers the menu item).
    func testTheFileMenuReviewsTheTrainingGameOnScreen()async throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        let training=try XCTUnwrap(model.training);training.games.engine=ScriptedDefender()
        let start="7K/8/6k1/8/8/8/8/1q6 b - - 0 37"
        let scenario=TrainingScenario(id:"ending-black-37",entry:"finish-the-game",variant:"kqk",tier:1,cluster:"ending-black-37",learner:"b",prompt:"Checkmate.",explanation:"Mate it.",hints:["Shrink the box."],fen:start,review:TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion),check:.ending)
        var record=TrainingState();record.active=TrainingSessionSnapshot(id:UUID().uuidString,entry:"finish-the-game",scenario:scenario,freshness:"new",revision:2,startedAt:Date(),actions:[.move(from:"b1",to:"b7",promotion:nil),.reply("h8g8")])
        model.session.state.training=record
        model.resumeTraining();game.refresh()
        training.attempt(from:"b7",to:"b8",promotion:nil)
        XCTAssertTrue(training.canReview(try XCTUnwrap(training.exercise)))
        // The practice game has moves, so the old menu item would have opened it instead.
        try model.session.rules.restore("1. e4 e5")
        let practicePGN=model.session.rules.pgn,practiceFEN=model.session.rules.fen
        let app=AppDelegate();app.model=model
        let item=NSMenuItem(title:"",action:#selector(AppDelegate.reviewCurrent),keyEquivalent:"")
        XCTAssertTrue(app.validateMenuItem(item),"a finished training game is reviewable")
        app.reviewCurrent()
        for _ in 0..<500 where model.review.document==nil{try await Task.sleep(for:.milliseconds(10))}
        let document=try XCTUnwrap(model.review.document)
        XCTAssertEqual(document.startingFEN,start,"the training game, not the practice game")
        XCTAssertEqual(document.provenance,"Training game")
        XCTAssertEqual(model.session.rules.pgn,practicePGN,"the practice game is untouched")
        XCTAssertEqual(model.session.rules.fen,practiceFEN)
    }
    /// An unfinished training game is not reviewable, and the menu does not fall back to the unrelated practice game.
    func testTheFileMenuRefusesAnUnfinishedTrainingGame()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let training=try XCTUnwrap(model.training);training.games.engine=ScriptedDefender()
        model.startTraining("finish-the-game",variant:"kqk")
        try model.session.rules.restore("1. e4 e5")
        let app=AppDelegate();app.model=model
        let item=NSMenuItem(title:"",action:#selector(AppDelegate.reviewCurrent),keyEquivalent:"")
        XCTAssertFalse(app.validateMenuItem(item),"an unfinished training game is not reviewable")
        model.reviewCurrent()
        XCTAssertNil(model.review.document);XCTAssertFalse(model.importingReview,"nothing fell back to the practice game")
    }
}
