import XCTest
import CheckmateDomain
final class DomainContractTests:XCTestCase {
    func testNotationBoundaries(){XCTAssertEqual(ChessNotation.squares.count,64);XCTAssertTrue(ChessNotation.validUCI("e7e8n"));XCTAssertFalse(ChessNotation.validUCI("e7e8k"));XCTAssertFalse(ChessNotation.validSquare("a9"))}
    func testSavedStateRetainsFutureFields()throws {
        var state=ApplicationState();state.unknownFields=["future":.object(["enabled":.bool(true)])]
        let raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as! [String:Any]
        let merged=ApplicationState.merged(raw,state.unknownFields)
        let decoded=try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:merged))
        XCTAssertEqual(decoded.unknownFields,state.unknownFields)
    }
    func testCourseLoadsWithoutNativeServices()throws {let course=try CourseLibrary();XCTAssertFalse(course.lessons.isEmpty);XCTAssertFalse(course.puzzles.isEmpty)}
}
