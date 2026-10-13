import XCTest
import CheckmateDomain
import CheckmateRules
import CheckmateEngine
import CheckmateApplication

final class ModulePortTests:XCTestCase {
    @MainActor final class HistoryEngine:EngineService {
        var binaryIdentity="contract-engine",capabilities=EngineCapabilities()
        var request:(String,[String],OpponentProfile,[String])?
        func prepare()async throws {}
        func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {XCTFail("Session must use the history port");return EngineAnalysis()}
        func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String])async throws -> EngineAnalysis {
            request=(startFEN,moves,profile,searchMoves);return EngineAnalysis(bestMove:"g1f3")
        }
    }
    @MainActor func testSessionForwardsHistoryAndStrengthThroughPort()async throws {
        let engine=HistoryEngine(),rules=try ChessRules();let start=rules.fen
        try rules.move(uci:"e2e4");try rules.move(uci:"e7e5")
        var state=ApplicationState();state.practice.pgn=rules.pgn;state.practice.fen=rules.fen;state.settings.opponentMode="elo";state.settings.opponentElo=1700
        let session=try GameSession(engine:nil,state:state)
        _ = try await session.chooseOpponentMove(engine:engine)
        XCTAssertEqual(engine.request?.0,start);XCTAssertEqual(engine.request?.1,["e2e4","e7e5"]);XCTAssertEqual(engine.request?.2,.elo(1700));XCTAssertEqual(engine.request?.3,[])
    }
    final class CountingRuntime:ChessScriptRuntime {
        let underlying=try! JavaScriptCoreChessRuntime()
        func evaluate(_ script:String)throws -> String {try underlying.evaluate(script)}
    }
    func testRulesCopyAndRestoreRetainRuntimeFactory()throws {
        var creations=0
        let rules=try ChessRules(runtimeFactory:{creations+=1;return CountingRuntime()})
        try rules.move(uci:"e2e4");let copy=try rules.copy()
        XCTAssertEqual(copy.fen,rules.fen);XCTAssertEqual(creations,2)
        try copy.move(uci:"e7e5");XCTAssertNotEqual(copy.fen,rules.fen)
        XCTAssertThrowsError(try rules.restore("not a valid game???"));XCTAssertEqual(rules.history,["e4"])
    }
    @MainActor func testInvalidWorkspaceEntryIsStagedWithoutMutatingSession()throws {
        let session=try GameSession(engine:nil),learning=try LearningPlayer(session:session),review=ReviewController()
        let coordinator=WorkspaceTransitionCoordinator(session:session,learning:learning,review:review),before=session.activity,fen=session.rules.fen
        XCTAssertThrowsError(try coordinator.prepare(.lesson(10_000)))
        XCTAssertEqual(session.activity,before);XCTAssertEqual(session.rules.fen,fen);XCTAssertFalse(review.active)
        let prepared=try coordinator.prepare(.reviewWorkspace)
        XCTAssertEqual(session.activity,before)
        try coordinator.enter(prepared:prepared,from:before.place,wasReviewing:false)
        XCTAssertTrue(session.activity.inReviewWorkspace)
    }
}
