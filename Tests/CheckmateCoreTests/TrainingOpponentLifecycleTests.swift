import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-012: the practice defender's lifecycle. Requests carry the start position and whole history with an explicit
/// profile; replies are checked before commit; failures pause the game; stale or cancelled replies never land; a
/// pending reply is asked for again on resume, never replayed.
@MainActor final class TrainingOpponentLifecycleTests:XCTestCase {
    // Increment B is gated behind its preview flags; these tests exercise it as development does.
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    private let start="8/8/8/8/K7/3Q4/8/k7 w - - 0 1"
    private func fixture(_ defender:ScriptedDefender)throws -> (GameSession,LearningPlayer,TrainingController) {try TrainingEndgameTests.fixture([TrainingEndgameTests.ending(start)],defender:defender)}
    func testRequestsCarryTheWholeHistoryAndAnExplicitProfile()async throws {
        let defender=ScriptedDefender()
        let (session,player,controller)=try fixture(defender);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        controller.attempt(from:"d3",to:"d2",promotion:nil);await TrainingEndgameTests.settle(controller)
        controller.attempt(from:"d2",to:"c3",promotion:nil);await TrainingEndgameTests.settle(controller)
        XCTAssertEqual(defender.requests.map(\.moves),[["d3d2"],["d3d2","a1b1","d2c3"]])
        XCTAssertTrue(defender.requests.allSatisfy{$0.startFEN==self.start && $0.profile == .skill(20) && $0.budget==TrainingEndgameController.budget})
        XCTAssertEqual(session.state.training?.active?.actions,[.move(from:"d3",to:"d2",promotion:nil),.reply("a1b1"),.move(from:"d2",to:"c3",promotion:nil),.reply(try XCTUnwrap(controller.exercise?.line.last))])
    }
    func testTheLearnerWaitsForThePendingReply()async throws {
        let defender=ScriptedDefender();defender.holding=true
        let (_,player,controller)=try fixture(defender);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        controller.attempt(from:"d3",to:"d2",promotion:nil)
        XCTAssertTrue(controller.games.thinking)
        controller.attempt(from:"a4",to:"b4",promotion:nil)
        XCTAssertEqual(controller.exercise?.line,["d3d2"],"no move while the defender is thinking");XCTAssertTrue(controller.exercise?.feedback.contains("Wait") ?? false)
        defender.release();await TrainingEndgameTests.settle(controller)
        XCTAssertEqual(controller.exercise?.line,["d3d2","a1b1"])
    }
    func testStaleAndCancelledRepliesNeverLand()async throws {
        let defender=ScriptedDefender();defender.holding=true
        let (_,player,controller)=try fixture(defender);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        controller.attempt(from:"d3",to:"d2",promotion:nil)
        let asked=try XCTUnwrap(controller.exercise?.snapshot)
        controller.undo()
        XCTAssertFalse(controller.games.thinking);XCTAssertEqual(controller.exercise?.line,[])
        defender.release();try await Task.sleep(nanoseconds:50_000_000)
        XCTAssertEqual(controller.exercise?.line,[],"the cancelled request's answer is discarded")
        // An answer for an older revision is discarded even if it arrives.
        controller.receiveReply("a1b1",attempt:asked.id,revision:asked.revision)
        XCTAssertEqual(controller.exercise?.line,[])
    }
    func testAReviewOverTheBoardHoldsTheReplyUntilItReturns()async throws {
        let defender=ScriptedDefender();defender.holding=true
        let (session,player,controller)=try fixture(defender);defer{player.shutdown()}
        let coordinator=WorkspaceTransitionCoordinator(session:session,learning:player,review:ReviewController());coordinator.training=controller
        func go(_ next:WorkspaceNavigation)throws {try coordinator.enter(prepared:try coordinator.prepare(next),from:session.activity.place,wasReviewing:session.activity.review != nil)}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        controller.attempt(from:"d3",to:"d2",promotion:nil)
        try go(.reviewWorkspace)
        XCTAssertFalse(controller.games.thinking,"the review owns the board")
        defender.release();try await Task.sleep(nanoseconds:50_000_000)
        XCTAssertEqual(controller.exercise?.line,["d3d2"],"no reply lands behind the review")
        try go(.returnToGame)
        await TrainingEndgameTests.settle(controller);try await Task.sleep(nanoseconds:20_000_000)
        XCTAssertEqual(controller.exercise?.line,["d3d2","a1b1"]);XCTAssertEqual(defender.requests.count,2,"asked again on return, answered once")
    }
    func testFailuresPauseAndRetryResumes()async throws {
        let defender=ScriptedDefender();defender.failure=CheckmateError.unavailable("engine stopped")
        let (session,player,controller)=try fixture(defender);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        controller.attempt(from:"d3",to:"d2",promotion:nil);await TrainingEndgameTests.settle(controller)
        XCTAssertNotNil(controller.exercise?.paused);XCTAssertEqual(controller.exercise?.status,.active);XCTAssertEqual(session.state.training?.attempts.count ?? 0,0,"a technical pause is not a result")
        controller.attempt(from:"a4",to:"b4",promotion:nil);XCTAssertEqual(controller.exercise?.line,["d3d2"],"paused play takes no moves")
        defender.failure=nil;controller.retryDefender();await TrainingEndgameTests.settle(controller)
        XCTAssertNil(controller.exercise?.paused);XCTAssertEqual(controller.exercise?.line,["d3d2","a1b1"])
        // An illegal reply is never committed.
        defender.choose={_ in "a1a1"}
        controller.attempt(from:"d2",to:"c3",promotion:nil);await TrainingEndgameTests.settle(controller)
        XCTAssertTrue(controller.exercise?.paused?.contains("not legal") ?? false);XCTAssertEqual(controller.exercise?.line.count,3)
        let engineless=try fixture(defender);defer{engineless.1.shutdown()}
        engineless.2.games.engine=nil;engineless.2.begin(try engineless.2.prepare(entry:"finish-the-game"))
        engineless.2.attempt(from:"d3",to:"d2",promotion:nil)
        XCTAssertTrue(engineless.2.exercise?.paused?.contains("not available") ?? false,"no silent fallback opponent")
    }
    func testAPendingReplyIsAskedForAgainOnResume()async throws {
        let defender=ScriptedDefender();defender.holding=true
        let (session,player,controller)=try fixture(defender);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        controller.attempt(from:"d3",to:"d2",promotion:nil)
        controller.openLibrary()
        XCTAssertFalse(controller.games.thinking);XCTAssertEqual(session.state.training?.active?.actions,[.move(from:"d3",to:"d2",promotion:nil)])
        let resumed=TrainingController(session:session,learning:player,provider:controller.provider);resumed.games.engine=defender
        resumed.begin(try resumed.prepareResume())
        XCTAssertEqual(resumed.exercise?.line,["d3d2"]);XCTAssertTrue(resumed.games.thinking,"the defender is asked again")
        defender.release();await TrainingEndgameTests.settle(resumed);try await Task.sleep(nanoseconds:20_000_000)
        XCTAssertEqual(defender.requests.count,2);XCTAssertEqual(resumed.exercise?.line,["d3d2","a1b1"],"exactly one reply lands")
        // A finished-move history replays exactly, replies included.
        let again=TrainingController(session:session,learning:player,provider:controller.provider);again.games.engine=defender
        again.begin(try again.prepareResume())
        XCTAssertEqual(again.exercise?.line,["d3d2","a1b1"]);XCTAssertEqual(again.exercise?.board["b1"],"bk");XCTAssertFalse(again.games.thinking)
    }
    func testAHintWhileThinkingIsRefusedAndTheReplyStillLands()async throws {
        let defender=ScriptedDefender();defender.holding=true
        let (_,player,controller)=try fixture(defender);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        controller.attempt(from:"d3",to:"d2",promotion:nil)
        let revision=try XCTUnwrap(controller.exercise?.snapshot.revision)
        controller.hint()
        XCTAssertEqual(controller.exercise?.hintLevel,0);XCTAssertEqual(controller.exercise?.snapshot.revision,revision,"the pending request's revision is untouched")
        defender.release();await TrainingEndgameTests.settle(controller)
        XCTAssertEqual(controller.exercise?.line,["d3d2","a1b1"])
    }
    func testAThirdHintWithoutAnEngineMoveStepsBackToTheSecond()async throws {
        let defender=ScriptedDefender()
        let (_,player,controller)=try fixture(defender);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        defender.choose={_ in nil}
        controller.hint();controller.hint();controller.hint()
        await controller.games.hintWork?.value
        XCTAssertEqual(controller.exercise?.hintLevel,2,"no move was named, so the third hint was not given")
        XCTAssertTrue(controller.exercise?.feedback.contains("No move could be suggested") ?? false)
    }
    func testLeavingTrainingCancelsThePendingReply()async throws {
        for destination in [WorkspaceNavigation.practice,.puzzles,.lesson(0)] {
            let defender=ScriptedDefender();defender.holding=true
            let (session,player,controller)=try fixture(defender);defer{player.shutdown()}
            let coordinator=WorkspaceTransitionCoordinator(session:session,learning:player,review:ReviewController());coordinator.training=controller
            controller.begin(try controller.prepare(entry:"finish-the-game"))
            controller.attempt(from:"d3",to:"d2",promotion:nil)
            try coordinator.enter(prepared:try coordinator.prepare(destination),from:session.activity.place,wasReviewing:false)
            XCTAssertFalse(controller.games.thinking,"\(destination): the request is cancelled on the way out")
            defender.release();try await Task.sleep(nanoseconds:50_000_000)
            XCTAssertEqual(session.state.training?.active?.actions,[.move(from:"d3",to:"d2",promotion:nil)],"\(destination): no reply is saved behind another workspace")
        }
    }
}
