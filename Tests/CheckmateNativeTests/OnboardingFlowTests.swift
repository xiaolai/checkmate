import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateApplication

/// The first-run welcome's three steps (L-20): voice only through the consent question, placement, then the first lesson.
@MainActor final class OnboardingFlowTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    func testTheStepsMoveBothWaysAndStartThePlacedLesson()throws {
        let model=try NativeModel();defer{model.shutdown()}
        var closed=0;let flow=OnboardingFlow(model:model){closed+=1}
        XCTAssertEqual(flow.step,.languageAndVoice);XCTAssertEqual(flow.placement,.new)
        flow.back();XCTAssertEqual(flow.step,.languageAndVoice,"the first step has nothing before it")
        flow.next();XCTAssertEqual(flow.step,.placement);flow.placement = .knowsMoves
        flow.next();XCTAssertEqual(flow.step,.firstMove);flow.next();XCTAssertEqual(flow.step,.firstMove,"the last step ends only by starting or skipping")
        flow.back();XCTAssertEqual(flow.step,.placement);flow.next()
        flow.start()
        XCTAssertEqual(closed,1)
        XCTAssertEqual(model.learning.lessonIndex,Onboarding.lessonIndex(.knowsMoves,in:model.learning.library),"the first move is made in the placed lesson")
    }
    func testSkippingClosesAndChangesNothing()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let before=model.learning.lessonIndex,settings=model.session.state.settings
        var closed=0;let flow=OnboardingFlow(model:model){closed+=1}
        flow.next();flow.placement = .knowsRules;flow.skip()
        XCTAssertEqual(closed,1);XCTAssertEqual(model.learning.lessonIndex,before);XCTAssertEqual(model.session.state.settings,settings)
    }
    func testVoiceIsSetUpOnlyThroughTheConsentQuestion()throws {
        let model=try NativeModel();defer{model.shutdown()}
        var asked=0;model.askVoiceConsent={_,reply in asked+=1;reply(.cancel)}
        let flow=OnboardingFlow(model:model){}
        flow.setUpVoice()
        XCTAssertEqual(asked,1,"setting up the voice coach asks the consent question first")
        XCTAssertFalse(model.session.state.settings.voiceConsent);XCTAssertFalse(model.voice.connected || model.voice.connecting,"Cancel connects nothing")
    }
}
