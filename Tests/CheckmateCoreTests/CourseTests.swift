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
}
