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
    /// The variants: another word for Cancel, a safe alternative beside it, and accessibility identifiers for the gates.
    /// Cancel stays the default in every one, and the alternative takes no key either.
    func testEveryVariantKeepsCancelTheDefault(){
        let alert=NSAlert.destructive("Your latest progress could not be saved.","Export it.",action:"Quit Anyway",cancel:"Keep Working",alternative:"Export Progress…",identifier:"progress-quit")
        XCTAssertEqual(alert.buttons.map(\.title),["Quit Anyway","Keep Working","Export Progress…"],"action, Cancel, alternative: the responses are first, second, third")
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction);XCTAssertEqual(alert.buttons[0].keyEquivalent,"")
        XCTAssertEqual(alert.buttons[1].keyEquivalent,"\r");XCTAssertTrue(alert.window.defaultButtonCell===alert.buttons[1].cell,"the renamed Cancel is the default")
        XCTAssertFalse(alert.buttons[2].hasDestructiveAction);XCTAssertEqual(alert.buttons[2].keyEquivalent,"","Return never picks the alternative over Cancel")
        XCTAssertEqual(alert.buttons.map{$0.accessibilityIdentifier()},["progress-quit-confirm","progress-quit-cancel","progress-quit-alternative"])
    }
    /// Save before leaving follows the Mac: Return saves, Escape cancels, and Don't Save is destructive with no key.
    func testSaveChangesDefaultsToSave(){
        let alert=NSAlert.saveChanges("Save this review before leaving?","Unsaved.")
        XCTAssertEqual(alert.buttons.map(\.title),["Save","Cancel","Don’t Save"],"Save, Cancel, Don't Save: the responses are first, second, third")
        XCTAssertEqual(alert.buttons[0].keyEquivalent,"\r");XCTAssertTrue(alert.window.defaultButtonCell===alert.buttons[0].cell,"Save is the default")
        XCTAssertEqual(alert.buttons[1].keyEquivalent,"\u{1b}")
        XCTAssertTrue(alert.buttons[2].hasDestructiveAction);XCTAssertEqual(alert.buttons[2].keyEquivalent,"","Return or Escape never discards")
    }
    /// The keys themselves, sent to the alert's own window as AppKit delivers them (never shown): Return and Escape
    /// both cancel a destructive confirmation, whatever Cancel is called; before leaving, Return saves and Escape cancels.
    func testReturnAndEscapeNeverRunTheDestructiveChoice(){
        for alert in [NSAlert.destructive("Resign this game?","Lost.",action:"Resign"),NSAlert.destructive("Quit?","Unsaved.",action:"Quit Anyway",cancel:"Keep Working",alternative:"Export Progress…")] {
            let cancel=alert.buttons[1].title
            XCTAssertEqual(Self.pressed("\r",36,in:alert),cancel,"Return cancels \(alert.messageText)");XCTAssertEqual(Self.pressed("\u{1b}",53,in:alert),cancel,"Escape cancels \(alert.messageText)")
        }
        let save=NSAlert.saveChanges("Save this review before leaving?","Unsaved.")
        XCTAssertEqual(Self.pressed("\r",36,in:save),"Save");XCTAssertEqual(Self.pressed("\u{1b}",53,in:save),"Cancel")
    }
    /// Which button a key press reaches: the window is asked for it as a key equivalent first, then as a key press.
    private static func pressed(_ key:String,_ code:UInt16,in alert:NSAlert)->String? {
        alert.layout();let recorder=PressRecorder()
        for button in alert.buttons{button.target=recorder;button.action=#selector(PressRecorder.press(_:))}
        for type in [NSEvent.EventType.keyDown,.keyUp] {
            let event=NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:0,windowNumber:alert.window.windowNumber,context:nil,characters:key,charactersIgnoringModifiers:key,isARepeat:false,keyCode:code)!
            if type == .keyDown, !alert.window.performKeyEquivalent(with:event){alert.window.sendEvent(event)} else if type == .keyUp{alert.window.sendEvent(event)}
        }
        return recorder.title
    }
    @MainActor private final class PressRecorder:NSObject {var title:String?;@objc func press(_ sender:NSButton){title=title ?? sender.title}}
    /// Every confirmation of something destructive is built by `NSAlert.destructive` (or `saveChanges`), so none can leave Return on it.
    func testNoDestructiveAlertIsHandBuilt()throws {
        let sources=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files=try XCTUnwrap(FileManager.default.enumerator(at:sources,includingPropertiesForKeys:nil)).compactMap{$0 as? URL}.filter{$0.pathExtension=="swift"}
        var builders=0
        for file in files where try String(contentsOf:file,encoding:.utf8).contains("hasDestructiveAction") {
            XCTAssertEqual(file.lastPathComponent,"Helpers.swift","\(file.lastPathComponent) hand-builds a destructive alert; use NSAlert.destructive or saveChanges");builders+=1
        }
        XCTAssertEqual(builders,1,"the builder itself was found")
    }
}
