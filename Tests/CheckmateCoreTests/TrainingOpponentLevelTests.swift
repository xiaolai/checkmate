import CheckmateTestSupport
import Combine
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// The WI-026 release, emulated for WI-017's forward-compatibility tests, as `Release082` emulates 0.8.2. What it reads
/// and writes of the active attempt comes from the frozen decoder (`FrozenTrainingDecoder`,
/// `Tests/Fixtures/TrainingCompatibility/release-decoder.json`): it decodes the fields that file lists, which must call
/// the attempt readable, and keeps every other field (`opponent` among them) by path (`ApplicationState.merged`,
/// unchanged since WI-026), writing it back into whatever attempt then holds the slot. Its play is this build's with
/// the attempt's opponent configuration unread. The fields' values pass through as saved: the fixture states which
/// fields the release knows, not how it would re-encode a value, and these tests' values are ones it reads as they are.
enum Release026 {
    enum Action {case continueRun([TrainingAction]),replace(id:String)}
    /// Opens `state` in the WI-026 release, does `action` to its active attempt (each saved, as that release saves on
    /// resume and after every action) and saves.
    static func session(_ state:ApplicationState,_ action:Action)throws -> ApplicationState {
        func object(_ data:Data)throws -> [String:Any] {try XCTUnwrap(try JSONSerialization.jsonObject(with:data) as? [String:Any])}
        let decoder=try FrozenTrainingDecoder(),known=try XCTUnwrap(decoder.fields(of:"active"))
        var top=try object(JSONEncoder().encode(state)),training=try XCTUnwrap(top["training"] as? [String:Any]),saved=try XCTUnwrap(training["active"] as? [String:Any])
        XCTAssertEqual(decoder.verdict(saved,as:"active"),.readable,"premise: the WI-026 release resumes this attempt")
        var written=saved.filter{known.contains($0.key)}
        switch action {
        case .continueRun(let actions):
            written["actions"]=try XCTUnwrap(written["actions"] as? [Any])+(try actions.map{try JSONSerialization.jsonObject(with:JSONEncoder().encode($0))})
            written["revision"]=try XCTUnwrap(written["revision"] as? Int)+1+actions.count
        case .replace(let id):
            written=["id":id,"entry":try XCTUnwrap(written["entry"]),"scenario":try XCTUnwrap(written["scenario"]),"freshness":"new","revision":1,"startedAt":try XCTUnwrap(written["startedAt"]),"actions":[Any](),"recordedHelp":false,"retry":false]
            XCTAssertEqual(Set(written.keys),known,"a new attempt is written with every field the release knows")
        }
        XCTAssertEqual(decoder.verdict(written,as:"active"),.readable,"what the release writes it reads again")
        let nested=Dictionary(uniqueKeysWithValues:try saved.filter{written[$0.key]==nil}.map{(["training","active",$0.key],try JSONDecoder().decode(JSONValue.self,from:JSONSerialization.data(withJSONObject:$0.value,options:.fragmentsAllowed)))})
        training["active"]=written;top["training"]=training
        return try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:ApplicationState.merged(top,[:],nested:nested)))
    }
}

