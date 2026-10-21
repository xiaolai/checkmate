import XCTest
@testable import CheckmateDomain

/// L-23 and L-24: which mini-games let the learner play Black, and the per-level record with its step-up and
/// step-down advice.
final class MiniGameRecordTests:XCTestCase {
    private static let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// A finished Pawn Duel at `level`, played from `side`: `winner` w or b, or nil for a draw by repetition.
    private func finished(_ winner:String?,level:String="standard",side:String="w",record:inout MiniGameRecord)->MiniGameState {
        var game=MiniGameState(kind:.pawnDuel)
        game.snapshot.board=winner=="w" ? ["a8":"wp","h7":"bp"]:winner=="b" ? ["a1":"bp","h2":"wp"]:["a2":"wp","h7":"bp"]
        if winner==nil{game.history=[game.snapshot,game.snapshot]}
        game.settleLevel(adopting:level)
        record.side=MiniGameRunSide(run:game.run,side:side)
        return game
    }
    func testOnlyGamesEqualFromBothSidesOfferTheChoice()throws {
        let results=try JSONDecoder().decode(MiniGameCalibration.Results.self,from:Data(contentsOf:Self.root.appendingPathComponent("Content/calibration/mini-game-results.json")))
        XCTAssertEqual(MiniGameSides.allowed(by:results),MiniGameSides.offered,"the side choice must be what the published results allow")
        XCTAssertEqual(Set(MiniGameKind.allCases.filter(MiniGameSides.offersChoice)),[.pawnDuel,.rookSweep,.rooksAndPawns,.bishopSweep,.bishopsAndPawns])
        XCTAssertFalse(MiniGameSides.symmetricStart(.queenVsPawns));XCTAssertFalse(MiniGameSides.symmetricStart(.knightCorners))
        XCTAssertTrue(MiniGameSides.symmetricStart(.knightCapture),"Knight Capture starts even but plays unevenly, so the evidence, not the board, withdraws it")
        XCTAssertFalse(MiniGameSides.offersChoice(.knightCapture))
    }
    func testASideIsSettledOnceAtTheStartOfARun() {
        var record=MiniGameRecord(),game=MiniGameState(kind:.pawnDuel)
        record.settleSide(of:game,preferred:"b");XCTAssertEqual(record.side(of:game),"b")
        record.settleSide(of:game,preferred:"w");XCTAssertEqual(record.side(of:game),"b","a run keeps its side")
        let next=MiniGameState(kind:.pawnDuel);XCTAssertEqual(record.side(of:next),"w","another run's side is never inherited")
        var moved=MiniGameState(kind:.pawnDuel);moved.history=[moved.snapshot]
        var fresh=MiniGameRecord();fresh.settleSide(of:moved,preferred:"b");XCTAssertEqual(fresh.side(of:moved),"w","a run already under way was played from White")
        for kind in [MiniGameKind.knightCapture,.queenVsPawns] {let other=MiniGameState(kind:kind);var r=MiniGameRecord();r.settleSide(of:other,preferred:"b");XCTAssertEqual(r.side(of:other),"w",kind.rawValue)}
        let human=MiniGameState(kind:.pawnDuel,computer:false);var r=MiniGameRecord();r.settleSide(of:human,preferred:"b");XCTAssertEqual(r.side(of:human),"w")
    }
    func testAFinishIsCountedOnceAtItsLevelFromTheLearnersSide() {
        var record=MiniGameRecord()
        let win=finished("w",record:&record);XCTAssertTrue(record.count(win));XCTAssertFalse(record.count(win),"the same run counts once")
        let lossAsBlack=finished("w",side:"b",record:&record);XCTAssertTrue(record.count(lossAsBlack))
        let winAsBlack=finished("b",side:"b",record:&record);XCTAssertTrue(record.count(winAsBlack))
        let draw=finished(nil,level:"beginner",record:&record);XCTAssertEqual(draw.draw,.repetition);XCTAssertTrue(record.count(draw))
        XCTAssertEqual(record.levels,["standard":MiniGameTally(wins:2,draws:0,losses:1),"beginner":MiniGameTally(wins:0,draws:1,losses:0)])
        XCTAssertEqual(record.streak,"d");XCTAssertEqual(record.streakLevel,"beginner")
        var unfinished=MiniGameState(kind:.pawnDuel);unfinished.settleLevel(adopting:"standard");XCTAssertFalse(record.count(unfinished))
        var human=finished("w",record:&record);human.computer=false;XCTAssertFalse(record.count(human),"only games against the computer are counted")
    }
    func testThreeWinsInARowSuggestAStepUpAndThreeLossesAStepDown() {
        let offered=["beginner","standard","challenging"]
        var record=MiniGameRecord()
        for _ in 0..<2 {let game=finished("w",record:&record);record.count(game)}
        XCTAssertNil(record.advice(level:"standard",offered:offered),"two wins are not yet a run")
        let third=finished("w",record:&record);record.count(third)
        XCTAssertEqual(record.advice(level:"standard",offered:offered),.stepUp(to:"challenging"))
        XCTAssertNil(record.advice(level:"challenging",offered:offered),"results at another level suggest nothing")
        XCTAssertNil(record.advice(level:"standard",offered:["beginner","standard"]),"no step up past the strongest offered level")
        let draw=finished(nil,record:&record);record.count(draw)
        XCTAssertNil(record.advice(level:"standard",offered:offered),"a mixed run suggests nothing")
        var losing=MiniGameRecord()
        for _ in 0..<3 {let game=finished("b",level:"beginner",record:&losing);losing.count(game)}
        XCTAssertNil(losing.advice(level:"beginner",offered:offered),"no step down below the weakest level")
        for _ in 0..<3 {let game=finished("b",record:&losing);losing.count(game)}
        XCTAssertEqual(losing.advice(level:"standard",offered:offered),.stepDown(to:"beginner"))
        let other=finished("w",level:"beginner",record:&losing);losing.count(other)
        XCTAssertEqual(losing.streak,"w","a result at another level starts the run again");XCTAssertNil(losing.advice(level:"standard",offered:offered))
    }
    func testOldAndDamagedSavesDecodeSafely()throws {
        let decoder=JSONDecoder()
        XCTAssertEqual(try decoder.decode(MiniGameRecord.self,from:Data("{}".utf8)),MiniGameRecord(),"every field defaults")
        XCTAssertEqual(try decoder.decode(MiniGameTally.self,from:Data(#"{"wins":2}"#.utf8)),MiniGameTally(wins:2))
        XCTAssertThrowsError(try decoder.decode(MiniGameTally.self,from:Data(#"{"wins":-1}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(MiniGameRecord.self,from:Data(#"{"streak":"wwww"}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(MiniGameRecord.self,from:Data(#"{"streak":"x"}"#.utf8)))
        XCTAssertNil(try decoder.decode(MiniGameRecord.self,from:Data(#"{"side":{"run":"r","side":"red"}}"#.utf8)).side,"a side this build cannot use reads as White")
        var record=MiniGameRecord();let game=finished("w",record:&record);record.count(game)
        XCTAssertEqual(try decoder.decode(MiniGameRecord.self,from:JSONEncoder().encode(record)),record)
    }
    func testTheSidePreferenceKeepsOnlyGamesThatOfferIt()throws {
        let s=AppSettings(raw:["miniLearnerSides":["pawn-duel":"b","rook-sweep":"w","knight-capture":"b","queen-vs-pawns":"b","bishop-sweep":"red","no-such-game":"b"]])
        XCTAssertEqual(s.miniLearnerSides,["pawn-duel":"b","rook-sweep":"w"]);XCTAssertNil(AppSettings(raw:[:]).miniLearnerSides)
        XCTAssertNil((try JSONSerialization.jsonObject(with:JSONEncoder().encode(AppSettings())) as? [String:Any])?["miniLearnerSides"],"a save without a choice writes nothing new")
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(s)).miniLearnerSides,s.miniLearnerSides)
    }
    func testRecordsAreSavedWithTheStateAndKeepWhatANewerBuildWrote()throws {
        var state=ApplicationState(),record=MiniGameRecord();let game=finished("w",record:&record);record.count(game);state.miniGameRecords=["pawn-duel":record]
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as? [String:Any])
        var records=try XCTUnwrap(object["miniGameRecords"] as? [String:Any]),pawn=try XCTUnwrap(records["pawn-duel"] as? [String:Any])
        pawn["future"]="kept";records["pawn-duel"]=pawn;records["some-new-game"]=["levels":[:]];object["miniGameRecords"]=records
        let loaded=try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(loaded.miniGameRecords,["pawn-duel":record],"a game this build does not know is left out")
        let written=ApplicationState.merged(try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(loaded)) as? [String:Any]),loaded.unknownFields,nested:loaded.unknownNestedFields)
        XCTAssertEqual(((written["miniGameRecords"] as? [String:Any])?["pawn-duel"] as? [String:Any])?["future"] as? String,"kept")
        XCTAssertNotNil((written["miniGameRecords"] as? [String:Any])?["some-new-game"],"and written back")
        XCTAssertNil(try JSONDecoder().decode(ApplicationState.self,from:JSONEncoder().encode(ApplicationState())).miniGameRecords,"an old save has none")
        records["pawn-duel"]=["levels":["standard":["wins":-3]]];object["miniGameRecords"]=records
        XCTAssertThrowsError(try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:object)),"damaged progress fails the load rather than being erased by the next save")
    }
    func testUndoAsBlackTakesBackTheLearnersMoveAndTheReply() {
        var game=MiniGameState(kind:.pawnDuel)
        for (from,to) in [("e2","e4"),("e7","e5"),("d2","d4")] {XCTAssertTrue(game.play(MiniGameMove(from:from,to:to)))}
        let blackToMove=game;XCTAssertTrue(game.play(MiniGameMove(from:"d7",to:"d6")));XCTAssertTrue(game.play(MiniGameMove(from:"g2",to:"g3")))
        MiniGameSides.undo(&game,learner:"b");XCTAssertEqual(game,blackToMove)
        var white=blackToMove;var plain=blackToMove;MiniGameSides.undo(&white,learner:"w");plain.undo();XCTAssertEqual(white,plain,"from White, undo is the game's own")
        var opening=MiniGameState(kind:.pawnDuel);XCTAssertTrue(opening.play(MiniGameMove(from:"e2",to:"e4")))
        MiniGameSides.undo(&opening,learner:"b");XCTAssertEqual(opening.history.count,0);XCTAssertEqual(opening.turn,"w","nothing of the learner's to take back: the computer's opening is replayed")
    }
}
