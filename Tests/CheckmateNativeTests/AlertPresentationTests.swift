import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain

/// What an error alert says, and how a confirmation of something that cannot be undone is built.
@MainActor final class AlertPresentationTests:XCTestCase {
    func testAFailureSaysWhatHappenedNeverAContractCode(){
        XCTAssertEqual(GameWindow.failureMessage(CheckmateError.invalid("ROLE_FORBIDDEN")),"This move can’t be played now. Wait for your turn.")
        XCTAssertEqual(GameWindow.failureMessage(CheckmateError.invalid("INVALID_MOVE")),"That action is not available right now.","an MCP code is not shown to a person")
        XCTAssertEqual(GameWindow.failureMessage(CheckmateError.unavailable("ENGINE_UNAVAILABLE")),"That action is not available right now.")
        XCTAssertEqual(GameWindow.failureMessage(CheckmateError.invalid("That lesson is not available.")),"That lesson is not available.","a sentence is shown as written")
        XCTAssertEqual(GameWindow.failureMessage(CocoaError(.fileReadNoPermission)),"That action could not be completed.")
    }
    func testAFailureAlertCarriesTheRecoverySuggestion(){
        let error=NSError(domain:"test",code:1,userInfo:[NSLocalizedRecoverySuggestionErrorKey:"Choose another file."])
        let alert=GameWindow.failureAlert(error)
        XCTAssertEqual(alert.messageText,"That action could not be completed.");XCTAssertEqual(alert.informativeText,"Choose another file.")
        XCTAssertEqual(GameWindow.failureAlert(CheckmateError.stale).informativeText,"","no suggestion, no informative text")
    }
    func testADestructiveConfirmationDefaultsToCancel(){
        let alert=NSAlert.destructive("Resign this game?","The game is recorded as a loss.",action:"Resign")
        XCTAssertEqual(alert.messageText,"Resign this game?");XCTAssertEqual(alert.informativeText,"The game is recorded as a loss.")
        XCTAssertEqual(alert.buttons.map(\.title),["Resign","Cancel"])
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction,"the action is marked destructive");XCTAssertEqual(alert.buttons[0].keyEquivalent,"","Return never runs it")
        XCTAssertFalse(alert.buttons[1].hasDestructiveAction);XCTAssertEqual(alert.buttons[1].keyEquivalent,"\r","Cancel is the default button")
    }
}
