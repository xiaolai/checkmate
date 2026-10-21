import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateApplication

/// B-23: Game ▸ Type a Move… (⌘L) plays a typed move on whatever board takes moves, through that board's own rules;
/// a refusal is shown and spoken, and nothing changes.
@MainActor final class TypedMoveEntryTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}

    func testTheGameMenuOffersTypeAMoveOnCommandL(){
        let menu=AppDelegate.makeGameMenu(target:nil),item=menu.items.first{$0.action == #selector(GameWindow.typeMove)}
        XCTAssertEqual(item?.title,"Type a Move…");XCTAssertEqual(item?.keyEquivalent,"l");XCTAssertEqual(item?.keyEquivalentModifierMask,[.command])
        XCTAssertEqual(menu.items.filter{$0.keyEquivalent=="l" && $0.keyEquivalentModifierMask == [.command]}.count,1,"⌘L is not used twice")
        XCTAssertTrue(HelpContent.sections.contains{$0.text.contains("Game ▸ Type a Move… (⌘L)")},"Help names the command and its shortcut")
    }
    func testPracticePlaysATypedMoveAndExplainsARefusal()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        model.practice();model.session.newGame(side:"w");game.refresh()
        XCTAssertTrue(game.typedMoveAvailable)
        XCTAssertEqual(game.submitTypedMove("Nf6"),"No knight of yours can move to f6.");XCTAssertEqual(model.session.rules.history,[])
        XCTAssertNil(game.submitTypedMove("e4"));XCTAssertEqual(model.session.rules.history.first,"e4")
        // The opponent's reply is asynchronous, so the position where it is the opponent's turn is set, not waited for.
        model.session.cancelWork();try model.session.rules.restore("1. e4 *");game.refresh();XCTAssertEqual(model.session.rules.turn,"b")
        XCTAssertEqual(game.submitTypedMove("Nf3"),"It's not your move yet.");XCTAssertEqual(model.session.rules.history,["e4"])
        // An earlier position shown from the move list takes no move.
        model.session.cancelWork();try model.session.rules.restore("1. e4 e5 *");game.refresh();game.showPracticeMove(0)
        XCTAssertEqual(game.submitTypedMove("Nf3"),"This is an earlier position. Choose Back to Game to play.");XCTAssertEqual(model.session.rules.history,["e4","e5"])
    }
    func testALessonExercisePlaysATypedMove()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        let fork=try XCTUnwrap(model.learning.library.lessons.firstIndex{$0.id=="fork"})
        model.lesson(fork);model.learning.goToAttempt();game.refresh()
        let attempt=try XCTUnwrap(model.learning.attempt);XCTAssertTrue(attempt.learnerToMove,"fixture: the exercise waits for the learner")
        let legal=try XCTUnwrap(attempt.rules.moves().first{$0.promotion==nil})
        XCTAssertNil(game.submitTypedMove(legal.from+legal.to));XCTAssertEqual(attempt.record?.moves.first,legal.uci)
    }
    func testAMiniGamePlaysATypedMoveByItsOwnRules()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        model.learning.startMini(.pawnDuel,restart:true,computer:false,fromLibrary:true);game.refresh()
        let mini=try XCTUnwrap(model.learning.miniGame),moves=MiniGameRules.moves(board:mini.board,kind:mini.kind,side:mini.turn)
        let first=try XCTUnwrap(moves.first),reach=Set(moves.filter{$0.from==first.from}.map(\.to))
        let unreachable=try XCTUnwrap(ChessNotation.squares.first{!reach.contains($0) && mini.board[$0]==nil})
        XCTAssertNotNil(game.submitTypedMove(first.from+unreachable));XCTAssertEqual(model.learning.miniGame?.history.count,0,"a refused move changes nothing")
        XCTAssertNil(game.submitTypedMove(first.from+first.to));XCTAssertEqual(model.learning.miniGame?.history.count,1)
    }
    /// A learner playing Black against the computer types Black's moves on their own turn and is told to wait on White's.
    func testAMiniGameAsBlackTakesTypedMovesOnBlacksTurnOnly()async throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        model.session.state.settings.pieceDuration=0;model.session.state.settings.miniLearnerSides=["pawn-duel":"b"]
        model.learning.startMini(.pawnDuel,restart:true,computer:true,fromLibrary:true);game.refresh();XCTAssertEqual(model.learning.miniLearnerSide,"b","fixture: the learner plays Black")
        // White's turn with no reply in flight (a pause cancelled it): no move is the learner's, White's least of all.
        model.learning.pause();XCTAssertFalse(model.learning.miniThinking);XCTAssertEqual(model.learning.miniTurn,"w")
        let mini=try XCTUnwrap(model.learning.miniGame),white=try XCTUnwrap(MiniGameRules.moves(board:mini.board,kind:mini.kind,side:"w").first)
        XCTAssertEqual(game.submitTypedMove(white.from+white.to),"It's not your move yet.");XCTAssertEqual(model.learning.miniGame?.history.count,0)
        // The computer opens, and then Black's typed move is played.
        model.learning.restartMini();for _ in 0..<150 where model.learning.miniThinking{try await Task.sleep(for:.milliseconds(20))}
        XCTAssertEqual(model.learning.miniTurn,"b","the computer replied");game.refresh()
        let after=try XCTUnwrap(model.learning.miniGame),black=try XCTUnwrap(MiniGameRules.moves(board:after.board,kind:after.kind,side:"b").first)
        XCTAssertNil(game.submitTypedMove(black.from+black.to));XCTAssertEqual(model.learning.miniGame?.history.count,2);XCTAssertEqual(model.learning.miniGame?.board[black.to],"bp")
    }
    /// An en passant capture typed in SAN lands on an empty square: a training exercise and a lesson puzzle read it from
    /// the position's en passant square, not only from the pieces.
    func testAnEnPassantCaptureIsTypedInTrainingAndInAPuzzle()throws {
        setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1);defer{unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        model.startTraining("special-moves",variant:"en-passant-available");game.refresh()
        let exercise=try XCTUnwrap(model.training?.exercise),answer=try XCTUnwrap(exercise.scenario.nodes?.first?.accepted.first)
        let from=String(answer.prefix(2)),to=String(answer.dropFirst(2).prefix(2));XCTAssertNil(exercise.board[to],"fixture: the capture lands on an empty square")
        XCTAssertNil(game.submitTypedMove("\(from.first!)x\(to)"));XCTAssertEqual(model.training?.exercise?.status,.correct)
        model.puzzles();model.learning.openPuzzle(id:"course:promotion-en-passant:2");game.refresh()
        XCTAssertEqual(model.learning.exercise?.from,"d5");XCTAssertNil(model.learning.frame.board?["c6"],"fixture: the capture lands on an empty square")
        XCTAssertNil(game.submitTypedMove("dxc6"));XCTAssertTrue(model.learning.passed)
    }
    /// A puzzle holds only its board, not the move before it. An en passant capture that board allows is read and graded
    /// as clicking it is, a wrong answer here, even when the puzzle's answer is another move.
    func testAPuzzleGradesAnEnPassantCaptureThatIsNotItsAnswer()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let puzzle=try XCTUnwrap(model.learning.library.puzzles.first{$0.id=="course:rook:2"}),exercise=puzzle.exercise
        var board=try XCTUnwrap(puzzle.board);XCTAssertEqual(board[exercise.from ?? ""],"wr","fixture: White moves")
        board["b5"]="wp";board["a5"]="bp"  // as if Black's a-pawn had just come from a7
        func typed(_ text:String)->TypedMove.Resolution {TypedMove.resolve(text,moves:GameWindow.puzzleMoves(board:board,mover:"w"),board:board,turn:"w",enPassant:nil,inCheck:false,squaresAsTyped:true)}
        guard case .move(let choice)=typed("bxa6") else{return XCTFail("the capture is read, not refused")}
        XCTAssertEqual([choice.from,choice.to],["b5","a6"]);XCTAssertFalse(exercise.matches([choice.from,choice.to]),"and graded as a wrong answer, as clicking b5 then a6 is")
        // With no pawn beside it to capture, the pawn cannot go there, and the refusal says so.
        board["a5"]=nil;guard case .refused(let reason)=typed("bxa6") else{return XCTFail("nothing to capture")}
        XCTAssertEqual(reason,"A pawn cannot move from b5 to a6.")
    }
    func testReviewTakesNoTypedMove()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        model.openReview(try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]);game.refresh()
        XCTAssertFalse(game.typedMoveAvailable)
        XCTAssertEqual(game.submitTypedMove("Nf3"),"Typed moves work in a game, a lesson exercise or a training exercise.")
    }
}
