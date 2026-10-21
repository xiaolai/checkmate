import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// R-24: tactical patterns are read from the real position a move made, on known textbook positions, and the game
/// overview names the analysis's costliest moves rather than counting moves.
final class ReviewMotifTests:XCTestCase {
    private func motifs(_ fen:String,_ uci:String)throws -> [ReviewMotif] {
        let rules=try ChessRules(fen:fen),before=rules.board,move=try rules.move(uci:uci)
        return ReviewMotifs.find(before:before,after:rules.board,from:move.from,to:move.to)
    }
    func testAKnightForksTheKingAndRook()throws {
        let found=try motifs("r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1","b5c7")
        XCTAssertEqual(found.map(\.kind),[.fork]);XCTAssertEqual(found.first?.squares,["c7","e8","a8"])
        XCTAssertEqual(found.first?.text,"Fork: the knight on c7 attacks the black king on e8 and the black rook on a8 at once.")
    }
    func testABishopPinsAKnightToTheKing()throws {
        let found=try motifs("4k3/8/2n5/8/8/8/8/4KB2 w - - 0 1","f1b5")
        XCTAssertEqual(found.map(\.kind),[.pin],"the pinned knight is named once, not again as hanging");XCTAssertEqual(found.first?.squares,["b5","c6","e8"])
    }
    func testARookSkewersTheKingAndQueen()throws {
        let found=try motifs("4q3/8/8/4k3/8/8/8/R6K w - - 0 1","a1e1")
        XCTAssertEqual(found.map(\.kind),[.skewer]);XCTAssertEqual(found.first?.squares,["e1","e5","e8"])
    }
    func testAKnightLeftWhereAPawnTakesItIsHanging()throws {
        let found=try motifs("4k3/8/3p4/8/8/5N2/8/4K3 w - - 0 1","f3e5")
        XCTAssertEqual(found.map(\.kind),[.hanging]);XCTAssertEqual(found.first?.text,"Hanging piece: the white knight on e5 is attacked by the pawn on d6 and nothing defends it.")
    }
    func testARookReachingTheOpenFileThreatensTheBackRank()throws {
        let found=try motifs("6k1/5ppp/8/8/8/8/P4PPP/R5K1 w - - 0 1","a1e1")
        XCTAssertEqual(found.map(\.kind),[.backRank]);XCTAssertEqual(found.first?.squares,["g8","e1","e8"])
        XCTAssertEqual(try motifs("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1","a1e1").map(\.kind),[],"a threat that was already there is not new")
        XCTAssertEqual(try motifs("6k1/5pp1/7p/8/8/8/P4PPP/R5K1 w - - 0 1","a1e1").map(\.kind),[],"a king with a free square in front is not caught")
    }
    func testAKnightMovingOffTheDiagonalDiscoversTheBishopsAttack()throws {
        let found=try motifs("7k/6q1/8/8/3N4/8/1B6/4K3 w - - 0 1","d4b5")
        XCTAssertEqual(found.map(\.kind),[.discovered]);XCTAssertEqual(found.first?.squares,["b2","d4","g7"])
    }
    func testAQuietOpeningMoveHasNoPattern()throws {XCTAssertEqual(try motifs(ReviewExplanation.standardStart,"e2e4"),[])}

    func testAMotifIsAVerifiedFactOfTheMove()throws {
        let document=try PGNImporter.parse(Data("[SetUp \"1\"]\n[FEN \"r3k3/8/8/1N6/8/8/8/4K3 w - - 0 1\"]\n\n1. Nc7+ *".utf8))[0]
        let explanation=try ReviewExplanation.make(document:document,node:document.mainline[0])
        XCTAssertEqual(explanation.facts.first{$0.kind=="fork"}?.squares,["c7","e8","a8"])
        XCTAssertTrue(explanation.summary.contains("Fork:"),"the pattern is among the facts the summary and the voice read first")
    }
    func testTheOverviewNamesTheCostliestMovesWithoutCountingHalfMoves()throws {
        let document=try PGNImporter.parse(Data("1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0".utf8))[0],line=document.mainline
        let plain=try ReviewExplanation.make(document:document,node:0)
        XCTAssertFalse(plain.summary.contains("counting each side"));XCTAssertFalse(plain.summary.contains(" moves recorded"))
        let analyzed=try ReviewExplanation.make(document:document,node:0,losses:[line[0]:0,line[3]:0.15,line[5]:0.9,line[6]:0.05])
        XCTAssertEqual(analyzed.summary,"The costliest moves were 3… Nf6 (blunder) and 2… Nc6 (mistake). Start with 3… Nf6: compare it with the engine's choice.")
        XCTAssertEqual(try ReviewExplanation.make(document:document,node:0,losses:[line[5]:0.9]).summary,"The costliest move was 3… Nf6 (blunder). Start there: compare it with the engine's choice.")
        XCTAssertTrue(try ReviewExplanation.make(document:document,node:0,losses:[line[0]:0.01]).summary.hasPrefix("The analysis found no mistakes or blunders in this game. "))
    }
}
