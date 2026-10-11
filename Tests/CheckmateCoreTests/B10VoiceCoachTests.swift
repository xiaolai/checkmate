import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


/// VC2-12: a narration segment whose speech differs from its verified script ends that explanation, not the session.
@MainActor final class B10VoiceCoachTests:XCTestCase {
    private var segments:[[String:Any]] {[["text":"Your pawn is on e2.","squares":["e2"],"kind":"observation"],["text":"Your king is on e1.","squares":["e1"],"kind":"observation"]]}
    private func count(_ events:[[String:Any]],_ type:String)->Int {events.filter{$0["type"] as? String==type}.count}
    /// Connects silently and starts reading the first of two verified segments.
    private func reading()async throws -> (GameSession,VoiceCoach,() -> [[String:Any]]) {
        let s=try GameSession(engine:nil),v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)};_ = try s.openVoice();v.receive(["type":"session.updated"])
        _ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":segments],id:"script")
        v.receive(["type":"response.done","response":["status":"completed"]])
        return (s,v,{events})
    }
    func testAMisreadSegmentStopsTheExplanationButKeepsTheSession()async throws {
        let (s,v,events)=try await reading();let requests=count(events(),"response.create")
        v.receive(["type":"response.output_audio_transcript.done","response_id":"script","transcript":"Your pawn is on e4."])
        XCTAssertTrue(v.connected,"A misread segment never disconnects the coach");XCTAssertEqual(count(events(),"response.cancel"),1,"The misread audio is cancelled")
        v.receive(["type":"response.done","response":["status":"cancelled"]])
        XCTAssertTrue(v.connected);XCTAssertEqual(count(events(),"response.create"),requests,"The next segment is not read")
        let shown=v.history.last?.text ?? "";XCTAssertTrue(shown.contains("Your pawn is on e2.") && shown.contains("Your king is on e1."),"The verified explanation is shown as text")
        XCTAssertTrue(s.voiceFocus.isEmpty);v.disconnect();XCTAssertFalse(s.voiceHold);XCTAssertNil(s.voiceLease)
    }
    func testAnUnverifiableSegmentStopsTheExplanationButKeepsTheSession()async throws {
        let (s,v,events)=try await reading();let requests=count(events(),"response.create")
        v.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertTrue(v.connected,"A segment without a transcript never disconnects the coach");XCTAssertEqual(count(events(),"response.cancel"),0,"A finished response is not cancelled")
        XCTAssertEqual(count(events(),"response.create"),requests,"The next segment is not read")
        XCTAssertTrue(v.history.last?.text.contains("Your king is on e1.")==true);XCTAssertTrue(s.voiceFocus.isEmpty);v.disconnect()
    }
    func testNumbersSpokenAsWordsStillMatchTheScript()async throws {
        let (_,v,events)=try await reading();let requests=count(events(),"response.create")
        v.receive(["type":"response.output_audio_transcript.done","response_id":"script","transcript":"Your pawn is on e two."])
        v.receive(["type":"response.done","response":["status":"completed"]])
        XCTAssertTrue(v.connected);XCTAssertEqual(count(events(),"response.cancel"),0);XCTAssertEqual(count(events(),"response.create"),requests+1,"The verified first segment leads to the second");v.disconnect()
    }
}
