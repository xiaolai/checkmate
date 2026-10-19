import XCTest
import CheckmateDomain
final class TrainingDefinitionTests:XCTestCase {
    private func entry(id:String="reach-target",objective:TrainingObjectiveKind = .reachTarget,legacy:MiniGameKind?=nil,increment:TrainingIncrement = .foundations,origin:TrainingOrigin = .new,rules:[String]=["Only your piece moves."],skills:[TrainingSkill]=[.movement],variants:[String]=["knight"],tiers:Int=3)->TrainingEntryDefinition {
        TrainingEntryDefinition(id:id,title:"Title",summary:"Summary",rules:rules,objective:objective,legacyKind:legacy,increment:increment,delivery:.pilot,origin:origin,skills:skills,variants:variants,lessonLinks:[],tiers:tiers)
    }
    func testBundledCatalogMatchesIncrementContracts()throws {
        let catalog=try TrainingCatalog.bundled()
        let a=catalog.entries(in:.foundations),b=catalog.entries(in:.beginner)
        XCTAssertEqual(a.count,15);XCTAssertEqual(a.filter{$0.origin == .existing}.count,8);XCTAssertEqual(a.filter{$0.origin == .new}.count,7)
        XCTAssertEqual(b.count,11,"B adds six groups, each one library entry with variants, the guided-game workflow and the four position games");XCTAssertTrue(b.allSatisfy{$0.origin == .new})
        XCTAssertEqual(Set(catalog.entries.compactMap(\.legacyKind)),Set(MiniGameKind.allCases),"every existing game is a library entry exactly once")
        XCTAssertEqual(Set(a.filter{$0.origin == .new}.map(\.objective)),[.reachTarget,.findAttackers,.findDefenders,.kingSafeSquares,.mateInOne,.escapeCheck,.classifyStatus])
        XCTAssertEqual(Set(b.map(\.objective)),[.saveYourPiece,.captureWisely,.specialMoves,.simpleTactics,.finishTheGame,.mixedPractice,.guidedGame,.positionGame])
        XCTAssertEqual(b.filter{$0.objective == .positionGame}.count,4,"the four position games of mini-game plan D2")
        XCTAssertEqual(Set(catalog.entries.filter{$0.delivery == .pilot}.map(\.id)),["reach-target","find-attackers","mate-in-one","pawn-duel"],"the four-entry pilot")
        // Every coverage-matrix row has at least one entry practising it.
        XCTAssertEqual(Set(catalog.entries.flatMap(\.skills)),Set(TrainingSkill.allCases))
        XCTAssertEqual(catalog.entries.filter{$0.skills.contains(.gameHabits)}.map(\.objective),[.guidedGame],"game habits are practised in guided games")
        // Original games keep their side, rules and simplified mode.
        for legacy in catalog.entries.filter({$0.origin == .existing}) {XCTAssertEqual(legacy.ruleMode,.simplifiedVariant);XCTAssertEqual(legacy.objective,.legacyGame)}
    }
    func testObjectivesDeclareRuleModeAndIllegalInputPolicy(){
        XCTAssertEqual(TrainingObjectiveKind.escapeCheck.illegalInput,.ruleError,"check evasion grades a raw illegal attempt")
        XCTAssertEqual(TrainingObjectiveKind.specialMoves.illegalInput,.ruleError)
        XCTAssertEqual(TrainingObjectiveKind.mateInOne.illegalInput,.selectionCorrection)
        XCTAssertEqual(TrainingObjectiveKind.saveYourPiece.illegalInput,.selectionCorrection)
        XCTAssertEqual(TrainingObjectiveKind.findAttackers.ruleMode,.recognitionDiagram);XCTAssertEqual(TrainingObjectiveKind.reachTarget.ruleMode,.movementDrill);XCTAssertEqual(TrainingObjectiveKind.kingSafeSquares.ruleMode,.standardChess)
        for kind in TrainingObjectiveKind.allCases {XCTAssertFalse(kind.actions.isEmpty,kind.rawValue)}
    }
    func testInvalidDefinitionsFailLoudly(){
        XCTAssertNoThrow(try entry().validate())
        for bad in [entry(id:"Reach"),entry(id:"bad id"),entry(id:String(repeating:"a",count:49)),entry(id:"-lead"),entry(rules:[]),entry(rules:[""]),entry(skills:[]),entry(skills:[.movement,.movement]),entry(variants:["Bad"]),entry(variants:["a","a"]),entry(tiers:0),entry(tiers:4),
                    entry(objective:.legacyGame),entry(id:"pawn-duel",objective:.legacyGame,legacy:.pawnDuel,origin:.new),entry(legacy:.pawnDuel),entry(origin:.existing),entry(objective:.saveYourPiece,increment:.foundations),entry(variants:[])] {
            XCTAssertThrowsError(try bad.validate(),bad.id)
        }
        XCTAssertNoThrow(try entry(id:"pawn-duel",objective:.legacyGame,legacy:.pawnDuel,origin:.existing,variants:[],tiers:1).validate())
    }
    func testDecodedRuleModeMustMatchObjective()throws {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(entry())) as! [String:Any]
        object["ruleMode"]="standardChess"
        let tampered=try JSONDecoder().decode(TrainingEntryDefinition.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertThrowsError(try tampered.validate(),"an entry cannot claim different rules than its objective's evaluator")
        object["ruleMode"]="movementDrill";object["objective"]="invented"
        XCTAssertThrowsError(try JSONDecoder().decode(TrainingEntryDefinition.self,from:JSONSerialization.data(withJSONObject:object)),"no executable or unknown objectives")
    }
    func testCatalogRejectsVersionsAndDuplicates(){
        XCTAssertThrowsError(try TrainingCatalog(schemaVersion:2,contentVersion:1,entries:[entry()]).validate())
        XCTAssertThrowsError(try TrainingCatalog(contentVersion:0,entries:[entry()]).validate())
        XCTAssertThrowsError(try TrainingCatalog(contentVersion:1,entries:[entry(),entry()]).validate())
        let pawn=entry(id:"pawn-duel",objective:.legacyGame,legacy:.pawnDuel,origin:.existing,variants:[],tiers:1),again=entry(id:"pawn-duel-two",objective:.legacyGame,legacy:.pawnDuel,origin:.existing,variants:[],tiers:1)
        XCTAssertThrowsError(try TrainingCatalog(contentVersion:1,entries:[pawn,again]).validate(),"one board owner per mini-game")
    }
    func testActivityOwnsLegacyOrigin(){
        XCTAssertEqual(Place.miniGame(lessonIndex:3,kind:.pawnDuel).mode,.lesson,"lesson-launched games keep their mode")
        XCTAssertEqual(Place.miniGame(lessonIndex:3,kind:.pawnDuel).lessonIndex,3)
        XCTAssertEqual(Place.miniGame(lessonIndex:nil,kind:.pawnDuel).mode,.training,"library-launched games are training")
        XCTAssertNil(Place.miniGame(lessonIndex:nil,kind:.pawnDuel).lessonIndex,"no fabricated lesson index")
        XCTAssertEqual(Place.miniGame(lessonIndex:3,kind:.pawnDuel),.miniGame(lessonIndex:3,kind:.pawnDuel,fromTraining:false),"a lesson game is not a training link by default")
        XCTAssertNotEqual(Place.miniGame(lessonIndex:3,kind:.pawnDuel,fromTraining:true),.miniGame(lessonIndex:3,kind:.pawnDuel),"the training origin is part of the place")
        XCTAssertEqual(Place.miniGame(lessonIndex:3,kind:.pawnDuel,fromTraining:true).mode,.lesson);XCTAssertEqual(Place.miniGame(lessonIndex:3,kind:.pawnDuel,fromTraining:true).lessonIndex,3)
        XCTAssertEqual(Place.trainingLibrary.mode,.training);XCTAssertEqual(Place.training(entry:"mate-in-one").mode,.training);XCTAssertNil(Place.training(entry:"mate-in-one").lessonIndex)
        let review=Activity.reviewing(ReviewVisit(document:nil,draft:false,returnTo:.miniGame(lessonIndex:nil,kind:.queenVsPawns)))
        XCTAssertEqual(review.place.mode,.training,"a review returns to the library-launched game it was opened over")
        XCTAssertEqual(try JSONDecoder().decode(NativeMode.self,from:Data(#""training""#.utf8)),.training)
    }
    func testTrainingIsDefaultOff(){
        XCTAssertNil(ProcessInfo.processInfo.environment["CHECKMATE_TRAINING_ENABLED"]);XCTAssertFalse(TrainingRolloutPolicy.enabled)
    }
}
