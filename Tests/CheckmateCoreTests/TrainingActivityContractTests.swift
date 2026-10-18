import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-001: the truthful training activity. A library-opened mini-game is training mode with unchanged rules, while a
/// lesson-opened one keeps today's lesson payload; agents, voice and moves fail closed outside practice.
@MainActor final class TrainingActivityContractTests:XCTestCase {
    private func fixture()throws -> (GameSession,LearningPlayer,CompanionTools) {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session),tools=try CompanionTools(session:session)
        session.setConnection(enabled:true,role:"coach",lease:"lease");return (session,player,tools)
    }
    private func code(_ body:() async throws -> Any) async -> String? {do{_ = try await body();return nil}catch let failure as ProtocolFailure{return failure.code}catch{return "\(error)"}}
    func testLibraryGameIsTruthfulTrainingWithUnchangedRules()async throws {
        let (session,player,tools)=try fixture();defer{player.shutdown()}
        let course=session.state.course
        player.startMini(.queenVsPawns,fromLibrary:true)
        XCTAssertEqual(session.activity,.at(.miniGame(lessonIndex:nil,kind:.queenVsPawns)));XCTAssertEqual(session.mode,.training)
        XCTAssertNil(session.lesson,"no lesson projection describes a library game")
        let state=session.publicState()
        XCTAssertEqual(state["mode"] as? String,"training");XCTAssertEqual(state["capabilities"] as? [String],[]);XCTAssertEqual(state["trainingProtocol"] as? Int,1)
        let training=try XCTUnwrap(state["training"] as? [String:Any])
        XCTAssertEqual(training["view"] as? String,"legacy_game");XCTAssertEqual(training["entryId"] as? String,"queen-vs-pawns");XCTAssertEqual(training["ruleMode"] as? String,"simplifiedVariant")
        XCTAssertEqual(training["rules"] as? [String],[MiniGameKind.queenVsPawns.rules],"the original rules, labelled as simplified")
        XCTAssertEqual(training["pieces"] as? [String:String],MiniGameKind.queenVsPawns.initialBoard)
        XCTAssertEqual(session.state.course.lessonID,course.lessonID,"opening from the library never moves the course bookmark");XCTAssertEqual(session.state.course.step,course.step)
        XCTAssertFalse(player.playing,"no narration")
        // Agent and voice gates fail closed outside practice.
        let args:[String:Any]=["sessionId":session.sessionId,"revision":session.revision]
        let moves=await code{try await tools.call("get_legal_moves",args:args,lease:"lease")}
        XCTAssertEqual(moves,"UNSUPPORTED_MODE")
        let brief=await code{try await tools.call("get_turn_brief",args:[:],lease:"lease")}
        XCTAssertEqual(brief,"UNSUPPORTED_MODE")
        let annotate=await code{try await tools.call("show_annotation",args:args.merging(["requestId":"annotate","positionId":session.positionId,"arrows":[["a2","a3"]],"highlights":[]]){a,_ in a},lease:"lease")}
        XCTAssertEqual(annotate,"UNSUPPORTED_MODE","generic annotations cannot reach training unrecorded")
        let play=await code{try await tools.call("play_move",args:args.merging(["requestId":"play"]){a,_ in a},lease:"lease")}
        XCTAssertEqual(play,"UNSUPPORTED_MODE")
        let projection=try await tools.call("get_session",args:[:],lease:"lease") as? [String:Any];XCTAssertEqual(projection?["mode"] as? String,"training")
        session.setConnection(enabled:false,role:"coach")
        XCTAssertThrowsError(try session.openVoice(),"voice cannot seize training")
        // A late lesson publish cannot paint over training.
        session.setLesson(LessonProjection(mode:"lesson",pieces:["e4":"wp"],title:"Stale",lessonId:"stale",step:0,prompt:nil,choices:nil,playing:false,narrationActive:false,moving:false,turn:nil,winner:nil,rules:nil))
        XCTAssertNil(session.lesson);XCTAssertEqual(session.displayBoard,MiniGameKind.queenVsPawns.initialBoard)
    }
    func testLessonGameKeepsItsExistingPayload()throws {
        let (session,player,_)=try fixture();defer{player.shutdown()}
        let index=try XCTUnwrap(player.library.lessons.firstIndex{$0.id=="pawn-duel"})
        player.openLesson(index:index);player.startMini(.pawnDuel)
        XCTAssertEqual(session.activity,.at(.miniGame(lessonIndex:index,kind:.pawnDuel)));XCTAssertEqual(session.mode,.lesson)
        let state=session.publicState()
        XCTAssertEqual(state["mode"] as? String,"pawn_duel");XCTAssertNil(state["training"]);XCTAssertNil(state["trainingProtocol"],"existing payloads are unchanged")
        XCTAssertNil(session.training)
        player.leaveMini();XCTAssertEqual(session.activity,.at(.lesson(index:index)),"a lesson game returns to its lesson")
    }
    func testOneBoardAcrossEntryPointsAndExplicitRestart()throws {
        let (session,player,_)=try fixture();defer{player.shutdown()}
        player.setMiniComputer(false)
        let index=try XCTUnwrap(player.library.lessons.firstIndex{$0.id=="pawn-duel"});player.openLesson(index:index);player.startMini(.pawnDuel,computer:false)
        player.click("e2");player.click("e4");let board=try XCTUnwrap(player.miniGame?.board);XCTAssertEqual(board["e4"],"wp")
        player.leaveMini();player.startMini(.pawnDuel,fromLibrary:true)
        XCTAssertEqual(player.miniGame?.board,board,"Continue from the library resumes the same saved board");XCTAssertEqual(session.state.miniGames?.count,1)
        player.restartMini();XCTAssertEqual(player.miniGame?.board,MiniGameKind.pawnDuel.initialBoard,"New Game is an explicit restart")
        XCTAssertEqual(session.activity,.at(.miniGame(lessonIndex:nil,kind:.pawnDuel)),"a restart keeps the library origin")
        player.leaveMini();XCTAssertEqual(session.activity,.at(.trainingLibrary),"a library game returns to the library")
        XCTAssertEqual(session.training,.library)
    }
    func testLibraryGameComputerReplyUsesTrainingMode()async throws {
        let (session,player,_)=try fixture();defer{player.shutdown()}
        session.state.settings.pieceDuration=0
        player.startMini(.pawnDuel,restart:true,fromLibrary:true)
        player.click("e2");player.click("e4");XCTAssertTrue(player.miniThinking,"the computer reply is scheduled in training mode")
        for _ in 0..<80 where player.miniGame?.history.count != 2 {try await Task.sleep(for:.milliseconds(25))}
        XCTAssertEqual(player.miniGame?.history.count,2);XCTAssertEqual(player.miniTurn,"w")
        XCTAssertEqual(session.training?.turn,"w");XCTAssertEqual(session.mode,.training)
        // A profile change leaves the pending reply in training mode too: it still arrives.
        player.click("d2");player.click("d4");XCTAssertTrue(player.miniThinking)
        session.state.settings.miniOpponentProfile="beginner";player.settingsChanged();XCTAssertTrue(player.miniThinking)
        for _ in 0..<80 where player.miniGame?.history.count != 4 {try await Task.sleep(for:.milliseconds(25))}
        XCTAssertEqual(player.miniGame?.history.count,4)
    }
    func testTrainingProjectionClearsOnLeavingTraining()throws {
        let (session,player,_)=try fixture();defer{player.shutdown()}
        player.startMini(.knightCorners,fromLibrary:true);XCTAssertNotNil(session.training)
        player.openLesson(index:0);XCTAssertNil(session.training,"no training projection outlives the activity");XCTAssertEqual(session.mode,.lesson)
        XCTAssertEqual(session.publicState()["mode"] as? String,"lesson")
    }
}
