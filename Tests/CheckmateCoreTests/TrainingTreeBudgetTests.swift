import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-009: every published Increment B answer is re-derived by the exact searches within the 32,000-position budget;
/// exhaustion or any tampering is rejected, and the search itself is pinned like chess.js.
@MainActor final class TrainingTreeBudgetTests:XCTestCase {
    func testEveryPublishedScenarioCertifiesWithinTheBudget()throws {
        let provider=try TrainingScenarioProvider.bundled()
        var largest=0,certified=0
        for definition in provider.catalog.entries(in:.beginner) {
            for scenario in provider.scenarios(for:definition.id) {
                XCTAssertNoThrow(try TrainingValidationService.validate(scenario,definition:definition,deep:true),scenario.id)
                if scenario.check?.searched==true {
                    let validator=try TrainingContinuationValidator()
                    XCTAssertNoThrow(try validator.certifyGraph(scenario,runtimeFactory:nil),scenario.id)
                    largest=max(largest,validator.nodes);certified+=1
                }
            }
        }
        XCTAssertLessThanOrEqual(largest,TrainingContinuationValidator.nodeCap)
        print("TRAINING-BUDGET searched=\(certified) largest=\(largest) cap=\(TrainingContinuationValidator.nodeCap)")
    }
    private func knight()throws -> TrainingScenario {
        let fen="4k3/8/8/8/3p4/2N5/6P1/4K3 w - - 0 1",goal=TrainingGoal(kind:.survive,threshold:0,target:"c3")
        let review=TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion)
        let probe=TrainingScenario(id:"knight",entry:"save-your-piece",variant:"move-away",tier:1,cluster:"k",learner:"w",prompt:"p",explanation:"e",hints:["h"],fen:fen,expected:TrainingExpected(wrong:["g2g3"]),review:review,check:.defense,goal:goal,plies:3)
        let root=try TrainingContinuationValidator().classify(probe,plies:3)
        return with(probe,[TrainingTeachingNode(fingerprint:try TrainingLegality(fen:fen).fingerprint(),accepted:root.accepted.sorted(),replies:root.replies)])
    }
    private func with(_ s:TrainingScenario,_ nodes:[TrainingTeachingNode])->TrainingScenario {
        TrainingScenario(id:s.id,entry:s.entry,variant:s.variant,tier:s.tier,cluster:s.cluster,learner:s.learner,prompt:s.prompt,explanation:s.explanation,hints:s.hints,fen:s.fen,expected:s.expected,review:s.review,check:s.check,goal:s.goal,plies:s.plies,nodes:nodes)
    }
    func testTamperedGraphsAndExhaustionAreRejected()throws {
        let good=try knight(),root=try XCTUnwrap(good.nodes?.first),definition=try XCTUnwrap(TrainingCatalog.bundled().entry("save-your-piece"))
        XCTAssertNoThrow(try TrainingValidationService.validate(good,definition:definition,deep:true))
        func rejects(_ nodes:[TrainingTeachingNode],_ reason:String,file:StaticString=#filePath,line:UInt=#line){
            XCTAssertThrowsError(try TrainingValidationService.validate(with(good,nodes),definition:definition,deep:true),file:file,line:line){XCTAssertTrue("\($0)".contains(reason),"\($0)",file:file,line:line)}
        }
        rejects([TrainingTeachingNode(fingerprint:root.fingerprint,accepted:root.accepted.filter{$0 != "c3e4"},replies:root.replies)],"accepted moves differ")
        var replies=root.replies;replies["g2g3"]="e8d8"
        rejects([TrainingTeachingNode(fingerprint:root.fingerprint,accepted:root.accepted,replies:replies)],"does not refute it")
        replies=root.replies;replies.removeValue(forKey:"c3e4")
        rejects([TrainingTeachingNode(fingerprint:root.fingerprint,accepted:root.accepted,replies:replies)],"replies for different moves")
        rejects([TrainingTeachingNode(fingerprint:"4k3/8/8/8/3p4/2N5/6P1/4K3 b - -",accepted:root.accepted,replies:root.replies)],"root fingerprint")
        XCTAssertThrowsError(try TrainingContinuationValidator(cap:40).certifyGraph(good,runtimeFactory:nil)){XCTAssertTrue("\($0)".contains("exceeded 40"),"exhaustion never certifies")}
    }
    func testTheSearchIsPinnedLikeTheRules()throws {
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("training/manifest.json"))) as! [String:Any]
        XCTAssertEqual(manifest["trainingSearch"] as? String,try reviewFileHash(NativeResources.url("training-search.js")),"content must be revalidated when the search changes")
    }
}
