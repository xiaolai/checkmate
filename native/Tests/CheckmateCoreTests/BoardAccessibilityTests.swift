import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
final class BoardAccessibilityTests:XCTestCase {
    func testAllSquareHitTargetsAndLabels()throws {let b=BoardView(frame:NSRect(x:0,y:0,width:720,height:720));b.position=try ChessRules().board;let children=b.accessibilityChildren() as! [SquareAccessibility];XCTAssertEqual(children.count,64);for child in children{let rect=b.squareRect(child.square);XCTAssertEqual(b.square(at:NSPoint(x:rect.midX,y:rect.midY)),child.square);XCTAssertTrue(child.accessibilityLabel()!.contains(child.square))};XCTAssertNil(b.square(at:NSPoint(x:-1,y:-1)));XCTAssertEqual(children.first(where:{$0.square=="e2"})!.accessibilityLabel(),"e2, White, pawn")}
    func testAssistivePressFocusAndSemanticMarkers(){let b=BoardView(frame:NSRect(x:0,y:0,width:720,height:720));b.position=["d4":"wp","e5":"bp"];b.destinations=["e5"];b.arrows=[["d4","e5"]];var pressed="";b.activate={pressed=$0};let square=SquareAccessibility(board:b,square:"e5");XCTAssertTrue(square.accessibilityLabel()!.contains("capture destination"));XCTAssertTrue(square.accessibilityLabel()!.contains("suggested move from d4"));XCTAssertTrue(square.accessibilityPerformPress());XCTAssertEqual(pressed,"e5");XCTAssertEqual(b.focus,"e5")}
    func testKeyboardTraversalAndEscape(){let b=BoardView(frame:NSRect(x:0,y:0,width:720,height:720));var cleared=false;b.clearSelection={cleared=true};func key(_ code:UInt16){b.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!)};b.focus="h8";key(124);key(126);XCTAssertEqual(b.focus,"h8");key(123);key(125);XCTAssertEqual(b.focus,"g7");key(53);XCTAssertTrue(cleared)}
}
