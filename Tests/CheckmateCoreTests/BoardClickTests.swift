import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore

/// Clicks on a legal square must never be lost: drift across a square edge, a first click on an inactive
/// window and a presentation opened between two clicks all used to drop the move silently.
final class BoardClickTests:XCTestCase {
    private func board()->BoardView {let b=BoardView(frame:NSRect(x:0,y:0,width:720,height:720));b.position=["e2":"wp"];b.canDrag={$0=="e2"};return b}
    private func mouse(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent {NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!}

    func testClickDriftingAcrossASquareEdgeActivatesThePressedSquare(){
        let b=board();var activated:[String]=[];b.activate={activated.append($0)}
        let e4=b.squareRect("e4"),press=NSPoint(x:e4.midX,y:e4.maxY-2),release=NSPoint(x:e4.midX,y:e4.maxY+6)
        XCTAssertEqual(b.square(at:release),"e5")
        b.mouseDown(with:mouse(.leftMouseDown,press));b.mouseDragged(with:mouse(.leftMouseDragged,release));b.mouseUp(with:mouse(.leftMouseUp,release))
        XCTAssertEqual(activated,["e4"])
    }
    func testReleaseOutsideTheBoardCancelsTheClick(){
        let b=board();var activated:[String]=[];b.activate={activated.append($0)}
        let e1=b.squareRect("e1"),press=NSPoint(x:e1.midX,y:e1.midY),release=NSPoint(x:e1.midX,y:b.boardRect.minY-10)
        b.mouseDown(with:mouse(.leftMouseDown,press));b.mouseDragged(with:mouse(.leftMouseDragged,release));b.mouseUp(with:mouse(.leftMouseUp,release))
        XCTAssertEqual(activated,[])
    }
    func testDragOfOwnPieceStillDropsOnAPlayableDestination(){
        let b=board();var activated:[String]=[];b.activate={sq in activated.append(sq);if sq=="e2"{b.selected="e2";b.destinations=["e3","e4"]}}
        let from=b.squareRect("e2"),to=b.squareRect("e4")
        b.mouseDown(with:mouse(.leftMouseDown,NSPoint(x:from.midX,y:from.midY)));b.mouseDragged(with:mouse(.leftMouseDragged,NSPoint(x:to.midX,y:to.midY)))
        XCTAssertTrue(b.dragging);XCTAssertTrue(b.cursor(at:NSPoint(x:to.midX,y:to.midY)) === NSCursor.closedHand)
        b.mouseUp(with:mouse(.leftMouseUp,NSPoint(x:to.midX,y:to.midY)))
        XCTAssertEqual(activated,["e2","e4"]);XCTAssertFalse(b.dragging)
    }
    func testFirstClickOnAnInactiveWindowReachesTheBoard(){XCTAssertTrue(board().acceptsFirstMouse(for:nil))}
    func testOpenHandShowsOnlyOverDraggablePieces(){
        let b=board();b.position["e7"]="bp";func at(_ sq:String)->NSCursor {let r=b.squareRect(sq);return b.cursor(at:NSPoint(x:r.midX,y:r.midY))}
        XCTAssertTrue(at("e2") === NSCursor.openHand);XCTAssertTrue(at("e7") === NSCursor.arrow);XCTAssertTrue(at("e4") === NSCursor.arrow)
    }

    @MainActor func testDemonstrationKeepsTheLearnersSelectionForTheGame()throws {
        let s=try GameSession(engine:nil);try s.select("e2");XCTAssertEqual(s.selected,"e2")
        try s.demonstrate(title:"Imagine",introduction:"",lines:[DemoLineInput(label:"Pawn",moves:[DemoStepInput(uci:"d2d4")])])
        XCTAssertNil(s.selected)
        s.selectPresentation(false)
        XCTAssertEqual(s.selected,"e2");XCTAssertEqual(s.inspection?.legalNow,true)
        try s.select("e4");XCTAssertEqual(s.rules.history.count,1)
    }
    @MainActor func testClosedPreviewRestoresTheLearnersSelection()throws {
        let s=try GameSession(engine:nil);try s.select("g1");try s.beginPreview();XCTAssertNil(s.selected)
        s.closePresentation();XCTAssertEqual(s.selected,"g1");try s.select("f3");XCTAssertEqual(s.rules.history.count,1)
    }
    @MainActor func testChangedPositionDiscardsAStashedSelection()throws {
        let s=try GameSession(engine:nil);try s.select("e2")
        try s.demonstrate(title:"Imagine",introduction:"",lines:[DemoLineInput(label:"Pawn",moves:[DemoStepInput(uci:"d2d4")])])
        let position=s.positionId;s.newGame();XCTAssertNotEqual(s.positionId,position,"The position really changed");XCTAssertNil(s.demonstration)
        s.closePresentation();s.selectPresentation(false)
        XCTAssertNil(s.selected)
    }
}
