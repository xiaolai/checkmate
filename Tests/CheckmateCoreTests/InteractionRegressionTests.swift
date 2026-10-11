import XCTest
@testable import CheckmateCore
/// Replies with the first legal move and counts requests, so tests can see whether the opponent was asked to move.
@MainActor private final class CountingEngine:EngineService {
    var requests=0
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int) async throws->EngineAnalysis {requests+=1;let rules=try ChessRules(fen:fen);return EngineAnalysis(bestMove:rules.moves().first?.uci)}
}
/// A board click must never look playable when it cannot play, and no learner action may leave the game stuck.
final class InteractionRegressionTests:XCTestCase {
    @MainActor private func settle() async {for _ in 0..<20{await Task.yield();try? await Task.sleep(nanoseconds:5_000_000)}}

    @MainActor func testOpponentPiecesAndOpponentTurnsAreNeverPlayable()throws {
        let s=try GameSession(engine:nil)
        try s.select("e7");XCTAssertEqual(s.inspection?.legalNow,false,"Black's pawn is not the learner's to move")
        try s.select("e5");XCTAssertEqual(s.selected,"e5");XCTAssertEqual(s.rules.history,[],"An opponent destination never plays")
        try s.select("e2");XCTAssertEqual(s.inspection?.legalNow,true);try s.select("e4");XCTAssertEqual(s.rules.history,["e4"])
        try s.select("d2");XCTAssertEqual(s.inspection?.legalNow,false,"Own piece on the opponent's turn")
        try s.select("d4");XCTAssertEqual(s.selected,"d2","A possible destination keeps the piece selected");XCTAssertEqual(s.rules.history,["e4"])
        XCTAssertTrue(s.message.contains("Wait for the opponent"))
    }

    @MainActor func testSelectionSurvivesTheOpponentReplyAndThenPlays()throws {
        let s=try GameSession(engine:nil);try s.playWhite(from:"e2",to:"e4");try s.select("d2")
        _ = try s.commitBlack("e7e5")
        XCTAssertEqual(s.selected,"d2");XCTAssertEqual(s.inspection?.legalNow,true)
        try s.select("d4");XCTAssertEqual(s.rules.history,["e4","e5","d4"])
    }

    @MainActor func testCapturedSelectionIsDroppedAfterTheReply()throws {
        let s=try GameSession(engine:nil);try s.playWhite(from:"e2",to:"e4");_ = try s.commitBlack("d7d5");try s.playWhite(from:"g1",to:"f3");try s.select("e4")
        _ = try s.commitBlack("d5e4");XCTAssertNil(s.selected,"The selected piece was captured")
    }

    /// SH-14: as Black, Stockfish's opening move alone is not the learner's to take back; Undo is unavailable instead of
    /// silently re-rolling Stockfish's move.
    @MainActor func testUndoCannotTakeBackTheOpponentsOpeningMove() async throws {
        let engine=CountingEngine(),s=try GameSession(engine:engine);s.state.settings.coachingMode="quiet"
        try s.installPracticeFork(try ChessRules(),side:"b");await settle()
        XCTAssertEqual(engine.requests,1);XCTAssertEqual(s.rules.history.count,1);XCTAssertEqual(s.rules.turn,"b");XCTAssertFalse(s.canTakeBack)
        s.undo();await settle()
        XCTAssertEqual(engine.requests,1,"Stockfish is not asked again");XCTAssertEqual(s.rules.history.count,1);XCTAssertEqual(s.rules.turn,"b")
    }

    @MainActor func testRetryRepeatsTheFailedHintOnTheLearnersTurn() async throws {
        let engine=CountingEngine(),s=try GameSession(engine:engine)
        s.retryEngine();XCTAssertEqual(s.busyReason,"analysis","Retry on the learner's turn retries the hint");await settle()
        XCTAssertEqual(engine.requests,1)
    }

    @MainActor func testPositionChangesClearAStaleEngineError() async throws {
        let s=try GameSession(engine:nil);s.hint();await settle();XCTAssertNotNil(s.error,"Fixture: a hint without an engine fails")
        try s.playWhite(from:"e2",to:"e4");XCTAssertNil(s.error,"The failure belonged to the previous position")
    }

    @MainActor func testRestorePreviousSwapsBothGamesWithTheirSides()throws {
        let s=try GameSession(engine:nil);try s.playWhite(from:"e2",to:"e4");s.newGame()
        let fork=try ChessRules();try fork.restore("1. d4 d5 2. c4");try s.installPracticeFork(fork,side:"b")
        XCTAssertEqual(s.state.practice.previousGame.contains("e4"),true);XCTAssertEqual(s.state.practice.previousSide,"w")
        try s.restorePrevious()
        XCTAssertEqual(s.rules.history,["e4"]);XCTAssertEqual(s.humanSide,"w");XCTAssertEqual(s.state.practice.previousSide,"b")
        XCTAssertTrue(s.state.practice.previousGame.contains("c4"),"The replaced game is kept as the previous game")
        try s.restorePrevious()
        XCTAssertEqual(s.rules.history,["d4","d5","c4"]);XCTAssertEqual(s.humanSide,"b")
    }

    func testPreviousSideDecodesSafely()throws {
        func decode(_ json:String)throws->PracticeState {try JSONDecoder().decode(PracticeState.self,from:Data(json.utf8))}
        XCTAssertEqual(try decode("{\"previousGame\":\"1. e4 *\"}").previousSide,"w","Saves before sides were recorded were White games")
        XCTAssertEqual(try decode("{\"previousSide\":\"b\"}").previousSide,"b")
        XCTAssertEqual(try decode("{\"previousSide\":\"x\"}").previousSide,"w")
        var state=PracticeState();state.previousSide="b"
        XCTAssertEqual(try JSONDecoder().decode(PracticeState.self,from:JSONEncoder().encode(state)).previousSide,"b")
    }

