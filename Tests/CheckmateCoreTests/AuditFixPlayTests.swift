import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// Final-round audit regressions for import recovery, presentation selection, archive reports and state encoding.
@MainActor final class AuditFixPlayTests:XCTestCase {
    private func report(_ text:String)throws -> (documents:[GameDocument],skipped:[ReviewImportError]) {try PGNImporter.parseReport(Data(text.utf8))}
    private func moves(_ documents:[GameDocument])->[[String]] {documents.map{document in document.mainline.compactMap{document.nodes[$0].san}}}
    // #4: a game rejected after reading its own result does not take the following headerless game with it.
    func testConflictingResultHeaderKeepsTheNextHeaderlessGame()throws {
        let conflict=try report("[Result \"1-0\"]\n\n1. e4 0-1 1. d4 d5 *");XCTAssertEqual(moves(conflict.documents),[["d4","d5"]]);XCTAssertEqual(conflict.skipped.count,1)
        let headed=try report("[Result \"1-0\"]\n\n1. e4 0-1\n\n[Event \"b\"]\n1. c4 *");XCTAssertEqual(moves(headed.documents),[["c4"]]);XCTAssertEqual(headed.skipped.count,1)
        let last=try report("1. d4 *\n\n[Result \"1-0\"]\n\n1. e4 0-1");XCTAssertEqual(moves(last.documents),[["d4"]]);XCTAssertEqual(last.skipped.count,1)
    }
    // #5: closing a hidden presentation keeps the selection the learner has back on the live board.
    func testClosingAHiddenPresentationKeepsTheLiveSelection()throws {
        let preview=try GameSession(engine:nil);try preview.select("e2");try preview.beginPreview();XCTAssertNil(preview.selected)
        preview.selectPresentation(false);XCTAssertEqual(preview.selected,"e2")
        preview.closePresentation();XCTAssertEqual(preview.selected,"e2");XCTAssertEqual(preview.inspection?.legalNow,true)
        try preview.select("e4");XCTAssertEqual(preview.rules.history.count,1)
        let demo=try GameSession(engine:nil);try demo.select("g1")
        try demo.demonstrate(title:"Imagine",introduction:"",lines:[DemoLineInput(label:"Pawn",moves:[DemoStepInput(uci:"d2d4")])])
        demo.selectPresentation(false);demo.closePresentation();XCTAssertEqual(demo.selected,"g1")
    }
    // #14: mini-games this version does not know are reported as skipped, never as recovered.
    func testUnknownMiniGamesAreReportedAsSkipped()throws {
        var source=ApplicationState();source.miniGames=["pawn-duel":MiniGameState(kind:.pawnDuel,computer:true)]
        var root=try JSONSerialization.jsonObject(with:JSONEncoder().encode(source)) as! [String:Any],games=root["miniGames"] as! [String:Any]
        root["miniGames"]=["future-game":games["pawn-duel"]!]
        var state=ApplicationState();let unknown=try LegacyImporter.apply(JSONSerialization.data(withJSONObject:root),to:&state,course:CourseLibrary())
        XCTAssertFalse(unknown.recovered.contains("miniGames"),"No mini-game survived the import");XCTAssertTrue(unknown.ignored.contains("Mini-game: future-game"))
        games["future-game"]=games["pawn-duel"]!;root["miniGames"]=games
        var mixedState=ApplicationState();let mixed=try LegacyImporter.apply(JSONSerialization.data(withJSONObject:root),to:&mixedState,course:CourseLibrary())
        XCTAssertTrue(mixed.recovered.contains("miniGames"));XCTAssertTrue(mixed.ignored.contains("Mini-game: future-game"));XCTAssertNotNil(mixedState.miniGames?["pawn-duel"])
    }
    // #15: save and export share one encoding, so both enforce validation and keep their own size messages.
    func testSaveAndExportShareValidatedEncoding()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("checkmate-audit-fix-\(UUID().uuidString)");defer{try? FileManager.default.removeItem(at:directory)}
        let store=StateStore(directory:directory),destination=directory.appendingPathComponent("export.json")
        var state=ApplicationState();state.savedAt = .distantPast;try store.save(state);try store.exportState(state,to:destination)
        let saved=try JSONDecoder().decode(ApplicationState.self,from:Data(contentsOf:store.url)),exported=try JSONDecoder().decode(ApplicationState.self,from:Data(contentsOf:destination))
        XCTAssertGreaterThan(saved.savedAt,.distantPast,"Saving stamps the time");XCTAssertGreaterThan(exported.savedAt,.distantPast,"Exporting stamps the time")
        state.practice.startPly=5;XCTAssertThrowsError(try store.save(state));XCTAssertThrowsError(try store.exportState(state,to:destination))
    }
}

/// A game that fails inside a variation is skipped to its own result: a result marker inside the variation is not the
/// game's, so the variation's remaining moves never import as a game of their own.
final class PGNVariationRecoveryTests:XCTestCase {
    func testAFailureInsideAVariationSkipsTheWholeGame()throws {
        let report=try PGNImporter.parseReport(Data("1. e4 (1. d4 BAD * 1. c4 *) 1... e5 *\n1. Nf3 *".utf8))
        XCTAssertEqual(report.documents.map{d in d.mainline.compactMap{d.nodes[$0].san}},[["Nf3"]],"Only the game after the failed one imports; c4 is not a game")
        XCTAssertEqual(report.skipped.count,1)
        let nested=try PGNImporter.parseReport(Data("1. e4 (1. d4 (1. c4 BAD *) 1... d5 *) 1... e5 *\n1. g3 *".utf8))
        XCTAssertEqual(nested.documents.map{d in d.mainline.compactMap{d.nodes[$0].san}},[["g3"]]);XCTAssertEqual(nested.skipped.count,1)
    }
}
