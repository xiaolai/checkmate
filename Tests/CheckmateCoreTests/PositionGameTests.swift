import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-017: the `positionGame` objective played through the training controller. D3's closed outcome matrix decides
/// each game, for either learner colour, and every existing finish-the-game sequence ends re-expressed as `checkmate`
/// with `keep` exactly as today's evaluator ended it. No learner content exists yet (WI-020): these are test fixtures.
@MainActor final class PositionGameTests:XCTestCase {
    override func setUp(){for name in ["CHECKMATE_TRAINING_ENABLED","CHECKMATE_TRAINING_B","CHECKMATE_POSITION_GAMES"]{setenv(name,"1",1)}}
    override func tearDown(){for name in ["CHECKMATE_TRAINING_ENABLED","CHECKMATE_TRAINING_B","CHECKMATE_POSITION_GAMES"]{unsetenv(name)}}
    /// A position-game entry for fixtures only: the bundled catalog has none until WI-020.
    static let entry=TrainingEntryDefinition(id:"position-test",title:"Position test",summary:"A fixture entry.",rules:["Play to the goal."],objective:.positionGame,increment:.beginner,delivery:.pilot,origin:.new,skills:[.convertingWin],variants:["test"],lessonLinks:[],tiers:1)
    static func catalog()throws -> TrainingCatalog {let bundled=try TrainingCatalog.bundled();return TrainingCatalog(contentVersion:bundled.contentVersion,entries:bundled.entries+[entry])}
    static func game(_ fen:String,goal:TrainingGoal.Kind = .checkmate,keep:[String]?=nil,id:String="position-test-1",learner:String?=nil)->TrainingScenario {
        TrainingScenario(id:id,entry:entry.id,variant:"test",tier:1,cluster:id,learner:learner ?? String(fen.split(separator:" ")[1]),prompt:"Play to the goal.",explanation:"Done.",hints:["Think.","Look."],fen:fen,review:TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion),check:.positionGame,goal:TrainingGoal(kind:goal,threshold:0),keep:keep)
    }
    static func fixture(_ scenarios:[TrainingScenario],defender:ScriptedDefender)throws -> (GameSession,LearningPlayer,TrainingController) {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        let controller=TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider(catalog:try catalog(),scenarios:scenarios))
        controller.games.engine=defender
        return (session,player,controller)
    }
    static func play(_ controller:TrainingController,_ uci:String)async {
        controller.attempt(from:String(uci.prefix(2)),to:String(uci.dropFirst(2).prefix(2)),promotion:uci.count==5 ? String(uci.suffix(1)):nil)
        await TrainingEndgameTests.settle(controller)
    }
    /// Plays `moves` in a fresh game of `scenario` against `defender` and returns how it stands.
    private func outcome(_ scenario:TrainingScenario,_ moves:[String],defender:ScriptedDefender?=nil)async throws -> TrainingController.Exercise {
        let (_,player,controller)=try Self.fixture([scenario],defender:defender ?? ScriptedDefender());defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:scenario.entry))
        for move in moves{await Self.play(controller,move)}
        return try XCTUnwrap(controller.exercise)
    }

    // MARK: D3, through the controller

    func testAnImmediateMateByPromotionWinsAndEachPromotionPieceIsJudged()async throws {
        let start="6k1/4P3/6K1/8/8/8/8/8 w - - 0 1"
        for goal in [TrainingGoal.Kind.checkmate,.promoteAndHold] {
            for piece in ["q","r"] {
                let game=try await outcome(Self.game(start,goal:goal),["e7e8"+piece])
                XCTAssertEqual(game.status,.correct,"\(goal) e8=\(piece) mates");XCTAssertTrue(game.feedback.hasPrefix("Checkmate!"))
            }
        }
        // A minor piece leaves king and minor piece against king: an automatic draw, which comes first in the matrix.
        for piece in ["b","n"] {
            let game=try await outcome(Self.game(start,goal:.promoteAndHold),["e7e8"+piece])
            XCTAssertEqual(game.status,.incorrect,piece);XCTAssertTrue(game.feedback.contains("enough material"),game.feedback)
        }
    }
    func testThePromotedPieceIsHeldThroughTheReplyOrCapturedOnIt()async throws {
        for piece in ["q","r","b","n"] {
            // Kings and a rook besides, so the capture is not an automatic draw first.
            let held=try await outcome(Self.game("8/4P3/8/8/8/8/k7/4K2R w - - 0 1",goal:.promoteAndHold),["e7e8"+piece])
            XCTAssertEqual(held.line.count,2,"the opponent replied");XCTAssertEqual(held.status,.correct,piece);XCTAssertTrue(held.feedback.hasPrefix("You promoted the pawn and kept the new piece."))
            let lost=try await outcome(Self.game("8/3kP3/8/8/8/8/8/R3K3 w - - 0 1",goal:.promoteAndHold),["e7e8"+piece],defender:ScriptedDefender(choose:ScriptedDefender.capturing(piece)))
            XCTAssertEqual(lost.line,["e7e8"+piece,"d7e8"]);XCTAssertEqual(lost.status,.incorrect,piece);XCTAssertTrue(lost.feedback.contains("captured the new piece"))
        }
    }
    func testPromotingIntoStalemateIsADraw()async throws {
        for goal in [TrainingGoal.Kind.checkmate,.promoteAndHold] {
            let game=try await outcome(Self.game("8/1P6/8/8/8/8/8/5K1k w - - 0 1",goal:goal),["b7b8q"])
            XCTAssertEqual(game.status,.incorrect);XCTAssertTrue(game.feedback.hasPrefix("Stalemate: your opponent has no legal move"),game.feedback)
        }
    }
    func testTheTrackedPawnCapturedBeforePromotingFails()async throws {
        let game=try await outcome(Self.game("8/8/8/8/8/8/3kP3/R6K w - - 0 1",goal:.promoteAndHold),["a1a8"],defender:ScriptedDefender(choose:ScriptedDefender.capturing("p")))
        XCTAssertEqual(game.line,["a1a8","d2e2"]);XCTAssertEqual(game.status,.incorrect);XCTAssertEqual(game.feedback,"Your pawn was captured before it could promote.")
    }
    func testLosingAKeptPieceFailsButAnAutomaticDrawIsReportedFirst()async throws {
        let kept=try await outcome(Self.game("8/8/8/8/8/2R5/1k6/4K2Q w - - 0 1",keep:["r"]),["h1h7"],defender:ScriptedDefender(choose:ScriptedDefender.capturing("r")))
        XCTAssertEqual(kept.line,["h1h7","b2c3"]);XCTAssertEqual(kept.status,.incorrect);XCTAssertTrue(kept.feedback.contains("lost your last rook"),kept.feedback)
        let bare=try await outcome(Self.game("8/8/8/8/8/2R5/1k6/4K3 w - - 0 1",keep:["r"]),["e1f1"],defender:ScriptedDefender(choose:ScriptedDefender.capturing("r")))
        XCTAssertEqual(bare.status,.incorrect);XCTAssertTrue(bare.feedback.contains("neither side has enough material"),bare.feedback)
    }
    /// The defender shuffles its king between h8 and g8; the learner's rook between a1 and a2.
    private static func shuffle()->ScriptedDefender {ScriptedDefender{rules in rules.moves().map(\.uci).first{$0=="h8g8" || $0=="g8h8"}}}
    private static let shuffling=["a1a2","a2a1"]
    func testAClaimedDrawEndsThePositionGameAsADraw()async throws {
        let (_,player,controller)=try Self.fixture([Self.game("7k/8/8/8/8/8/8/R3K3 w - - 0 1")],defender:Self.shuffle());defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:Self.entry.id))
        for index in 0..<4{XCTAssertNil(controller.exercise?.claimable);await Self.play(controller,Self.shuffling[index%2])}
        XCTAssertEqual(controller.exercise?.claimable,"threefold repetition","a claim is offered, never forced");XCTAssertFalse(controller.exercise?.finished ?? true)
        controller.claimDraw()
        XCTAssertEqual(controller.exercise?.status,.incorrect);XCTAssertEqual(controller.exercise?.feedback,"Draw claimed by threefold repetition. That is a draw, so this one is not solved.")
        XCTAssertEqual(controller.exercise?.snapshot.actions.last,.claim("threefold repetition"))
    }
    func testEachAutomaticDrawEndsThePositionGame()async throws {
        // Fivefold repetition, with no claim made at the third.
        let (_,player,controller)=try Self.fixture([Self.game("7k/8/8/8/8/8/8/R3K3 w - - 0 1")],defender:Self.shuffle());defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:Self.entry.id))
        for index in 0..<8{XCTAssertFalse(controller.exercise?.finished ?? true,"ply \(index*2)");await Self.play(controller,Self.shuffling[index%2])}
        XCTAssertEqual(controller.exercise?.status,.incorrect);XCTAssertEqual(controller.exercise?.feedback,"The game is drawn: fivefold repetition.")
        // The 75-move rule.
        let slow=try await outcome(Self.game("7k/8/8/8/8/8/8/R3K3 w - - 149 80"),["a1a2"])
        XCTAssertEqual(slow.line,["a1a2"]);XCTAssertEqual(slow.status,.incorrect);XCTAssertEqual(slow.feedback,"The game is drawn: the 75-move rule.")
        // Insufficient material is the kept-piece case above.
    }
    func testBlackToMoveAtFullmove37()async throws {
        let mate=try await outcome(Self.game("8/8/8/8/8/6k1/4p3/6K1 b - - 0 37",goal:.promoteAndHold),["e2e1q"])
        XCTAssertEqual(mate.status,.correct);XCTAssertTrue(mate.feedback.hasPrefix("Checkmate!"))
        // A quiet move and its reply, taken back, then saved and resumed: the pawn is followed through all of it.
        let start="4k3/8/8/8/8/8/4p3/K7 b - - 0 37"
        let (session,player,controller)=try Self.fixture([Self.game(start,goal:.promoteAndHold)],defender:ScriptedDefender());defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:Self.entry.id))
        XCTAssertEqual(controller.exercise?.pawns,[.pawn("e2")])
        await Self.play(controller,"e8d8");XCTAssertEqual(controller.exercise?.line,["e8d8","a1a2"]);XCTAssertEqual(controller.exercise?.pawns.last,.pawn("e2"))
        controller.undo();XCTAssertEqual(controller.exercise?.line,[]);XCTAssertEqual(controller.exercise?.pawns,[.pawn("e2")],"take back restores the pawn's square")
        await Self.play(controller,"e8d7")
        let saved=try JSONDecoder().decode(ApplicationState.self,from:JSONEncoder().encode(session.state))
        let (_,again,resumed)=try Self.fixture([Self.game(start,goal:.promoteAndHold)],defender:ScriptedDefender());defer{again.shutdown()}
        resumed.session.state=saved;resumed.begin(try resumed.prepareResume())
        XCTAssertEqual(resumed.exercise?.line,["e8d7","a1a2"]);XCTAssertEqual(resumed.exercise?.pawns.last,.pawn("e2"),"resumed by replay")
        await Self.play(resumed,"e2e1q")
        XCTAssertEqual(resumed.exercise?.line.count,4);XCTAssertEqual(resumed.exercise?.status,.correct,"held through White's reply")
    }
    func testTheBreakReminderAndTheEnginePauseApplyUnchanged()async throws {
        let failing=ScriptedDefender();failing.failure=CheckmateError.unavailable("stopped")
        let (_,player,controller)=try Self.fixture([Self.game("7k/8/8/8/8/8/8/R3K3 w - - 0 1")],defender:failing);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:Self.entry.id))
        await Self.play(controller,"a1a2")
        XCTAssertNotNil(controller.exercise?.paused);XCTAssertEqual(controller.exercise?.status,.active,"an engine failure is never counted")
        let (_,other,reminded)=try Self.fixture([Self.game("7k/8/8/8/8/8/8/R3K3 w - - 0 1",id:"position-test-2")],defender:Self.shuffle());defer{other.shutdown()}
        reminded.games.reminderPlies=4;reminded.begin(try reminded.prepare(entry:Self.entry.id))
        await Self.play(reminded,"a1a2");await Self.play(reminded,"a2a1")
        XCTAssertTrue(reminded.exercise?.reminder ?? false)
    }

    // MARK: Validation

    func testStartsAreValidatedAsThePositionGameTheyClaim()throws {
        func validate(_ scenario:TrainingScenario)throws {try TrainingValidationService.validate(scenario,definition:Self.entry)}
        XCTAssertNoThrow(try validate(Self.game("8/4P3/8/8/8/8/k7/4K2R w - - 0 1",goal:.promoteAndHold)))
        XCTAssertNoThrow(try validate(Self.game("8/8/8/8/8/2R5/1k6/4K2Q w - - 0 1",keep:["r","q"])))
        XCTAssertThrowsError(try validate(Self.game("8/4P3/8/8/8/8/k4P2/4K3 w - - 0 1",goal:.promoteAndHold)),"a pawn race has exactly one learner pawn")
        XCTAssertThrowsError(try validate(Self.game("8/8/8/8/8/2R5/1k6/4K3 w - - 0 1",keep:["q"])),"it keeps only what the learner has")
        XCTAssertThrowsError(try validate(Self.game("8/8/8/8/8/2R5/1k6/4K3 b - - 0 1",learner:"w")),"the learner is to move")
        XCTAssertThrowsError(try validate(Self.game("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")),"a game that is over")
        let base=Self.game("8/8/8/8/8/2R5/1k6/4K3 w - - 0 1")
        func with(goal:TrainingGoal?=TrainingGoal(kind:.checkmate,threshold:0),plies:Int?=nil,keep:[String]?=nil,check:TrainingCheck = .positionGame)->TrainingScenario {
            TrainingScenario(id:base.id,entry:base.entry,variant:base.variant,tier:1,cluster:base.cluster,learner:"w",prompt:base.prompt,explanation:base.explanation,hints:base.hints,fen:base.fen,review:base.review,check:check,goal:goal,plies:plies,keep:keep)
        }
        XCTAssertThrowsError(try validate(with(goal:nil)),"a position game names its goal")
        XCTAssertThrowsError(try validate(with(goal:TrainingGoal(kind:.checkmate,threshold:1))),"threshold 0")
        XCTAssertThrowsError(try validate(with(goal:TrainingGoal(kind:.gain,threshold:1))),"a bounded search's goal")
        XCTAssertThrowsError(try validate(with(plies:3)),"no horizon")
        XCTAssertThrowsError(try validate(with(keep:["k"])),"never the king")
        XCTAssertThrowsError(try validate(with(keep:["r","r"])))
        XCTAssertThrowsError(try validate(with(keep:[])))
        let ending=try XCTUnwrap(TrainingCatalog.bundled().entry("finish-the-game")),krk=TrainingEndgameTests.ending("8/8/8/8/K7/3R4/8/k7 w - - 0 1",variant:"krk")
        XCTAssertNoThrow(try TrainingValidationService.validate(krk,definition:ending))
        let kept=TrainingScenario(id:krk.id,entry:krk.entry,variant:krk.variant,tier:1,cluster:krk.cluster,learner:"w",prompt:krk.prompt,explanation:krk.explanation,hints:krk.hints,fen:krk.fen,review:krk.review,check:.ending,keep:["r"])
        XCTAssertThrowsError(try TrainingValidationService.validate(kept,definition:ending),"only a position game keeps piece types")
        // A bounded search may not borrow a position game's goal.
        let material=try XCTUnwrap(TrainingScenarioProvider.bundled().scenarios(for:"capture-wisely").first{$0.check == .material})
        let borrowed=TrainingScenario(id:material.id,entry:material.entry,variant:material.variant,tier:material.tier,cluster:material.cluster,learner:material.learner,prompt:material.prompt,explanation:material.explanation,hints:material.hints,fen:material.fen,review:material.review,check:material.check,goal:TrainingGoal(kind:.checkmate,threshold:0),plies:material.plies,nodes:material.nodes)
        XCTAssertThrowsError(try TrainingValidationService.validate(borrowed,definition:try XCTUnwrap(TrainingCatalog.bundled().entry("capture-wisely"))))
    }
    func testAPositionGameScenarioReadsAsTheContentScriptPublishesIt()throws {
        let json=#"{"id":"kpk-e","entry":"position-test","variant":"test","tier":1,"cluster":"kpk-e","learner":"w","prompt":"Promote.","explanation":"Lead with the king.","hints":["Keep the king in front."],"fen":"4k3/8/8/8/8/8/4P3/4K3 w - - 0 1","review":{"author":"a","reviewer":null,"validatorVersion":1},"check":"positionGame","goal":{"kind":"promoteAndHold","threshold":0}}"#
        let scenario=try JSONDecoder().decode(TrainingScenario.self,from:Data(json.utf8))
        XCTAssertEqual(scenario.check,.positionGame);XCTAssertEqual(scenario.goal?.kind,.promoteAndHold);XCTAssertNil(scenario.keep)
        XCTAssertNoThrow(try TrainingValidationService.validate(scenario,definition:Self.entry))
        let kept=try JSONDecoder().decode(TrainingScenario.self,from:Data(json.replacingOccurrences(of:#""threshold":0}"#,with:#""threshold":0},"keep":["p"]"#).utf8))
        XCTAssertEqual(kept.keep,["p"])
    }
    func testPositionGamesAreOfferedOnlyBehindTheirFlag()throws {
        let (_,player,controller)=try Self.fixture([Self.game("7k/8/8/8/8/8/8/R3K3 w - - 0 1")],defender:ScriptedDefender());defer{player.shutdown()}
        unsetenv("CHECKMATE_POSITION_GAMES")
        XCTAssertThrowsError(try controller.prepare(entry:Self.entry.id),"default off")
        XCTAssertTrue(TrainingRolloutPolicy.offered(try XCTUnwrap(controller.catalog?.entry("finish-the-game"))),"existing games are unaffected")
        setenv("CHECKMATE_POSITION_GAMES","1",1);XCTAssertNoThrow(try controller.prepare(entry:Self.entry.id))
    }

    // MARK: The finish-the-game regression

    private struct Recorded:Decodable {let scenario:String,moves:String,outcome:String,message:String,claim:String?}
    private struct Recording:Decodable {let records:[Recorded]}
    /// Each recorded sequence, replayed through today's `ending` evaluator and re-expressed as `checkmate` keeping the
    /// mating piece, ends at the same ply with the same outcome; today's message is unchanged too.
    func testEveryRecordedFinishTheGameSequenceEndsTheSameReexpressedAsCheckmateWithKeep()async throws {
        let url=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/PositionGames/finish-the-game-sequences.json")
        let records=try JSONDecoder().decode(Recording.self,from:Data(contentsOf:url)).records
        let kinds=Set(records.map{$0.outcome=="correct" ? "mate":$0.claim != nil ? "claim":$0.message.hasPrefix("Stalemate") ? "stalemate":$0.message.contains("captured your") ? "piece":"other"})
        XCTAssertEqual(kinds,["mate","claim","stalemate","piece"],"the fixture covers every ending today's evaluator gives");XCTAssertGreaterThanOrEqual(records.count,30)
        let bundled=try TrainingScenarioProvider.bundled().scenarios(for:"finish-the-game")
        XCTAssertEqual(Set(records.map(\.scenario)).count,Set(bundled.map(\.id)).intersection(records.map(\.scenario)).count,"every recorded scenario is bundled")
        for record in records {
            let original=try XCTUnwrap(bundled.first{$0.id==record.scenario})
            let restated=TrainingScenario(id:"restated-"+original.id,entry:Self.entry.id,variant:"test",tier:1,cluster:original.cluster,learner:original.learner,prompt:original.prompt,explanation:original.explanation,hints:original.hints,fen:original.fen,review:original.review,check:.positionGame,goal:TrainingGoal(kind:.checkmate,threshold:0),keep:[original.variant=="krk" ? "r":"q"])
            let moves=record.moves.split(separator:" ").map(String.init)
            for scenario in [original,restated] {
                var replies=moves.indices.filter{$0 % 2==1}.map{moves[$0]}
                let defender=ScriptedDefender{_ in replies.isEmpty ? nil:replies.removeFirst()}
                let (_,player,controller)=try Self.fixture([scenario],defender:defender)
                controller.begin(try controller.prepare(entry:scenario.entry))
                for index in moves.indices where index % 2==0 {
                    XCTAssertFalse(controller.exercise?.finished ?? true,"\(scenario.id) ended before ply \(index)");await Self.play(controller,moves[index])
                }
                if let claim=record.claim{XCTAssertEqual(controller.exercise?.claimable,claim,scenario.id);controller.claimDraw()}
                XCTAssertEqual(controller.exercise?.line,moves,scenario.id);XCTAssertEqual(controller.exercise?.status.rawValue,record.outcome,scenario.id)
                if scenario == original{XCTAssertEqual(controller.exercise?.feedback,record.message,"today's message, \(scenario.id)")}
                player.shutdown()
            }
        }
    }
}
