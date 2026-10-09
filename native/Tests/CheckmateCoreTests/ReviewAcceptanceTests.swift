import XCTest
@testable import CheckmateCore
final class PGNImportTests:XCTestCase {
    func testBOMCRLFRAVAndEscapes()throws {let data=Data("\u{feff}[Event \"Café \\\"quoted\\\"\"]\r\n1. e4 $1 (1. d4 d5) e5 *\r\n".utf8),doc=try PGNImporter.parse(data)[0];XCTAssertEqual(doc.original,data);XCTAssertEqual(doc.headers[0].value,"Café \"quoted\"");XCTAssertEqual(doc.mainline.count,2);try doc.validate()}
    func testByteLimitAndCancellation()throws {XCTAssertThrowsError(try PGNImporter.parse(Data(repeating:32,count:ReviewPolicy.maximumBytes+1)));XCTAssertThrowsError(try PGNImporter.parse(Data("1. e4 *".utf8),cancelled:{true}))}
    func testDepthAndMainlineLimits()throws {let nested="1. e4 "+String(repeating:"(1. d4 ",count:33)+String(repeating:")",count:33)+" *";XCTAssertThrowsError(try PGNImporter.parse(Data(nested.utf8)));var long="";for i in 0..<501{long+="\(i*2+1). Nf3 Nf6 \(i*2+2). Ng1 Ng8 "};long+="*";XCTAssertThrowsError(try PGNImporter.parse(Data(long.utf8)))}
    func testFENSanity()throws {for fen in ["4k3/8/8/8/8/8/8/4K3 w K - 0 1","8/8/8/8/8/8/4k3/4K3 w - - 0 1","4k3/8/8/8/8/8/8/4K3 w - e6 0 1"]{XCTAssertThrowsError(try PGNImporter.parse(Data(fen.utf8)))}}
}
@MainActor final class ReviewCompanionTests:XCTestCase {
    func testScopedToolsRejectStaleAndOldPractice()async throws {let session=try GameSession(engine:nil),review=ReviewController(),root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)};let tools=try CompanionTools(session:session),adapter=ReviewTools(review:review,session:session,store:ReviewStore(directory:root),analyzer:ReviewAnalyzer(engine:NativeEngine()));tools.reviewTools=adapter;session.reviewController=review;session.setConnection(enabled:true,role:"coach",lease:"test");let observed:[String:Any]=["sessionId":session.sessionId,"revision":session.revision,"source":"paste","text":"1. e4 e5 *"];_ = try await tools.call("open_review",args:observed,lease:"test");var args:[String:Any]=["sessionId":session.sessionId,"revision":session.revision,"documentId":review.document!.id.uuidString,"reviewRevision":review.revision,"nodeId":review.nodeID];let result=try await tools.call("get_review",args:args,lease:"test") as! [String:Any];XCTAssertEqual((result["moves"] as? [Any])?.count,3);args["reviewRevision"] = -1;do{_ = try await tools.call("get_review",args:args,lease:"test");XCTFail()}catch{};do{_ = try await tools.call("get_legal_moves",args:["sessionId":session.sessionId,"revision":session.revision],lease:"test");XCTFail()}catch{};XCTAssertEqual(session.rules.history,[])}
}
@MainActor final class ReviewVoiceTests:XCTestCase {
    func testBoundedContextAndGroundedCues()throws {let s=try GameSession(engine:nil),r=ReviewController(),d=try PGNImporter.parse(Data("[PrivateTag \"Do not upload\"]\n1. a3 *".utf8))[0];r.open(d,practice:s);try r.select(1);let text=String(decoding:try JSONSerialization.data(withJSONObject:ReviewVoiceScript.context(review:r)),as:UTF8.self);XCTAssertFalse(text.contains("Do not upload"));let explanation=r.explanation!,segments=try JSONDecoder().decode([SpeechSegment].self,from:JSONSerialization.data(withJSONObject:ReviewVoiceScript.segments(explanation)));XCTAssertNoThrow(try ReviewVoiceScript.validate(segments,explanation:explanation));let bad=try JSONDecoder().decode([SpeechSegment].self,from:Data("[{\"text\":\"The pawn forces mate\",\"squares\":[\"a3\"],\"kind\":\"focus\"}]".utf8));XCTAssertThrowsError(try ReviewVoiceScript.validate(bad,explanation:explanation))}
}
@MainActor final class ReviewBranchTests:XCTestCase {
    func testIllegalPreviewIsAtomicAndPlyReplay()throws {let s=try GameSession(engine:nil),r=ReviewController(),d=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0];r.open(d,practice:s);XCTAssertThrowsError(try r.previewLine(["e2e4","e7e4"]));XCTAssertNil(r.branch);try r.previewLine(["e2e4","e7e5"]);r.seekBranch(0);XCTAssertEqual(r.displayFEN,d.startingFEN);r.step(1);XCTAssertEqual(r.branchPly,1);r.clearBranch();XCTAssertEqual(r.nodeID,0);XCTAssertEqual(r.authoredBranches.count,1)}
    func testInvalidPromotionDoesNotCrash()throws {let s=try GameSession(engine:nil),r=ReviewController(),d=try PGNImporter.parse(Data("8/P7/8/8/8/6k1/8/6K1 w - - 0 1".utf8))[0];r.open(d,practice:s);try r.beginBranch();try r.selectSquare("a7");XCTAssertThrowsError(try r.selectSquare("a8",promotion:"k"));try r.selectSquare("a8",promotion:"n");XCTAssertEqual(r.board["a8"],"wn")}
}
@MainActor final class ReviewAutomaticBranchTests:XCTestCase {
    func testAutomaticDrawImaginedPositionSkipsEngine()async throws {
        let document=try PGNImporter.parse(Data("7k/8/8/8/8/8/R7/K7 w - - 150 76".utf8))[0]
        XCTAssertTrue(try document.status(at:0).automaticSeventyFiveMove)
        let missing=URL(fileURLWithPath:"/tmp/checkmate-no-such-review-engine"),analyzer=ReviewAnalyzer(engine:NativeEngine(executable:missing))
        let result=try await analyzer.analyzeBranch(document:document,root:0,moves:[],revision:1)
        XCTAssertNil(result.root.bestMove);XCTAssertTrue(result.root.lines.isEmpty)
    }
}
