import XCTest
@testable import CheckmateCore
final class RulesTests:XCTestCase {
    func testHistorySurvivesPGNRestoreAndUndo() throws {
        let rules=try ChessRules();try rules.move("e2","e4");try rules.move("e7","e5")
        let restored=try ChessRules();try restored.restore(rules.pgn)
        XCTAssertEqual(restored.fen,rules.fen);XCTAssertEqual(restored.history,["e4","e5"])
        restored.undo();XCTAssertEqual(restored.turn,"b")
    }
    func testIllegalMoveDoesNotChangeState() throws {
        let rules=try ChessRules();let before=rules.pgn
        XCTAssertThrowsError(try rules.move("d4","e5"));XCTAssertEqual(rules.pgn,before)
    }
    func testEnPassantAndPromotion() throws {
        let r=try ChessRules(fen:"4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 2")
        let m=try r.move("e5","d6");XCTAssertEqual(m.captured,"p");XCTAssertNil(r.piece("d5"))
        let p=try ChessRules(fen:"4k3/P7/8/8/8/8/8/4K3 w - - 0 1")
        try p.move("a7","a8","n");XCTAssertEqual(p.piece("a8")?.type,"n")
    }
    func testOpponentInspectionIsSeparateFromLegalMove() throws {
        let r=try ChessRules();let inspection=try r.inspect("e7")
        XCTAssertEqual(Set(inspection.destinations),Set(["e6","e5"]));XCTAssertFalse(inspection.legalNow)
        XCTAssertThrowsError(try r.move("e7","e5"))
    }
}
