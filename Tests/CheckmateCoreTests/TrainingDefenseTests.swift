import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-009: the exact bounded search behind Save Your Piece and Capture Wisely, and the multi-move runtime that plays
/// its validated teaching graph. Expected sets are hand-verified; the search must also agree with brute force.
@MainActor final class TrainingDefenseTests:XCTestCase {
    // Increment B is gated behind its preview flags; these tests exercise it as development does.
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    private let review=TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion)
    private func scenario(_ id:String,entry:String="save-your-piece",variant:String="move-away",check:TrainingCheck = .defense,fen:String,goal:TrainingGoal,plies:Int=3,nodes:[TrainingTeachingNode]?=nil,wrong:[String]?=nil)->TrainingScenario {
        TrainingScenario(id:id,entry:entry,variant:variant,tier:1,cluster:id,learner:String(fen.split(separator:" ")[1]),prompt:"Keep your piece.",explanation:"Explained.",hints:["Concept.","Pieces."],fen:fen,expected:wrong.map{TrainingExpected(wrong:$0)},review:review,check:check,goal:goal,plies:plies,nodes:nodes)
    }
    private func classify(_ fen:String,_ goal:TrainingGoal,plies:Int=3,cap:Int=TrainingContinuationValidator.nodeCap)throws -> (accepted:Set<String>,rejected:Set<String>,replies:[String:String]) {
        try TrainingContinuationValidator(cap:cap).classify(scenario("probe",fen:fen,goal:goal,plies:plies),plies:plies)
    }
    /// The teaching graph the search derives: the root, plus the node after the reply to each move in `continuing`.
    private func graph(_ base:TrainingScenario,continuing:Set<String>=[])throws -> [TrainingTeachingNode] {
        let validator=try TrainingContinuationValidator(),plies=base.plies ?? 3
        let root=try validator.classify(base,plies:plies),fingerprint=try TrainingLegality(fen:base.fen!).fingerprint()
        var nodes=[TrainingTeachingNode(fingerprint:fingerprint,accepted:root.accepted.sorted(),replies:root.replies)],next:[String:Int]=[:]
        for move in continuing.sorted() {
            let reply=try XCTUnwrap(root.replies[move]),found=try validator.classify(base,line:[move,reply],plies:plies-2)
            next[move]=nodes.count;nodes.append(TrainingTeachingNode(fingerprint:try TrainingLegality(fen:base.fen!,prelude:[move,reply]).fingerprint(),accepted:found.accepted.sorted(),replies:found.replies))
        }
        if !next.isEmpty{nodes[0]=TrainingTeachingNode(fingerprint:nodes[0].fingerprint,accepted:nodes[0].accepted,replies:nodes[0].replies,next:next)}
        return nodes
    }
    private func published(_ base:TrainingScenario,_ nodes:[TrainingTeachingNode])->TrainingScenario {
        TrainingScenario(id:base.id,entry:base.entry,variant:base.variant,tier:base.tier,cluster:base.cluster,learner:base.learner,prompt:base.prompt,explanation:base.explanation,hints:base.hints,fen:base.fen,expected:base.expected,review:base.review,check:base.check,goal:base.goal,plies:base.plies,nodes:nodes,focus:["c3"])
    }
    // The knight on c3 is attacked by the pawn on d4; every knight move escapes, nothing else saves it.
    private let knightFEN="4k3/8/8/8/3p4/2N5/6P1/4K3 w - - 0 1"
    private let knightGoal=TrainingGoal(kind:.survive,threshold:0,target:"c3")
    // A knight on b5 can fork the king on e8 and the rook on a6 from c7; the pawns keep it from being a bare draw.
    private let forkFEN="4k3/6p1/r7/1N6/8/8/6P1/4K3 w - - 0 1"
    // MARK: Search semantics
    func testEveryGenuineAlternativeIsAcceptedAndPassiveMovesFail()throws {
        let found=try classify(knightFEN,knightGoal)
        XCTAssertEqual(found.accepted,["c3a2","c3a4","c3b1","c3b5","c3d1","c3d5","c3e2","c3e4"],"every safe knight square, including the centre")
        XCTAssertTrue(found.rejected.isSuperset(of:["g2g3","g2g4","e1d1","e1d2"]),"a passive move loses the knight")
        XCTAssertEqual(found.replies["g2g3"],"d4c3","the refutation takes the knight")
    }
    func testRecapturesPinnedDefendersAndThePlyThreeArtifact()throws {
        // The pawn on d6 defends e5 but is pinned to its king by the bishop on b4, so Rxe5+ wins the knight.
        let pinned=try classify("8/4k3/3p4/4n3/1B6/8/8/4R1K1 w - - 0 1",TrainingGoal(kind:.gain,threshold:1))
        XCTAssertEqual(pinned.accepted,["e1e5"]);XCTAssertEqual(pinned.replies["b4c5"],"d6c5","an unpinned pawn recaptures")
        // Taking the defended pawn on d5 at once, or after a waiting move at ply three, loses the queen to the recapture.
        let leaf=try classify("4k3/8/2p5/3p4/8/8/8/3QK3 w - - 0 1",TrainingGoal(kind:.gain,threshold:1))
        XCTAssertEqual(leaf.accepted,[],"a ply-three capture of a defended piece is not a gain");XCTAssertEqual(leaf.replies["d1d5"],"c6d5")
        XCTAssertTrue(leaf.rejected.contains("d1d3"))
    }
    func testMateTakesPrecedenceAndDrawsCountOnlyWhenAllowed()throws {
        // The rook on a1 hangs to the bishop, but taking it allows a back-rank mate: those moves keep the goal.
        let mate=try classify("6k1/5ppp/8/8/8/8/1b3PPP/R2Q2K1 w - - 0 1",TrainingGoal(kind:.survive,threshold:0,target:"a1"))
        XCTAssertTrue(mate.accepted.isSuperset(of:["d1d8","g2g3","a1a2"]),"mate at once, or mate after Bxa1")
        XCTAssertTrue(mate.rejected.isSuperset(of:["d1f1","a1a3"]),"leaving the back rank, or a rook square the bishop covers")
        // Qf7 and Qc4 stalemate the king: a draw satisfies only a goal that allows it. Qf8 is mate.
        let fen="7k/8/6K1/8/8/8/8/5Q2 w - - 0 1"
        let strict=try classify(fen,TrainingGoal(kind:.hold,threshold:0),plies:1),relaxed=try classify(fen,TrainingGoal(kind:.hold,threshold:0,drawOK:true),plies:1)
        XCTAssertEqual(strict.rejected,["f1c4","f1f7"]);XCTAssertTrue(strict.accepted.contains("f1f8"));XCTAssertEqual(relaxed.rejected,[])
    }
    func testStandPatAndEvasionsInQuiescence()throws {
        // With one ply, only taking the rook gains. Quiet moves fail statically (the opponent stands pat), but after
        // a check the opponent must evade, so a reply is shown.
        let found=try classify("4k3/8/8/3r4/8/8/3R4/4K3 w - - 0 1",TrainingGoal(kind:.gain,threshold:1),plies:1)
        XCTAssertEqual(found.accepted,["d2d5"]);XCTAssertNil(found.replies["d2d3"]);XCTAssertEqual(found.replies["d2e2"],"e8d7")
    }
    func testCheaperAttackersAndIntermediateChecks()throws {
        // The knight on d4 is protected by the pawn on c3, but a pawn attacks it: protection is not enough, every
        // knight move is accepted, and a waiting or protecting move loses it to exd4.
        let cheaper=try classify("4k3/8/8/4p3/3N4/2P5/8/4K3 w - - 0 1",TrainingGoal(kind:.survive,threshold:0,target:"d4"))
        XCTAssertEqual(cheaper.accepted,["d4b3","d4b5","d4c2","d4c6","d4e2","d4e6","d4f3","d4f5"]);XCTAssertEqual(cheaper.replies["e1d2"],"e5d4")
        // Rxa7 wins a pawn only on its face: Nb5+ is a check that forks the king and the rook, which falls next.
        let check=try classify("7k/p7/3n4/8/8/2K5/8/R7 w - - 0 1",TrainingGoal(kind:.gain,threshold:1))
        XCTAssertFalse(check.accepted.contains("a1a7"));XCTAssertEqual(check.replies["a1a7"],"d6b5")
    }
    func testThresholdSearchAgreesWithBruteForce()throws {
        let validator=try TrainingContinuationValidator(cap:600_000),gain=TrainingGoal(kind:.gain,threshold:1)
        let cases:[(fen:String,prelude:[String],goal:TrainingGoal,line:[String],plies:Int)]=[
            (knightFEN,[],knightGoal,[],3),
            ("4k3/8/2p5/8/3N4/8/8/4K3 b - - 0 1",["c6c5"],TrainingGoal(kind:.survive,threshold:0,target:"d4"),[],3),
            (forkFEN,[],gain,[],3),(forkFEN,[],gain,["b5c7","e8d7"],1),
            ("4k3/8/8/3r4/8/8/3R4/4K3 w - - 0 1",[],gain,[],3),
            ("4k3/8/8/4p3/3N4/2P5/8/4K3 w - - 0 1",[],TrainingGoal(kind:.survive,threshold:0,target:"d4"),[],3),
            ("7k/p7/3n4/8/8/2K5/8/R7 w - - 0 1",[],gain,[],3)]
        for item in cases {
            let probe=TrainingScenario(id:"parity",entry:"save-your-piece",variant:"move-away",tier:1,cluster:"p",learner:"w",prompt:"p",explanation:"e",hints:["h"],fen:item.fen,prelude:item.prelude,review:review,check:.defense,goal:item.goal,plies:item.plies)
            XCTAssertEqual(try validator.classify(probe,line:item.line,plies:item.plies).accepted,try validator.bruteAccepted(probe,line:item.line,plies:item.plies),"\(item.fen) after \(item.line)")
        }
    }
    func testExhaustionNeverCertifiesAPartialResult()throws {
        XCTAssertThrowsError(try classify(forkFEN,TrainingGoal(kind:.gain,threshold:1),cap:20)){error in XCTAssertTrue("\(error)".contains("exceeded 20"))}
    }
    // MARK: Multi-move runtime
    private func fixture(_ scenarios:[TrainingScenario])throws -> (GameSession,LearningPlayer,TrainingController) {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        let controller=TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider(catalog:try TrainingCatalog.bundled(),scenarios:scenarios))
        controller.now={Date(timeIntervalSince1970:1_800_000_000)};controller.calendar=Calendar(identifier:.gregorian);controller.calendar.timeZone=TimeZone(identifier:"UTC")!
        return (session,player,controller)
    }
    private func forkScenario()throws -> TrainingScenario {
        let base=scenario("fork-test",entry:"simple-tactics",variant:"fork-realize",check:.material,fen:forkFEN,goal:TrainingGoal(kind:.gain,threshold:1))
        return published(base,try graph(base,continuing:["b5c7"]))
    }
    func testCorrectRootThenWrongContinuationIsNotASuccess()throws {
        let fork=try forkScenario();try TrainingValidationService.validate(fork,definition:try XCTUnwrap(TrainingCatalog.bundled().entry("simple-tactics")),deep:true)
        let (session,player,controller)=try fixture([fork]);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"simple-tactics"))
        controller.attempt(from:"b5",to:"c7",promotion:nil)
        let middle=try XCTUnwrap(controller.exercise)
        XCTAssertFalse(middle.finished);XCTAssertEqual(middle.node,1);XCTAssertEqual(middle.line,["b5c7","e8d7"],"the published reply is played")
        XCTAssertEqual(middle.board["d7"],"bk");XCTAssertEqual(session.state.training?.active?.actions,[.move(from:"b5",to:"c7",promotion:nil),.reply("e8d7")],"each committed ply is saved")
        XCTAssertNil(session.publicState()["nodes"]);XCTAssertFalse("\(session.training as Any)".contains("c7a6"),"no accepted set or scheduled reply is projected")
        controller.attempt(from:"c7",to:"e6",promotion:nil)
        XCTAssertEqual(controller.exercise?.status,.incorrect,"a correct root followed by a wrong continuation is not a success")
        XCTAssertEqual(session.state.training?.attempts.last?.outcome,.incorrect)
        // Retry returns to the concrete root.
        controller.retry();XCTAssertEqual(controller.exercise?.node,0);XCTAssertEqual(controller.exercise?.board["b5"],"wn")
        controller.attempt(from:"b5",to:"c7",promotion:nil);controller.attempt(from:"c7",to:"a6",promotion:nil)
        XCTAssertEqual(controller.exercise?.status,.correct)
    }
    func testAWrongRootShowsItsRefutation()throws {
        let (session,player,controller)=try fixture([try forkScenario()]);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"simple-tactics"))
        controller.attempt(from:"b5",to:"d6",promotion:nil)
        let shown=try XCTUnwrap(controller.exercise)
        XCTAssertEqual(shown.status,.incorrect);XCTAssertEqual(shown.board["d6"],"br","the refuting capture is demonstrated");XCTAssertTrue(shown.feedback.hasPrefix("After Rxd6"))
        XCTAssertEqual(session.state.training?.attempts.count,1)
    }
    func testIllegalInputIsASelectionCorrection()throws {
        let (_,player,controller)=try fixture([published(scenario("knight",fen:knightFEN,goal:knightGoal,wrong:["g2g3"]),try graph(scenario("knight",fen:knightFEN,goal:knightGoal,wrong:["g2g3"])))]);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"save-your-piece"))
        controller.attempt(from:"c3",to:"c5",promotion:nil)
        XCTAssertFalse(controller.exercise?.finished ?? true);XCTAssertTrue(controller.exercise?.snapshot.actions.isEmpty ?? false,"not counted")
        // An off-turn submission (moving the opponent's pawn) is refused the same way.
        controller.attempt(from:"d4",to:"d3",promotion:nil)
        XCTAssertFalse(controller.exercise?.finished ?? true);XCTAssertTrue(controller.exercise?.snapshot.actions.isEmpty ?? false,"an off-turn move is not counted")
        controller.attempt(from:"c3",to:"e4",promotion:nil)
        XCTAssertEqual(controller.exercise?.status,.correct);XCTAssertTrue(controller.exercise?.feedback.contains("You saved it by moving it away") ?? false,"feedback names the actual technique")
    }
    func testAFaultVoidsOnlyTheUncommittedPly()throws {
        let (session,player,controller)=try fixture([try forkScenario()]);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"simple-tactics"))
        var allowed=Int.max
        controller.runtimeFactory={if allowed<=0{throw CheckmateError.unavailable("injected fault")};allowed-=1;return try JavaScriptCoreChessRuntime()}
        allowed=1
        controller.attempt(from:"b5",to:"c7",promotion:nil)
        let after=try XCTUnwrap(controller.exercise)
        XCTAssertEqual(after.status,.active);XCTAssertEqual(after.node,0);XCTAssertEqual(after.line,[]);XCTAssertTrue(after.snapshot.actions.isEmpty)
        XCTAssertTrue(after.feedback.contains("Nothing was counted"));XCTAssertEqual(session.state.training?.attempts.count ?? 0,0)
        allowed = .max
        controller.attempt(from:"b5",to:"c7",promotion:nil);XCTAssertEqual(controller.exercise?.node,1,"the same ply works once the fault is gone")
    }
    func testAFingerprintMismatchSuspendsWithoutLearnerFailure()throws {
        let fork=try forkScenario(),nodes=try XCTUnwrap(fork.nodes)
        let broken=published(fork,[nodes[0],TrainingTeachingNode(fingerprint:"8/8/8/8/8/8/8/8 w - -",accepted:nodes[1].accepted,replies:nodes[1].replies)])
        let (session,player,controller)=try fixture([broken]);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"simple-tactics"))
        controller.attempt(from:"b5",to:"c7",promotion:nil)
        XCTAssertEqual(controller.exercise?.status,.suspended);XCTAssertEqual(session.state.training?.attempts.count ?? 0,0,"nothing is scored")
        XCTAssertNil(session.state.training?.active);XCTAssertFalse(controller.provider?.available(try XCTUnwrap(controller.catalog?.entry("simple-tactics"))) ?? true,"the scenario is withdrawn")
        controller.retry();XCTAssertEqual(controller.exercise?.status,.suspended,"a withdrawn scenario offers no retry")
    }
    func testACommittedPlyResumesAtItsNodeAndHelpCoversTheWholeRun()throws {
        let fork=try forkScenario()
        let (session,player,controller)=try fixture([fork]);defer{player.shutdown()}
        controller.begin(try controller.prepare(entry:"simple-tactics"))
        controller.recordAgentHelp();controller.attempt(from:"b5",to:"c7",promotion:nil)
        let resumed=TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider(catalog:try TrainingCatalog.bundled(),scenarios:[fork]))
        resumed.begin(try resumed.prepareResume())
        let state=try XCTUnwrap(resumed.exercise)
        XCTAssertEqual(state.node,1);XCTAssertEqual(state.line,["b5c7","e8d7"]);XCTAssertEqual(state.board["c7"],"wn");XCTAssertTrue(state.snapshot.recordedHelp)
        resumed.attempt(from:"c7",to:"a6",promotion:nil)
        XCTAssertEqual(resumed.exercise?.status,.correct);XCTAssertEqual(session.state.training?.attempts.last?.firstTryNoRecordedHelp,false,"agent help on the first ply marks the whole run")
    }
}
