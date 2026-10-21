import XCTest
@testable import CheckmateNative
import CheckmateCore

/// R-20: the review header names the record's opening with its ECO code and the move where the game leaves theory.
@MainActor final class ReviewOpeningTests:XCTestCase {
    func testTheHeaderNamesTheOpeningAndTheMoveThatLeavesTheory()throws {
        let game=try PGNImporter.parse(Data("1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Nf3 h6 5. a3 *".utf8))[0],header=try XCTUnwrap(ReviewFormat.openingHeader(game))
        XCTAssertEqual(header.title,"D37 · Queen's Gambit Declined: Three Knights Variation")
        XCTAssertEqual(header.leaves,game.mainline[7]);XCTAssertEqual(ReviewFormat.moveText(game.nodes[game.mainline[7]]),"4… h6")
        let inBook=try PGNImporter.parse(Data("1. Nf3 d5 2. d4 Nf6 3. c4 e6 4. Nc3 *".utf8))[0]
        XCTAssertEqual(ReviewFormat.openingHeader(inBook)?.title,header.title,"a transposition finds the same opening");XCTAssertNil(ReviewFormat.openingHeader(inBook)?.leaves)
        XCTAssertNil(ReviewFormat.openingHeader(try PGNImporter.parse(Data("[SetUp \"1\"]\n[FEN \"4k3/8/8/8/8/8/4P3/4K3 w - - 0 1\"]\n\n1. e4 *".utf8))[0]),"a set-up position has no opening")
    }
}
