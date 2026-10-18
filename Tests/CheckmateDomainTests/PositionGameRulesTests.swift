import XCTest
@testable import CheckmateDomain

/// WI-017, the pure parts: D3's closed outcome matrix and its tracked pawn, for both learner colours; the frozen
/// opponent configuration and its saved shape; the per-entry level preference and offering (plan D4).
final class PositionGameRulesTests:XCTestCase {
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B");unsetenv("CHECKMATE_POSITION_GAMES")}
    private func positionGames(_ on:Bool){
        for name in ["CHECKMATE_TRAINING_ENABLED","CHECKMATE_TRAINING_B","CHECKMATE_POSITION_GAMES"]{if on{setenv(name,"1",1)}else{unsetenv(name)}}
    }
    private func move(_ uci:String,color:String,captured:String?=nil,promotion:String?=nil,flags:String="n")->MoveOutcome {
        MoveOutcome(from:String(uci.prefix(2)),to:String(uci.dropFirst(2).prefix(2)),piece:"p",color:color,san:uci,flags:flags,after:"",captured:captured,promotion:promotion,check:false,checkmate:false,stalemate:false)
    }
    private func judge(_ goal:TrainingGoal.Kind = .checkmate,keep:[String]=[],learner:String="w",mover:String,mate:Bool=false,stalemate:Bool=false,draw:String?=nil,board:Position=[:],pawn:PositionGamePawn?=nil)->PositionGameRow? {
        PositionGameReferee.judge(goal:goal,keep:keep,learner:learner,mover:mover,checkmate:mate,stalemate:stalemate,automaticDraw:draw,board:board,pawn:pawn)
    }

    // MARK: D3, row by row and in precedence order, for either colour

    func testTheMatrixRowsInPrecedenceOrderForBothColours(){
        for learner in ["w","b"] {
            let other=learner=="w" ? "b":"w",both:[TrainingGoal.Kind]=[.checkmate,.promoteAndHold]
            for goal in both {
                XCTAssertEqual(judge(goal,learner:learner,mover:learner,mate:true,draw:"x"),.learnerGaveMate,"mate first, \(learner) \(goal)")
                XCTAssertEqual(judge(goal,learner:learner,mover:other,mate:true),.learnerMated)
                XCTAssertEqual(judge(goal,learner:learner,mover:learner,stalemate:true,draw:"x"),.stalemate,"stalemate before an automatic draw")
                XCTAssertEqual(judge(goal,learner:learner,mover:other,stalemate:true),.stalemate,"either side stalemated")
                XCTAssertEqual(judge(goal,keep:["q"],learner:learner,mover:other,draw:"neither side has enough material to checkmate",board:[:]),.automaticDraw,"an automatic draw before a lost kept piece")
                XCTAssertEqual(judge(goal,keep:["r"],learner:learner,mover:other,board:[ "a1":learner+"k","h8":other+"k","d4":learner+"q"]),.keptPieceLost)
                XCTAssertNil(judge(goal,keep:["r"],learner:learner,mover:other,board:["a1":learner+"k","h8":other+"k","d4":learner+"r"]),"the game goes on")
            }
            // The tracked pawn decides only a promoteAndHold game, and after the kept pieces.
            XCTAssertEqual(judge(.promoteAndHold,keep:["r"],learner:learner,mover:other,board:["a1":learner+"k"],pawn:.pawnCaptured),.keptPieceLost)
            XCTAssertEqual(judge(.promoteAndHold,learner:learner,mover:other,pawn:.pawnCaptured),.pawnCaptured)
            XCTAssertEqual(judge(.promoteAndHold,learner:learner,mover:other,pawn:.promotedCaptured),.promotedPieceCaptured)
            XCTAssertNil(judge(.promoteAndHold,learner:learner,mover:learner,pawn:.promoted("e8")),"just promoted: the opponent has not replied")
            XCTAssertEqual(judge(.promoteAndHold,learner:learner,mover:other,pawn:.promoted("e8")),.promotedPieceHeld,"the reply left it on the board")
            XCTAssertNil(judge(.promoteAndHold,learner:learner,mover:other,pawn:.pawn("e5")))
            XCTAssertNil(judge(.checkmate,learner:learner,mover:other,pawn:.promoted("e8")),"a checkmate goal ignores the pawn")
        }
        XCTAssertEqual(PositionGameRow.allCases.filter(\.success),[.learnerGaveMate,.promotedPieceHeld])
    }
    func testTheMessagesSayWhatHappened(){
        XCTAssertEqual(PositionGameReferee.message(.claimedDraw,mover:"w",learner:"w",explanation:"",reason:"threefold repetition"),"Draw claimed by threefold repetition. That is a draw, so this one is not solved.")
        XCTAssertTrue(PositionGameReferee.message(.keptPieceLost,mover:"b",learner:"w",explanation:"",keep:["b","r"],board:["e1":"wk","c1":"wb"]).contains("last rook"))
        XCTAssertTrue(PositionGameReferee.message(.stalemate,mover:"w",learner:"w",explanation:"").contains("your opponent has no legal move"))
        XCTAssertTrue(PositionGameReferee.message(.stalemate,mover:"b",learner:"w",explanation:"").contains("you have no legal move"))
        XCTAssertEqual(PositionGameReferee.message(.learnerGaveMate,mover:"b",learner:"b",explanation:"Well done."),"Checkmate! Well done.")
    }

