import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// Audit regressions for import recovery, practice game swaps and saved-state validation.
@MainActor final class AuditPlayRecoveryTests:XCTestCase {
    private func report(_ text:String)throws -> (documents:[GameDocument],skipped:[ReviewImportError]) {try PGNImporter.parseReport(Data(text.utf8))}
    private func moves(_ documents:[GameDocument])->[[String]] {documents.map{document in document.mainline.compactMap{document.nodes[$0].san}}}
    // #1: an invalid FEN header is that game's problem; the valid games around it still import.
    func testInvalidFENHeaderSkipsOnlyItsGame()throws {
        let result=try report("[Event \"a\"]\n1. e4 *\n\n[SetUp \"1\"]\n[FEN \"4k3/8/8/8/8/8/8/P3K3 w - - 0 1\"]\n1. Ke2 *\n\n[Event \"c\"]\n1. d4 *")
        XCTAssertEqual(moves(result.documents),[["e4"],["d4"]]);XCTAssertEqual(result.skipped.count,1);XCTAssertEqual(result.skipped.first?.record,2)
        XCTAssertTrue(result.skipped.first?.reason.hasPrefix("Invalid FEN") ?? false,result.skipped.first?.reason ?? "")
    }
    // #2: a lexical error met while skipping an unreadable game never discards the games already read.
    func testLexicalErrorWhileSkippingKeepsOtherGames()throws {
        let result=try report("[Event \"a\"]\n1. e4 *\n\n[Event \"b\"]\n1. e5 e4 [Bad 2. d4 *\n\n[Event \"c\"]\n1. d4 *")
        XCTAssertEqual(moves(result.documents),[["e4"],["d4"]]);XCTAssertEqual(result.skipped.count,1)
    }
    // Same mechanism: a lexical error before a game's headers, or in the first token, is reported for that game alone.
    func testLexicalErrorInPreambleOrFirstTokenKeepsOtherGames()throws {
        let preamble=try report("1. e4 *\n{note} [Bad 1. d4 *\n\n[Event \"x\"]\n1. c4 *")
        XCTAssertEqual(moves(preamble.documents),[["e4"],["c4"]]);XCTAssertEqual(preamble.skipped.count,1)
        let first=try report("[Event \"a\"\n1. e4 *\n\n[Event \"b\"]\n1. d4 *")
        XCTAssertEqual(moves(first.documents),[["d4"]]);XCTAssertEqual(first.skipped.count,1)
    }
    // A header the lexer cannot read leaves the game's other headers behind it: they are skipped with the game, never
    // read as a game of their own.
    func testUnreadableHeaderSkipsTheRestOfItsGame()throws {
        let result=try report("[Event \"a\"]\n[Bad\n[Site \"x\"]\n1. e4 *\n\n[Event \"b\"]\n1. d4 *")
        XCTAssertEqual(moves(result.documents),[["d4"]]);XCTAssertEqual(result.skipped.count,1)
    }
    // #3: a resigned game keeps its result through New Game and Restore Previous Game.
    func testRestoredPreviousGameKeepsItsEnding()throws {
        let s=try GameSession(engine:nil);try s.playWhite(from:"e2",to:"e4");s.resign();let resigned=s.gameOverMessage;XCTAssertTrue(s.finished)
        s.newGame();XCTAssertFalse(s.finished);try s.playWhite(from:"d2",to:"d4");try s.restorePrevious()
        XCTAssertTrue(s.finished,"The resigned game must not restore as unfinished");XCTAssertEqual(s.gameOverMessage,resigned);XCTAssertFalse(s.canTakeBack)
        try s.restorePrevious();XCTAssertFalse(s.finished,"The new game swapped back stays unfinished")
        let reloaded=try GameSession(engine:nil,state:JSONDecoder().decode(ApplicationState.self,from:JSONEncoder().encode(s.state)));try reloaded.restorePrevious();XCTAssertTrue(reloaded.finished,"The previous game's ending survives a save")
    }
    // #4: a restored practice fork keeps its Take Back boundary.
    func testRestoredPracticeForkKeepsItsStart()throws {
        let d=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],s=try GameSession(engine:nil);try s.installPracticeFork(d.rules(at:d.mainline.last!),side:"w")
        try s.playWhite(from:"g1",to:"f3");s.newGame();try s.restorePrevious();XCTAssertEqual(s.rules.history,["e4","e5","Nf3"])
        s.undo();XCTAssertEqual(s.rules.history,["e4","e5"]);XCTAssertFalse(s.canTakeBack,"Take Back never rewinds into the reviewed game");s.undo();XCTAssertEqual(s.rules.history,["e4","e5"])
    }
    // #15: importing a legacy practice game replaces the ended game, so the import is playable with its own boundary.
    func testLegacyPracticeImportClearsTheReplacedGamesState()throws {
        let s=try GameSession(engine:nil);try s.playWhite(from:"e2",to:"e4");s.resign();var state=s.state;state.practice.pgn=s.rules.pgn;state.practice.fen=s.rules.fen;state.practice.startPly=1;state.practice.beginnerSevereStreak=1
        try LegacyImporter.apply(Data(#"{"checkmate-practice-pgn":"1. d4 d5"}"#.utf8),to:&state,course:CourseLibrary())
        XCTAssertNil(state.practice.ending);XCTAssertEqual(state.practice.startPly,0);XCTAssertEqual(state.practice.beginnerSevereStreak,0)
        let imported=try GameSession(engine:nil,state:state);XCTAssertFalse(imported.finished);XCTAssertTrue(imported.canTakeBack)
        try imported.restorePrevious();XCTAssertEqual(imported.rules.history,["e4"]);XCTAssertTrue(imported.finished,"The replaced game keeps its ending as the previous game")
    }
    // #16: a damaged mini-game this version knows fails the load; only an unknown kind is dropped.
    func testDamagedKnownMiniGameFailsTheLoad()throws {
        var state=ApplicationState();state.miniGames=["pawn-duel":MiniGameState(kind:.pawnDuel)]
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as! [String:Any],games=object["miniGames"] as! [String:Any],game=games["pawn-duel"] as! [String:Any]
        game["computer"]="yes";games["pawn-duel"]=game;object["miniGames"]=games
        XCTAssertThrowsError(try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:object)))
        games["pawn-duel"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(MiniGameState(kind:.pawnDuel)));var future=game;future["kind"]="future-game";games["future-game"]=future;object["miniGames"]=games
        XCTAssertEqual(try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:object)).miniGames?.keys.sorted(),["pawn-duel"])
    }
    // #17: a practice start beyond its game's moves is refused, for the current and the previous game.
    func testPracticeStartBeyondTheGameIsRefused()throws {
        let rules=try ChessRules();try rules.move(uci:"e2e4");try rules.move(uci:"e7e5")
        var state=ApplicationState();state.practice.pgn=rules.pgn;state.practice.fen=rules.fen;state.practice.startPly=2;XCTAssertNoThrow(try StateStore.validate(state))
        state.practice.startPly=3;XCTAssertThrowsError(try StateStore.validate(state))
        state.practice.startPly=0;state.practice.previousGame=rules.pgn
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as! [String:Any],practice=object["practice"] as! [String:Any];practice["previousStartPly"]=3;object["practice"]=practice
        XCTAssertThrowsError(try StateStore.validate(JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:object))))
    }
}
