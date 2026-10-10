import XCTest
@testable import CheckmateCore

final class AuditPGNRegressionTests:XCTestCase {
    func testCRLFSemicolonCommentDoesNotConsumeNextMove()throws {
        let doc=try PGNImporter.parse(Data("[Result \"*\"]\r\n\r\n1. e4 ; explanation\r\ne5 2. Nf3 *\r\n".utf8))[0]
        XCTAssertEqual(doc.mainline.count,3)
        XCTAssertEqual(doc.nodes[1].commentsAfter,[" explanation"])
    }
    func testLeadingVariationCommentsBelongToFirstVariationMove()throws {
        let doc=try PGNImporter.parse(Data("{Root} 1. e4 {Main} ({Alternative} 1. d4 {Queen pawn} d5) e5 *".utf8))[0]
        let alternative=doc.nodes.first{$0.san=="d4"}!
        XCTAssertEqual(alternative.commentsBefore,["Alternative"])
        XCTAssertEqual(doc.nodes[0].commentsBefore,["Root"])
        XCTAssertEqual(doc.nodes[1].commentsAfter,["Main"])
        XCTAssertEqual(alternative.commentsAfter,["Queen pawn"])
    }
    func testSixFieldDrawPGNIsNotMistakenForFEN()throws {
        XCTAssertEqual(try PGNImporter.parse(Data("1. e4 e5 2. Nf3 Nf6 1/2-1/2".utf8))[0].mainline.count,4)
    }
    func testCancellationDuringTokenScan()throws {
        var polls=0
        let text="{ "+String(repeating:"comment ",count:10000)+"} 1. e4 *"
        XCTAssertThrowsError(try PGNImporter.parse(Data(text.utf8),cancelled:{polls+=1;return polls>2}))
        XCTAssertGreaterThan(polls,2)
    }
    func testPawnOnBackRankIsRejected()throws {
        XCTAssertThrowsError(try PGNImporter.parse(Data("7k/8/8/8/8/8/8/P3K3 w - - 0 1".utf8)))
    }
}

@MainActor private final class PendingReviewEngine:EngineService {
    var continuations:[CheckedContinuation<EngineAnalysis,Error>]=[]
    var calls=0
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {
        calls+=1
        return try await withCheckedThrowingContinuation{continuations.append($0)}
    }
    func finish(_ move:String){guard !continuations.isEmpty else{return};continuations.removeFirst().resume(returning:EngineAnalysis(bestMove:move))}
}
@MainActor final class AuditReviewOwnershipTests:XCTestCase {
    func testPendingOpponentCannotCommitWhileReviewOpenAndResumesOnce()async throws {
        let engine=PendingReviewEngine(),session=try GameSession(engine:engine),review=ReviewController()
        try session.rules.move(uci:"e2e4");let before=session.rules.pgn
        session.reply();for _ in 0..<20{await Task.yield()};XCTAssertEqual(engine.calls,1)
        let doc=try PGNImporter.parse(Data("1. d4 *".utf8))[0]
        review.open(doc,practice:session);engine.finish("e7e5")
        for _ in 0..<20{await Task.yield()}
        XCTAssertEqual(session.rules.pgn,before);XCTAssertEqual(engine.calls,1)
        XCTAssertThrowsError(try session.commitBlack("e7e5"))
        review.close(practice:session);for _ in 0..<20{await Task.yield()}
        XCTAssertEqual(engine.calls,2);XCTAssertEqual(session.rules.pgn,before)
        engine.finish("e7e5");for _ in 0..<20{await Task.yield()}
        XCTAssertEqual(session.rules.history.count,2)
    }
    func testDisplayAndExplanationUseSelectedPositionAndExcludeOriginalTextInBranch()throws {
        let session=try GameSession(engine:nil),review=ReviewController(),doc=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        review.open(doc,practice:session);try review.select(1)
        XCTAssertEqual(review.displayFEN,doc.nodes[1].afterFEN)
        try review.beginBranch();try review.playBranch("c7c5")
        let projection=review.projection()
        XCTAssertEqual(projection["original"] as? Bool,false)
        let original=try ReviewExplanation.make(document:doc,node:1)
        XCTAssertFalse((projection["explanation"] as? [String:Any])?["summary"] as? String == original.summary)
    }
    func testSnapshotStatusCountsThreefoldWithoutReplayingEveryNode()throws {
        let d=try PGNImporter.parse(Data("1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 Nf6 4. Ng1 Ng8 *".utf8))[0]
        XCTAssertTrue(try d.status(at:d.mainline.last!).claimableThreefold)
        XCTAssertFalse(try d.status(at:d.mainline.last!).automaticFivefold)
    }
}

