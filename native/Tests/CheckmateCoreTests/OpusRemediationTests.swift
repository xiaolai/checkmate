import XCTest
@testable import CheckmateCore

/// Regressions for the 2026-10-09 post-acceptance audit (Opus remediation).
@MainActor private final class RecordingPendingEngine:EngineService {
    var continuations:[CheckedContinuation<EngineAnalysis,Error>]=[]
    var skills:[Int]=[]
    func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {skills.append(skill);return try await withCheckedThrowingContinuation{continuations.append($0)}}
    func finish(at index:Int,_ move:String){continuations[index].resume(returning:EngineAnalysis(bestMove:move))}
}
private func temporaryDirectory()throws -> URL {let url=FileManager.default.temporaryDirectory.appendingPathComponent("opus-"+UUID().uuidString);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url}
/// Scripted UCI executable: records position commands; optionally exits on go (failure) or delays.
private func fakeEngine(failOnGo:Bool=false,delay:Double=0)throws -> (URL,URL) {
    let directory=try temporaryDirectory(),path=directory.appendingPathComponent("fake.py")
    let code="""
#!/usr/bin/python3
import sys,time,os
here=os.path.dirname(__file__)
for raw in sys.stdin:
 s=raw.strip()
 if s=='uci':print('id name Fake UCI',flush=True);print('option name Skill Level type spin default 20 min 0 max 20',flush=True);print('uciok',flush=True)
 elif s=='isready':print('readyok',flush=True)
 elif s.startswith('position'):
  with open(os.path.join(here,'positions'),'a') as f:f.write(s+'\\n')
 elif s.startswith('go'):
  if \(failOnGo ? "True":"False"):sys.exit(0)
  time.sleep(\(delay))
  print('info depth 4 multipv 1 score cp 10 nodes 10 time 1 pv a7a6',flush=True)
  print('bestmove a7a6',flush=True)
"""
    try code.write(to:path,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path);return (path,directory)
}

final class OpusImportMessageTests:XCTestCase {
    func testLaterRecordErrorsReportTheirOwnRecordNumber()throws {
        do{_ = try PGNImporter.parse(Data("[Event \"A\"]\n1. e4 *\n\n[Event \"B\"]\n1. e9 *".utf8));XCTFail("Invalid second record accepted")}
        catch let error as ReviewImportError{XCTAssertEqual(error.record,2)}
        // A lexer failure in the second record's first token must not be attributed to record 1.
        do{_ = try PGNImporter.parse(Data("[Event \"A\"]\n1. e4 *\n\n[Event \"B".utf8));XCTFail("Unclosed header accepted")}
        catch let error as ReviewImportError{XCTAssertEqual(error.record,2,error.errorDescription ?? "")}
    }
    func testUserFacingMessagesAreReadableAndPathFree(){
        let importError=ReviewImportError(record:3,token:7,reason:"Illegal or ambiguous SAN: e9.")
        XCTAssertEqual(userFacingMessage(importError,fallback:"x"),"Record 3, token 7: Illegal or ambiguous SAN: e9.")
        XCTAssertFalse(String(describing:importError).hasPrefix("Record"),"Raw struct description is not user text")
        XCTAssertEqual(userFacingMessage(CheckmateError.invalid("File exceeds 16 MiB."),fallback:"x"),"File exceeds 16 MiB.")
        let foundation=NSError(domain:NSCocoaErrorDomain,code:260,userInfo:[NSFilePathErrorKey:"/Users/private/secret.pgn",NSLocalizedDescriptionKey:"The file “secret.pgn” couldn’t be opened at /Users/private/secret.pgn."])
        XCTAssertEqual(userFacingMessage(foundation,fallback:"The file could not be read."),"The file could not be read.")
    }
    func testLaterRecordSemanticErrorKeepsItsRecordNumber()throws {
        do{_ = try PGNImporter.parse(Data("[Event \"A\"]\n1. e4 *\n\n[Event \"B\"]\n1. d4 d5 ( 1-0 ) *".utf8));XCTFail("Result inside variation accepted")}
        catch let error as ReviewImportError{XCTAssertEqual(error.record,2)}
    }
}

