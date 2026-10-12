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
    func testFutureFieldsInsideKnownRecordsAndLargeIntegersSurviveASave()throws {
        var raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(ApplicationState())) as! [String:Any]
        var settings=raw["settings"] as! [String:Any];settings["futureSetting"]="kept";raw["settings"]=settings
        raw["futureCounter"]=Int64(9_007_199_254_740_993)
        let state=try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:raw))
        let written=try JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as! [String:Any]
        let text=String(decoding:try JSONSerialization.data(withJSONObject:ApplicationState.merged(written,state.unknownFields,nested:state.unknownNestedFields)),as:UTF8.self)
        XCTAssertTrue(text.contains("\"futureSetting\":\"kept\""),"a newer field inside a known record is written back")
        XCTAssertTrue(text.contains("9007199254740993"),"a whole number beyond Double precision is written back unchanged")
    }
    func testCourseLoadsWithoutNativeServices()throws {let course=try CourseLibrary();XCTAssertFalse(course.lessons.isEmpty);XCTAssertFalse(course.puzzles.isEmpty)}
}
