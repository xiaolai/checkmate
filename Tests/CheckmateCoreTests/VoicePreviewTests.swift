import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// D6: the voice selected in Settings is the one previewed. A separate preview session carries no microphone, tools
/// or conversation, and a listening coach pauses while it plays. No network, no audio.
@MainActor final class VoicePreviewTests:XCTestCase {
    func testPreviewSessionHasNoInputToolsOrConversation()throws {
        let session=try XCTUnwrap(VoicePreview.sessionEvent(voice:"marin")["session"] as? [String:Any])
        XCTAssertEqual(((session["audio"] as? [String:Any])?["output"] as? [String:Any])?["voice"] as? String,"marin")
        XCTAssertNil((session["audio"] as? [String:Any])?["input"],"no microphone input is configured");XCTAssertEqual((session["tools"] as? [Any])?.count,0)
        let response=try XCTUnwrap(VoicePreview.greetingEvent(language:"Spanish")["response"] as? [String:Any])
        XCTAssertEqual(response["conversation"] as? String,"none");XCTAssertEqual(response["tool_choice"] as? String,"none");XCTAssertTrue((response["instructions"] as? String ?? "").contains("Spanish"))
    }
    func testAutomationNeverPreviews() {
        let preview=VoicePreview();var blockedAsked=false;preview.blocked={blockedAsked=true;return nil};preview.consented={true}
        preview.play(voice:"marin",language:"English",model:"gpt-realtime-2.1",volume:1)
        XCTAssertFalse(preview.playing);XCTAssertFalse(blockedAsked);XCTAssertEqual(preview.status,"Live voice previews are disabled during automation.")
    }
    /// V-1: a preview opens an OpenAI session, so it plays only after the learner has agreed; without being told, it never does.
    func testNoPreviewWithoutConsent() {
        let preview=VoicePreview()
        preview.play(voice:"marin",language:"English",model:"gpt-realtime-2.1",volume:1)
        XCTAssertFalse(preview.playing);XCTAssertEqual(preview.status,VoiceUnavailability.consentNeeded.message)
    }
    func testAListeningCoachPausesForAPreview() {
        XCTAssertTrue(VoiceCoach.listens(ready:true,idle:true,externalPlayback:false,microphoneOn:true,capturing:true,silent:false))
        XCTAssertFalse(VoiceCoach.listens(ready:true,idle:true,externalPlayback:true,microphoneOn:true,capturing:true,silent:false),"the coach heard the preview")
    }
}
