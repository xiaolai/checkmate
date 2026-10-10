import XCTest
@testable import CheckmateCore
final class CourseTests:XCTestCase {
    func testAllTimelineEndpointsMatchReference() throws {
        let course=try CourseLibrary()
        for (li,l) in course.lessons.enumerated() {for step in l.beats.indices {
            let expected=course.referenceFrames[li][step]
            XCTAssertEqual(try course.frame(lesson:li,step:step,seconds:0),expected.start,"\(l.id):\(step) start")
            XCTAssertEqual(try course.frame(lesson:li,step:step,seconds:course.voices[li][step].duration),expected.end,"\(l.id):\(step) end")
        }}
    }
    func testEveryExerciseAcceptsAuthoredAnswerAndRejectsWrongAnswer() throws {
        let c=try CourseLibrary()
        for (id,e) in c.exercises where e.kind != "path" {
            XCTAssertTrue(e.matches(e.referenceAnswer),id)
            XCTAssertFalse(e.matches(["invalid"]),id)
        }
    }

    func testKnightJumpsOverUnmovedFriendlyPawnsInLesson() throws {
        let course=try CourseLibrary()
        let li=try XCTUnwrap(course.lessons.firstIndex{$0.id=="knight"})
        let si=try XCTUnwrap(course.lessons[li].beats.firstIndex{$0.id=="knight:16"})
        let start=try XCTUnwrap(course.frame(lesson:li,step:si,seconds:0).board)
        let end=try XCTUnwrap(course.frame(lesson:li,step:si,seconds:course.voices[li][si].duration).board)
        let rules=try ChessRules()
        XCTAssertEqual(start,rules.board)
        XCTAssertEqual(Set(rules.moves("g1").map(\.to)),Set(["f3","h3"]))
        XCTAssertThrowsError(try rules.move("g1","e2"))
        try rules.move("g1","f3")
        XCTAssertEqual(end,rules.board)
        for file in "abcdefgh" {
            XCTAssertEqual(end[String(file)+"2"],"wp")
            XCTAssertEqual(end[String(file)+"7"],"bp")
        }
    }
}