/// WI-017: a standard-rule training game plays at the level its attempt froze (plan D4), through the `OpponentStrategy`
/// seam, with every search node-limited; the frozen level survives preference changes, relaunch, and an older build's
/// continuing or replacing the attempt, and the record says which level played.
@MainActor final class TrainingOpponentLevelTests:XCTestCase {
    private static let flags=["CHECKMATE_TRAINING_ENABLED","CHECKMATE_TRAINING_B","CHECKMATE_POSITION_GAMES"]
    /// The mechanism needs a game with every level: the rook ending offers all three here, whatever calibration says.
    override func setUp(){Self.flags.forEach{setenv($0,"1",1)};MiniGameOffering.testPositionGames=["finish-the-game/krk":TrainingOpponentLevel.allCases]}
    override func tearDown(){Self.flags.forEach{unsetenv($0)};MiniGameOffering.testPositionGames=nil}
    /// A rook ending whose lone king has eight moves, so the beginner opponent has candidates to explore.
    private let open="8/8/8/3k4/8/8/8/K6R w - - 0 1"
    private func fixture(_ defender:ScriptedDefender,level:TrainingOpponentLevel?,fen:String?=nil,state:ApplicationState?=nil)throws -> (GameSession,LearningPlayer,TrainingController) {
        let (session,player,controller)=try TrainingEndgameTests.fixture([TrainingEndgameTests.ending(fen ?? open,variant:"krk")],defender:defender)
        if let state{session.state=state}
        if let level{session.state.settings.positionGameLevels=["finish-the-game":level.rawValue]}
        controller.games.fairness=session.fairness
        return (session,player,controller)
    }
    private func relaunched(_ state:ApplicationState)throws -> ApplicationState {try JSONDecoder().decode(ApplicationState.self,from:JSONEncoder().encode(state))}
    private func play(_ controller:TrainingController,_ uci:String)async {await PositionGameTests.play(controller,uci)}
    private func settle(_ condition:()->Bool,_ message:String)async throws {for _ in 0..<500 where !condition(){try await Task.sleep(nanoseconds:2_000_000)};XCTAssertTrue(condition(),message)}
    /// Scores for the beginner opponent: the root names one leading move, each constrained search its own candidate.
    private static func scored(_ request:ScriptedDefender.Request,_ rules:ChessRules)->EngineAnalysis {
        let legal=rules.moves().map(\.uci).sorted()
        if let candidate=request.searchMoves.first{return EngineAnalysis(bestMove:candidate,lines:[AnalysisLine(depth:8,multiPv:1,score:AnalysisScore(kind:"cp",value:520),pv:[candidate],san:[])])}
        return EngineAnalysis(bestMove:legal.first,lines:[AnalysisLine(depth:8,multiPv:1,score:AnalysisScore(kind:"cp",value:500),pv:[legal[0]],san:[])])
    }

    // MARK: The strategy seam and its node limits

