import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// L-25: a finished mini-game's review sheet can be made larger than its readable minimum instead of staying 420 points
/// wide, and each fact offers Show on Board only where the board can show it.
@MainActor final class MiniGameReviewSheetTests:XCTestCase {
    func review()->MiniGameReview {
        var game=MiniGameState(kind:.rookSweep,computer:true);game.snapshot.board=["a1":"wr","h2":"wp","e5":"br","a7":"bp"]
        for move in [("a1","b1"),("e5","h5"),("b1","b2"),("h5","h2")] {XCTAssertTrue(game.play(MiniGameMove(from:move.0,to:move.1)))}
        return MiniGameReview.run(game,cpuSeconds:{0},stop:{false})
    }
    func testTheSheetIsResizableFromItsReadableWidth()throws {
        let session=try GameSession(engine:nil),voice=try VoiceCoach(session:session),review=review()
        let window=MiniGameReviewSheet.window(MiniGameReviewSheet(review:review,voice:voice,read:{},close:{},show:nil))
        defer{window.close()}
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize.width,MiniGameReviewSheet.minimumWidth,accuracy:1,"no narrower than the text was written for")
        XCTAssertGreaterThan(window.contentMaxSize.width,MiniGameReviewSheet.minimumWidth*2,"and free to grow")
        XCTAssertEqual(window.title,"Rook Sweep review")
    }
}
