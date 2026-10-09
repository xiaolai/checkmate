import XCTest
@testable import CheckmateCore
final class ResourceTests:XCTestCase {
    func testCompleteCourseAndPuzzleResourceClosure() throws {
        let course=try CourseLibrary()
        XCTAssertEqual(course.lessons.count,40)
        XCTAssertEqual(course.lessons.reduce(0){$0+$1.beats.count},947)
        XCTAssertEqual(course.exercises.count,83)
        XCTAssertEqual(course.puzzles.count,87)
        for voices in course.voices {for voice in voices {XCTAssertTrue(FileManager.default.fileExists(atPath:NativeResources.url(voice.file).path),voice.file)}}
    }
}
