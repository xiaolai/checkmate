import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// Training moves land as practice moves do: each committed ply, the learner's and the defender's, reaches `onMove`
/// once, with the position it was played from, so the window can animate, sound and announce it. A move that is not
/// committed (a slip, a pending promotion) reaches it never.
@MainActor final class TrainingMoveCallbackTests:XCTestCase {
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    func testAGameReportsTheLearnersMoveAndTheDefendersReply()async throws {
        let start="4k3/8/8/8/8/8/8/3QK3 w - - 0 1"
        let (_,player,controller)=try TrainingEndgameTests.fixture([TrainingEndgameTests.ending(start)],defender:ScriptedDefender(choose:ScriptedDefender.capturing("q")));defer{player.shutdown()}
        var moves:[MoveRecord]=[];controller.onMove={moves.append($0)}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        controller.attempt(from:"d1",to:"d4",promotion:nil);controller.attempt(from:"e1",to:"e3",promotion:nil)
        XCTAssertEqual(moves.map(\.uci),["d1d4"],"only the committed move lands; one made while the defender thinks does not")
        await TrainingEndgameTests.settle(controller)
        XCTAssertEqual(moves.map(\.uci),["d1d4",try XCTUnwrap(controller.exercise?.line.last)],"the defender's reply lands after the learner's move")
        let learner=try XCTUnwrap(moves.first)
        XCTAssertEqual(learner.color,"w");XCTAssertEqual(learner.piece,"q");XCTAssertEqual(learner.san,"Qd4");XCTAssertEqual(learner.before,start)
        XCTAssertEqual(moves.last?.color,"b");XCTAssertEqual(moves.last?.before,learner.after,"the reply is played from the position the learner's move reached")
    }
    func testACapturingReplyThatEndsTheGameStillLands()async throws {
        let (_,player,controller)=try TrainingEndgameTests.fixture([TrainingEndgameTests.ending("4k3/8/8/8/8/8/8/3QK3 w - - 0 1")],defender:ScriptedDefender(choose:ScriptedDefender.capturing("q")));defer{player.shutdown()}
        var moves:[MoveRecord]=[];controller.onMove={moves.append($0)}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        controller.attempt(from:"d1",to:"d7",promotion:nil);await TrainingEndgameTests.settle(controller)
        XCTAssertEqual(controller.exercise?.status,.incorrect)
        XCTAssertEqual(moves.map(\.san),["Qd7+","Kxd7"]);XCTAssertEqual(moves.last?.captured,"q")
    }
    func testAPendingPromotionLandsOnlyOnceAPieceIsChosen()throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session);defer{player.shutdown()}
        let controller=TrainingController(session:session,learning:player);var next:UInt64=7;controller.seed={next+=1;return next}
        var moves:[MoveRecord]=[];controller.onMove={moves.append($0)}
        controller.begin(try controller.prepare(entry:"special-moves",variant:"promotion"))
        let exercise=try XCTUnwrap(controller.exercise),move=try XCTUnwrap(exercise.scenario.nodes?.first?.accepted.first{$0.count==5})
        let from=String(move.prefix(2)),to=String(move.dropFirst(2).prefix(2))
        controller.attempt(from:from,to:to,promotion:nil)
        XCTAssertNotNil(controller.exercise?.pendingPromotion);XCTAssertEqual(moves,[],"a promotion still waiting for its piece has not landed")
        controller.attempt(from:from,to:to,promotion:String(move.suffix(1)))
        XCTAssertEqual(moves.first?.uci,move);XCTAssertEqual(moves.first?.promotion,String(move.suffix(1)))
        XCTAssertEqual(moves.count,controller.exercise?.line.count,"every ply committed, the learner's and any published reply, lands once")
    }
}
