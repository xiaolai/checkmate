import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class CleanupPersistenceTests:XCTestCase {
    /// `plies` moves shuttling both knights, numbered `1.Nf3` with no space after the number.
    private func attachedNumberGame(plies:Int)->String {
        let cycle=["Nf3","Nf6","Ng1","Ng8"]
        return (0..<plies).map{($0%2==0 ? "\($0/2+1).":"")+cycle[$0%4]}.joined(separator:" ")
    }
    private func assertInvalid(_ message:String,file:StaticString=#filePath,line:UInt=#line,_ body:()throws->Void) {
        XCTAssertThrowsError(try body(),file:file,line:line){error in
            guard case CheckmateError.invalid(let reason)=error else{return XCTFail("Unexpected error \(error)",file:file,line:line)}
            XCTAssertEqual(reason,message,file:file,line:line)
        }
    }

    /// Each sample's count is what chess.js replays; the scan must agree before any replay happens.
    func testMainlineMoveCountMatchesReplayForEveryTokenShape()throws {
        let samples=[
            "1. e4 e5 2. Nf3 Nc6",
            "1.e4 e5 2.Nf3 Nc6 3.Bb5 a6",
            "1.Nf3 Nf6 2.g3 g6 3.Bg2 Bg7 4.0-0 0-0 5.d3 d6 1-0",
            "1.e4 {best by test; (really) 2.Nf3} 1...e5 2.Nf3 $1 Nc6!? (2...d6 3.d4 (3.Bc4) exd4) 3.Bb5 a6 ; comment Nf6\n4.Ba4 Nf6 5.O-O Be7 *",
            "[Event \"Casual (game) {x}\"]\n[White \"A; B\"]\n\n1.e4 e5 2.Qh5 Nc6 3.Bc4 Nf6 4.Qxf7# 1-0",
            "1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Bg5 Be7 5. e3 O-O 6. Nf3 Nbd7 1/2-1/2",
            "1.e4 d5 2.exd5 Qxd5 3.Nc3 Qa5 4.d4 c6 5.Nf3 Bg4 6.h3 Bxf3 7.Qxf3 e6 8.Bd2 Nf6 9.O-O-O Nbd7",
        ]
        let expected=[4,6,10,10,7,12,18]
        for (pgn,count) in zip(samples,expected) {
            XCTAssertEqual(StateStore.mainlineMoveCount(pgn),count,pgn)
            let rules=try ChessRules();try rules.restore(pgn);XCTAssertEqual(rules.records.count,count,pgn)
        }
    }
    func testAttachedMoveNumbersCountEveryMove() {
        XCTAssertEqual(StateStore.mainlineMoveCount("1.Nf3"),1)
        XCTAssertEqual(StateStore.mainlineMoveCount("1.Nf3 Nf6 2.Ng1 Ng8"),4)
        XCTAssertEqual(StateStore.mainlineMoveCount("1.Nf3 1...Nf6 2.0-0"),3)
        XCTAssertEqual(StateStore.mainlineMoveCount(attachedNumberGame(plies:2001)),2001)
    }
    /// The bypass: numbered tokens such as `1.Nf3` were not counted, so an over-long game was replayed in full first.
    func testOverLongGameWithAttachedNumbersIsRefusedFromItsText()throws {
        var state=ApplicationState();state.practice.pgn=attachedNumberGame(plies:ReviewPolicy.maximumMainlinePlies+1)
        XCTAssertGreaterThan(StateStore.mainlineMoveCount(state.practice.pgn),ReviewPolicy.maximumMainlinePlies)
        assertInvalid("The saved game is longer than 2000 moves."){try StateStore.validate(state)}
        state.practice.pgn="";state.practice.previousGame=attachedNumberGame(plies:ReviewPolicy.maximumMainlinePlies+1)
        assertInvalid("The previous game is longer than 2000 moves."){try StateStore.validate(state)}
    }
    /// Moves inside comments and variations are not replayed, so they do not count toward the bound.
    func testCommentsAndVariationsDoNotCountTowardTheBound()throws {
        let long=attachedNumberGame(plies:ReviewPolicy.maximumMainlinePlies+1)
        let pgn="1.Nc3 {"+long+"} 1...Nc6 ("+long+") 2.Nb1"
        XCTAssertEqual(StateStore.mainlineMoveCount(pgn),3)
        XCTAssertEqual(StateStore.mainlineMoveCount("1.e4 ; 1.Nf3 Nf6 2.Ng1\n1...e5"),2)
    }

    func testPuzzleAttemptsAboveTheBoundAreRefusedOnLoadAndImport()throws {
        XCTAssertEqual(PuzzleProgress.maximumAttempts,TrainingState.maximumCount)
        for attempts in [PuzzleProgress.maximumAttempts+1,Int.max] {
            var state=ApplicationState();var progress=PuzzleProgress();progress.attempts=attempts;state.puzzles["fixture"]=progress
            assertInvalid("Saved learning progress has invalid bounds."){try StateStore.validate(state)}
            let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
            let store=StateStore(directory:dir);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            try JSONEncoder().encode(state).write(to:store.url)
            assertInvalid("Saved learning progress has invalid bounds."){_ = try store.load()}
        }
        var state=ApplicationState();var progress=PuzzleProgress();progress.attempts=PuzzleProgress.maximumAttempts;state.puzzles["fixture"]=progress
        XCTAssertNoThrow(try StateStore.validate(state))
    }
    func testRecordCountsEachAnswerWithinTheLoadedBound()throws {
        var progress=PuzzleProgress();progress.record(correct:false)
        XCTAssertEqual(progress.attempts,1);XCTAssertTrue(progress.review);XCTAssertFalse(progress.solved)
        progress.record(correct:true);XCTAssertEqual(progress.attempts,2);XCTAssertTrue(progress.solved);XCTAssertFalse(progress.review)
        progress.attempts=PuzzleProgress.maximumAttempts-1;progress.record(correct:true)
        XCTAssertEqual(progress.attempts,PuzzleProgress.maximumAttempts)
        var state=ApplicationState();state.puzzles["fixture"]=progress;XCTAssertNoThrow(try StateStore.validate(state))
    }
    /// A record loaded at the bound and answered again stays at the bound, so the next save is not refused (#33).
    func testAnsweringARecordLoadedAtTheBoundSavesAtTheBound()throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let store=StateStore(directory:dir)
        var state=ApplicationState();var progress=PuzzleProgress();progress.attempts=PuzzleProgress.maximumAttempts;state.puzzles["fixture"]=progress
        try store.save(state)
        var loaded=try store.load();var record=try XCTUnwrap(loaded.puzzles["fixture"])
        XCTAssertEqual(record.attempts,PuzzleProgress.maximumAttempts)
        record.record(correct:false);XCTAssertEqual(record.attempts,PuzzleProgress.maximumAttempts);XCTAssertTrue(record.review)
        record.record(correct:true);XCTAssertEqual(record.attempts,PuzzleProgress.maximumAttempts);XCTAssertTrue(record.solved);XCTAssertFalse(record.review)
        loaded.puzzles["fixture"]=record
        XCTAssertNoThrow(try store.save(loaded))
        XCTAssertEqual(try store.load().puzzles["fixture"]?.attempts,PuzzleProgress.maximumAttempts)
    }
}
