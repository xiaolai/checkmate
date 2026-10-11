import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class LegacyMigrationTests:XCTestCase {
    func testPartialArchiveReportsRecoveredAndDroppedFields() throws {
        let course=try CourseLibrary();var state=ApplicationState()
        let raw:[String:Any]=["checkmate-settings-v1":["volume":0.4,"boardTheme":"obsolete","unexpected":"ignored"],"checkmate-puzzles-v1":["rook":["solved":true,"review":false,"attempts":2],"knight":"broken","unknown":["solved":true]],"checkmate-course-v1":["lesson":1,"step":99,"completed":["intro", "missing", 12],"answered":["intro:17","missing:0"]],"unrelated":"not imported"]
        let report=try LegacyImporter.apply(JSONSerialization.data(withJSONObject:raw),to:&state,course:course)
        XCTAssertFalse(report.duplicate);XCTAssertEqual(state.settings.volume,0.4);XCTAssertEqual(state.settings.boardTheme,"wood");XCTAssertEqual(state.puzzles["rook"]?.attempts,2);XCTAssertTrue(report.recovered.contains("Puzzle progress: rook"));XCTAssertTrue(report.ignored.contains("Puzzle progress: knight"));XCTAssertTrue(report.ignored.contains("Puzzle progress: unknown"));XCTAssertTrue(report.adjusted.contains("Setting: boardTheme"));XCTAssertTrue(report.ignored.contains("Setting: unexpected"));XCTAssertEqual(state.course.completed,["intro"]);XCTAssertTrue(report.adjusted.contains("Lesson transcript"))
    }
    func testDuplicateImportReportsNoChanges()throws {var state=ApplicationState();let course=try CourseLibrary(),data=Data(#"{"checkmate-settings-v1":{"voiceLanguage":"fr"}}"#.utf8);_ = try LegacyImporter.apply(data,to:&state,course:course);state.settings.voiceLanguage="en";let report=try LegacyImporter.apply(data,to:&state,course:course);XCTAssertTrue(report.duplicate);XCTAssertTrue(report.recovered.isEmpty);XCTAssertEqual(state.settings.voiceLanguage,"en")}
    func testExportedLegacyStoreReimportsWithoutCredentials()throws {let data:Data;if let path=ProcessInfo.processInfo.environment["CHECKMATE_LEGACY_EXPORT"] {data=try Data(contentsOf:URL(fileURLWithPath:path))}else{data=Data(#"{"values":{"checkmate-practice-pgn":"1. e4 e5","checkmate-settings-v1":"{\"voiceLanguage\":\"ja\"}"}}"#.utf8)};var state=ApplicationState();let report=try LegacyImporter.apply(data,to:&state,course:CourseLibrary());try StateStore.validate(state);XCTAssertFalse(report.recovered.isEmpty);XCTAssertFalse(String(decoding:try JSONEncoder().encode(state),as:UTF8.self).contains("access_token"))}
    /// An old archive changes only the settings it carries: opt-outs and strength stay as the learner set them.
    func testArchiveSettingsNeverResetSettingsItLacks()throws {
        var state=ApplicationState();state.settings.voiceAutoConnect=false;state.settings.companionAutoStart=false;state.settings.voiceMicrophone=false;state.settings.skill=7
        _ = try LegacyImporter.apply(JSONSerialization.data(withJSONObject:["checkmate-settings-v1":["volume":0.4]]),to:&state,course:CourseLibrary())
        XCTAssertEqual(state.settings.volume,0.4);XCTAssertFalse(state.settings.voiceAutoConnect);XCTAssertFalse(state.settings.companionAutoStart);XCTAssertFalse(state.settings.voiceMicrophone);XCTAssertEqual(state.settings.skill,7)
    }
    /// A legacy practice game was played as White, and the game it replaces stays under Restore Previous Game.
    func testLegacyPracticeGameIsWhiteAndKeepsTheReplacedGame()throws {
        var state=ApplicationState();let current=try ChessRules();try current.move(uci:"d2d4");try current.move(uci:"d7d5");try current.move(uci:"c2c4")
        state.practice.pgn=current.pgn;state.practice.fen=current.fen;state.settings.practiceSide="b"
        _ = try LegacyImporter.apply(JSONSerialization.data(withJSONObject:["checkmate-practice-pgn":"1. e4 e5"]),to:&state,course:CourseLibrary())
        XCTAssertEqual(state.settings.practiceSide,"w");XCTAssertEqual(state.practice.previousGame,current.pgn);XCTAssertEqual(state.practice.previousSide,"b")
        let restored=try ChessRules();try restored.restore(state.practice.pgn);XCTAssertEqual(restored.history,["e4","e5"])
    }
}
