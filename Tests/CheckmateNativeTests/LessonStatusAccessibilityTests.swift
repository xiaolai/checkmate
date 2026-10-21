import XCTest
import CheckmateContent
@testable import CheckmateNative
/// The lesson list's column titles are hidden from VoiceOver, so each status cell names its own column; a blank cell
/// still says what it means.
final class LessonStatusAccessibilityTests:XCTestCase {
    func testEachStatusCellNamesItsColumn(){
        let cells=LessonSettingsPane.statusCells(LessonStoredStatus(translated:true,recorded:3,clips:12,stale:false))
        XCTAssertEqual(cells.map(\.column),LessonSettingsPane.statusColumns)
        XCTAssertEqual(cells.map(\.column),["Translated","Recorded","Out of Date"])
        XCTAssertEqual(cells.map(\.shown),["Yes","3 of 12",""])
        XCTAssertEqual(cells.map(\.spoken),["Yes","3 of 12","No"])
        XCTAssertEqual(cells.map(\.help),["","",""])
    }
    func testAStaleLessonIsSaidToBeOutOfDate(){
        let cells=LessonSettingsPane.statusCells(LessonStoredStatus(translated:false,recorded:0,clips:12,stale:true))
        XCTAssertEqual(cells.map(\.shown),["No","None","Yes"])
        XCTAssertEqual(cells.map(\.spoken),["No","None","Yes"])
        XCTAssertEqual(cells.map(\.help),["","",LessonSettingsPane.staleHelp],"only the Out of Date cell explains a stale lesson (D-12: no shown words compared)")
    }
    func testAStatusStillBeingReadIsSaidToBeLoading(){
        let cells=LessonSettingsPane.statusCells(nil)
        XCTAssertEqual(cells.map(\.shown),["…","…",""])
        XCTAssertEqual(cells.map(\.spoken),["Loading","Loading","Loading"])
    }
}