@MainActor final class OpusReviewOwnershipTests:XCTestCase {
    private func tools(_ root:URL)throws -> (ReviewTools,ReviewController,GameSession,ReviewStore) {let session=try GameSession(engine:nil),review=ReviewController(),store=ReviewStore(directory:root);session.reviewController=review;return (ReviewTools(review:review,session:session,store:store,analyzer:ReviewAnalyzer(engine:NativeEngine())),review,session,store)}
    func testMCPOpenReviewRejectsActivityChangeDuringParseWithoutOrphan()async throws {
        let root=try temporaryDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let (adapter,review,_,store)=try tools(root);var reads=0,opened=0
        adapter.activityGeneration={reads+=1;return reads==1 ? 7:8};adapter.onOpen={_ in opened+=1}
        do{_ = try await adapter.call("open_review",args:["source":"paste","text":"[Event \"Agent\"]\n1. e4 *"]);XCTFail("Stale agent open accepted")}catch let failure as ProtocolFailure{XCTAssertEqual(failure.code,"STALE_REVIEW")}
        XCTAssertEqual(opened,0);XCTAssertFalse(review.active);XCTAssertEqual(try store.list().count,0,"Rejected open left a library entry")
    }
    func testMCPOpenReviewRejectsActivityChangeDuringSaveAndRemovesStagedEntry()async throws {
        let root=try temporaryDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let (adapter,review,_,store)=try tools(root);var reads=0,opened=0
        adapter.activityGeneration={reads+=1;return reads<=2 ? 7:8};adapter.onOpen={_ in opened+=1}
        do{_ = try await adapter.call("open_review",args:["source":"current"]);XCTFail("Stale agent open accepted")}catch let failure as ProtocolFailure{XCTAssertEqual(failure.code,"STALE_REVIEW")}
        XCTAssertEqual(opened,0);XCTAssertFalse(review.active);XCTAssertEqual(try store.list().count,0)
    }
    func testMCPOpenReviewStillOpensWhenActivityUnchanged()async throws {
        let root=try temporaryDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let (adapter,review,_,store)=try tools(root);adapter.activityGeneration={3}
        _ = try await adapter.call("open_review",args:["source":"paste","text":"[Event \"Agent\"]\n1. e4 *"])
        XCTAssertTrue(review.active);XCTAssertEqual(try store.list().count,1)
    }
    func testReviewJobsAreCancelledWhenTheReviewCloses()async throws {
        let root=try temporaryDirectory(),(path,directory)=try fakeEngine(delay:5);defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:directory)}
        let session=try GameSession(engine:nil),review=ReviewController();session.reviewController=review
        let adapter=ReviewTools(review:review,session:session,store:ReviewStore(directory:root),analyzer:ReviewAnalyzer(engine:NativeEngine(executable:path)))
        _ = try await adapter.call("open_review",args:["source":"paste","text":"1. e4 e5 *"]);try review.select(1)
        let identity:[String:Any]=["documentId":review.document!.id.uuidString,"reviewRevision":review.revision,"nodeId":review.nodeID]
        let job=try await adapter.call("analyze_review",args:identity) as! [String:Any];XCTAssertEqual(job["status"] as? String,"pending")
        XCTAssertEqual(adapter.jobStatuses,["pending"])
        review.close(practice:session,resumePractice:false)
        XCTAssertEqual(adapter.jobStatuses,["cancelled"],"An MCP analysis job outlived its review")
        let start=Date();while adapter.runningJobTasks>0,Date().timeIntervalSince(start)<2{try await Task.sleep(for:.milliseconds(20))}
        XCTAssertEqual(adapter.runningJobTasks,0,"Cancelled job kept its engine search alive")
    }
}

