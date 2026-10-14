import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// How the live session listens: it waits through a thinking pause, and transcription is told a language only when
/// the learner chose one. Configuration only: no network, no audio.
final class VoiceSessionSettingsTests:XCTestCase {
    private func input(_ event:[String:Any])->[String:Any] {((event["session"] as? [String:Any])?["audio"] as? [String:Any])?["input"] as? [String:Any] ?? [:]}
    func testTurnDetectionWaitsForThinkingPauses() {
        let detection=input(VoiceSessionConfiguration.event(instructions:"",voice:"cedar",tools:[]))["turn_detection"] as? [String:Any]
        XCTAssertEqual(detection?["type"] as? String,"semantic_vad");XCTAssertEqual(detection?["eagerness"] as? String,"low")
        XCTAssertEqual(detection?["create_response"] as? Bool,false)
    }
    func testTranscriptionLanguageOnlyWhenChosen() {
        XCTAssertNil((input(VoiceSessionConfiguration.event(instructions:"",voice:"cedar",tools:[]))["transcription"] as? [String:Any])?["language"])
        XCTAssertEqual((input(VoiceSessionConfiguration.event(instructions:"",voice:"cedar",tools:[],inputLanguage:"zh"))["transcription"] as? [String:Any])?["language"] as? String,"zh")
        var settings=AppSettings();XCTAssertEqual(settings.voiceInputLanguage,"auto");XCTAssertNil(VoiceCoach.inputLanguage(settings))
        settings.voiceInputLanguage="response";settings.voiceLanguage="es";XCTAssertEqual(VoiceCoach.inputLanguage(settings),"es")
        XCTAssertEqual(AppSettings(raw:["voiceInputLanguage":"klingon"]).voiceInputLanguage,"auto");XCTAssertEqual(AppSettings(raw:["voiceInputLanguage":"response"]).voiceInputLanguage,"response")
    }
    @MainActor func testChangingTheSpokenLanguageUpdatesTranscriptionOnly()throws {
        let s=try GameSession(engine:nil);s.state.settings.coachingMode="quiet";let v=try VoiceCoach(session:s);var events:[[String:Any]]=[];v.automationOutbound={events.append($0)}
        _ = try s.openVoice();v.receive(["type":"session.updated"]);defer{v.disconnect()}
        var settings=s.state.settings;settings.voiceInputLanguage="response";settings.voiceLanguage="en";s.updateSettings(settings);v.settingsChanged()
        XCTAssertEqual((input(events.last ?? [:])["transcription"] as? [String:Any])?["language"] as? String,"en")
        settings.voiceInputLanguage="auto";s.updateSettings(settings);v.settingsChanged()
        let transcription=input(events.last ?? [:])["transcription"] as? [String:Any];XCTAssertNotNil(transcription);XCTAssertNil(transcription?["language"])
    }
}
