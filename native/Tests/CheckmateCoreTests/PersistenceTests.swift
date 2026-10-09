import XCTest
@testable import CheckmateCore
final class PersistenceTests:XCTestCase {
    func testAtomicRoundtripAndFutureSchemaPreserved() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let store=StateStore(directory:dir);var state=ApplicationState();state.settings.voiceLanguage="zh";state.practice.pgn="1. e4 e5";state.course.lessonID="pawn"
        try store.save(state);let restored=try store.load();XCTAssertEqual(restored.settings.voiceLanguage,"zh");XCTAssertEqual(restored.practice.pgn,state.practice.pgn)
        let future=Data("{\"schemaVersion\":99}".utf8);try future.write(to:store.url)
        XCTAssertThrowsError(try store.load());XCTAssertEqual(try Data(contentsOf:store.url),future)
    }
    func testLegacyImportIsIdempotentAndValidatesPGN() throws {
        let c=try CourseLibrary();var state=ApplicationState()
        let archive: [String:Any] = ["checkmate-practice-pgn":"1. e4 e5", "checkmate-settings-v1":["boardTheme":"blue","voiceLanguage":"ja"],"checkmate-course-v1":["lesson":2,"step":3,"completed":["intro"]]]
        let data=try JSONSerialization.data(withJSONObject:archive)
        try LegacyImporter.apply(data,to:&state,course:c)
        XCTAssertEqual(state.settings.boardTheme,"blue");XCTAssertEqual(state.course.lessonID,"pawn")
        state.course.step=4;try LegacyImporter.apply(data,to:&state,course:c);XCTAssertEqual(state.course.step,4)
        XCTAssertThrowsError(try LegacyImporter.apply(Data("{\"checkmate-practice-pgn\":\"not a game\"}".utf8),to:&state,course:c))
    }
    func testCedarDefaultPreservesSavedVoiceChoices() throws {
        XCTAssertEqual(AppSettings().coachVoice,"cedar")
        XCTAssertEqual(AppSettings(raw:[:]).coachVoice,"cedar")
        XCTAssertEqual(AppSettings(raw:["coachVoice":"invalid"]).coachVoice,"cedar")
        XCTAssertEqual(AppSettings(raw:["coachVoice":"marin"]).coachVoice,"marin")
        let restored=try JSONDecoder().decode(AppSettings.self,from:Data("{\"coachVoice\":\"coral\"}".utf8))
        XCTAssertEqual(restored.coachVoice,"coral")
    }
    func testSettingsNormalizeWithoutChangingDefaults() {
        let s=AppSettings(raw:["voiceLanguage":"unknown","volume":99,"pieceDuration":-1,"voiceAssistMoves":true])
        XCTAssertEqual(s.voiceLanguage,"en");XCTAssertEqual(s.volume,1);XCTAssertEqual(s.pieceDuration,700);XCTAssertTrue(s.voiceAssistMoves)
    }
}
extension PersistenceTests {
    func testNativeExportImportPreservesFullState()throws {let course=try CourseLibrary();var original=ApplicationState();let rules=try ChessRules();_ = try rules.move("e2","e4");original.practice.pgn=rules.pgn;original.practice.fen=rules.fen;original.settings.voiceLanguage="fr";original.course.answered=["intro:17"];let data=try JSONEncoder().encode(original);var result=ApplicationState();try LegacyImporter.apply(data,to:&result,course:course);XCTAssertEqual(result.practice.pgn,original.practice.pgn);XCTAssertEqual(result.settings.voiceLanguage,"fr");XCTAssertEqual(result.course.answered,original.course.answered);result.course.step=5;try LegacyImporter.apply(data,to:&result,course:course);XCTAssertEqual(result.course.step,5)}
    func testUnknownArchiveCannotSilentlySucceed()throws{var state=ApplicationState();XCTAssertThrowsError(try LegacyImporter.apply(Data("{\"other\":1}".utf8),to:&state,course:CourseLibrary()))}
}
extension PersistenceTests {
    @MainActor func testSpikeFenImportRetainsPositionWithSetupHeader()throws {var state=ApplicationState();let fen="4k3/8/8/4p3/3P4/8/8/4K3 w - - 0 1";try LegacyImporter.apply(JSONSerialization.data(withJSONObject:["spikeFEN":fen]),to:&state,course:CourseLibrary());let restored=try GameSession(engine:nil,state:state);XCTAssertEqual(restored.rules.fen,fen);XCTAssertTrue(restored.rules.history.isEmpty);try StateStore.validate(state)}
}
extension PersistenceTests {
    func testBackupRecoveryPreservesUnreadableOriginal()throws {let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let store=StateStore(directory:dir);try store.save(ApplicationState());var next=ApplicationState();next.settings.voiceLanguage="zh";try store.save(next);let corrupt=Data("corrupt bytes".utf8);try corrupt.write(to:store.url);let backup=try Data(contentsOf:store.backupURL);try store.restoreBackup();XCTAssertEqual(try store.load().settings.voiceLanguage,"en");XCTAssertEqual(try Data(contentsOf:store.backupURL),backup);let preserved=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("state-preserved-")};XCTAssertEqual(try Data(contentsOf:XCTUnwrap(preserved)),corrupt)}
}
extension PersistenceTests {func testNumericSettingsSurviveCodableRoundTrip()throws {var s=AppSettings();s.skill=5;s.pieceDuration=300;let restored=try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(s));XCTAssertEqual(restored.skill,5);XCTAssertEqual(restored.pieceDuration,300)}}
extension PersistenceTests {
    func testPreImportArchiveSurvivesLaterSaves()throws {let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let store=StateStore(directory:dir);var original=ApplicationState();original.settings.skill=8;try store.save(original);let archive=try store.preserveBeforeImport(original);var replacement=ApplicationState();replacement.settings.skill=3;try store.save(replacement);replacement.settings.skill=0;try store.save(replacement);let recovered=try JSONDecoder().decode(ApplicationState.self,from:Data(contentsOf:archive));XCTAssertEqual(recovered.settings.skill,8)}
}
