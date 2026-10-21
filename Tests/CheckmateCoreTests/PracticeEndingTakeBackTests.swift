import XCTest
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// Take Back works after every practice ending alike: checkmate, resignation and a claimed draw. Taking back a move
/// after a resignation or a claimed draw also takes back the ending, so the game continues.
final class PracticeEndingTakeBackTests:XCTestCase {
    @MainActor func testTakeBackAfterResignationContinuesTheGame() throws {
        let s=try GameSession(engine:nil);for uci in ["e2e4","e7e5"]{try s.rules.move(uci:uci)};s.resign();XCTAssertTrue(s.finished)
        XCTAssertTrue(s.canTakeBack,"A resigned game can take back like a mated one");s.undo()
        XCTAssertEqual(s.rules.history,[]);XCTAssertNil(s.state.practice.ending,"Taking back undoes the resignation");XCTAssertFalse(s.finished);XCTAssertEqual(s.message,"Move taken back.")
    }
    @MainActor func testTakeBackAfterClaimedDrawContinuesTheGame() throws {
        let s=try GameSession(engine:nil);for uci in ["g1f3","g8f6","f3g1","f6g8","g1f3","g8f6","f3g1","f6g8"]{try s.rules.move(uci:uci)}
        XCTAssertNotNil(s.claimableDraw);s.claimDraw();XCTAssertTrue(s.finished);XCTAssertTrue(s.canTakeBack);s.undo()
        XCTAssertEqual(s.rules.history.count,6);XCTAssertNil(s.state.practice.ending);XCTAssertFalse(s.finished)
    }
    @MainActor func testTakeBackAfterCheckmateStillWorks() throws {
        let s=try GameSession(engine:nil);for uci in ["f2f3","e7e5","g2g4","d8h4"]{try s.rules.move(uci:uci)};XCTAssertTrue(s.rules.checkmate);XCTAssertTrue(s.canTakeBack);s.undo();XCTAssertEqual(s.rules.history.count,2)
    }
}