    func testGentlesRootAndCandidateSearchesCarryTheNodeLimitAndTheirMoveWithinTheCap()async throws {
        let defender=ScriptedDefender();defender.analysis=Self.scored
        let (session,player,controller)=try fixture(defender,level:.gentle);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game",variant:"krk"))
        XCTAssertEqual(session.state.training?.active?.opponent?.strategy,.beginner,"frozen when the attempt started")
        await play(controller,"h1h2")
        let requests=defender.requests,nodes=TrainingOpponentPolicy.gentleSearchNodes
        XCTAssertEqual(requests.count,1+BeginnerPolicy.explorationCount,"the root and every candidate allowed")
        XCTAssertTrue(requests.allSatisfy{$0.limit == .nodes(nodes) && $0.profile == .skill(20) && $0.moves==["h1h2"]},"each search is node-limited: \(requests)")
        XCTAssertEqual(requests[0].searchMoves,[]);XCTAssertEqual(requests[0].multiPv,BeginnerPolicy.candidateCount)
        let candidates=requests.dropFirst().map(\.searchMoves)
        XCTAssertTrue(candidates.allSatisfy{$0.count==1},"each candidate search is constrained to its own move")
        let legal=try ChessRules(fen:open);try legal.move(uci:"h1h2")
        XCTAssertEqual(Set(candidates.map{$0[0]}).count,candidates.count);XCTAssertTrue(candidates.allSatisfy{c in legal.moves().contains{$0.uci==c[0]} && c[0] != "d5c4"},"distinct legal moves other than the leading one")
        XCTAssertLessThanOrEqual(requests.compactMap(\.nodes).reduce(0,+),TrainingOpponentPolicy.gentleDecisionNodes,"within the decision cap")
        XCTAssertEqual(controller.exercise?.line.count,2,"and it replied")
    }
    func testTheDecisionCapStopsFurtherCandidateSearches()async throws {
        let defender=ScriptedDefender();defender.analysis=Self.scored
        let rules=try ChessRules(fen:open);try rules.move(uci:"h1h2")
        _ = try await BeginnerOpponent.choose(rules:rules,engine:defender,seed:3,limit:.nodes(1000),decisionNodes:2000)
        XCTAssertEqual(defender.requests.count,2,"the root and one candidate: a third search would pass the cap");XCTAssertTrue(defender.requests.allSatisfy{$0.limit == .nodes(1000)})
    }
    func testSteadyAndStrongMakeOneNodeLimitedSearchAtTheirSkill()async throws {
        for (level,skill) in [(TrainingOpponentLevel.steady,3),(.strong,20)] {
            let defender=ScriptedDefender()
            let (_,player,controller)=try fixture(defender,level:level);defer{player.shutdown()}
            controller.begin(try controller.prepare(entry:"finish-the-game",variant:"krk"));await play(controller,"h1h2")
            XCTAssertEqual(defender.requests,[ScriptedDefender.Request(startFEN:open,moves:["h1h2"],profile:.skill(skill),limit:.nodes(TrainingOpponentPolicy.engineNodes),multiPv:1,searchMoves:[])],level.rawValue)
        }
    }
    func testWithPositionGamesOffNothingNewIsWrittenAndTodaysSearchPlays()async throws {
        unsetenv("CHECKMATE_POSITION_GAMES")
        let defender=ScriptedDefender()
        let (session,player,controller)=try fixture(defender,level:.gentle);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game",variant:"krk"));await play(controller,"h1h2")
        XCTAssertNil(session.state.training?.active?.opponent,"no opponent configuration is written")
        XCTAssertEqual(defender.requests.map(\.limit),[.movetime(TrainingEndgameController.budget)]);XCTAssertEqual(defender.requests.first?.profile,.skill(20))
        controller.setGameLevel(.steady);XCTAssertEqual(session.state.settings.positionGameLevels,["finish-the-game":"gentle"],"the picker is not offered, and its setting is not written")
        XCTAssertEqual(controller.gameLevels(try XCTUnwrap(controller.exercise)),[.strong])
        controller.begin(try controller.prepare(entry:"finish-the-game",variant:"krk"))
        XCTAssertNil(session.state.training?.attempts.last?.level,"the abandoned attempt records no level");XCTAssertNil(session.state.training?.attempts.last?.levelPolicy)
    }

    // MARK: Gentle's severe-mistake run

    func testASevereMistakeIsSavedAndAResumedAttemptKeepsTheRun()async throws {
        // Black to move: the leading reply keeps the score at 0, the second gives White 400 more, a severe mistake.
        let answer:(ScriptedDefender.Request,ChessRules)throws -> EngineAnalysis={request,rules in
            let legal=rules.moves().map(\.uci).sorted()
            guard request.searchMoves.isEmpty else{return EngineAnalysis()}
            return EngineAnalysis(bestMove:legal[0],lines:[AnalysisLine(depth:8,multiPv:1,score:AnalysisScore(kind:"cp",value:0),pv:[legal[0]],san:[]),AnalysisLine(depth:8,multiPv:2,score:AnalysisScore(kind:"cp",value:400),pv:[legal[1]],san:[])])
        }
        // The run continues from the attempt's seed and the ply, so a seed whose first choice is the mistake is found first.
        let probe=ScriptedDefender();probe.analysis=answer
        let position=try ChessRules(fen:open);try position.move(uci:"h1h2");let mistake=position.moves().map(\.uci).sorted()[1]
        var found:UInt64?
        for seed in UInt64(1)...400 where found==nil {if try await BeginnerOpponent.choose(rules:position,engine:probe,seed:seed &+ 2,limit:.nodes(1000)).bestMove==mistake{found=seed}}
        let seed=try XCTUnwrap(found,"fixture: some seed makes the mistake")
        let defender=ScriptedDefender();defender.analysis=answer
        let (session,player,controller)=try fixture(defender,level:.gentle);defer{player.shutdown()}
        controller.seed={seed}
        controller.begin(try controller.prepare(entry:"finish-the-game",variant:"krk"));await play(controller,"h1h2")
        XCTAssertEqual(controller.exercise?.line,["h1h2",mistake]);XCTAssertEqual(controller.games.lastDecision?.estimatedRegretCp,400)
        XCTAssertEqual(session.state.training?.active?.opponent?.severeStreak,1,"saved with the reply")
        // Relaunched, the attempt resumes its run: the next decision begins one severe mistake in.
        let (_,again,resumed)=try fixture(defender,level:nil,state:try relaunched(session.state));defer{again.shutdown()}
        resumed.begin(try resumed.prepareResume());XCTAssertEqual(resumed.exercise?.snapshot.opponent?.severeStreak,1)
        let learner=try XCTUnwrap(resumed.exercise?.current?.outcomes().first{$0.piece=="r"}?.uci)
        await play(resumed,learner);XCTAssertEqual(resumed.games.lastDecision?.priorSevereStreak,1)
    }

