import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-011: creating and preventing an immediate mating threat. A created threat is a mate the learner could give next
/// move if the opponent did nothing; a prevented one leaves no reply that mates. Both are exact one-move queries.
@MainActor final class TrainingMateThreatTests:XCTestCase {
    // Increment B is gated behind its preview flags; these tests exercise it as development does.
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    private let review=TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion)
    private func scenario(_ fen:String,create:Bool)throws -> TrainingScenario {
        let base=TrainingScenario(id:"threat",entry:"simple-tactics",variant:create ? "mate-threat-create":"mate-threat-prevent",tier:1,cluster:"threat",learner:String(fen.split(separator:" ")[1]),prompt:"Threat.",explanation:"Explained.",hints:["Concept."],fen:fen,review:review,check:create ? .mateThreatCreate:.mateThreatPrevent)
        let found=try TrainingContinuationValidator().threat(base,create:create)
        return TrainingScenario(id:base.id,entry:base.entry,variant:base.variant,tier:1,cluster:base.cluster,learner:base.learner,prompt:base.prompt,explanation:base.explanation,hints:base.hints,fen:fen,review:review,check:base.check,nodes:[TrainingTeachingNode(fingerprint:try TrainingLegality(fen:fen).fingerprint(),accepted:found.accepted.sorted(),replies:found.replies)])
    }
    private func definition()throws -> TrainingEntryDefinition {try XCTUnwrap(TrainingCatalog.bundled().entry("simple-tactics"))}
    // The rook on c3 sits behind its own pawn; on any open file it threatens mate on the back rank.
    private let createFEN="6k1/5ppp/8/8/2P5/2R5/5PPP/6K1 w - - 0 1"
    // Black's rook threatens Rd1 mate; making room for the king, or covering f1, stops it.
    private let preventFEN="3r2k1/5ppp/8/8/8/8/5PPP/6K1 w - - 0 1"
    func testCreatingAThreatForBothColours()throws {
        let white=try TrainingContinuationValidator().threat(try scenario(createFEN,create:true),create:true)
        XCTAssertEqual(Set(white.accepted),["c3a3","c3b3","c3d3","c3e3"]);XCTAssertFalse(white.opponentThreat)
        XCTAssertTrue(white.rejected.contains("c3f3"),"the f-file is closed by Black's own pawn on f7")
        let black=try TrainingContinuationValidator().threat(try scenario("6k1/5ppp/2r5/2p5/8/8/5PPP/6K1 b - - 0 1",create:true),create:true)
        XCTAssertEqual(Set(black.accepted),["c6a6","c6b6","c6d6","c6e6"])
        XCTAssertNoThrow(try TrainingValidationService.validate(try scenario(createFEN,create:true),definition:definition(),deep:true))
    }
    func testAMateInOneIsNotAThreatTask()throws {
        // With Rb8 mate on the board, "threaten mate" would reward missing the mate.
        XCTAssertThrowsError(try TrainingValidationService.validate(try scenario("6k1/5ppp/8/8/8/8/1R3PPP/6K1 w - - 0 1",create:true),definition:definition()))
    }
    func testPreventingAThreatChecksEveryReply()throws {
        let found=try TrainingContinuationValidator().threat(try scenario(preventFEN,create:false),create:false)
        XCTAssertTrue(found.opponentThreat)
        XCTAssertEqual(Set(found.accepted),["f2f3","f2f4","g1f1","g2g3","g2g4","h2h3","h2h4"])
        XCTAssertEqual(found.rejected,["g1h1"]);XCTAssertEqual(found.replies["g1h1"],"d8d1","the mating reply is the refutation")
        XCTAssertNoThrow(try TrainingValidationService.validate(try scenario(preventFEN,create:false),definition:definition(),deep:true))
        // Without a threat there is nothing to prevent.
        XCTAssertThrowsError(try TrainingValidationService.validate(try scenario("6k1/5ppp/8/8/8/8/5PPP/6K1 w - - 0 1",create:false),definition:definition(),deep:true))
    }
    func testThePreventingMoveIsPlayedAgainstThePublishedReply()throws {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session);defer{player.shutdown()}
        let training=TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider(catalog:try TrainingCatalog.bundled(),scenarios:[try scenario(preventFEN,create:false)]))
        training.begin(try training.prepare(entry:"simple-tactics"))
        training.attempt(from:"g1",to:"h1",promotion:nil)
        XCTAssertEqual(training.exercise?.status,.incorrect);XCTAssertTrue(training.exercise?.feedback.hasPrefix("After Rd1#") ?? false)
        training.retry();training.attempt(from:"h2",to:"h3",promotion:nil)
        XCTAssertEqual(training.exercise?.status,.correct)
    }
}
