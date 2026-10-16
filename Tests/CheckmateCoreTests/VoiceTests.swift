import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform
import RealtimeConnection
import PCM16

final class VoiceTests:XCTestCase {
    func testGenerationDoesNotEndPlayback(){var gate=VoiceTurnGate();gate.begin();XCTAssertFalse(gate.ready);gate.generated(hasAudio:true);XCTAssertFalse(gate.ready);gate.playbackEnded();XCTAssertTrue(gate.ready);gate.begin();gate.playbackEnded();XCTAssertFalse(gate.ready);gate.generated(hasAudio:true);XCTAssertTrue(gate.ready)}
    func testCredentialParsingAndRejections()throws {XCTAssertEqual(try CodexSubscriptionClient.chatGPTAccessToken(Data(#"{"tokens":{"access_token":"sample"}}"#.utf8)),"sample");XCTAssertThrowsError(try CodexSubscriptionClient.chatGPTAccessToken(Data(#"{"api_key":"no"}"#.utf8)))}
    func testPCMConversion(){let input:[Float]=[-2,-1,0,0.5,1,2];let data=PCM.encode(input);XCTAssertEqual(data.count,12);let values=PCM.decode(data);XCTAssertEqual(values.count,6);XCTAssertEqual(values[2],0);XCTAssertEqual(values[3],0.5,accuracy:0.001)}
}
extension VoiceTests {
    @MainActor func testVoiceToolAuthorizationAndStaleSpeech() async throws {let s=try GameSession(engine:nil),v=try VoiceCoach(session:s)
        do{_ = try await v.execute("play_requested_move",args:["positionId":s.positionId,"from":"e2","to":"e4"],id:"request");XCTFail("Unrequested move accepted")}catch{}
        XCTAssertTrue(s.rules.history.isEmpty)
        do{_ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":"obsolete","segments":[["text":"Knight on g1","squares":["g1"],"kind":"observation"]]],id:"speech");XCTFail("Stale display accepted")}catch{}
        do{_ = try await v.execute("speak_explanation",args:["positionId":s.positionId,"displayIdentity":s.displayIdentity,"segments":[["text":"Knight","squares":["g9"],"kind":"observation"]]],id:"speech");XCTFail("Invalid square accepted")}catch{}
        _ = try s.openVoice();v.receive(["type":"session.updated"]);XCTAssertTrue(v.connected);XCTAssertFalse(v.microphone);v.receive(["type":"response.done","response":["status":"completed"]]);v.disconnect();XCTAssertNil(s.voiceLease);XCTAssertFalse(s.voiceHold)
    }
    @MainActor func testSettingsCannotOpenLessonFromPractice()throws {let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);p.settingsChanged();XCTAssertEqual(s.mode,.practice)}
}
extension VoiceTests {@MainActor func testStopSpeechReleasesEngineHold()throws {let s=try GameSession(engine:nil),v=try VoiceCoach(session:s);_ = try s.openVoice();v.receive(["type":"session.updated"]);XCTAssertTrue(s.voiceHold);v.stopTurn();XCTAssertFalse(s.voiceHold);XCTAssertFalse(v.status.contains("thinking"));v.disconnect()}}
extension VoiceTests {
    @MainActor func testRecheckWaitsForCancelledUnconfirmedResponse()throws {let s=try GameSession(engine:nil),v=try VoiceCoach(session:s);_ = try s.openVoice();v.receive(["type":"session.updated"]);XCTAssertTrue(v.status.contains("thinking"));v.recheck();XCTAssertFalse(v.status.contains("thinking"));v.receive(["type":"response.done","response":["id":"cancelled-original","status":"cancelled"]]);XCTAssertTrue(v.status.contains("thinking"));v.disconnect()}
}
extension VoiceTests {
    func testCoachReasoningSettingsMigrationAndRoundtrip()throws {
        XCTAssertEqual(AppSettings(raw:[:]).coachReasoningEffort,"minimal")
        for invalid:Any in ["none","maximum",true,5,NSNull()] {XCTAssertEqual(AppSettings(raw:["coachReasoningEffort":invalid]).coachReasoningEffort,"minimal")}
        for effort in AppSettings.reasoningEfforts {
            let settings=AppSettings(raw:["coachReasoningEffort":effort])
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(settings)).coachReasoningEffort,effort)
            let event=VoiceSessionConfiguration.event(instructions:"Test",voice:"cedar",tools:[],effort:effort)
            let config=try XCTUnwrap(event["session"] as? [String:Any])
            XCTAssertEqual((config["reasoning"] as? [String:String])?["effort"],effort)
        }
        XCTAssertEqual(VoiceSessionConfiguration.model,"gpt-realtime-2.1")
        XCTAssertEqual(RealtimeSession.url(model:VoiceSessionConfiguration.model).absoluteString,"wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")
        let fallback=VoiceSessionConfiguration.reasoningEvent(effort:"invalid")["session"] as? [String:Any]
        XCTAssertEqual((fallback?["reasoning"] as? [String:String])?["effort"],"minimal")
    }
    @MainActor func testConnectedCoachEffortChangesWithoutReconnect()throws {
        // Quiet: no introduction is being generated, so each change is sent at once (a turn in progress defers it).
        let session=try GameSession(engine:nil);session.state.settings.coachingMode="quiet";let coach=try VoiceCoach(session:session)
        _=try session.openVoice();coach.receive(["type":"session.updated"])
        let lease=session.voiceLease
        var events:[[String:Any]]=[];coach.automationOutbound={events.append($0)}
        for effort in AppSettings.reasoningEfforts {
            var settings=session.state.settings;settings.coachReasoningEffort=effort
            session.updateSettings(settings);coach.settingsChanged()
            if effort != "minimal" {
                let config=try XCTUnwrap(events.last?["session"] as? [String:Any])
                XCTAssertEqual((config["reasoning"] as? [String:String])?["effort"],effort)
                // The next change waits for this one's acknowledgement.
                coach.receive(["type":"session.updated","session":["reasoning":["effort":effort]]]);XCTAssertEqual(coach.activeEffort,effort)
            }
            XCTAssertTrue(coach.connected);XCTAssertEqual(session.voiceLease,lease);XCTAssertFalse(coach.microphone)
        }
        coach.disconnect()
    }
}
