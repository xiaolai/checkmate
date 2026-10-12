import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-010: castling, promotion and en passant under the pinned chess.js, with their history. Raw illegal attempts are
/// rule errors that never move a piece; cancelling the promotion chooser is a selection correction.
@MainActor final class TrainingSpecialMoveTests:XCTestCase {
    // Increment B is gated behind its preview flags; these tests exercise it as development does.
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    private let review=TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion)
    private func reasons(_ fen:String,_ prelude:[String]=[],to destination:String)throws -> Set<TrainingCastleReason> {try TrainingSpecialRules.castleReasons(TrainingLegality(fen:fen,prelude:prelude),destination:destination)}
    private func passant(_ fen:String,_ prelude:[String],_ target:String)throws -> Set<TrainingPassantReason> {try TrainingSpecialRules.passantReasons(TrainingLegality(fen:fen,prelude:prelude),target:target,prelude:prelude)}
    func testCastlingReasonsForBothColours()throws {
        XCTAssertEqual(try reasons("4k3/8/8/8/8/8/5PPP/4K2R w K - 0 1",to:"g1"),[.allowed])
        XCTAssertEqual(try reasons("r3k3/ppp5/8/8/8/8/8/4K3 b q - 0 1",to:"c8"),[.allowed])
        // The king went to f1 and back: the right is gone for good, though the king is home again.
        XCTAssertEqual(try reasons("4k3/8/8/8/8/8/5PPP/4K2R w K - 0 1",["e1f1","e8d8","f1e1","d8e8"],to:"g1"),[.moved])
        XCTAssertEqual(try reasons("4k3/8/8/8/8/8/5PPP/4K2R w K - 0 1",["h1g1","e8d8","g1h1","d8e8"],to:"g1"),[.moved],"the rook moved and came back")
        XCTAssertEqual(try reasons("4k3/8/8/8/8/8/5PPP/4KB1R w K - 0 1",to:"g1"),[.blocked])
        XCTAssertEqual(try reasons("4r1k1/8/8/8/8/8/5PPP/4K2R w K - 0 1",to:"g1"),[.check])
        XCTAssertEqual(try reasons("4kr2/8/8/8/8/8/6PP/4K2R w K - 0 1",to:"g1"),[.transit])
        XCTAssertEqual(try reasons("4k1r1/8/8/8/8/8/5P1P/4K2R w K - 0 1",to:"g1"),[.destination])
        XCTAssertEqual(try reasons("4k3/8/8/7b/8/8/PPP5/R3K3 w Q - 0 1",to:"c1"),[.transit],"d1 is crossed on the queenside")
        XCTAssertEqual(try reasons("1r2k3/8/8/8/8/8/P4PPP/R3K2R w KQ - 0 1",to:"c1"),[.allowed],"b1 may be attacked: the king never uses it")
        XCTAssertEqual(try reasons("rnbqk2r/8/8/8/8/8/8/R3K1R1 b kq - 0 1",to:"g8"),[.destination],"Black's g8 is attacked down the open file")
        // Several reasons at once form a set; curated questions must have exactly one.
        XCTAssertEqual(try reasons("4kr2/8/8/8/8/8/6PP/4KB1R w K - 0 1",to:"g1"),[.blocked,.transit])
        XCTAssertThrowsError(try reasons("4k3/8/8/8/8/8/8/4K2R w K - 0 1",to:"g8"),"the destination must be on the mover's back rank")
    }
    private func castle(_ fen:String,wrong:[String],prelude:[String]?=nil)throws -> TrainingScenario {
        let legality=try TrainingLegality(fen:fen,prelude:prelude ?? [])
        return TrainingScenario(id:"castle-test",entry:"special-moves",variant:"castle-legal",tier:1,cluster:"c",learner:try legality.turn(),prompt:"Castle.",explanation:"Castling.",hints:["Rules."],fen:fen,prelude:prelude,expected:TrainingExpected(wrong:wrong),review:review,check:.castle,nodes:[TrainingTeachingNode(fingerprint:try legality.fingerprint(),accepted:try TrainingSpecialRules.castlingMoves(legality).sorted(),replies:[:])])
    }
    private func controller(_ scenarios:[TrainingScenario])throws -> (GameSession,LearningPlayer,TrainingController) {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        return (session,player,TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider(catalog:try TrainingCatalog.bundled(),scenarios:scenarios)))
    }
    func testCastlingIsGradedAsARuleNotByLegalMoveFiltering()throws {
        let definition=try XCTUnwrap(TrainingCatalog.bundled().entry("special-moves"))
        let scenario=try castle("4k3/8/8/8/8/8/PPPPPPPP/RN2K2R w KQ - 0 1",wrong:["e1h1","e1c1"])
        XCTAssertNoThrow(try TrainingValidationService.validate(scenario,definition:definition))
        XCTAssertEqual(scenario.nodes?.first?.accepted,["e1g1"],"queenside is blocked by the knight")
        let (session,player,training)=try controller([scenario]);defer{player.shutdown()}
        // King onto its own rook is not castling: a rule error, and nothing moves.
        training.begin(try training.prepare(entry:"special-moves"))
        training.click("e1");training.click("h1")
        XCTAssertEqual(training.exercise?.status,.incorrect);XCTAssertEqual(training.exercise?.board["e1"],"wk");XCTAssertTrue(training.exercise?.feedback.contains("two squares towards the rook") ?? false)
        // Raw illegal castling through the knight is a rule error too.
        training.retry();training.attempt(from:"e1",to:"c1",promotion:nil)
        XCTAssertEqual(training.exercise?.status,.incorrect);XCTAssertTrue(training.exercise?.feedback.contains("Castling is not allowed here") ?? false);XCTAssertEqual(training.exercise?.board["e1"],"wk")
        // A legal move that is not castling is wrong for this task.
        training.retry();training.attempt(from:"h2",to:"h3",promotion:nil)
        XCTAssertEqual(training.exercise?.status,.incorrect);XCTAssertTrue(training.exercise?.feedback.contains("not castling") ?? false)
        training.retry();training.attempt(from:"e1",to:"g1",promotion:nil)
        XCTAssertEqual(training.exercise?.status,.correct);XCTAssertEqual(training.exercise?.board["f1"],"wr","the rook jumps over the king")
        XCTAssertEqual(session.state.training?.attempts.count,4)
        XCTAssertThrowsError(try TrainingValidationService.validate(try castle("4k3/8/8/8/8/8/PPPPPPPP/RN2K2R w KQ - 0 1",wrong:["e1g1"]),definition:definition),"a legal castling move is no wrong attempt")
    }
    func testEveryPromotionPieceIsAcceptedAndCancellingIsNotCounted()throws {
        let fen="3r4/4P3/8/8/8/8/k7/6K1 w - - 0 1",legality=try TrainingLegality(fen:fen)
        let promotions=try TrainingSpecialRules.promotions(legality)
        XCTAssertEqual(promotions,["e7d8q","e7d8r","e7d8b","e7d8n","e7e8q","e7e8r","e7e8b","e7e8n"],"pushing and capturing, every piece")
        let scenario=TrainingScenario(id:"promote-test",entry:"special-moves",variant:"promotion",tier:1,cluster:"p",learner:"w",prompt:"Promote.",explanation:"Promotion.",hints:["Rules."],fen:fen,review:review,check:.promotion,nodes:[TrainingTeachingNode(fingerprint:try legality.fingerprint(),accepted:promotions.sorted(),replies:[:])])
        XCTAssertNoThrow(try TrainingValidationService.validate(scenario,definition:try XCTUnwrap(TrainingCatalog.bundled().entry("special-moves"))))
        let (_,player,training)=try controller([scenario]);defer{player.shutdown()}
        training.begin(try training.prepare(entry:"special-moves"))
        training.attempt(from:"e7",to:"e8",promotion:nil)
        XCTAssertNotNil(training.exercise?.pendingPromotion);XCTAssertTrue(training.exercise?.snapshot.actions.isEmpty ?? false)
        training.cancelPromotion()
        XCTAssertNil(training.exercise?.pendingPromotion);XCTAssertFalse(training.exercise?.finished ?? true);XCTAssertTrue(training.exercise?.snapshot.actions.isEmpty ?? false,"a cancelled chooser counts nothing")
        training.attempt(from:"e7",to:"d8",promotion:"n")
        XCTAssertEqual(training.exercise?.status,.correct,"an underpromotion is a legal promotion");XCTAssertEqual(training.exercise?.board["d8"],"wn")
    }
    func testEnPassantTimingHistoryAndKingSafety()throws {
        XCTAssertEqual(try passant("4k3/3p4/8/4P3/8/8/8/4K3 b - - 0 1",["d7d5"],"d5"),[.allowed])
        XCTAssertEqual(try passant("4k3/8/8/8/4p3/8/5P2/4K3 w - - 0 1",["f2f4"],"f4"),[.allowed],"Black captures en passant too")
        XCTAssertEqual(try passant("4k3/8/3p4/4P3/8/8/8/4K3 b - - 0 1",["d6d5"],"d5"),[.notDouble])
        XCTAssertEqual(try passant("4k3/3p4/8/4P3/8/8/8/4K3 b - - 0 1",["d7d5","e1d1","e8d8"],"d5"),[.expired])
        XCTAssertEqual(try passant("4k3/3p4/8/K3P2r/8/8/8/8 b - - 0 1",["d7d5"],"d5"),[.exposesKing],"both pawns leave the rank and the rook checks the king")
        XCTAssertEqual(try passant("4k3/3p4/8/1P6/8/8/8/4K3 b - - 0 1",["d7d5"],"d5"),[.notBeside])
        XCTAssertThrowsError(try passant("4k3/8/8/3pP3/8/8/8/4K3 w - - 0 1",[],"d5"),"without history, timing cannot be judged")
    }
    func testTheEffectiveEnPassantStateRoundTripsAndSeparatesClusters()throws {
        // After the two-square step the position carries its en-passant square; replaying the FEN gives the same capture.
        let available=try TrainingLegality(fen:"4k3/3p4/8/4P3/8/8/8/4K3 b - - 0 1",prelude:["d7d5"])
        XCTAssertEqual(available.fen.split(separator:" ")[3],"d6")
        XCTAssertEqual(try TrainingSpecialRules.enPassantMoves(TrainingLegality(fen:available.fen)),["e5d6"])
        // The same pieces a move pair later: the board matches, the rule state does not.
        let expired=try TrainingLegality(fen:"4k3/3p4/8/4P3/8/8/8/4K3 b - - 0 1",prelude:["d7d5","e1d1","e8d8","d1e1","d8e8"])
        XCTAssertEqual(try available.board(),try expired.board())
        XCTAssertNotEqual(try available.fingerprint(),try expired.fingerprint(),"a rule-state difference is a different position")
        XCTAssertEqual(try TrainingSpecialRules.enPassantMoves(expired),[])
    }
    func testAnEnPassantQuestionIsANoActionChoiceWithOneReason()throws {
        let definition=try XCTUnwrap(TrainingCatalog.bundled().entry("special-moves"))
        func question(_ prelude:[String],_ choice:TrainingPassantReason,noAction:Bool=true)->TrainingScenario {
            TrainingScenario(id:"ep-test",entry:"special-moves",variant:"en-passant-unavailable",tier:1,cluster:"e",learner:"w",prompt:"Can you?",explanation:"Timing.",hints:["Rules."],fen:"4k3/3p4/8/4P3/8/8/8/4K3 b - - 0 1",prelude:prelude,target:"d5",choices:TrainingPassantReason.choices,expected:TrainingExpected(choice:choice.label),noAction:noAction,review:review,check:.enPassantChoice)
        }
        XCTAssertNoThrow(try TrainingValidationService.validate(question(["d7d5","e1d1","e8d8"],.expired),definition:definition))
        XCTAssertThrowsError(try TrainingValidationService.validate(question(["d7d5","e1d1","e8d8"],.notDouble),definition:definition))
        XCTAssertThrowsError(try TrainingValidationService.validate(question(["d7d5","e1d1","e8d8"],.expired,noAction:false),definition:definition),"declining is the right action")
        let (_,player,training)=try controller([question(["d7d5","e1d1","e8d8"],.expired)]);defer{player.shutdown()}
        training.begin(try training.prepare(entry:"special-moves"))
        XCTAssertEqual(training.exercise?.task,.choose)
        training.choose(TrainingPassantReason.allowed.label);XCTAssertEqual(training.exercise?.status,.incorrect)
        training.retry();training.choose(TrainingPassantReason.expired.label);XCTAssertEqual(training.exercise?.status,.correct)
    }
}
