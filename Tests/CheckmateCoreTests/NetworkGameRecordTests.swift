import XCTest
@testable import CheckmateApplication
@testable import CheckmateDomain

/// LAN-play plan D9: the review record a network game hands to Review, and the crash file the next launch reads.
final class NetworkGameRecordTests:XCTestCase {
    private func game(pgn:String,outcome:NetworkOutcome?)->NetworkPublicGame {
        NetworkPublicGame(gameID:NetworkGameID.random(using:.system),revision:4,hostSide:.white,whiteName:"Ana",blackName:"Ben \"B\"",timeControl:.tenPlusFive,pgn:pgn,clocks:NetworkClocks(white:1000,black:2000,active:nil),openOffer:nil,outcome:outcome)
    }
    private let day=DateComponents(calendar:Calendar(identifier:.gregorian),timeZone:TimeZone(identifier:"UTC"),year:2026,month:10,day:6).date!
    private var utc:Calendar {var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"UTC")!;return calendar}

    /// The headers come from `ended`, the game's own tags are dropped, and the movetext ends in the real result.
    func testAFinishedGameCarriesTheEndedHeaders(){
        let record=NetworkGameRecord.reviewPGN(game(pgn:"[Event \"?\"]\n[Result \"*\"]\n\n1. e4 e5 2. Qh5 Nc6 *",outcome:NetworkOutcome(result:.blackWins,termination:.resignation)),on:day,calendar:utc)
        XCTAssertEqual(record,"""
        [Event "Checkmate network game"]
        [Site "?"]
        [Date "2026.10.06"]
        [Round "?"]
        [White "Ana"]
        [Black "Ben \\"B\\""]
        [Result "0-1"]
        [TimeControl "600+5"]
        [Termination "Resignation"]

        1. e4 e5 2. Qh5 Nc6 0-1
        """)
    }
    /// An interrupted game has no result and no Termination.
    func testAnInterruptedGameEndsInAStar(){
        let record=NetworkGameRecord.reviewPGN(game(pgn:"1. d4 d5",outcome:nil),on:day,calendar:utc)
        XCTAssertTrue(record.contains("[Result \"*\"]"));XCTAssertFalse(record.contains("Termination"));XCTAssertTrue(record.hasSuffix("1. d4 d5 *"))
    }
    /// The crash file round-trips, names the other player, is private to the user, and an unreadable one is removed.
    func testTheCrashFileHoldsThePublicRecordOnly()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let file=NetworkCrashFile(dataDirectory:directory);XCTAssertNil(file.pending())
        let entry=NetworkCrashFile.Entry(game:game(pgn:"1. e4",outcome:nil),part:.white)
        try file.save(entry);XCTAssertEqual(file.pending(),entry)
        XCTAssertEqual(file.url.lastPathComponent,"current.json");XCTAssertEqual(file.url.deletingLastPathComponent().lastPathComponent,"NetworkGames")
        XCTAssertEqual(entry.notice,"Your network game with Ben \"B\" ended when Checkmate closed.")
        XCTAssertEqual(NetworkCrashFile.Entry(game:entry.game,part:.black).notice,"Your network game with Ana ended when Checkmate closed.")
        let permissions=try FileManager.default.attributesOfItem(atPath:file.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions,0o600)
        let text=try String(contentsOf:file.url,encoding:.utf8)
        for forbidden in ["credential","claimID","epoch"]{XCTAssertFalse(text.contains(forbidden),forbidden)}
        file.clear();XCTAssertNil(file.pending())
        try FileManager.default.createDirectory(at:file.url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("not json".utf8).write(to:file.url);XCTAssertNil(file.pending());XCTAssertFalse(FileManager.default.fileExists(atPath:file.url.path))
    }
}
