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
    override func setUpWithError()throws{try isolateDataDirectory(["CHECKMATE_TRAINING_ENABLED":"1","CHECKMATE_TRAINING_B":"1"])}
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
            game.board.drag(from:from,to:to);game.refresh()
            XCTAssertEqual(shown.last?.items.map(\.title),["Queen","Rook","Bishop","Knight"],"reaching the last rank opens the board's promotion menu")
            XCTAssertEqual(shown.last?.items.map(\.keyEquivalent),["q","r","b","n"],"B-13: each piece has its key");XCTAssertTrue(shown.last?.items.allSatisfy{$0.keyEquivalentModifierMask.isEmpty} ?? false,"the key alone chooses")
            XCTAssertNil(model.training?.exercise?.pendingPromotion,"closing the menu cancels the promotion")
            XCTAssertEqual(model.training?.exercise?.feedback,"Promotion canceled. Nothing was counted.")
            XCTAssertEqual(model.training?.exercise?.snapshot.actions,[],"cancelling is not an answer")
            XCTAssertFalse(model.training?.exercise?.finished ?? true);XCTAssertEqual(game.board.position[from],pawn)
            // A choice from a menu that has since closed is stale and does nothing.
            let stale=try XCTUnwrap(shown.last?.items.first{($0.representedObject as? GameWindow.TrainingPromotion)?.piece==piece})
            game.promoteTraining(stale)
            XCTAssertEqual(model.training?.exercise?.snapshot.actions,[],"a closed menu's choice is ignored")
            // The menu is answered: the chosen piece is the attempt's promotion.
            game.presentPromotionMenu={[weak game] menu,_,_ in shown.append(menu);guard let item=menu.items.first(where:{($0.representedObject as? GameWindow.TrainingPromotion)?.piece==piece}) else{return false};game?.promoteTraining(item);return true}
            game.board.drag(from:from,to:to);game.refresh()
            XCTAssertEqual(model.training?.exercise?.status,.correct,"promoting to \(piece) is legal and counts")
            XCTAssertEqual(game.board.position[to],exercise.scenario.learner+piece)
        }
    }
}
