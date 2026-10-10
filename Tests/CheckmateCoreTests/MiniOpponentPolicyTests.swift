import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class MiniOpponentPolicyTests:XCTestCase {
    func testEveryCompetitiveProfileIsLegalAndDeterministic(){for kind in MiniGameKind.allCases where !kind.solo {let game=MiniGameState(kind:kind);for profile in ["beginner","standard","challenging"] {let a=MiniGameOpponent.choose(in:game,profile:profile,seed:42,timeLimited:false),b=MiniGameOpponent.choose(in:game,profile:profile,seed:42,timeLimited:false);XCTAssertEqual(a,b);XCTAssertTrue(a.map{MiniGameRules.moves(board:game.board,kind:kind,side:game.turn).contains($0)} ?? false)}}}
}
extension MiniOpponentPolicyTests {
    func testSeedActuallySelectsDifferentEqualCandidates(){let game=MiniGameState(kind:.pawnDuel);let choices=Set((1...16).compactMap{seed in MiniGameOpponent.choose(in:game,profile:"beginner",seed:UInt64(seed)).map{$0.from+$0.to}});XCTAssertGreaterThan(choices.count,1)}
    func testFrozenSweepAndImmediateRaceWin(){var hunt=MiniGameState(kind:.rookSweep);hunt.snapshot.board=["a1":"wr","h8":"br","a7":"bp","b2":"wp"];for profile in ["beginner","standard","challenging"]{let move=MiniGameOpponent.choose(in:hunt,profile:profile,seed:1);XCTAssertEqual(move,MiniGameMove(from:"a1",to:"a7"));XCTAssertFalse(MiniGameRules.moves(board:hunt.board,kind:.rookSweep,side:"w").contains{$0.from=="b2"})};var race=MiniGameState(kind:.pawnDuel);race.snapshot.board=["a7":"wp","b2":"bp"];XCTAssertEqual(MiniGameOpponent.choose(in:race,profile:"beginner"),MiniGameMove(from:"a7",to:"a8"))}
    func testEveryGameProfileP95UnderOneSecond()throws {var samples:[Double]=[],rows:[[String:Any]]=[];for kind in MiniGameKind.allCases where !kind.solo{for profile in ["beginner","standard","challenging"]{let game=MiniGameState(kind:kind),start=Date(),move=MiniGameOpponent.choose(in:game,profile:profile,seed:17),milliseconds=Date().timeIntervalSince(start)*1000;samples.append(milliseconds);XCTAssertNotNil(move);rows.append(["game":kind.rawValue,"profile":profile,"milliseconds":milliseconds,"policy":jsonObject(MiniOpponentPolicy.forGame(kind,profile:profile))])}};samples.sort();let p95=samples[Int(Double(samples.count)*0.95)];XCTAssertLessThanOrEqual(p95,1000);if let path=ProcessInfo.processInfo.environment["CHECKMATE_MINI_PERFORMANCE"]{try JSONSerialization.data(withJSONObject:["p95Ms":p95,"samples":rows],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))}}
    func testMiniSeedPersistsAndLegacyStateStillDecodes()throws {
        let game=MiniGameState(kind:.pawnDuel),data=try JSONEncoder().encode(game),restored=try JSONDecoder().decode(MiniGameState.self,from:data)
        XCTAssertEqual(restored.opponentSeed,game.opponentSeed);XCTAssertNotNil(restored.opponentSeed)
        var old=try JSONSerialization.jsonObject(with:data) as! [String:Any];old.removeValue(forKey:"opponentSeed")
        let legacy=try JSONDecoder().decode(MiniGameState.self,from:JSONSerialization.data(withJSONObject:old));XCTAssertNil(legacy.opponentSeed);XCTAssertEqual(legacy.board,game.board)
    }

}
@MainActor final class MiniProfileCancellationTests:XCTestCase {
    func testProfileChangeReplacesPendingReplyAndResetCancelsIt()async throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        session.state.settings.pieceDuration=0;session.state.settings.miniOpponentProfile="challenging"
        player.openLesson(index:3);player.startPawnDuel()
        // Use an opening after which the two profiles choose different replies, so the reply shows which profile
        // chose it: a reply that merely arrives cannot tell a replaced request from the original one.
        func seed(_ game:MiniGameState)->UInt64 {(UInt64(game.opponentSeed ?? "1",radix:16) ?? 1) &+ UInt64(game.history.count+1)}
        var expected:MiniGameMove?
        for (from,to) in [("g2","g4"),("b2","b4"),("c2","c4"),("d2","d4"),("e2","e4"),("f2","f4"),("b2","b3"),("c2","c3"),("d2","d3"),("e2","e3"),("f2","f3"),("g2","g3")] {
            player.click(from);player.click(to);XCTAssertTrue(player.miniThinking)
            let game=try XCTUnwrap(player.miniGame),beginner=MiniGameOpponent.choose(in:game,profile:"beginner",seed:seed(game))
            if beginner != MiniGameOpponent.choose(in:game,profile:"challenging",seed:seed(game)){expected=beginner;break}
            player.restartMini()
        }
        let reply=try XCTUnwrap(expected,"No opening separates the profiles, so a replaced reply cannot be observed")
        session.state.settings.miniOpponentProfile="beginner";player.settingsChanged()
        for _ in 0..<75 where player.miniThinking{try await Task.sleep(for:.milliseconds(40))}
        XCTAssertFalse(player.miniThinking);XCTAssertEqual(player.miniGame?.history.count,2);XCTAssertEqual(player.miniGame?.snapshot.lastMove,reply)
        try await Task.sleep(for:.milliseconds(700));XCTAssertEqual(player.miniGame?.history.count,2)
        let next=try XCTUnwrap(MiniGameRules.moves(board:try XCTUnwrap(player.miniGame).board,kind:.pawnDuel,side:"w").first)
        player.click(next.from);player.click(next.to);session.state.settings.miniOpponentProfile="challenging";player.settingsChanged();player.restartMini()
        let seed=player.miniGame?.opponentSeed
        try await Task.sleep(for:.milliseconds(750));XCTAssertEqual(player.miniGame?.history.count,0);XCTAssertEqual(player.miniTurn,"w");XCTAssertEqual(player.miniGame?.opponentSeed,seed)
        player.shutdown()
    }
}
@MainActor final class MiniLanguageChangeTests:XCTestCase {
    func testLanguageChangeStillRepliesInAMiniGame()async throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        session.state.settings.pieceDuration=0;player.settingsChanged()  // settle the initial pack selection
        player.openLesson(index:3);player.startPawnDuel();player.click("g2");player.click("g4");XCTAssertTrue(player.miniThinking)
        player.pause();session.state.settings.lessonLanguage="fr";player.settingsChanged()  // as Settings ▸ Lessons does
        for _ in 0..<75 where player.miniGame?.history.count != 2{try await Task.sleep(for:.milliseconds(40))}
        XCTAssertEqual(player.miniGame?.history.count,2);XCTAssertEqual(player.miniTurn,"w")
        player.shutdown()
    }
}
