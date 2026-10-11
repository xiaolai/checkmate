import XCTest
@testable import CheckmateCore

@MainActor final class UsageTests: XCTestCase {
    private func directory()->URL {FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("checkmate-usage-tests-\(UUID().uuidString)")}
    func testCumulativeReplacementAndRoundtrip() async throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let ledger=UsageLedger(directory:root),id=ledger.begin(activity:.translation,provider:"codex",sessionID:"session")
        ledger.record(operationID:id,providerID:"turn",tokens:UsageTokens(input:10,output:5,total:15,reasoning:3),status:.running,cumulative:true)
        ledger.record(operationID:id,providerID:"turn",tokens:UsageTokens(input:20,output:8,total:28,reasoning:4),status:.completed,cumulative:true)
        try await ledger.flush();XCTAssertEqual(ledger.totals().total,28);XCTAssertEqual(UsageLedger(directory:root).totals().total,28)
        try ledger.clear();try await ledger.flush();XCTAssertTrue(UsageLedger(directory:root).records.isEmpty)
    }
    func testResponseDeduplicationAndUnknownCancelled() {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let ledger=UsageLedger(directory:root),id=ledger.begin(activity:.voiceCoach,provider:"realtime",sessionID:"a")
        ledger.record(operationID:id,providerID:"response",tokens:UsageTokens(total:9),status:.cancelled)
        ledger.record(operationID:id,providerID:"response",tokens:UsageTokens(total:9),status:.cancelled)
        let second=ledger.begin(activity:.voiceCoach,provider:"realtime",sessionID:"a")
        ledger.record(operationID:second,providerID:"response",tokens:UsageTokens(total:9),status:.completed)
        let missing=ledger.begin(activity:.voiceCoach,provider:"realtime",sessionID:"b")
        ledger.record(operationID:missing,providerID:"response",tokens:nil,status:.failed)
        XCTAssertEqual(ledger.totals().total,9);XCTAssertEqual(ledger.totals().unknownRecords,1)
    }
    func testRejectMalformedCounters() {
        for value in [-1,1.5,NSNumber(value:true),Double.infinity,Double(Int64.max)] as [Any] {XCTAssertNil(UsageTokens.parseRealtime(["total_tokens":value]))}
        XCTAssertNil(UsageTokens(input:-1).input)
        XCTAssertEqual(UsageTokens.parseCodex(["totalTokens":20,"reasoningOutputTokens":5])?.total,20)
    }
    func testCorruptionPreservedAndExplicitClear() throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)};try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file=root.appendingPathComponent("usage-v1.json"),data=Data("bad file".utf8);try data.write(to:file)
        let ledger=UsageLedger(directory:root);XCTAssertNotNil(ledger.storageError)
        _=ledger.begin(activity:.translation,provider:"codex",sessionID:"a");XCTAssertEqual(try Data(contentsOf:file),data)
        try ledger.clear();XCTAssertNil(ledger.storageError)
    }
    func testIncompleteReloadPrivacyAndDateRanges() async throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let ledger=UsageLedger(directory:root);_=ledger.begin(activity:.lessonRecording,provider:"realtime",sessionID:"session",model:"gpt-realtime",locale:"fr",voice:"cedar",lessonID:"lesson")
        try await ledger.flush()
        let reloaded=UsageLedger(directory:root);XCTAssertEqual(reloaded.records.first?.status,.incomplete)
        let exported=try XCTUnwrap(String(data:reloaded.exportJSON(),encoding:.utf8))
        for key in ["transcript","credentials","prompt","email","board"]{XCTAssertFalse(exported.contains(key))}
        XCTAssertEqual(reloaded.records(in:.today).count,1);XCTAssertTrue(reloaded.records(in:.all,now:Date(timeIntervalSince1970:0)).isEmpty)
    }
    func testCoachCapturesCancelledIgnoredResponseAndTranscriptionOnce() throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let ledger=UsageLedger(directory:root),session=try GameSession(engine:nil),coach=try VoiceCoach(session:session)
        coach.usageLedger=ledger;var metadata:[String:String]=[:]
        coach.automationOutbound={event in if let response=event["response"] as? [String:Any],let value=response["metadata"] as? [String:String]{metadata=value}}
        _=try session.openVoice();coach.receive(["type":"session.updated"])
        coach.receive(["type":"response.created","response":["id":"r1","metadata":metadata]])
        coach.stopTurn()
        coach.receive(["type":"response.output_audio.delta","response_id":"r1","delta":Data(repeating:0,count:4800).base64EncodedString()])
        let done:[String:Any]=["type":"response.done","response":["id":"r1","status":"cancelled","usage":["total_tokens":17]]]
        coach.receive(done);coach.receive(done)
        let transcript:[String:Any]=["type":"conversation.item.input_audio_transcription.completed","item_id":"item","transcript":"PRIVATE TRANSCRIPT","usage":["total_tokens":4]]
        coach.receive(transcript);coach.receive(transcript);coach.disconnect()
        XCTAssertEqual(ledger.totals().total,21)
        XCTAssertEqual(ledger.records.filter{$0.activity == .inputTranscription}.count,1)
        XCTAssertEqual(ledger.records.first?.status,.cancelled)
        XCTAssertEqual(ledger.records.first?.durationSeconds,0.1)
        XCTAssertFalse(String(decoding:try ledger.exportJSON(),as:UTF8.self).contains("PRIVATE TRANSCRIPT"))
    }

    func testRealtimeBreakdownAndProviderEstimates() async throws {
        let tokens=try XCTUnwrap(UsageTokens.parseRealtime(["total_tokens":100,"input_tokens":70,"output_tokens":30,"input_token_details":["text_tokens":20,"audio_tokens":50,"cached_tokens":10,"cached_tokens_details":["text_tokens":4,"audio_tokens":6]],"output_token_details":["text_tokens":5,"audio_tokens":25]]))
        XCTAssertEqual(tokens.inputAudio,50);XCTAssertEqual(tokens.cachedAudio,6);XCTAssertEqual(tokens.outputText,5)
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let ledger=UsageLedger(directory:root),id=ledger.begin(activity:.translation,provider:"codex",sessionID:"session")
        ledger.record(operationID:id,providerID:"turn",tokens:tokens,status:.completed,estimatedCredits:1.5,estimatedUSD:0.002)
        XCTAssertEqual(ledger.totals().total,100)
        try await ledger.flush()
        let record=try XCTUnwrap(UsageLedger(directory:root).records.first)
        XCTAssertEqual(record.estimatedCredits,1.5);XCTAssertEqual(record.estimatedUSD,0.002)
    }
    func testSymlinkStorageAndClearFailure() throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let target=root.appendingPathComponent("target"),link=root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        let ledger=UsageLedger(directory:link);_=ledger.begin(activity:.translation,provider:"codex",sessionID:"session")
        XCTAssertNotNil(ledger.storageError);XCTAssertThrowsError(try ledger.clear())
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.appendingPathComponent("usage-v1.json").path))
    }
    func testClearDoesNotResurrectTranscription() throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let ledger=UsageLedger(directory:root),session=try GameSession(engine:nil),coach=try VoiceCoach(session:session)
        coach.usageLedger=ledger
        let event:[String:Any]=["type":"conversation.item.input_audio_transcription.completed","item_id":"item","usage":["total_tokens":4]]
        coach.receive(event);try ledger.clear();coach.receive(event)
        XCTAssertTrue(ledger.records.isEmpty);coach.disconnect()
    }

    func testLateCumulativeCountersPreserveTerminalStatusAndModel() {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let ledger=UsageLedger(directory:root),id=ledger.begin(activity:.translation,provider:"codex",sessionID:"a")
        ledger.record(operationID:id,providerID:"turn",tokens:nil,status:.cancelled,cumulative:true)
        ledger.record(operationID:id,providerID:"turn",tokens:UsageTokens(total:12),status:.running,cumulative:true,model:"resolved-model")
        XCTAssertEqual(ledger.records.first?.status,.cancelled);XCTAssertEqual(ledger.records.first?.model,"resolved-model");XCTAssertEqual(ledger.totals().total,12)
    }

    func testClearPreservesRunningAndFlushReload() async throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let ledger=UsageLedger(directory:root),active=ledger.begin(activity:.translation,provider:"codex",sessionID:"session")
        let done=ledger.begin(activity:.voiceCoach,provider:"realtime",sessionID:"session")
        ledger.record(operationID:done,providerID:"done",tokens:UsageTokens(total:3),status:.completed)
        try ledger.clear();XCTAssertEqual(ledger.records.map(\.id),[active])
        ledger.record(operationID:active,providerID:"turn",tokens:UsageTokens(total:7),status:.completed)
        ledger.record(operationID:active,providerID:"turn",tokens:UsageTokens(total:99),status:.running)
        try await ledger.flush()
        let reload=UsageLedger(directory:root);XCTAssertEqual(reload.totals().total,7);XCTAssertEqual(reload.records.first?.status,.completed)
    }

    func testShutdownDrainPersistsLatestSnapshot() {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let ledger=UsageLedger(directory:root),id=ledger.begin(activity:.voiceCoach,provider:"realtime",sessionID:"a")
        ledger.record(operationID:id,providerID:"response",tokens:UsageTokens(total:23),status:.completed)
        ledger.flushForShutdown()
        XCTAssertEqual(UsageLedger(directory:root).totals().total,23)
    }

    func testOversizedWriterPreservesPreviousFile() throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file=root.appendingPathComponent("usage-v1.json"),original=Data("previous ledger".utf8)
        try original.write(to:file)
        XCTAssertThrowsError(try UsageLedger.writeSnapshot(Data(repeating:0,count:UsageLimits.maximumFileBytes+1),to:root))
        XCTAssertEqual(try Data(contentsOf:file),original)
    }

    func testFinishCannotReplaceCompletedWithCancellation() {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)}
        let ledger=UsageLedger(directory:root),id=ledger.begin(activity:.translation,provider:"codex",sessionID:"a")
        ledger.record(operationID:id,providerID:"turn",tokens:UsageTokens(total:3),status:.completed,cumulative:true)
        ledger.finish(operationID:id,status:.cancelled)
        XCTAssertEqual(ledger.records.first?.status,.completed)
        ledger.record(operationID:id,providerID:"turn",tokens:UsageTokens(total:4),status:.running,cumulative:true)
        XCTAssertEqual(ledger.records.first?.status,.completed);XCTAssertEqual(ledger.totals().total,4)
    }

}
