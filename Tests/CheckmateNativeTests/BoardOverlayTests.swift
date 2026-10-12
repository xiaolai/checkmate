import XCTest
import AppKit
@testable import CheckmateNative

final class BoardOverlayTests:XCTestCase {
    func testArrowEndpointsStayInsideBoardAtAllSizes()throws {
        for size in [CGFloat(320),780,1200] {
            let board=BoardView(frame:NSRect(x:0,y:0,width:size,height:size))
            for (from,to) in [("a1","a8"),("h8","a1"),("e2","e3"),("d4","e5"),("g1","f3"),("d4","b5"),("b8","c6")] {
                let arrow=try XCTUnwrap(BoardArrow(from:from,to:to,board:board))
                XCTAssertTrue(board.boardRect.contains(arrow.origin));XCTAssertTrue(board.squareRect(to).contains(arrow.tip))
                XCTAssertTrue(board.boardRect.contains(arrow.shaft.bounds));XCTAssertTrue(board.boardRect.contains(arrow.head.bounds))
                XCTAssertEqual(arrow.shaft.lineCapStyle,.round);XCTAssertEqual(arrow.head.lineJoinStyle,.round)
            }
        }
    }
    /// An arrow clears a piece on its source and stops before a piece on its target; long arrows keep the full clearances.
    func testArrowsClearThePiecesTheyJoin()throws {
        let board=BoardView(frame:NSRect(x:0,y:0,width:780,height:780)),side=board.squareRect("e2").width
        for (from,to) in [("a1","a8"),("g1","f3"),("d4","b5"),("h8","a1")] {
            board.position=[from:"wq",to:"bk"]
            let arrow=try XCTUnwrap(BoardArrow(from:from,to:to,board:board)),rect=board.squareRect(from),target=board.squareRect(to)
            XCTAssertEqual(hypot(arrow.origin.x-rect.midX,arrow.origin.y-rect.midY),side*BoardOverlay.sourceClearance,accuracy:0.00001,"\(from)-\(to)")
            XCTAssertEqual(hypot(arrow.tip.x-target.midX,arrow.tip.y-target.midY),side*BoardOverlay.endpointInset,accuracy:0.00001,"\(from)-\(to)")
            XCTAssertTrue((0..<arrow.head.elementCount).contains{arrow.head.element(at:$0) == .closePath})
            // The shaft finishes at the filled head's base, never beyond its tip.
            var points=[NSPoint](repeating:.zero,count:3)
            _ = arrow.shaft.element(at:arrow.shaft.elementCount-1,associatedPoints:&points)
            XCTAssertGreaterThanOrEqual((arrow.tip.x-points[0].x)*(arrow.tip.x-arrow.origin.x)+(arrow.tip.y-points[0].y)*(arrow.tip.y-arrow.origin.y),0)
        }
    }
    /// A one-square arrow (a king step, a pawn push, a capture next door) keeps a visible shaft and a whole head; it used to
    /// shrink to a sliver of head because both clearances together nearly filled the square.
    func testOneSquareArrowsStayVisible()throws {
        let board=BoardView(frame:NSRect(x:0,y:0,width:780,height:780)),side=board.squareRect("e2").width
        for (position,from,to) in [(["e4":"wk"],"e4","e5"),(["e4":"wk"],"e4","f5"),(["b5":"wq","a5":"bk"],"b5","a5"),(["h8":"br","h7":"wp"],"h8","h7"),([:],"c5","d5")] {
            board.position=position
            let arrow=try XCTUnwrap(BoardArrow(from:from,to:to,board:board))
            XCTAssertGreaterThanOrEqual(hypot(arrow.tip.x-arrow.origin.x,arrow.tip.y-arrow.origin.y),side*BoardOverlay.minimumArrowSpan-0.00001,"\(from)-\(to)")
            XCTAssertEqual(arrow.head.bounds.height.rounded()==0 && arrow.head.bounds.width.rounded()==0,false,"\(from)-\(to) has no head")
            XCTAssertGreaterThanOrEqual(max(arrow.head.bounds.width,arrow.head.bounds.height),side*BoardOverlay.headLength*0.99,"\(from)-\(to) head is cut short")
            XCTAssertTrue(board.squareRect(to).contains(arrow.tip))
        }
        // An empty source needs no clearance: the arrow starts at its centre.
        board.position=[:]
        let fromEmpty=try XCTUnwrap(BoardArrow(from:"d4",to:"d6",board:board)),rect=board.squareRect("d4")
        XCTAssertEqual(hypot(fromEmpty.origin.x-rect.midX,fromEmpty.origin.y-rect.midY),0,accuracy:0.00001)
    }
    /// The Knight lesson's "two squares, then one sideways": c3-c5 and c5-d5 meet on an empty square and draw as one route.
    /// Arrows meeting at a piece, or a pair pointing at each other, stay separate.
    func testArrowsMeetingOnAnEmptySquareFormOneRoute()throws {
        let board=BoardView(frame:NSRect(x:0,y:0,width:780,height:780))
        XCTAssertEqual(BoardArrow.joints([["c3","c5"],["c5","d5"]],position:["c3":"wn"]),["c5"])
        XCTAssertEqual(BoardArrow.joints([["c3","d3"],["d3","d5"]],position:["c3":"wn"]),["d3"])
        XCTAssertEqual(BoardArrow.joints([["d3","e4"],["e4","d5"]],position:["d3":"wp","e4":"wp","d5":"bk"]),[],"a defended piece is not a turn")
        XCTAssertEqual(BoardArrow.joints([["d1","d8"],["d8","d1"]],position:[:]),[],"two arrows facing each other are not a route")
        board.position=["c3":"wn"]
        let first=try XCTUnwrap(BoardArrow(from:"c3",to:"c5",board:board,through:true)),second=try XCTUnwrap(BoardArrow(from:"c5",to:"d5",board:board))
        let turn=board.squareRect("c5")
        XCTAssertEqual(first.head.elementCount,0,"the first leg has no head")
        XCTAssertEqual(first.tip.x,turn.midX,accuracy:0.00001);XCTAssertEqual(first.tip.y,turn.midY,accuracy:0.00001)
        XCTAssertEqual(second.origin.x,turn.midX,accuracy:0.00001);XCTAssertEqual(second.origin.y,turn.midY,accuracy:0.00001)
        XCTAssertGreaterThan(second.head.elementCount,0)
    }
    func testAllThemeMarksHaveContrastOnBothSquares()throws {
        func luminance(_ color:NSColor)->Double {
            let c=color.usingColorSpace(.sRGB)!
            func linear(_ x:CGFloat)->Double {let v=Double(x);return v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)}
            return 0.2126*linear(c.redComponent)+0.7152*linear(c.greenComponent)+0.0722*linear(c.blueComponent)
        }
        for theme in ["wood","green","blue","neutral"] {
            let p=BoardPalette.theme(theme)
            for mark in [p.ink,p.protection,p.danger] {for square in [p.lightSquare,p.darkSquare] {
                let a=luminance(mark),b=luminance(square)
                XCTAssertGreaterThanOrEqual((max(a,b)+0.05)/(min(a,b)+0.05),3,"\(theme) mark contrast")
            }}
        }
        XCTAssertEqual(BoardPalette.theme("unknown").ink,BoardPalette.theme("wood").ink)
    }
    func testKnightRoutesTurnInBothDirectionsAndInvalidArrowsAreIgnored()throws {
        let board=BoardView(frame:NSRect(x:0,y:0,width:780,height:780))
        for target in ["b3","b5","c2","c6","e2","e6","f3","f5"] {
            let route=try XCTUnwrap(BoardArrow(from:"d4",to:target,board:board))
            XCTAssertEqual(route.shaft.elementCount,4)
            var points=[NSPoint](repeating:.zero,count:3)
            XCTAssertEqual(route.shaft.element(at:2,associatedPoints:&points),.cubicCurveTo)
        }
        XCTAssertEqual(try XCTUnwrap(BoardArrow(from:"d4",to:"d5",board:board)).shaft.elementCount,2)
        XCTAssertNil(BoardArrow(from:"d4",to:"d4",board:board));XCTAssertNil(BoardArrow(from:"a0",to:"d4",board:board))
    }
    func testDashFlowMovesForwardAndWrapsWithoutJumping(){
        let side=CGFloat(80),period=Double(BoardOverlay.arrowDash.reduce(0,+))/BoardOverlay.arrowSpeed
        let start=BoardOverlay.arrowDashPhase(at:0,side:side),later=BoardOverlay.arrowDashPhase(at:0.5,side:side)
        XCTAssertLessThan(later,start)
        XCTAssertEqual(BoardOverlay.arrowDashPhase(at:period,side:side),start,accuracy:0.00001)
        XCTAssertEqual(BoardOverlay.arrowDashPhase(at:0.5,side:side*2),later*2,accuracy:0.00001)
    }
    func testBreathingHasSmoothBoundedCycleWithoutFlashes(){
        XCTAssertEqual(BoardOverlay.breath(at:0),0,accuracy:0.00001)
        XCTAssertEqual(BoardOverlay.breath(at:BoardOverlay.breathPeriod/2),1,accuracy:0.00001)
        XCTAssertEqual(BoardOverlay.breath(at:BoardOverlay.breathPeriod),0,accuracy:0.00001)
        let samples=(0...100).map{BoardOverlay.breath(at:Double($0)*BoardOverlay.breathPeriod/100)}
        XCTAssertTrue(samples.allSatisfy{(0...1).contains($0)})
        XCTAssertTrue(zip(samples,samples.dropFirst()).allSatisfy{abs($0-$1)<0.04})
    }
}
