import XCTest
@testable import CheckmateCore
final class ProjectionParityTests:XCTestCase {
    @MainActor func testEveryAuthoredPublicLessonAndQuizProjection()throws {
        let expected=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("projections.json"))) as! [[[String:Any]]]
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);var count=0
        for (li,lesson) in expected.enumerated(){p.openLesson(index:li);for (step,want) in lesson.enumerated(){p.seek(step:step);let got=s.publicState()["state"] as! [String:Any];XCTAssertTrue(NSDictionary(dictionary:got).isEqual(to:want),"Projection mismatch \(li):\(step) actual=\(got) expected=\(want)");count+=1}}
        XCTAssertEqual(count,947)
    }
    @MainActor func testPublicNullableFieldsAndLessonEventIdentity()throws {let s=try GameSession(engine:nil);let publicValue=s.publicState();let coaching=publicValue["coaching"] as! [String:Any];XCTAssertTrue(coaching["analysis"] is NSNull);XCTAssertTrue(coaching["recommendation"] is NSNull)
        let p=try LearningPlayer(session:s);p.openLesson(index:0);let original=s.positionId,cursor=s.cursor,revision=s.revision;var v=s.lesson!;s.setLesson(v);XCTAssertEqual(s.cursor,cursor);XCTAssertEqual(s.revision,revision);v.playing=true;s.setLesson(v);XCTAssertEqual(s.positionId,original);XCTAssertGreaterThan(s.revision,revision);v.moving=true;s.setLesson(v);XCTAssertNotEqual(s.positionId,original)
        for puzzle in p.library.puzzles{p.openPuzzle(id:puzzle.id);let value=s.publicState()["state"] as! [String:Any];XCTAssertEqual(value["step"] as? Int,0);XCTAssertEqual(value["lessonId"] as? String,puzzle.id);XCTAssertNil(value["answers"]);XCTAssertNil(value["solution"])}
        p.startPawnDuel();let mini=s.publicState()["state"] as! [String:Any];XCTAssertEqual(mini["mode"] as? String,"pawn_duel");XCTAssertTrue(mini["winner"] is NSNull)
    }
}

extension ProjectionParityTests {
 @MainActor func testNestedPublicNulls()throws {let s=try GameSession(engine:nil);try s.demonstrate(title:"Line",introduction:"Imagine",lines:[DemoLineInput(label:"Main",moves:[DemoStepInput(uci:"e2e4")])]);let demo=s.publicState()["demonstration"] as! [String:Any];let frames=(demo["lines"] as! [[String:Any]])[0]["frames"] as! [[String:Any]];for key in ["san","uci","captured"]{XCTAssertTrue(frames[0][key] is NSNull)};XCTAssertTrue(frames[1]["captured"] is NSNull);let analysis=jsonObject(EngineAnalysis()) as! [String:Any];XCTAssertTrue(analysis["bestMove"] is NSNull)}
}
