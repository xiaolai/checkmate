import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class VoiceOrchestrationTests:XCTestCase {
    @MainActor func testQuietAndOnRequestNeverSpeakWithoutUserInput()throws {for mode in ["quiet","on_request"]{let s=try GameSession(engine:nil);s.state.settings.coachingMode=mode;let v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)};_ = try s.openVoice();v.receive(["type":"session.updated"]);XCTAssertFalse(events.contains{$0["type"] as? String=="response.create"});let start=Date();v.receive(["type":"input_audio_buffer.committed"]);XCTAssertLessThan(Date().timeIntervalSince(start),0.1);XCTAssertEqual(events.filter{$0["type"] as? String=="response.create"}.count,1);v.disconnect();XCTAssertFalse(s.voiceHold);XCTAssertNil(s.voiceLease)}}
    /// Guided commentary follows the learner's moves; Stockfish's quiet reply passes without comment, its capture does not.
    @MainActor func testGuidedCommentaryFollowsLearnerMovesAndNotableReplies()async throws {
        let s=try GameSession(engine:nil);s.state.settings.coachingMode="guided";let v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)};_ = try s.openVoice();v.receive(["type":"session.updated"])
        func count()->Int {events.filter{$0["type"] as? String=="response.create"}.count}
        func done()async throws {v.receive(["type":"response.done","response":["status":"completed"]]);try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertEqual(count(),1,"the introduction");try await done()
        try s.playWhite(from:"e2",to:"e4");try await Task.sleep(nanoseconds:20_000_000);XCTAssertEqual(count(),2,"after the learner's move");try await done()
        _ = try s.commitBlack("e7e5");try await Task.sleep(nanoseconds:20_000_000);XCTAssertEqual(count(),2,"a quiet reply passes without comment")
        XCTAssertTrue(s.voiceHold,"the learner's next move is still held for commentary")
        try s.playWhite(from:"d2",to:"d4");try await Task.sleep(nanoseconds:20_000_000);XCTAssertEqual(count(),3);try await done()
        _ = try s.commitBlack("e5d4");try await Task.sleep(nanoseconds:20_000_000);XCTAssertEqual(count(),4,"a capture is commented")
        XCTAssertTrue((events.last(where:{$0["type"] as? String=="response.create"})?["response"] as? [String:Any])?["instructions"].map{"\($0)".contains("a capture")}==true)
        s.emit(semantic:false);try await Task.sleep(nanoseconds:20_000_000);XCTAssertEqual(count(),4);v.disconnect()
    }
    func testCommentaryTriggers() {
        func move(_ color:String,_ san:String,captured:String?=nil,promotion:String?=nil)->MoveRecord {MoveRecord(color:color,from:"a1",to:"a2",piece:"p",flags:"n",san:san,before:"",after:"",captured:captured,promotion:promotion)}
        XCTAssertNotNil(VoiceCoach.commentary(after:nil,learnerSide:"w",over:false))
        XCTAssertNotNil(VoiceCoach.commentary(after:move("w","e4"),learnerSide:"w",over:false))
        XCTAssertNil(VoiceCoach.commentary(after:move("b","e5"),learnerSide:"w",over:false))
        XCTAssertNil(VoiceCoach.commentary(after:move("w","e4"),learnerSide:"b",over:false),"the learner plays Black")
        for (record,word) in [(move("b","Bb4+"),"check"),(move("b","Qxf2#",captured:"p"),"checkmate"),(move("b","exd4",captured:"p"),"a capture"),(move("b","a1=Q",promotion:"q"),"a promotion")] {XCTAssertTrue(VoiceCoach.commentary(after:record,learnerSide:"w",over:false)?.contains(word)==true,word)}
        XCTAssertTrue(VoiceCoach.commentary(after:move("b","Kg8"),learnerSide:"w",over:true)?.contains("end of the game")==true)
    }
    /// Commentary nobody asked for speaks one segment; a learner's question may use more.
    @MainActor func testCommentarySpeaksOneSegment()async throws {
        let s=try GameSession(engine:nil);s.state.settings.coachingMode="guided";let v=try VoiceCoach(session:s);_ = try s.openVoice();v.receive(["type":"session.updated"]);defer{v.disconnect()}
        v.receive(["type":"response.done","response":["status":"completed"]]);try s.playWhite(from:"e2",to:"e4");try await Task.sleep(nanoseconds:20_000_000)
        let two:[[String:Any]]=[["text":"Your pawn is on e4.","squares":["e4"],"kind":"observation"],["text":"It controls d5.","squares":["d5"],"kind":"observation"]]
        do {_ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":two],id:"long");XCTFail("two segments of commentary accepted")}
        catch {XCTAssertEqual((ProtocolErrors.failure(error)["error"] as? [String:Any])?["code"] as? String,"PROACTIVE_LIMIT")}
        v.stopTurn();v.receive(["type":"response.done","response":["status":"cancelled"]]);v.receive(["type":"input_audio_buffer.committed"])
        let queued=try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":two],id:"answer") as? [String:Any]
        XCTAssertEqual(queued?["queued"] as? Int,2)
    }
    @MainActor func testScriptFocusWaitsForPlaybackAndClearsAtEnd()async throws {let s=try GameSession(engine:nil),v=try VoiceCoach(session:s);_ = try s.openVoice();v.receive(["type":"session.updated"]);_ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":[["text":"Your pawn is on e2.","squares":["e2"],"kind":"observation"]]],id:"segment");v.receive(["type":"response.done","response":["status":"completed"]]);XCTAssertTrue(s.voiceFocus.isEmpty);v.audio.onPlaybackStart?();XCTAssertEqual(s.voiceFocus,["e2"]);XCTAssertFalse(v.microphone);v.audio.onPlaybackEnd?();XCTAssertTrue(s.voiceFocus.isEmpty);v.disconnect()}
    @MainActor func testLanguageAndServiceErrorCleanup()throws {let s=try GameSession(engine:nil),v=try VoiceCoach(session:s);s.state.settings.voiceLanguage="en";var packets:[[String:Any]]=[];v.automationOutbound={packets.append($0)};_ = try s.openVoice();v.receive(["type":"session.updated"]);let response=packets.first(where:{$0["type"] as? String=="response.create"})?["response"] as? [String:Any];XCTAssertTrue((response?["instructions"] as? String ?? "").contains("Response language: English"));v.disconnect()
        // A service error before the session is ready means it never started: everything it held is released.
        let t=try VoiceCoach(session:s);_ = try s.openVoice();t.receive(["type":"error","error":["code":"invalid_request"]]);XCTAssertFalse(t.connected);XCTAssertFalse(t.audio.capturing);XCTAssertFalse(t.audio.playing);XCTAssertNil(s.voiceLease);XCTAssertFalse(s.voiceHold)}
    @MainActor func testQueuedToolRejectsLearnerChangedPosition()async throws {let s=try GameSession(engine:nil);s.state.settings.coachingMode="quiet";let v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)};_ = try s.openVoice();v.receive(["type":"session.updated"]);v.receive(["type":"input_audio_buffer.committed"]);v.receive(["type":"response.function_call_arguments.done","name":"get_board","call_id":"old-board","arguments":"{}"]);v.receive(["type":"response.done","response":["status":"completed"]]);try s.playWhite(from:"e2",to:"e4");try await Task.sleep(nanoseconds:30_000_000);let output=events.compactMap{$0["item"] as? [String:Any]}.first{$0["call_id"] as? String=="old-board"}?["output"] as? String;XCTAssertTrue(output?.contains("STALE_STATE")==true);v.disconnect()}

}

