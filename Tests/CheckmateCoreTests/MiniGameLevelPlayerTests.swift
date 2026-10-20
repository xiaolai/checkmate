import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateApplication

/// The 0.8.2 release, emulated for WI-015's forward-compatibility tests. No 0.8.2 binary is available to a test, so
/// the behaviour these tests depend on is reproduced from its sources:
/// - its mini-game and completion-event types, copied below as 0.8.2 declared them (without `level`, `levelPolicy`
///   and `levelExact`), so decoding drops this build's new fields exactly as 0.8.2's synthesized decoders do;
/// - its save: a mini-game record's unknown fields are kept by path and written back into the record if it still
///   exists (`ApplicationState.merged`, unchanged since 0.8.2), unknown settings are kept, and completion events are
///   re-encoded as its own type, losing what it does not know;
/// - its player: a restart is a new `MiniGameState` with a new seed, and a reply searches at the global
///   `miniOpponentProfile`, the only preference 0.8.2 has. Its rules and opponent search are this build's, which
///   WI-015 does not change.
enum Release082 {
    struct Mini:Codable {var kind:MiniGameKind,computer:Bool,snapshot:MiniGameSnapshot,history:[MiniGameSnapshot];var opponentSeed:String?}
    struct Event:Codable {let id:String,kind:String,run:String,winner:String?,drawReason:String?,computer:Bool,origin:String,at:Date}
    enum Action {case open,restart,continueRun(MiniGameMove)}
    /// Opens the saved state at `file` in 0.8.2 with its global profile set to `profile`, does `action` to the board
    /// of `kind`, and saves.
    static func session(_ file:URL,kind:MiniGameKind,profile:String,_ action:Action)throws {
        func object(_ data:Data)throws -> [String:Any] {try XCTUnwrap(try JSONSerialization.jsonObject(with:data) as? [String:Any])}
        var top=try object(Data(contentsOf:file)),settings=try XCTUnwrap(top["settings"] as? [String:Any]);settings["miniOpponentProfile"]=profile;top["settings"]=settings
        var games=try XCTUnwrap(top["miniGames"] as? [String:Any]),saved=try XCTUnwrap(games[kind.rawValue] as? [String:Any])
        var mini=try JSONDecoder().decode(Mini.self,from:JSONSerialization.data(withJSONObject:saved))
        func board(_ mini:Mini)throws -> MiniGameState {try JSONDecoder().decode(MiniGameState.self,from:JSONEncoder().encode(mini))}
        func back(_ game:MiniGameState)throws -> Mini {try JSONDecoder().decode(Mini.self,from:JSONEncoder().encode(game))}
        switch action {
        case .open:break
        case .restart:mini=try back(MiniGameState(kind:kind,computer:mini.computer))
        case .continueRun(let move):
            var game=try board(mini);XCTAssertTrue(game.play(move),"fixture: the learner's move is legal")
            let reply=try XCTUnwrap(MiniGameOpponent.choose(in:game,profile:profile,seed:(UInt64(game.opponentSeed ?? "1",radix:16) ?? 1) &+ UInt64(game.history.count+1),timeLimited:false))
            XCTAssertTrue(game.play(reply));mini=try back(game)
        }
        let written=try object(JSONEncoder().encode(mini));games[kind.rawValue]=written;top["miniGames"]=games
        let nested=Dictionary(uniqueKeysWithValues:try saved.filter{written[$0.key]==nil}.map{(["miniGames",kind.rawValue,$0.key],try JSONDecoder().decode(JSONValue.self,from:JSONSerialization.data(withJSONObject:$0.value,options:.fragmentsAllowed)))})
        if var training=top["training"] as? [String:Any],let events=training["events"] as? [Any] {
            training["events"]=try events.map{try object(JSONEncoder().encode(try JSONDecoder().decode(Event.self,from:JSONSerialization.data(withJSONObject:$0))))};top["training"]=training
        }
        try JSONSerialization.data(withJSONObject:ApplicationState.merged(top,[:],nested:nested),options:[.sortedKeys]).write(to:file)
    }
}

