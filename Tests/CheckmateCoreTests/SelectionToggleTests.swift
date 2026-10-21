import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// Clicking the square already selected clears the selection, on every board the learner moves pieces on: practice,
/// a network game and a training exercise behave the same.
@MainActor final class SelectionToggleTests:XCTestCase {
    func testPracticeClearsTheSelectionOnASecondClick()throws {
        let s=try GameSession(engine:nil)
        try s.select("e2");XCTAssertEqual(s.selected,"e2");XCTAssertNotNil(s.inspection)
        try s.select("e2");XCTAssertNil(s.selected,"the second click on the selected square clears it");XCTAssertNil(s.inspection);XCTAssertEqual(s.destinations,[])
        try s.select("e2");XCTAssertEqual(s.selected,"e2","a third click selects it again")
        try s.select("e7");try s.select("e7");XCTAssertNil(s.selected,"the opponent's piece, inspected, clears the same way")
    }
    func testANetworkGameClearsTheSelectionOnASecondClick()throws {
        let game=try NetworkGameController();game.submit={_ in XCTFail("no move is submitted")}
        try game.show(seat:.player(side:"w"),title:"Ana vs Ben",pgn:"")
        game.click("e2");XCTAssertEqual(game.selected,"e2")
        game.click("e2");XCTAssertNil(game.selected,"the second click on the selected square clears it");XCTAssertEqual(game.destinations,[])
        game.click("e2");XCTAssertEqual(game.selected,"e2")
    }
    func testATrainingExerciseClearsThePickedPieceOnASecondClick()throws {
        setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1);defer{unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
        let (_,player,controller)=try TrainingEndgameTests.fixture([TrainingEndgameTests.ending("4k3/8/8/8/8/8/8/3QK3 w - - 0 1")],defender:ScriptedDefender());defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        controller.click("d1");XCTAssertEqual(controller.exercise?.picked,"d1")
        controller.click("d1");XCTAssertNil(controller.exercise?.picked,"the second click on the picked piece drops it")
    }
}
