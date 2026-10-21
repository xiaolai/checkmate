import XCTest
import CheckmateDomain
/// A lesson's status is derived from saved progress alone: explored, practised and mastered each claim only what the
/// saved records show, and progress saved before these records existed still loads.
final class LessonStatusTests:XCTestCase {
    private func solved(firstTime:Bool)->PuzzleProgress {var p=PuzzleProgress();if !firstTime{p.record(correct:false)};p.record(correct:true,afterMistake:!firstTime);return p}
    func testEachStatusClaimsOnlyWhatTheSavedProgressShows()throws {
        let library=try CourseLibrary(),castling=try XCTUnwrap(library.lessons.first{$0.id=="castling"})
        let linked=library.puzzles.filter{$0.topic==castling.title}.map(\.id);XCTAssertEqual(linked.count,2,"fixture: Castling has two linked puzzles")
        func status(_ course:CourseProgress,_ puzzles:[String:PuzzleProgress]=[:])->LessonStatus {LessonStatus.of(castling,in:library,course:course,puzzles:puzzles)}
        var course=CourseProgress();XCTAssertEqual(status(course),.notStarted)
        course.completed=["castling"];XCTAssertEqual(status(course),.explored,"reaching the end, exercise skipped, is explored only")
        course.practised=["castling"];XCTAssertEqual(status(course),.practised)
        course.unaided=["castling"];XCTAssertEqual(status(course),.practised,"its linked puzzles are not solved yet")
        var puzzles=Dictionary(uniqueKeysWithValues:linked.map{($0,solved(firstTime:true))})
        XCTAssertEqual(status(course,puzzles),.mastered)
        puzzles[linked[0]]=solved(firstTime:false);XCTAssertEqual(status(course,puzzles),.practised,"a puzzle solved on a later try is not mastery")
        course.unaided=[];puzzles[linked[0]]=solved(firstTime:true);XCTAssertEqual(status(course,puzzles),.practised,"an exercise done with hints is not mastery")
        course=CourseProgress();course.practised=["castling"];course.unaided=["castling"];XCTAssertEqual(status(course,puzzles),.mastered,"practised without reaching the end still counts")
        // A lesson without an exercise is explored at most, whatever its puzzles say.
        let intro=try XCTUnwrap(library.lessons.first{$0.id=="intro"});XCTAssertNil(intro.practice)
        var done=CourseProgress();done.completed=["intro"];done.practised=["intro"];done.unaided=["intro"]
        let introPuzzles=Dictionary(uniqueKeysWithValues:library.puzzles.filter{$0.topic==intro.title}.map{($0.id,solved(firstTime:true))})
        XCTAssertEqual(LessonStatus.of(intro,in:library,course:done,puzzles:introPuzzles),.explored)
        XCTAssertEqual(LessonStatus.notStarted.title,nil);XCTAssertEqual(LessonStatus.explored.title,"Explored");XCTAssertEqual(LessonStatus.practised.title,"Practised");XCTAssertEqual(LessonStatus.mastered.title,"Mastered")
    }
    func testAPuzzleRecordsItsFirstAnswerAndALaterSolveApart(){
        var first=PuzzleProgress();first.record(correct:true);XCTAssertTrue(first.solved);XCTAssertTrue(first.solvedFirstTime);XCTAssertNil(first.solvedLater)
        first.record(correct:false);XCTAssertTrue(first.solvedFirstTime,"a later wrong answer does not undo the first")
        var later=PuzzleProgress();later.record(correct:false);later.record(correct:true,afterMistake:true)
        XCTAssertFalse(later.solved);XCTAssertEqual(later.solvedLater,true);XCTAssertFalse(later.solvedFirstTime);XCTAssertTrue(later.review,"still worth reviewing");XCTAssertEqual(later.attempts,2)
        var revealed=PuzzleProgress();revealed.record(correct:false,revealed:true);XCTAssertFalse(revealed.solvedFirstTime);XCTAssertNil(revealed.solvedLater)
    }
    /// Records saved before first-try and later-solve tracking load unchanged; a single correct answer is a first-time solve.
    func testOlderProgressLoadsAndIsReadConservatively()throws {
        let old=#"{"schemaVersion":1,"savedAt":0,"practice":{},"course":{"lessonID":"castling","step":0,"completed":["castling"],"answered":[],"edition":2,"practised":["castling"]},"settings":{},"puzzles":{"one":{"solved":true,"review":false,"attempts":1},"two":{"solved":true,"review":false,"attempts":3}},"window":{"left":false,"right":false,"settingsCategory":"board"},"importedArchives":[]}"#
        let state=try JSONDecoder().decode(ApplicationState.self,from:Data(old.utf8))
        XCTAssertNil(state.course.unaided);XCTAssertEqual(state.course.practised,["castling"])
        XCTAssertTrue(state.puzzles["one"]!.solvedFirstTime,"one correct answer was the first");XCTAssertFalse(state.puzzles["two"]!.solvedFirstTime,"unknown, so not claimed")
        XCTAssertTrue(state.unknownFields.isEmpty)
        var next=state;next.course.unaided=["castling"];next.puzzles["two"]?.record(correct:true)
        let written=try JSONSerialization.jsonObject(with:JSONEncoder().encode(next)) as! [String:Any]
        XCTAssertEqual((written["course"] as? [String:Any])?["unaided"] as? [String],["castling"])
        XCTAssertNil((written["puzzles"] as? [String:[String:Any]])?["two"]?["firstTry"],"only a record's first answer sets it")
        let again=try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:written))
        XCTAssertEqual(again.course.unaided,["castling"]);XCTAssertTrue(again.unknownFields.isEmpty,"the new fields are this build's own")
    }
}