    // MARK: Cancellation and fairness during Gentle's searches

    func testCancellingBetweenCandidateSearchesMakesNoFurtherSearch()async throws {
        let defender=ScriptedDefender();defender.analysis=Self.scored;defender.holding=true
        let (_,player,controller)=try fixture(defender,level:.gentle);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game",variant:"krk"))
        controller.attempt(from:"h1",to:"h2",promotion:nil);try await settle({defender.requests.count==1},"the root search is asked")
        controller.undo()
        defender.release();try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertEqual(defender.requests.count,1,"no candidate search after the cancellation");XCTAssertEqual(controller.exercise?.line,[])
    }
    func testNetworkParticipationBeginningDuringASearchStopsFurtherSearches()async throws {
        let defender=ScriptedDefender();defender.analysis=Self.scored;defender.holding=true
        let (session,player,controller)=try fixture(defender,level:.gentle);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game",variant:"krk"))
        controller.attempt(from:"h1",to:"h2",promotion:nil);try await settle({defender.requests.count==1},"the root search is asked")
        session.fairness.participation.begin(.player);defer{session.fairness.participation.end()}
        defender.release();try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertEqual(defender.requests.count,1,"no further engine search once participating");XCTAssertEqual(controller.exercise?.line,["h1h2"],"and no reply lands")
    }

    // MARK: The frozen level

