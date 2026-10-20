import XCTest
import CryptoKit
@testable import CheckmateDomain

/// WI-020: the standard-rule calibration manifest is fixed and checked before any game, a game is scored as chess or by
/// the learner's goal, the pass rule separates only levels that differ (outward from each entry's fallback), and the
/// offering is exactly what the published results allow.
final class PositionGameCalibrationTests:XCTestCase {
    private static let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func manifest()throws -> PositionGameCalibration.Manifest {
        try JSONDecoder().decode(PositionGameCalibration.Manifest.self,from:Data(contentsOf:Self.root.appendingPathComponent("Content/calibration/position-game-manifest.json")))
    }
    private func tally(_ wins:Int,_ draws:Int,of games:Int)->MiniGameCalibration.Tally {var t=MiniGameCalibration.Tally();t.games=games;t.wins=wins;t.draws=draws;t.losses=games-wins-draws;return t}
    private func split(_ t:MiniGameCalibration.Tally,sides:[String])->(MiniGameCalibration.Tally,MiniGameCalibration.Tally) {
        guard sides.count==2 else{return sides==["w"] ? (t,MiniGameCalibration.Tally()):(MiniGameCalibration.Tally(),t)}
        var a=t,b=t;a.games=t.games/2;b.games=t.games-a.games;a.wins=t.wins/2;b.wins=t.wins-a.wins;a.draws=t.draws/2;b.draws=t.draws-a.draws;a.losses=a.games-a.wins-a.draws;b.losses=b.games-b.wins-b.draws;return (a,b)
    }
    /// A result for `entry` in which every pairing has its tally in `tallies` by level, unless `references` names it.
    private func result(_ entry:PositionGameCalibration.Entry,_ m:PositionGameCalibration.Manifest,_ tallies:[TrainingOpponentLevel:MiniGameCalibration.Tally],references:[String:MiniGameCalibration.Tally]=[:])->PositionGameCalibration.EntryResult {
        let rows=PositionGameCalibration.pairings(m,entry).map{pairing->MiniGameCalibration.Pairing in
            let (w,b)=split(references["\(pairing.level.rawValue)|\(pairing.reference)"] ?? tallies[pairing.level]!,sides:entry.sides)
            return MiniGameCalibration.Pairing(level:pairing.level.rawValue,reference:pairing.reference,asWhite:w,asBlack:b)
        }
        return PositionGameCalibration.EntryResult(entry:entry.entry,variant:entry.variant,pairings:rows)
    }
    private func entry(_ key:String)throws -> PositionGameCalibration.Entry {try XCTUnwrap(try manifest().entries.first{$0.key==key})}