final class AuditExportAndQualityTests:XCTestCase {
    func testExportIdeasPreservesOriginalAndPrecedingHistory()throws {
        let original=Data("{keep exactly} 1. e4 e5 (1... c5) 2. Nf3 *\n".utf8)
        let document=try PGNImporter.parse(original)[0];var branch=ReviewBranch(root:1);branch.moves=["c7c5","g1f3"]
        let export=try PGNExporter.withIdeas(document,branches:[branch,branch])
        XCTAssertEqual(export.prefix(original.count),original)
        let imported=try PGNImporter.parse(export);XCTAssertEqual(imported.count,2)
        XCTAssertEqual(try imported[1].history(to:imported[1].mainline.last!),["e2e4","c7c5","g1f3"])
        XCTAssertTrue(imported[1].title.contains("imagined"))
    }
    func testQualityHandlesBlackBoundsMateAndUnstableEvidence()throws {
        let cp:(Int)->AnalysisScore={AnalysisScore(kind:"cp",value:$0)}
        XCTAssertEqual(MoveQuality.compare(best:cp(-200),played:cp(-20),mover:"b",stable:true),"engine-prefers-alternative")
        XCTAssertEqual(MoveQuality.compare(best:cp(200),played:cp(180),mover:"w",stable:true),"near-best")
        XCTAssertEqual(MoveQuality.compare(best:cp(200),played:cp(180),mover:"w",stable:false),"provisional")
        XCTAssertEqual(MoveQuality.compare(best:AnalysisScore(kind:"mate",value:3),played:cp(900),mover:"w",stable:true),"mate-outcome-changed")
        XCTAssertEqual(MoveQuality.compare(best:AnalysisScore(kind:"cp",value:300,bound:"lowerbound"),played:cp(100),mover:"w",stable:true),"provisional")
    }
    func testCancellationTokenAndInvalidSnapshotNode()throws {
        let token=ReviewImportCancellation();token.cancel()
        XCTAssertThrowsError(try PGNImporter.parse(Data("1. e4 *".utf8),cancelled:{token.cancelled}))
        let doc=try PGNImporter.parse(Data("*".utf8))[0]
        XCTAssertThrowsError(try doc.status(at:-1,using:ChessRules()))
    }
}
@MainActor final class AuditReviewAnnotationTests:XCTestCase {
    func testAnnotationsStayScopedAndExpireOnNavigation()throws {
        let review=ReviewController(),session=try GameSession(engine:nil),doc=try PGNImporter.parse(Data("1. e4 *".utf8))[0]
        review.open(doc,practice:session);review.annotate(arrows:[["e2","e4"]],highlights:[Highlight(sq:"e2",kind:"focus")],ttl:1000)
        XCTAssertEqual(review.arrows.count,1);try review.select(1);XCTAssertTrue(review.arrows.isEmpty);XCTAssertTrue(review.highlights.isEmpty)
    }
    func testAutomaticFivefoldCannotForkIntoLiveGame()throws {
        let rules=try ChessRules();for _ in 0..<4{for move in ["g1f3","g8f6","f3g1","f6g8"]{try rules.move(uci:move)}}
        XCTAssertThrowsError(try GameSession(engine:nil).installPracticeFork(rules,side:"w"))
    }
}

final class AuditReviewCacheTests:XCTestCase {
    private func evidence(_ id:UUID=UUID())->ReviewEvidence {ReviewEvidence(schemaVersion:1,documentID:id,documentHash:"document",nodeID:1,historyHash:"history",revision:1,engineVersion:"test",options:[:],budgetMs:500,createdAt:Date(),root:EngineAnalysis(),played:nil,quality:"provisional",provisional:true)}
    func testChecksumCorruptionAndDocumentCleanup()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let cache=ReviewAnalysisCache(directory:directory),value=evidence()
        try cache.save(value,key:"valid");XCTAssertEqual(cache.load("valid")?.documentID,value.documentID)
        try cache.delete(documentID:value.documentID);XCTAssertNil(cache.load("valid"))
        try cache.save(value,key:"broken");let file=directory.appendingPathComponent(reviewHash(Data("broken".utf8))+".json")
        try Data("{broken".utf8).write(to:file);XCTAssertNil(cache.load("broken"));XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testEvictionHonorsBytesAndKeepsMostRecentlyReadEntry()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let cache=ReviewAnalysisCache(directory:directory)
        try cache.save(evidence(),key:"a");try cache.save(evidence(),key:"b");_ = cache.load("a")
        let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey]),bytes=try files.reduce(0){try $0+($1.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)}
        let bounded=ReviewAnalysisCache(directory:directory,maximumBytes:bytes/2+50);try bounded.evict()
        XCTAssertNotNil(bounded.load("a"));XCTAssertNil(bounded.load("b"))
    }
}

