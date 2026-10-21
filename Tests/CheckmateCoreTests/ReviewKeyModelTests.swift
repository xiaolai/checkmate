import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// R-8: the review's key model, after Lichess. ←/→ move along the line shown, an imagined one included; ↑/↓ choose
/// between the recorded moves and kept ideas played from the same position.
@MainActor final class ReviewKeyModelTests:XCTestCase {
    private func review(_ pgn:String="1. e4 e5 (1... c5) (1... e6) 2. Nf3 *")throws -> (ReviewController,GameDocument) {
        let document=try PGNImporter.parse(Data(pgn.utf8))[0],review=ReviewController();review.load(document);return (review,document)
    }
    func testUpAndDownChooseBetweenRecordedMoves()throws {
        let (review,document)=try review(),replies=document.nodes[document.mainline[0]].children
        XCTAssertEqual(replies.map{document.nodes[$0].san},["e5","c5","e6"])
        XCTAssertTrue(review.variations.isEmpty,"the start has no alternatives")
        try review.select(replies[0]);XCTAssertEqual(review.variations.map(\.move),["e7e5","c7c5","e7e6"])
        try review.variation(1);XCTAssertEqual(review.nodeID,replies[1])
        try review.variation(1);XCTAssertEqual(review.nodeID,replies[2])
        try review.variation(1);XCTAssertEqual(review.nodeID,replies[2],"the last alternative stays put")
        try review.variation(-1);XCTAssertEqual(review.nodeID,replies[1])
        review.forward();XCTAssertEqual(review.nodeID,replies[1],"a variation with no continuation goes no further")
        try review.back();XCTAssertEqual(review.nodeID,document.mainline[0])
    }
    func testLeftAndRightWalkAnImaginedLineAndLeaveItAtItsStart()throws {
        let (review,document)=try review(),e4=document.mainline[0]
        try review.select(e4);try review.selectSquare("d7");try review.selectSquare("d5");try review.selectSquare("e4");try review.selectSquare("d5")
        XCTAssertEqual(review.branch?.moves,["d7d5","e4d5"]);XCTAssertEqual(review.branchPly,2)
        try review.back();XCTAssertEqual(review.branchPly,1,"← steps back inside the idea")
        review.forward();XCTAssertEqual(review.branchPly,2,"→ steps on inside the idea")
        review.forward();XCTAssertEqual(review.branchPly,2)
        try review.back();try review.back();XCTAssertNil(review.branch,"← from the idea's first move returns to the record");XCTAssertEqual(review.nodeID,e4)
        XCTAssertEqual(review.branchesForSaving.map(\.moves),[["d7d5","e4d5"]],"the idea is kept")
    }
    func testKeptIdeasAreVariationsOfTheirPosition()throws {
        let (review,document)=try review(),e4=document.mainline[0],replies=document.nodes[e4].children
        try review.select(e4);try review.selectSquare("d7");try review.selectSquare("d5")
        XCTAssertEqual(review.variations.map(\.move),["e7e5","c7c5","e7e6","d7d5"],"recorded moves first, then the idea")
        try review.variation(-1);XCTAssertNil(review.branch);XCTAssertEqual(review.nodeID,replies[2])
        try review.variation(1);XCTAssertEqual(review.branch?.moves,["d7d5"]);XCTAssertEqual(review.branchPly,1);XCTAssertEqual(review.board["d5"],"bp")
        let idea=try XCTUnwrap(review.branch?.id)
        try review.select(e4);try review.selectSquare("e7");try review.selectSquare("e6");XCTAssertEqual(review.branch?.moves,["e7e6"])
        XCTAssertEqual(review.variations.map(\.move),["e7e5","c7c5","e7e6","d7d5"],"an idea repeating a recorded move adds nothing")
        XCTAssertTrue(review.variations.contains{$0.line == .idea(idea,ply:1)})
    }
}
