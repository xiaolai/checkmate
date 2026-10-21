import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// V-11: where the voice coach's connection stands is a typed state; the status line is derived from it and nothing
/// compares that line. Silent: the voice double and an injected authorization failure stand in for the provider.
@MainActor final class VoiceConnectionStateTests:XCTestCase {
    private func coach()throws->(GameSession,VoiceCoach) {
        let session=try GameSession(engine:nil);session.state.settings.voiceMicrophone=false;session.state.settings.voiceConsent=true
        return (session,try VoiceCoach(session:session))
    }
    private func waitFor(_ what:String,_ condition:()->Bool)async throws {for _ in 0..<200 {if condition(){return};try await Task.sleep(for:.milliseconds(10))};XCTFail(what)}

    func testEachStateSaysWhereItStands() {
        XCTAssertEqual(VoiceConnectionState.disconnected.text,"Disconnected");XCTAssertNil(VoiceConnectionState.disconnected.problem)
        XCTAssertTrue(VoiceConnectionState.authorizing.inProgress);XCTAssertTrue(VoiceConnectionState.connecting.inProgress)
        XCTAssertFalse(VoiceConnectionState.ready.inProgress);XCTAssertNil(VoiceConnectionState.ready.problem)
        XCTAssertEqual(VoiceConnectionState.failed("Voice connection ended.").problem,"Voice connection ended.")
        XCTAssertEqual(VoiceConnectionState.unavailable(.companionConnected).problem,VoiceUnavailability.companionConnected.message)
        let reasons:[VoiceUnavailability]=[.companionConnected,.practiceOnly,.trainingGameOnly,.networkGame,.reviewNotReadable,.lessonRecording,.previewPlaying,.narrationPlaying]
        for reason in reasons {XCTAssertFalse(reason.message.contains("MCP"),"\(reason) is said in plain words: \(reason.message)");XCTAssertFalse(reason.message.isEmpty)}
        XCTAssertEqual(VoiceUnavailability.companionConnected.message,"Voice is unavailable while Codex is connected to Checkmate.")
        XCTAssertEqual(VoiceCoach.networkGameStatus,VoiceUnavailability.networkGame.message)
        XCTAssertEqual(VoiceCoach.miniReviewUnavailable,VoiceUnavailability.reviewNotReadable.message)
    }

    func testAConnectionMovesThroughTypedStates()async throws {
        let (_,voice)=try coach();voice.voiceDouble=true;defer{voice.disconnect()}
        XCTAssertEqual(voice.connection,.disconnected);XCTAssertEqual(voice.status,"Disconnected")
        voice.connect();XCTAssertEqual(voice.connection,.connecting);XCTAssertTrue(voice.connecting);XCTAssertFalse(voice.connected)
        XCTAssertEqual(voice.status,VoiceConnectionState.connecting.text)
        try await waitFor("the double opens the session"){voice.connection == .ready}
        XCTAssertTrue(voice.connected);XCTAssertFalse(voice.connecting)
        voice.disconnect();XCTAssertEqual(voice.connection,.disconnected);XCTAssertEqual(voice.status,"Disconnected");XCTAssertFalse(voice.connected)
    }

    func testAFailedAuthorizationEndsAsFailedWithItsReason()async throws {
        let (_,voice)=try coach();voice.automationAuthorizationFailure=CheckmateError.unavailable("Fixture sign-in refused.");defer{voice.disconnect()}
        voice.connect();XCTAssertEqual(voice.connection,.authorizing);XCTAssertTrue(voice.connecting)
        try await waitFor("the failure arrives"){voice.connection != .authorizing}
        XCTAssertEqual(voice.connection,.failed("Fixture sign-in refused."));XCTAssertEqual(voice.status,"Fixture sign-in refused.")
        XCTAssertFalse(voice.connecting);XCTAssertFalse(voice.connected)
    }

    func testRefusalsNameTheirTypedReason()throws {
        let (session,voice)=try coach();voice.voiceDouble=true;defer{voice.disconnect()}
        session.setConnection(enabled:true,role:"coach",lease:"companion")
        voice.connect();XCTAssertEqual(voice.connection,.unavailable(.companionConnected));XCTAssertEqual(voice.status,VoiceUnavailability.companionConnected.message)
        XCTAssertEqual(voice.practiceVoiceUnavailability,.companionConnected);XCTAssertEqual(voice.trainingVoiceUnavailability,.companionConnected)
        session.setConnection(enabled:false,role:"coach")
        XCTAssertNil(voice.practiceVoiceUnavailability);XCTAssertEqual(voice.trainingVoiceUnavailability,.trainingGameOnly,"no training game is being played")
        voice.connectionBlocked={true};voice.connectionBlockReason={.previewPlaying}
        voice.connect();XCTAssertEqual(voice.connection,.unavailable(.previewPlaying));XCTAssertEqual(voice.status,VoiceUnavailability.previewPlaying.message)
    }
}