    func testAPreferenceChangeDuringAnAttemptKeepsItsFrozenOpponentAcrossSaveAndRelaunch()async throws {
        let defender=ScriptedDefender();defender.analysis=Self.scored
        let (session,player,controller)=try fixture(defender,level:.gentle);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game",variant:"krk"))
        let attempt=try XCTUnwrap(controller.exercise)
        XCTAssertEqual(controller.gameLevels(attempt),[.gentle,.steady,.strong]);XCTAssertFalse(controller.gameNewLevelOffered(attempt))
        // No move yet: choosing another level takes it now, in the same attempt.
        controller.setGameLevel(.steady);XCTAssertEqual(controller.exercise?.snapshot.opponent?.level,.steady);XCTAssertEqual(controller.exercise?.snapshot.id,attempt.snapshot.id)
        controller.setGameLevel(.gentle)
        await play(controller,"h1h2")
        // Only the setting changes, so the controller must announce it: the panel's picker and offer read it.
        var announced=0;let watch=controller.objectWillChange.sink{announced+=1}
        controller.setGameLevel(.strong);watch.cancel()
        XCTAssertGreaterThan(announced,0,"the panel is told the level changed")
        XCTAssertEqual(session.state.settings.positionGameLevels,["finish-the-game":"strong"]);XCTAssertEqual(controller.exercise?.snapshot.opponent?.level,.gentle,"the game in progress keeps its level")
        XCTAssertTrue(controller.gameNewLevelOffered(try XCTUnwrap(controller.exercise)))
        let before=defender.requests.count
        await play(controller,try XCTUnwrap(controller.exercise?.current?.outcomes().first{$0.piece=="r"}?.uci))
        XCTAssertTrue(defender.requests.dropFirst(before).allSatisfy{$0.limit == .nodes(TrainingOpponentPolicy.gentleSearchNodes)} && defender.requests.count-before>1,"still Gentle's searches")
        // Saved and relaunched with the new preference: still Gentle.
        let (_,again,resumed)=try fixture(defender,level:nil,state:try relaunched(session.state));defer{again.shutdown()}
        resumed.begin(try resumed.prepareResume())
        XCTAssertEqual(resumed.exercise?.snapshot.opponent?.level,.gentle);XCTAssertNil(resumed.exercise?.snapshot.opponent?.mixed,"a normal resume stays exact")
        let resumedAt=defender.requests.count
        await play(resumed,try XCTUnwrap(resumed.exercise?.current?.outcomes().first{$0.piece=="r"}?.uci))
        XCTAssertTrue(defender.requests.dropFirst(resumedAt).allSatisfy{$0.limit == .nodes(TrainingOpponentPolicy.gentleSearchNodes)})
        // A new game at the chosen level: the one in progress is recorded at its own level.
        resumed.startGameAtChosenLevel()
        XCTAssertEqual(resumed.exercise?.snapshot.opponent?.level,.strong);XCTAssertEqual(resumed.session.state.training?.attempts.last?.outcome,.abandoned)
        XCTAssertEqual(resumed.session.state.training?.attempts.last?.level,"gentle");XCTAssertEqual(resumed.session.state.training?.attempts.last?.levelPolicy,TrainingOpponentConfiguration.frozen(.gentle,attempt:"x",seed:1).policy)
    }

    /// The panel's new-game offer compares the level the game is actually bound to (`boundOpponent`), never a
    /// configuration another attempt left in the saved snapshot; the panel and the review name that same opponent.
    func testTheNewGameOfferIgnoresAnotherAttemptsSavedOpponent()async throws {
        let defender=ScriptedDefender();defender.analysis=Self.scored
        let (_,player,controller)=try fixture(defender,level:.gentle);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game",variant:"krk"))
        await play(controller,"h1h2")
        controller.setGameLevel(.strong)
        let own=try XCTUnwrap(controller.exercise)
        XCTAssertTrue(controller.gameNewLevelOffered(own),"the frozen level differs from the chosen one")
        var other=own;other.snapshot.opponent?.attempt="theirs"
        XCTAssertNil(other.snapshot.boundOpponent)
        XCTAssertFalse(controller.gameNewLevelOffered(other),"another attempt's configuration is not this game's level")
    }

    // MARK: An older build continuing or replacing the attempt (the frozen WI-026 decoder)

