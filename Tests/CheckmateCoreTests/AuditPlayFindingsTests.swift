import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// Audit regressions for headerless import recovery, the companion's published side, and saved-archive limits.
@MainActor final class AuditPlayFindingsTests:XCTestCase {
    private func report(_ text:String)throws -> (documents:[GameDocument],skipped:[ReviewImportError]) {try PGNImporter.parseReport(Data(text.utf8))}
    private func moves(_ documents:[GameDocument])->[[String]] {documents.map{document in document.mainline.compactMap{document.nodes[$0].san}}}
    // #4: skipping an unreadable game stops at its result, so a following headerless game still imports.
    func testRecoveryResumesAfterAResultMarker()throws {
        let plain=try report("1. e4 BAD * 1. d4 d5 *");XCTAssertEqual(moves(plain.documents),[["d4","d5"]]);XCTAssertEqual(plain.skipped.count,1)
        let inVariation=try report("1. e4 (1. d4 BAD) 1... e5 * 1. c4 *");XCTAssertEqual(moves(inVariation.documents),[["c4"]]);XCTAssertEqual(inVariation.skipped.count,1)
        let nested=try report("1. e4 BAD (1. d4 *) 2. Nf3 * 1. c4 *");XCTAssertEqual(moves(nested.documents),[["c4"]],"A result inside a skipped variation does not end the game");XCTAssertEqual(nested.skipped.count,1)
        let markerInVariation=try report("1. e4 (1. d4 *) 1... e5 * 1. c4 *");XCTAssertEqual(moves(markerInVariation.documents),[["c4"]]);XCTAssertEqual(markerInVariation.skipped.count,1)
        let lexical=try report("1. e4 BAD * [Bad 1. d4 *\n\n[Event \"c\"]\n1. c4 *");XCTAssertEqual(moves(lexical.documents),[["c4"]]);XCTAssertEqual(lexical.skipped.map(\.record),[1,2])
    }
    // #5: the companion opponent owns the side the learner does not play.
    func testCompanionOpponentPublishesTheOpponentsSide()throws {
        let black=try GameSession(engine:nil),fork=try ChessRules();try fork.move(uci:"e2e4");try black.installPracticeFork(fork,side:"b")
        black.setConnection(enabled:true,role:"opponent",lease:"fixture")
        XCTAssertEqual((black.publicState()["controller"] as? [String:Any])?["side"] as? String,"w")
        let white=try GameSession(engine:nil);white.setConnection(enabled:true,role:"opponent",lease:"fixture")
        XCTAssertEqual((white.publicState()["controller"] as? [String:Any])?["side"] as? String,"b")
    }
    // #16: the previous game meets the same start-position rule as the current one.
    func testPreviousGameFromAnIllegalPositionIsRejected()throws {
        var state=ApplicationState();state.practice.previousGame="[SetUp \"1\"]\n[FEN \"4k3/8/8/8/8/8/8/4K3 w KQ - 0 1\"]\n\n*"
        XCTAssertThrowsError(try StateStore.validate(state),"Castling rights without rooks are not a legal start")
        state.practice.previousGame="[SetUp \"1\"]\n[FEN \"4k3/8/8/8/8/8/8/R3K3 w Q - 0 1\"]\n\n*";XCTAssertNoThrow(try StateStore.validate(state))
    }
    // #17: an export the importer would refuse is never reported as written.
    func testOversizedExportFails()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=StateStore(directory:root),destination=root.appendingPathComponent("export.json");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var state=ApplicationState();state.importedArchives=(0..<70_000).map{String(format:"%064d",$0)}
        XCTAssertThrowsError(try store.exportState(state,to:destination));XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        state.importedArchives=[];try store.exportState(state,to:destination);var imported=ApplicationState();XCTAssertNoThrow(try LegacyImporter.apply(Data(contentsOf:destination),to:&imported,course:CourseLibrary()))
    }
    // #18: a previous-game entry that cannot be read does not stop the replaced game from being kept.
    func testUnreadablePreviousGameStillPreservesTheReplacedGame()throws {
        var state=ApplicationState();let rules=try ChessRules();try rules.move(uci:"e2e4");state.practice.pgn=rules.pgn;state.practice.fen=rules.fen
        let archive=try JSONSerialization.data(withJSONObject:["checkmate-practice-pgn":"1. d4 *","checkmate-previous-game":123])
        let report=try LegacyImporter.apply(archive,to:&state,course:CourseLibrary())
        XCTAssertTrue(report.ignored.contains("Previous game"));XCTAssertEqual(state.practice.previousGame,rules.pgn)
    }
}
