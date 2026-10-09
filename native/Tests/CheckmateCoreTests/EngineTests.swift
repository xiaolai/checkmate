import XCTest
@testable import CheckmateCore
final class EngineTests:XCTestCase {
    @MainActor func testBundledEngineProducesLegalWhiteAndBlackLines() async throws {
        let engine=NativeEngine(),rules=try ChessRules()
        for _ in 0..<2 {let result=try await engine.analyze(fen:rules.fen,skill:0,budget:100,multiPv:2);let move=try XCTUnwrap(result.bestMove);XCTAssertTrue(rules.moves().contains{$0.uci==move});for line in result.lines{let copy=try rules.copy();for uci in line.pv{_ = try copy.move(uci:uci)}};_ = try rules.move(uci:move)}
    }
    @MainActor func testCancelledSearchDoesNotReturnMove() async throws {let engine=NativeEngine();let task=Task{try await engine.analyze(fen:ChessRules().fen,skill:20,budget:1000,multiPv:3)};try await Task.sleep(nanoseconds:30_000_000);task.cancel();do{_ = try await task.value;XCTFail("Cancelled engine returned a result")}catch{}}
    @MainActor func testLateReplyCannotChangeNewGame() async throws {let engine=DelayedEngine(),s=try GameSession(engine:engine);try s.playWhite(from:"e2",to:"e4");try await Task.sleep(nanoseconds:10_000_000);s.newGame();try await Task.sleep(nanoseconds:100_000_000);XCTAssertEqual(s.rules.history,[]);XCTAssertFalse(s.busy)}
}
@MainActor private final class DelayedEngine:EngineService {func analyze(fen:String,skill:Int,budget:Int,multiPv:Int) async throws->EngineAnalysis{try? await Task.sleep(nanoseconds:60_000_000);return EngineAnalysis(bestMove:"e7e5")}}
