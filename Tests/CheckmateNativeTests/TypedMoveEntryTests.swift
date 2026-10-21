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
        if model.session.rules.turn=="b"{XCTAssertEqual(game.submitTypedMove("Nf3"),"It's not your move yet.")}
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
    func testReviewTakesNoTypedMove()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{model.session.cancelWork();game.window?.delegate=nil;model.shutdown()}
        model.openReview(try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]);game.refresh()
        XCTAssertFalse(game.typedMoveAvailable)
        XCTAssertEqual(game.submitTypedMove("Nf3"),"Typed moves work in a game, a lesson exercise or a training exercise.")
    }
}
