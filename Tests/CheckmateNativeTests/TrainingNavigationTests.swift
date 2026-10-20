import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-004: the training library and its exercises go through the one transition function. A failed start changes
/// nothing; library-opened mini-games are routed without assuming a lesson; the rollout flag hides everything.
@MainActor final class TrainingNavigationTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1);setenv("CHECKMATE_TRAINING_ENABLED","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");unsetenv("CHECKMATE_TRAINING_ENABLED");try? FileManager.default.removeItem(at:directory)}
    private func quiet(_ model:NativeModel)async throws {var settings=model.session.state.settings;settings.pieceDuration=0;model.session.updateSettings(settings);try await Task.sleep(for:.milliseconds(100))}
    func testTheFlagOffHidesTrainingAndRefusesItsNavigation()throws {
        unsetenv("CHECKMATE_TRAINING_ENABLED")
        let model=try NativeModel();defer{model.shutdown()}
        XCTAssertNil(model.training);let before=model.session.activity
        model.trainingLibrary();model.startTraining("reach-target");model.playTrainingGame(.pawnDuel)
        XCTAssertEqual(model.session.activity,before,"nothing opens while training is off");XCTAssertNotNil(model.storageError)
    }
    func testLibraryExerciseAndBackAreOneTransitionEach()throws {
        let model=try NativeModel();let game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        model.trainingLibrary();game.refresh()
        XCTAssertEqual(model.session.activity,.at(.trainingLibrary));XCTAssertEqual(model.session.mode,.training)
        XCTAssertTrue(game.board.isHidden);XCTAssertFalse(game.trainingLibraryView.isHidden);XCTAssertEqual(game.titleView.label.stringValue,"Training")
        model.startTraining("find-attackers");game.refresh()
        XCTAssertEqual(model.session.activity,.at(.training(entry:"find-attackers")));XCTAssertFalse(game.board.isHidden);XCTAssertTrue(game.trainingLibraryView.isHidden)
        XCTAssertEqual(game.titleView.label.stringValue,"Find the Attackers")
        model.trainingLibrary();game.refresh();XCTAssertTrue(game.board.isHidden);XCTAssertNotNil(model.training?.resumable,"the unfinished exercise is offered as Continue")
        model.resumeTraining();XCTAssertEqual(model.session.activity,.at(.training(entry:"find-attackers")))
        model.practice();XCTAssertEqual(model.session.activity,.at(.practice));XCTAssertEqual(model.session.state.training?.active?.entry,"find-attackers","leaving keeps the attempt")
    }
    func testAFailedStartShowsWhyAndChangesNothing()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.lesson(2);let before=model.session.activity,lesson=model.learning.lessonIndex
        model.startTraining("no-such-entry")
        XCTAssertEqual(model.session.activity,before);XCTAssertEqual(model.learning.lessonIndex,lesson);XCTAssertNotNil(model.storageError)
        model.dismissStorageError();model.resumeTraining();XCTAssertEqual(model.session.activity,before,"no saved exercise to continue");XCTAssertNotNil(model.storageError)
    }
    func testAReviewClosesWhenTrainingOpens()throws {
        let model=try NativeModel();defer{model.shutdown()}
        XCTAssertTrue(model.openReview(try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]));XCTAssertTrue(model.review.active)
        model.startTraining("reach-target")
        XCTAssertFalse(model.review.active);XCTAssertNil(model.session.activity.review);XCTAssertEqual(model.session.activity,.at(.training(entry:"reach-target")))
    }
    func testALibraryMiniGameIsRoutedWithoutALesson()async throws {
        let model=try NativeModel();let game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        try await quiet(model)
        model.playTrainingGame(.pawnDuel);game.refresh()
        XCTAssertEqual(model.session.activity,.at(.miniGame(lessonIndex:nil,kind:.pawnDuel)));XCTAssertEqual(game.titleView.label.stringValue,"Pawn Duel")
        XCTAssertTrue(game.validateMenuItem(NSMenuItem(title:"",action:#selector(GameWindow.newGame),keyEquivalent:"")),"New Game works for a library game")
        model.learning.click("g2");model.learning.click("g4");XCTAssertTrue(model.learning.miniThinking)
        // Leaving cancels the pending computer reply; reopening resumes the one saved board and queues the reply again.
        model.trainingLibrary();XCTAssertFalse(model.learning.miniThinking)
        try await Task.sleep(for:.milliseconds(800));XCTAssertEqual(model.session.state.miniGames?["pawn-duel"]?.history.count,1,"no reply played behind the library")
        model.playTrainingGame(.pawnDuel);XCTAssertTrue(model.learning.miniThinking)
        for _ in 0..<60 where model.learning.miniGame?.history.count != 2{try await Task.sleep(for:.milliseconds(50))}
        XCTAssertEqual(model.learning.miniGame?.history.count,2)
        XCTAssertTrue(game.validateMenuItem(NSMenuItem(title:"",action:#selector(GameWindow.undo as (GameWindow)->()->Void),keyEquivalent:"")));game.undo();XCTAssertEqual(model.learning.miniGame?.history.count,0,"Take Back undoes the whole turn")
        // The lesson opens the same board.
        model.learning.click("e2");model.learning.click("e3");for _ in 0..<60 where model.learning.miniGame?.history.count != 2{try await Task.sleep(for:.milliseconds(50))}
        let board=model.learning.miniGame?.board;model.lesson(3);model.learning.startMini(.pawnDuel)
        XCTAssertEqual(model.learning.miniGame?.board,board);XCTAssertEqual(model.session.activity,.at(.miniGame(lessonIndex:3,kind:.pawnDuel)))
        // Changing the difficulty in a library game restarts no lesson and keeps the library origin.
        model.playTrainingGame(.pawnDuel);model.learning.setMiniLevel("beginner");try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(model.session.activity,.at(.miniGame(lessonIndex:nil,kind:.pawnDuel)))
        model.learning.restartMini();XCTAssertEqual(model.session.activity,.at(.miniGame(lessonIndex:nil,kind:.pawnDuel)),"restart keeps the library origin")
    }
    /// WI-015: the drawer's level picker is per game. Choosing a level while a game is in progress keeps that game at
    /// its level, with its pending reply, and offers a new game at the chosen one; the offer starts it there.
    /// The mechanism is tested with every level offered, whatever calibration (WI-016) withdrew.
    func testTheLevelPickerIsPerGameAndOffersANewGameAtTheChosenLevel()async throws {
        MiniGameOffering.testTable=Dictionary(uniqueKeysWithValues:MiniGameKind.allCases.filter{!$0.solo}.map{($0,MiniOpponentPolicy.profiles)});defer{MiniGameOffering.testTable=nil}
        let model=try NativeModel();defer{model.shutdown()};try await quiet(model)
        model.playTrainingGame(.rookSweep);model.learning.restartMini();let rookLevel=model.learning.miniLevel
        model.playTrainingGame(.pawnDuel);model.learning.restartMini();XCTAssertEqual(model.learning.miniLevel,"standard")
        XCTAssertTrue(MiniGameOffering.offersChoice(.pawnDuel),"the picker is shown");XCTAssertFalse(MiniGameOffering.offersChoice(.knightCorners))
        model.learning.click("e2");model.learning.click("e4");XCTAssertTrue(model.learning.miniThinking);let requests=model.learning.miniReplyRequests
        model.learning.setMiniLevel("challenging");try await Task.sleep(for:.milliseconds(50))  // the settings observer runs
        XCTAssertEqual(model.learning.miniReplyRequests,requests,"the pending reply is kept");XCTAssertEqual(model.learning.miniLevel,"standard")
        for _ in 0..<60 where model.learning.miniGame?.history.count != 2{try await Task.sleep(for:.milliseconds(50))}
        XCTAssertEqual(model.learning.miniGame?.history.count,2);XCTAssertEqual(model.learning.miniPreferredLevel,"challenging");XCTAssertTrue(model.learning.miniNewLevelOffered)
        model.learning.restartMini()  // Start a new game at this level
        XCTAssertEqual(model.learning.miniLevel,"challenging");XCTAssertEqual(model.learning.miniGame?.history.count,0);XCTAssertFalse(model.learning.miniNewLevelOffered)
        XCTAssertEqual(model.session.state.miniGames?["pawn-duel"]?.runLevel?.profile,"challenging")
        model.playTrainingGame(.rookSweep);XCTAssertEqual(model.learning.miniLevel,rookLevel,"another game keeps its own level");XCTAssertEqual(model.learning.miniPreferredLevel,"standard")
    }
}
