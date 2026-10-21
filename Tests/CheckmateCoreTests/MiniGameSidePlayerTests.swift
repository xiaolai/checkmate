import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateApplication

/// L-23 and L-24 in the player: a learner may take Black in a game equal from both sides, the computer then plays
/// White, and every finish against the computer counts at its level from the learner's side, with a suggested step.
@MainActor final class MiniGameSidePlayerTests:XCTestCase {
    override func setUp(){MiniGameOffering.testTable=MiniGameLevelPlayerTests.allLevels}
    override func tearDown(){MiniGameOffering.testTable=nil}
    private func fixture(_ state:ApplicationState=ApplicationState())throws -> (GameSession,LearningPlayer) {
        let session=try GameSession(engine:nil,state:state),player=try LearningPlayer(session:session)
        session.state.settings.pieceDuration=0;player.settingsChanged();return (session,player)
    }
    private func reply(_ player:LearningPlayer,until turn:String)async throws {
        for _ in 0..<150 where player.miniThinking{try await Task.sleep(for:.milliseconds(20))}
        XCTAssertFalse(player.miniThinking,"the computer did not reply");XCTAssertEqual(player.miniTurn,turn)
    }
    /// A saved Pawn Duel with Black to move, played from Black in its run: a1 is two moves away for the a-pawn.
    private func blackNearlyWon(level:String="standard",record:MiniGameRecord=MiniGameRecord())->ApplicationState {
        var game=MiniGameState(kind:.pawnDuel);game.snapshot.board=["a3":"bp","h2":"wp","c7":"bp"];game.snapshot.turn="b";game.settleLevel(adopting:level)
        var state=ApplicationState(),record=record;record.side=MiniGameRunSide(run:game.run,side:"b")
        state.miniGames=["pawn-duel":game];state.miniGameRecords=["pawn-duel":record];return state
    }

    func testPlayingBlackTheComputerOpensAndTheLearnerAnswers()async throws {
        let (session,player)=try fixture();defer{player.shutdown()}
        XCTAssertTrue(player.miniSideOffered == false,"nothing is offered outside a mini-game")
        session.state.settings.miniLearnerSides=["pawn-duel":"b"];player.startMini(.pawnDuel)
        XCTAssertTrue(player.miniSideOffered);XCTAssertEqual(player.miniLearnerSide,"b");XCTAssertEqual(session.state.miniGameRecords?["pawn-duel"]?.side?.side,"b","saved with the board")
        XCTAssertTrue(player.miniThinking,"the computer plays White's first move");XCTAssertEqual(player.miniStatus,"Computer’s turn · White")
        try await reply(player,until:"b");XCTAssertEqual(player.miniGame?.history.count,1);XCTAssertEqual(player.miniStatus,"Your turn · Black")
        let before=player.miniGame;player.click("b2");player.click("b3");XCTAssertEqual(player.miniGame,before,"the learner never moves the computer's pieces")
        player.click("e7");player.click("e6");XCTAssertTrue(player.miniThinking);try await reply(player,until:"b");XCTAssertEqual(player.miniGame?.history.count,3)
        player.undoMini();XCTAssertEqual(player.miniGame?.history.count,1,"undo takes back the learner's move and the reply");XCTAssertEqual(player.miniTurn,"b");XCTAssertFalse(player.miniThinking)
        XCTAssertEqual(player.miniGame?.board["e7"],"bp")
        // A game the computer does not play, or one uneven between the sides, is always played from White.
        player.setMiniComputer(false);XCTAssertFalse(player.miniSideOffered)
        session.state.settings.miniLearnerSides=["pawn-duel":"b","knight-capture":"b"];player.startMini(.knightCapture,restart:true)
        XCTAssertFalse(player.miniSideOffered);XCTAssertEqual(player.miniLearnerSide,"w");XCTAssertFalse(player.miniThinking)
    }
    func testChoosingASideStartsAFreshGameAtItAndKeepsAGameInProgress()async throws {
        let (session,player)=try fixture();defer{player.shutdown()}
        player.startMini(.pawnDuel);XCTAssertEqual(player.miniLearnerSide,"w");XCTAssertEqual(player.miniPreferredSide,"w")
        let seed=player.miniGame?.opponentSeed;player.setMiniSide("b")
        XCTAssertEqual(session.state.settings.miniLearnerSides,["pawn-duel":"b"]);XCTAssertEqual(player.miniLearnerSide,"b");XCTAssertNotEqual(player.miniGame?.opponentSeed,seed,"a game with no move restarts at once")
        try await reply(player,until:"b");player.click("e7");player.click("e6");try await reply(player,until:"b")
        player.setMiniSide("w");XCTAssertEqual(player.miniLearnerSide,"b","a game in progress keeps its side");XCTAssertTrue(player.miniNewSideOffered)
        player.restartMini();XCTAssertEqual(player.miniLearnerSide,"w");XCTAssertFalse(player.miniNewSideOffered)
        player.setMiniSide("x");XCTAssertEqual(session.state.settings.miniLearnerSides,["pawn-duel":"w"],"an unknown side is refused")
        // An older save's run in progress, with no side recorded, was played from White.
        var old=MiniGameState(kind:.pawnDuel);XCTAssertTrue(old.play(MiniGameMove(from:"e2",to:"e4")));XCTAssertTrue(old.play(MiniGameMove(from:"e7",to:"e5")))
        var state=ApplicationState();state.miniGames=["pawn-duel":old];state.settings.miniLearnerSides=["pawn-duel":"b"]
        let (_,resumed)=try fixture(state);defer{resumed.shutdown()};resumed.startMini(.pawnDuel);XCTAssertEqual(resumed.miniLearnerSide,"w");XCTAssertFalse(resumed.miniThinking)
    }
    func testAWinAsBlackCountsAtItsLevelAndThreeInARowSuggestAStepUp()async throws {
        var streak=MiniGameRecord();streak.streak="ww";streak.streakLevel="standard";streak.levels=["standard":MiniGameTally(wins:2)]
        let (session,player)=try fixture(blackNearlyWon(record:streak));defer{player.shutdown()}
        player.startMini(.pawnDuel);XCTAssertEqual(player.miniLearnerSide,"b");XCTAssertNil(player.miniAdvice,"no advice during a game")
        player.click("a3");player.click("a2");try await reply(player,until:"b")
        player.click("a2");player.click("a1");XCTAssertEqual(player.miniGame?.winner,"b");XCTAssertEqual(player.miniStatus,"You win!")
        XCTAssertEqual(session.state.miniGameRecords?["pawn-duel"]?.levels["standard"],MiniGameTally(wins:3));XCTAssertEqual(session.state.training?.summaries["pawn-duel"]?.legacyWins,1,"the training summary counts the learner's win")
        XCTAssertEqual(player.miniAdvice,.stepUp(to:"challenging"));XCTAssertEqual(player.miniRecordText,"At Steady: 3 won, 0 drawn, 0 lost")
        player.undoMini();player.click("a2");player.click("a1");XCTAssertEqual(session.state.miniGameRecords?["pawn-duel"]?.levels["standard"],MiniGameTally(wins:3),"a replayed finish of the same run counts once")
        player.takeMiniAdvice();XCTAssertEqual(session.state.settings.miniOpponentProfiles["pawn-duel"],"challenging");XCTAssertEqual(player.miniLevel,"challenging","the step starts a new game at it");XCTAssertNil(player.miniAdvice)
        XCTAssertEqual(player.miniLearnerSide,"w","the side preference was never chosen here, so the new game is from White")
    }
}
