import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// B10 review findings RV2-6, RV2-8 and RV2-9: saved reviews survive a changed reader, the same game reopens its
/// record, and imported comment text reaches an agent bounded and labeled as data.
final class B10ReviewStoreTests:XCTestCase {
    private func directory()->URL {FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}
    /// Edits the stored record's JSON in place, standing in for a file written by an older importer or chess.js.
    private func rewrite(_ url:URL,_ edit:(inout [String:Any],inout [[String:Any]])throws->Void)throws -> Data {
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        var stored=try XCTUnwrap(object["document"] as? [String:Any]),nodes=try XCTUnwrap(stored["nodes"] as? [[String:Any]])
        try edit(&object,&nodes);stored["nodes"]=nodes;object["document"]=stored
        let data=try JSONSerialization.data(withJSONObject:object);try data.write(to:url,options:.atomic);return data
    }
    func testATreeFromAnOlderReaderIsReadAgainKeepingCursorAndIdeas()throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let store=ReviewStore(directory:root),document=try PGNImporter.parse(Data("1. e4 e5 2. Nf3 *".utf8))[0];var idea=ReviewBranch(root:1);idea.moves=["c7c5"]
        try store.save(document,cursor:2,branches:[idea])
        let url=store.documentURL(document.id),stale=try rewrite(url){_,nodes in nodes[1]["commentsAfter"]=["written by an older reader"]}
        let reopened=ReviewStore(directory:root),saved=try reopened.load(document.id)
        XCTAssertEqual(saved.document.nodes,document.nodes);XCTAssertEqual(saved.cursor,2);XCTAssertEqual(saved.branches,[idea])
        XCTAssertEqual(try reopened.list().map(\.id),[document.id],"Not quarantined");XCTAssertEqual(reopened.takeQuarantinedCount(),0)
        XCTAssertEqual(try Data(contentsOf:url),stale,"Reading never rewrites the stored file")
    }
    func testIdeasThatNoLongerFitKeepTheFileAndAreReportedOnce()throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let store=ReviewStore(directory:root),document=try PGNImporter.parse(Data("1. e4 *".utf8))[0],other=try PGNImporter.parse(Data("1. d4 *".utf8))[0]
        try store.save(document,cursor:1,branches:[])
        // The stored tree claims 1. d4 and holds an idea legal only there: Bf4 needs the d-pawn moved.
        var idea=ReviewBranch(root:1);idea.moves=["g8f6","c1f4"]
        let replaced=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(other.nodes[1])) as? [String:Any]),branches=try JSONSerialization.jsonObject(with:JSONEncoder().encode([idea]))
        let url=store.documentURL(document.id),stale=try rewrite(url){object,nodes in nodes[1]=replaced;object["branches"]=branches}
        XCTAssertThrowsError(try ReviewStore(directory:root).load(document.id));XCTAssertEqual(try Data(contentsOf:url),stale)
        let reopened=ReviewStore(directory:root);XCTAssertTrue(try reopened.list().isEmpty)
        XCTAssertEqual(reopened.takeQuarantinedCount(),1);XCTAssertEqual(reopened.takeQuarantinedCount(),0,"Reported once")
        let quarantined=try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("Quarantine"),includingPropertiesForKeys:nil)
        XCTAssertEqual(try quarantined.map{try Data(contentsOf:$0)},[stale],"Moved aside byte for byte, never deleted")
    }
    func testASavedRecordIsFoundByItsTextAcrossRestarts()throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let store=ReviewStore(directory:root),first=try PGNImporter.parse(Data("1. e4 *".utf8))[0],second=try PGNImporter.parse(Data("1. d4 *".utf8))[0]
        try store.save(first,cursor:0,branches:[]);try store.save(second,cursor:0,branches:[])
        let reopened=ReviewStore(directory:root)
        XCTAssertEqual(try reopened.savedReview(contentHash:first.contentHash),first.id);XCTAssertEqual(try reopened.savedReview(contentHash:second.contentHash),second.id)
        XCTAssertNil(try reopened.savedReview(contentHash:reviewHash(Data("1. c4 *".utf8))))
        try reopened.delete(first.id);XCTAssertNil(try reopened.savedReview(contentHash:first.contentHash))
    }
}

