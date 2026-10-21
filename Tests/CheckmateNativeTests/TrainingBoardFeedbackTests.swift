import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// A training exercise's board behaves as practice's: its moves animate and are announced, its feedback and hints open
/// the details drawer that shows them, and the bar carries the latest feedback line.
@MainActor final class TrainingBoardFeedbackTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1);setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B");try? FileManager.default.removeItem(at:directory)}
    private func open(_ model:NativeModel,_ game:GameWindow){
        var next:UInt64=11;model.training?.seed={next+=1;return next}
        game.board.frame=NSRect(x:0,y:0,width:640,height:640)
        model.startTraining("special-moves",variant:"promotion");game.refresh()
    }
    private func settle(){RunLoop.main.run(until:Date().addingTimeInterval(0.05))}
    func testAClickedTrainingMoveAnimatesAndIsAnnounced()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.board.cancelAnimation();game.window?.delegate=nil;model.shutdown()}
        open(model,game);game.board.automationReduceMotion=false
        var landed:[MoveRecord]=[];let window=model.training?.onMove;model.training?.onMove={window?($0);landed.append($0)}
        let exercise=try XCTUnwrap(model.training?.exercise),move=try XCTUnwrap(exercise.scenario.nodes?.first?.accepted.first{$0.count==5})
        game.presentPromotionMenu={[weak game] menu,_,_ in guard let item=menu.items.first(where:{($0.representedObject as? GameWindow.TrainingPromotion)?.piece==String(move.suffix(1))}) else{return false};game?.promoteTraining(item);return true}
        game.select(String(move.prefix(2)));game.select(String(move.dropFirst(2).prefix(2)))
        let played=try XCTUnwrap(landed.first)
        XCTAssertEqual(played.uci,move)
        XCTAssertTrue(game.board.moveAnimationActive,"a clicked training move animates from the board shown")
        let check=played.san.hasSuffix("#") ? " Checkmate.":played.san.hasSuffix("+") ? " Check.":""
        XCTAssertEqual(game.trainingAnnouncement(for:played),"You played \(played.san).\(check)")
    }
    func testTheAnnouncementNamesWhoMovedAndTheCheck()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        open(model,game)
        let learner=try XCTUnwrap(model.training?.exercise?.scenario.learner),other=learner=="w" ? "b":"w"
        func record(_ color:String,_ san:String)->MoveRecord {MoveRecord(color:color,from:"e2",to:"e4",piece:"q",flags:"n",san:san,before:"",after:"",captured:nil,promotion:nil)}
        XCTAssertEqual(game.trainingAnnouncement(for:record(learner,"Qe4")),"You played Qe4.")
        XCTAssertEqual(game.trainingAnnouncement(for:record(learner,"Qe4+")),"You played Qe4+. Check.")
        XCTAssertEqual(game.trainingAnnouncement(for:record(learner,"Qe4#")),"You played Qe4#. Checkmate.")
        XCTAssertEqual(game.trainingAnnouncement(for:record(other,"Qe4+")),"The opponent played Qe4+. Your king is in check.")
        XCTAssertEqual(game.trainingAnnouncement(for:record(other,"Qe4#")),"The opponent played Qe4#. Checkmate.")
    }
    func testFeedbackAndHintsOpenTheDrawerAndTheBarShowsTheLatestLine()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        open(model,game);settle()
        let exercise=try XCTUnwrap(model.training?.exercise),learner=exercise.scenario.learner
        let bar={ControlBarModel.make(session:model.session,learning:model.learning,review:model.review,training:model.training,network:model.network,voice:.off(unavailable:nil))}
        XCTAssertEqual(bar().status,.turn(side:learner,label:learner=="w" ? "You are White":"You are Black"),"no feedback yet: the bar says whose side the learner plays")
        game.desiredRight=false
        let theirs=try XCTUnwrap(exercise.board.first{!$0.value.hasPrefix(learner)}?.key)
        game.select(theirs);settle()
        let feedback=try XCTUnwrap(model.training?.exercise?.feedback);XCTAssertFalse(feedback.isEmpty)
        XCTAssertTrue(game.desiredRight,"training feedback opens the drawer, as puzzle feedback does")
        XCTAssertEqual(bar().status,.text(feedback),"the bar carries the latest feedback line");XCTAssertFalse(bar().statusInCentre,"a feedback line may be long, so it truncates at the leading edge")
        game.desiredRight=false
        XCTAssertTrue(model.training?.hint() ?? false);settle()
        XCTAssertNotNil(model.training?.exercise?.hintText)
        XCTAssertTrue(game.desiredRight,"a hint opens the drawer that shows it")
    }
}
