import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore

/// The board area's hosted views must not size the window. With its default sizing options the review workspace's
/// NSHostingView turned its SwiftUI sizes into constraints, hidden or not; a drawer moving the window frame then made
/// AppKit change the frame from those constraints, the hosted views asked for another constraint pass, and AppKit
/// raised in -[NSWindow _postWindowNeedsUpdateConstraints], ending the app.
@MainActor final class ReviewWorkspaceSizingTests:XCTestCase {
    private func settle(_ seconds:TimeInterval){RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
    func testReviewWorkspaceTakesNoSizeFromItsContent() throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        XCTAssertEqual(game.reviewWorkspaceView.sizingOptions,[])
    }
    /// The layout gate's own moves: each drawer opens and closes while the window is on screen. A constraint loop
    /// raises an exception that ends this process, so the test fails by crashing rather than by an assertion.
    func testDrawersMoveTheWindowWithoutAConstraintLoop() throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.orderOut(nil);game.window?.delegate=nil;model.shutdown()}
        let window=try XCTUnwrap(game.window);window.orderFront(nil);settle(0.5)
        let initial=window.frame
        for left in [true,false,true,false] {(left ? game.toggleLeft:game.toggleRight)();settle(0.8);window.layoutIfNeeded()}
        XCTAssertEqual(window.frame.width,initial.width,accuracy:1,"both drawers are closed again")
    }
}