    // MARK: The tracked pawn

    func testTheTrackedPawnIsFollowedSquareBySquare(){
        for (learner,other,start,step,promote) in [("w","b","e2","e2e4","e7e8"),("b","w","d7","d7d5","d2d1")] {
            var pawn=PositionGamePawn.pawn(start)
            pawn=pawn.after(move(step,color:learner),learner:learner);XCTAssertEqual(pawn,.pawn(String(step.suffix(2))))
            XCTAssertEqual(pawn.after(move("a1a2",color:learner),learner:learner),pawn,"another learner move leaves it")
            XCTAssertEqual(pawn.after(move("h1h2",color:other),learner:learner),pawn,"a quiet opponent move leaves it")
            XCTAssertEqual(pawn.after(move("a1"+String(step.suffix(2)),color:other,captured:"p"),learner:learner),.pawnCaptured)
            for piece in ["q","r","b","n"] {
                let promoted=PositionGamePawn.pawn(String(promote.prefix(2))).after(move(promote,color:learner,promotion:piece),learner:learner)
                XCTAssertEqual(promoted,.promoted(String(promote.suffix(2))),"any promotion piece counts: \(piece)")
                XCTAssertEqual(promoted.after(move("a1"+String(promote.suffix(2)),color:other,captured:piece),learner:learner),.promotedCaptured)
                XCTAssertEqual(promoted.after(move(String(promote.suffix(2))+"a1",color:learner),learner:learner),.promoted("a1"),"the new piece is followed too")
            }
        }
        // En passant takes the pawn beside the capturing pawn's destination.
        XCTAssertEqual(PositionGamePawn.pawn("e4").after(move("d4e3",color:"b",captured:"p",flags:"e"),learner:"w"),.pawnCaptured)
        XCTAssertEqual(PositionGamePawn.pawn("e5").after(move("d5e6",color:"w",captured:"p",flags:"e"),learner:"b"),.pawnCaptured)
        XCTAssertEqual(PositionGamePawn.pawn("c4").after(move("d4e3",color:"b",captured:"p",flags:"e"),learner:"w"),.pawn("c4"),"another pawn taken en passant")
        XCTAssertEqual(PositionGamePawn.pawnCaptured.after(move("a1a2",color:"w"),learner:"w"),.pawnCaptured,"captured stays captured")
    }

    // MARK: The frozen opponent (D4)

