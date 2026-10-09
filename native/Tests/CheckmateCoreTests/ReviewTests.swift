import XCTest
@testable import CheckmateCore
final class GameDocumentTests:XCTestCase {
    func testTreeAndOriginalRoundTrip()throws {
        let source="[Event \"Tree\"]\n[Result \"*\"]\n\n{before} 1. e4 {after} $1 (1. d4 d5 (1... Nf6)) e5 *"
        let document=try PGNImporter.parse(Data(source.utf8))[0]
        XCTAssertEqual(document.mainline.count,2)
        XCTAssertEqual(document.nodes.count,6)
        XCTAssertEqual(document.nodes[1].commentsAfter,["after"])
        XCTAssertEqual(document.nodes[1].nags,[1])
        XCTAssertEqual(document.nodes[0].commentsBefore,["before"])
        XCTAssertEqual(PGNExporter.original(document),Data(source.utf8))
        let restored=try JSONDecoder().decode(GameDocument.self,from:JSONEncoder().encode(document))
        XCTAssertEqual(restored,document)
        try restored.validate()
    }
    func testPolicyFailures()throws {
        for source in ["", "[Variant \"Chess960\"]\n*", "[Result \"1-0\"]\n1. e4 0-1", "1. e5 *", "1. e4 (1. d4"] {
            XCTAssertThrowsError(try PGNImporter.parse(Data(source.utf8)),source)
        }
    }
    func testMultipleAndBlackStart()throws {
        let source="[Event \"A\"]\n*\n\n[Event \"B\"]\n[SetUp \"1\"]\n[FEN \"8/8/8/8/8/8/1k6/5K2 b - - 0 12\"]\n12... Kc3 *"
        let docs=try PGNImporter.parse(Data(source.utf8));XCTAssertEqual(docs.count,2)
        XCTAssertEqual(docs[1].nodes[1].side,"b");XCTAssertEqual(docs[1].nodes[1].fullmove,12)
    }
    func testHistoryDrawPolicy()throws {
        let doc=try PGNImporter.parse(Data("1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 Nf6 4. Ng1 Ng8 *".utf8))[0]
        let status=try doc.status(at:doc.mainline.last!)
        XCTAssertTrue(status.claimableThreefold);XCTAssertFalse(status.automaticFivefold)
        XCTAssertFalse(status.terminal)
    }
}
@MainActor final class ReviewSessionTests:XCTestCase {
    func testReviewNeverChangesPracticeAndBranchRestores()throws {
        let session=try GameSession(engine:nil);try session.rules.move(uci:"e2e4")
        session.emit(save:true);let saved=session.state.practice.pgn,fen=session.rules.fen
        let controller=ReviewController();let doc=try PGNImporter.parse(Data("1. d4 d5 *".utf8))[0]
        controller.open(doc,practice:session);try controller.select(doc.mainline[0]);try controller.beginBranch();try controller.playBranch("g8f6");controller.clearBranch()
        XCTAssertEqual(controller.nodeID,doc.mainline[0]);XCTAssertEqual(session.rules.fen,fen);XCTAssertEqual(session.state.practice.pgn,saved)
        XCTAssertTrue(session.reviewSuspended);controller.close(practice:session);XCTAssertFalse(session.reviewSuspended)
    }
}
