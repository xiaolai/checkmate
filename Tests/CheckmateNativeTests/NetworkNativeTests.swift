import XCTest
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// LAN-play plan D8 and D9 in the app: one fairness check shared by every component, lessons, puzzles and training
/// closed during a network game, practice viewable but paused, and the network place's own board.
@MainActor final class NetworkNativeTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func bar(_ model:NativeModel)->ControlBarModel {ControlBarModel.make(session:model.session,learning:model.learning,review:model.review,training:model.training,network:model.network,voice:.off(unavailable:nil))}

    /// A component built with its own policy would never see the game begin: the app hands every one the same.
    func testEveryComponentSharesTheAppsFairnessCheck()throws {
        let model=try NativeModel();defer{model.shutdown()}
        XCTAssertTrue(model.session.fairness===model.fairness);XCTAssertTrue(model.reviewAnalyzer.fairness===model.fairness)
        XCTAssertTrue(model.review.fairness===model.fairness);XCTAssertTrue(model.session.network===model.network)
        if let training=model.training{XCTAssertTrue(training.games.fairness===model.fairness)}
    }
    func testLessonsPuzzlesAndTrainingAreClosedDuringANetworkGame()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.playOnNetwork();XCTAssertEqual(model.session.activity,.at(.network))
        model.fairness.participation.begin(.player)
        model.lesson(0);XCTAssertEqual(model.session.activity,.at(.network),"a lesson is refused");XCTAssertEqual(model.storageError,FairnessPolicy.destinationUnavailable)
        model.storageError=nil;model.puzzles();XCTAssertEqual(model.session.activity,.at(.network),"puzzles are refused")
        if model.training != nil{model.trainingLibrary();XCTAssertEqual(model.session.activity,.at(.network),"training is refused")}
        // Practice stays viewable, with Stockfish paused and hints off; the network place is one click back.
        model.practice();XCTAssertEqual(model.session.activity,.at(.practice))
        let paused=bar(model);XCTAssertEqual(paused.status,.text(FairnessPolicy.practicePaused))
        XCTAssertEqual(paused.trailing.first{$0.action == .hint}?.enabled,false);XCTAssertEqual(paused.trailing.first{$0.action == .tryMove}?.enabled,false)
        XCTAssertTrue(paused.trailingGroups.isEmpty,"no voice controls during a network game")
        model.playOnNetwork();XCTAssertEqual(model.session.activity,.at(.network));XCTAssertEqual(bar(model),ControlBarModel(),"no game to act on yet: the bar stays empty")
        // Once the game ends, everything opens again.
        model.fairness.participation.end();model.lesson(0);XCTAssertEqual(model.session.mode,.lesson)
    }
    /// A review shown over the network place exports nothing, as Copy PGN and practice's Export already give nothing
    /// there: no game leaves the app while a game against another person may be on.
    func testAReviewShownOverTheNetworkPlaceCannotBeExported()throws {
        let model=try NativeModel(),app=AppDelegate();app.model=model;defer{model.shutdown()}
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        model.openReview(document);XCTAssertTrue(model.review.active);XCTAssertTrue(model.mayExportReview,"a review over practice exports");XCTAssertTrue(app.canExport)
        XCTAssertTrue(model.returnToGame());model.playOnNetwork();XCTAssertEqual(model.session.activity,.at(.network))
        model.openReview(document);XCTAssertTrue(model.review.active,"the review opens over the network place");XCTAssertEqual(model.session.mode,.network)
        XCTAssertNil(model.shownRecord);XCTAssertFalse(model.mayExportReview);XCTAssertFalse(app.canExport,"File ▸ Export… is off over the network place")
    }
}
