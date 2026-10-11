import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


final class PawnDuelInteractionTests:XCTestCase {
    @MainActor func testBothSidesCanMoveCaptureAndFinishPawnDuel()throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        player.openLesson(index:3);player.startPawnDuel(computer:false)
        player.click("h7");XCTAssertTrue(player.picked.isEmpty)
        for (from,to) in [("g2","g4"),("h7","h5"),("g4","h5"),("g7","g6"),("h5","h6"),("g6","g5"),("h6","h7"),("g5","g4"),("h7","h8")] {
            let side=player.miniTurn
            player.click(from);XCTAssertEqual(player.picked,[from])
            XCTAssertTrue(player.destinations.contains(to),"\(from) → \(to)")
            player.click(to);XCTAssertEqual(player.frame.board?[to],side+"p")
            XCTAssertNil(player.frame.board?[from]);XCTAssertTrue(player.picked.isEmpty)
            XCTAssertNotEqual(player.miniTurn,side)
        }
        XCTAssertEqual(player.winner,"w")
        let finished=player.frame.board;player.click("a7");player.click("a6")
        XCTAssertEqual(player.frame.board,finished)
    }
}