    func testTheTrackedManifestIsValidAndNamesEveryNewEntry()throws {
        let m=try manifest();XCTAssertEqual(PositionGameCalibration.problems(m),[])
        XCTAssertEqual(Set(m.entries.map(\.key)),["pawn-race/kpk","pawn-war/pawns","cut-down-chess/knights","cut-down-chess/bishops","cut-down-chess/rooks","cut-down-chess/queens","cut-down-chess/minor-pieces","cut-down-chess/major-pieces","two-bishop-mate/kbbk","finish-the-game/krk","guided-games/initial-setup","guided-games/short-start"])
        XCTAssertEqual(PositionGameCalibration.pairings(m,try entry("pawn-war/pawns")).map{"\($0.level.rawValue)|\($0.reference)"},["gentle|random","gentle|greedy","steady|random","steady|greedy","steady|level-below","strong|random","strong|greedy","strong|level-below"])
        XCTAssertEqual(PositionGameCalibration.pairings(m,try entry("two-bishop-mate/kbbk")).map{"\($0.level.rawValue)|\($0.reference)"},["gentle|random","gentle|greedy","steady|random","steady|greedy","strong|random","strong|greedy"],"a level that only defends has no head-to-head")
        XCTAssertEqual(m.opponent,.current,"the levels as the app plays them")
    }
    func testTheValidatorRefusesAManifestThatCannotDecide()throws {
        let valid=try manifest()
        func refuses(_ change:(inout PositionGameCalibration.Manifest)->Void,_ fragment:String,file:StaticString=#filePath,line:UInt=#line){
            var m=valid;change(&m);let found=PositionGameCalibration.problems(m)
            XCTAssertTrue(found.contains{$0.contains(fragment)},"\(found)",file:file,line:line)
        }
        refuses({$0.gamesPerPairing=60},"is below the");refuses({$0.gamesPerPairing=101},"split evenly")
        refuses({$0.entries[0].kind="simplified"},"is not standard")
        // A guided entry's starts name the learner's colour, and the level plays the other side.
        let guided=try XCTUnwrap(valid.entries.firstIndex{$0.check == .guidedGame})
        refuses({$0.entries[0].check = .guidedGame},"ordinary chess is scored as chess")
        refuses({$0.entries[0].starts[0].learner="b"},"only a guided game names the learner per start")
        refuses({$0.entries[guided].starts[0].learner="b"},"opposite each start's learner")
        refuses({$0.entries[guided].sides=["w"]},"opposite each start's learner")
        refuses({$0.entries[guided].starts.append(PositionGameCalibration.Start(scenario:"gg-extra",fen:"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",learner:"w"))},"both learner colours equally")
        refuses({$0.entries[guided].scoring = .goal},"ordinary chess is scored as chess")
        refuses({$0.entries.append($0.entries[0])},"appears once");refuses({$0.entries=[]},"names its entries")
        refuses({$0.entries[0].sides=["w"]},"only the opponent's");refuses({$0.entries[0].references=["random","greedy","level-below"]},"no head-to-head")
        refuses({$0.entries[1].references=["random","greedy"]},"every reference");refuses({$0.entries[1].scoring = .goal},"scored as chess");refuses({$0.entries[0].scoring = .chess},"scored by the goal")
        refuses({$0.entries[0].starts=[]},"distinct published scenarios");refuses({$0.entries[0].starts[0].fen="8/8/8/8/8/8/8/8 b - - 0 1"},"learner to move")
        refuses({$0.entries[0].accessibility.reference="level-below"},"fixed reference");refuses({$0.entries[0].accessibility.minimumReferenceScore=1},"inside (0, 1)")
        refuses({$0.levels=["steady","gentle","strong"]},"weakest first");refuses({$0.drawScore=1},"half a point");refuses({$0.seed="not-hex"},"hexadecimal")
        refuses({$0.passRule.minimumDifference=0.05},"10 points");refuses({$0.passRule.headToHead.minimumScore=0.55},"at least 60%")
        refuses({$0.opponent.engineNodes=100_000},"as the app plays them");refuses({$0.opponent.gentleSearchNodes+=1},"as the app plays them")
    }
    /// The sample: the fewest games at which a level scoring exactly the head-to-head minimum (60%) passes branch (b).
    func testTheSampleIsSizedByTheHeadToHeadInterval()throws {
        let rule=try manifest().passRule,n=PositionGameCalibration.requiredGames(rule.headToHead,confidence:rule.confidence)
        XCTAssertGreaterThan(MiniGameCalibration.wilson(score:0.6,games:n,confidence:0.95).lowerBound,0.5)
        XCTAssertLessThanOrEqual(MiniGameCalibration.wilson(score:0.6,games:n-2,confidence:0.95).lowerBound,0.5)
        XCTAssertGreaterThanOrEqual(try manifest().gamesPerPairing,n)
        // At that size branch (a) needs more than ten points in mid-range scores: fewer games only make a pass harder.
        let d=PositionGameCalibration.separatingDifference(games:n,confidence:0.95)
        XCTAssertGreaterThan(d,0.10);XCTAssertLessThan(d,0.30)
    }
    func testAGameIsScoredAsChessOrByTheGoal(){
        XCTAssertEqual(PositionGameCalibration.winner(.learnerGaveMate,learner:"w",scoring:.chess),"w")
        XCTAssertEqual(PositionGameCalibration.winner(.learnerMated,learner:"w",scoring:.chess),"b")
        XCTAssertNil(PositionGameCalibration.winner(.stalemate,learner:"w",scoring:.chess));XCTAssertNil(PositionGameCalibration.winner(.automaticDraw,learner:"w",scoring:.chess))
        XCTAssertNil(PositionGameCalibration.winner(nil,learner:"w",scoring:.chess),"the ply cap is a draw in chess")
        // By the goal, everything but success is the defender's: the app counts a draw as a failed goal (D3).
        for row in [PositionGameRow.stalemate,.automaticDraw,.keptPieceLost,.pawnCaptured,.promotedPieceCaptured,.learnerMated] {XCTAssertEqual(PositionGameCalibration.winner(row,learner:"w",scoring:.goal),"b",row.rawValue)}
        XCTAssertEqual(PositionGameCalibration.winner(nil,learner:"w",scoring:.goal),"b")
        XCTAssertEqual(PositionGameCalibration.winner(.promotedPieceHeld,learner:"w",scoring:.goal),"w");XCTAssertEqual(PositionGameCalibration.winner(.learnerGaveMate,learner:"w",scoring:.goal),"w")
    }
    /// The identical-profiles test: one profile entered as all three levels never separates under either branch, so
    /// the entry offers only its fallback, Strong.
    func testIdenticalProfilesFailThePassRule()throws {
        let m=try manifest(),symmetric=try entry("pawn-war/pawns"),defends=try entry("two-bishop-mate/kbbk")
        let same=tally(60,10,of:100)
        let verdict=try PositionGameCalibration.verdict(result(symmetric,m,[.gentle:same,.steady:same,.strong:same]),manifest:m)
        XCTAssertEqual(verdict.pairs.map(\.passed),[false,false]);XCTAssertEqual(verdict.offered,["strong"])
        let saturated=tally(98,0,of:100),even=tally(45,10,of:100)
        let ceiling=try PositionGameCalibration.verdict(result(symmetric,m,[.gentle:saturated,.steady:saturated,.strong:saturated],references:["steady|level-below":even,"strong|level-below":even]),manifest:m)
        XCTAssertEqual(ceiling.pairs.map(\.saturated),[true,true]);XCTAssertEqual(ceiling.pairs.map(\.passed),[false,false]);XCTAssertEqual(ceiling.offered,["strong"])
        // A defender holding every game against greedy cannot be told apart by it, and has no head-to-head.
        let held=tally(100,0,of:100)
        let ending=try PositionGameCalibration.verdict(result(defends,m,[.gentle:held,.steady:held,.strong:held]),manifest:m)
        XCTAssertEqual(ending.pairs.map(\.passed),[false,false]);XCTAssertEqual(ending.pairs.map(\.headToHeadScore),[0,0]);XCTAssertFalse(ending.gentleAccessible);XCTAssertEqual(ending.offered,["strong"])
    }
    /// Levels are offered outward from the fallback: Steady when its pair with Strong passes, Gentle only then and when
    /// its own pair passes and it is accessible.
    func testLevelsAreOfferedOutwardFromTheFallback()throws {
        let m=try manifest(),symmetric=try entry("pawn-war/pawns")
        let apart=[TrainingOpponentLevel.gentle:tally(30,10,of:100),.steady:tally(55,10,of:100),.strong:tally(85,10,of:100)]
        let all=try PositionGameCalibration.verdict(result(symmetric,m,apart,references:["gentle|greedy":tally(30,10,of:100)]),manifest:m)
        XCTAssertEqual(all.pairs.map(\.passedAgainstReference),[true,true]);XCTAssertTrue(all.gentleAccessible);XCTAssertEqual(all.offered,["gentle","steady","strong"])
        // Steady does not separate from Strong, so Gentle is compared with Strong itself, by branch (a) alone.
        let flat=try PositionGameCalibration.verdict(result(symmetric,m,apart.merging([.strong:tally(55,10,of:100)]){$1},references:["gentle|greedy":tally(30,10,of:100)]),manifest:m)
        XCTAssertEqual(flat.pairs.map(\.passed),[true,false]);XCTAssertEqual(flat.decisions.map{"\($0.lower)-\($0.higher)"},["steady-strong","gentle-strong"])
        XCTAssertEqual(flat.decisions.map(\.passed),[false,true]);XCTAssertEqual(flat.offered,["gentle","strong"])
        // Two steps apart there is no head-to-head: a saturated pair cannot pass that way.
        let saturated2=tally(97,0,of:100)
        let far=try PositionGameCalibration.verdict(result(symmetric,m,[.gentle:saturated2,.steady:saturated2,.strong:saturated2],references:["strong|level-below":tally(50,0,of:100),"steady|level-below":tally(90,0,of:100)]),manifest:m)
        XCTAssertEqual(far.decisions.map(\.passed),[false,false]);XCTAssertEqual(far.decisions[1].headToHeadScore,0);XCTAssertEqual(far.offered,["strong"])
        // Greedy scoring under 30% against Gentle withdraws it.
        let hard=try PositionGameCalibration.verdict(result(symmetric,m,apart.merging([.gentle:tally(45,10,of:100)]){$1},references:["gentle|greedy":tally(80,0,of:100)]),manifest:m)
        XCTAssertFalse(hard.gentleAccessible);XCTAssertEqual(hard.offered,["steady","strong"])
        // Saturated greedy, then head-to-head decides (branch (b)).
        let saturated=tally(97,0,of:100)
        let duel=try PositionGameCalibration.verdict(result(symmetric,m,[.gentle:saturated,.steady:saturated,.strong:saturated],references:["strong|level-below":tally(75,10,of:100),"steady|level-below":tally(50,0,of:100)]),manifest:m)
        XCTAssertEqual(duel.pairs.map(\.passedHeadToHead),[false,true]);XCTAssertEqual(duel.offered,["steady","strong"])
        // A result missing games does not answer the manifest.
        var short=result(symmetric,m,apart);short.pairings[0].asWhite.games-=1
        XCTAssertThrowsError(try PositionGameCalibration.verdict(short,manifest:m))
    }
    /// The published results name the sources they were played from; re-hashing them must give the same digests.
    func testThePublishedResultsArePlayedFromTheseSources()throws {
        let results=try JSONDecoder().decode(PositionGameCalibration.Results.self,from:Data(contentsOf:Self.root.appendingPathComponent("Content/calibration/position-game-results.json")))
        let recorded=results.identity.sourceSHA256
        XCTAssertEqual(Set(recorded.keys),Set(PositionGameCalibration.sourceFiles+["Content/calibration/position-game-manifest.json"]),"the results record exactly the harness's source files")
        for (path,digest) in recorded.sorted(by:{$0.key<$1.key}) {
            let data=try Data(contentsOf:Self.root.appendingPathComponent(path))
            XCTAssertEqual(SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),digest,"\(path) changed after calibration; calibrate again on the test host")
        }
        XCTAssertEqual(results.identity.options,AnalysisPolicy.options,"the engine options it played with")
    }
    /// The offering is calibration's verdict, from a full run of the tracked manifest.
    func testTheOfferingIsWhatThePublishedResultsAllow()throws {
        let results=try JSONDecoder().decode(PositionGameCalibration.Results.self,from:Data(contentsOf:Self.root.appendingPathComponent("Content/calibration/position-game-results.json")))
        let tracked=try manifest()
        XCTAssertFalse(results.smoke,"a smoke run never sets the offering");XCTAssertEqual(results.manifest,tracked,"the results are of the tracked manifest")
        XCTAssertEqual(Set(results.entries.map(\.key)),Set(tracked.entries.map(\.key)))
        XCTAssertEqual(Set(MiniGameOffering.positionGames.keys),Set(tracked.entries.map(\.key)),"every calibrated entry, and only those, has published levels")
        for entry in results.entries {
            let verdict=try PositionGameCalibration.verdict(entry,manifest:tracked)
            XCTAssertEqual(results.verdicts.first{$0.entry==entry.entry && $0.variant==entry.variant},verdict,entry.key)
            XCTAssertEqual(MiniGameOffering.positionGames[entry.key]?.map(\.rawValue),verdict.offered,entry.key)
            let check=try XCTUnwrap(tracked.entries.first{$0.key==entry.key}).check
            XCTAssertTrue(verdict.offered.contains(MiniGameOffering.fallbackLevel(for:check).rawValue))
        }
    }
}
