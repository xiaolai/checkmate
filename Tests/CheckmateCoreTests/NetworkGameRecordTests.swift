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
    /// Assistance plan A11: the terms as a header, and each assisted move followed by its comment, which Review's
    /// importer reads as a comment, not a move.
    func testAnAssistedGameNamesItsTermsAndMarksAssistedMoves()throws {
        var assisted=game(pgn:"[Event \"?\"]\n\n1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0",outcome:NetworkOutcome(result:.whiteWins,termination:.checkmate))
        assisted.revision=8;assisted.assistance=NetworkAssistance(white:.hints,black:.off);assisted.assistedPlies=[1,5,7]
        let record=NetworkGameRecord.reviewPGN(assisted,on:day,calendar:utc)
        XCTAssertTrue(record.contains("[TimeControl \"600+5\"]\n[Assistance \"White: Hints on request; Black: Off\"]\n[Termination \"Checkmate\"]"),record)
        XCTAssertTrue(record.hasSuffix("1. e4 {Hint shown} e5 2. Qh5 Nc6 3. Bc4 {Hint shown} Nf6 4. Qxf7# {Hint shown} 1-0"),record)
        let documents=try PGNImporter.parse(Data(record.utf8)),document=try XCTUnwrap(documents.first)
        XCTAssertEqual(documents.count,1);XCTAssertEqual(document.mainline.count,7,"the comments are not moves")
        for (index,node) in document.mainline.enumerated() {XCTAssertEqual(document.nodes[node].commentsAfter,[1,5,7].contains(index+1) ? ["Hint shown"]:[],"ply \(index+1)")}
        XCTAssertFalse(NetworkGameRecord.reviewPGN(game(pgn:"1. d4 d5",outcome:nil),on:day,calendar:utc).contains("Assistance"),"no header without assistance")
    }
    /// A peer's record is any PGN the rules replay, comments and variations included (chess.js keeps comments when it
    /// exports): only moves count as plies, so a comment after Black's assisted move lands after that move, not inside
    /// another comment.
    func testOnlyMovesCountAsPliesInAPeersRecord()throws {
        var commented=game(pgn:"1. e4 {note here} e5 (1... c5 {a variation} 2. Nf3) 2. Nf3 $1 ; to the end of the line\nNc6 *",outcome:nil)
        commented.assistedPlies=[2,4]
        let record=NetworkGameRecord.reviewPGN(commented,on:day,calendar:utc)
        XCTAssertTrue(record.hasSuffix("1. e4 e5 {Hint shown} 2. Nf3 Nc6 {Hint shown} *"),record)
        let document=try XCTUnwrap(PGNImporter.parse(Data(record.utf8)).first)
        XCTAssertEqual(document.mainline.map{document.nodes[$0].san},["e4","e5","Nf3","Nc6"]);XCTAssertEqual(document.nodes[document.mainline[1]].commentsAfter,["Hint shown"])
    }
    /// A record that starts from a set-up position keeps it, so Review replays its moves from there.
    func testASetUpStartIsKept()throws {
        let fen="4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"
        let record=NetworkGameRecord.reviewPGN(game(pgn:"[SetUp \"1\"]\n[FEN \"\(fen)\"]\n\n1. e4 Kd7 *",outcome:nil),on:day,calendar:utc)
        XCTAssertTrue(record.contains("[SetUp \"1\"]\n[FEN \"\(fen)\"]"),record)
        let document=try XCTUnwrap(PGNImporter.parse(Data(record.utf8)).first)
        XCTAssertEqual(document.mainline.map{document.nodes[$0].san},["e4","Kd7"])
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
        // A11: the crash file keeps the terms and the assisted moves, through the public record alone.
        var assisted=entry.game;assisted.assistance=NetworkAssistance(white:.guided,black:.insight);assisted.assistedPlies=[1]
        try file.save(NetworkCrashFile.Entry(game:assisted,part:.black));XCTAssertEqual(file.pending()?.game.assistance,assisted.assistance);XCTAssertEqual(file.pending()?.game.assistedPlies,[1])
        file.clear();XCTAssertNil(file.pending())
        try FileManager.default.createDirectory(at:file.url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("not json".utf8).write(to:file.url);XCTAssertNil(file.pending());XCTAssertFalse(FileManager.default.fileExists(atPath:file.url.path))
    }
}
