import XCTest
@testable import CheckmateCore
final class VoiceTests:XCTestCase {
    func testGenerationDoesNotEndPlayback(){var gate=VoiceTurnGate();gate.begin();XCTAssertFalse(gate.ready);gate.generated(hasAudio:true);XCTAssertFalse(gate.ready);gate.playbackEnded();XCTAssertTrue(gate.ready);gate.begin();gate.playbackEnded();XCTAssertFalse(gate.ready);gate.generated(hasAudio:true);XCTAssertTrue(gate.ready)}
    func testCredentialParsingAndRejections()throws {XCTAssertEqual(try VoiceGateway.accessToken(Data(#"{"tokens":{"access_token":"sample"}}"#.utf8)),"sample");XCTAssertThrowsError(try VoiceGateway.accessToken(Data(#"{"api_key":"no"}"#.utf8)));XCTAssertThrowsError(try VoiceGateway.clientSecret(Data(#"{"value":""}"#.utf8)));XCTAssertEqual(try VoiceGateway.clientSecret(Data(#"{"value":"ephemeral"}"#.utf8)),"ephemeral")}
    func testPCMConversion(){let input:[Float]=[-2,-1,0,0.5,1,2];let data=VoicePCM.encode(input);XCTAssertEqual(data.count,12);let values=VoicePCM.decode(data);XCTAssertEqual(values.count,6);XCTAssertEqual(values[2],0);XCTAssertEqual(values[3],0.5,accuracy:0.001)}
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
