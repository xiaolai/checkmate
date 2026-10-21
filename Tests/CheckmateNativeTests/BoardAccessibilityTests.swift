import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
final class BoardAccessibilityTests:XCTestCase {
    func testAllSquareHitTargetsAndLabels()throws {let b=BoardView(frame:NSRect(x:0,y:0,width:720,height:720));b.position=try ChessRules().board;let children=(b.accessibilityChildren() ?? []).compactMap{$0 as? SquareAccessibility};XCTAssertEqual(children.count,64);for child in children{let rect=b.squareRect(child.square);XCTAssertEqual(b.square(at:NSPoint(x:rect.midX,y:rect.midY)),child.square);XCTAssertTrue(child.accessibilityLabel()!.contains(child.square))};XCTAssertNil(b.square(at:NSPoint(x:-1,y:-1)));XCTAssertEqual(children.first(where:{$0.square=="e2"})!.accessibilityLabel(),"e2, White, pawn")}
    func testAssistivePressFocusAndSemanticMarkers(){let b=BoardView(frame:NSRect(x:0,y:0,width:720,height:720));b.position=["d4":"wp","e5":"bp"];b.destinations=["e5"];b.arrows=[["d4","e5"]];var pressed="";b.activate={pressed=$0};let square=SquareAccessibility(board:b,square:"e5");XCTAssertTrue(square.accessibilityLabel()!.contains("capture destination"));XCTAssertTrue(square.accessibilityLabel()!.contains("suggested move from d4"));XCTAssertTrue(square.accessibilityPerformPress());XCTAssertEqual(pressed,"e5");XCTAssertEqual(b.focus,"e5")}
    func testKeyboardTraversalAndEscape(){let b=BoardView(frame:NSRect(x:0,y:0,width:720,height:720));var cleared=false;b.clearSelection={cleared=true};func key(_ code:UInt16){b.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!)};b.focus="h8";key(124);key(126);XCTAssertEqual(b.focus,"h8");key(123);key(125);XCTAssertEqual(b.focus,"g7");key(53);XCTAssertTrue(cleared)}
}
/// D-21, D-22, D-24, D-37: the board is a grid VoiceOver can walk by row and column, with headers and rotors; a covered
/// square says how many pieces attack and defend it; coordinates scale with the board; keyboard focus is the system ring.
final class BoardGridAccessibilityTests:XCTestCase {
    private func board()->BoardView {BoardView(frame:NSRect(x:0,y:0,width:720,height:720))}
    func testBoardIsAGridWithRowAndColumnIndexesThatFollowOrientation()throws {
        let b=board();b.position=try ChessRules().board
        XCTAssertEqual(b.accessibilityRole(),.grid);XCTAssertEqual(b.accessibilityLabel(),"Chessboard")
        XCTAssertEqual(b.accessibilityRowCount(),8);XCTAssertEqual(b.accessibilityColumnCount(),8)
        let squares=(b.accessibilityChildren() ?? []).compactMap{$0 as? SquareAccessibility}
        XCTAssertEqual(squares.count,64,"every square stays one element");XCTAssertEqual(squares.first{$0.square=="e2"}?.accessibilityLabel(),"e2, White, pawn","labels the gates press by are unchanged")
        XCTAssertEqual(squares.first{$0.square=="e2"}?.accessibilityRole(),.button,"a square still presses like a button")
        func cell(_ sq:String)->SquareAccessibility {squares.first{$0.square==sq}!}
        // White at the bottom: row 0 is the eighth rank, column 0 the a-file.
        XCTAssertEqual(cell("a8").accessibilityRowIndexRange(),NSRange(location:0,length:1));XCTAssertEqual(cell("a8").accessibilityColumnIndexRange(),NSRange(location:0,length:1))
        XCTAssertEqual(cell("e2").accessibilityRowIndexRange(),NSRange(location:6,length:1));XCTAssertEqual(cell("e2").accessibilityColumnIndexRange(),NSRange(location:4,length:1))
        XCTAssertEqual((b.accessibilityCell(forColumn:4,row:6) as? SquareAccessibility)?.square,"e2")
        func labels(_ elements:[Any]?)->[String] {(elements ?? []).compactMap{($0 as? NSAccessibilityElement)?.accessibilityLabel()}}
        XCTAssertEqual(labels(b.accessibilityColumnHeaderUIElements()),["File a","File b","File c","File d","File e","File f","File g","File h"])
        XCTAssertEqual(labels(b.accessibilityRowHeaderUIElements()),["Rank 8","Rank 7","Rank 6","Rank 5","Rank 4","Rank 3","Rank 2","Rank 1"])
        XCTAssertEqual((b.accessibilityChildren() ?? []).count,80,"the squares and their sixteen headers")
        // Black at the bottom mirrors both.
        b.blackAtBottom=true
        XCTAssertEqual(cell("h1").accessibilityRowIndexRange(),NSRange(location:0,length:1));XCTAssertEqual(cell("h1").accessibilityColumnIndexRange(),NSRange(location:0,length:1))
        XCTAssertEqual((b.accessibilityCell(forColumn:0,row:0) as? SquareAccessibility)?.square,"h1")
        XCTAssertEqual(labels(b.accessibilityColumnHeaderUIElements()).first,"File h");XCTAssertEqual(labels(b.accessibilityRowHeaderUIElements()).first,"Rank 1")
        XCTAssertNil(b.accessibilityCell(forColumn:8,row:0))
    }
    func testRotorsStepThroughPiecesAndAttackedPiecesInReadingOrder(){
        let b=board();b.position=["a8":"bk","e5":"bp","d4":"wp","e1":"wk","h1":"wr"]
        XCTAssertEqual(b.accessibilityCustomRotors().map(\.label),["Pieces","Attacked Pieces"])
        XCTAssertEqual(b.rotorSquares(.pieces),["a8","e5","d4","e1","h1"],"top row first, left to right, as the board is read")
        XCTAssertEqual(b.rotorSquares(.attacked),["e5","d4"],"each pawn attacks the other")
        let rotor=b.accessibilityCustomRotors()[0]
        let first=NSAccessibilityCustomRotor.SearchParameters();first.searchDirection = .next
        let hit=b.rotor(rotor,resultFor:first);XCTAssertEqual((hit?.targetElement as? SquareAccessibility)?.square,"a8")
        let next=NSAccessibilityCustomRotor.SearchParameters();next.searchDirection = .next;next.currentItem=hit
        XCTAssertEqual((b.rotor(rotor,resultFor:next)?.targetElement as? SquareAccessibility)?.square,"e5")
        let back=NSAccessibilityCustomRotor.SearchParameters();back.searchDirection = .previous;back.currentItem=hit
        XCTAssertNil(b.rotor(rotor,resultFor:back),"nothing before the first piece")
        let attacked=b.accessibilityCustomRotors()[1],start=NSAccessibilityCustomRotor.SearchParameters();start.searchDirection = .next
        let item=b.rotor(attacked,resultFor:start);XCTAssertEqual((item?.targetElement as? SquareAccessibility)?.square,"e5");XCTAssertEqual(item?.customLabel,"e5, Black, pawn, attacked by 1, defended by 0")
    }
    func testCoveredSquaresSayHowManyAttackAndDefend(){
        // The white rook on a1 is selected; it covers its own pawn on a2 and knight on b1.
        let b=board();b.position=["a1":"wr","a2":"wp","b1":"wn","a7":"bp","b8":"bn","c5":"bb","e1":"wk","e8":"bk"];b.selected="a1";b.attacked=["a2","b1"]
        func label(_ sq:String)->String {SquareAccessibility(board:b,square:sq).accessibilityLabel() ?? ""}
        XCTAssertFalse(label("a2").contains("attacked or defended"),"no ambiguous state")
        XCTAssertEqual(label("a2"),"a2, White, pawn, attacked by 0, defended by 1")
        b.position=["a1":"wr","a6":"bp","b7":"bp","c4":"wb","e1":"wk","e8":"bk"];b.attacked=["a6","a3"]
        // A piece of the other side: its attackers are the selected side's, its defenders its own side's.
        XCTAssertEqual(label("a6"),"a6, Black, pawn, attacked by 2, defended by 1")
        // An empty square is counted for the side of the selected piece: who would attack it there, who would defend it.
        XCTAssertEqual(label("a3"),"a3, attacked by 0, defended by 1")
        XCTAssertEqual(label("h5"),"h5","a square the piece does not cover says nothing about pressure")
    }
    func testCoordinatesScaleWithTheBoardAndFitTheMargin(){
        XCTAssertEqual(BoardView.coordinateFontSize(side:40),Metrics.coordinateSize,"never smaller than the minimum")
        XCTAssertGreaterThan(BoardView.coordinateFontSize(side:100),BoardView.coordinateFontSize(side:60))
        XCTAssertLessThanOrEqual(BoardView.coordinateFontSize(side:400),Metrics.boardMargin-4,"never larger than the margin it sits in")
    }
    func testKeyboardFocusUsesTheSystemFocusRing(){
        let b=board();b.focus="e2";XCTAssertEqual(b.focusRingMaskBounds,.zero,"a pointer user sees no ring")
        b.keyboardFocusVisible=true;XCTAssertEqual(b.focusRingMaskBounds,b.squareRect("e2"))
        b.focus="h8";XCTAssertEqual(b.focusRingMaskBounds,b.squareRect("h8"),"the ring follows the focused square")
        XCTAssertEqual(b.focusRingType,.default)
    }
}
