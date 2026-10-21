import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// V-1: the first Connect the learner presses asks once what voice sends and where; only a confirmed answer connects,
/// and it is remembered. The sheet is replaced by an injected answer; nothing connects for real.
@MainActor final class VoiceConsentTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    /// A model whose consent sheet answers `answer` and counts how often it was shown.
    private func model(answer:VoiceConsentAnswer)throws->(NativeModel,()->Int) {
        let model=try NativeModel();var asked=0
        model.askVoiceConsent={autoConnect,reply in asked+=1;XCTAssertEqual(autoConnect,model.session.state.settings.voiceAutoConnect,"the checkbox starts from the saved choice");reply(answer)}
        return (model,{asked})
    }

    func testTheFirstConnectAsksAndAConfirmedAnswerIsRemembered()throws {
        let (model,asked)=try model(answer:.connect(autoConnect:true));defer{model.shutdown()}
        XCTAssertFalse(model.session.state.settings.voiceConsent);XCTAssertFalse(model.session.state.settings.voiceAutoConnect,"a new install is opted out")
        var connects=0
        model.connectVoiceWithConsent{connects+=1}
        XCTAssertEqual(asked(),1);XCTAssertEqual(connects,1)
        XCTAssertTrue(model.session.state.settings.voiceConsent);XCTAssertTrue(model.session.state.settings.voiceAutoConnect,"the checkbox turned on connecting at launch")
        model.connectVoiceWithConsent{connects+=1}
        XCTAssertEqual(asked(),1,"the sheet is shown once");XCTAssertEqual(connects,2)
        try model.store.save(model.session.state)
        XCTAssertTrue(try model.store.load().settings.voiceConsent,"consent is saved")
    }

    func testCancelConnectsNothingAndAsksAgainNextTime()throws {
        let (model,asked)=try model(answer:.cancel);defer{model.shutdown()}
        var connects=0
        model.connectVoiceWithConsent{connects+=1};model.connectVoiceWithConsent{connects+=1}
        XCTAssertEqual(connects,0);XCTAssertEqual(asked(),2);XCTAssertFalse(model.session.state.settings.voiceConsent)
        XCTAssertFalse(model.session.state.settings.voiceAutoConnect)
    }

    func testLeavingTheCheckboxOffKeepsLaunchConnectionOff()throws {
        let (model,_)=try model(answer:.connect(autoConnect:false));defer{model.shutdown()}
        var connects=0;model.connectVoiceWithConsent{connects+=1}
        XCTAssertEqual(connects,1);XCTAssertTrue(model.session.state.settings.voiceConsent);XCTAssertFalse(model.session.state.settings.voiceAutoConnect)
    }

    /// Every Connect the learner can press goes through the question: the bar, the network page and Settings.
    func testEveryConnectButtonAsksFirst()throws {
        let (model,asked)=try model(answer:.cancel);defer{model.shutdown()}
        model.connectPracticeVoice();model.connectNetworkVoice();model.connectVoiceFromSettings()
        XCTAssertEqual(asked(),3);XCTAssertEqual(model.voice.connectRequests,[],"nothing connects without consent")
    }

    /// The sheet says what is sent, to whom, on whose plan, and when the microphone listens.
    func testTheSheetNamesWhatIsSentAndWhere() {
        let text=VoiceConsent.explanation
        for phrase in ["OpenAI","ChatGPT","Codex","microphone"] {XCTAssertTrue(text.contains(phrase),"the sheet mentions \(phrase): \(text)")}
        XCTAssertTrue(text.contains(VoiceConsent.sentToOpenAI),"the same words as About")
    }
}
