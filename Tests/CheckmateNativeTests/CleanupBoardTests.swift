import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// #40: a move animation is bound to the exact boards on either side of its move and only moves forward, so a replaced
/// board cancels it even when the replacement holds a same-coloured piece on the destination or is the board before it.
@MainActor final class CleanupBoardAnimationTests:XCTestCase {
    private func board(showing position:Position)->BoardView {
        let board=BoardView(frame:NSRect(x:0,y:0,width:640,height:640));board.automationReduceMotion=false;board.position=position;return board
    }
    private func landing(_ move:MoveRecord)throws -> Position {try XCTUnwrap(TrainingMaterial.board(fen:move.after))}

    func testAReplacementBoardWithASameColouredPieceOnTheDestinationCancelsTheAnimation()throws {
        let rules=try ChessRules(),start=rules.board,move=try XCTUnwrap(rules.moves("e2").first{$0.to=="e4"})
        let view=board(showing:start);defer{view.cancelAnimation()}
        view.animate(move,duration:10)
        XCTAssertTrue(view.moveAnimationActive,"the move starts from the board shown")
        view.position=try landing(move)
        XCTAssertTrue(view.moveAnimationActive,"the board the move lands on keeps its animation")
        var replacement=try landing(move);replacement["a2"]=nil;replacement["a3"]="wp"
        XCTAssertEqual(replacement["e4"]?.first,"w","the replacement holds a white piece on the destination, the case that used to survive")
        view.position=replacement
        XCTAssertFalse(view.moveAnimationActive,"a board the move does not land on cancels the animation")
        XCTAssertNil(view.transition)
    }

    func testAReplacementBeforeTheBoardLandsAlsoCancels()throws {
        let rules=try ChessRules(),start=rules.board,move=try XCTUnwrap(rules.moves("g1").first{$0.to=="f3"})
        let view=board(showing:start);defer{view.cancelAnimation()}
        view.animate(move,duration:10);XCTAssertTrue(view.moveAnimationActive)
        var hypothetical=try landing(move);hypothetical["b1"]=nil;hypothetical["c3"]="wn"
        view.position=hypothetical
        XCTAssertFalse(view.moveAnimationActive,"a hypothetical board shown before the move lands is not this transition")
    }

    func testAMoveThatDoesNotBelongToTheShownBoardIsNotAnimated()throws {
        let rules=try ChessRules(),move=try XCTUnwrap(rules.moves("e2").first{$0.to=="e4"})
        let other=try ChessRules();try other.restore("1. d4 d5 2. c4 *")
        let view=board(showing:other.board);defer{view.cancelAnimation()}
        view.animate(move,duration:10)
        XCTAssertFalse(view.moveAnimationActive,"an animation never draws a move over a board it does not belong to")
        XCTAssertNil(view.transition)
    }

    func testTheAnimationMayStartAfterTheBoardHasLanded()throws {
        let rules=try ChessRules(),move=try XCTUnwrap(rules.moves("e2").first{$0.to=="e4"})
        let view=board(showing:try landing(move));defer{view.cancelAnimation()}
        view.animate(move,duration:10)
        XCTAssertTrue(view.moveAnimationActive)
        XCTAssertEqual(view.transition?.before,try ChessRules().board,"the board before the move is derived from the landing board")
    }

    /// The transition only moves forward: once the board has landed, showing the board before the move again (an undo,
    /// or another presentation of that position) is a different board and cancels the animation.
    func testShowingTheBoardBeforeTheMoveAfterItLandedCancels()throws {
        let rules=try ChessRules(),start=rules.board,move=try XCTUnwrap(rules.moves("e2").first{$0.to=="e4"})
        let view=board(showing:start);defer{view.cancelAnimation()}
        view.animate(move,duration:10);XCTAssertEqual(view.transition?.phase,.awaitingLanding)
        view.position=try landing(move);XCTAssertEqual(view.transition?.phase,.landed)
        view.position=start
        XCTAssertFalse(view.moveAnimationActive,"the board before the move, shown after it landed, is not this transition")
        XCTAssertNil(view.transition)
    }

