import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// D1: with echo cancellation the learner interrupts the coach by speaking; without it the coach keeps the floor and
/// the learner uses Stop. Echo cancellation is stated, not measured: no network, no audio.
@MainActor final class VoiceBargeInTests:XCTestCase {
    private let script:[[String:Any]]=[["text":"Your pawn is on e2.","squares":["e2"],"kind":"observation"],["text":"Your king is on e1.","squares":["e1"],"kind":"observation"]]
    private func narrating(echoCancelled:Bool)async throws -> (GameSession,VoiceCoach,() -> [[String:Any]]) {
        let s=try GameSession(engine:nil);s.state.settings.coachingMode="quiet";let v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)}
        _ = try s.openVoice();v.receive(["type":"session.updated"]);v.audio.echoCancelled=echoCancelled
        v.receive(["type":"input_audio_buffer.committed"])
        _ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":script],id:"script")
        v.receive(["type":"response.done","response":["status":"completed"]])
        return (s,v,{events})
    }
    private func requests(_ events:[[String:Any]])->[String] {events.filter{$0["type"] as? String=="response.create"}.compactMap{($0["response"] as? [String:Any])?["instructions"] as? String}}
    func testListeningDuringNarrationNeedsEchoCancellation() {
        XCTAssertTrue(VoiceCoach.listens(ready:true,idle:false,narrating:true,echoCancelled:true,externalPlayback:false,microphoneOn:true,capturing:true,silent:false))
        XCTAssertFalse(VoiceCoach.listens(ready:true,idle:false,narrating:true,echoCancelled:false,externalPlayback:false,microphoneOn:true,capturing:true,silent:false),"without echo cancellation the coach would hear itself")
        XCTAssertFalse(VoiceCoach.listens(ready:true,idle:false,narrating:false,echoCancelled:true,externalPlayback:false,microphoneOn:true,capturing:true,silent:false),"not while the coach is thinking")
    }
    /// Speech while a segment is being generated cancels it and the rest of the explanation; the learner's words are
    /// answered once the cancellation is acknowledged.
    func testSpeakingInterruptsAGeneratingSegment()async throws {
        let (s,v,events)=try await narrating(echoCancelled:true);defer{v.disconnect()}
        v.audio.onPlaybackStart?();XCTAssertEqual(s.voiceFocus,["e2"])
        v.receive(["type":"input_audio_buffer.speech_started"])
        XCTAssertTrue(events().contains{$0["type"] as? String=="response.cancel"});XCTAssertTrue(s.voiceFocus.isEmpty);XCTAssertEqual(v.status,"I hear you — go ahead")
        v.receive(["type":"input_audio_buffer.committed"]);let before=requests(events()).count
        v.receive(["type":"response.done","response":["status":"cancelled"]])
        XCTAssertEqual(requests(events()).count,before+1);XCTAssertTrue(requests(events()).last?.contains("Respond to the learner")==true,"the second segment was narrated instead")
    }
    /// A segment already generated only stops playing: nothing is cancelled, and the next segment never starts.
    func testSpeakingStopsPlaybackOfAFinishedSegment()async throws {
        let (_,v,events)=try await narrating(echoCancelled:true);defer{v.disconnect()}
        v.audio.onPlaybackStart?();v.receive(["type":"response.output_audio_transcript.done","transcript":"Your pawn is on e2."]);v.receive(["type":"response.done","response":["status":"completed"]])
        let before=requests(events()).count
        v.receive(["type":"input_audio_buffer.speech_started"])
        XCTAssertFalse(events().contains{$0["type"] as? String=="response.cancel"});XCTAssertFalse(v.canStopTurn)
        XCTAssertEqual(requests(events()).count,before,"the next segment started after the interruption")
    }
    func testWithoutEchoCancellationSpeechDoesNotInterrupt()async throws {
        let (_,v,events)=try await narrating(echoCancelled:false);defer{v.disconnect()}
        v.receive(["type":"input_audio_buffer.speech_started"])
        XCTAssertFalse(events().contains{$0["type"] as? String=="response.cancel"});XCTAssertTrue(v.canStopTurn)
    }
}
