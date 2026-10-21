import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-010: a pawn reaching the last rank through the board's own mouse handling opens the board's promotion menu, as
/// practice does; closing it changes nothing and counts nothing; every promotion piece is a legal answer.
@MainActor final class TrainingPromotionTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1);setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B");try? FileManager.default.removeItem(at:directory)}
    private func mouse(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent {NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
    private func drag(_ board:BoardView,from:String,to:String){
        let a=board.squareRect(from),b=board.squareRect(to)
        board.mouseDown(with:mouse(.leftMouseDown,NSPoint(x:a.midX,y:a.midY)));board.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:b.midX,y:b.midY)));board.mouseUp(with:mouse(.leftMouseUp,NSPoint(x:b.midX,y:b.midY)))
    }
    func testTheBoardMenuPromotesAndClosingItCountsNothing()throws {
        for piece in ["q","r","b","n"] {
            let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
            var next=UInt64(piece.unicodeScalars.first!.value);model.training?.seed={next+=1;return next}
            game.board.frame=NSRect(x:0,y:0,width:640,height:640)
            model.startTraining("special-moves",variant:"promotion");game.refresh()
            let exercise=try XCTUnwrap(model.training?.exercise),move=try XCTUnwrap(exercise.scenario.nodes?.first?.accepted.first{$0.count==5})
            let from=String(move.prefix(2)),to=String(move.dropFirst(2).prefix(2)),pawn=exercise.scenario.learner+"p"
            XCTAssertEqual(game.board.position[from],pawn)
            // The menu is closed without a choice: the window cancels the pending promotion itself.
            var shown:[NSMenu]=[];game.presentPromotionMenu={menu,_,_ in shown.append(menu);return false}
            drag(game.board,from:from,to:to);game.refresh()
            XCTAssertEqual(shown.last?.items.map(\.title),["Queen","Rook","Bishop","Knight"],"reaching the last rank opens the board's promotion menu")
            XCTAssertNil(model.training?.exercise?.pendingPromotion,"closing the menu cancels the promotion")
            XCTAssertEqual(model.training?.exercise?.feedback,"Promotion cancelled. Nothing was counted.")
            XCTAssertEqual(model.training?.exercise?.snapshot.actions,[],"cancelling is not an answer")
            XCTAssertFalse(model.training?.exercise?.finished ?? true);XCTAssertEqual(game.board.position[from],pawn)
            // A choice from a menu that has since closed is stale and does nothing.
            let stale=try XCTUnwrap(shown.last?.items.first{($0.representedObject as? GameWindow.TrainingPromotion)?.piece==piece})
            game.promoteTraining(stale)
            XCTAssertEqual(model.training?.exercise?.snapshot.actions,[],"a closed menu's choice is ignored")
            // The menu is answered: the chosen piece is the attempt's promotion.
            game.presentPromotionMenu={[weak game] menu,_,_ in shown.append(menu);guard let item=menu.items.first(where:{($0.representedObject as? GameWindow.TrainingPromotion)?.piece==piece}) else{return false};game?.promoteTraining(item);return true}
            drag(game.board,from:from,to:to);game.refresh()
            XCTAssertEqual(model.training?.exercise?.status,.correct,"promoting to \(piece) is legal and counts")
            XCTAssertEqual(game.board.position[to],exercise.scenario.learner+piece)
        }
    }
}