@MainActor final class OpusPracticeForkTests:XCTestCase {
    /// 1. f3 e5 2. g4 Qh4#: the selected move is checkmate but its parent is playable.
    private func mateReview()throws -> (GameDocument,ReviewController,GameSession) {
        let d=try PGNImporter.parse(Data("1. f3 e5 2. g4 Qh4# 0-1".utf8))[0],session=try GameSession(engine:nil),review=ReviewController();session.reviewController=review
        review.open(d,practice:session);try review.select(d.mainline.last!);return (d,review,session)
    }
    func testParentRootPreviewAtPlyZeroForksDisplayedParentNotSelectedMove()throws {
        let (d,review,session)=try mateReview(),parent=d.nodes[d.mainline.last!].parent!
        XCTAssertTrue(try d.status(at:review.nodeID).terminal);XCTAssertFalse(review.practiceForkAvailable,"Checkmate original position must stay unavailable")
        try review.previewLine(["d8h4"],fromNode:parent);review.seekBranch(0)
        XCTAssertEqual(review.displayFEN,d.nodes[parent].afterFEN)
        XCTAssertTrue(review.practiceForkAvailable,"Displayed parent is playable even though the selected move mates")
        let fork=try review.practiceForkRules();XCTAssertEqual(fork.fen,d.nodes[parent].afterFEN);XCTAssertEqual(fork.history,["f3","e5","g4"])
        try session.installPracticeFork(fork,side:"b");XCTAssertEqual(session.rules.history,["f3","e5","g4"]);XCTAssertEqual(session.rules.turn,"b")
    }
    func testParentRootPreviewAtLaterPlyReplaysOnTheParentAndDetectsTerminalLine()throws {
        let (d,review,_)=try mateReview(),parent=d.nodes[d.mainline.last!].parent!
        try review.previewLine(["b8c6","b1c3"],fromNode:parent);review.seekBranch(1)
        let fork=try review.practiceForkRules();XCTAssertEqual(fork.history,["f3","e5","g4","Nc6"]);XCTAssertEqual(fork.fen,review.displayFEN);XCTAssertTrue(review.practiceForkAvailable)
        try review.previewLine(["d8h4"],fromNode:parent);review.seekBranch(1)
        XCTAssertTrue(try review.practiceForkRules().checkmate);XCTAssertFalse(review.practiceForkAvailable,"Imagined mate cannot start practice")
    }
    func testMCPPracticeAvailabilityUsesDisplayedImaginedPosition()async throws {
        let root=try temporaryDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let session=try GameSession(engine:nil),review=ReviewController();session.reviewController=review
        let adapter=ReviewTools(review:review,session:session,store:ReviewStore(directory:root),analyzer:ReviewAnalyzer(engine:NativeEngine()));var requested=0;adapter.onPractice={requested+=1}
        _ = try await adapter.call("open_review",args:["source":"paste","text":"1. f3 e5 2. g4 Qh4# 0-1"]);let d=review.document!;try review.select(d.mainline.last!)
        func identity()->[String:Any]{["documentId":d.id.uuidString,"reviewRevision":review.revision,"nodeId":review.nodeID]}
        do{_ = try await adapter.call("start_practice_from_review",args:identity());XCTFail("Checkmate fork accepted")}catch let failure as ProtocolFailure{XCTAssertEqual(failure.code,"GAME_OVER")}
        try review.previewLine(["d8h4"],fromNode:d.nodes[review.nodeID].parent!);review.seekBranch(0)
        let result=try await adapter.call("start_practice_from_review",args:identity()) as! [String:Any]
        XCTAssertEqual(result["confirmationRequired"] as? Bool,true);XCTAssertEqual(requested,1)
        review.seekBranch(1)
        do{_ = try await adapter.call("start_practice_from_review",args:identity());XCTFail("Imagined mate fork accepted")}catch let failure as ProtocolFailure{XCTAssertEqual(failure.code,"GAME_OVER")}
    }
}

@MainActor final class OpusOpponentSettingsTests:XCTestCase {
    func testPresetOnlyChangeCancelsPendingReplyAndRestartsWithNewProfile()async throws {
        let engine=RecordingPendingEngine(),session=try GameSession(engine:engine)
        try session.playWhite(from:"e2",to:"e4");for _ in 0..<20{await Task.yield()}
        XCTAssertEqual(engine.skills,[0])
        var settings=session.state.settings;settings.opponentPreset="club";session.updateSettings(settings);for _ in 0..<20{await Task.yield()}
        XCTAssertEqual(engine.skills,[0,10],"Preset switch must cancel and restart with the effective profile")
        engine.finish(at:0,"e7e5");for _ in 0..<20{await Task.yield()}
        XCTAssertEqual(session.rules.history,["e4"],"Stale old-profile reply committed")
        engine.finish(at:1,"c7c5");for _ in 0..<20{await Task.yield()}
        XCTAssertEqual(session.rules.history,["e4","c5"])
    }
    func testPresetChangeWithSameEffectiveProfileDoesNotRestart()async throws {
        let engine=RecordingPendingEngine(),session=try GameSession(engine:engine)
        try session.playWhite(from:"e2",to:"e4");for _ in 0..<20{await Task.yield()}
        var settings=session.state.settings;settings.opponentPreset="gentle";session.updateSettings(settings);for _ in 0..<20{await Task.yield()}
        XCTAssertEqual(engine.skills,[0],"Custom skill 0 and Gentle are the same profile")
        engine.finish(at:0,"e7e5");for _ in 0..<20{await Task.yield()};XCTAssertEqual(session.rules.history,["e4","e5"])
    }
}

@MainActor final class OpusCanonicalMoveTests:XCTestCase {
    func testImaginedPromotionIsStoredAsCanonicalUCI()throws {
        let d=try PGNImporter.parse(Data("[SetUp \"1\"]\n[FEN \"7k/4P3/8/8/8/8/8/K7 w - - 0 1\"]\n*".utf8))[0],session=try GameSession(engine:nil),review=ReviewController()
        review.open(d,practice:session);try review.previewLine(["e7e8"])
        XCTAssertEqual(review.branch?.moves,["e7e8q"]);XCTAssertEqual(try PGNImporter.parse(PGNExporter.withIdeas(d,branches:review.branchesForSaving)).count,2)
    }
    func testEngineReceivesValidatedCanonicalHistory()async throws {
        let (path,directory)=try fakeEngine();defer{try? FileManager.default.removeItem(at:directory)}
        let engine=NativeEngine(executable:path)
        _ = try await engine.analyzeHistory(startFEN:"7k/4P3/8/8/8/8/8/K7 w - - 0 1",moves:["e7e8"],profile:.skill(20),budget:100,multiPv:1)
        let sent=try String(contentsOf:directory.appendingPathComponent("positions"),encoding:.utf8)
        XCTAssertTrue(sent.contains("moves e7e8q"),sent)
    }
}