final class AuditReviewPersistenceAndImportTests:XCTestCase {
    func testCursorUpdatesDoNotRewriteImmutableRecord()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=ReviewStore(directory:root),document=try PGNImporter.parse(Data("1. e4 *".utf8))[0]
        try store.save(document,cursor:0,branches:[]);let before=try Data(contentsOf:store.documentURL(document.id))
        try store.save(document,cursor:1,branches:[]);XCTAssertEqual(before,try Data(contentsOf:store.documentURL(document.id)))
        XCTAssertEqual(try ReviewStore(directory:root).load(document.id).cursor,1)
        XCTAssertEqual(try ReviewStore(directory:root).list().count,1)
    }
    func testCollectionBoundaryAndStreamingBeyondFormerGlobalTokenCap()throws {
        XCTAssertEqual(try PGNImporter.parse(Data(String(repeating:"*\n",count:1000).utf8)).count,1000)
        XCTAssertThrowsError(try PGNImporter.parse(Data(String(repeating:"*\n",count:1001).utf8)))
        let data=Data(("1. e4 "+String(repeating:"$1 ",count:200001)+"*").utf8)
        XCTAssertEqual(try PGNImporter.parse(data)[0].nodes[1].nags.count,200001)
    }
    func testPresetRoundTripPreservesCustomConfiguration() {
        var settings=AppSettings(raw:["skill":7,"opponentMode":"elo","opponentElo":1800])
        settings.opponentPreset="gentle";XCTAssertEqual(OpponentProfile.settings(settings),.skill(0))
        settings.opponentPreset="club";XCTAssertEqual(OpponentProfile.settings(settings),.skill(10))
        settings.opponentPreset="custom";XCTAssertEqual(OpponentProfile.settings(settings),.elo(1800));XCTAssertEqual(settings.skill,7)
    }
}
@MainActor final class AuditReviewVariationTests:XCTestCase {
    func testTransportFollowsRecordedVariation()throws {
        let doc=try PGNImporter.parse(Data("1. e4 e5 (1... c5 2. Nf3 d6) 2. Nf3 *".utf8))[0],review=ReviewController(),session=try GameSession(engine:nil)
        review.open(doc,practice:session);let alternate=doc.nodes.first{$0.san=="c5"}!
        try review.select(alternate.id);review.step(1);XCTAssertEqual(doc.nodes[review.nodeID].san,"Nf3")
        XCTAssertEqual(doc.nodes[review.nodeID].parent,alternate.id);review.step(-1);XCTAssertEqual(review.nodeID,alternate.id)
        review.last();XCTAssertEqual(doc.nodes[review.nodeID].san,"d6");review.first();XCTAssertEqual(review.nodeID,0)
    }
}

@MainActor final class AuditReviewSavedScopeTests:XCTestCase {
    func testSavedMCPReviewRestoresCursorAndIdeasWithoutErasingThem()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=ReviewStore(directory:root),document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        var branch=ReviewBranch(root:1);branch.moves=["c7c5","g1f3"];try store.save(document,cursor:2,branches:[branch])
        let review=ReviewController(),session=try GameSession(engine:nil),tools=ReviewTools(review:review,session:session,store:store,analyzer:ReviewAnalyzer(engine:NativeEngine()))
        _ = try await tools.call("open_review",args:["source":"saved","gameId":document.id.uuidString])
        XCTAssertEqual(review.nodeID,2);XCTAssertEqual(review.authoredBranches,[branch]);XCTAssertEqual(try store.load(document.id).branches,[branch])
        try review.openSavedBranch(branch.id);review.step(1);XCTAssertEqual(review.board["c5"],"bp")
        try review.playBranch("b1c3");XCTAssertEqual(review.branchesForSaving.count,1);XCTAssertEqual(review.branchesForSaving[0].moves,["c7c5","b1c3"])
        try store.save(document,cursor:review.nodeID,branches:review.branchesForSaving);XCTAssertEqual(try store.load(document.id).branches[0].moves,["c7c5","b1c3"])
        review.clearBranch();XCTAssertEqual(review.nodeID,1)
        let identity:[String:Any]=["documentId":document.id.uuidString,"reviewRevision":review.revision,"nodeId":review.nodeID,"offset":1]
        do{_ = try await tools.call("get_review",args:identity);XCTFail("Paged calls need immutable record identity")}catch{}
        var valid=identity;valid["pageIdentity"]=document.contentHash;_ = try await tools.call("get_review",args:valid)
    }
}

