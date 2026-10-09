import XCTest
@testable import CheckmateCore
final class GameSessionTests:XCTestCase {
    @MainActor func testCandidateAndDemonstrationNeverChangeRealHistory() async throws {
        let session=try GameSession(engine:nil);let pgn=session.rules.pgn,fen=session.rules.fen
        try session.demonstrate(title:"Opening",introduction:"Imagine",lines:[DemoLineInput(label:"Center",moves:[DemoStepInput(uci:"e2e4"),DemoStepInput(uci:"e7e5")])])
        for _ in 0..<100 {try session.seekDemo(line:0,ply:2);try session.seekDemo(line:0,ply:0)}
        XCTAssertEqual(session.rules.pgn,pgn);XCTAssertEqual(session.rules.fen,fen)
        session.closePresentation();XCTAssertEqual(session.displayBoard,session.rules.board)
    }
    @MainActor func testCaptureTakesPrecedenceOverOpponentInspection() async throws {
        let s=try GameSession(engine:nil);try s.rules.load("4k3/8/8/4p3/3P4/8/8/4K3 w - - 0 1")
        try s.select("d4");try s.select("e5")
        XCTAssertEqual(s.rules.piece("e5")?.color,"w");XCTAssertNil(s.rules.piece("d4"))
    }
}
extension GameSessionTests {
    @MainActor func testUndoCancelsHintWithoutDisplayingStaleError() async throws {let s=try GameSession(engine:SlowHintEngine());s.hint();XCTAssertTrue(s.busy);s.undo();try await Task.sleep(nanoseconds:80_000_000);XCTAssertNil(s.error);XCTAssertEqual(s.coaching.status,"idle");XCTAssertFalse(s.busy)}
}
@MainActor private final class SlowHintEngine:EngineService{func analyze(fen:String,skill:Int,budget:Int,multiPv:Int) async throws->EngineAnalysis{try? await Task.sleep(nanoseconds:50_000_000);return EngineAnalysis(bestMove:"e2e4")}}
extension GameSessionTests {
    @MainActor func testCoachConnectionDoesNotStopStockfish() async throws {let s=try GameSession(engine:CoachReplyEngine());s.setConnection(enabled:true,role:"coach",lease:"coach");try s.playWhite(from:"e2",to:"e4");try await Task.sleep(nanoseconds:50_000_000);XCTAssertEqual(s.rules.history,["e4","e5"])}
    @MainActor func testOpponentConnectionOwnsBlackTurn() async throws {let s=try GameSession(engine:CoachReplyEngine());s.setConnection(enabled:true,role:"opponent",lease:"opponent");try s.playWhite(from:"e2",to:"e4");try await Task.sleep(nanoseconds:50_000_000);XCTAssertEqual(s.rules.history,["e4"])}
}
@MainActor private final class CoachReplyEngine:EngineService{func analyze(fen:String,skill:Int,budget:Int,multiPv:Int) async throws->EngineAnalysis{EngineAnalysis(bestMove:fen.split(separator:" ")[1]=="b" ? "e7e5":"g1f3")}}
extension GameSessionTests {
    @MainActor func testHiddenDemonstrationDoesNotBlockRealMove()throws {let s=try GameSession(engine:nil);try s.demonstrate(title:"Imagine",introduction:"",lines:[DemoLineInput(label:"Pawn",moves:[DemoStepInput(uci:"e2e4")])]);s.selectPresentation(false);try s.playWhite(from:"d2",to:"d4");XCTAssertEqual(s.rules.history,["d4"]);XCTAssertNil(s.demonstration)}
    @MainActor func testGameCommandsCannotMutatePracticeDuringLesson()throws {let s=try GameSession(engine:nil);try s.playWhite(from:"e2",to:"e4");let original=s.rules.pgn;let p=try LearningPlayer(session:s);p.openLesson(index:0);s.undo();s.newGame();try s.restorePrevious();XCTAssertEqual(s.rules.pgn,original)}
    @MainActor func testOpponentDisconnectCanResumeWithStockfish() async throws {let s=try GameSession(engine:CoachReplyEngine());s.setConnection(enabled:true,role:"opponent",lease:"fixture");try s.playWhite(from:"e2",to:"e4");s.setConnection(enabled:false,role:"opponent");XCTAssertTrue(s.pausedOpponent);s.continueWithStockfish();try await Task.sleep(nanoseconds:50_000_000);XCTAssertEqual(s.rules.history,["e4","e5"])}
}
extension GameSessionTests {
    @MainActor func testFirstCoachClaimPreservesLearnerPresentation()throws {let s=try GameSession(engine:nil);s.setConnection(enabled:true,role:"coach");try s.beginPreview();let id=s.preview?.id;s.setConnection(enabled:true,role:"coach",lease:"claim");XCTAssertEqual(s.preview?.id,id)}
    @MainActor func testImportedStateInstallsValidatedBoard()throws {let s=try GameSession(engine:nil);var imported=ApplicationState();let rules=try ChessRules();_ = try rules.move("d2","d4");imported.practice.pgn=rules.pgn;imported.practice.fen=rules.fen;try s.installImportedState(imported);XCTAssertEqual(s.rules.history,["d4"])}
}
extension GameSessionTests {
    @MainActor func testSlowCandidateCannotReplaceNewerPreview() async throws {let s=try GameSession(engine:DelayedCandidateEngine());try s.beginPreview();let first=Task{try await s.testMove(from:"e2",to:"e4")};try await Task.sleep(nanoseconds:5_000_000);try await s.testMove(from:"d2",to:"d4");let current=s.preview?.id;try await first.value;XCTAssertEqual(s.preview?.id,current);XCTAssertEqual(s.preview?.candidate?.to,"d4");XCTAssertEqual(s.rules.history,[])}
}
@MainActor private final class DelayedCandidateEngine:EngineService {var count=0;func analyze(fen:String,skill:Int,budget:Int,multiPv:Int) async throws->EngineAnalysis {count+=1;let delay:UInt64=count==1 ? 80_000_000:2_000_000;try await Task.sleep(nanoseconds:delay);let r=try ChessRules(fen:fen);return EngineAnalysis(bestMove:r.moves().first?.uci)}}
extension GameSessionTests {
    @MainActor func testOpponentReconnectClearsDisconnectPause()throws {let s=try GameSession(engine:nil);s.setConnection(enabled:true,role:"opponent",lease:"first");s.setConnection(enabled:true,role:"opponent");XCTAssertTrue(s.pausedOpponent);s.setConnection(enabled:true,role:"opponent",lease:"second");XCTAssertFalse(s.pausedOpponent)}
    @MainActor func testCancellingGuidedHintClearsThinkingStatus()throws {let s=try GameSession(engine:SlowHintEngine());s.hint();XCTAssertEqual(s.coaching.status,"thinking");try s.beginPreview();XCTAssertEqual(s.coaching.status,"idle")}
}
