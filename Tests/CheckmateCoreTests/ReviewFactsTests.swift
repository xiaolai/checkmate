import XCTest
@testable import CheckmateCore
final class ReviewFactsTests:XCTestCase {
    func testIndependentMoveFactsAcrossTwentyHeldOutRecords()throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/GameReview")
        var checked=0
        for name in ["manifest-expanded.json","manifest-novice.json"] {
            let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent(name))) as! [String:Any]
            for entry in manifest["entries"] as! [[String:Any]] where entry["split"] as? String=="held-out" && entry["expectedImport"] as? String=="accept" {
                let document=try PGNImporter.parse(Data(contentsOf:root.appendingPathComponent(entry["path"] as! String)))[0]
                for node in document.mainline.prefix(20) {
                    let record=document.nodes[node],uci=try XCTUnwrap(record.uci),parent=try XCTUnwrap(record.parent)
                    let before=try document.snapshotRules(at:parent),piece=try XCTUnwrap(before.piece(String(uci.prefix(2)))),explanation=try ReviewExplanation.make(document:document,node:node)
                    let move=try XCTUnwrap(explanation.facts.first{$0.kind=="move"})
                    XCTAssertEqual(move.squares,[String(uci.prefix(2)),String(uci.dropFirst(2).prefix(2))])
                    XCTAssertTrue(move.text.hasPrefix(piece.color=="w" ? "White moved":"Black moved"))
                    XCTAssertFalse(explanation.facts.contains{$0.kind=="recommendation" || $0.kind=="alternative"},"No engine evidence must not invent advice")
                    XCTAssertEqual(Set(explanation.facts.map(\.id)).count,explanation.facts.count)
                    XCTAssertTrue(explanation.facts.flatMap(\.squares).allSatisfy(ChessRules.validSquare))
                }
                if document.mainline.isEmpty {let explanation=try ReviewExplanation.make(document:document,node:0);XCTAssertNotNil(explanation.historyNote);let status=try document.status(at:0);if status.terminal{XCTAssertFalse(explanation.facts.contains{$0.kind=="recommendation"})}}
                checked+=1
            }
        }
        XCTAssertGreaterThanOrEqual(checked,20)
    }
    func testEnPassantNamesCapturedSquareAndUnderpromotionNamesPiece()throws {
        let enPassant=try PGNImporter.parse(Data("1. e4 a6 2. e5 d5 3. exd6 *".utf8))[0]
        let facts=try ReviewExplanation.make(document:enPassant,node:enPassant.mainline.last!).facts
        XCTAssertEqual(facts.first{$0.kind=="capture"}?.squares,["d5","d6"])
        let promotion=try PGNImporter.parse(Data("[SetUp \"1\"]\n[FEN \"7k/P7/8/8/8/8/8/7K w - - 0 1\"]\n1. a8=N *".utf8))[0]
        XCTAssertEqual(try ReviewExplanation.make(document:promotion,node:1).facts.first{$0.kind=="promotion"}?.text,"The pawn became a knight.")
    }
}