@MainActor final class AuditBeginnerSafetyTests:XCTestCase {
    func testPersistedStreakMigrationAndCapUsingMeasuredCandidates()async throws {
        let old=try JSONDecoder().decode(PracticeState.self,from:Data("{\"pgn\":\"\",\"fen\":\"\",\"previousGame\":\"\"}".utf8));XCTAssertEqual(old.beginnerSevereStreak,0)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let script=root.appendingPathComponent("fake.py")
        let code="""
#!/usr/bin/python3
import sys
for raw in sys.stdin:
 s=raw.strip()
 if s=='uci':
  print('id name Candidate Safety Fake',flush=True)
  print('option name MultiPV type spin default 1 min 1 max 16',flush=True)
  print('uciok',flush=True)
 elif s=='isready':print('readyok',flush=True)
 elif s.startswith('go'):
  moves=s.split('searchmoves ')[1].split() if 'searchmoves ' in s else ['e2e4','d2d4','g1f3','b1c3','a2a3','h2h3']
  for i,move in enumerate(moves):print(f'info depth 17 multipv {i+1} score cp {800 if move=="e2e4" else 400} pv {move}',flush=True)
  print('bestmove '+moves[0],flush=True)
"""
        try code.write(to:script,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:script.path)
        let engine=NativeEngine(executable:script),rules=try ChessRules()
        let capped=try await BeginnerOpponent.choose(rules:rules,engine:engine,seed:42,severeStreak:BeginnerPolicy.maximumConsecutiveSevereErrors)
        XCTAssertEqual(capped.bestMove,"e2e4");XCTAssertEqual(capped.opponentDecision?.policyVersion,3);XCTAssertEqual(capped.opponentDecision?.estimatedRegretCp,0);XCTAssertEqual(capped.opponentDecision?.fallback,false)
        XCTAssertEqual(BeginnerOpponent.nextSevereStreak(capped,mover:"w",current:2),0)
        let repeated=try await BeginnerOpponent.choose(rules:rules,engine:engine,seed:42,severeStreak:2);XCTAssertEqual(repeated.bestMove,capped.bestMove)
        var value=PracticeState();value.beginnerSevereStreak=2;XCTAssertEqual(try JSONDecoder().decode(PracticeState.self,from:JSONEncoder().encode(value)).beginnerSevereStreak,2)
    }
}

@MainActor final class AuditReviewLifecycleTests:XCTestCase {
    func testResetDropsPriorDocumentBatchState()throws {
        let analyzer=ReviewAnalyzer(engine:NativeEngine(executable:URL(fileURLWithPath:"/missing-engine")))
        let document=try PGNImporter.parse(Data("1. e4 e5 2. Nf3 *".utf8))[0]
        analyzer.startBatch(document);XCTAssertEqual(analyzer.batchDocument,document.id);XCTAssertEqual(analyzer.total,3)
        analyzer.reset();XCTAssertNil(analyzer.batchDocument);XCTAssertEqual(analyzer.total,0);XCTAssertEqual(analyzer.completed,0);XCTAssertTrue(analyzer.moments.isEmpty);XCTAssertEqual(analyzer.batchStatus,"idle")
    }
    func testBranchNavigationInvalidatesPendingAnalysis()throws {
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],review=ReviewController(),session=try GameSession(engine:nil)
        review.open(document,practice:session);try review.beginBranch()
        review.analyze(using:ReviewAnalyzer(engine:NativeEngine(executable:URL(fileURLWithPath:"/missing-engine"))))
        XCTAssertEqual(review.analysisStatus,"pending");try review.playBranch("d2d4")
        XCTAssertEqual(review.analysisStatus,"idle");XCTAssertNil(review.evidence)
        review.analyze(using:ReviewAnalyzer(engine:NativeEngine(executable:URL(fileURLWithPath:"/missing-engine"))))
        review.clearBranch();XCTAssertEqual(review.analysisStatus,"idle");XCTAssertNil(review.evidence)
    }
    func testRepeatedPreviewsDeduplicateAndRestorationPublishesIdeas()throws {
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],review=ReviewController(),session=try GameSession(engine:nil)
        review.open(document,practice:session)
        for _ in 0..<102 {try review.previewLine(["d2d4"]);review.clearBranch()}
        XCTAssertEqual(review.authoredBranches.count,1)
        let saved=review.authoredBranches;review.close(practice:session);review.open(document,practice:session)
        var observed:[ReviewBranch]=[];review.onEvent={observed=review.branchesForSaving}
        try review.restoreSaved(cursor:1,branches:saved);XCTAssertEqual(observed,saved)
        var many:[ReviewBranch]=[]
        for root in 0..<102 {var idea=ReviewBranch(root:root);idea.moves=["d2d4"];many.append(idea)}
        try review.restoreSaved(cursor:1,branches:many);XCTAssertEqual(review.branchesForSaving.count,ReviewPolicy.maximumBranches)
    }
}
