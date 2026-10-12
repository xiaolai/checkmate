import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-012: Finish the Game. Every legal learner move is allowed; only an actual checkmate succeeds; the other endings
/// follow the plan's precedence; claimable draws need a claim and automatic ones do not.
@MainActor final class TrainingEndgameTests:XCTestCase {
    // Increment B is gated behind its preview flags; these tests exercise it as development does.
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    static func ending(_ fen:String,variant:String="kqk",id:String="ending-test")->TrainingScenario {
        TrainingScenario(id:id,entry:"finish-the-game",variant:variant,tier:1,cluster:id,learner:String(fen.split(separator:" ")[1]),prompt:"Checkmate.",explanation:"Mate it.",hints:["Shrink the box.","Bring the king."],fen:fen,review:TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion),check:.ending)
    }
    static func fixture(_ scenarios:[TrainingScenario],defender:ScriptedDefender)throws -> (GameSession,LearningPlayer,TrainingController) {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        let controller=TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider(catalog:try TrainingCatalog.bundled(),scenarios:scenarios))
        controller.games.engine=defender
        return (session,player,controller)
    }
    /// Lets the defender's pending reply arrive.
    static func settle(_ controller:TrainingController)async {for _ in 0..<500 where controller.games.thinking{try? await Task.sleep(nanoseconds:2_000_000)}}
    private func play(_ controller:TrainingController,_ uci:String)async {controller.attempt(from:String(uci.prefix(2)),to:String(uci.dropFirst(2).prefix(2)),promotion:nil);await Self.settle(controller)}
    func testStartsAreValidatedAsTheEndingTheyClaim()throws {
        let definition=try XCTUnwrap(TrainingCatalog.bundled().entry("finish-the-game"))
        XCTAssertNoThrow(try TrainingValidationService.validate(Self.ending("8/8/8/8/K7/3Q4/8/k7 w - - 0 1"),definition:definition))
        XCTAssertNoThrow(try TrainingValidationService.validate(Self.ending("7K/8/6k1/8/8/8/8/1q6 b - - 0 1"),definition:definition),"Black learns too")
        XCTAssertThrowsError(try TrainingValidationService.validate(Self.ending("8/8/8/8/K7/3R4/8/k7 w - - 0 1"),definition:definition),"a rook is not a queen ending")
        XCTAssertThrowsError(try TrainingValidationService.validate(Self.ending("8/8/8/8/K7/3Q4/8/k7 w - - 3 1"),definition:definition),"the halfmove clock starts at 0")
        XCTAssertThrowsError(try TrainingValidationService.validate(Self.ending("8/8/8/8/K7/8/1Q6/k7 w - - 0 1"),definition:definition),"the queen next to the lone king and unprotected is capturable")
        XCTAssertThrowsError(try TrainingValidationService.validate(Self.ending("8/8/8/8/K7/3Q4/p7/k7 w - - 0 1"),definition:definition),"no extra pieces")
    }
    func testOnlyAnActualCheckmateSucceedsForBothColours()async throws {
        let defender=ScriptedDefender()
        let (session,player,controller)=try Self.fixture([Self.ending("7k/8/6K1/8/8/8/8/1Q6 w - - 0 1")],defender:defender);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        XCTAssertEqual(controller.exercise?.task,.game)
        await play(controller,"b1b8")
        XCTAssertEqual(controller.exercise?.status,.correct);XCTAssertTrue(controller.exercise?.feedback.hasPrefix("Checkmate!") ?? false);XCTAssertTrue(defender.requests.isEmpty)
        XCTAssertTrue(session.state.training?.attempts.last?.firstTryNoRecordedHelp ?? false)
        let (_,blackPlayer,black)=try Self.fixture([Self.ending("7K/8/6k1/8/8/8/8/1q6 b - - 0 1",id:"ending-black")],defender:defender);defer{blackPlayer.shutdown()}
        black.begin(try black.prepare(entry:"finish-the-game"));await play(black,"b1b8")
        XCTAssertEqual(black.exercise?.status,.correct,"Black mates too")
    }
    func testStalemateAndLosingTheMatingPieceAreNotWins()async throws {
        let defender=ScriptedDefender(choose:ScriptedDefender.capturing("q"))
        let (_,player,controller)=try Self.fixture([Self.ending("7k/8/5K2/8/8/8/8/6Q1 w - - 0 1")],defender:defender);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        await play(controller,"g1g6")
        XCTAssertEqual(controller.exercise?.status,.incorrect);XCTAssertTrue(controller.exercise?.feedback.hasPrefix("Stalemate") ?? false)
        // Losing the queen leaves bare kings, an automatic draw; losing the mating piece is reported first.
        let (_,other,lost)=try Self.fixture([Self.ending("4k3/8/8/8/8/8/8/3QK3 w - - 0 1",id:"ending-lost")],defender:defender);defer{other.shutdown()}
        lost.begin(try lost.prepare(entry:"finish-the-game"));await play(lost,"d1d7")
        XCTAssertEqual(lost.exercise?.line,["d1d7","e8d7"]);XCTAssertEqual(lost.exercise?.status,.incorrect)
        XCTAssertTrue(lost.exercise?.feedback.contains("captured your queen") ?? false)
    }
    func testClaimableDrawsNeedAClaimAndAutomaticDrawsEndTheGame()async throws {
        // The rook shuffles a2-b2 and the king h8-g8: the position repeats every four plies.
        let shuffle={(rules:ChessRules)->String? in rules.piece("h8") != nil ? "h8g8":"g8h8"}
        let scenario=Self.ending("7k/8/8/8/8/8/R7/4K3 w - - 0 1",variant:"krk")
        let (_,player,controller)=try Self.fixture([scenario],defender:ScriptedDefender(choose:shuffle));defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        for move in ["a2b2","b2a2","a2b2","b2a2"]{await play(controller,move)}
        XCTAssertEqual(controller.exercise?.claimable,"threefold repetition");XCTAssertFalse(controller.exercise?.finished ?? true,"a claimable draw does not end the game by itself")
        for move in ["a2b2","b2a2","a2b2","b2a2"]{await play(controller,move)}
        XCTAssertEqual(controller.exercise?.status,.incorrect);XCTAssertTrue(controller.exercise?.feedback.contains("fivefold repetition") ?? false,"the fifth repetition is automatic")
        let (_,claimer,claim)=try Self.fixture([scenario],defender:ScriptedDefender(choose:shuffle));defer{claimer.shutdown()}
        claim.begin(try claim.prepare(entry:"finish-the-game"))
        for move in ["a2b2","b2a2","a2b2","b2a2"]{await play(claim,move)}
        claim.claimDraw()
        XCTAssertEqual(claim.exercise?.status,.incorrect);XCTAssertEqual(claim.exercise?.snapshot.actions.last,.claim("threefold repetition"));XCTAssertTrue(claim.exercise?.feedback.contains("Draw claimed") ?? false)
    }
    func testNoProgressDrawsFollowTheClock()throws {
        // Fifty moves by each side without a capture or pawn move may be claimed; seventy-five end the game.
        XCTAssertNil(try TrainingLegality(fen:"7k/8/8/8/8/8/R7/4K3 w - - 99 80").claimableDraw())
        XCTAssertEqual(try TrainingLegality(fen:"7k/8/8/8/8/8/R7/4K3 w - - 100 80").claimableDraw(),"the 50-move rule")
        XCTAssertNil(try TrainingLegality(fen:"7k/8/8/8/8/8/R7/4K3 w - - 100 80").automaticDraw(),"a claim is never automatic")
        XCTAssertEqual(try TrainingLegality(fen:"7k/8/8/8/8/8/R7/4K3 w - - 150 100").automaticDraw(),"the 75-move rule")
        XCTAssertEqual(try TrainingLegality(fen:"7k/8/8/8/8/8/8/4K3 w - - 0 1").automaticDraw(),"neither side has enough material to checkmate")
    }
    func testRepetitionSurvivesAResume()async throws {
        let shuffle={(rules:ChessRules)->String? in rules.piece("h8") != nil ? "h8g8":"g8h8"}
        let (session,player,controller)=try Self.fixture([Self.ending("7k/8/8/8/8/8/R7/4K3 w - - 0 1",variant:"krk")],defender:ScriptedDefender(choose:shuffle));defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        for move in ["a2b2","b2a2","a2b2","b2a2"]{await play(controller,move)}
        XCTAssertEqual(controller.exercise?.claimable,"threefold repetition")
        controller.openLibrary()
        let resumed=TrainingController(session:session,learning:player,provider:controller.provider);resumed.games.engine=ScriptedDefender(choose:shuffle)
        resumed.begin(try resumed.prepareResume())
        XCTAssertEqual(resumed.exercise?.claimable,"threefold repetition","the replayed history keeps every repetition")
    }
    func testHintsUndoAndTheBreakReminderAreRecordedHonestly()async throws {
        let defender=ScriptedDefender()
        let (session,player,controller)=try Self.fixture([Self.ending("8/8/8/8/K7/3Q4/8/k7 w - - 0 1")],defender:defender);defer{player.shutdown()}
        controller.games.reminderPlies=2
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        await play(controller,"d3d2")
        XCTAssertEqual(controller.exercise?.line,["d3d2","a1b1"]);XCTAssertTrue(controller.exercise?.reminder ?? false,"a break is suggested");XCTAssertFalse(controller.exercise?.finished ?? true,"never a loss")
        controller.dismissReminder();XCTAssertFalse(controller.exercise?.reminder ?? true)
        controller.hint();controller.hint();XCTAssertEqual(Set(controller.exercise?.hintSquares ?? []),["d2","b1"],"the second hint shows the queen and the lone king")
        controller.hint()
        for _ in 0..<200 where controller.exercise?.hintText?.hasPrefix("One good move") != true{try await Task.sleep(nanoseconds:2_000_000)}
        XCTAssertTrue(controller.exercise?.hintText?.hasPrefix("One good move") ?? false);XCTAssertEqual(controller.exercise?.hintSquares.count,2)
        controller.undo()
        XCTAssertEqual(controller.exercise?.line,[]);XCTAssertEqual(controller.exercise?.board["d3"],"wq");XCTAssertTrue(controller.exercise?.snapshot.recordedHelp ?? false)
        await play(controller,"d3d2")
        XCTAssertEqual(session.state.training?.active?.actions.last,.reply("a1b1"))
    }
    func testClickingTwoSquaresPlaysAGameMove()async throws {
        let (_,player,controller)=try Self.fixture([Self.ending("8/8/8/8/K7/3Q4/8/k7 w - - 0 1")],defender:ScriptedDefender());defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        controller.click("d3");controller.click("d2");await Self.settle(controller)
        XCTAssertEqual(controller.exercise?.line,["d3d2","a1b1"],"a clicked move is played, not dropped")
    }
    func testAGameTooLongToSaveIsPausedNotLost()async throws {
        let (session,player,controller)=try Self.fixture([Self.ending("8/8/8/8/K7/3Q4/8/k7 w - - 0 1")],defender:ScriptedDefender());defer{player.shutdown()}
        controller.games.maximumActions=2
        controller.begin(try controller.prepare(entry:"finish-the-game"))
        await play(controller,"d3d2");await play(controller,"d2c2")
        XCTAssertNotNil(controller.exercise?.paused);XCTAssertFalse(controller.exercise?.finished ?? true);XCTAssertEqual(controller.exercise?.line.count,2)
        XCTAssertEqual(session.state.training?.attempts.count ?? 0,0,"a technical pause is never a result")
    }
}
