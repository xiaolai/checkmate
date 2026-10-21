import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateApplication

/// A learner's command that fails says so where the learner is looking; none is dropped silently. Hint opens the drawer
/// that shows it.
@MainActor final class NativeActionFailureTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    func testANavigationThatFailsSaysWhy()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let place=model.session.activity.place
        model.lesson(9999)
        XCTAssertEqual(model.storageError,"That lesson is not available.","the failed entry is said, not swallowed")
        XCTAssertEqual(model.session.activity.place,place,"nothing changed")
    }
    func testAPracticeActionThatFailsIsSaidInTheDrawer()throws {
        let s=try GameSession(engine:nil)
        try s.playWhite(from:"e2",to:"e4");s.resign();XCTAssertNil(s.error)
        DetailContent.attempt(s){try s.beginPreview()}
        XCTAssertEqual(s.error,GameWindow.failureMessage(CheckmateError.invalid("ROLE_FORBIDDEN")),"a refused Try a move is said, never dropped")
    }
    func testHintOpensTheDetails()throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        game.desiredRight=false
        game.controls.rootView.perform(.hint)
        XCTAssertTrue(game.desiredRight,"the hint is shown in the drawer, so the drawer opens")
    }
}
