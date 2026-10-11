import XCTest
@testable import CheckmateCore

/// Low-severity fixes in play and saved progress.
@MainActor final class B10ShellPlayTests:XCTestCase {
    private func directory()->URL {FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}
    /// PL2-12: passing up a forced mate is a large regret, so the beginner's caps still apply.
    func testAMissedMateIsAlwaysAboveTheRegretCap(){
        let mateInThree=AnalysisScore(kind:"mate",value:3),winning=AnalysisScore(kind:"cp",value:900)
        XCTAssertGreaterThan(BeginnerOpponent.centipawns(mateInThree)-BeginnerOpponent.centipawns(winning),BeginnerPolicy.maximumRegretCp)
        XCTAssertGreaterThan(BeginnerOpponent.centipawns(AnalysisScore(kind:"mate",value:1)),BeginnerOpponent.centipawns(mateInThree),"A faster mate is worth more")
        XCTAssertLessThan(BeginnerOpponent.centipawns(AnalysisScore(kind:"mate",value:-2)),-9000)
    }
    /// PL-13: import and practice-fork backups never grow without bound.
    func testImportBackupsAreCapped()throws {
        let root=directory();defer{try? FileManager.default.removeItem(at:root)};let store=StateStore(directory:root)
        for _ in 0..<(StateStore.keptImportBackups+5){_ = try store.preserveBeforeImport(ApplicationState())}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path).filter{$0.hasPrefix("state-before-import-")}.count,StateStore.keptImportBackups)
    }
    /// PL2-4: a saved practice game must start from a legal position.
    func testSavedGameFromAnIllegalPositionIsRejected()throws {
        var state=ApplicationState();state.practice.pgn="[SetUp \"1\"]\n[FEN \"4k3/8/8/8/8/8/8/4K3 w KQ - 0 1\"]\n\n*"
        XCTAssertThrowsError(try StateStore.validate(state),"Castling rights without rooks are not a legal start")
        state.practice.pgn="[SetUp \"1\"]\n[FEN \"4k3/8/8/8/8/8/8/R3K3 w Q - 0 1\"]\n\n*";XCTAssertNoThrow(try StateStore.validate(state))
    }
    /// PL-5 / PL2-1 companions: the review workspace is reported as such, never as practice.
    func testReviewWorkspaceIsNotReportedAsPractice()throws {
        let s=try GameSession(engine:nil);s.suspendForReview();XCTAssertEqual(s.publicState()["mode"] as? String,"review_workspace")
        XCTAssertThrowsError(try s.openVoice(),"Voice does not connect in the review workspace")
        s.returnFromReview(resumeReply:false);XCTAssertEqual(s.publicState()["mode"] as? String,"practice")
    }
}

/// LE2-6: a saved mini-game of an unknown kind (from a newer version) is dropped; the rest of the state loads.
final class B10StateCompatibilityTests:XCTestCase {
    func testAnUnknownMiniGameDoesNotFailTheWholeState()throws {
        var state=ApplicationState();state.miniGames=["pawn-duel":MiniGameState(kind:.pawnDuel)];state.settings.skill=9
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as! [String:Any]
        var games=object["miniGames"] as! [String:Any];var future=games["pawn-duel"] as! [String:Any];future["kind"]="future-game";games["future-game"]=future;object["miniGames"]=games
        let decoded=try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(decoded.settings.skill,9);XCTAssertEqual(decoded.miniGames?.keys.sorted(),["pawn-duel"])
        object.removeValue(forKey:"practice");XCTAssertThrowsError(try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:object)),"Required fields stay required")
    }
}