    func testAnAnimationStartedOverTheLandedBoardIsCancelledByTheBoardBeforeIt()throws {
        let rules=try ChessRules(),start=rules.board,move=try XCTUnwrap(rules.moves("e2").first{$0.to=="e4"})
        let view=board(showing:try landing(move));defer{view.cancelAnimation()}
        view.animate(move,duration:10);XCTAssertEqual(view.transition?.phase,.landed)
        view.position=start
        XCTAssertFalse(view.moveAnimationActive,"an animation that started landed never returns to the board before the move")
    }

    func testTheBoardBeforeTheMoveThenTheLandingBoardKeepsTheAnimation()throws {
        let rules=try ChessRules(),start=rules.board,move=try XCTUnwrap(rules.moves("e2").first{$0.to=="e4"})
        let view=board(showing:start);defer{view.cancelAnimation()}
        view.animate(move,duration:10)
        XCTAssertTrue(view.moveAnimationActive,"the animation starts over the board before the move, which is applied afterwards")
        view.position=start;XCTAssertTrue(view.moveAnimationActive,"re-showing the same board is no change")
        view.position=try landing(move)
        XCTAssertTrue(view.moveAnimationActive);XCTAssertEqual(view.transition?.phase,.landed)
    }

    func testAnotherSourceWithTheSamePiecesCancels()throws {
        let rules=try ChessRules(),start=rules.board,move=try XCTUnwrap(rules.moves("e2").first{$0.to=="e4"})
        let view=board(showing:start);defer{view.cancelAnimation()};view.displaySource="review"
        view.animate(move,duration:10);view.position=try landing(move);XCTAssertTrue(view.moveAnimationActive)
        view.displaySource="review";XCTAssertTrue(view.moveAnimationActive,"the same source keeps its animation")
        view.displaySource="review_preview"
        XCTAssertFalse(view.moveAnimationActive,"a preview showing the same pieces is another display");XCTAssertNil(view.transition)
    }
    func testTheLandingBoardThenAThirdBoardCancels()throws {
        let rules=try ChessRules(),start=rules.board,move=try XCTUnwrap(rules.moves("e2").first{$0.to=="e4"})
        let view=board(showing:start);defer{view.cancelAnimation()}
        view.animate(move,duration:10);view.position=try landing(move);XCTAssertTrue(view.moveAnimationActive)
        try rules.move("e2","e4");try rules.move("e7","e5")
        view.position=rules.board
        XCTAssertFalse(view.moveAnimationActive,"a later board is a different transition")
        XCTAssertNil(view.transition)
    }

    /// The derived board before the move undoes the rook of a castle and restores an en passant capture.
    func testSpecialMovesDeriveTheBoardBeforeTheMove()throws {
        for (pgn,from,to) in [("1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 *","e1","g1"),("1. e4 a6 2. e5 d5 *","e5","d6"),("1. e4 d5 2. exd5 c6 3. dxc6 Nf6 4. cxb7 Nbd7 *","b7","a8")] {
            let rules=try ChessRules();try rules.restore(pgn);let before=rules.board
            let move=try rules.move(from,to,"q")
            let view=board(showing:before);defer{view.cancelAnimation()}
            view.animate(move,duration:10)
            XCTAssertTrue(view.moveAnimationActive,"\(move.san) animates from the board before it")
            XCTAssertEqual(view.transition?.before,before,move.san);XCTAssertEqual(view.transition?.landing,rules.board,move.san)
        }
    }

    /// Mini-game moves carry no FEN: the caller names the landing board, and without one nothing is animated.
    func testAMiniGameMoveUsesItsExplicitLandingBoard()throws {
        let before:Position=["a2":"wp","b7":"bp"],landing:Position=["a3":"wp","b7":"bp"]
        let move=MoveRecord(color:"w",from:"a2",to:"a3",piece:"p",flags:"n",san:"a2–a3",before:"",after:"",captured:nil,promotion:nil)
        let view=board(showing:before);defer{view.cancelAnimation()}
        view.animate(move,duration:10)
        XCTAssertFalse(view.moveAnimationActive,"a move with no known landing board is not animated")
        view.animate(move,landing:landing,duration:10)
        XCTAssertTrue(view.moveAnimationActive)
        view.position=landing;XCTAssertTrue(view.moveAnimationActive)
        view.position=["a3":"wp","b6":"bp"];XCTAssertFalse(view.moveAnimationActive,"a replaced mini-game board cancels the animation")
    }
}