    func testLevelsFreezeANodeLimitedStrategyAndAreNamedNeverAsElo(){
        XCTAssertEqual(TrainingOpponentLevel.allCases.map(\.title),["Gentle","Steady","Strong"])
        let gentle=TrainingOpponentConfiguration.frozen(.gentle,attempt:"a",seed:0x9a),steady=TrainingOpponentConfiguration.frozen(.steady,attempt:"a",seed:1),strong=TrainingOpponentConfiguration.frozen(.strong,attempt:"a",seed:1)
        XCTAssertEqual(gentle.strategy,.beginner);XCTAssertEqual(gentle.limit,.nodes(TrainingOpponentPolicy.gentleSearchNodes));XCTAssertEqual(gentle.seed,"9a")
        XCTAssertEqual(TrainingOpponentPolicy.gentleDecisionNodes,TrainingOpponentPolicy.gentleSearchNodes*(1+BeginnerPolicy.explorationCount),"the root and at most explorationCount constrained searches")
        XCTAssertEqual([steady.strategy,strong.strategy],[.engine,.engine]);XCTAssertEqual(steady.limit,.nodes(TrainingOpponentPolicy.engineNodes))
        XCTAssertEqual(TrainingOpponentPolicy.skill(.steady),3);XCTAssertEqual(TrainingOpponentPolicy.skill(.strong),20)
        XCTAssertTrue([gentle,steady,strong,.legacy(attempt:"a",revision:3)].allSatisfy(\.valid))
        XCTAssertEqual(gentle.policy,"beginner-v\(BeginnerPolicy.version)-nodes-\(TrainingOpponentPolicy.gentleSearchNodes)x\(1+BeginnerPolicy.explorationCount)")
        XCTAssertEqual(strong.policy,"skill-20-nodes-\(TrainingOpponentPolicy.engineNodes)");XCTAssertEqual(steady.policy,"skill-3-nodes-\(TrainingOpponentPolicy.engineNodes)")
        XCTAssertEqual(TrainingOpponentConfiguration.legacy(attempt:"a",revision:3).policy,"legacy",legacyNote)
        var mixed=gentle;mixed.mixed=true;XCTAssertEqual(mixed.policy,"mixed")
    }
    private let legacyNote="an attempt begun before levels names no node policy: it never ran one"
    func testTheSavedShapeIsTheOneTheFrozenFixtureModels()throws {
        let saved=try JSONSerialization.jsonObject(with:JSONEncoder().encode(TrainingOpponentConfiguration.frozen(.gentle,attempt:"attempt-1",seed:0x3c,revision:2))) as? [String:Any]
        XCTAssertEqual(Set((saved ?? [:]).keys),["attempt","strategy","profile","limit","seed","policyVersion","severeStreak","witness"],"`mixed` is written only when true")
        XCTAssertEqual(saved?["limit"] as? [String:Int],["nodes":TrainingOpponentPolicy.gentleSearchNodes]);XCTAssertEqual(saved?["profile"] as? String,"gentle");XCTAssertEqual(saved?["strategy"] as? String,"beginner")
        let fixture=#"{"attempt":"a","strategy":"beginner","profile":"gentle","limit":{"nodes":20000},"seed":"9a","policyVersion":1,"severeStreak":0,"witness":2}"#
        let read=try JSONDecoder().decode(TrainingOpponentConfiguration.self,from:Data(fixture.utf8))
        XCTAssertEqual(read.limit,.nodes(20000));XCTAssertTrue(read.valid)
        XCTAssertEqual(try JSONDecoder().decode(EngineSearchLimit.self,from:Data(#"{"movetime":300}"#.utf8)),.movetime(300))
        XCTAssertThrowsError(try JSONDecoder().decode(EngineSearchLimit.self,from:Data(#"{"movetime":300,"nodes":5}"#.utf8)),"one limit, not two")
        XCTAssertThrowsError(try JSONDecoder().decode(TrainingOpponentConfiguration.self,from:Data(fixture.replacingOccurrences(of:"beginner",with:"fromALaterBuild").utf8)),"an unknown strategy does not decode, so its attempt is set aside")
    }
    func testAConfigurationThisBuildCannotPlayExactlyIsNotValid(){
        var c=TrainingOpponentConfiguration.frozen(.gentle,attempt:"a",seed:5)
        XCTAssertTrue(c.valid)
        c.profile="strong";XCTAssertFalse(c.valid,"a beginner strategy is Gentle")
        c=TrainingOpponentConfiguration.frozen(.strong,attempt:"a",seed:5);c.limit = .movetime(300);XCTAssertFalse(c.valid,"levels are node-limited")
        c=TrainingOpponentConfiguration.frozen(.strong,attempt:"a",seed:5);c.severeStreak=9;XCTAssertFalse(c.valid)
        c=TrainingOpponentConfiguration.frozen(.strong,attempt:"a",seed:5);c.seed="xyz";XCTAssertFalse(c.valid)
        c=TrainingOpponentConfiguration.frozen(.strong,attempt:"",seed:5);XCTAssertFalse(c.valid)
        c=TrainingOpponentConfiguration.legacy(attempt:"a",revision:0);c.limit = .movetime(250);XCTAssertFalse(c.valid,"legacy is exactly today's search")
    }
    func testAConfigurationIsBoundToItsAttemptAndMarkedMixedWhenItsWitnessIsBehind(){
        let scenario=TrainingScenario(id:"s",entry:"finish-the-game",variant:"krk",tier:1,cluster:"c",learner:"w",prompt:"p",explanation:"e",hints:["h"],fen:"8/8/8/8/K7/3R4/8/k7 w - - 0 1",check:.ending)
        var snapshot=TrainingSessionSnapshot(id:"mine",entry:"finish-the-game",scenario:scenario,freshness:"new",revision:4,startedAt:Date(),opponent:.frozen(.gentle,attempt:"mine",seed:7,revision:4))
        XCTAssertEqual(snapshot.boundOpponent?.mixed,nil,"this build saved it last")
        snapshot.revision=7;XCTAssertEqual(snapshot.boundOpponent?.mixed,true,"an older build continued it");XCTAssertEqual(snapshot.boundOpponent?.level,.gentle,"and it keeps its level")
        snapshot.opponent?.attempt="theirs";XCTAssertNil(snapshot.boundOpponent,"another attempt's configuration is ignored")
        positionGames(false);XCTAssertNil(snapshot.settledOpponent,"with position games off nothing new is written")
        positionGames(true);XCTAssertEqual(snapshot.settledOpponent,.legacy(attempt:"mine",revision:7),"with them on it is legacy")
        snapshot.opponent=nil;XCTAssertEqual(snapshot.settledOpponent?.strategy,.legacy,"an attempt saved before levels is legacy")
    }

    // MARK: Records

    func testRecordsSayTheLevelLegacyStrengthMixedOrNotRecorded(){
        func attempt(_ opponent:TrainingOpponentConfiguration?)->TrainingAttempt {TrainingAttempt(id:"x",entry:"e",scenarioID:"s",cluster:"c",tier:1,learner:"w",startedAt:Date(),finishedAt:Date(),outcome:.correct,firstTryNoRecordedHelp:true,recordedHelp:false,retry:false,freshness:"new",opponent:opponent)}
        var mixed=TrainingOpponentConfiguration.frozen(.gentle,attempt:"a",seed:1);mixed.mixed=true
        XCTAssertEqual(attempt(.frozen(.steady,attempt:"a",seed:1)).levelLabel,"Steady")
        XCTAssertEqual(attempt(.legacy(attempt:"a",revision:0)).levelLabel,"Legacy strength")
        XCTAssertEqual(attempt(mixed).levelLabel,"Gentle, mixed: an older version of Checkmate played part of this game")
        XCTAssertEqual(attempt(nil).levelLabel,"Level not recorded")
        XCTAssertEqual(attempt(mixed).level,"gentle");XCTAssertEqual(attempt(mixed).levelPolicy,"mixed")
    }

    // MARK: Preference and offering

    func testThePerEntryPreferenceIsParsedEntryByEntryAndAbsentUntilChosen()throws {
        let s=AppSettings(raw:["positionGameLevels":["finish-the-game":"gentle","guided-games":"impossible","Bad Id":"strong","pawn-race":7,"two-bishop-mate":"strong"]])
        XCTAssertEqual(s.positionGameLevels,["finish-the-game":"gentle","two-bishop-mate":"strong"])
        XCTAssertNil(AppSettings(raw:[:]).positionGameLevels)
        let saved=try JSONSerialization.jsonObject(with:JSONEncoder().encode(AppSettings())) as? [String:Any]
        XCTAssertNil(saved?["positionGameLevels"],"a save without a choice writes nothing new")
        var chosen=AppSettings();chosen.positionGameLevels=["finish-the-game":"steady"]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(chosen)).positionGameLevels,["finish-the-game":"steady"])
    }
    func testOffPositionGamesEveryGamePlaysItsCodedStrengthWithNoChoice(){
        positionGames(false)
        XCTAssertEqual(MiniGameOffering.levels(entry:"finish-the-game",variant:"krk",check:.ending),[.strong])
        XCTAssertEqual(MiniGameOffering.levels(entry:"guided-games",variant:"initial-setup",check:.guidedGame),[.steady])
        let s=AppSettings(raw:["positionGameLevels":["finish-the-game":"gentle"]])
        XCTAssertEqual(MiniGameOffering.level(entry:"finish-the-game",variant:"krk",check:.ending,settings:s),.strong,"a preference that is not offered falls back")
    }
    func testThePreviewOffersThreeLevelsAndTheStalemateTrapOnlyStrong(){
        positionGames(true)
        XCTAssertEqual(MiniGameOffering.levels(entry:"finish-the-game",variant:"krk",check:.ending),[.gentle,.steady,.strong])
        XCTAssertEqual(MiniGameOffering.levels(entry:"finish-the-game",variant:"kqk",check:.ending),[.strong],"a weaker defender rarely heads for the stalemate")
        let s=AppSettings(raw:["positionGameLevels":["finish-the-game":"gentle"]])
        XCTAssertEqual(MiniGameOffering.level(entry:"finish-the-game",variant:"krk",check:.ending,settings:s),.gentle)
        XCTAssertEqual(MiniGameOffering.level(entry:"finish-the-game",variant:"kqk",check:.ending,settings:s),.strong)
        XCTAssertEqual(MiniGameOffering.level(entry:"guided-games",variant:"initial-setup",check:.guidedGame,settings:AppSettings()),.steady,"no preference: the coded strength")
        XCTAssertEqual(MiniGameOffering.title("gentle"),"Gentle");XCTAssertEqual(MiniGameOffering.title("legacy"),"Legacy strength")
    }
    func testOnlyAPositionGameEntryNeedsItsOwnFlag(){
        let entry=TrainingEntryDefinition(id:"pawn-race",title:"Pawn race",summary:"s",rules:["r"],objective:.positionGame,increment:.beginner,delivery:.pilot,origin:.new,skills:[.convertingWin],variants:["kpk"],lessonLinks:[],tiers:1)
        XCTAssertNoThrow(try entry.validate())
        setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)
        XCTAssertFalse(TrainingRolloutPolicy.offered(entry),"default off");XCTAssertFalse(TrainingRolloutPolicy.positionGamesEnabled)
        setenv("CHECKMATE_POSITION_GAMES","1",1);XCTAssertTrue(TrainingRolloutPolicy.offered(entry))
        unsetenv("CHECKMATE_TRAINING_B");XCTAssertFalse(TrainingRolloutPolicy.offered(entry),"on top of Increment B")
        XCTAssertEqual(TrainingCheck.focused(.positionGame,variant:"kpk"),.positionGame);XCTAssertEqual(TrainingCheck.positionGame.task,.game)
    }
}
