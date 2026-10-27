import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore

/// The learner's own arrows and circles (B-11): a right-drag draws an arrow, a right-click a circle, modifiers pick the
/// colour as on Lichess, and a move clears them. They never reach the board's left-click and drag play.
final class BoardSketchTests:XCTestCase {
    private func board()->BoardView {let b=BoardView(frame:NSRect(x:0,y:0,width:720,height:720));b.position=["e2":"wp","e7":"bp"];b.canDrag={$0=="e2"};return b}
    private func centre(_ b:BoardView,_ sq:String)->NSPoint {let r=b.squareRect(sq);return NSPoint(x:r.midX,y:r.midY)}
    private func rightDrag(_ b:BoardView,_ from:String,_ to:String,_ modifiers:NSEvent.ModifierFlags=[]){
        b.rightMouseDown(with:mouseEvent(.rightMouseDown,centre(b,from),modifiers));if from != to{b.rightMouseDragged(with:mouseEvent(.rightMouseDragged,centre(b,to),modifiers))};b.rightMouseUp(with:mouseEvent(.rightMouseUp,centre(b,to),modifiers))
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
        let b=board();b.rightMouseDown(with:mouseEvent(.rightMouseDown,centre(b,"g1")));b.rightMouseDragged(with:mouseEvent(.rightMouseDragged,centre(b,"f3")))
        XCTAssertEqual(b.sketchPreview,BoardSketch.Mark(from:"g1",to:"f3",brush:.green))
        let off=NSPoint(x:b.boardRect.maxX+5,y:b.boardRect.midY);b.rightMouseDragged(with:mouseEvent(.rightMouseDragged,off));b.rightMouseUp(with:mouseEvent(.rightMouseUp,off))
        XCTAssertNil(b.sketchPreview);XCTAssertEqual(b.sketch.marks,[])
    }
    func testAMoveOrAnotherBoardClearsTheMarks(){
        let b=board();rightDrag(b,"e2","e4");b.selected="e2";b.destinations=["e3","e4"];XCTAssertEqual(b.sketch.marks.count,1,"selection keeps them")
        b.position=["e4":"wp","e7":"bp"];XCTAssertEqual(b.sketch.marks,[],"a move clears them")
        rightDrag(b,"e7","e5");b.displaySource="review";XCTAssertEqual(b.sketch.marks,[],"another board clears them")
    }
    func testALeftClickAnywhereOnTheBoardClearsTheMarks(){
        let b=board();rightDrag(b,"a2","a4");rightDrag(b,"h3","h3");XCTAssertEqual(b.sketch.marks.count,2)
        b.mouseDown(with:mouseEvent(.leftMouseDown,centre(b,"h5")));XCTAssertEqual(b.sketch.marks,[],"the press clears them, as on Lichess")
        b.mouseUp(with:mouseEvent(.leftMouseUp,centre(b,"h5")))
        rightDrag(b,"a2","a4");b.mouseDown(with:mouseEvent(.leftMouseDown,NSPoint(x:b.boardRect.maxX+5,y:b.boardRect.midY)));XCTAssertEqual(b.sketch.marks.count,1,"a press beside the board keeps them")
    }
    func testRightButtonEventsNeverPlayAndLeftPlayNeverDraws(){
        let b=board();var activated:[String]=[];b.activate={sq in activated.append(sq);if sq=="e2"{b.selected="e2";b.destinations=["e3","e4"]}}
        rightDrag(b,"e2","e4");rightDrag(b,"e2","e2");XCTAssertEqual(activated,[]);XCTAssertFalse(b.dragging)
        b.mouseDown(with:mouseEvent(.leftMouseDown,centre(b,"e2")));b.mouseDragged(with:mouseEvent(.leftMouseDragged,centre(b,"e4")));XCTAssertTrue(b.dragging)
        // A right press during a left drag is ignored rather than starting a mark over the dragged piece.
        b.rightMouseDown(with:mouseEvent(.rightMouseDown,centre(b,"e4")));b.rightMouseUp(with:mouseEvent(.rightMouseUp,centre(b,"e4")));XCTAssertTrue(b.dragging)
        b.mouseUp(with:mouseEvent(.leftMouseUp,centre(b,"e4")))
        XCTAssertEqual(activated,["e2","e4"])
        XCTAssertEqual(b.sketch.marks,[],"the left press cleared the earlier marks, and the right press during the drag drew none")
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