@MainActor final class OpusRecordAndAnalysisTests:XCTestCase {
    func testReviewCurrentRecordsAutomaticTerminalResult()throws {
        let mate=try ChessRules();for m in ["f2f3","e7e5","g2g4","d8h4"]{try mate.move(uci:m)}
        XCTAssertEqual(try PGNImporter.parse(ReviewRecordSource.data(mate)).first?.result,"0-1")
        let live=try ChessRules();try live.move(uci:"e2e4")
        XCTAssertEqual(try PGNImporter.parse(ReviewRecordSource.data(live)).first?.result,"*")
        let stalemate=try ChessRules(fen:"7k/5Q2/6K1/8/8/8/8/8 w - - 0 1");try stalemate.move(uci:"g6h6")
        XCTAssertTrue(stalemate.stalemate);XCTAssertEqual(try PGNImporter.parse(ReviewRecordSource.data(stalemate)).first?.result,"1/2-1/2")
        XCTAssertEqual(try PGNImporter.parse(ReviewRecordSource.data(previousGame:"")).first?.result,"*")
        XCTAssertEqual(try PGNImporter.parse(ReviewRecordSource.data(previousGame:mate.pgn)).first?.result,"0-1")
    }
    func testContradictoryRecordedResultIsPreservedAndExplained()throws {
        let d=try PGNImporter.parse(Data("1. f3 e5 2. g4 Qh4# 1-0".utf8))[0]
        XCTAssertEqual(d.result,"1-0","Externally recorded result is kept")
        let overview=try ReviewExplanation.make(document:d,node:0)
        XCTAssertTrue(overview.takeaways.first?.contains("1-0")==true,overview.takeaways.first ?? "")
        let consistent=try ReviewExplanation.make(document:PGNImporter.parse(Data("1. f3 e5 2. g4 Qh4# 0-1".utf8))[0],node:0)
        XCTAssertFalse(consistent.takeaways.first?.contains("differs")==true)
    }
    func testAllFailedBatchIsNotReportedReady()async throws {
        let (path,directory)=try fakeEngine(failOnGo:true);defer{try? FileManager.default.removeItem(at:directory)}
        let analyzer=ReviewAnalyzer(engine:NativeEngine(executable:path)),d=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        analyzer.startBatch(d);let start=Date()
        while ["pending","deepening"].contains(analyzer.batchStatus),Date().timeIntervalSince(start)<20{try await Task.sleep(for:.milliseconds(20))}
        XCTAssertEqual(analyzer.completed,2);XCTAssertEqual(analyzer.failed,2);XCTAssertEqual(analyzer.batchStatus,"failed")
    }
    func testFirstLaunchBackupIsWrittenOnceAndNeverOverwritten()throws {
        let root=try temporaryDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let store=StateStore(directory:root);store.preserveFirstLaunchBackup();XCTAssertFalse(FileManager.default.fileExists(atPath:store.firstLaunchBackupURL.path))
        var old=ApplicationState();old.settings.skill=17;try store.save(old);let original=try Data(contentsOf:store.url)
        let upgraded=StateStore(directory:root);upgraded.preserveFirstLaunchBackup()
        var next=old;next.settings.skill=3;try upgraded.save(next);try upgraded.save(next);upgraded.preserveFirstLaunchBackup()
        XCTAssertEqual(try Data(contentsOf:upgraded.firstLaunchBackupURL),original,"Pre-upgrade bytes must survive later saves")
        XCTAssertNotEqual(try Data(contentsOf:upgraded.backupURL),original,"The rolling backup still tracks the previous save")
    }
}

@MainActor final class OpusReviewVoiceTests:XCTestCase {
    func testReviewTranscriptContextNamesReviewPosition()throws {
        let session=try GameSession(engine:nil),review=ReviewController(),voice=try VoiceCoach(session:session);session.reviewController=review;voice.attachReview(review)
        let d=try PGNImporter.parse(Data("1. d4 d5 *".utf8))[0];try session.rules.move(uci:"e2e4");review.open(d,practice:session);try review.select(2)
        voice.receive(["type":"response.output_audio_transcript.done","response_id":"r1","transcript":"Review explanation."])
        XCTAssertEqual(voice.history.last?.context,"Review · 1... d5")
    }
}
