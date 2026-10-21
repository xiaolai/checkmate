import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore

/// The learner's own arrows and circles (B-11): a right-drag draws an arrow, a right-click a circle, modifiers pick the
/// colour as on Lichess, and a move clears them. They never reach the board's left-click and drag play.
final class BoardSketchTests:XCTestCase {
    private func board()->BoardView {let b=BoardView(frame:NSRect(x:0,y:0,width:720,height:720));b.position=["e2":"wp","e7":"bp"];b.canDrag={$0=="e2"};return b}
    private func mouse(_ type:NSEvent.EventType,_ point:NSPoint,_ modifiers:NSEvent.ModifierFlags=[])->NSEvent {NSEvent.mouseEvent(with:type,location:point,modifierFlags:modifiers,timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
    private func centre(_ b:BoardView,_ sq:String)->NSPoint {let r=b.squareRect(sq);return NSPoint(x:r.midX,y:r.midY)}
    private func rightDrag(_ b:BoardView,_ from:String,_ to:String,_ modifiers:NSEvent.ModifierFlags=[]){
        b.rightMouseDown(with:mouse(.rightMouseDown,centre(b,from),modifiers));if from != to{b.rightMouseDragged(with:mouse(.rightMouseDragged,centre(b,to),modifiers))};b.rightMouseUp(with:mouse(.rightMouseUp,centre(b,to),modifiers))
    }

    func testARightDragDrawsAnArrowAndARightClickACircle(){
        let b=board();rightDrag(b,"e2","e4");rightDrag(b,"d5","d5")
        XCTAssertEqual(b.sketch.marks,[BoardSketch.Mark(from:"e2",to:"e4",brush:.green),BoardSketch.Mark(from:"d5",to:"d5",brush:.green)])
    }
    func testDrawingTheSameMarkAgainRemovesItAndAnotherColourReplacesIt(){
        let b=board();rightDrag(b,"e2","e4");rightDrag(b,"e2","e4");XCTAssertEqual(b.sketch.marks,[])
        rightDrag(b,"d5","d5");rightDrag(b,"d5","d5",.shift);XCTAssertEqual(b.sketch.marks,[BoardSketch.Mark(from:"d5",to:"d5",brush:.red)])
    }
    func testModifiersChooseTheColourAsOnLichess(){
        XCTAssertEqual(BoardSketch.Brush(modifiers:[]),.green)
        XCTAssertEqual(BoardSketch.Brush(modifiers:.shift),.red);XCTAssertEqual(BoardSketch.Brush(modifiers:.control),.red)
        XCTAssertEqual(BoardSketch.Brush(modifiers:.option),.blue);XCTAssertEqual(BoardSketch.Brush(modifiers:.command),.blue)
        XCTAssertEqual(BoardSketch.Brush(modifiers:[.shift,.option]),.yellow)
        XCTAssertEqual(BoardSketch.Brush(modifiers:[.capsLock,.function]),.green,"other modifiers keep the default")
    }
    func testADragShowsItsArrowWhileHeldAndAReleaseOffTheBoardDrawsNothing(){
        let b=board();b.rightMouseDown(with:mouse(.rightMouseDown,centre(b,"g1")));b.rightMouseDragged(with:mouse(.rightMouseDragged,centre(b,"f3")))
        XCTAssertEqual(b.sketchPreview,BoardSketch.Mark(from:"g1",to:"f3",brush:.green))
        let off=NSPoint(x:b.boardRect.maxX+5,y:b.boardRect.midY);b.rightMouseDragged(with:mouse(.rightMouseDragged,off));b.rightMouseUp(with:mouse(.rightMouseUp,off))
        XCTAssertNil(b.sketchPreview);XCTAssertEqual(b.sketch.marks,[])
    }
    func testAMoveOrAnotherBoardClearsTheMarks(){
        let b=board();rightDrag(b,"e2","e4");b.selected="e2";b.destinations=["e3","e4"];XCTAssertEqual(b.sketch.marks.count,1,"selection keeps them")
        b.position=["e4":"wp","e7":"bp"];XCTAssertEqual(b.sketch.marks,[],"a move clears them")
        rightDrag(b,"e7","e5");b.displaySource="review";XCTAssertEqual(b.sketch.marks,[],"another board clears them")
    }
    func testRightButtonEventsNeverPlayAndLeftPlayNeverDraws(){
        let b=board();var activated:[String]=[];b.activate={sq in activated.append(sq);if sq=="e2"{b.selected="e2";b.destinations=["e3","e4"]}}
        rightDrag(b,"e2","e4");rightDrag(b,"e2","e2");XCTAssertEqual(activated,[]);XCTAssertFalse(b.dragging)
        b.mouseDown(with:mouse(.leftMouseDown,centre(b,"e2")));b.mouseDragged(with:mouse(.leftMouseDragged,centre(b,"e4")));XCTAssertTrue(b.dragging)
        // A right press during a left drag is ignored rather than starting a mark over the dragged piece.
        b.rightMouseDown(with:mouse(.rightMouseDown,centre(b,"e4")));b.rightMouseUp(with:mouse(.rightMouseUp,centre(b,"e4")));XCTAssertTrue(b.dragging)
        b.mouseUp(with:mouse(.leftMouseUp,centre(b,"e4")))
        XCTAssertEqual(activated,["e2","e4"])
        XCTAssertEqual(b.sketch.marks,[BoardSketch.Mark(from:"e2",to:"e4",brush:.green),BoardSketch.Mark(from:"e2",to:"e2",brush:.green)],"only the marks drawn before the left drag")
        XCTAssertNil(b.menu,"the board has no context menu for the right button to compete with")
    }
    func testEveryBrushReadsOnBothSquaresOfEveryTheme(){
        func luminance(_ color:NSColor)->Double {let c=color.usingColorSpace(.sRGB)!;func linear(_ x:CGFloat)->Double {let v=Double(x);return v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)};return 0.2126*linear(c.redComponent)+0.7152*linear(c.greenComponent)+0.0722*linear(c.blueComponent)}
        func contrast(_ x:NSColor,_ y:NSColor)->Double {let a=luminance(x),b=luminance(y);return (max(a,b)+0.05)/(min(a,b)+0.05)}
        for theme in ["wood","green","blue","neutral"] {for dark in [false,true] {let p=BoardPalette.theme(theme,dark:dark);for square in [p.lightSquare,p.darkSquare] {
            XCTAssertGreaterThanOrEqual(contrast(BoardPalette.sketchCasing,square),3,"\(theme) casing, dark \(dark)")
        }}}
        for brush in BoardSketch.Brush.allCases {XCTAssertGreaterThanOrEqual(contrast(brush.color,BoardPalette.sketchCasing),3,"\(brush) inside its casing")}
    }
}
