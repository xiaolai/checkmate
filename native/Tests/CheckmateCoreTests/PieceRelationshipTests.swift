import XCTest
@testable import CheckmateCore
@testable import CheckmateNative

final class PieceRelationshipTests:XCTestCase {
    func testStartingPawnProtectionAndNoAttacksPreserveGame()throws {
        let rules=try ChessRules(),fen=rules.fen,pgn=rules.pgn
        let protection=try rules.relationships("e2",mode:.protected)
        XCTAssertEqual(Set(protection.relations.map(\.square)),Set(["d1","e1","f1","g1"]))
        XCTAssertTrue(protection.relations.allSatisfy{$0.status=="coverage"})
        XCTAssertTrue(try rules.relationships("e2",mode:.attacked).relations.isEmpty)
        XCTAssertEqual(rules.fen,fen);XCTAssertEqual(rules.pgn,pgn)
    }
    func testPinnedDefenderCannotRecaptureButKingCan()throws {
        let rules=try ChessRules(fen:"k3r3/8/8/6b1/8/8/3PR3/4K3 w - - 0 1")
        let report=try rules.relationships("d2",mode:.protected)
        let rook=try XCTUnwrap(report.relations.first{$0.square=="e2"})
        XCTAssertEqual(rook.status,"restricted");XCTAssertFalse(rook.responses.isEmpty);XCTAssertTrue(rook.responses.allSatisfy{!$0.canRecapture})
        XCTAssertEqual(report.relations.first{$0.square=="e1"}?.status,"available")
    }
    func testPinnedAttackIsGeometricOnly()throws {
        let rules=try ChessRules(fen:"4k3/4b3/3P4/8/8/8/8/K3R3 w - - 0 1")
        let attack=try XCTUnwrap(rules.relationships("d6",mode:.attacked).relations.first{$0.square=="e7"})
        XCTAssertTrue(attack.coverage);XCTAssertEqual(attack.status,"restricted")
    }
    func testRecaptureAlongKingFileRemainsLegal()throws {
        let rules=try ChessRules(fen:"k3r3/8/8/8/8/4Q3/4R3/4K3 w - - 0 1")
        let rook=try XCTUnwrap(rules.relationships("e3",mode:.protected).relations.first{$0.square=="e2"})
        XCTAssertEqual(rook.status,"available");XCTAssertTrue(rook.responses.allSatisfy{$0.canRecapture})
    }
    func testDefenderCanBeConditionalOnWhichAttackerCaptures()throws {
        let rules=try ChessRules(fen:"k3q3/3PR3/8/8/6b1/8/8/4K3 w - - 0 1")
        let rook=try XCTUnwrap(rules.relationships("d7",mode:.protected).relations.first{$0.square=="e7"})
        XCTAssertEqual(rook.status,"conditional")
        XCTAssertTrue(rook.responses.contains{$0.attackerSquare=="e8" && $0.canRecapture})
        XCTAssertTrue(rook.responses.contains{$0.attackerSquare=="g4" && !$0.canRecapture})
    }
    func testKingCannotRecaptureOntoAnAttackedSquare()throws {
        let rules=try ChessRules(fen:"k3r3/8/8/8/6b1/8/4P3/4K3 w - - 0 1")
        let king=try XCTUnwrap(rules.relationships("e2",mode:.protected).relations.first{$0.square=="e1"})
        XCTAssertEqual(king.status,"restricted");XCTAssertTrue(king.responses.allSatisfy{!$0.canRecapture})
    }
    func testEnPassantAttackAndRecaptureUseActualLandingSquare()throws {
        let rules=try ChessRules(fen:"4k3/8/8/8/3pP3/8/5P2/4K3 b - e3 0 1"),fen=rules.fen
        let attacker=try XCTUnwrap(rules.relationships("e4",mode:.attacked).relations.first{$0.square=="d4"})
        XCTAssertTrue(attacker.enPassant);XCTAssertEqual(attacker.status,"available");XCTAssertEqual(attacker.responses.first?.destination,"e3")
        let defender=try XCTUnwrap(rules.relationships("e4",mode:.protected).relations.first{$0.square=="f2"})
        XCTAssertFalse(defender.coverage);XCTAssertTrue(defender.responses.contains{$0.destination=="e3" && $0.canRecapture});XCTAssertEqual(rules.fen,fen)
    }
    func testPawnForwardMotionIsNotAnAttack()throws {
        let rules=try ChessRules(fen:"4k3/8/8/3pp3/3P4/8/8/4K3 w - - 0 1")
        XCTAssertEqual(try rules.relationships("d4",mode:.attacked).relations.map(\.square),["e5"])
    }
    func testPartialDiagramAndKingNeverClaimLegalCaptures()throws {
        let rules=try ChessRules()
        let diagram=try rules.relationships("d4",mode:.protected,diagram:["d4":"wp","e3":"wp"])
        XCTAssertFalse(diagram.legalContext);XCTAssertEqual(diagram.relations.map(\.square),["e3"]);XCTAssertEqual(diagram.relations.first?.status,"coverage")
        let king=try ChessRules(fen:"4k3/8/8/8/8/8/4r3/4K3 w - - 0 1").relationships("e1",mode:.attacked)
        XCTAssertEqual(king.piece,"k");XCTAssertEqual(king.relations.first?.status,"coverage");XCTAssertTrue(king.relations.first?.responses.isEmpty==true)
    }
    @MainActor func testInspectionSelectionNeverPlaysLegalDestination()throws {
        let session=try GameSession(engine:nil),fen=session.rules.fen
        try session.select("e2");try session.inspectPiece("e4")
        XCTAssertEqual(session.selected,"e4");XCTAssertEqual(session.rules.fen,fen);XCTAssertTrue(session.rules.history.isEmpty)
    }
    @MainActor func testFinishedGameStillAllowsExplanationOnlySelection()throws {
        let session=try GameSession(engine:nil)
        try session.rules.load("7k/6Q1/5K2/8/8/8/8/8 b - - 0 1")
        XCTAssertTrue(session.rules.over);let fen=session.rules.fen
        try session.select("h8");XCTAssertEqual(session.selected,"h8");XCTAssertEqual(session.rules.fen,fen)
    }
    @MainActor func testControllerToggleSelectionAndDisplayedPositionInvalidation()throws {
        let controller=RelationshipController(),rules=try ChessRules()
        controller.update(board:rules.board,fen:rules.fen,selected:"e2",identity:"game")
        controller.toggle(.protected,selected:"e2");controller.update(board:rules.board,fen:rules.fen,selected:"e2",identity:"game")
        XCTAssertEqual(controller.report?.mode,.protected)
        controller.select("g1");controller.update(board:rules.board,fen:rules.fen,selected:"e2",identity:"game");XCTAssertEqual(controller.report?.square,"g1")
        controller.toggle(.attacked,selected:"g1");controller.update(board:rules.board,fen:rules.fen,selected:"e2",identity:"game");XCTAssertEqual(controller.report?.mode,.attacked)
        controller.update(board:rules.board,fen:rules.fen,selected:"e2",identity:"demonstration");XCTAssertNil(controller.report);XCTAssertNil(controller.mode)
    }
}
