import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-010: a pawn reaching the last rank through the board's own mouse handling opens the chooser; cancelling it
/// changes nothing and counts nothing; every promotion piece is a legal answer.
@MainActor final class TrainingPromotionTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1);setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B");try? FileManager.default.removeItem(at:directory)}
    private func mouse(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent {NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
    private func drag(_ board:BoardView,from:String,to:String){
        let a=board.squareRect(from),b=board.squareRect(to)
        board.mouseDown(with:mouse(.leftMouseDown,NSPoint(x:a.midX,y:a.midY)));board.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:b.midX,y:b.midY)));board.mouseUp(with:mouse(.leftMouseUp,NSPoint(x:b.midX,y:b.midY)))
    }
    func testThePromotionChooserCanBeCancelledAndEveryPieceIsAccepted()throws {
        for piece in ["q","r","b","n"] {
            let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
            var next=UInt64(piece.unicodeScalars.first!.value);model.training?.seed={next+=1;return next}
            game.board.frame=NSRect(x:0,y:0,width:640,height:640)
            model.startTraining("special-moves",variant:"promotion");game.refresh()
            let exercise=try XCTUnwrap(model.training?.exercise),move=try XCTUnwrap(exercise.scenario.nodes?.first?.accepted.first{$0.count==5})
            let from=String(move.prefix(2)),to=String(move.dropFirst(2).prefix(2)),pawn=exercise.scenario.learner+"p"
            XCTAssertEqual(game.board.position[from],pawn)
            drag(game.board,from:from,to:to);game.refresh()
            XCTAssertNotNil(model.training?.exercise?.pendingPromotion,"reaching the last rank asks which piece")
            XCTAssertEqual(game.board.position[from],pawn,"nothing moves until a piece is chosen")
            model.training?.cancelPromotion();game.refresh()
            XCTAssertNil(model.training?.exercise?.pendingPromotion);XCTAssertEqual(model.training?.exercise?.snapshot.actions,[],"cancelling is not an answer")
            XCTAssertFalse(model.training?.exercise?.finished ?? true);XCTAssertEqual(game.board.position[from],pawn)
            drag(game.board,from:from,to:to);model.training?.attempt(from:from,to:to,promotion:piece);game.refresh()
            XCTAssertEqual(model.training?.exercise?.status,.correct,"promoting to \(piece) is legal and counts")
            XCTAssertEqual(game.board.position[to],exercise.scenario.learner+piece)
        }
    }
}
