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

    /// Everything the learner can press that reaches OpenAI goes through the question: Connect on the bar, the network
    /// page and Settings, a mini-game review's Read Aloud, Check availability and Preview voice.
    func testEveryConnectButtonAsksFirst()throws {
        let (model,asked)=try model(answer:.cancel);defer{model.shutdown()}
        model.connectPracticeVoice();model.connectNetworkVoice();model.connectVoiceFromSettings()
        model.readMiniReviewAloud();model.checkVoiceAvailability();model.previewVoice()
        XCTAssertEqual(asked(),6);XCTAssertEqual(model.voice.connectRequests,[],"nothing connects without consent")
        XCTAssertEqual(model.voice.availability,"Not checked");XCTAssertFalse(model.voicePreview.playing);XCTAssertEqual(model.voicePreview.status,"")
    }

    /// Below the buttons, every door into an OpenAI session refuses on its own without consent, so a new caller that
    /// skips the question still reaches nothing: the coach's connections, Read Aloud (with or without a sign-in check),
    /// Check availability and the voice preview.
    func testNothingReachesOpenAIWithoutConsent()async throws {
        let model=try NativeModel();defer{model.shutdown()};let voice=model.voice,refusal=VoiceUnavailability.consentNeeded.message
        XCTAssertFalse(model.session.state.settings.voiceConsent)
        voice.connect();voice.connect(greet:false);voice.connectTraining();voice.readMiniReviewAloud();voice.readMiniReviewAloudAfterSignIn()
        XCTAssertEqual(voice.connectRequests,[]);XCTAssertFalse(voice.connecting)
        let secret=await voice.checkAvailability().value
        XCTAssertNil(secret);XCTAssertEqual(voice.availability,refusal,"the check authorizes nothing")
        model.voicePreview.play(voice:"marin",language:"English",model:"gpt-realtime-2.1",volume:1)
        XCTAssertFalse(model.voicePreview.playing);XCTAssertEqual(model.voicePreview.status,refusal)
    }

    /// Structural: in the voice coach and the preview, every call that authorizes with OpenAI or opens its socket sits
    /// in a function that checks consent before it. Elsewhere only the model probe (reached through the coach) and
    /// lesson recording (its own choice, disclosed in About) may open one.
    func testEveryOpenAIDoorChecksConsentFirst()throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let contact=try NSRegularExpression(pattern:#"gateway\.[a-zA-Z]+\(|\.authorize\(|VoiceSocket\.open\(|VoiceGateway\(\)\.|(?<!func )resolveModel\(|supportsCoach\("#),guardCall=try NSRegularExpression(pattern:#"guard [^;\n]*onsent"#)
        let gated=["Sources/CheckmateMacPlatform/VoiceCoach.swift","Sources/CheckmateMacPlatform/VoicePreview.swift"]
        let allowed=["Sources/CheckmateContent/VoiceModelSelection.swift","Sources/CheckmateContent/LessonRecording.swift"]
        let files=try XCTUnwrap(FileManager.default.enumerator(at:root.appendingPathComponent("Sources"),includingPropertiesForKeys:nil)).compactMap{$0 as? URL}.filter{$0.pathExtension=="swift"}
        var checked=0
        for file in files {
            let path=String(file.path.dropFirst(root.path.count+1)),text=try String(contentsOf:file,encoding:.utf8)
            guard contact.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) != nil else{continue}
            if allowed.contains(path){continue}
            XCTAssertTrue(gated.contains(path),"\(path) reaches OpenAI outside the consent gate")
            // Each contact is preceded, within its own function, by a consent guard.
            var function=""
            for line in text.components(separatedBy:"\n") {
                if let start=line.range(of:"func "){function=String(line[start.lowerBound...])} else{function+="\n"+line}
                for match in contact.matches(in:line,range:NSRange(line.startIndex...,in:line)) {
                    let before=String(function[..<(function.range(of:String(line[Range(match.range,in:line)!]),options:.backwards)?.lowerBound ?? function.endIndex)])
                    checked+=1
                    XCTAssertNotNil(guardCall.firstMatch(in:before,range:NSRange(before.startIndex...,in:before)),"\(path): \(line.trimmingCharacters(in:.whitespaces).prefix(120)) is not behind a consent check")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked,8,"the scan found the coach's and the preview's calls")
    }

    /// The sheet says what is sent, to whom, on whose plan, and when the microphone listens.
    func testTheSheetNamesWhatIsSentAndWhere() {
        let text=VoiceConsent.explanation
        for phrase in ["OpenAI","ChatGPT","Codex","microphone"] {XCTAssertTrue(text.contains(phrase),"the sheet mentions \(phrase): \(text)")}
        XCTAssertTrue(text.contains(VoiceConsent.sentToOpenAI),"the same words as About")
    }
}
