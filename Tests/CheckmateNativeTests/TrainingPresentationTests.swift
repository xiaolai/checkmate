import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-004: what an exercise shows. The board carries the learner's own selection and the marked target only; marking
/// tasks are click-only; moves can be clicked or dragged through the board's own mouse handling.
@MainActor final class TrainingPresentationTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1);setenv("CHECKMATE_TRAINING_ENABLED","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");unsetenv("CHECKMATE_TRAINING_ENABLED");try? FileManager.default.removeItem(at:directory)}
    private func window(seed:UInt64=11)throws -> (NativeModel,GameWindow) {
        let model=try NativeModel(),game=GameWindow(model:model);var next=seed;model.training?.seed={next+=1;return next};return (model,game)
    }
    private func mouse(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent {NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
    /// A press, a drag and a release through the board's own handlers, in its coordinates.
    private func drag(_ board:BoardView,from:String,to:String){
        let a=board.squareRect(from),b=board.squareRect(to)
        board.mouseDown(with:mouse(.leftMouseDown,NSPoint(x:a.midX,y:a.midY)));board.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:b.midX,y:b.midY)));board.mouseUp(with:mouse(.leftMouseUp,NSPoint(x:b.midX,y:b.midY)))
    }
    private func click(_ board:BoardView,_ square:String){let a=board.squareRect(square),p=NSPoint(x:a.midX,y:a.midY);board.mouseDown(with:mouse(.leftMouseDown,p));board.mouseUp(with:mouse(.leftMouseUp,p))}
    func testRecognitionShowsNoAnswerAndIsClickOnly()throws {
        let (model,game)=try window();defer{game.window?.delegate=nil;model.shutdown()}
        game.board.frame=NSRect(x:0,y:0,width:640,height:640)
        model.startTraining("find-attackers");game.refresh()
        let exercise=try XCTUnwrap(model.training?.exercise),diagram=try XCTUnwrap(exercise.scenario.diagram),target=try XCTUnwrap(exercise.scenario.target)
        XCTAssertEqual(game.board.position,diagram);XCTAssertEqual(game.board.destinations,[]);XCTAssertEqual(game.board.attacked,[]);XCTAssertEqual(game.board.arrows,[])
        XCTAssertEqual(game.board.highlights.map(\.sq),[target],"only the marked square is shown before the learner answers")
        let piece=try XCTUnwrap(diagram.keys.first{$0 != target})
        XCTAssertFalse(game.board.canDrag?(piece) ?? true,"marking squares never drags a piece")
        click(game.board,piece);game.refresh()
        XCTAssertEqual(model.training?.exercise?.selection,[piece]);XCTAssertTrue(game.board.highlights.contains{$0.sq==piece && $0.kind=="answer"})
        XCTAssertFalse(model.training?.exercise?.finished ?? true,"a click selects; only Submit grades")
        click(game.board,piece);game.refresh();XCTAssertEqual(model.training?.exercise?.selection,[])
        model.training?.submit(none:true);game.refresh();XCTAssertTrue(model.training?.exercise?.finished ?? false)
        click(game.board,piece);XCTAssertEqual(model.training?.exercise?.selection,[],"a finished exercise takes no more input")
    }
    func testADrillMoveCanBeClickedOrDragged()throws {
        let (model,game)=try window();defer{game.window?.delegate=nil;model.shutdown()}
        game.board.frame=NSRect(x:0,y:0,width:640,height:640)
        model.startTraining("reach-target");game.refresh()
        let drill=try XCTUnwrap(model.training?.exercise?.scenario.drill)
        XCTAssertEqual(game.board.blackAtBottom,drill.color=="b","the learner's side sits nearest them")
        XCTAssertEqual(Set(game.board.highlights.map(\.sq)),[drill.target]);XCTAssertEqual(game.board.destinations,[],"no move dots give the route away")
        XCTAssertTrue(game.board.canDrag?(drill.start) ?? false)
        let moves=drill.moves(drill.initial).map(\.to).filter{$0 != drill.target}
        let first=try XCTUnwrap(moves.first)
        drag(game.board,from:drill.start,to:first);game.refresh()
        XCTAssertEqual(model.training?.exercise?.movesUsed,1,"a drag plays the move");XCTAssertEqual(game.board.position[first],drill.piece)
        let state=try XCTUnwrap(model.training?.exercise?.drillState),second=try XCTUnwrap(drill.moves(state).first?.to)
        click(game.board,first);click(game.board,second);game.refresh()
        XCTAssertEqual(model.training?.exercise?.movesUsed,2,"two clicks play the move");XCTAssertTrue(game.board.highlights.contains{$0.sq==second && $0.kind=="last"})
    }
    func testMateInOneByDragAndHonestResultLabels()throws {
        let (model,game)=try window();defer{game.window?.delegate=nil;model.shutdown()}
        game.board.frame=NSRect(x:0,y:0,width:640,height:640)
        model.startTraining("mate-in-one");game.refresh()
        let scenario=try XCTUnwrap(model.training?.exercise?.scenario),answer=try XCTUnwrap(scenario.expected?.moves?.first)
        let from=String(answer.prefix(2)),to=String(answer.dropFirst(2).prefix(2))
        XCTAssertEqual(game.board.blackAtBottom,scenario.learner=="b")
        XCTAssertFalse(game.board.canDrag?(scenario.learner=="w" ? (game.board.position.first{$0.value.first=="b"}?.key ?? "a1"):(game.board.position.first{$0.value.first=="w"}?.key ?? "a1")) ?? true,"only the learner's pieces drag")
        drag(game.board,from:from,to:to);game.refresh()
        if answer.count==5 {model.training?.attempt(from:from,to:to,promotion:String(answer.last!))}
        let exercise=try XCTUnwrap(model.training?.exercise)
        XCTAssertEqual(exercise.status,.correct);XCTAssertEqual(TrainingPanel.resultLabel(exercise),"Solved · first try · no recorded help")
        model.training?.retry();model.training?.hint();model.training?.attempt(from:from,to:to,promotion:answer.count==5 ? String(answer.last!):nil)
        XCTAssertEqual(TrainingPanel.resultLabel(try XCTUnwrap(model.training?.exercise)),"Solved with recorded help")
        model.training?.next();model.training?.reveal()
        XCTAssertEqual(TrainingPanel.resultLabel(try XCTUnwrap(model.training?.exercise)),"Answer shown")
    }
    /// The panel names the opponent the review names (`boundOpponent`), not the raw saved one: a game an older build
    /// continued is marked mixed, and another attempt's configuration is not named at all.
    func testThePanelNamesTheOpponentTheReviewNames(){
        let scenario=TrainingScenario(id:"s",entry:"cut-down-chess",variant:"krk",tier:1,cluster:"c",learner:"w",prompt:"p",explanation:"e",hints:["h"],fen:"8/8/8/8/K7/3R4/8/k7 w - - 0 1",check:.ending)
        var snapshot=TrainingSessionSnapshot(id:"mine",entry:"cut-down-chess",scenario:scenario,freshness:"new",revision:4,startedAt:Date(),opponent:.frozen(.gentle,attempt:"mine",seed:7,revision:4))
        XCTAssertEqual(TrainingPanel.opponentLine(snapshot),"Opponent: Gentle")
        snapshot.revision=7
        XCTAssertEqual(TrainingPanel.opponentLine(snapshot),"Opponent: Gentle, mixed: an older version of Checkmate played part of this game","an older build continued it")
        XCTAssertEqual(TrainingPanel.opponentLine(snapshot),snapshot.boundOpponent.map{"Opponent: "+$0.label},"the review's label")
        snapshot.opponent?.attempt="theirs";XCTAssertNil(TrainingPanel.opponentLine(snapshot),"another attempt's configuration is not named")
        snapshot.opponent=nil;XCTAssertNil(TrainingPanel.opponentLine(snapshot))
    }
    func testAHintShowsItsSquaresOnlyAfterItIsAsked()throws {
        let (model,game)=try window();defer{game.window?.delegate=nil;model.shutdown()}
        model.startTraining("mate-in-one");game.refresh()
        XCTAssertFalse(game.board.highlights.contains{$0.kind=="hint"})
        model.training?.hint();model.training?.hint();game.refresh()
        XCTAssertTrue(game.board.highlights.contains{$0.kind=="hint"},"the second hint level points at the mating piece")
        XCTAssertEqual(model.session.training?.assisted,true)
    }
    /// The library host fills the board area whether or not training is enabled: an empty hosting view once broke the
    /// window's square layout by pinning itself to zero size.
    func testTheLibraryFillsTheBoardAreaWithTrainingOnOrOff()throws {
        for enabled in [false,true] {
            if enabled{setenv("CHECKMATE_TRAINING_ENABLED","1",1)}else{unsetenv("CHECKMATE_TRAINING_ENABLED")}
            let (model,game)=try window();defer{game.window?.delegate=nil;model.shutdown()}
            game.window?.contentView?.layoutSubtreeIfNeeded()
            let board=game.board.frame,library=game.trainingLibraryView.frame
            XCTAssertGreaterThan(board.width,0);XCTAssertEqual(library.size,board.size,"training enabled: \(enabled)")
            if enabled{model.trainingLibrary();game.refresh();game.window?.contentView?.layoutSubtreeIfNeeded();XCTAssertEqual(game.trainingLibraryView.frame.size,board.size);XCTAssertFalse(game.trainingLibraryView.isHidden)}
        }
    }
}
