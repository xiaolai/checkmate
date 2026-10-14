import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// D7 (#45): Stop is available from the coach's turn state, never from its status wording. It covers a response being
/// generated, its audio playing (in either order), and turn work still running after response.done; it ends with the
/// cancellation request, a failure or a disconnect. Driven only through the silent hooks: no network, no audio.
@MainActor final class CleanupVoiceStopTests:XCTestCase {
    private let line="Your pawn is on e2."
    private func connected()throws -> (GameSession,VoiceCoach,() -> [[String:Any]]) {
        let s=try GameSession(engine:nil);s.state.settings.coachingMode="quiet"
        let v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)}
        _ = try s.openVoice();v.receive(["type":"session.updated"])
        XCTAssertTrue(v.connected,"fixture: the silent session did not become ready");XCTAssertFalse(v.canStopTurn,"nothing to stop before a turn")
        return (s,v,{events})
    }
    private func requests(_ events:[[String:Any]])->[String] {events.filter{$0["type"] as? String=="response.create"}.compactMap{($0["response"] as? [String:Any])?["instructions"] as? String}}
    /// A learner turn whose tool call scripted one spoken segment; the segment's audio is now being generated.
    private func generatingScript(_ s:GameSession,_ v:VoiceCoach)async throws {
        v.receive(["type":"input_audio_buffer.committed"]);XCTAssertTrue(v.canStopTurn,"a response being generated can be stopped")
        _ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":[["text":line,"squares":["e2"],"kind":"observation"]]],id:"script")
        v.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertTrue(v.canStopTurn,"the scripted segment's audio is being generated")
    }

    func testGenerationThenPlayback()async throws {
        let (s,v,_)=try connected();defer{v.disconnect()}
        try await generatingScript(s,v)
        v.receive(["type":"response.output_audio_transcript.done","transcript":line]);v.receive(["type":"response.done","response":["status":"completed"]])
        v.audio.onPlaybackStart?();XCTAssertTrue(v.canStopTurn,"audio that starts after its response finished can be stopped")
        v.audio.onPlaybackEnd?();XCTAssertFalse(v.canStopTurn,"the turn is over once its audio ends")
    }
    func testPlaybackThenGeneration()async throws {
        let (s,v,_)=try connected();defer{v.disconnect()}
        try await generatingScript(s,v)
        v.audio.onPlaybackStart?();XCTAssertTrue(v.canStopTurn)
        v.receive(["type":"response.output_audio_transcript.done","transcript":line]);v.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertTrue(v.canStopTurn,"audio still playing after its response finished can be stopped")
        v.audio.onPlaybackEnd?();XCTAssertFalse(v.canStopTurn)
    }
    /// A tool task outstanding after response.done is cancellable turn work, although the status reads as ready; when
    /// it finishes, the queued continuation keeps Stop available until that response is done too.
    func testOutstandingToolWorkAndItsContinuationKeepStopAvailable()async throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.committed"])
        v.receive(["type":"response.function_call_arguments.done","name":"get_board","call_id":"board","arguments":"{}"])
        v.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertTrue(v.canStopTurn,"a tool task still running after response.done can be stopped")
        // The status wording changes with what the learner does, not with the outstanding work: Stop does not follow it.
        v.receive(["type":"input_audio_buffer.speech_started"]);XCTAssertEqual(v.status,"I hear you — go ahead","fixture: the status did not change")
        XCTAssertTrue(v.canStopTurn,"Stop followed the status wording instead of the outstanding tool task")
        let before=requests(events()).count
        for _ in 0..<100 where requests(events()).count==before {try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(requests(events()).last?.contains("Continue after the tool results")==true,"fixture: the continuation was never requested")
        XCTAssertTrue(v.canStopTurn,"the continuation queued by the finished tool can be stopped")
        v.receive(["type":"response.done","response":["status":"completed"]]);XCTAssertFalse(v.canStopTurn)
    }
    func testStoppingOutstandingToolWorkEndsStop()throws {
        let (_,v,_)=try connected();defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.committed"])
        v.receive(["type":"response.function_call_arguments.done","name":"get_board","call_id":"board","arguments":"{}"])
        v.receive(["type":"response.done","response":["status":"completed"]]);XCTAssertTrue(v.canStopTurn)
        v.stopTurn();XCTAssertFalse(v.canStopTurn,"stopping cancels the tool task, leaving nothing to stop")
    }
    /// Stop is spent once pressed: while the cancellation awaits acknowledgement there is nothing more to stop, and a
    /// learner turn queued meanwhile starts (and can be stopped) once the cancellation is acknowledged.
    func testCancellationAndAQueuedTurn()throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.committed"]);XCTAssertTrue(v.canStopTurn)
        v.stopTurn()
        XCTAssertTrue(events().contains{$0["type"] as? String=="response.cancel"},"fixture: no cancellation was sent")
        XCTAssertFalse(v.canStopTurn,"a cancellation awaiting acknowledgement leaves nothing to stop")
        let before=requests(events()).count
        v.receive(["type":"input_audio_buffer.committed"])
        XCTAssertEqual(requests(events()).count,before,"fixture: the learner's turn should wait for the acknowledgement");XCTAssertFalse(v.canStopTurn)
        v.receive(["type":"response.done","response":["status":"cancelled"]])
        XCTAssertEqual(requests(events()).count,before+1,"the queued turn starts after the acknowledgement");XCTAssertTrue(v.canStopTurn,"the queued turn's response can be stopped")
        v.receive(["type":"response.done","response":["status":"completed"]]);XCTAssertFalse(v.canStopTurn)
    }
    func testAcknowledgementWithNothingQueuedEndsStop()throws {
        let (_,v,events)=try connected();defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.committed"]);v.stopTurn()
        let cancel=try XCTUnwrap(events().last(where:{$0["type"] as? String=="response.cancel"})?["event_id"] as? String)
        v.receive(["type":"error","error":["code":"response_cancel_not_active","event_id":cancel]])
        XCTAssertTrue(v.connected);XCTAssertFalse(v.canStopTurn)
        // Acknowledged: the next learner turn starts at once instead of waiting.
        let before=requests(events()).count;v.receive(["type":"input_audio_buffer.committed"]);XCTAssertEqual(requests(events()).count,before+1)
    }
    /// A failed turn ends that turn, not the session: Stop has nothing left to stop and the coach listens again.
    func testFailureEndsStop()throws {
        for failure:[String:Any] in [["type":"error","error":["code":"invalid_request"]],["type":"response.done","response":["status":"failed"]]] {
            let (_,v,events)=try connected();defer{v.disconnect()}
            v.receive(["type":"input_audio_buffer.committed"]);XCTAssertTrue(v.canStopTurn)
            v.receive(failure)
            // An error may belong to a response still running: its cancellation is acknowledged, naming its own event,
            // before the turn is over.
            if failure["type"] as? String=="error",let cancel=events().last(where:{$0["type"] as? String=="response.cancel"})?["event_id"] as? String {v.receive(["type":"error","error":["code":"response_cancel_not_active","event_id":cancel]])}
            XCTAssertTrue(v.connected,"\(failure) ended the session instead of the turn");XCTAssertFalse(v.canStopTurn,"\(failure)")
            XCTAssertEqual(v.status,VoiceCoach.turnFailure)
        }
    }
    func testDisconnectEndsStopWithWorkOutstanding()throws {
        let (_,v,_)=try connected()
        v.receive(["type":"input_audio_buffer.committed"])
        v.receive(["type":"response.function_call_arguments.done","name":"get_board","call_id":"board","arguments":"{}"])
        XCTAssertTrue(v.canStopTurn)
        v.disconnect();XCTAssertFalse(v.canStopTurn,"a disconnected coach has nothing to stop")
    }
}