@MainActor final class B10ReviewAgentTests:XCTestCase {
    private func directory()->URL {FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}
    private func tools(_ root:URL)throws -> (ReviewTools,ReviewController,GameSession,ReviewStore) {
        let session=try GameSession(engine:nil),review=ReviewController(),store=ReviewStore(directory:root);session.reviewController=review
        return (ReviewTools(review:review,session:session,store:store,analyzer:ReviewAnalyzer(engine:NativeEngine(executable:URL(fileURLWithPath:"/missing-engine")))),review,session,store)
    }
    func testTheSameGameOpenedAgainReopensItsRecordWithItsIdeas()async throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let (adapter,review,session,store)=try tools(root),text="[Event \"Agent\"]\n1. e4 e5 *"
        let opened=try await adapter.call("open_review",args:["source":"paste","text":text]) as? [String:Any],id=try XCTUnwrap(opened?["documentId"] as? String)
        var idea=ReviewBranch(root:1);idea.moves=["c7c5"];try store.save(try XCTUnwrap(review.document),cursor:1,branches:[idea])
        // The record already open keeps its live position, which a reload from disk would drop.
        try review.select(2)
        let live=try await adapter.call("open_review",args:["source":"paste","text":text,"expectedReviewRevision":review.revision]) as? [String:Any]
        XCTAssertEqual(live?["documentId"] as? String,id);XCTAssertEqual(live?["nodeId"] as? Int,2)
        review.close(practice:session)
        let again=try await adapter.call("open_review",args:["source":"paste","text":text]) as? [String:Any]
        XCTAssertEqual(again?["documentId"] as? String,id);XCTAssertEqual(review.authoredBranches,[idea]);XCTAssertEqual(review.nodeID,1)
        let (relaunched,_,_,_)=try tools(root)
        let afterRestart=try await relaunched.call("open_review",args:["source":"paste","text":text]) as? [String:Any]
        XCTAssertEqual(afterRestart?["documentId"] as? String,id);XCTAssertEqual(try store.list().count,1,"One record, however often the agent opens it")
    }
    func testImportedCommentsReachTheAgentCappedAndLabeled()async throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let (adapter,review,_,_)=try tools(root),long=String(repeating:"a",count:ReviewTools.maximumCommentScalars+500)
        _ = try await adapter.call("open_review",args:["source":"paste","text":"[Termination \"\(String(repeating:"t",count:1000))\"]\n{\(long)} 1. e4 {short} e5 *"])
        let document=try XCTUnwrap(review.document)
        let result=try await adapter.call("get_review",args:["documentId":document.id.uuidString,"reviewRevision":review.revision,"nodeId":review.nodeID])
        let page=try XCTUnwrap(result as? [String:Any])
        XCTAssertNotNil(page["commentPolicy"] as? String);let moves=try XCTUnwrap(page["moves"] as? [[String:Any]])
        let opening=try XCTUnwrap((moves[0]["commentsBefore"] as? [String])?.first)
        XCTAssertEqual(opening.unicodeScalars.count,ReviewTools.maximumCommentScalars);XCTAssertTrue(opening.hasSuffix("…"));XCTAssertEqual(moves[0]["commentsTruncated"] as? Bool,true)
        XCTAssertEqual(moves[1]["commentsAfter"] as? [String],["short"]);XCTAssertNil(moves[1]["commentsTruncated"])
        XCTAssertEqual((page["termination"] as? String)?.unicodeScalars.count,ReviewPolicy.maximumTitleScalars)
        XCTAssertEqual(document.nodes[0].commentsBefore,[long],"The record itself is unchanged")
    }
    func testAPageOfCommentsHasABoundedTotal()throws {
        let comment=String(repeating:"x",count:ReviewTools.maximumCommentScalars),sans=["e4","e5","Nf3","Nc6","Bb5","a6","Ba4","Nf6","O-O","Be7","Re1","b5"]
        var text="";for (index,san) in sans.enumerated(){text+=(index%2==0 ? "\(index/2+1). ":"")+san+" {\(comment)} "}
        let document=try PGNImporter.parse(Data((text+"*").utf8))[0],nodes=try XCTUnwrap(ReviewTools.agentNodes(document.nodes[...]) as? [[String:Any]])
        XCTAssertEqual(nodes.map{($0["commentsAfter"] as? [String] ?? []).count},[0]+Array(repeating:1,count:10)+[0,0],"Ten full comments fill a page")
        XCTAssertEqual(nodes.compactMap{$0["commentsTruncated"] as? Bool},[true,true])
    }
}
