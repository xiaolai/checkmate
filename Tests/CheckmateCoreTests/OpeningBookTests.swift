import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateApplication

/// R-20: a reviewed game is named from the bundled opening book by position, so a transposed move order finds the same
/// opening, and the first move outside the book is located.
final class OpeningBookTests:XCTestCase {
    private func document(_ pgn:String)throws -> GameDocument {try PGNImporter.parse(Data(pgn.utf8))[0]}
    private let threeKnights=OpeningName(eco:"D37",name:"Queen's Gambit Declined: Three Knights Variation")

    func testTheBundledBookLoadsEveryNamedLine()throws {
        let book=try OpeningBook.bundled()
        XCTAssertTrue(book.contains(fen:ReviewExplanation.standardStart),"the starting position is in the book")
        XCTAssertEqual(book.name(fen:"rnbqkb1r/1p2pppp/p2p1n2/8/3NP3/2N5/PPP2PPP/R1BQKB1R w KQkq - 0 6"),OpeningName(eco:"B90",name:"Sicilian Defense: Najdorf Variation"))
    }
    func testATransposedMoveOrderFindsTheSameOpening()throws {
        let book=try OpeningBook.bundled()
        let main=try document("1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Nf3 *"),transposed=try document("1. Nf3 d5 2. d4 Nf6 3. c4 e6 4. Nc3 *")
        XCTAssertEqual(book.classify(main)?.opening,threeKnights)
        XCTAssertEqual(book.classify(transposed)?.opening,threeKnights,"matched on the position, not the move order")
        XCTAssertEqual(book.classify(transposed)?.openingNode,transposed.mainline.last)
        XCTAssertNil(book.classify(transposed)?.leavesTheory,"a game still in the book has not left it")
    }
    func testTheFirstMoveOutsideTheBookIsFound()throws {
        let game=try document("1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Nf3 h6 5. a3 a6 *"),result=try XCTUnwrap(OpeningBook.bundled().classify(game))
        XCTAssertEqual(result.opening,threeKnights);XCTAssertEqual(result.openingNode,game.mainline[6])
        XCTAssertEqual(result.leavesTheory.map{game.nodes[$0].san},"h6","4...h6 is the first move the book does not have")
    }
    func testASetUpPositionOutsideTheBookHasNoOpening()throws {
        XCTAssertNil(try OpeningBook.bundled().classify(document("[SetUp \"1\"]\n[FEN \"4k3/8/8/8/8/8/4P3/4K3 w - - 0 1\"]\n\n1. e4 *")))
    }
    func testAMalformedBookIsRefused() {
        XCTAssertThrowsError(try OpeningBook(text:"eco\tname\tpgn\n"));XCTAssertThrowsError(try OpeningBook(text:"epd\teco\tname\nx w KQkq\tB90\t\n"))
        XCTAssertThrowsError(try OpeningBook(text:"epd\teco\tname\n"))
    }
}