/// #47: a practice promotion chosen from the menu applies only to the exact game position the menu was opened over.
@MainActor final class CleanupPracticePromotionTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    /// White to move with a pawn on b7 that can promote on b8.
    private let line="1. e4 d5 2. exd5 c6 3. dxc6 Nf6 4. cxb7 Nbd7 *"
    private func choice(_ promotion:GameWindow.PracticePromotion)->NSMenuItem {let item=NSMenuItem(title:"Knight",action:#selector(GameWindow.promote(_:)),keyEquivalent:"");item.representedObject=promotion;return item}

    func testANewGameWithTheSamePiecesEndsTheAnimation()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        model.practice();model.session.newGame(side:"w");game.refresh()
        let start=try ChessRules(),move=try XCTUnwrap(start.moves("e2").first{$0.to=="e4"})
        game.board.animate(move,duration:10);XCTAssertTrue(game.board.moveAnimationActive,"fixture: the move animates over the start position")
        game.refresh();XCTAssertTrue(game.board.moveAnimationActive,"the same game keeps its animation")
        model.session.newGame(side:"w");game.refresh()
        XCTAssertEqual(game.board.position,start.board,"fixture: the new game shows the same pieces")
        XCTAssertFalse(game.board.moveAnimationActive,"a new game is another display, even from identical pieces")
    }

    func testAnIdenticalPositionInAReplacementGameRefusesThePromotion()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        model.practice();model.session.newGame(side:"w");try model.session.rules.restore(line);game.refresh()
        let shown=game.practiceGame,fen=model.session.rules.fen
        // An agent replaces the game while the menu is open and reaches the very same position.
        model.session.newGame(side:"w");try model.session.rules.restore(line);game.refresh()
        XCTAssertEqual(model.session.rules.fen,fen);XCTAssertEqual(game.practiceGame.history,shown.history);XCTAssertNotEqual(game.practiceGame.generation,shown.generation)
        game.promote(choice(.init(from:"b7",to:"b8",piece:"n",game:shown)))
        XCTAssertEqual(model.session.rules.history,shown.history,"the old menu's choice must not play in the replacement game")
        game.promote(choice(.init(from:"b7",to:"b8",piece:"n",game:game.practiceGame)))
        XCTAssertEqual(model.session.rules.history.last,"b8=N","a menu opened over the current game still promotes")
    }

    func testAMovePlayedInTheSameGameRefusesThePromotion()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        model.practice();model.session.newGame(side:"w");try model.session.rules.restore(line);game.refresh()
        let shown=game.practiceGame
        try model.session.rules.restore("1. e4 d5 2. exd5 c6 3. dxc6 Nf6 4. cxb7 Nbd7 5. a3 a6 *");game.refresh()
        XCTAssertEqual(game.practiceGame.generation,shown.generation)
        game.promote(choice(.init(from:"b7",to:"b8",piece:"n",game:shown)))
        XCTAssertEqual(model.session.rules.history.count,shown.history.count+2,"a choice made over an earlier position of the game is not applied")
    }

    /// A move and its undo restore the very same history, but not the same position: the session's position counter moved.
    func testAMoveAndItsUndoRefuseTheOldPromotion()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        model.practice();model.session.newGame(side:"w");try model.session.rules.restore(line);game.refresh()
        let shown=game.practiceGame
        try model.session.playWhite(from:"a2",to:"a3");model.session.undo();game.refresh()
        XCTAssertEqual(game.practiceGame.generation,shown.generation);XCTAssertEqual(game.practiceGame.history,shown.history,"the undo restores the history the menu was opened over")
        XCTAssertNotEqual(game.practiceGame.position,shown.position)
        game.promote(choice(.init(from:"b7",to:"b8",piece:"n",game:shown)))
        XCTAssertEqual(model.session.rules.history,shown.history,"the old menu's choice is refused after a move and its undo")
        game.promote(choice(.init(from:"b7",to:"b8",piece:"n",game:game.practiceGame)))
        XCTAssertEqual(model.session.rules.history.last,"b8=N","a menu opened over the current position still promotes")
    }
}
