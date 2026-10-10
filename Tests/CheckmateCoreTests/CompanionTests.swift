import XCTest
@testable import CheckmateCore
final class CompanionTests:XCTestCase {
    @MainActor func testRoleRevisionAndRequestDeduplication() async throws {
        let s=try GameSession(engine:nil),tools=try CompanionTools(session:s);s.setConnection(enabled:true,role:"coach",lease:"fixture")
        let a:[String:Any]=["sessionId":s.sessionId,"revision":s.revision,"positionId":s.positionId,"requestId":"once","highlights":[["sq":"e2","kind":"focus"]]]
        _ = try await tools.call("show_annotation",args:a,lease:"fixture");let n=s.overlayRevision
        _ = try await tools.call("show_annotation",args:a,lease:"fixture");XCTAssertEqual(s.overlayRevision,n)
        var illegal=a;illegal["from"]="e2";do{_ = try await tools.call("show_annotation",args:illegal,lease:"fixture");XCTFail("Unknown fields accepted")}catch{}
        do{_ = try await tools.call("play_move",args:["sessionId":s.sessionId,"revision":s.revision,"requestId":"forbidden"],lease:"fixture");XCTFail("Coach moved White")}catch{}
        s.undo();do{_ = try await tools.call("get_legal_moves",args:["sessionId":s.sessionId,"revision":0],lease:"fixture");XCTFail("Stale revision accepted")}catch{}
    }
    @MainActor func testProjectionCannotLeakFutureAnswers() throws {
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);p.openLesson(index:0);p.seek(step:19)
        let data=try JSONSerialization.data(withJSONObject:s.publicState());let text=String(decoding:data,as:UTF8.self)
        XCTAssertFalse(text.contains("\"answer\""));XCTAssertFalse(text.contains("\"beats\""));XCTAssertFalse(text.contains("\"choices\""))
    }
    func testSchemaDefaultsAndStrictBounds() throws {
        let schemas=try ToolSchemas();let a=try schemas.parse("analyze_position",args:["sessionId":"s","revision":0]);XCTAssertEqual(a["movetimeMs"] as? Int,350)
        XCTAssertThrowsError(try schemas.parse("analyze_position",args:["sessionId":"s","revision":0,"movetimeMs":2000]))
    }
}
extension CompanionTests {
    @MainActor func testChangeWaitWakesOnEventAndCancellation() async throws {let s=try GameSession(engine:nil),tools=try CompanionTools(session:s);s.setConnection(enabled:true,role:"coach",lease:"fixture");let cursor=s.cursor;let waiter=Task{try await tools.call("wait_for_change",args:["sessionId":s.sessionId,"cursor":cursor,"timeoutMs":1000],lease:"fixture")};try await Task.sleep(nanoseconds:10_000_000);s.emit();let result=try await waiter.value as! [String:Any];XCTAssertEqual(result["changed"] as? Bool,true);let cancelled=Task{try await tools.call("wait_for_change",args:["sessionId":s.sessionId,"cursor":s.cursor,"timeoutMs":1000],lease:"fixture")};try await Task.sleep(nanoseconds:10_000_000);cancelled.cancel();do{_ = try await cancelled.value;XCTFail("Cancelled waiter returned")}catch{}}
}
extension CompanionTests {
    @MainActor func testLearningProjectionNullsAndPawnRulesMatchReference()throws {let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);p.openLesson(index:0);let title=s.publicState()["state"] as! [String:Any];XCTAssertTrue(title["pieces"] is NSNull);XCTAssertNil(title["winner"]);p.startPawnDuel();let mini=s.publicState()["state"] as! [String:Any];XCTAssertTrue(mini["winner"] is NSNull);XCTAssertEqual(mini["rules"] as? [String],["Reach the far rank with a pawn, capture every opposing pawn, or leave the opponent without a move.","Pawns move forward and capture diagonally. A pawn on its starting rank may advance two empty squares.","No en passant. Pawns stay pawns at the far rank."])}
    @MainActor func testPuzzleFiltersSurviveStateRestart()throws {let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);p.query="rook";p.filter="To review";let restored=try JSONDecoder().decode(ApplicationState.self,from:JSONEncoder().encode(s.state));let second=try LearningPlayer(session:GameSession(engine:nil,state:restored));XCTAssertEqual(second.query,"rook");XCTAssertEqual(second.filter,"To review")}
}
