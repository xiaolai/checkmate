import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-009: Capture Wisely. A stated exchange is judged by the sign of its resolved material change; a declined capture
/// is a no-action case; every published answer is re-derived.
@MainActor final class TrainingExchangeTests:XCTestCase {
    // Increment B is gated behind its preview flags; these tests exercise it as development does.
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    private let review=TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion)
    private func exchange(_ fen:String,_ stated:[String],choice:String?=nil)->TrainingScenario {
        TrainingScenario(id:"exchange-test",entry:"capture-wisely",variant:"compare-exchange",tier:1,cluster:"x",learner:String(fen.split(separator:" ")[1]),prompt:"Ahead, even or behind?",explanation:"Count.",hints:["Count."],fen:fen,choices:TrainingExchangeResult.choices,expected:TrainingExpected(choice:choice),review:review,check:.exchange,stated:stated)
    }
    private var definition:TrainingEntryDefinition {get throws {try XCTUnwrap(TrainingCatalog.bundled().entry("capture-wisely"))}}
    func testStatedLinesResolveToTheirSign()throws {
        let validator=try TrainingContinuationValidator()
        for (fen,stated,sign) in [
            ("4k3/8/8/3n4/8/8/3R4/4K3 w - - 0 1",["d2d5"],1),                // an undefended knight
            ("4k3/2p5/3n4/8/4N3/8/8/4K3 w - - 0 1",["e4d6"],0),              // knight for knight
            ("4k3/2p5/3n4/8/4N3/8/8/4K3 w - - 0 1",["e4d6","c7d6"],0),       // the recapture stated too
            ("4k3/8/2p5/3p4/8/8/8/3QK3 w - - 0 1",["d1d5"],-1),              // queen for a pawn
            ("3r2k1/8/4p3/3n4/8/8/3R4/3RK3 w - - 0 1",["d2d5"],-1),          // stopping after exd5 is still behind
            ("3qk3/8/8/8/3P4/4P3/8/4K3 b - - 0 1",["d8d4"],-1),              // Black's queen for a pawn
            ("4k3/8/5b2/8/3N4/4P3/8/4K3 b - - 0 1",["f6d4"],0)] {            // Black's bishop for a knight
            XCTAssertEqual(try validator.exchangeSign(exchange(fen,stated)),sign,"\(fen) \(stated)")
        }
    }
    /// Owner decision D2: classification reports the resolved material delta. A line that ends in mate or stalemate is
    /// a leaf scored by its material, never by who is mated, for either learner colour.
    func testTerminalLinesAreClassifiedByMaterial()throws {
        let validator=try TrainingContinuationValidator()
        for (fen,stated,sign) in [
            // Qxd8 wins a rook (+5), then Qxg2# mates the learner: still four points up, so ahead.
            ("3r4/1b5k/6q1/8/8/8/6PP/3Q3K w - - 0 1",["d1d8"],1),
            ("3q3k/6pp/8/8/8/6Q1/1B5K/3R4 b - - 0 1",["d8d1"],1),
            // Qxg8+ Rxg8 Nf7#: the learner mates, but a queen went for a bishop (-6), so behind.
            ("3r2bk/6pp/7N/8/2Q5/8/8/1K6 w - - 0 1",["c4g8","d8g8","h6f7"],-1),
            ("1k6/8/8/2q5/8/7n/6PP/3R2BK b - - 0 1",["c5g1","d1g1","h3f2"],-1),
            // Qxg6 wins a rook and stalemates: the stalemated leaf is scored (+5), not skipped as a draw.
            ("7k/5K2/6r1/8/8/8/8/6Q1 w - - 0 1",["g1g6"],1),
            ("6q1/8/8/8/8/6R1/5k2/7K b - - 0 1",["g8g3"],1)] {
            XCTAssertEqual(try validator.exchangeSign(exchange(fen,stated)),sign,"\(fen) \(stated)")
        }
    }
    /// Owner decision D2: exercise goals keep mate precedence over material. The same positions as above: gaining the
    /// rook while being mated fails the goal, and delivering mate at a material deficit meets it.
    func testGoalsKeepMatePrecedenceOverMaterial()throws {
        func classify(_ fen:String)throws -> (accepted:Set<String>,rejected:Set<String>,replies:[String:String]) {
            let probe=TrainingScenario(id:"mate-precedence",entry:"capture-wisely",variant:"poisoned-capture",tier:1,cluster:"m",learner:String(fen.split(separator:" ")[1]),prompt:"Win material.",explanation:"Mate decides.",hints:["Mate."],fen:fen,expected:TrainingExpected(wrong:[]),review:review,check:.material,goal:TrainingGoal(kind:.gain,threshold:1),plies:3)
            return try TrainingContinuationValidator().classify(probe,plies:3)
        }
        for (fen,capture,mate) in [("3r4/1b5k/6q1/8/8/8/6PP/3Q3K w - - 0 1","d1d8","g6g2"),("3q3k/6pp/8/8/8/6Q1/1B5K/3R4 b - - 0 1","d8d1","g3g7")] {
            let root=try classify(fen)
            XCTAssertTrue(root.rejected.contains(capture),"\(fen): winning the rook into mate fails the goal")
            XCTAssertEqual(root.replies[capture],mate,"\(fen): the mate is the refutation")
        }
        for (fen,sacrifice) in [("3r2bk/6pp/7N/8/2Q5/8/8/1K6 w - - 0 1","c4g8"),("1k6/8/8/2q5/8/7n/6PP/3R2BK b - - 0 1","c5g1")] {
            XCTAssertTrue(try classify(fen).accepted.contains(sacrifice),"\(fen): the queen sacrifice that mates meets the goal")
        }
    }
    func testTheExchangeQuestionIsGradedOnTheResolvedSign()throws {
        let good=exchange("4k3/2p5/3n4/8/4N3/8/8/4K3 w - - 0 1",["e4d6"],choice:TrainingExchangeResult.even.label)
        XCTAssertNoThrow(try TrainingValidationService.validate(good,definition:try definition,deep:true))
        let wrong=exchange("4k3/2p5/3n4/8/4N3/8/8/4K3 w - - 0 1",["e4d6"],choice:TrainingExchangeResult.ahead.label)
        XCTAssertNoThrow(try TrainingValidationService.validate(wrong,definition:try definition),"the sign needs the search, which runs offline")
        XCTAssertThrowsError(try TrainingValidationService.validate(wrong,definition:try definition,deep:true)){XCTAssertTrue("\($0)".contains("exchange result differs"))}
        XCTAssertThrowsError(try TrainingValidationService.validate(exchange("4k3/2p5/3n4/8/4N3/8/8/4K3 w - - 0 1",["e1d1"],choice:TrainingExchangeResult.even.label),definition:try definition)){XCTAssertTrue("\($0)".contains("starts with the learner's capture"))}
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session);defer{player.shutdown()}
        let controller=TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider(catalog:try TrainingCatalog.bundled(),scenarios:[good]))
        controller.begin(try controller.prepare(entry:"capture-wisely"))
        XCTAssertEqual(controller.exercise?.task,.choose);XCTAssertEqual(session.training?.choices ?? [],TrainingExchangeResult.choices)
        controller.attempt(from:"e4",to:"d6",promotion:nil);XCTAssertTrue(controller.exercise?.snapshot.actions.isEmpty ?? false,"a choice question takes no moves")
        controller.choose(TrainingExchangeResult.ahead.label)
        XCTAssertEqual(controller.exercise?.status,.incorrect);XCTAssertTrue(controller.exercise?.feedback.contains(TrainingExchangeResult.even.label) ?? false,"feedback after the answer names the result")
        controller.retry();controller.choose(TrainingExchangeResult.even.label);XCTAssertEqual(controller.exercise?.status,.correct)
    }
    func testADeclinedCaptureIsANoActionCase()throws {
        // Qxd5 is answered by cxd5: every capture loses, so any safe quiet move is right.
        let fen="4k3/8/2p5/3p4/8/8/8/3QK3 w - - 0 1",goal=TrainingGoal(kind:.hold,threshold:0)
        let probe=TrainingScenario(id:"declined",entry:"capture-wisely",variant:"poisoned-capture",tier:1,cluster:"d",learner:"w",prompt:"Do not give material away.",explanation:"Every capture loses.",hints:["Recaptures."],fen:fen,expected:TrainingExpected(wrong:["d1d5"]),noAction:true,review:review,check:.material,goal:goal,plies:3)
        let validator=try TrainingContinuationValidator(),root=try validator.classify(probe,plies:3)
        XCTAssertFalse(root.accepted.contains("d1d5"));XCTAssertTrue(root.accepted.contains("d1d3"),"a quiet move that keeps the queen");XCTAssertEqual(root.replies["d1d5"],"c6d5")
        let scenario=TrainingScenario(id:"declined",entry:"capture-wisely",variant:"poisoned-capture",tier:1,cluster:"d",learner:"w",prompt:"Do not give material away.",explanation:"Every capture loses.",hints:["Recaptures."],fen:fen,expected:TrainingExpected(wrong:["d1d5"]),noAction:true,review:review,check:.material,goal:goal,plies:3,nodes:[TrainingTeachingNode(fingerprint:try TrainingLegality(fen:fen).fingerprint(),accepted:root.accepted.sorted(),replies:root.replies)])
        XCTAssertNoThrow(try TrainingValidationService.validate(scenario,definition:try definition,deep:true))
        let unmarked=TrainingScenario(id:"declined",entry:"capture-wisely",variant:"poisoned-capture",tier:1,cluster:"d",learner:"w",prompt:"p",explanation:"e",hints:["h"],fen:fen,expected:TrainingExpected(wrong:["d1e2"]),review:review,check:.material,goal:goal,plies:3,nodes:scenario.nodes)
        XCTAssertThrowsError(try TrainingValidationService.validate(unmarked,definition:try definition)){XCTAssertTrue("\($0)".contains("tempting capture"),"the named temptation must be a failing capture")}
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session);defer{player.shutdown()}
        let controller=TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider(catalog:try TrainingCatalog.bundled(),scenarios:[scenario]))
        controller.begin(try controller.prepare(entry:"capture-wisely"))
        controller.attempt(from:"d1",to:"d5",promotion:nil)
        XCTAssertEqual(controller.exercise?.status,.incorrect);XCTAssertEqual(controller.exercise?.board["d5"],"bp","the recapture is shown")
        controller.retry();controller.attempt(from:"d1",to:"d3",promotion:nil);XCTAssertEqual(controller.exercise?.status,.correct)
    }
}
