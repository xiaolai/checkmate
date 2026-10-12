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
        player.click("g7");XCTAssertTrue(player.picked.isEmpty)
        for (from,to) in [("g2","g4"),("f7","f5"),("g4","f5"),("g7","g6"),("f5","g6"),("b7","b6"),("g6","g7"),("b6","b5"),("g7","g8")] {
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
