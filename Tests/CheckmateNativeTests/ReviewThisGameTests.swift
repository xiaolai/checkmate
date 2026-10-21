import XCTest
import AppKit
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