extension VoiceOrchestrationTests {
    @MainActor func testChangedScriptStopsBeforeNextSegment()async throws {
        let s=try GameSession(engine:nil),v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)};_ = try s.openVoice();v.receive(["type":"session.updated"])
        _ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":[["text":"Your pawn is on e2.","squares":["e2"],"kind":"observation"],["text":"Your king is on e1.","squares":["e1"],"kind":"observation"]]],id:"script")
        v.receive(["type":"response.done","response":["status":"completed"]]);let requests=events.filter{$0["type"] as? String=="response.create"}.count
        v.receive(["type":"response.output_audio_transcript.done","response_id":"script","transcript":"Your pawn is on e4."])
        v.receive(["type":"response.done","response":["status":"cancelled"]])
        XCTAssertTrue(v.connected);XCTAssertEqual(events.filter{$0["type"] as? String=="response.create"}.count,requests);XCTAssertTrue(s.voiceFocus.isEmpty);v.disconnect();XCTAssertFalse(s.voiceHold)
    }
    /// An incomplete reply ends its turn with a visible reason; the session and its lease stay, and nothing is spoken.
    @MainActor func testIncompleteResponseDoesNotAdvanceTurn()throws {
        let s=try GameSession(engine:nil),v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)};let lease=try s.openVoice();v.receive(["type":"session.updated"])
        let requests=events.filter{$0["type"] as? String=="response.create"}.count
        v.receive(["type":"response.done","response":["status":"incomplete"]]);XCTAssertTrue(v.connected);XCTAssertEqual(s.voiceLease,lease);XCTAssertEqual(v.status,VoiceCoach.turnFailure)
        XCTAssertEqual(events.filter{$0["type"] as? String=="response.create"}.count,requests,"an incomplete reply is not retried or continued");XCTAssertFalse(v.canStopTurn);v.disconnect();XCTAssertFalse(s.voiceHold)
    }
}
