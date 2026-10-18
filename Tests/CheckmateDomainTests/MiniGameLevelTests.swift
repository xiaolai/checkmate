import XCTest
import CheckmateDomain

/// WI-015: a mini-game's opponent level is preferred per game, frozen per run, and verified against the run it names.
final class MiniGameLevelTests:XCTestCase {
    private func settings(_ raw:[String:Any])->AppSettings {AppSettings(raw:raw)}
    func testPerGamePreferenceOverridesTheGlobalOne(){
        let s=settings(["miniOpponentProfile":"beginner","miniOpponentProfiles":["pawn-duel":"challenging"]])
        XCTAssertEqual(MiniGameOffering.level(for:.pawnDuel,settings:s),"challenging")
        XCTAssertEqual(MiniGameOffering.level(for:.rookSweep,settings:s),"beginner","a game without its own preference uses the global one")
        XCTAssertEqual(MiniGameOffering.level(for:.rookSweep,settings:AppSettings()),"standard","today's default")
    }
    func testUnknownAndDamagedPreferencesAreRejectedEntryByEntry(){
        let s=settings(["miniOpponentProfile":"impossible","miniOpponentProfiles":["pawn-duel":"challenging","rook-sweep":"gentle","knight-corners":"beginner","no-such-game":"beginner","queen-vs-pawns":7]])
        XCTAssertEqual(s.miniOpponentProfiles,["pawn-duel":"challenging"]);XCTAssertEqual(s.miniOpponentProfile,"standard")
        XCTAssertEqual(settings(["miniOpponentProfiles":["pawn-duel","beginner"]]).miniOpponentProfiles,[:],"not an object")
        XCTAssertEqual(settings(["miniOpponentProfiles":NSNull()]).miniOpponentProfiles,[:])
    }
    func testPreferencesSurviveASave()throws {
        var s=AppSettings();s.miniOpponentProfiles=["bishop-sweep":"beginner"]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(s)).miniOpponentProfiles,["bishop-sweep":"beginner"])
    }
    func testTheOfferingKeepsTodaysLevelsUntilCalibrationPublishes(){
        for kind in MiniGameKind.allCases {
            XCTAssertEqual(MiniGameOffering.levels(for:kind),kind.solo ? []:["beginner","standard","challenging"],kind.rawValue)
            XCTAssertEqual(MiniGameOffering.offersChoice(kind),!kind.solo)
        }
        // A preference the game does not offer falls through to the global one, then to the fallback.
        let s=settings(["miniOpponentProfile":"beginner","miniOpponentProfiles":["pawn-duel":"challenging"]])
        XCTAssertEqual(MiniGameOffering.level(for:.pawnDuel,settings:s,offered:["beginner","standard"]),"beginner")
        XCTAssertEqual(MiniGameOffering.level(for:.pawnDuel,settings:s,offered:["standard"]),"standard")
        XCTAssertEqual(MiniGameOffering.level(for:.pawnDuel,settings:s,offered:[]),MiniGameOffering.fallbackLevel)
    }
    func testANewRunFreezesItsLevelAndASoloGameHasNone(){
        var game=MiniGameState(kind:.pawnDuel);game.settleLevel(adopting:"challenging")
        XCTAssertEqual(game.runLevel,MiniGameLevel(profile:"challenging",run:game.run,witness:game.witness,exact:true))
        game.settleLevel(adopting:"beginner");XCTAssertEqual(game.runLevel?.profile,"challenging","settling again keeps the run's level")
        var solo=MiniGameState(kind:.knightCorners);solo.settleLevel(adopting:"beginner");XCTAssertNil(solo.level)
    }
    func testALevelOfAnotherRunIsIgnored(){
        var game=MiniGameState(kind:.pawnDuel);_ = game.play(MiniGameMove(from:"e2",to:"e4"))
        game.level=MiniGameLevel(profile:"challenging",run:"another-run",witness:game.witness)
        XCTAssertNil(game.runLevel,"unverified")
        game.settleLevel(adopting:"beginner")
        XCTAssertEqual(game.runLevel?.profile,"beginner");XCTAssertEqual(game.runLevel?.exact,false,"a move was played at an unknown level")
        var fresh=MiniGameState(kind:.pawnDuel);fresh.level=MiniGameLevel(profile:"challenging",run:"another-run",witness:"");fresh.settleLevel(adopting:"beginner")
        XCTAssertEqual(fresh.runLevel?.exact,true,"no move yet: the adopted level is exact")
    }
    func testABoardMovedWithoutItsWitnessMarksTheRunInexactForGood(){
        var game=MiniGameState(kind:.pawnDuel);game.settleLevel(adopting:"challenging")
        _ = game.play(MiniGameMove(from:"e2",to:"e4"));game.stampWitness();game.settleLevel(adopting:"beginner")
        XCTAssertEqual(game.runLevel?.exact,true,"control: every save stamped the witness")
        _ = game.play(MiniGameMove(from:"d7",to:"d5"))  // as an older build continuing the run: no stamp
        game.settleLevel(adopting:"beginner");XCTAssertEqual(game.runLevel,MiniGameLevel(profile:"challenging",run:game.run,witness:game.witness,exact:false))
        game.stampWitness();game.settleLevel(adopting:"beginner");XCTAssertEqual(game.runLevel?.exact,false,"rewriting the witness never makes it exact again")
    }
    func testTheWitnessFollowsTheBoardAndTheHistoryLength(){
        var a=MiniGameState(kind:.pawnDuel);let start=a.witness
        XCTAssertEqual(start.count,16);XCTAssertEqual(start,MiniGameState(kind:.pawnDuel).witness,"independent of the seed")
        _ = a.play(MiniGameMove(from:"e2",to:"e3"));XCTAssertNotEqual(a.witness,start)
        a.undo();XCTAssertEqual(a.witness,start)
        var b=a;b.history=[b.snapshot];XCTAssertNotEqual(b.witness,a.witness,"the same board after more positions differs")
    }
    func testLevelsDecodeLenientlyAndOlderSavesStillLoad()throws {
        var game=MiniGameState(kind:.rookSweep);game.settleLevel(adopting:"beginner")
        let data=try JSONEncoder().encode(game);XCTAssertEqual(try JSONDecoder().decode(MiniGameState.self,from:data),game)
        var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        object.removeValue(forKey:"level");let older=try JSONDecoder().decode(MiniGameState.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(older.level);XCTAssertEqual(older.board,game.board);XCTAssertEqual(older.opponentSeed,game.opponentSeed)
        XCTAssertNil((try JSONSerialization.jsonObject(with:JSONEncoder().encode(older)) as! [String:Any])["level"],"no level, no key")
        for damaged:Any in ["standard",["profile":"gentle","run":game.run,"witness":"","exact":true],["profile":"standard","run":game.run],["profile":"standard","run":"","witness":"","exact":true]] {
            object["level"]=damaged
            XCTAssertNil(try JSONDecoder().decode(MiniGameState.self,from:JSONSerialization.data(withJSONObject:object)).level,"\(damaged)")
        }
    }
    func testCompletionEventsRecordTheLevelAndOlderEventsStillDecode()throws {
        let level=MiniGameLevel(profile:"challenging",run:"r",witness:"w",exact:false),at=Date(timeIntervalSince1970:1_800_000_000)
        let event=TrainingCompletionEvent(id:"e",kind:"pawn-duel",run:"r",winner:"w",drawReason:nil,computer:true,origin:"lesson",at:at,level:level)
        XCTAssertEqual(event.level,"challenging");XCTAssertEqual(event.levelPolicy,"mini-search-v2");XCTAssertEqual(event.levelExact,false)
        XCTAssertEqual(try JSONDecoder().decode(TrainingCompletionEvent.self,from:JSONEncoder().encode(event)),event)
        let unlevelled=TrainingCompletionEvent(id:"e",kind:"pawn-duel",run:"r",winner:"w",drawReason:nil,computer:false,origin:"lesson",at:at)
        let keys=Set((try JSONSerialization.jsonObject(with:JSONEncoder().encode(unlevelled)) as! [String:Any]).keys)
        XCTAssertEqual(keys,["id","kind","run","winner","computer","origin","at"],"an event without a level is written exactly as before")
        XCTAssertEqual(try JSONDecoder().decode(TrainingCompletionEvent.self,from:JSONEncoder().encode(unlevelled)),unlevelled)
    }
}
