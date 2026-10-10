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
    func testSourceClearanceAndShortMoveHeads()throws {
        let board=BoardView(frame:NSRect(x:0,y:0,width:780,height:780)),side=board.squareRect("e2").width
        for (from,to) in [("e2","e3"),("d4","e5"),("g1","f3"),("a1","a8"),("h8","h7")] {
            let arrow=try XCTUnwrap(BoardArrow(from:from,to:to,board:board)),rect=board.squareRect(from)
            XCTAssertEqual(hypot(arrow.origin.x-rect.midX,arrow.origin.y-rect.midY),side*BoardOverlay.sourceClearance,accuracy:0.00001)
            XCTAssertGreaterThan(BoardOverlay.sourceClearance,0.5)
            XCTAssertTrue(board.boardRect.contains(arrow.head.bounds))
            let target=board.squareRect(to)
            XCTAssertGreaterThan(hypot(arrow.tip.x-target.midX,arrow.tip.y-target.midY),side*0.4)
            var points=[NSPoint](repeating:.zero,count:3)
            XCTAssertTrue((0..<arrow.head.elementCount).contains{arrow.head.element(at:$0) == .closePath})
            // The shaft finishes at the filled head's base, never beyond its tip.
            _ = arrow.shaft.element(at:arrow.shaft.elementCount-1,associatedPoints:&points)
            let shaftEnd=points[0]
            XCTAssertGreaterThanOrEqual((arrow.tip.x-shaftEnd.x)*(arrow.tip.x-arrow.origin.x)+(arrow.tip.y-shaftEnd.y)*(arrow.tip.y-arrow.origin.y),0)
        }
        let short=try XCTUnwrap(BoardArrow(from:"e2",to:"e3",board:board))
        XCTAssertGreaterThanOrEqual(short.head.bounds.minY,short.origin.y-0.00001)
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
            XCTAssertEqual(route.shaft.element(at:2,associatedPoints:&points),.curveTo)
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
