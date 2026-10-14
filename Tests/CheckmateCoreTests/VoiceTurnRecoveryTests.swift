import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// A turn that goes wrong ends that turn, never the session, and never loops; the learner's spoken turns are answered
/// in order and shown where they were spoken. Driven only through the silent hooks: no network, no audio.
@MainActor final class VoiceTurnRecoveryTests:XCTestCase {
    private func connected(_ mode:String="quiet",volume:Double?=nil)throws -> (GameSession,VoiceCoach,() -> [[String:Any]]) {
        let s=try GameSession(engine:nil);s.state.settings.coachingMode=mode;if let volume{s.state.settings.voiceVolume=volume}
        let v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)}
        _ = try s.openVoice();v.receive(["type":"session.updated"]);XCTAssertTrue(v.connected,"fixture: the silent session did not become ready")
        return (s,v,{events})
    }
    private func requests(_ events:[[String:Any]])->[String] {events.filter{$0["type"] as? String=="response.create"}.compactMap{($0["response"] as? [String:Any])?["instructions"] as? String}}
    private func until(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<200{if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};XCTFail("timed out waiting for \(what)")}

    /// A coach that keeps calling tools without speaking is stopped after the cap: the session stays, the turn ends
    /// with a reason, and no further request is made.
    func testToolRoundsAreCapped()async throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.committed"])
        for round in 0..<VoiceCoach.maximumToolResponses {
            let before=requests(events()).count
            v.receive(["type":"response.function_call_arguments.done","name":"get_board","call_id":"board-\(round)","arguments":"{}"])
            v.receive(["type":"response.done","response":["status":"completed"]])
            if round+1<VoiceCoach.maximumToolResponses {try await until("continuation \(round+1)"){requests(events()).count==before+1}}
            else {try await until("the capped turn to end"){v.status==VoiceCoach.turnUnfinished}}
        }
        XCTAssertEqual(requests(events()).count,VoiceCoach.maximumToolResponses,"responses in total, the first included")
        XCTAssertEqual(v.history.last?.text,VoiceCoach.turnUnfinished,"the transcript says why the explanation stopped")
        XCTAssertTrue(v.connected);XCTAssertFalse(v.canStopTurn)
        // The next learner turn starts with a fresh allowance.
        v.receive(["type":"input_audio_buffer.committed"]);v.receive(["type":"response.function_call_arguments.done","name":"get_board","call_id":"board-next","arguments":"{}"])
        let before=requests(events()).count;v.receive(["type":"response.done","response":["status":"completed"]])
        try await until("a continuation for the new turn"){requests(events()).count==before+1}
    }
    /// The guided game is released when a capped turn ends: Stockfish never waits on a coach that cannot finish.
    func testCappedGuidedTurnReleasesTheGame()async throws {
        let (s,v,_)=try connected("guided");defer{v.disconnect()}
        try s.playWhite(from:"e2",to:"e4");try await Task.sleep(nanoseconds:30_000_000)
        v.receive(["type":"response.done","response":["status":"completed"]]);try await Task.sleep(nanoseconds:30_000_000)
        XCTAssertTrue(s.voiceHold,"fixture: the coach holds Stockfish while it explains the learner's move")
        for round in 0..<VoiceCoach.maximumToolResponses {
            v.receive(["type":"response.function_call_arguments.done","name":"get_board","call_id":"guided-\(round)","arguments":"{}"])
            v.receive(["type":"response.done","response":["status":"completed"]]);try await Task.sleep(nanoseconds:30_000_000)
        }
        try await until("the capped turn to end"){v.status==VoiceCoach.turnUnfinished};XCTAssertFalse(s.voiceHold,"the opponent may reply")
    }
    func testFailedOrIncompleteRepliesEndOnlyTheTurn()throws {
        for status in ["failed","incomplete"] {
            let (s,v,events)=try connected();defer{v.disconnect()}
            let lease=s.voiceLease;v.receive(["type":"input_audio_buffer.committed"]);let before=requests(events()).count
            v.receive(["type":"response.done","response":["status":status]])
            XCTAssertTrue(v.connected,status);XCTAssertEqual(s.voiceLease,lease);XCTAssertEqual(v.status,VoiceCoach.turnFailure)
            XCTAssertEqual(requests(events()).count,before,"\(status): not retried")
            v.receive(["type":"input_audio_buffer.committed"]);XCTAssertEqual(requests(events()).count,before+1,"\(status): the coach answers the next spoken turn")
        }
    }
    /// A session that expired, or an error before the session is ready, still disconnects.
    func testSessionErrorsStillDisconnect()throws {
        let (s,v,_)=try connected()
        v.receive(["type":"error","error":["code":"session_expired"]]);XCTAssertFalse(v.connected);XCTAssertNil(s.voiceLease)
    }
    func testSlowAnswerEndsTheTurnAndUnacknowledgedCancellationEndsTheSession()async throws {
        let (_,v,events)=try connected();defer{v.disconnect()};v.timeoutScale=0.001
        v.receive(["type":"input_audio_buffer.committed"])
        try await until("the slow turn to time out"){v.status==VoiceCoach.turnTimeout || !v.connected}
        // The timed-out response was being generated, so it is cancelled; the provider never acknowledges it.
        XCTAssertTrue(events().contains{$0["type"] as? String=="response.cancel"})
        try await until("the unacknowledged cancellation to end the session"){!v.connected}
        XCTAssertEqual(v.status,"Voice response timed out. Reconnect to continue.")
    }
    func testSlowAnswerAcknowledgedKeepsTheSession()async throws {
        let (_,v,_)=try connected();defer{v.disconnect()};v.timeoutScale=0.001
        v.receive(["type":"input_audio_buffer.committed"])
        try await until("the cancellation"){!v.canStopTurn};v.timeoutScale=1
        v.receive(["type":"response.done","response":["status":"cancelled"]])
        XCTAssertTrue(v.connected);XCTAssertEqual(v.status,VoiceCoach.turnTimeout)
    }
    func testThinkingTimeoutGrowsWithEffort() {
        XCTAssertEqual(AppSettings.reasoningEfforts.map(VoiceCoach.thinkingTimeout),[45,45,60,90,120])
    }
    /// Speech committed while the coach is busy is answered afterwards; it is never dropped, and a board change while
    /// it waits does not replace it.
    func testLearnerTurnWhileBusyIsAnsweredAfterwards()throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.committed"]);let before=requests(events()).count
        v.receive(["type":"input_audio_buffer.committed"]);XCTAssertEqual(requests(events()).count,before,"waits for the current reply")
        v.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertEqual(requests(events()).count,before+1);XCTAssertTrue(requests(events()).last?.contains("Respond to the learner’s latest spoken turn")==true)
    }
    func testBoardChangeKeepsAWaitingLearnerTurn()async throws {
        let (s,v,events)=try connected("guided");defer{v.disconnect()}
        XCTAssertTrue(requests(events()).last?.contains("Introduce yourself")==true,"fixture: the guided introduction is being generated")
        v.receive(["type":"input_audio_buffer.committed"])
        try s.playWhite(from:"e2",to:"e4");try await Task.sleep(nanoseconds:30_000_000)
        XCTAssertTrue(events().contains{$0["type"] as? String=="response.cancel"},"fixture: the move interrupted the introduction")
        v.receive(["type":"response.done","response":["status":"cancelled"]])
        XCTAssertTrue(requests(events()).last?.contains("Respond to the learner’s latest spoken turn")==true,"the learner's turn was replaced by commentary")
    }
    /// The learner's words appear where they spoke, even when transcription arrives after the coach's reply.
    func testLearnerTranscriptKeepsItsPlace()throws {
        let (_,v,_)=try connected();defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.committed","item_id":"learner-1"])
        v.receive(["type":"response.output_audio_transcript.done","response_id":"coach-1","transcript":"Your knight on g1 can go to f3."])
        v.receive(["type":"conversation.item.input_audio_transcription.completed","item_id":"learner-1","transcript":"Where can my knight go?"])
        XCTAssertEqual(v.history.map(\.id),["learner-1","coach-1"]);XCTAssertEqual(v.history.first?.text,"Where can my knight go?")
        v.receive(["type":"input_audio_buffer.committed","item_id":"learner-2"]);v.receive(["type":"conversation.item.input_audio_transcription.completed","item_id":"learner-2","transcript":"  "])
        XCTAssertEqual(v.history.map(\.id),["learner-1","coach-1"],"silence leaves no empty entry")
        v.receive(["type":"input_audio_buffer.committed","item_id":"learner-3"]);v.receive(["type":"conversation.item.input_audio_transcription.failed","item_id":"learner-3"])
        XCTAssertEqual(v.history.last?.text,"Transcription unavailable")
    }
    /// Only the cancelled response acknowledges a Stop: another response's completion does not start the next turn.
    func testOnlyTheCancelledResponseAcknowledgesStop()throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.committed"]);let turn=(events().last?["response"] as? [String:Any])?["metadata"] as? [String:String]
        v.receive(["type":"response.created","response":["id":"current","metadata":turn ?? [:]]])
        v.stopTurn();v.receive(["type":"input_audio_buffer.committed"]);let before=requests(events()).count
        v.receive(["type":"response.done","response":["id":"unrelated","status":"completed"]])
        XCTAssertEqual(requests(events()).count,before,"an unrelated completion acknowledged the cancellation")
        v.receive(["type":"response.done","response":["id":"current","status":"cancelled"]])
        XCTAssertEqual(requests(events()).count,before+1,"the waiting learner turn starts once the cancelled response ends")
    }
    func testSessionLevelErrorsDisconnectAndOthersEndTheTurn()throws {
        for (error,fatal) in [(["type":"authentication_error","code":"x"],true),(["type":"permission_error"],true),(["code":"invalid_api_key"],true),(["type":"invalid_request_error","code":"conversation_already_has_active_response"],false),(["type":"server_error"],false)] as [([String:String],Bool)] {
            let (_,v,_)=try connected();defer{v.disconnect()}
            v.receive(["type":"error","error":error]);XCTAssertEqual(v.connected,!fatal,"\(error)")
        }
    }
    /// A watchdog that fires while only playback remains stops the audio without cancelling the finished response.
    func testPlaybackWatchdogDoesNotCancelAFinishedResponse()async throws {
        let (s,v,events)=try connected();defer{v.disconnect()}
        _ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":[["text":"Your pawn is on e2.","squares":["e2"],"kind":"observation"]]],id:"script")
        v.receive(["type":"response.done","response":["status":"completed"]]);v.audio.onPlaybackStart?()
        v.receive(["type":"response.output_audio_transcript.done","transcript":"Your pawn is on e2."])
        v.timeoutScale=0.001;v.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertTrue(v.canStopTurn,"fixture: the audio is still playing")
        try await until("the watchdog"){!v.canStopTurn}
        XCTAssertFalse(events().contains{$0["type"] as? String=="response.cancel"},"a finished response was cancelled");XCTAssertTrue(v.connected);XCTAssertEqual(v.status,VoiceCoach.turnTimeout)
    }
    /// A reasoning effort the connected model refuses is not kept: Settings returns to the confirmed effort.
    func testRejectedEffortReverts()throws {
        let (s,v,events)=try connected();defer{v.disconnect()}
        var settings=s.state.settings;settings.coachReasoningEffort="xhigh";s.updateSettings(settings);v.settingsChanged()
        let update=try XCTUnwrap(events().last);XCTAssertEqual(update["type"] as? String,"session.update");let id=try XCTUnwrap(update["event_id"] as? String)
        v.receive(["type":"error","error":["type":"invalid_request_error","code":"unsupported_value","event_id":id]])
        XCTAssertTrue(v.connected);XCTAssertEqual(s.state.settings.coachReasoningEffort,"minimal");XCTAssertEqual(v.activeEffort,"minimal");XCTAssertTrue(v.status.contains("does not support Extra high"))
    }
    /// A change made during a turn waits until the turn is over.
    func testEffortChangeWaitsForTheTurn()throws {
        let (s,v,events)=try connected();defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.committed"])
        var settings=s.state.settings;settings.coachReasoningEffort="high";s.updateSettings(settings);v.settingsChanged()
        XCTAssertFalse(events().contains{$0["type"] as? String=="session.update"},"sent during the turn")
        v.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertEqual(VoiceCoach.effort(of:events().last ?? [:]),"high")
    }
    func testLateTranscriptOfAPrunedEntryIsDropped()throws {
        let (_,v,_)=try connected();defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.committed","item_id":"old"])
        for index in 0..<31 {v.receive(["type":"response.output_audio_transcript.done","response_id":"coach-\(index)","transcript":"Idea \(index)."])}
        XCTAssertFalse(v.history.contains{$0.id=="old"},"fixture: the placeholder was pruned")
        v.receive(["type":"conversation.item.input_audio_transcription.completed","item_id":"old","transcript":"An old question"])
        XCTAssertFalse(v.history.contains{$0.id=="old"});XCTAssertEqual(v.history.count,30)
    }
    /// Completed tool pairs from an earlier exchange are deleted once the coach is idle; the latest exchange's stay,
    /// and a deletion the provider refuses is not a turn failure.
    func testCompletedToolItemsFromEarlierExchangesArePruned()async throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        func deletes()->[String] {events().filter{$0["type"] as? String=="conversation.item.delete"}.compactMap{$0["item_id"] as? String}}
        func exchange(_ n:Int)async throws {
            v.receive(["type":"input_audio_buffer.committed"])
            v.receive(["type":"response.output_item.done","item":["type":"function_call","id":"call-item-\(n)","call_id":"call-\(n)"]])
            v.receive(["type":"response.function_call_arguments.done","name":"get_board","call_id":"call-\(n)","arguments":"{}"])
            v.receive(["type":"response.done","response":["status":"completed"]])
            try await until("the tool output and its continuation \(n)"){events().contains{($0["item"] as? [String:Any])?["call_id"] as? String=="call-\(n)"} && events().last?["type"] as? String=="response.create"}
            v.receive(["type":"conversation.item.added","item":["type":"function_call_output","id":"output-item-\(n)","call_id":"call-\(n)"]])
            v.receive(["type":"response.done","response":["status":"completed"]])
        }
        try await exchange(1);XCTAssertEqual(deletes(),[],"the latest exchange is kept")
        try await exchange(2);XCTAssertEqual(Set(deletes()),["call-item-1","output-item-1"])
        v.receive(["type":"error","error":["type":"invalid_request_error","code":"item_not_found","event_id":VoiceCoach.prunePrefix+"output-item-1"]])
        XCTAssertTrue(v.connected);XCTAssertNotEqual(v.status,VoiceCoach.turnFailure)
    }
    /// Each narrated segment records whether it was heard as written, replaced by text, or stopped: once, and
    /// separately from the provider's completion status.
    func testNarrationOutcomesAreRecorded()async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let (s,v,_)=try connected();defer{v.disconnect()};let ledger=UsageLedger(directory:directory);v.usageLedger=ledger
        func narrate(_ text:String)async throws {_ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":[["text":text,"squares":["e2"],"kind":"observation"]]],id:UUID().uuidString);v.receive(["type":"response.done","response":["status":"completed"]])}
        try await narrate("Your pawn is on e2.");v.receive(["type":"response.output_audio_transcript.done","transcript":"Your pawn is on e2."]);v.receive(["type":"response.done","response":["status":"completed"]])
        try await narrate("Your king is on e1.");v.receive(["type":"response.output_audio_transcript.done","transcript":"Your queen is on e1."]);v.receive(["type":"response.done","response":["status":"cancelled"]])
        try await narrate("Your knight is on g1.");v.stopTurn();v.receive(["type":"response.done","response":["status":"cancelled"]])
        let counts=ledger.narrationCounts();XCTAssertEqual(counts[.verified],1);XCTAssertEqual(counts[.unverified],1);XCTAssertEqual(counts[.interrupted],1)
        XCTAssertEqual(ledger.records.filter{$0.narration != nil}.map(\.activity),[.voiceCoach,.voiceCoach,.voiceCoach])
    }
    /// D3: a session nearing the provider's limit is renewed between turns, never during one, and carries a bounded
    /// summary of the conversation instead of a greeting.
    func testSessionIsRenewedBetweenTurnsBeforeItsLimit()async throws {
        XCTAssertEqual(VoiceCoach.renewalAge,55*60)
        let s=try GameSession(engine:nil);s.state.settings.coachingMode="quiet";let v=try VoiceCoach(session:s);v.renewalDelay=0.05
        _ = try s.openVoice();v.receive(["type":"session.updated"]);defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.committed","item_id":"question"]);v.receive(["type":"conversation.item.input_audio_transcription.completed","item_id":"question","transcript":"Why is my bishop stuck?"])
        try await Task.sleep(nanoseconds:150_000_000);XCTAssertEqual(v.renewals,0,"renewed in the middle of a turn")
        v.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertEqual(v.renewals,1,"renewed once the turn was over");XCTAssertTrue(v.carriedSummary.contains("Learner: Why is my bishop stuck?"))
        XCTAssertFalse(v.connected,"the old session is closed, not left to expire");XCTAssertNil(s.voiceLease);XCTAssertEqual(v.connectRequests,[false],"a fresh session is requested, without a greeting")
        XCTAssertLessThanOrEqual(v.carriedSummary.count,2000)
    }
    func testIdleSessionIsRenewedOnTime()async throws {
        let s=try GameSession(engine:nil);s.state.settings.coachingMode="quiet";let v=try VoiceCoach(session:s);v.renewalDelay=0.02
        _ = try s.openVoice();v.receive(["type":"session.updated"]);defer{v.disconnect()}
        try await until("the idle renewal"){v.renewals==1};XCTAssertEqual(v.connectRequests,[false])
    }
    /// A late "nothing to cancel" for an earlier Stop does not acknowledge a newer one.
    func testStaleCancellationErrorDoesNotReleaseANewerStop()throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        func cancels()->[String] {events().filter{$0["type"] as? String=="response.cancel"}.compactMap{$0["event_id"] as? String}}
        v.receive(["type":"input_audio_buffer.committed"]);v.stopTurn();let first=try XCTUnwrap(cancels().last)
        v.receive(["type":"response.done","response":["status":"completed"]])
        v.receive(["type":"input_audio_buffer.committed"]);v.stopTurn();let second=try XCTUnwrap(cancels().last);XCTAssertNotEqual(first,second)
        v.receive(["type":"input_audio_buffer.committed"]);let before=requests(events()).count
        v.receive(["type":"error","error":["type":"invalid_request_error","code":"response_cancel_not_active","event_id":first]])
        XCTAssertEqual(requests(events()).count,before,"the stale error released the newer cancellation")
        v.receive(["type":"error","error":["type":"invalid_request_error","code":"response_cancel_not_active"]])
        XCTAssertEqual(requests(events()).count,before,"an error naming no event cannot acknowledge a Stop")
        v.receive(["type":"error","error":["type":"invalid_request_error","code":"response_cancel_not_active","event_id":second]])
        XCTAssertEqual(requests(events()).count,before+1)
    }
    /// Renewal waits while a preview plays or connecting is blocked, then happens.
    func testRenewalWaitsForAPreviewAndAnUnblockedConnection()async throws {
        let s=try GameSession(engine:nil);s.state.settings.coachingMode="quiet";let v=try VoiceCoach(session:s);v.renewalDelay=0.02
        var blocked=true;v.connectionBlocked={blocked};v.externalPlayback=true
        _ = try s.openVoice();v.receive(["type":"session.updated"]);defer{v.disconnect()}
        try await Task.sleep(nanoseconds:100_000_000);XCTAssertEqual(v.renewals,0,"renewed during a preview")
        v.externalPlayback=false;XCTAssertEqual(v.renewals,0,"renewed while connecting was blocked");XCTAssertTrue(v.connected)
        blocked=false;v.receive(["type":"input_audio_buffer.committed"]);v.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertEqual(v.renewals,1)
    }
    /// Audio still arriving keeps the turn alive past the thinking limit.
    func testArrivingAudioKeepsTheTurnAlive()async throws {
        let (s,v,_)=try connected();defer{v.disconnect()};v.timeoutScale=0.01
        _ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":[["text":"Your pawn is on e2.","squares":["e2"],"kind":"observation"]]],id:"script")
        v.receive(["type":"response.done","response":["status":"completed"]])
        let chunk=Data(count:4800).base64EncodedString()
        for _ in 0..<6 {try await Task.sleep(nanoseconds:150_000_000);v.receive(["type":"response.output_audio.delta","delta":chunk])}
        XCTAssertTrue(v.connected);XCTAssertNotEqual(v.status,VoiceCoach.turnTimeout,"audio was cut off while it was still arriving");XCTAssertTrue(v.canStopTurn)
    }
    /// A session-level error ends the session even when it names a pending effort change or a pruning deletion.
    func testFatalErrorsWinOverTheirEventIDs()throws {
        for id in ["effort",VoiceCoach.prunePrefix+"item"] {
            let (s,v,events)=try connected();defer{v.disconnect()}
            var source=id
            if id=="effort"{var settings=s.state.settings;settings.coachReasoningEffort="high";s.updateSettings(settings);v.settingsChanged();source=events().last?["event_id"] as? String ?? ""}
            v.receive(["type":"error","error":["type":"authentication_error","code":"session_expired","event_id":source]])
            XCTAssertFalse(v.connected,id);XCTAssertNil(s.voiceLease,id)
        }
    }
    /// A newer effort chosen while an older one was pending survives the older one's rejection and is sent next.
    func testNewerEffortSurvivesAnOlderRejection()throws {
        let (s,v,events)=try connected();defer{v.disconnect()}
        var settings=s.state.settings;settings.coachReasoningEffort="xhigh";s.updateSettings(settings);v.settingsChanged()
        let id=try XCTUnwrap(events().last?["event_id"] as? String)
        settings.coachReasoningEffort="high";s.updateSettings(settings);v.settingsChanged()
        v.receive(["type":"error","error":["type":"invalid_request_error","code":"unsupported_value","event_id":id]])
        XCTAssertEqual(s.state.settings.coachReasoningEffort,"high");XCTAssertEqual(VoiceCoach.effort(of:events().last ?? [:]),"high")
    }
    /// An effort chosen while connecting is sent once the session is ready.
    func testEffortChosenWhileConnectingIsApplied()throws {
        let s=try GameSession(engine:nil);s.state.settings.coachingMode="quiet";let v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)};_ = try s.openVoice();defer{v.disconnect()}
        var settings=s.state.settings;settings.coachReasoningEffort="high";s.updateSettings(settings);v.settingsChanged()
        v.receive(["type":"session.updated","session":["reasoning":["effort":"minimal"]]])
        XCTAssertEqual(VoiceCoach.effort(of:events.last ?? [:]),"high")
    }
    /// Several spoken turns while busy are answered together, each of them.
    func testSeveralWaitingLearnerTurnsAreAnsweredTogether()throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.committed"]);v.receive(["type":"input_audio_buffer.committed"]);v.receive(["type":"input_audio_buffer.committed"])
        v.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertEqual(requests(events()).count,2);XCTAssertTrue(requests(events()).last?.contains(VoiceCoach.learnerTurns)==true,"the waiting turns were not all answered")
    }
    /// While another voice plays (a Settings preview), the coach's own replies wait.
    func testCoachWaitsForAPreview()throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        v.externalPlayback=true;v.receive(["type":"input_audio_buffer.committed"]);XCTAssertEqual(requests(events()).count,0)
        v.externalPlayback=false;XCTAssertEqual(requests(events()).count,1)
    }
    func testSavedCoachVolumeAppliesWithoutASettingsChange()throws {
        let (_,v,_)=try connected(volume:0.3);defer{v.disconnect()}
        XCTAssertEqual(v.audio.volume,0.3,accuracy:0.0001)
    }
}
