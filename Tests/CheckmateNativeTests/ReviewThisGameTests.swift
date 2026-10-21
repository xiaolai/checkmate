import XCTest
import AppKit
import SwiftUI
@testable import CheckmateNative
import CheckmateCore

/// B-7: a finished practice game sums itself up and offers its review, and Review Current Game has a shortcut of its own.
@MainActor final class ReviewThisGameTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    func testTheSummaryGivesTheResultAndTheMovesPlayed() {
        XCTAssertEqual(DetailContent.practiceSummary(result:"1-0",plies:45),"1–0 · 23 moves")
        XCTAssertEqual(DetailContent.practiceSummary(result:"1/2-1/2",plies:1),"½–½ · 1 move")
        XCTAssertEqual(DetailContent.practiceSummary(result:"0-1",plies:4),"0–1 · 2 moves")
    }
    /// The finished game's card offers its review without taking Return: the board's keyboard play and the coach's
    /// question field keep it, so nothing in the window claims Return as a key equivalent.
    func testAFinishedGameLeavesReturnToTheBoard()throws {
        let model=try NativeModel(),relationships=RelationshipController()
        defer{model.shutdown()}
        try model.session.playWhite(from:"e2",to:"e4");model.session.resign();XCTAssertTrue(model.session.finished);XCTAssertTrue(model.canReviewCurrent)
        let host=NSHostingView(rootView:DetailContent(session:model.session,learning:model.learning,model:model,voice:model.voice,relationships:relationships,inspect:{_ in}))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:360,height:900),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=host
        defer{window.close()};window.orderFront(nil);window.layoutIfNeeded()
        for _ in 0..<20{RunLoop.main.run(until:Date().addingTimeInterval(0.02))}
        let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36))
        XCTAssertFalse(window.performKeyEquivalent(with:event),"the card claims Return");XCTAssertNil(window.defaultButtonCell)
        XCTAssertFalse(model.review.active,"Return did not open the review")
    }
    /// Shift-Command-R opens the current game's review, and no other menu item uses that key.
    func testReviewCurrentGameHasAShortcutNoOtherItemUses()throws {
        let model=try NativeModel(),game=GameWindow(model:model),app=AppDelegate(),before=NSApp.mainMenu
        defer{NSApp.mainMenu=before;game.window?.delegate=nil;model.shutdown()}
        app.model=model;app.installMenus(window:game,model:model)
        func items(_ menu:NSMenu?)->[NSMenuItem] {(menu?.items ?? []).flatMap{[$0]+items($0.submenu)}}
        let all=items(NSApp.mainMenu),review=try XCTUnwrap(all.first{$0.title=="Review Current Game"})
        XCTAssertEqual(review.keyEquivalent,"r");XCTAssertEqual(review.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask),[.command,.shift])
        // An upper-case key equivalent implies Shift.
        func chord(_ item:NSMenuItem)->String {let key=item.keyEquivalent,shift=key != key.lowercased();return "\(item.keyEquivalentModifierMask.union(shift ? .shift:[]).intersection(.deviceIndependentFlagsMask).rawValue)-\(key.lowercased())"}
        let chords=all.filter{!$0.keyEquivalent.isEmpty}.map(chord)
        XCTAssertEqual(chords.filter{$0==chord(review)}.count,1,"another menu item uses Shift-Command-R")
    }
}
