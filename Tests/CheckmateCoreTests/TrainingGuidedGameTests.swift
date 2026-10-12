import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-013: guided games are ordinary legal chess against a gentle opponent. Habits are notes worth reviewing, never
/// wrong answers; exact mate-in-one detectors find up to two moments, which are retried afterwards as practice. The
/// real practice game is never touched.
@MainActor final class TrainingGuidedGameTests:XCTestCase {
    // Increment B is gated behind its preview flags; these tests exercise it as development does.
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    private func guided(_ fen:String,learner:String?=nil,id:String="guided-test")->TrainingScenario {
        TrainingScenario(id:id,entry:"guided-games",variant:"short-start",tier:1,cluster:id,learner:learner ?? String(fen.split(separator:" ")[1]),prompt:"Play.",explanation:"Habits.",hints:["Develop.","Look at checks."],fen:fen,review:TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion),check:.guidedGame,workflow:"guided-game")
    }
    private func play(_ controller:TrainingController,_ uci:String)async {controller.attempt(from:String(uci.prefix(2)),to:String(uci.dropFirst(2).prefix(2)),promotion:nil);await TrainingEndgameTests.settle(controller)}
    func testTheBundledStartsValidate()throws {
        let provider=try TrainingScenarioProvider.bundled(),definition=try XCTUnwrap(provider.catalog.entry("guided-games"))
        let starts=provider.scenarios(for:"guided-games")
        XCTAssertEqual(starts.count,4);XCTAssertEqual(Set(starts.map(\.variant)),["initial-setup","short-start"]);XCTAssertEqual(Set(starts.map(\.learner)),["w","b"])
        for start in starts{XCTAssertNoThrow(try TrainingValidationService.validate(start,definition:definition),start.id);XCTAssertEqual(start.workflow,"guided-game")}
        XCTAssertThrowsError(try TrainingValidationService.validate(guided("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1"),definition:definition),"a guided game starts quietly, not in check")
    }
    func testBlackWaitsForTheOpponentsFirstMoveAndTheGentleProfile()async throws {
        let defender=ScriptedDefender()
        let start="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        let (session,player,controller)=try TrainingEndgameTests.fixture([guided(start,learner:"b")],defender:defender);defer{player.shutdown()}
        let practice=session.rules.pgn
        controller.begin(try controller.prepare(entry:"guided-games"));await TrainingEndgameTests.settle(controller)
        XCTAssertEqual(defender.requests.first?.moves,[]);XCTAssertEqual(defender.requests.first?.profile,TrainingEndgameController.guidedProfile)
        XCTAssertEqual(controller.exercise?.line.count,1,"the opponent's first move landed")
        await play(controller,"e7e5")
        XCTAssertEqual(controller.exercise?.line.count,3)
        controller.undo()
        XCTAssertEqual(controller.exercise?.line.count,1,"Take back removes Black's move and the reply, never White's first move")
        XCTAssertEqual(session.rules.pgn,practice,"the real practice game is untouched")
    }
    func testHabitsAreNotesNotVerdicts()async throws {
        let (_,player,controller)=try TrainingEndgameTests.fixture([guided("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")],defender:ScriptedDefender());defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"guided-games"))
        await play(controller,"g1f3")
        XCTAssertNil(controller.exercise?.habit,"developing a knight draws no note");XCTAssertEqual(controller.exercise?.status,.active)
        await play(controller,"e2e4")
        await play(controller,"e1e2")
        XCTAssertTrue(controller.exercise?.habit?.contains("can no longer castle") ?? false);XCTAssertEqual(controller.exercise?.status,.active,"a note never ends or grades the game")
        XCTAssertTrue(controller.exercise?.habit?.hasPrefix("Worth reviewing") ?? false)
    }
    func testAMissedMateBecomesAMomentToRetry()async throws {
        // Ra8 is mate; the learner plays h3 instead.
        let (session,player,controller)=try TrainingEndgameTests.fixture([guided("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1")],defender:ScriptedDefender());defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"guided-games"))
        await play(controller,"h2h3")
        let moment=try XCTUnwrap(controller.exercise?.moments.first)
        XCTAssertEqual(moment.kind,.mateFind);XCTAssertEqual(moment.ply,0);XCTAssertTrue(moment.label.contains("h3"))
        controller.endGuidedGame()
        XCTAssertEqual(controller.exercise?.status,.ended);XCTAssertEqual(session.state.training?.attempts.last?.outcome,.abandoned,"an ended guided game is neither won nor lost")
        controller.retryMoment(0)
        let retry=try XCTUnwrap(controller.exercise)
        XCTAssertEqual(retry.scenario.check,.moment);XCTAssertEqual(retry.task,.move);XCTAssertTrue(retry.snapshot.retry,"a moment from the learner's own game is practice")
        XCTAssertEqual(retry.scenario.nodes?.first?.accepted,["a1a8"])
        controller.attempt(from:"a1",to:"a8",promotion:nil)
        XCTAssertEqual(controller.exercise?.status,.correct)
    }
    func testAnAllowedMateIsRetriedAgainstEveryReply()async throws {
        // After Rb2, Black mates with Rd1; a move that gives the king air or keeps the back rank covered prevents it.
        let (_,player,controller)=try TrainingEndgameTests.fixture([guided("3r2k1/5ppp/8/8/8/8/5PPP/1R4K1 w - - 0 1")],defender:ScriptedDefender(choose:{_ in "h7h6"}));defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"guided-games"))
        await play(controller,"b1b2")
        XCTAssertEqual(controller.exercise?.moments.first?.kind,.mateAvoid)
        // Undo removes the moment with the move.
        controller.undo();XCTAssertEqual(controller.exercise?.moments,[])
        await play(controller,"b1b2");controller.endGuidedGame();controller.retryMoment(0)
        let node=try XCTUnwrap(controller.exercise?.scenario.nodes?.first)
        XCTAssertTrue(node.accepted.contains("h2h3"));XCTAssertTrue(node.accepted.contains("b1e1"),"covering the back rank");XCTAssertFalse(node.accepted.contains("b1d1"),"Rxd1 is still mate");XCTAssertFalse(node.accepted.contains("b1b2"));XCTAssertEqual(node.replies["b1b2"],"d8d1")
        controller.attempt(from:"b1",to:"b2",promotion:nil)
        XCTAssertEqual(controller.exercise?.status,.incorrect);XCTAssertTrue(controller.exercise?.feedback.hasPrefix("After Rd1#") ?? false)
    }
    func testMomentsAndNotesReplayOnResume()async throws {
        let defender=ScriptedDefender()
        let (session,player,controller)=try TrainingEndgameTests.fixture([guided("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1")],defender:defender);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"guided-games"))
        await play(controller,"h2h3")
        let moments=try XCTUnwrap(controller.exercise?.moments)
        controller.openLibrary()
        let resumed=TrainingController(session:session,learning:player,provider:controller.provider);resumed.games.engine=defender
        resumed.begin(try resumed.prepareResume())
        XCTAssertEqual(moments.count,1);XCTAssertEqual(resumed.exercise?.moments,moments,"replaying the saved moves finds the same moments")
    }
    func testARetriedMomentLeadsBackToTheFinishedGame()async throws {
        let (_,player,controller)=try TrainingEndgameTests.fixture([guided("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 7")],defender:ScriptedDefender());defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"guided-games"))
        await play(controller,"h2h3")
        XCTAssertTrue(controller.exercise?.moments.first?.label.contains("move 7") ?? false,"a start after move one keeps its own move numbers")
        controller.endGuidedGame();controller.retryMoment(0)
        XCTAssertNotNil(controller.guidedReview);XCTAssertEqual(controller.exercise?.scenario.check,.moment)
        controller.returnToGuidedGame()
        XCTAssertEqual(controller.exercise?.scenario.check,.guidedGame);XCTAssertEqual(controller.exercise?.status,.ended);XCTAssertEqual(controller.exercise?.moments.count,1)
    }
    func testBeginnerEntriesAreNotOfferedWithoutThePreview()throws {
        let (_,player,controller)=try TrainingEndgameTests.fixture([guided("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")],defender:ScriptedDefender());defer{player.shutdown()}
        unsetenv("CHECKMATE_TRAINING_B")
        XCTAssertThrowsError(try controller.prepare(entry:"guided-games"),"Increment B stays off until its preview is enabled")
    }
    func testADrawnStartIsRejected()throws {
        let definition=try XCTUnwrap(TrainingCatalog.bundled().entry("guided-games"))
        XCTAssertThrowsError(try TrainingValidationService.validate(guided("4k3/8/8/8/8/8/8/4K3 w - - 0 1"),definition:definition),"bare kings are already drawn")
    }
}
