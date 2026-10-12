import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-003: existing mini-games keep one saved board whichever way they are opened. Progress only observes an
/// unfinished-to-finished transition, in the same save as the board; undo, replay and loading never add another.
@MainActor final class TrainingLegacyBridgeTests:XCTestCase {
    private let day=Date(timeIntervalSince1970:1_800_000_000)
    /// White to play a7-a8 and win Pawn Duel, two-player so no computer reply is involved.
    private func nearlyWon()->MiniGameState {var game=MiniGameState(kind:.pawnDuel,computer:false);game.snapshot.board=["a7":"wp","h7":"bp","c2":"wp"];return game}
    private func fixture(_ state:ApplicationState=ApplicationState())throws -> (GameSession,LearningPlayer,[ApplicationState]) {
        let session=try GameSession(engine:nil,state:state),player=try LearningPlayer(session:session);player.now={[day] in day}
        player.calendar=Calendar(identifier:.gregorian);player.calendar.timeZone=TimeZone(identifier:"UTC")!
        return (session,player,[])
    }
    func testFinishingFromTheLibraryRecordsOneEventInTheSameSave()throws {
        var state=ApplicationState();state.miniGames=["pawn-duel":nearlyWon()]
        let (session,player,_)=try fixture(state);defer{player.shutdown()}
        var saves:[ApplicationState]=[];session.onPersist={saves.append($0)}
        player.startMini(.pawnDuel,fromLibrary:true);XCTAssertEqual(session.activity,.at(.miniGame(lessonIndex:nil,kind:.pawnDuel)))
        XCTAssertNil(session.state.training,"opening an unfinished game records nothing")
        player.click("a7");player.click("a8")
        XCTAssertTrue(player.miniGame?.isFinished ?? false)
        let events=try XCTUnwrap(session.state.training?.events);XCTAssertEqual(events.count,1)
        XCTAssertEqual(events[0].origin,"library");XCTAssertEqual(events[0].winner,"w");XCTAssertEqual(events[0].kind,"pawn-duel");XCTAssertEqual(events[0].computer,false)
        XCTAssertEqual(session.state.training?.summaries["pawn-duel"]?.twoPlayerFinishes,1)
        // The first save that holds the finished board already holds its event: they commit together.
        let finishedSave=try XCTUnwrap(saves.first{$0.miniGames?["pawn-duel"]?.isFinished==true})
        XCTAssertEqual(finishedSave.training?.events.map(\.id),events.map(\.id))
        XCTAssertNil(String(data:try JSONEncoder().encode(session.state.training),encoding:.utf8)?.range(of:"\"board\""),"training holds no copy of the legacy board")
        // Undo and the same win again in this run: no second event.
        player.undoMini();player.click("a7");player.click("a8");XCTAssertEqual(session.state.training?.events.count,1)
        // Leaving returns to the library; an explicit restart is a new run that may earn a new event.
        player.leaveMini();XCTAssertEqual(session.activity,.at(.trainingLibrary))
        player.startMini(.pawnDuel,restart:true,computer:false,fromLibrary:true);player.restartMini()
        XCTAssertEqual(session.activity,.at(.miniGame(lessonIndex:nil,kind:.pawnDuel)),"restart keeps the library origin")
        XCTAssertNotEqual(player.miniGame?.opponentSeed,events[0].run)
    }
    func testBothEntryPointsShareTheOneBoardAndTheLessonOriginIsRecorded()throws {
        var state=ApplicationState();state.miniGames=["pawn-duel":nearlyWon()]
        let (session,player,_)=try fixture(state);defer{player.shutdown()}
        player.startMini(.pawnDuel,fromLibrary:true);player.click("c2");player.click("c3");let board=player.miniGame?.board
        player.leaveMini()
        player.openLesson(index:3);player.startMini(.pawnDuel)
        XCTAssertEqual(session.activity,.at(.miniGame(lessonIndex:3,kind:.pawnDuel)));XCTAssertEqual(player.miniGame?.board,board,"the same saved board, resumed")
        player.click("h7");player.click("h6");player.click("a7");player.click("a8")
        XCTAssertEqual(session.state.training?.events.map(\.origin),["lesson"])
        // Switching entry points afterwards never re-awards the finished run.
        player.leaveMini();player.startMini(.pawnDuel,fromLibrary:true);XCTAssertEqual(session.state.training?.events.count,1)
    }
    func testALoadedFinishedGameInventsNoWin()throws {
        var state=ApplicationState(),game=nearlyWon();_ = game.play(MiniGameMove(from:"a7",to:"a8"));XCTAssertTrue(game.isFinished);state.miniGames=["pawn-duel":game]
        let (session,player,_)=try fixture(state);defer{player.shutdown()}
        player.startMini(.pawnDuel,fromLibrary:true);player.undoMini();player.leaveMini();player.startMini(.pawnDuel,fromLibrary:true)
        XCTAssertNil(session.state.training?.events.first,"a historical terminal board produces no event")
    }
    func testAnOldSaveWithoutASeedIsOneRunUntilRestarted()throws {
        var game=nearlyWon();game.opponentSeed=nil;var state=ApplicationState();state.miniGames=["pawn-duel":game]
        let (session,player,_)=try fixture(state);defer{player.shutdown()}
        player.startMini(.pawnDuel,fromLibrary:true);player.click("a7");player.click("a8");player.undoMini();player.click("a7");player.click("a8")
        XCTAssertEqual(session.state.training?.events.map(\.run),["unseeded"])
        // An imported backup of the same run is not credited again: the record of credited runs travels with it.
        let backup=session.state;session.state.miniGames?["pawn-duel"]=nil
        try session.installImportedState(backup);let player2=try LearningPlayer(session:session);defer{player2.shutdown()}
        player2.startMini(.pawnDuel,fromLibrary:true);player2.undoMini();player2.click("a7");player2.click("a8")
        XCTAssertEqual(session.state.training?.events.count,1)
    }
    func testAReviewOverALibraryGameReturnsToIt()throws {
        let (session,player,_)=try fixture();defer{player.shutdown()}
        let coordinator=WorkspaceTransitionCoordinator(session:session,learning:player,review:ReviewController())
        player.startMini(.queenVsPawns,fromLibrary:true);session.enterReview(document:nil)
        try coordinator.enter(prepared:try coordinator.prepare(.returnToGame),from:.miniGame(lessonIndex:nil,kind:.queenVsPawns),wasReviewing:true)
        XCTAssertEqual(session.activity,.at(.miniGame(lessonIndex:nil,kind:.queenVsPawns)));XCTAssertEqual(session.mode,.training)
    }
}
