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
    /// Plays `moves` in a fresh game of `scenario` against `defender` and returns how it stands. For `.black` the game,
    /// the moves and the defender are each played as their mirror image (`Learner`), so the case is the same for a Black learner.
    private func outcome(_ scenario:TrainingScenario,_ moves:[String],defender:ScriptedDefender?=nil,as learner:Learner = .white)async throws -> TrainingController.Exercise {
        let (_,player,controller)=try Self.fixture([learner.scenario(scenario)],defender:learner.defender(defender ?? ScriptedDefender()));defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:scenario.entry))
        for move in moves{await Self.play(controller,learner.uci(move))}
        return try XCTUnwrap(controller.exercise)
    }
    /// D3's cases are written for a White learner; each also runs as its mirror image, ranks flipped and colours swapped,
    /// for a Black one. The defender then sees the board as the White case has it, and its move is mirrored back.
    enum Learner:CaseIterable {
        case white,black
        static func square(_ s:Substring)->String {String(s.prefix(1))+String(9-Int(String(s.suffix(1)))!)}
        static func swapped(_ c:Character)->Character {c.isUppercase ? Character(c.lowercased()):Character(c.uppercased())}
        static func mirrored(_ fen:String)->String {
            var fields=fen.split(separator:" ").map(String.init)
            fields[0]=fields[0].split(separator:"/").reversed().map{String($0.map(swapped))}.joined(separator:"/")
            fields[1]=fields[1]=="w" ? "b":"w"
            if fields[2] != "-"{let castling=fields[2].map(swapped);fields[2]="KQkq".filter{castling.contains($0)}}
            if fields[3] != "-"{fields[3]=square(Substring(fields[3]))}
            return fields.joined(separator:" ")
        }
        func uci(_ uci:String)->String {self == .white ? uci:Self.square(uci.prefix(2))+Self.square(uci.dropFirst(2).prefix(2))+uci.dropFirst(4)}
        @MainActor func scenario(_ scenario:TrainingScenario)->TrainingScenario {
            guard self == .black,let start=scenario.fen else{return scenario}
            return PositionGameTests.game(Self.mirrored(start),goal:scenario.goal?.kind ?? .checkmate,keep:scenario.keep,id:scenario.id,learner:scenario.learner=="w" ? "b":"w")
        }
        @MainActor func defender(_ defender:ScriptedDefender)->ScriptedDefender {
            guard self == .black else{return defender}
            let choose=defender.choose,mirrored=ScriptedDefender{rules in try choose(try ChessRules(fen:Self.mirrored(rules.fen))).map(Learner.black.uci)}
            mirrored.failure=defender.failure;return mirrored
        }
    }

    // MARK: D3, through the controller

    func testAnImmediateMateByPromotionWinsAndEachPromotionPieceIsJudged()async throws {
        let start="6k1/4P3/6K1/8/8/8/8/8 w - - 0 1"
        for learner in Learner.allCases {
            for goal in [TrainingGoal.Kind.checkmate,.promoteAndHold] {
                for piece in ["q","r"] {
                    let game=try await outcome(Self.game(start,goal:goal),["e7e8"+piece],as:learner)
                    XCTAssertEqual(game.status,.correct,"\(learner) \(goal) e8=\(piece) mates");XCTAssertTrue(game.feedback.hasPrefix("Checkmate!"))
                }
            }
            // A minor piece leaves king and minor piece against king: an automatic draw, which comes first in the matrix.
            for piece in ["b","n"] {
                let game=try await outcome(Self.game(start,goal:.promoteAndHold),["e7e8"+piece],as:learner)
                XCTAssertEqual(game.status,.incorrect,"\(learner) \(piece)");XCTAssertTrue(game.feedback.contains("enough material"),game.feedback)
            }
        }
    }
    func testThePromotedPieceIsHeldThroughTheReplyOrCapturedOnIt()async throws {
        for learner in Learner.allCases {
            for piece in ["q","r","b","n"] {
                // Kings and a rook besides, so the capture is not an automatic draw first.
                let held=try await outcome(Self.game("8/4P3/8/8/8/8/k7/4K2R w - - 0 1",goal:.promoteAndHold),["e7e8"+piece],as:learner)
                XCTAssertEqual(held.line.count,2,"the opponent replied");XCTAssertEqual(held.status,.correct,"\(learner) \(piece)");XCTAssertTrue(held.feedback.hasPrefix("You promoted the pawn and kept the new piece."))
                let lost=try await outcome(Self.game("8/3kP3/8/8/8/8/8/R3K3 w - - 0 1",goal:.promoteAndHold),["e7e8"+piece],defender:ScriptedDefender(choose:ScriptedDefender.capturing(piece)),as:learner)
                XCTAssertEqual(lost.line,["e7e8"+piece,"d7e8"].map(learner.uci));XCTAssertEqual(lost.status,.incorrect,"\(learner) \(piece)");XCTAssertTrue(lost.feedback.contains("captured the new piece"))
            }
        }
    }
    func testPromotingIntoStalemateIsADraw()async throws {
        for learner in Learner.allCases {
            for goal in [TrainingGoal.Kind.checkmate,.promoteAndHold] {
                let game=try await outcome(Self.game("8/1P6/8/8/8/8/8/5K1k w - - 0 1",goal:goal),["b7b8q"],as:learner)
                XCTAssertEqual(game.status,.incorrect,"\(learner)");XCTAssertTrue(game.feedback.hasPrefix("Stalemate: your opponent has no legal move"),game.feedback)
            }
        }
    }
    func testTheTrackedPawnCapturedBeforePromotingFails()async throws {
        for learner in Learner.allCases {
            let game=try await outcome(Self.game("8/8/8/8/8/8/3kP3/R6K w - - 0 1",goal:.promoteAndHold),["a1a8"],defender:ScriptedDefender(choose:ScriptedDefender.capturing("p")),as:learner)
            XCTAssertEqual(game.line,["a1a8","d2e2"].map(learner.uci));XCTAssertEqual(game.status,.incorrect,"\(learner)");XCTAssertEqual(game.feedback,"Your pawn was captured before it could promote.")
        }
    }
    func testLosingAKeptPieceFailsButAnAutomaticDrawIsReportedFirst()async throws {
        for learner in Learner.allCases {
            let kept=try await outcome(Self.game("8/8/8/8/8/2R5/1k6/4K2Q w - - 0 1",keep:["r"]),["h1h7"],defender:ScriptedDefender(choose:ScriptedDefender.capturing("r")),as:learner)
            XCTAssertEqual(kept.line,["h1h7","b2c3"].map(learner.uci));XCTAssertEqual(kept.status,.incorrect,"\(learner)");XCTAssertTrue(kept.feedback.contains("lost your last rook"),kept.feedback)
            let bare=try await outcome(Self.game("8/8/8/8/8/2R5/1k6/4K3 w - - 0 1",keep:["r"]),["e1f1"],defender:ScriptedDefender(choose:ScriptedDefender.capturing("r")),as:learner)
            XCTAssertEqual(bare.status,.incorrect,"\(learner)");XCTAssertTrue(bare.feedback.contains("neither side has enough material"),bare.feedback)
        }
    }
    /// The defender shuffles its king between h8 and g8; the learner's rook between a1 and a2.
    private static func shuffle()->ScriptedDefender {ScriptedDefender{rules in rules.moves().map(\.uci).first{$0=="h8g8" || $0=="g8h8"}}}
    private static let shuffling=["a1a2","a2a1"]
    func testAClaimedDrawEndsThePositionGameAsADraw()async throws {
        for learner in Learner.allCases {
            let (_,player,controller)=try Self.fixture([learner.scenario(Self.game("7k/8/8/8/8/8/8/R3K3 w - - 0 1"))],defender:learner.defender(Self.shuffle()));defer{player.shutdown()}
            controller.begin(try controller.prepare(entry:Self.entry.id))
            for index in 0..<4{XCTAssertNil(controller.exercise?.claimable);await Self.play(controller,learner.uci(Self.shuffling[index%2]))}
            XCTAssertEqual(controller.exercise?.claimable,"threefold repetition","\(learner): a claim is offered, never forced");XCTAssertFalse(controller.exercise?.finished ?? true)
            controller.claimDraw()
            XCTAssertEqual(controller.exercise?.status,.incorrect);XCTAssertEqual(controller.exercise?.feedback,"Draw claimed by threefold repetition. That is a draw, so this one is not solved.")
            XCTAssertEqual(controller.exercise?.snapshot.actions.last,.claim("threefold repetition"))
        }
    }
    func testEachAutomaticDrawEndsThePositionGame()async throws {
        for learner in Learner.allCases {
            // Fivefold repetition, with no claim made at the third.
            let (_,player,controller)=try Self.fixture([learner.scenario(Self.game("7k/8/8/8/8/8/8/R3K3 w - - 0 1"))],defender:learner.defender(Self.shuffle()));defer{player.shutdown()}
            controller.begin(try controller.prepare(entry:Self.entry.id))
            for index in 0..<8{XCTAssertFalse(controller.exercise?.finished ?? true,"\(learner) ply \(index*2)");await Self.play(controller,learner.uci(Self.shuffling[index%2]))}
            XCTAssertEqual(controller.exercise?.status,.incorrect);XCTAssertEqual(controller.exercise?.feedback,"The game is drawn: fivefold repetition.")
            // The 75-move rule.
            let slow=try await outcome(Self.game("7k/8/8/8/8/8/8/R3K3 w - - 149 80"),["a1a2"],as:learner)
            XCTAssertEqual(slow.line,["a1a2"].map(learner.uci));XCTAssertEqual(slow.status,.incorrect,"\(learner)");XCTAssertEqual(slow.feedback,"The game is drawn: the 75-move rule.")
            // Insufficient material is the kept-piece case above.
        }
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