/// WI-015: each run of a simplified mini-game plays at the level frozen when it started, whatever the settings do
/// afterwards, and a level an older build could have invalidated is never trusted.
@MainActor final class MiniGameLevelPlayerTests:XCTestCase {
    private var directory:URL!
    /// The mechanism is tested with every level offered, whatever calibration withdrew; `testAWithdrawnLevel…` withdraws one.
    static let allLevels=Dictionary(uniqueKeysWithValues:MiniGameKind.allCases.filter{!$0.solo}.map{($0,MiniOpponentPolicy.profiles)})
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);MiniGameOffering.testTable=Self.allLevels}
    override func tearDown(){try? FileManager.default.removeItem(at:directory);MiniGameOffering.testTable=nil}
    private func fixture(_ state:ApplicationState=ApplicationState())throws -> (GameSession,LearningPlayer) {
        let session=try GameSession(engine:nil,state:state),player=try LearningPlayer(session:session)
        session.state.settings.pieceDuration=0;player.settingsChanged();return (session,player)
    }
    private func reply(_ player:LearningPlayer)async throws {
        for _ in 0..<150 where player.miniThinking{try await Task.sleep(for:.milliseconds(20))}
        XCTAssertFalse(player.miniThinking,"the computer did not reply");XCTAssertEqual(player.miniTurn,"w")
    }
    private func move(_ player:LearningPlayer,_ from:String,_ to:String)async throws {player.click(from);player.click(to);try await reply(player)}
    /// White to play a6-a7 and then a7-a8, which Black's h-pawn cannot stop: a game against the computer that finishes.
    private func nearlyWon()->MiniGameState {var game=MiniGameState(kind:.pawnDuel);game.snapshot.board=["a6":"wp","c2":"wp","h7":"bp"];return game}

    func testNewGameAndRestartFreezeThePreferenceIntoTheRun()async throws {
        let (session,player)=try fixture();defer{player.shutdown()}
        session.state.settings.miniOpponentProfiles=["pawn-duel":"beginner"];player.startMini(.pawnDuel,fromLibrary:true)
        XCTAssertEqual(player.miniLevel,"beginner");XCTAssertEqual(session.state.miniGames?["pawn-duel"]?.runLevel?.profile,"beginner","saved with the board")
        try await move(player,"e2","e4")
        player.setMiniLevel("challenging")
        XCTAssertEqual(player.miniLevel,"beginner","the game in progress keeps its level");XCTAssertEqual(player.miniGame?.history.count,2);XCTAssertTrue(player.miniNewLevelOffered)
        XCTAssertEqual(session.state.settings.miniOpponentProfiles,["pawn-duel":"challenging"]);XCTAssertEqual(session.state.settings.miniOpponentProfile,"standard","the global preference is untouched")
        player.restartMini();XCTAssertEqual(player.miniLevel,"challenging","a restart freezes the preference");XCTAssertFalse(player.miniNewLevelOffered)
        // With no move played, choosing a level starts the new game at it straight away: nothing is lost.
        let seed=player.miniGame?.opponentSeed;player.setMiniLevel("beginner")
        XCTAssertEqual(player.miniLevel,"beginner");XCTAssertNotEqual(player.miniGame?.opponentSeed,seed,"a new run");XCTAssertFalse(player.miniNewLevelOffered)
        player.setMiniLevel("gentle");XCTAssertEqual(session.state.settings.miniOpponentProfiles["pawn-duel"],"beginner","a level the game does not offer is refused")
        // A finished game offers Play again instead, which also freezes the preference.
        let (other,finisher)=try fixture({var state=ApplicationState();state.miniGames=["pawn-duel":nearlyWon()];return state}());defer{finisher.shutdown()}
        finisher.startMini(.pawnDuel,fromLibrary:true);try await move(finisher,"a6","a7");finisher.click("a7");finisher.click("a8");XCTAssertTrue(finisher.miniGame?.isFinished ?? false)
        finisher.setMiniLevel("challenging");XCTAssertFalse(finisher.miniNewLevelOffered);finisher.restartMini();XCTAssertEqual(finisher.miniLevel,"challenging")
        XCTAssertEqual(other.state.training?.events.first?.level,"standard","the finished run was recorded at its own level")
    }
    func testSwitchingGamesUsesEachGamesPreferenceAndResumingKeepsTheRunsLevel()throws {
        let (session,player)=try fixture();defer{player.shutdown()}
        session.state.settings.miniOpponentProfiles=["pawn-duel":"beginner","rook-sweep":"challenging"]
        player.startMini(.pawnDuel,fromLibrary:true);XCTAssertEqual(player.miniLevel,"beginner")
        player.startMini(.rookSweep,fromLibrary:true);XCTAssertEqual(player.miniLevel,"challenging")
        player.startMini(.bishopSweep,fromLibrary:true);XCTAssertEqual(player.miniLevel,"standard","the global preference")
        session.state.settings.miniOpponentProfiles["pawn-duel"]="challenging";player.startMini(.pawnDuel,fromLibrary:true)
        XCTAssertEqual(player.miniLevel,"beginner","resuming keeps the run's level");XCTAssertEqual(player.miniGame?.runLevel?.exact,true)
        player.startMini(.knightCorners,fromLibrary:true);XCTAssertNil(player.miniLevel,"a solo game has no opponent level");XCTAssertFalse(player.miniNewLevelOffered)
    }
    /// WI-016 (plan D4): a run frozen at a level calibration later withdraws finishes at that level, labelled, and is
    /// recorded at it; new runs take the fallback. Also before its first move: nothing forces the run onto another level.
    func testAWithdrawnLevelFinishesItsRunLabelledAndNewRunsUseTheFallback()async throws {
        var state=ApplicationState();state.miniGames=["pawn-duel":nearlyWon()];state.settings.miniOpponentProfiles=["pawn-duel":"challenging","rook-sweep":"challenging"]
        let (session,player)=try fixture(state);defer{player.shutdown()}
        player.startMini(.pawnDuel,fromLibrary:true);player.startMini(.rookSweep,fromLibrary:true)
        XCTAssertEqual(player.miniLevel,"challenging");XCTAssertFalse(player.miniLevelWithdrawn);XCTAssertFalse(player.miniNewLevelOffered)
        MiniGameOffering.testTable=[.pawnDuel:["standard"],.rookSweep:["standard"]]  // calibration withdraws Strong
        player.startMini(.rookSweep,fromLibrary:true)
        XCTAssertEqual(player.miniLevel,"challenging","the run keeps its level");XCTAssertTrue(player.miniLevelWithdrawn,"labelled")
        XCTAssertEqual(player.miniPreferredLevel,"standard");XCTAssertTrue(player.miniNewLevelOffered,"a new game at the fallback is offered before any move")
        player.startMini(.pawnDuel,fromLibrary:true);XCTAssertEqual(player.miniLevel,"challenging");XCTAssertTrue(player.miniLevelWithdrawn)
        try await move(player,"a6","a7");XCTAssertEqual(player.miniGame?.runLevel?.profile,"challenging","the reply was searched in the run");XCTAssertEqual(player.miniProfile,"challenging","the reply searched at the withdrawn level, not the fallback")
        player.click("a7");player.click("a8");XCTAssertTrue(player.miniGame?.isFinished ?? false);XCTAssertFalse(player.miniNewLevelOffered,"a finished game offers Play again")
        let event=try XCTUnwrap(session.state.training?.events.last);XCTAssertEqual(event.level,"challenging");XCTAssertEqual(event.levelExact,true)
        player.restartMini();XCTAssertEqual(player.miniLevel,"standard","the new run plays the fallback");XCTAssertFalse(player.miniLevelWithdrawn)
        player.setMiniLevel("challenging");XCTAssertEqual(player.miniLevel,"standard","a withdrawn level cannot be chosen")
    }
    func testVolumeOrLanguageChangesLeaveAPendingReplyAlone()async throws {
        let (session,player)=try fixture();defer{player.shutdown()}
        player.startMini(.pawnDuel,fromLibrary:true);player.click("e2");player.click("e4");XCTAssertTrue(player.miniThinking);let requests=player.miniReplyRequests
        session.state.settings.volume=0.3;player.settingsChanged();session.state.settings.voiceVolume=0.2;player.settingsChanged();session.state.settings.lessonLanguage="fr";player.settingsChanged()
        XCTAssertTrue(player.miniThinking);XCTAssertEqual(player.miniReplyRequests,requests,"the pending reply was replaced")
        try await reply(player);XCTAssertEqual(player.miniGame?.history.count,2);XCTAssertEqual(player.miniReplyRequests,requests)
    }
    func testAStoredLevelOfAnotherRunIsIgnored()throws {
        var game=MiniGameState(kind:.pawnDuel);_ = game.play(MiniGameMove(from:"e2",to:"e4"));_ = game.play(MiniGameMove(from:"e7",to:"e5"))
        game.level=MiniGameLevel(profile:"challenging",run:"0123456789abcdef",witness:game.witness)
        var state=ApplicationState();state.miniGames=["pawn-duel":game];state.settings.miniOpponentProfile="beginner"
        let (session,player)=try fixture(state);defer{player.shutdown()}
        player.startMini(.pawnDuel,fromLibrary:true)
        XCTAssertEqual(player.miniLevel,"beginner","not the unverified level");XCTAssertEqual(player.miniGame?.runLevel?.run,game.opponentSeed)
        XCTAssertEqual(player.miniGame?.runLevel?.exact,false,"its earlier moves were played at an unknown level");XCTAssertEqual(session.state.miniGames?["pawn-duel"]?.runLevel,player.miniGame?.runLevel)
    }
    /// (a) 0.8.2 restarts the game under another profile and writes the old level back; the new run does not inherit it.
    func testARestartInTheOlderBuildDoesNotInheritTheOldLevel()async throws {
        let store=StateStore(directory:directory)
        do{
            var state=ApplicationState();state.settings.miniOpponentProfile="challenging";let (session,player)=try fixture(state);defer{player.shutdown()}
            player.startMini(.pawnDuel,fromLibrary:true);try await move(player,"e2","e4");XCTAssertEqual(player.miniLevel,"challenging");try store.save(session.state)
        }
        try Release082.session(store.url,kind:.pawnDuel,profile:"beginner",.restart)
        let downgraded=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:store.url)) as? [String:Any]),game=try XCTUnwrap((downgraded["miniGames"] as? [String:Any])?["pawn-duel"] as? [String:Any])
        XCTAssertEqual((game["level"] as? [String:Any])?["profile"] as? String,"challenging","premise: 0.8.2 wrote the old level back into the restarted game")
        XCTAssertNotEqual((game["level"] as? [String:Any])?["run"] as? String,game["opponentSeed"] as? String)
        let (session,player)=try fixture(try store.load());defer{player.shutdown()}
        player.startMini(.pawnDuel,fromLibrary:true)
        XCTAssertEqual(player.miniLevel,"beginner","the new run takes today's preference");XCTAssertEqual(player.miniGame?.runLevel?.run,game["opponentSeed"] as? String);XCTAssertEqual(player.miniGame?.runLevel?.exact,true)
        try store.save(session.state);XCTAssertEqual(try store.load().miniGames?["pawn-duel"]?.runLevel?.profile,"beginner")
    }
    /// (b) 0.8.2 continues the same run after the global profile changed and the computer replied: the stale witness
    /// marks the run's level inexact; the run keeps it, and its completion says so.
    func testContinuingTheRunInTheOlderBuildMarksItsLevelInexact()async throws {
        let store=StateStore(directory:directory)
        do{
            var state=ApplicationState();state.miniGames=["pawn-duel":nearlyWon()];state.settings.miniOpponentProfiles=["pawn-duel":"challenging"];let (session,player)=try fixture(state);defer{player.shutdown()}
            player.startMini(.pawnDuel,fromLibrary:true);XCTAssertEqual(player.miniGame?.runLevel?.exact,true);try store.save(session.state)
        }
        try Release082.session(store.url,kind:.pawnDuel,profile:"beginner",.continueRun(MiniGameMove(from:"c2",to:"c3")))
        let (session,player)=try fixture(try store.load());defer{player.shutdown()}
        let resumed=try XCTUnwrap(session.state.miniGames?["pawn-duel"]);XCTAssertEqual(resumed.history.count,2,"premise: 0.8.2 moved the board");XCTAssertNotNil(resumed.runLevel,"premise: with the old level kept")
        XCTAssertNotEqual(resumed.runLevel?.witness,resumed.witness,"premise: and its witness stale")
        player.startMini(.pawnDuel,fromLibrary:true)
        XCTAssertEqual(player.miniLevel,"challenging","the run keeps its level");XCTAssertEqual(player.miniGame?.runLevel?.exact,false)
        try await move(player,"a6","a7");player.click("a7");player.click("a8");XCTAssertTrue(player.miniGame?.isFinished ?? false)
        let event=try XCTUnwrap(session.state.training?.events.last);XCTAssertEqual(event.level,"challenging");XCTAssertEqual(event.levelExact,false,"level not exact");XCTAssertEqual(event.levelPolicy,"mini-search-v2")
    }
    /// (c) Control: a normal resume in this build stays exact, after a preference change too; a downgrade-and-save then
    /// loses the event's level, which is shown as not recorded.
    func testANormalResumeStaysExact()async throws {
        let store=StateStore(directory:directory)
        do{
            var state=ApplicationState();state.miniGames=["pawn-duel":nearlyWon()];state.settings.miniOpponentProfile="challenging";let (session,player)=try fixture(state);defer{player.shutdown()}
            player.startMini(.pawnDuel,fromLibrary:true);try await move(player,"c2","c3");try store.save(session.state)
        }
        var loaded=try store.load();loaded.settings.miniOpponentProfile="beginner";let (session,player)=try fixture(loaded);defer{player.shutdown()}
        player.startMini(.pawnDuel,fromLibrary:true);XCTAssertEqual(player.miniLevel,"challenging");XCTAssertEqual(player.miniGame?.runLevel?.exact,true)
        try await move(player,"a6","a7");player.click("a7");player.click("a8")
        let event=try XCTUnwrap(session.state.training?.events.last);XCTAssertEqual(event.level,"challenging");XCTAssertEqual(event.levelExact,true)
        try store.save(session.state);try Release082.session(store.url,kind:.pawnDuel,profile:"beginner",.open)
        let downgraded=try XCTUnwrap(try store.load().training?.events.last);XCTAssertEqual(downgraded.id,event.id);XCTAssertTrue(downgraded.computer)
        XCTAssertNil(downgraded.level,"level not recorded");XCTAssertNil(downgraded.levelExact);XCTAssertNil(downgraded.levelPolicy)
    }
}
