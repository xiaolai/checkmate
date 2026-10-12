import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-013: mixed practice. Cases hide their topic until answered, accept every move that meets the common goal (also
/// off-theme ones), include cases where doing nothing special is right, and interleave topics.
@MainActor final class TrainingMixedSessionTests:XCTestCase {
    // Increment B is gated behind its preview flags; these tests exercise it as development does.
    override func setUp(){setenv("CHECKMATE_TRAINING_ENABLED","1",1);setenv("CHECKMATE_TRAINING_B","1",1)}
    override func tearDown(){unsetenv("CHECKMATE_TRAINING_ENABLED");unsetenv("CHECKMATE_TRAINING_B")}
    private func mixed()throws -> (TrainingScenarioProvider,[TrainingScenario]) {let provider=try TrainingScenarioProvider.bundled();return (provider,provider.scenarios(for:"mixed-practice"))}
    func testTheCaseSetMeetsTheMatrix()throws {
        let (provider,cases)=try mixed()
        XCTAssertGreaterThanOrEqual(cases.count,48)
        for skill in [TrainingSkill.movement,.attackProtection,.threatResponse,.captureExchange,.checkMateDraw,.specialRules,.elementaryTactics,.diagnosis] {
            XCTAssertGreaterThanOrEqual(cases.filter{$0.skills?.contains(skill)==true}.count,4,skill.rawValue)
        }
        let primary=Dictionary(grouping:cases,by:{$0.primarySkill!}).mapValues(\.count)
        XCTAssertLessThanOrEqual(primary.values.max() ?? 0,cases.count/4,"no row holds more than a quarter")
        // Reused positions name their published source and keep its novelty cluster.
        for item in cases {
            let source=try XCTUnwrap(item.source.flatMap{provider.scenario($0)},"\(item.id) names its source")
            XCTAssertEqual(source.fen,item.fen);XCTAssertEqual(source.cluster,item.cluster)
        }
        XCTAssertGreaterThanOrEqual(cases.filter{$0.noAction==true}.count,3,"some cases reward not acting")
    }
    func testNoTopicIsShownBeforeTheAnswer()throws {
        let (_,cases)=try mixed()
        let neutral=["Make a move that does not give away material.","Win material, or give checkmate.","What needs your attention here? Choose one answer that applies."]
        for item in cases where [.material,.diagnosis].contains(item.check) {
            XCTAssertTrue(neutral.contains{item.prompt.hasSuffix($0)},"\(item.id): \(item.prompt)")
            XCTAssertNil(item.focus,"no squares are pointed at");XCTAssertNil(item.goal?.target)
            for word in ["fork","pin","defend","protect","exchange","trade","castl","threat","attack"] {XCTAssertFalse((item.prompt+item.hints.joined()).lowercased().contains(word),"\(item.id) leaks \(word)")}
        }
    }
    func testReusedPositionsAcceptStrongerOffThemeMoves()throws {
        let (provider,cases)=try mixed()
        for item in cases where item.check == .material && item.goal?.kind == .hold && item.noAction != true {
            let source=try XCTUnwrap(provider.scenario(item.source!))
            guard source.check == .defense,let saving=source.nodes?.first?.accepted,let accepted=item.nodes?.first?.accepted else{continue}
            // Every move that saved the piece still keeps material; some other moves may too.
            XCTAssertTrue(Set(saving).isSubset(of:Set(accepted)),"\(item.id) rejects a move that saved the piece")
        }
    }
    func testTopicsInterleave(){
        func make(_ id:String,_ skill:TrainingSkill)->TrainingScenario {TrainingScenario(id:id,entry:"mixed-practice",variant:"mixed",tier:1,cluster:id,learner:"w",prompt:"",explanation:"",hints:[],skills:[skill],primarySkill:skill)}
        let pool=[make("a",.captureExchange),make("b",.captureExchange),make("c",.specialRules),make("d",.movement)]
        XCTAssertEqual(TrainingMixedController.order(pool,seen:[],previous:.captureExchange).map(\.id),["c","d","a","b"],"another topic comes first")
        XCTAssertEqual(TrainingMixedController.order(pool,seen:["c"],previous:.captureExchange).map(\.id),["d","a","b","c"],"fresh before seen")
        XCTAssertEqual(TrainingMixedController.order(pool,seen:[],previous:nil).map(\.id),["a","b","c","d"])
    }
    private func controller(_ scenarios:[TrainingScenario])throws -> (GameSession,LearningPlayer,TrainingController) {
        let session=try GameSession(engine:nil),player=try LearningPlayer(session:session)
        return (session,player,TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider(catalog:try TrainingCatalog.bundled(),scenarios:scenarios)))
    }
    func testADiagnosisAsksForTheConcernThenTheMove()throws {
        let (_,cases)=try mixed()
        let item=try XCTUnwrap(cases.first{$0.check == .diagnosis && $0.expected?.choices?.contains(TrainingConcern.mateThreat.label)==true})
        let (_,player,training)=try controller([item]);defer{player.shutdown()}
        training.begin(try training.prepare(entry:"mixed-practice"))
        XCTAssertEqual(training.exercise?.task,.choose);XCTAssertEqual(training.exercise?.feedback,"","no feedback before an answer")
        training.choose(TrainingConcern.mateThreat.label)
        XCTAssertEqual(training.exercise?.task,.move,"a genuine concern leads to the action");XCTAssertFalse(training.exercise?.finished ?? true)
        let move=try XCTUnwrap(item.nodes?.first?.accepted.first)
        training.attempt(from:String(move.prefix(2)),to:String(move.dropFirst(2).prefix(2)),promotion:move.count==5 ? String(move.suffix(1)):nil)
        XCTAssertEqual(training.exercise?.status,.correct);XCTAssertTrue(training.exercise?.feedback.contains("What mattered here") ?? false,"the explanation comes after the answer")
        training.retry();training.choose(TrainingConcern.none.label)
        XCTAssertEqual(training.exercise?.status,.incorrect,"Nothing urgent is wrong when the opponent threatens mate")
    }
    func testDecliningACaptureIsTheRightAnswer()throws {
        let (_,cases)=try mixed()
        let item=try XCTUnwrap(cases.first{$0.check == .material && $0.noAction==true})
        let legality=try TrainingLegality(fen:item.fen!,prelude:item.prelude ?? [])
        let capture=try XCTUnwrap(legality.outcomes().first{$0.captured != nil})
        let quiet=try XCTUnwrap(item.nodes?.first?.accepted.first)
        let (_,player,training)=try controller([item]);defer{player.shutdown()}
        training.begin(try training.prepare(entry:"mixed-practice"))
        training.attempt(from:capture.from,to:capture.to,promotion:capture.promotion)
        XCTAssertEqual(training.exercise?.status,.incorrect,"the tempting capture loses material")
        training.retry();training.attempt(from:String(quiet.prefix(2)),to:String(quiet.dropFirst(2).prefix(2)),promotion:quiet.count==5 ? String(quiet.suffix(1)):nil)
        XCTAssertEqual(training.exercise?.status,.correct)
    }
}
