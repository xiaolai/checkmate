import XCTest
@testable import CheckmateNative
@testable import CheckmateCore

/// Regressions for review work that outlives the request or question that started it: a cancelled agent open, a
/// cache write overtaking a deletion, a question answered after the review moved, and file reads that cannot be cancelled.
private func temporaryDirectory()throws -> URL {let url=FileManager.default.temporaryDirectory.appendingPathComponent("race-"+UUID().uuidString);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url}
/// Scripted UCI executable answering every search with the legal 1. e4.
private func fakeEngine()throws -> (URL,URL) {
    let directory=try temporaryDirectory(),path=directory.appendingPathComponent("fake.py")
    let code="""
#!/usr/bin/python3
import sys
for raw in sys.stdin:
 s=raw.strip()
 if s=='uci':print('id name Fake UCI',flush=True);print('option name Skill Level type spin default 20 min 0 max 20',flush=True);print('uciok',flush=True)
 elif s=='isready':print('readyok',flush=True)
 elif s.startswith('go'):print('info depth 4 multipv 1 score cp 10 nodes 10 time 1 pv e2e4',flush=True);print('bestmove e2e4',flush=True)
"""
    try code.write(to:path,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path);return (path,directory)
}
private final class ReadLog:@unchecked Sendable {
    private let lock=NSLock();private var active=0
    private(set) var most=0,files:[String]=[]
    func begin(_ name:String){lock.lock();active+=1;most=max(most,active);files.append(name);lock.unlock()}
    func end(){lock.lock();active-=1;lock.unlock()}
}

@MainActor final class CancelledReviewOpenTests:XCTestCase {
    /// The broker's timeout, cancel and disconnect all cancel the request's task; the detached parse ignores that,
    /// so the open must check it before saving or opening anything.
    func testACancelledOpenNeitherOpensAReviewNorLeavesARecord()async throws {
        let root=try temporaryDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let session=try GameSession(engine:nil),review=ReviewController(),store=ReviewStore(directory:root);session.reviewController=review
        try session.rules.restore("1. e4 e5 *")
        let adapter=ReviewTools(review:review,session:session,store:store,analyzer:ReviewAnalyzer(engine:NativeEngine()))
        let call=Task{try await adapter.call("open_review",args:["source":"current"])};await Task.yield();call.cancel()
        do{_ = try await call.value;XCTFail("a cancelled open reported success")}catch{XCTAssertTrue(error is CancellationError,"\(error)")}
        XCTAssertFalse(review.active,"a cancelled open still opened the review");XCTAssertEqual(try store.list().count,0,"a cancelled open left a library entry")
    }
}

/// Blocks a background thread, never the main actor, until the semaphore is signalled; nil after the ceiling (a broken fixture).
private func signalled(_ semaphore:DispatchSemaphore,within seconds:Double=20)async -> Bool {
    await withCheckedContinuation{done in DispatchQueue.global().async{done.resume(returning:semaphore.wait(timeout:.now()+seconds) == .success)}}
}
/// Every main-actor job queued before this call has run: the main queue is serial and first in, first out.
@MainActor private func drainMainQueue()async {await withCheckedContinuation{done in DispatchQueue.main.async{done.resume()}}}

@MainActor final class ForgottenAnalysisWriteTests:XCTestCase {
    func testForgettingWaitsForACacheWriteAlreadyRunning()async throws {
        let root=try temporaryDirectory(),(path,directory)=try fakeEngine();defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:directory)}
        let analyzer=ReviewAnalyzer(engine:NativeEngine(executable:path),cacheDirectory:root),writing=DispatchSemaphore(value:0),proceed=DispatchSemaphore(value:0)
        // The write holds until the forget has started, so it is in flight when the forget runs, by order, not by delay.
        analyzer.writeCache={cache,evidence,key in writing.signal();proceed.wait();try cache.save(evidence,key:key)}
        let d=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        let analysis=Task{try await analyzer.analyze(document:d,node:1,revision:0)}
        guard await signalled(writing) else{proceed.signal();return XCTFail("fixture: the analysis never wrote its cache")}
        // The forget runs to its first suspension (taking the write it must wait for) before the drain resumes.
        let forgetting=Task{try await analyzer.forgetAnalysis(documentID:d.id)};await drainMainQueue()
        proceed.signal();try await forgetting.value;_ = try await analysis.value
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath:root.path)) ?? [],[],"a write already running restored the deleted review's analysis")
    }
}

