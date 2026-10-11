import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class GameDocumentTests:XCTestCase {
    func testUnknownPGNMetadataUsesReadableTitles()throws {
        let data=Data("[Event \"?\"]\n[White \"?\"]\n[Black \"?\"]\n1. e4 *".utf8)
        XCTAssertEqual(try PGNImporter.parse(data,provenance:"Current game")[0].title,"Current game")
        XCTAssertEqual(try PGNImporter.parse(data)[0].title,"Imported game")
        XCTAssertEqual(try PGNImporter.parse(Data("[Event \" \" ]\n[White \"Alice\"]\n[Black \"Bob\"]\n1. d4 *".utf8))[0].title,"Alice – Bob")
    }
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

/// chess.js reads FEN move counters with `parseInt`, so `1.`, `1x` or `1e3` pass its validation; the importer
/// must reject them instead of trusting them (a forced `Int(...)!` used to crash the app on these inputs).
final class FENCounterTests:XCTestCase {
    private let board="8/8/8/4k3/8/8/8/4K3 w - - "
    func testMalformedMoveCountersAreRejectedNotTrusted(){
        for counters in ["0 1.","0 1,","0 1)","0 1e3","0 1x","0 1_000","0 99999999999999999999","0 0","x 1","1e3 1"] {
            XCTAssertThrowsError(try PGNImporter.parse(Data((board+counters).utf8)),counters)
            XCTAssertThrowsError(try PGNImporter.parse(Data("[SetUp \"1\"]\n[FEN \"\(board+counters)\"]\n*".utf8)),counters)
        }
        // Inside a FEN tag a zero-width space is part of the counter; a pasted FEN is trimmed like other whitespace.
        XCTAssertThrowsError(try PGNImporter.parse(Data("[SetUp \"1\"]\n[FEN \"\(board)0 1\u{200B}\"]\n*".utf8)))
        XCTAssertEqual(try PGNImporter.parse(Data((board+"0 1\u{200B}").utf8))[0].nodes[0].fullmove,1)
    }
    func testPlainMoveCountersAreKept()throws {
        XCTAssertEqual(try PGNImporter.parse(Data((board+"3 42").utf8))[0].nodes[0].fullmove,42)
        XCTAssertEqual(try PGNImporter.validateFEN(board+"0 999999"),999999)
    }
}

@MainActor final class FENCounterMCPTests:XCTestCase {
    func testMCPPasteOfMalformedFENIsRejectedWithoutOpeningOrSaving()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=ReviewStore(directory:root),review=ReviewController(),session=try GameSession(engine:nil),tools=ReviewTools(review:review,session:session,store:store,analyzer:ReviewAnalyzer(engine:NativeEngine()))
        do{_ = try await tools.call("open_review",args:["source":"paste","text":"8/8/8/4k3/8/8/8/4K3 w - - 0 1."]);XCTFail("A malformed FEN must be rejected")}catch{}
        XCTAssertFalse(review.active);XCTAssertTrue(try store.list().isEmpty)
    }
}

/// Real-world PGN and FEN that used to be rejected outright now import; a bad game in a collection is skipped
/// and reported instead of failing the whole file.
final class PGNCompatibilityTests:XCTestCase {
    func testLatin1PGNImports()throws {
        let data=try XCTUnwrap("[White \"Müller\"]\n1. e4 e5 *".data(using:.isoLatin1));XCTAssertNil(String(data:data,encoding:.utf8))
        XCTAssertEqual(try PGNImporter.parse(data)[0].headers.first{$0.name=="White"}?.value,"Müller")
    }
    func testMoveListWithoutResultIsUnfinishedOrTakesItsHeader()throws {
        XCTAssertEqual(try PGNImporter.parse(Data("1. e4 e5 2. Nf3".utf8))[0].result,"*")
        XCTAssertEqual(try PGNImporter.parse(Data("[Result \"1-0\"]\n1. e4 e5 2. Nf3".utf8))[0].result,"1-0")
    }
    func testCommentsAroundGamesAreAccepted()throws {
        let docs=try PGNImporter.parse(Data("{Annotated collection}\n[Event \"A\"]\n1. e4 *\n{Between games}\n[Event \"B\"]\n1. d4 *\n{The end}".utf8))
        XCTAssertEqual(docs.count,2);XCTAssertEqual(docs[0].nodes[0].commentsBefore,["Annotated collection"])
    }
    func testShortFENAndCommonExportVariants()throws {
        XCTAssertEqual(try PGNImporter.parse(Data("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -".utf8))[0].nodes[0].fullmove,1)
        XCTAssertNoThrow(try PGNImporter.parse(Data("[Variant \"From Position\"]\n[FEN \"8/8/8/4k3/8/8/8/4K2R w K - 0 1\"]\n1. Rh5+ *".utf8)))
        XCTAssertNoThrow(try PGNImporter.parse(Data("[FEN \"8/8/8/4k3/8/8/8/4K2R w K - 0 1\"]\n1. O-O *".utf8)),"A FEN header alone is a custom start")
        XCTAssertEqual(try PGNImporter.parse(Data("[SetUp \"1\"]\n[FEN \"7k/4P3/8/8/8/8/8/K7 w - - 0 1\"]\n1. e8Q+ *".utf8))[0].nodes[1].uci,"e7e8q")
        XCTAssertEqual(try PGNImporter.parse(Data("1. e4 e5 1/2".utf8))[0].result,"1/2-1/2")
        XCTAssertThrowsError(try PGNImporter.parse(Data("[SetUp \"0\"]\n[FEN \"8/8/8/4k3/8/8/8/4K3 w - - 0 1\"]\n*".utf8)),"SetUp 0 with a FEN still conflicts")
    }
    func testABadGameIsSkippedAndReported()throws {
        let report=try PGNImporter.parseReport(Data("[Event \"Good\"]\n1. e4 *\n\n[Event \"Bad\"]\n1. e5 *\n\n[Event \"Also good\"]\n1. d4 *".utf8))
        XCTAssertEqual(report.documents.map(\.title),["Good","Also good"]);XCTAssertEqual(report.skipped.count,1);XCTAssertEqual(report.skipped[0].record,2)
        XCTAssertThrowsError(try PGNImporter.parse(Data("1. e5 *".utf8)),"A file with no readable game still fails")
    }
}
