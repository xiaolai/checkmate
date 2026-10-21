import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
/// B-9: the practice move list opens a read-only view of an earlier position; any change to the game returns to the
/// live position, and the arrow keys step through the moves when the board and text fields do not want them.
@MainActor final class PracticeHistoryTests:XCTestCase {
    private func key(_ code:UInt16,_ flags:NSEvent.ModifierFlags=[.function,.numericPad])->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!}
    func testMoveListLabelsNumberEachMoveForItsSide()throws {
        let rules=try ChessRules();try rules.restore("1. e4 e5 2. Nf3 *")
        XCTAssertEqual(PracticeMoveList.labels(rules.records),["1. e4","1... e5","2. Nf3"])
        let black=try ChessRules();try black.load("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1");_=try black.move(uci:"e7e5")
        XCTAssertEqual(PracticeMoveList.labels(black.records),["1... e5"],"a game that starts with Black to move numbers from its own start")
    }
    func testAnEarlierPositionIsReadOnlyAndAnyChangeReturnsToTheGame()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        model.practice();model.session.newGame(side:"w");try model.session.rules.restore("1. e4 e5 2. Nf3 *");game.refresh()
        let live=game.board.position;XCTAssertEqual(live["f3"],"wn")
        XCTAssertNil(game.shownHistoryPly,"the live game shows no earlier position")
        // Choosing the first move shows the board after it, with that move marked, and nothing to play.
        game.showPracticeMove(0)
        XCTAssertEqual(game.shownHistoryPly,1);XCTAssertEqual(game.board.position["e4"],"wp");XCTAssertNil(game.board.position["e5"]);XCTAssertEqual(game.board.position["e7"],"bp")
        XCTAssertEqual(Set(game.board.highlights.filter{$0.kind=="last"}.map(\.sq)),["e2","e4"])
        XCTAssertTrue(game.board.destinations.isEmpty);XCTAssertNil(game.board.selected)
        game.select("g1");XCTAssertNil(model.session.selected,"a square cannot be chosen in an earlier position")
        XCTAssertFalse(game.dragMoves("g1"),"a piece cannot be dragged in an earlier position")
        XCTAssertEqual(model.session.rules.history,["e4","e5","Nf3"],"the game itself is unchanged")
        // Stepping: back to the start, never past it; forward to the live game.
        XCTAssertTrue(game.stepHistory(-1));XCTAssertEqual(game.shownHistoryPly,0);XCTAssertEqual(game.board.position["e2"],"wp")
        XCTAssertFalse(game.stepHistory(-1),"nothing before the start")
        XCTAssertTrue(game.stepHistory(1));XCTAssertTrue(game.stepHistory(1));XCTAssertTrue(game.stepHistory(1))
        XCTAssertNil(game.shownHistoryPly,"stepping past the last move is the live game");XCTAssertEqual(game.board.position,live)
        XCTAssertFalse(game.stepHistory(1),"nothing after the live game")
        // Choosing the last move is the live game.
        game.showPracticeMove(2);XCTAssertNil(game.shownHistoryPly)
        // A reply or any other change to the game returns to it.
        game.showPracticeMove(0);XCTAssertEqual(game.shownHistoryPly,1)
        try model.session.rules.restore("1. e4 e5 2. Nf3 Nc6 *");game.refresh()
        XCTAssertNil(game.shownHistoryPly,"a new move returns to the live position");XCTAssertEqual(game.board.position["c6"],"bn")
        // Back to Game closes it too.
        game.showPracticeMove(1);XCTAssertEqual(game.shownHistoryPly,2);game.history.close();game.refresh();XCTAssertNil(game.shownHistoryPly);XCTAssertEqual(game.board.position["c6"],"bn")
    }
    func testArrowKeysStepThroughMovesOnlyWhenNothingElseWantsThem(){
        func arrow(_ code:UInt16,flags:NSEvent.ModifierFlags=[.function,.numericPad],board:Bool=false,text:Bool=false,browsable:Bool=true)->Int? {GameWindow.historyArrow(keyCode:code,modifiers:flags,boardFocused:board,textFocused:text,browsable:browsable)}
        XCTAssertEqual(arrow(123),-1);XCTAssertEqual(arrow(124),1)
        XCTAssertNil(arrow(123,board:true),"the focused board explores squares with the arrows")
        XCTAssertNil(arrow(124,text:true),"a text field moves its caret")
        XCTAssertNil(arrow(123,browsable:false),"only a practice game with moves can be browsed")
        XCTAssertNil(arrow(125));XCTAssertNil(arrow(126),"up and down are not move steps")
        XCTAssertNil(arrow(123,flags:[.function,.numericPad,.command]),"a shortcut with a modifier is not a step")
        XCTAssertNil(arrow(124,flags:[.function,.numericPad,.option]))
    }
    func testTheWindowStepsWhenTheBoardDoesNotHaveFocus()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        model.practice();model.session.newGame(side:"w");try model.session.rules.restore("1. e4 e5 *");game.refresh()
        game.window?.makeFirstResponder(nil)
        game.window?.keyDown(with:key(123));XCTAssertEqual(game.shownHistoryPly,1,"Left Arrow steps back one move")
        game.window?.keyDown(with:key(124));XCTAssertNil(game.shownHistoryPly,"Right Arrow returns to the game")
        game.window?.makeFirstResponder(game.board);game.board.keyDown(with:key(123))
        XCTAssertNil(game.shownHistoryPly,"the focused board keeps the arrows for its squares")
    }
}
