import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-011: forks and pins. Recognising a motif and winning with it are separate tasks: recognition answers are the
/// board's geometry; realisation answers are what the bounded search proves against every opponent reply.
@MainActor final class TrainingTacticTests:XCTestCase {
    // Increment B is gated behind its preview flags; these tests exercise it as development does.
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    private let review=TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion)
    private func definition()throws -> TrainingEntryDefinition {try XCTUnwrap(TrainingCatalog.bundled().entry("simple-tactics"))}
    private func recognize(_ check:TrainingCheck,_ fen:String,ask:String,squares:[String],noAction:Bool?=nil)->TrainingScenario {
        TrainingScenario(id:"recognize",entry:"simple-tactics",variant:check == .forks ? "fork-recognize":"pin-recognize",tier:1,cluster:"recognize",learner:"w",prompt:"Select them.",explanation:"Explained.",hints:["Concept."],fen:fen,expected:TrainingExpected(squares:squares),noAction:noAction,review:review,check:check,askColor:ask)
    }
    private func realize(_ fen:String,variant:String="fork-realize")throws -> TrainingScenario {
        let base=TrainingScenario(id:"realize",entry:"simple-tactics",variant:variant,tier:1,cluster:"realize",learner:String(fen.split(separator:" ")[1]),prompt:"Win material.",explanation:"Explained.",hints:["Concept."],fen:fen,review:review,check:.material,goal:TrainingGoal(kind:.gain,threshold:3),plies:3)
        let root=try TrainingContinuationValidator().classify(base,plies:3)
        return TrainingScenario(id:base.id,entry:base.entry,variant:base.variant,tier:1,cluster:base.cluster,learner:base.learner,prompt:base.prompt,explanation:base.explanation,hints:base.hints,fen:fen,review:review,check:.material,goal:base.goal,plies:3,nodes:[TrainingTeachingNode(fingerprint:try TrainingLegality(fen:fen).fingerprint(),accepted:root.accepted.sorted(),replies:root.replies)])
    }
    // The knight on b5 forks the king on e8 and the rook on a6 from c7; the pawns keep the ending from a bare draw.
    private let forkFEN="4k3/6p1/r7/1N6/8/8/6P1/4K3 w - - 0 1"
    // The same, with a bishop on b8 guarding c7: the fork is only a pattern.
    private let pseudoFEN="1b2k3/6p1/r7/1N6/8/8/6P1/4K3 w - - 0 1"
    func testRealisingAForkMustSurviveEveryReply()throws {
        let validator=try TrainingContinuationValidator()
        let fork=try validator.classify(try realize(forkFEN),plies:3)
        XCTAssertEqual(fork.accepted,["b5c7"]);XCTAssertEqual(fork.replies["b5c7"],"e8d7","the king steps away and the rook falls")
        let pseudo=try validator.classify(try realize(pseudoFEN),plies:3)
        XCTAssertEqual(pseudo.accepted,[],"the bishop takes the forking knight");XCTAssertEqual(pseudo.replies["b5c7"],"b8c7")
        XCTAssertEqual(try validator.bruteAccepted(try realize(forkFEN),plies:3),fork.accepted,"the search agrees with brute force")
        XCTAssertEqual(try validator.bruteAccepted(try realize(pseudoFEN),plies:3),pseudo.accepted)
        XCTAssertNoThrow(try TrainingValidationService.validate(try realize(forkFEN),definition:definition(),deep:true))
        XCTAssertThrowsError(try TrainingValidationService.validate(try realize(pseudoFEN),definition:definition(),deep:true),"no accepted move wins with a fork")
    }
    func testRecognitionAnswersAreTheGeometry()throws {
        let definition=try definition()
        let fork="7k/2N5/r3q3/8/8/8/8/7K w - - 0 1"
        XCTAssertNoThrow(try TrainingValidationService.validate(recognize(.forks,fork,ask:"w",squares:["c7"]),definition:definition))
        XCTAssertThrowsError(try TrainingValidationService.validate(recognize(.forks,fork,ask:"w",squares:[]),definition:definition),"the answer must match the board")
        // Two defended pawns are no fork: a no-action case, and it must say so.
        let none="7k/1pN2p2/p3p3/8/8/8/8/4K3 w - - 0 1"
        XCTAssertNoThrow(try TrainingValidationService.validate(recognize(.forks,none,ask:"w",squares:[],noAction:true),definition:definition))
        XCTAssertThrowsError(try TrainingValidationService.validate(recognize(.forks,none,ask:"w",squares:[]),definition:definition),"an empty answer is a no-action case")
        let pins="4r1k1/8/8/8/4N3/8/8/K3Q3 w - - 0 1"
        XCTAssertNoThrow(try TrainingValidationService.validate(recognize(.pins,pins,ask:"w",squares:["e4"]),definition:definition))
        XCTAssertThrowsError(try TrainingValidationService.validate(recognize(.pins,pins,ask:"b",squares:["e4"]),definition:definition),"Black has nothing pinned")
    }
    private func controller(_ scenarios:[TrainingScenario])throws -> (GameSession,LearningPlayer,TrainingController) {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        return (session,player,TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider(catalog:try TrainingCatalog.bundled(),scenarios:scenarios)))
    }
    func testRecognitionIsAnsweredBySelectingSquares()throws {
        let (session,player,training)=try controller([recognize(.forks,"7k/2N5/r3q3/8/8/8/8/7K w - - 0 1",ask:"w",squares:["c7"])]);defer{player.shutdown()}
        training.begin(try training.prepare(entry:"simple-tactics"))
        XCTAssertEqual(training.exercise?.task,.select)
        training.click("a6");training.submit()
        XCTAssertEqual(training.exercise?.status,.incorrect,"the attacked rook is not the forking piece")
        training.retry();training.click("c7");training.submit()
        XCTAssertEqual(training.exercise?.status,.correct);XCTAssertEqual(session.state.training?.attempts.count,2)
    }
    func testRealisationPlaysTheForkAndShowsTheReply()throws {
        let (_,player,training)=try controller([try realize(forkFEN)]);defer{player.shutdown()}
        training.begin(try training.prepare(entry:"simple-tactics"))
        training.attempt(from:"b5",to:"d6",promotion:nil)
        XCTAssertEqual(training.exercise?.status,.incorrect);XCTAssertTrue(training.exercise?.feedback.hasPrefix("After Rxd6") ?? false,"the refutation is shown")
        training.retry();training.attempt(from:"b5",to:"c7",promotion:nil)
        XCTAssertEqual(training.exercise?.status,.correct);XCTAssertEqual(training.exercise?.line,["b5c7","e8d7"])
    }
}
