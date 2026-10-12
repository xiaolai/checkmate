import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class ResourceTests:XCTestCase {
    func testCompleteCourseAndPuzzleResourceClosure() throws {
        let course=try CourseLibrary()
        XCTAssertEqual(course.lessons.count,39)
        XCTAssertEqual(course.lessons.reduce(0){$0+$1.beats.count},710)
        XCTAssertEqual(course.exercises.count,0)
        XCTAssertEqual(course.puzzles.count,82)
        for voices in course.voices {for voice in voices {XCTAssertTrue(FileManager.default.fileExists(atPath:NativeResources.url(voice.file).path),voice.file)}}
    }
}
