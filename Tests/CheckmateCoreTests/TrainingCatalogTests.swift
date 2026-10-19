import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// Every published scenario is re-derived by the exact Swift evaluators (the Python packager checks structure only).
@MainActor final class TrainingCatalogTests:XCTestCase {
    func testEveryPublishedScenarioValidates()throws {
        let provider=try TrainingScenarioProvider.bundled()
        var counted:[String:Int]=[:]
        for definition in provider.catalog.entries {
            for scenario in provider.scenarios(for:definition.id) {
                XCTAssertNoThrow(try TrainingValidationService.validate(scenario,definition:definition),scenario.id)
                counted[definition.id,default:0]+=1
                XCTAssertNil(scenario.review?.reviewer,"\(scenario.id): no editor has reviewed this content yet; the record must say so")
            }
        }
        print("TRAINING-CONTENT "+counted.sorted{$0.key<$1.key}.map{"\($0.key)=\($0.value)"}.joined(separator:" "))
    }
    /// Move objectives and diagnosis ship a teaching graph; every other choice question must not.
    func testOnlyMoveObjectivesAndDiagnosisCarryATeachingGraph()throws {
        let provider=try TrainingScenarioProvider.bundled()
        let all=provider.catalog.entries.flatMap{definition in provider.scenarios(for:definition.id).map{(definition,$0)}}
        func edited(_ scenario:TrainingScenario,nodes:Any?)throws -> TrainingScenario {
            var raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(scenario)) as! [String:Any]
            raw["nodes"]=nodes
            return try JSONDecoder().decode(TrainingScenario.self,from:JSONSerialization.data(withJSONObject:raw))
        }
        let (diagnosisEntry,diagnosis)=try XCTUnwrap(all.first{$0.1.check == .diagnosis})
        let graph=try XCTUnwrap((JSONSerialization.jsonObject(with:JSONEncoder().encode(diagnosis)) as! [String:Any])["nodes"])
        XCTAssertThrowsError(try edited(diagnosis,nodes:nil).validateStructure(for:diagnosisEntry),"a diagnosis without its graph is refused")
        let (choiceEntry,choice)=try XCTUnwrap(all.first{$0.1.check?.task == .choose && $0.1.check != .diagnosis})
        XCTAssertNoThrow(try choice.validateStructure(for:choiceEntry))
        XCTAssertThrowsError(try edited(choice,nodes:graph).validateStructure(for:choiceEntry),"\(choice.id): a non-diagnosis choice carrying a graph is refused")
    }
    func testMateInOnePoolMeetsItsPilotContract()throws {
        let provider=try TrainingScenarioProvider.bundled(),mates=provider.scenarios(for:"mate-in-one")
        let practice=mates.filter{$0.reserve != true},reserve=mates.filter{$0.reserve==true}
        XCTAssertGreaterThanOrEqual(practice.count,30);XCTAssertGreaterThanOrEqual(Set(reserve.map(\.cluster)).count,10,"ten reserved clusters for later fresh practice")
        XCTAssertTrue(Set(practice.map(\.cluster)).isDisjoint(with:Set(reserve.map(\.cluster))),"a reserved cluster never appears in the practice pool")
        XCTAssertEqual(Set(mates.map(\.learner)),["w","b"],"both colours")
        XCTAssertTrue(mates.contains{($0.expected?.moves ?? []).count>1},"some positions have several correct mates")
        XCTAssertTrue(mates.contains{($0.expected?.moves ?? []).contains{$0.hasSuffix("n")}},"an underpromotion mate is included")
        XCTAssertTrue(mates.allSatisfy{!$0.prompt.contains("several") && !$0.prompt.contains("only")},"prompts never reveal how many answers exist")
    }
    func testManifestPinsMatchTheValidatorAndRules()throws {
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("training/manifest.json"))) as! [String:Any]
        XCTAssertEqual(manifest["validatorVersion"] as? Int,TrainingValidationService.validatorVersion)
        XCTAssertEqual(manifest["chessJS"] as? String,try reviewFileHash(NativeResources.url("chess.js")),"content must be revalidated when chess.js changes")
    }
    // MARK: WI-005
    func testIncrementAIsTheEightExistingGamesAndSevenNewExercises()throws {
        let catalog=try TrainingCatalog.bundled(),foundations=catalog.entries.filter{$0.increment == .foundations}
        let existing=foundations.filter{$0.origin == .existing},new=foundations.filter{$0.origin == .new}
        XCTAssertEqual(foundations.count,15);XCTAssertEqual(existing.count,8);XCTAssertEqual(new.count,7)
        XCTAssertEqual(Set(existing.compactMap(\.legacyKind)),Set(MiniGameKind.allCases),"every existing game, once")
        XCTAssertTrue(existing.allSatisfy{$0.objective == .legacyGame && $0.ruleMode == .simplifiedVariant})
        XCTAssertEqual(Set(new.map(\.objective)),[.reachTarget,.findAttackers,.findDefenders,.kingSafeSquares,.mateInOne,.escapeCheck,.classifyStatus])
        // The original games keep their fixed start, White to move.
        for kind in MiniGameKind.allCases {let game=MiniGameState(kind:kind);XCTAssertEqual(game.turn,"w");XCTAssertEqual(game.board,kind.initialBoard)}
    }
    /// Increment B: seven exercises and the four position games of mini-game plan D2 (WI-020), all new.
    func testIncrementBIsSevenExercisesAndTheFourPositionGames()throws {
        let beginner=try TrainingCatalog.bundled().entries(in:.beginner)
        XCTAssertEqual(beginner.count,11);XCTAssertTrue(beginner.allSatisfy{$0.origin == .new})
        XCTAssertEqual(beginner.filter{$0.objective == .positionGame}.map(\.id),["pawn-race","pawn-war","cut-down-chess","two-bishop-mate"])
        XCTAssertEqual(Set(beginner.filter{$0.objective != .positionGame}.map(\.objective)),[.saveYourPiece,.captureWisely,.specialMoves,.simpleTactics,.finishTheGame,.mixedPractice,.guidedGame])
    }
    func testEveryCuratedPoolMeetsItsContract()throws {
        let provider=try TrainingScenarioProvider.bundled()
        for entry in ["mate-in-one","king-safe-squares","escape-check","check-mate-stalemate"] {
            let scenarios=provider.scenarios(for:entry),practice=scenarios.filter{$0.reserve != true},reserve=scenarios.filter{$0.reserve==true}
            XCTAssertGreaterThanOrEqual(scenarios.count,30,entry);XCTAssertGreaterThanOrEqual(practice.count,20,entry)
            XCTAssertGreaterThanOrEqual(Set(reserve.map(\.cluster)).count,10,"\(entry): ten reserved clusters")
            XCTAssertEqual(Set(practice.map(\.learner)),["w","b"],"\(entry): practice in both colours")
            XCTAssertEqual(Set(scenarios.map(\.tier)),[1,2,3],"\(entry): every tier")
            XCTAssertTrue(scenarios.allSatisfy{$0.review?.reviewer==nil},"\(entry): unreviewed content says so")
        }
        let statuses=provider.scenarios(for:"check-mate-stalemate").compactMap{$0.expected?.choice}
        XCTAssertEqual(Set(statuses),Set(TrainingStatus.choices),"every classification is practised")
    }
    func testEveryNewExerciseComesInBothColours()throws {
        let provider=try TrainingScenarioProvider.bundled()
        for definition in provider.catalog.entries where definition.increment == .foundations && definition.origin == .new {
            var colours=Set<String>()
            for seed in UInt64(1)...64 {if case .scenario(let scenario,_)=provider.next(for:definition,seen:[],seed:seed){colours.insert(scenario.learner)};if colours.count==2{break}}
            XCTAssertEqual(colours,["w","b"],definition.id)
        }
    }
}