@MainActor final class ReviewModalRaceTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    /// Main-actor work (an agent's select_review_position) runs during the modal draft question.
    func testAForkRefusesAPositionMovedDuringTheDraftQuestion()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let document=try PGNImporter.parse(Data("1. e4 e5 2. Nf3 *".utf8))[0]
        model.openReview(document,draft:true);try model.review.select(1);try model.review.beginBranch();try model.review.playBranch("c7c5")
        let history=model.session.rules.history;model.practiceFromReview()
        model.askAboutDraft={_ in try? model.review.select(2);return .discard}
        model.confirmPracticeFork(side:"w",preset:"custom")
        XCTAssertTrue(model.review.active,"the fork started from a position the learner never chose");XCTAssertEqual(model.review.nodeID,2)
        XCTAssertEqual(model.session.rules.history,history);XCTAssertNotNil(model.storageError);XCTAssertFalse(model.practiceForkRequested)
    }
    /// The broker cancels a request on disconnect or timeout while the draft question is still on screen: the learner's
    /// answer must not then open the agent's review, and the record it staged must not stay in the library.
    func testAnOpenCancelledDuringTheDraftQuestionOpensNothing()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let draft=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        model.openReview(draft,draft:true);try model.review.select(1);try model.review.beginBranch();try model.review.playBranch("c7c5")
        let tools=try XCTUnwrap(model.companion.tools.reviewTools);let before=try model.reviewStore.list().count
        var cancel:(()->Void)?,asked=0;model.askAboutDraft={_ in asked+=1;cancel?();return .discard}
        let revision=model.review.revision;let call=Task{try await tools.call("open_review",args:["source":"paste","text":"1. d4 d5 *","expectedReviewRevision":revision])};cancel={call.cancel()}
        do{_ = try await call.value;XCTFail("an open cancelled during the draft question reported success")}catch{XCTAssertTrue(error is CancellationError,"\(error)")}
        XCTAssertEqual(asked,1,"fixture: the draft question was never raised")
        XCTAssertEqual(model.review.document?.id,draft.id,"the cancelled request still replaced the learner's draft");XCTAssertEqual(try model.reviewStore.list().count,before,"the cancelled open left its staged record")
        cancel=nil;model.askAboutDraft={_ in asked+=1;return .cancel};XCTAssertFalse(model.openReview(try PGNImporter.parse(Data("1. c4 *".utf8))[0]))
        XCTAssertEqual(asked,2,"the withdrawn open's \"Don't save\" still let a later exit discard the draft without asking");XCTAssertEqual(model.review.document?.id,draft.id)
    }
    /// A review opened while the progress panel was up must not stay open over the game the import replaces.
    func testProgressInstallRefusesAnOpenReview()throws {
        let model=try NativeModel();defer{model.shutdown()}
        model.openReview(try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]);XCTAssertTrue(model.review.active)
        var state=model.session.state;let skill=state.settings.skill;state.settings.skill=skill==3 ? 4:3
        XCTAssertThrowsError(try model.installImport(state));XCTAssertTrue(model.review.active);XCTAssertEqual(model.session.state.settings.skill,skill)
    }
}

@MainActor final class ReviewFileReaderSerializationTests:XCTestCase {
    func testSlowReadsRunOneAtATimeAndOnlyTheNewestIsDelivered()async throws {
        let reader=ReviewFileReader(),log=ReadLog(),release=DispatchSemaphore(value:0),delivery=expectation(description:"the newest file is delivered");var delivered:[String]=[]
        // The first read holds until every request is made, so the others arrive while it runs, by order, not by delay.
        reader.read={url in log.begin(url.lastPathComponent);if url.lastPathComponent=="a"{release.wait()};log.end();return Data(url.lastPathComponent.utf8)}
        for name in ["a","b","c","d"]{reader.load(URL(fileURLWithPath:"/nonexistent/"+name),deliver:{delivered.append(String(decoding:$0,as:UTF8.self));delivery.fulfill()},failed:{XCTFail("the read failed")})}
        release.signal();await fulfillment(of:[delivery],timeout:20)
        // Delivering d leaves the reader idle with nothing queued, so no later delivery can follow.
        XCTAssertEqual(delivered,["d"]);XCTAssertEqual(log.most,1,"uncancellable reads ran at once");XCTAssertEqual(log.files,["a","d"],"superseded files were still read")
    }
}

/// #9: the broker's own disconnect, not a direct cancel, while the draft question is up during an agent's open_review.
@MainActor final class BrokerDisconnectDuringDraftTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    private func post(_ d:[String:Any],client:String,method:String,args:[String:Any]=[:])async throws -> [String:Any] {
        var r=URLRequest(url:URL(string:(d["url"] as! String)+"/rpc")!);r.httpMethod="POST";r.setValue("Bearer "+(d["token"] as! String),forHTTPHeaderField:"Authorization");r.setValue(client,forHTTPHeaderField:"X-Checkmate-Client")
        r.httpBody=try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"method":method,"args":args]);let (data,_)=try await URLSession.shared.data(for:r);return try JSONSerialization.jsonObject(with:data) as! [String:Any]
    }
    func testABrokerDisconnectDuringTheDraftQuestionOpensNothing()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let draft=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        model.openReview(draft,draft:true);try model.review.select(1);try model.review.beginBranch();try model.review.playBranch("c7c5")
        let broker=model.companion;try broker.enable(role:"coach");defer{broker.disable()}
        let file=broker.directory.appendingPathComponent("connection.json")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath:file.path){try await Task.sleep(nanoseconds:10_000_000)}
        let discovery=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any],client=UUID().uuidString
        _ = try await post(discovery,client:client,method:"get_session");XCTAssertTrue(broker.connected,"fixture: the client holds no lease")
        let before=try model.reviewStore.list().count
        // The learner is still answering when the client's lease ends: release() cancels its in-flight requests.
        var asked=0;model.askAboutDraft={_ in asked+=1;broker.release();return .discard}
        let result=try await post(discovery,client:client,method:"open_review",args:["sessionId":model.session.sessionId,"revision":model.session.revision,"source":"paste","text":"1. d4 d5 *","expectedReviewRevision":model.review.revision])
        XCTAssertEqual(asked,1,"fixture: the draft question was never raised: \(result)")
        XCTAssertEqual((result["error"] as? [String:Any])?["code"] as? String,"CANCELLED","\(result)");XCTAssertFalse(broker.connected)
        XCTAssertEqual(model.review.document?.id,draft.id,"the disconnected agent's review replaced the learner's draft");XCTAssertEqual(try model.reviewStore.list().count,before,"the disconnected open left its staged record")
        model.askAboutDraft={_ in asked+=1;return .cancel};XCTAssertFalse(model.openReview(try PGNImporter.parse(Data("1. c4 *".utf8))[0]))
        XCTAssertEqual(asked,2,"the withdrawn open's \"Don't save\" still let a later exit discard the draft without asking");XCTAssertEqual(model.review.document?.id,draft.id)
    }
}
