import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class ProjectionParityTests:XCTestCase {
    @MainActor func testEveryAuthoredPublicLessonAndQuizProjection()throws {
        let expected=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("projections.json"))) as! [[[String:Any]]]
        let s=try GameSession(engine:nil),p=try LearningPlayer(session:s);var count=0
        for (li,lesson) in expected.enumerated(){p.openLesson(index:li);for (step,want) in lesson.enumerated(){p.seek(step:step);var got=s.publicState()["state"] as! [String:Any]
            // An exercise step adds the live attempt (a fresh id each time) and White's turn to the authored projection.
            if p.attemptStep{
                // Every attempt field but its fresh id is fixed by the authored practice: a fresh attempt at its start.
                let attempt=got.removeValue(forKey:"attempt") as? [String:Any],practice=try XCTUnwrap(p.current.practice),place="\(li):\(step)"
                XCTAssertFalse((attempt?["attemptId"] as? String ?? "").isEmpty,place);XCTAssertEqual(attempt?["phase"] as? String,"yourTurn",place)
                XCTAssertEqual((attempt?["fen"] as? String)?.split(separator:" ").prefix(4),practice.fen.split(separator:" ").prefix(4),place);XCTAssertEqual(attempt?["turn"] as? String,"w",place)
                XCTAssertEqual(attempt?["goal"] as? String,practice.goal,place);XCTAssertEqual(attempt?["thinking"] as? Bool,false,place);XCTAssertEqual(attempt?["waitingToResume"] as? Bool,false,place)
                XCTAssertNil(attempt?["feedback"] as? String,place)
                let checkpoints=attempt?["checkpoints"] as? [[String:Any]]
                XCTAssertEqual(checkpoints?.compactMap{$0["label"] as? String},practice.checkpoints?.map(\.label),place);XCTAssertEqual(checkpoints?.compactMap{$0["done"] as? Bool},practice.checkpoints?.map{_ in false},place)
                XCTAssertEqual(Set(attempt?.keys.map{$0} ?? []),Set(["attemptId","fen","turn","phase","goal","checkpoints","thinking","waitingToResume"]).union(attempt?["feedback"]==nil ? []:["feedback"]),place);XCTAssertEqual(got.removeValue(forKey:"turn") as? String,"w");got["turn"]=want["turn"]}else{XCTAssertNil(got["attempt"])};XCTAssertTrue(NSDictionary(dictionary:got).isEqual(to:want),"Projection mismatch \(li):\(step) actual=\(got) expected=\(want)");count+=1}}
        XCTAssertEqual(count,710)
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