    @MainActor func testLeavingAnImaginedBoardDropsItsSelection()throws {
        let s=try GameSession(engine:nil);try s.beginPreview();try s.select("e2");XCTAssertEqual(s.selected,"e2")
        s.closePresentation();XCTAssertNil(s.selected,"A selection made on the preview board does not carry into the game")
    }

    @MainActor func testPresentationsStartWithoutAnotherBoardsSelection()throws {
        let s=try GameSession(engine:nil);try s.select("e2");try s.beginPreview();XCTAssertNil(s.selected,"Try a move starts clean")
        s.closePresentation();try s.select("e2")
        try s.demonstrate(title:"Idea",introduction:"",lines:[DemoLineInput(label:"Line",moves:[DemoStepInput(uci:"e2e4")])])
        XCTAssertNil(s.selected,"A live selection's playable dots would be drawn over the demonstration")
    }

    @MainActor func testAForkedPositionWithoutMovesIsKeptAsThePreviousGame()throws {
        let s=try GameSession(engine:nil);try s.installPracticeFork(try ChessRules(fen:"4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"),side:"w")
        s.newGame();XCTAssertFalse(s.state.practice.previousGame.isEmpty,"The position was dropped")
        try s.restorePrevious();XCTAssertEqual(s.rules.fen,"4k3/8/8/8/8/8/4P3/4K3 w - - 0 1")
        XCTAssertTrue(s.state.practice.previousGame.isEmpty,"An untouched standard start is not worth keeping")
    }

    @MainActor func testMovePuzzleSwitchesFromAnOpponentPickWithoutGrading()throws {
        let library=try CourseLibrary()
        let candidate=library.puzzles.first{p in let e=p.exercise;guard e.kind=="move",let from=e.from,let mover=p.board?[from]?.first else{return false};return p.board?.contains{$0.value.first != mover} == true}
        let puzzle=try XCTUnwrap(candidate);let e=puzzle.exercise,mover=try XCTUnwrap(puzzle.board?[e.from!]?.first)
        let opponent=try XCTUnwrap(puzzle.board?.first{$0.value.first != mover}?.key)
        let session=try GameSession(engine:nil),p=try LearningPlayer(session:session);p.openPuzzle(id:puzzle.id)
        p.click(opponent);XCTAssertEqual(p.picked,[],"An opponent piece is not the piece to move")
        p.click(e.from!);p.click(e.to!);XCTAssertEqual(session.state.puzzles[puzzle.id]?.solved,true)
    }

    @MainActor func testPuzzleLibraryEndsAMiniGame()throws {
        let p=try LearningPlayer(session:try GameSession(engine:nil));p.startPawnDuel();XCTAssertTrue(p.mini)
        p.showPuzzleLibrary();XCTAssertFalse(p.mini,"Mini-game controls stay live behind the library")
    }

    @MainActor func testMovePuzzleSwitchesPiecesInsteadOfGradingTheSwitch()throws {
        let library=try CourseLibrary()
        let candidate=library.puzzles.first{p in let e=p.exercise;guard e.kind=="move",let from=e.from,let mover=p.board?[from]?.first else{return false};return p.board?.contains{$0.key != from && $0.value.first==mover} == true}
        let puzzle=try XCTUnwrap(candidate,"No move puzzle with a second piece of the moving side");let e=puzzle.exercise
        let other=try XCTUnwrap(puzzle.board?.first{$0.key != e.from && $0.value.first==puzzle.board?[e.from!]?.first}?.key)
        let session=try GameSession(engine:nil),p=try LearningPlayer(session:session);p.openPuzzle(id:puzzle.id)
        p.click(other);p.click(e.from!);XCTAssertEqual(p.picked,[e.from!]);XCTAssertFalse(p.passed)
        p.click(e.to!);XCTAssertTrue(p.passed);XCTAssertEqual(session.state.puzzles[puzzle.id]?.solved,true,"Switching pieces was graded as a wrong answer")
    }

    @MainActor func testNextPuzzleContinuesWhenTheSolvedPuzzleLeavesTheFilter()throws {
        let p=try LearningPlayer(session:try GameSession(engine:nil));p.filter="Unsolved"
        let first=try XCTUnwrap(p.filteredPuzzles.first{$0.exercise.kind=="choice"});p.openPuzzle(id:first.id);p.choose(first.exercise.answer!)
        XCTAssertTrue(p.passed);XCTAssertFalse(p.filteredPuzzles.contains{$0.id==first.id})
        p.next();XCTAssertNotNil(p.activePuzzle);XCTAssertNotEqual(p.activePuzzle?.id,first.id,"Next puzzle did nothing")
    }

    @MainActor func testAMoveOnTheOriginalGameOpensAnImaginedLine()throws {
        let s=try GameSession(engine:nil),r=ReviewController(),d=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        r.open(d,practice:s);try r.selectSquare("d2");XCTAssertEqual(r.destinations.contains("d4"),true)
        try r.selectSquare("d4");XCTAssertEqual(r.branch?.moves,["d2d4"]);XCTAssertEqual(r.branch?.root,0);XCTAssertEqual(d.mainline.count,2,"The imported record is unchanged")
    }
}
