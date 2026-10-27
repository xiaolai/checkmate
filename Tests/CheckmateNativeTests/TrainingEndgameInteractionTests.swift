import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-012: playing an ending through the board's own mouse handling. Any legal move may be dragged; while the
/// defender thinks the board takes no input; its reply lands on the board; Take back restores the position.
@MainActor final class TrainingEndgameInteractionTests:XCTestCase {
    override func setUpWithError()throws{try isolateDataDirectory(["CHECKMATE_TRAINING_ENABLED":"1","CHECKMATE_TRAINING_B":"1"])}
    func testAnEndingIsPlayedOnTheBoardAgainstTheDefender()async throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        let defender=ScriptedDefender();defender.holding=true
        model.training?.games.engine=defender
        game.board.frame=NSRect(x:0,y:0,width:640,height:640)
        model.startTraining("finish-the-game",variant:"kqk");game.refresh()
        let training=try XCTUnwrap(model.training),exercise=try XCTUnwrap(training.exercise),start=game.board.position
        XCTAssertEqual(exercise.task,.game);XCTAssertEqual(game.board.blackAtBottom,exercise.scenario.learner=="b")
        // Any legal queen move that does not end the game at once.
        let queen=try XCTUnwrap(TrainingGeometry.square(of:exercise.scenario.learner+"q",on:start))
        let legality=try XCTUnwrap(exercise.current)
        let move=try XCTUnwrap(try legality.outcomes().first{outcome in
            guard outcome.from==queen else{return false}
            let after=try TrainingLegality(fen:exercise.scenario.fen!,prelude:[outcome.uci])
            return try after.status() == .neither && !after.outcomes().isEmpty && after.board().values.contains(exercise.scenario.learner+"q") && (try after.outcomes().allSatisfy{$0.captured != "q"})
        })
        XCTAssertTrue(game.board.canDrag?(queen) ?? false)
        game.board.drag(from:move.from,to:move.to);game.refresh()
        XCTAssertEqual(game.board.position[move.to],exercise.scenario.learner+"q");XCTAssertTrue(training.games.thinking)
        XCTAssertFalse(game.board.canDrag?(move.to) ?? true,"the board waits for the defender")
        defender.release()
        for _ in 0..<500 where training.games.thinking{try await Task.sleep(nanoseconds:2_000_000)}
        game.refresh()
        XCTAssertEqual(training.exercise?.line.count,2);XCTAssertTrue(game.board.canDrag?(move.to) ?? false,"the learner's turn again")
        let reply=try XCTUnwrap(training.exercise?.line.last)
        XCTAssertNotNil(game.board.position[String(reply.dropFirst(2).prefix(2))],"the reply lands on the board")
        training.undo();game.refresh()
        XCTAssertEqual(game.board.position,start,"Take back restores the start");XCTAssertTrue(training.exercise?.snapshot.recordedHelp ?? false)
    }
}