    func testAGentleAttemptAnOlderBuildContinuedKeepsItsLevelMarkedMixed()async throws {
        let defender=ScriptedDefender();defender.analysis=Self.scored
        let (session,player,controller)=try fixture(defender,level:.gentle);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game",variant:"krk"));await play(controller,"h1h2")
        let line=try XCTUnwrap(controller.exercise?.line),rules=try ChessRules(fen:open);for move in line{try rules.move(uci:move)}
        let learner=try XCTUnwrap(rules.moves().first{$0.piece=="r"});try rules.move(uci:learner.uci);let reply=try XCTUnwrap(rules.moves().map(\.uci).sorted().first)
        let downgraded=try Release026.session(session.state,.continueRun([.move(from:learner.from,to:learner.to,promotion:nil),.reply(reply)]))
        XCTAssertEqual(downgraded.training?.active?.opponent?.attempt,downgraded.training?.active?.id,"premise: the configuration was written back by path")
        let (upgraded,again,resumed)=try fixture(defender,level:nil,state:downgraded);defer{again.shutdown()}
        resumed.begin(try resumed.prepareResume())
        XCTAssertEqual(resumed.exercise?.line.count,4);XCTAssertEqual(resumed.exercise?.snapshot.opponent?.level,.gentle,"it keeps playing at its level")
        XCTAssertEqual(resumed.exercise?.snapshot.opponent?.mixed,true)
        let before=defender.requests.count
        await play(resumed,try XCTUnwrap(resumed.exercise?.current?.outcomes().first{$0.piece=="r"}?.uci))
        XCTAssertTrue(defender.requests.dropFirst(before).allSatisfy{$0.limit == .nodes(TrainingOpponentPolicy.gentleSearchNodes)})
        resumed.begin(try resumed.prepare(entry:"finish-the-game",variant:"krk"))
        let record=try XCTUnwrap(upgraded.state.training?.attempts.last)
        XCTAssertEqual(record.level,"gentle");XCTAssertEqual(record.levelPolicy,"mixed","recorded as such on completion");XCTAssertTrue(record.levelLabel.contains("mixed"))
    }
    func testAGentleConfigurationAnOlderBuildCarriedIntoAReplacementAttemptIsIgnored()async throws {
        let defender=ScriptedDefender();defender.analysis=Self.scored
        let (session,player,controller)=try fixture(defender,level:.gentle);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game",variant:"krk"));await play(controller,"h1h2")
        let downgraded=try Release026.session(session.state,.replace(id:"started-by-the-older-build"))
        XCTAssertEqual(downgraded.training?.active?.opponent?.level,.gentle,"premise: the old configuration was written into the new attempt by path")
        XCTAssertNil(downgraded.training?.active?.boundOpponent,"it names another attempt")
        let (upgraded,again,resumed)=try fixture(defender,level:.gentle,state:downgraded);defer{again.shutdown()}
        resumed.begin(try resumed.prepareResume())
        XCTAssertEqual(resumed.exercise?.snapshot.id,"started-by-the-older-build");XCTAssertEqual(resumed.exercise?.snapshot.opponent,.legacy(attempt:"started-by-the-older-build",revision:2),"begun without a level: legacy")
        let before=defender.requests.count
        await play(resumed,"h1h2")
        XCTAssertEqual(defender.requests.dropFirst(before).map(\.limit),[.movetime(TrainingEndgameController.budget)],"today's search");XCTAssertEqual(defender.requests.last?.profile,.skill(20))
        resumed.begin(try resumed.prepare(entry:"finish-the-game",variant:"krk"))
        XCTAssertEqual(upgraded.state.training?.attempts.last?.levelLabel,"Legacy strength")
    }
    func testAnAttemptSavedBeforeLevelsFinishesWithTodaysSearchUnderPolicyLegacy()async throws {
        unsetenv("CHECKMATE_POSITION_GAMES")
        let defender=ScriptedDefender(choose:ScriptedDefender.capturing("r")),start="8/8/8/8/2k5/8/8/K6R w - - 0 1"
        let (session,player,controller)=try fixture(defender,level:nil,fen:start);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"finish-the-game",variant:"krk"));await play(controller,"h1h2")
        XCTAssertEqual(session.state.training?.active?.actions.last,.reply("c4b3"),"a committed reply");XCTAssertNil(session.state.training?.active?.opponent)
        setenv("CHECKMATE_POSITION_GAMES","1",1)
        let (upgraded,again,resumed)=try fixture(defender,level:.gentle,fen:start,state:try relaunched(session.state));defer{again.shutdown()}
        resumed.begin(try resumed.prepareResume())
        XCTAssertEqual(resumed.exercise?.snapshot.opponent?.strategy,.legacy,"no node-limit policy is attributed to searches it did not run")
        await play(resumed,"h2c2")
        XCTAssertEqual(resumed.exercise?.line,["h1h2","c4b3","h2c2","b3c2"]);XCTAssertEqual(resumed.exercise?.status,.incorrect)
        XCTAssertEqual(defender.requests.map(\.limit),[.movetime(TrainingEndgameController.budget),.movetime(TrainingEndgameController.budget)],"today's search to the end")
        let record=try XCTUnwrap(upgraded.state.training?.attempts.last)
        XCTAssertEqual(record.level,"legacy");XCTAssertEqual(record.levelPolicy,"legacy");XCTAssertEqual(record.levelLabel,"Legacy strength")
    }
    func testAnOlderBuildRewritingFinishedAttemptsLosesTheirLevelShownAsNotRecorded()throws {
        struct Attempt026:Codable {let id:String,entry:String,scenarioID:String,cluster:String,tier:Int,learner:String,startedAt:Date,finishedAt:Date,outcome:TrainingOutcome,firstTryNoRecordedHelp:Bool,recordedHelp:Bool,retry:Bool,freshness:String}
        let attempt=TrainingAttempt(id:"a",entry:"finish-the-game",scenarioID:"s",cluster:"c",tier:1,learner:"w",startedAt:Date(timeIntervalSince1970:0),finishedAt:Date(timeIntervalSince1970:60),outcome:.correct,firstTryNoRecordedHelp:true,recordedHelp:false,retry:false,freshness:"new",opponent:.frozen(.strong,attempt:"a",seed:1))
        XCTAssertEqual(attempt.levelLabel,"Strong")
        let rewritten=try JSONDecoder().decode(TrainingAttempt.self,from:JSONEncoder().encode(try JSONDecoder().decode(Attempt026.self,from:JSONEncoder().encode(attempt))))
        XCTAssertNil(rewritten.level);XCTAssertEqual(rewritten.levelLabel,"Level not recorded")
    }
    /// A guided game with no level keeps the strength it had before levels: Stockfish at skill 3 for 300 ms (an ending's
    /// is skill 20), whether it began before position games or was saved before levels.
    func testALegacyGuidedGameSearchesAtSkill3For300Milliseconds()async throws {
        XCTAssertEqual(OpponentStrategy.legacy(.guidedGame),.engine(.skill(3),limit:.movetime(300)))
        XCTAssertEqual(OpponentStrategy(.legacy(attempt:"a",revision:0),check:.guidedGame),.engine(.skill(3),limit:.movetime(300)))
        XCTAssertEqual(OpponentStrategy(.legacy(attempt:"a",revision:0),check:.ending),.engine(.skill(20),limit:.movetime(300)))
        unsetenv("CHECKMATE_POSITION_GAMES")
        let scenario=TrainingScenario(id:"guided-legacy",entry:"guided-games",variant:"short-start",tier:1,cluster:"guided-legacy",learner:"b",prompt:"Play.",explanation:"Habits.",hints:["Develop."],fen:"6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 7",prelude:["h2h3"],review:TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion),check:.guidedGame,workflow:"guided-game")
        let defender=ScriptedDefender(choose:{_ in "g1h2"})
        let (session,player,controller)=try TrainingEndgameTests.fixture([scenario],defender:defender);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"guided-games"));await play(controller,"h7h6")
        XCTAssertNil(session.state.training?.active?.opponent,"no level was frozen");XCTAssertEqual(controller.exercise?.line,["h7h6","g1h2"])
        XCTAssertEqual(defender.requests.map(\.profile),[.skill(3)]);XCTAssertEqual(defender.requests.map(\.limit),[.movetime(300)])
    }
    func testTheNoteNamesTheFrozenLevel(){
        XCTAssertEqual(TrainingEndgameController.note(for:.ending),TrainingEndgameController.defenderNote,"without a level, today's note")
        XCTAssertTrue(TrainingEndgameController.note(for:.ending,opponent:.frozen(.gentle,attempt:"a",seed:1)).hasPrefix("Your opponent is Gentle"))
        XCTAssertTrue(TrainingEndgameController.note(for:.guidedGame,opponent:.frozen(.steady,attempt:"a",seed:1)).hasSuffix("not wrong answers."))
        XCTAssertEqual(TrainingEndgameController.note(for:.ending,opponent:.legacy(attempt:"a",revision:0)),TrainingEndgameController.defenderNote)
    }
}
