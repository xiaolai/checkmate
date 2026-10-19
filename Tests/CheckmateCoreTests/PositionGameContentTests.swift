import CheckmateTestSupport
import XCTest
import CryptoKit
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateApplication

/// WI-020: the position games of plan D2 as published content. Every start is legal, not over and the learner's to
/// move; a pawn race is an exact promoteAndHold success by the KPK oracle, whose verdict and identity the manifest holds;
/// a checkmate game's goal is reachable, shown by a legal line to a position in which the bundled engine at a fixed node
/// count reports a forced mate for the learner, searched again here; and the entries are offered only behind their flags.
@MainActor final class PositionGameContentTests:XCTestCase {
    private static let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let entries=["pawn-race":["kpk"],"pawn-war":["pawns"],"cut-down-chess":["knights","bishops","rooks","queens","minor-pieces","major-pieces"],"two-bishop-mate":["kbbk"]]
    private static let flags=["CHECKMATE_TRAINING_ENABLED","CHECKMATE_TRAINING_B","CHECKMATE_POSITION_GAMES"]
    override func tearDown(){Self.flags.forEach{unsetenv($0)}}
    private func games()throws -> [(TrainingEntryDefinition,TrainingScenario)] {
        let provider=try TrainingScenarioProvider.bundled()
        return provider.catalog.entries.filter{$0.objective == .positionGame}.flatMap{definition in provider.scenarios(for:definition.id).map{(definition,$0)}}
    }
    private func evidence()throws -> [String:[String:Any]] {
        let manifest=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("training/manifest.json"))) as? [String:Any])
        return try XCTUnwrap(manifest["positionGames"] as? [String:[String:Any]])
    }

    func testTheCatalogHasTheFourPositionGamesWithTheirVariants()throws {
        let catalog=try TrainingCatalog.bundled(),positions=catalog.entries.filter{$0.objective == .positionGame}
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:positions.map{($0.id,$0.variants)}),Self.entries)
        XCTAssertTrue(positions.allSatisfy{$0.increment == .beginner && $0.origin == .new && $0.ruleMode == .standardChess})
        XCTAssertEqual(catalog.entries(in:.beginner).count,7+Self.entries.count,"Increment B: seven exercises and the four position games")
        let counted=Dictionary(grouping:try games(),by:{"\($0.1.entry)/\($0.1.variant)"}).mapValues(\.count)
        XCTAssertEqual(counted,["pawn-race/kpk":9,"pawn-war/pawns":1,"cut-down-chess/knights":1,"cut-down-chess/bishops":1,"cut-down-chess/rooks":1,"cut-down-chess/queens":1,
                                "cut-down-chess/minor-pieces":1,"cut-down-chess/major-pieces":1,"two-bishop-mate/kbbk":6])
        let races=try games().filter{$0.1.entry=="pawn-race"}.map(\.1)
        XCTAssertGreaterThanOrEqual(Set(try races.map{try XCTUnwrap(TrainingLegality(fen:$0.fen!).board().first{$0.value=="wp"}?.key.prefix(1))}).count,6,"pawn races on several files")
        XCTAssertEqual(Set(races.map(\.tier)),[1,2,3])
    }
    func testEveryStartIsLegalNotOverTheLearnersMoveAndUnreviewed()throws {
        for (definition,scenario) in try games() {
            XCTAssertNoThrow(try TrainingValidationService.validate(scenario,definition:definition),scenario.id)
            let start=try TrainingLegality(fen:try XCTUnwrap(scenario.fen))
            XCTAssertEqual(scenario.learner,"w",scenario.id);XCTAssertEqual(try start.turn(),scenario.learner,scenario.id)
            XCTAssertFalse(try start.outcomes().isEmpty,scenario.id);XCTAssertNil(try start.automaticDraw(),scenario.id);XCTAssertNotEqual(try start.status(),.check,scenario.id)
            XCTAssertEqual(scenario.check,.positionGame);XCTAssertNil(scenario.review?.reviewer,"\(scenario.id): no editor has reviewed it yet")
            XCTAssertEqual(scenario.goal?.kind,scenario.entry=="pawn-race" ? .promoteAndHold:.checkmate,scenario.id)
            XCTAssertEqual(scenario.keep,scenario.entry=="two-bishop-mate" ? ["b"]:nil,scenario.id)
        }
    }
    /// The manifest holds each race's verdict from the oracle as it is now: the generator's source hash is re-derived
    /// from the files it names (`Tools/kpk-oracle.py identity`).
    func testEveryPawnRaceIsAnExactPromoteAndHoldSuccessByTheOracle()throws {
        let records=try evidence()
        var digest=SHA256()
        for name in ["kpk-oracle.py","kpk_retrograde.py","kpk_forward.py","lesson_rules.py"] {
            digest.update(data:Data(name.utf8)+Data([0])+(try Data(contentsOf:Self.root.appendingPathComponent("Tools/"+name)))+Data([0]))
        }
        let hash=digest.finalize().map{String(format:"%02x",$0)}.joined()
        let races=try games().map(\.1).filter{$0.goal?.kind == .promoteAndHold}
        XCTAssertEqual(races.count,9)
        for race in races {
            let record=try XCTUnwrap(records[race.id],race.id),oracle=try XCTUnwrap(record["oracle"] as? [String:Any],race.id)
            XCTAssertEqual(record["goal"] as? String,"promoteAndHold")
            XCTAssertEqual(oracle["fen"] as? String,race.fen,race.id);XCTAssertEqual(oracle["promoteAndHold"] as? String,"success",race.id);XCTAssertEqual(oracle["chess"] as? String,"win",race.id)
            XCTAssertTrue(oracle["over"] is NSNull,race.id);XCTAssertGreaterThan(oracle["successPlies"] as? Int ?? 0,0,race.id)
            let generator=try XCTUnwrap(oracle["generator"] as? [String:Any])
            XCTAssertEqual(generator["tool"] as? String,"kpk-oracle");XCTAssertEqual(generator["version"] as? Int,1);XCTAssertEqual(generator["sourceHash"] as? String,hash,"the oracle changed since its verdicts were published")
        }
    }
    /// Each checkmate game's line is legal and does not end the game, and the bundled engine at the recorded node count
    /// (skill 20, one thread, a fresh hash per search: the search is deterministic) reports the recorded mate for the
    /// learner there.
    func testEveryMateIsReachableAndConfirmedByTheEngineAtItsNodeCount()async throws {
        let records=try evidence(),mates=try games().map(\.1).filter{$0.goal?.kind == .checkmate}
        XCTAssertEqual(mates.count,13);XCTAssertEqual(Set(records.keys),Set(try games().map(\.1.id)),"every position game, and only they, has its evidence")
        let engine=NativeEngine();try await engine.prepare()
        for scenario in mates {
            let record=try XCTUnwrap(records[scenario.id],scenario.id),fen=try XCTUnwrap(scenario.fen)
            let line=try XCTUnwrap(record["line"] as? [String]),nodes=try XCTUnwrap(record["nodes"] as? Int),mate=try XCTUnwrap(record["mate"] as? Int)
            XCTAssertEqual(record["engine"] as? String,engine.binaryIdentity,"\(scenario.id): the engine changed since its mate was recorded; regenerate position-game-evidence.json")
            let rules=try ChessRules(fen:fen)
            for move in line {XCTAssertFalse(rules.over,scenario.id);_ = try rules.move(uci:move)}
            XCTAssertFalse(rules.over,scenario.id);XCTAssertEqual(rules.turn,scenario.learner,scenario.id)
            let result=try await engine.analyzeHistory(startFEN:fen,moves:line,profile:.skill(20),limit:.nodes(nodes),multiPv:1,searchMoves:[])
            let score=try XCTUnwrap(result.lines.first?.score,scenario.id)
            XCTAssertEqual(score.kind,"mate",scenario.id);XCTAssertEqual(score.value*(scenario.learner=="w" ? 1:-1),mate,scenario.id)
        }
    }
    /// The entries appear only with training, Increment B and position games all on, and then under the preview
    /// heading that says they are machine-checked but not reviewed.
    func testThePositionGamesAreOfferedOnlyBehindAllThreeFlags()throws {
        let positions=try TrainingCatalog.bundled().entries.filter{$0.objective == .positionGame}
        for on in 0...Self.flags.count {
            for (index,name) in Self.flags.enumerated(){if index<on{setenv(name,"1",1)}else{unsetenv(name)}}
            XCTAssertEqual(positions.map(TrainingRolloutPolicy.offered),Array(repeating:on==Self.flags.count,count:positions.count),"\(on) of the flags on")
        }
        XCTAssertTrue(positions.allSatisfy{TrainingRolloutPolicy.preview($0)})
    }
    /// The calibration manifest's starts are the published scenarios, so its results describe these games.
    func testTheCalibrationStartsAreThePublishedScenarios()throws {
        let manifest=try JSONDecoder().decode(PositionGameCalibration.Manifest.self,from:Data(contentsOf:Self.root.appendingPathComponent("Content/calibration/position-game-manifest.json")))
        let provider=try TrainingScenarioProvider.bundled()
        for entry in manifest.entries {
            let published=provider.scenarios(for:entry.entry).filter{$0.variant==entry.variant && $0.learner==entry.learner}
            XCTAssertEqual(Dictionary(uniqueKeysWithValues:entry.starts.map{($0.scenario,$0.fen)}),Dictionary(uniqueKeysWithValues:published.map{($0.id,$0.fen!)}),"\(entry.key): every published start, as published")
            XCTAssertTrue(published.allSatisfy{$0.check==entry.check},entry.key)
        }
    }
}
