import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-010: each family of existing mini-games, grouped by the simplified rule it shares, links one reviewed
/// normal-chess case that names the difference. Opening a bridge never changes the old game or the course.
@MainActor final class TrainingBridgeTests:XCTestCase {
    // Increment B is gated behind its preview flags; these tests exercise it as development does.
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    func testEveryExistingGameReachesAReviewedNormalChessBridge()throws {
        let provider=try TrainingScenarioProvider.bundled()
        for kind in MiniGameKind.allCases {
            let bridge=try XCTUnwrap(provider.bridge(for:kind),"\(kind.rawValue) has no bridge")
            XCTAssertEqual(bridge.bridge,kind.bridgeFamily)
            let entry=try XCTUnwrap(provider.catalog.entry(bridge.entry))
            XCTAssertEqual(entry.ruleMode,.standardChess,"a bridge is normal chess, never the variant's rules")
            XCTAssertTrue(bridge.explanation.contains("in chess"),"\(bridge.id) contrasts the mini-game with chess")
            XCTAssertNotNil(bridge.review)
        }
        // Each family has exactly one bridge, so a game always opens the same contrast.
        let families=Set(MiniGameKind.allCases.map(\.bridgeFamily))
        XCTAssertEqual(families,[.pawnDuel,.rookSweep,.knightCapture,.knightCorners])
        for family in families{XCTAssertEqual(provider.scenarios(for:"special-moves").filter{$0.bridge==family}.count+provider.scenarios(for:"capture-wisely").filter{$0.bridge==family}.count+provider.scenarios(for:"save-your-piece").filter{$0.bridge==family}.count,1)}
    }
    func testOpeningABridgeLeavesTheOldGameAndCourseAlone()throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session);defer{player.shutdown()}
        let training=TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider.bundled())
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        let before=try encoder.encode(session.state.miniGames),course=try encoder.encode(session.state.course)
        let bridge=try XCTUnwrap(training.provider?.bridge(for:.queenVsPawns))
        training.begin(try training.prepare(scenario:bridge.id))
        XCTAssertEqual(training.exercise?.scenario.id,bridge.id)
        let accepted=try XCTUnwrap(bridge.nodes?.first?.accepted.first)
        training.attempt(from:String(accepted.prefix(2)),to:String(accepted.dropFirst(2).prefix(2)),promotion:accepted.count==5 ? String(accepted.suffix(1)):nil)
        XCTAssertEqual(training.exercise?.status,.correct)
        XCTAssertEqual(try encoder.encode(session.state.miniGames),before);XCTAssertEqual(try encoder.encode(session.state.course),course)
        XCTAssertEqual(MiniGameKind.queenVsPawns.title,"Queen Against Pawns","the old game keeps its identity")
    }
    func testABridgeCanBeWithdrawnWithoutTouchingTheGame()throws {
        let provider=try TrainingScenarioProvider.bundled()
        let bridge=try XCTUnwrap(provider.bridge(for:.knightCorners))
        provider.suspend(bridge.id)
        XCTAssertNil(provider.bridge(for:.knightCorners),"a withdrawn bridge is simply not offered")
        XCTAssertNotNil(provider.catalog.entry("knight-corners"),"the game itself stays")
    }
}
