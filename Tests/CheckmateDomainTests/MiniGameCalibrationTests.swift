import XCTest
@testable import CheckmateDomain

/// WI-016: the calibration manifest is fixed and checked before any game, the pass rule separates only levels that
/// differ, and the offering is exactly what the published results allow.
final class MiniGameCalibrationTests:XCTestCase {
    private static let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private func manifest()throws -> MiniGameCalibration.Manifest {
        try JSONDecoder().decode(MiniGameCalibration.Manifest.self,from:Data(contentsOf:Self.root.appendingPathComponent("Content/calibration/mini-game-manifest.json")))
    }
    private func tally(_ wins:Int,_ draws:Int,of games:Int)->MiniGameCalibration.Tally {var t=MiniGameCalibration.Tally();t.games=games;t.wins=wins;t.draws=draws;t.losses=games-wins-draws;return t}
    private func halves(_ t:MiniGameCalibration.Tally)->(MiniGameCalibration.Tally,MiniGameCalibration.Tally) {
        var a=t,b=t;a.games=t.games/2;b.games=t.games-a.games;a.wins=t.wins/2;b.wins=t.wins-a.wins;a.draws=t.draws/2;b.draws=t.draws-a.draws;a.losses=a.games-a.wins-a.draws;b.losses=b.games-b.wins-b.draws;return (a,b)
    }
    /// A result in which every pairing of a level has its tally in `tallies`, unless `references` names that pairing.
    private func result(_ game:String,_ tallies:[String:MiniGameCalibration.Tally],references:[String:MiniGameCalibration.Tally]=[:])->MiniGameCalibration.EntryResult {
        let rows=MiniOpponentPolicy.profiles.map{level in MiniGameCalibration.references.compactMap{reference->MiniGameCalibration.Pairing? in
            guard MiniGameCalibration.Player(reference:reference,below:level) != nil else{return nil}
            let (w,b)=halves(references["\(level)|\(reference)"] ?? tallies[level]!);return MiniGameCalibration.Pairing(level:level,reference:reference,asWhite:w,asBlack:b)}}.flatMap{$0}
        return MiniGameCalibration.EntryResult(game:game,pairings:rows,policies:[:])
    }

    func testTheTrackedManifestIsValidAndCoversEveryCompetitiveGame()throws {
        let m=try manifest();XCTAssertEqual(MiniGameCalibration.problems(m),[])
        XCTAssertEqual(Set(m.entries.map(\.game)),Set(MiniGameKind.allCases.filter{!$0.solo}.map(\.rawValue)),"Knight Corners has no opponent")
        XCTAssertEqual(MiniGameCalibration.pairings(m).map{"\($0.level)|\($0.reference)"},["beginner|random","beginner|greedy","standard|random","standard|greedy","standard|level-below","challenging|random","challenging|greedy","challenging|level-below"])
    }
    func testTheValidatorRefusesAManifestThatCannotDecide()throws {
        let valid=try manifest()
        func refuses(_ change:(inout MiniGameCalibration.Manifest)->Void,_ fragment:String,file:StaticString=#filePath,line:UInt=#line){
            var m=valid;change(&m);let found=MiniGameCalibration.problems(m)
            XCTAssertTrue(found.contains{$0.contains(fragment)},"\(found)",file:file,line:line)
        }
        refuses({$0.gamesPerPairing=200},"is below the");refuses({$0.gamesPerPairing=401},"split evenly")
        refuses({$0.entries.removeLast()},"every competitive game");refuses({$0.entries.append($0.entries[0])},"every competitive game")
        refuses({$0.entries[0].game="knight-corners"},"every competitive game")
        refuses({$0.entries[0].kind="standard-rule"},"follow WI-017")
        refuses({$0.entries[0].start="random-opening"},"initial position")
        refuses({$0.entries[0].accessibility.reference="level-below"},"fixed reference");refuses({$0.entries[0].accessibility.minimumReferenceScore=0},"inside (0, 1)")
        refuses({$0.levels=["standard","beginner","challenging"]},"weakest first");refuses({$0.sides=["w"]},"sides");refuses({$0.drawScore=0},"half a point")
        refuses({$0.passRule.minimumDifference=0.05},"10 points");refuses({$0.passRule.reference="random"},"greedy");refuses({$0.passRule.confidence=0.9},"95%")
        refuses({$0.seed="not-hex"},"hexadecimal");refuses({$0.deadline.gamesPerLevel=3},"even number")
    }
    func testWilsonIntervalsAndTheSampleSizeTheRuleNeeds(){
        let i=MiniGameCalibration.wilson(score:0.5,games:100,confidence:0.95)
        XCTAssertEqual(i.lowerBound,0.4038,accuracy:0.0001);XCTAssertEqual(i.upperBound,0.5962,accuracy:0.0001)
        XCTAssertEqual(MiniGameCalibration.wilson(score:1,games:400,confidence:0.95).upperBound,1,accuracy:1e-12)
        // 200 games are not enough: two scores 10 points apart near one half still overlap there.
        let n=MiniGameCalibration.requiredGames(minimumDifference:0.10,confidence:0.95)
        XCTAssertGreaterThan(n,200);XCTAssertLessThanOrEqual(n,400)
        XCTAssertGreaterThanOrEqual(MiniGameCalibration.wilson(score:0.45,games:n-2,confidence:0.95).upperBound,MiniGameCalibration.wilson(score:0.55,games:n-2,confidence:0.95).lowerBound)
        XCTAssertLessThan(MiniGameCalibration.wilson(score:0.45,games:n,confidence:0.95).upperBound,MiniGameCalibration.wilson(score:0.55,games:n,confidence:0.95).lowerBound)
    }
    /// The identical-profiles test: one profile entered as all three levels never separates, so the game offers only
    /// its fallback. First with equal tallies, then with real games of one profile under different seeds.
    func testIdenticalProfilesFailThePassRule()throws {
        var m=try manifest();let same=tally(240,40,of:400)
        let verdict=try MiniGameCalibration.verdict(result("pawn-duel",["beginner":same,"standard":same,"challenging":same]),manifest:m)
        XCTAssertEqual(verdict.pairs.map(\.passed),[false,false]);XCTAssertEqual(verdict.pairs.map(\.differs),[false,false]);XCTAssertEqual(verdict.offered,["standard"])
        m.gamesPerPairing=40;let seed=UInt64(m.seed,radix:16)!
        func play(_ stream:String)->MiniGameCalibration.Tally {
            var t=MiniGameCalibration.Tally()
            for index in 0..<m.gamesPerPairing {
                let white=index<m.gamesPerPairing/2,me=MiniGameCalibration.Player.level("beginner")
                let game=MiniGameCalibration.play(.rookSweep,white:white ? me:.greedy,black:white ? .greedy:me,seed:MiniGameCalibration.seed(seed,.rookSweep,stream,index),maximumPlies:m.maximumPlies)
                t.add(game,side:white ? "w":"b")
            }
            return t
        }
        let a=play("a"),b=play("b"),c=play("c");XCTAssertFalse(a==b && b==c,"premise: the seeds give different games")
        let real=try MiniGameCalibration.verdict(result("rook-sweep",["beginner":a,"standard":b,"challenging":c]),manifest:m)
        XCTAssertEqual(real.pairs.map(\.passed),[false,false],"\(real.pairs)");XCTAssertEqual(real.offered,["standard"])
    }
    func testSeparatedLevelsPassAndGentleNeedsToBeAccessible()throws {
        let m=try manifest()
        let apart=["beginner":tally(120,40,of:400),"standard":tally(220,40,of:400),"challenging":tally(300,40,of:400)]
        let all=try MiniGameCalibration.verdict(result("pawn-duel",apart),manifest:m)
        XCTAssertEqual(all.pairs.map(\.passed),[true,true]);XCTAssertTrue(all.gentleAccessible);XCTAssertEqual(all.offered,["beginner","standard","challenging"])
        // Ten points apart but overlapping intervals at a smaller sample is not enough; nor is 9 points at 400 games.
        let close=try MiniGameCalibration.verdict(result("pawn-duel",apart.merging(["challenging":tally(256,0,of:400),"standard":tally(220,0,of:400)]){$1}),manifest:m)
        XCTAssertEqual(close.pairs[1].differs,false);XCTAssertEqual(close.offered,["beginner","standard"])
        // Greedy scoring under 30% against Gentle withdraws Gentle, even though it separates from Steady.
        let hard=try MiniGameCalibration.verdict(result("pawn-duel",apart,references:["beginner|greedy":tally(300,0,of:400),"standard|greedy":tally(380,20,of:400),"challenging|greedy":tally(400,0,of:400)]),manifest:m)
        XCTAssertEqual(hard.pairs[0].passed,true);XCTAssertFalse(hard.gentleAccessible);XCTAssertEqual(hard.referenceScoreAgainstGentle,0.25,accuracy:1e-9)
        XCTAssertEqual(hard.offered,["standard"],"Strong at 100% does not separate from Steady at 97.5%: the ceiling")
        // A result missing games does not answer the manifest.
        var short=result("pawn-duel",apart);short.pairings[short.pairings.firstIndex{$0.reference=="greedy"}!].asWhite.games-=1
        XCTAssertThrowsError(try MiniGameCalibration.verdict(short,manifest:m))
    }
    func testReferencePlayersAndGamesAreReproducible(){
        var state=MiniGameState(kind:.rooksAndPawns,computer:false);state.snapshot.board=["a1":"wr","a5":"bp","h1":"wr","h5":"br","d4":"wp","d8":"bq"]
        XCTAssertEqual(MiniGameCalibration.referenceMove(.greedy,in:state,seed:7),MiniGameMove(from:"h1",to:"h5"),"the most valuable capture it can make")
        let legal=MiniGameRules.moves(board:state.board,kind:state.kind,side:"w")
        let random=Set((0..<64).compactMap{MiniGameCalibration.referenceMove(.random,in:state,seed:UInt64($0))}.map{$0.from+$0.to})
        XCTAssertGreaterThan(random.count,5);XCTAssertTrue(random.isSubset(of:Set(legal.map{$0.from+$0.to})))
        let a=MiniGameCalibration.play(.pawnDuel,white:.level("beginner"),black:.greedy,seed:99,maximumPlies:600)
        XCTAssertEqual(a,MiniGameCalibration.play(.pawnDuel,white:.level("beginner"),black:.greedy,seed:99,maximumPlies:600))
        XCTAssertGreaterThan(a.decisions,0);XCTAssertEqual(a.deadlineCuts,0,"the deadline is off")
        let capped=MiniGameCalibration.play(.knightCapture,white:.random,black:.random,seed:5,maximumPlies:4)
        XCTAssertTrue(capped.adjudicated);XCTAssertNil(capped.winner);XCTAssertEqual(capped.plies,4)
    }
    /// The search plays either side: the level is White in half of every pairing. Both colours take a winning capture.
    func testTheSearchPlaysEitherSide(){
        for (side,mine,theirs) in [("w","wr","bp"),("b","br","wp")] {
            var state=MiniGameState(kind:.rookSweep,computer:false);state.snapshot.board=["a1":mine,"a7":theirs,"h8":side=="w" ? "br":"wr",side=="w" ? "b2":"g7":side=="w" ? "wp":"bp"];state.snapshot.turn=side
            for profile in MiniOpponentPolicy.profiles {
                let decision=MiniGameOpponent.decide(in:state,profile:profile,seed:3,timeLimited:false)
                XCTAssertEqual(decision.move,MiniGameMove(from:"a1",to:"a7"),"\(side) \(profile)");XCTAssertEqual(decision.move,MiniGameOpponent.choose(in:state,profile:profile,seed:3,timeLimited:false))
                XCTAssertFalse(decision.deadlineCut)
            }
        }
    }
    /// The offering is calibration's verdict, from a full run of the tracked manifest at today's search policies.
    func testTheOfferingIsWhatThePublishedResultsAllow()throws {
        let data=try Data(contentsOf:Self.root.appendingPathComponent("Content/calibration/mini-game-results.json"))
        let results=try JSONDecoder().decode(MiniGameCalibration.Results.self,from:data),tracked=try manifest()
        XCTAssertFalse(results.smoke,"a smoke run never sets the offering");XCTAssertEqual(results.manifest,tracked,"the results are of the tracked manifest")
        XCTAssertEqual(Set(results.entries.map(\.game)),Set(tracked.entries.map(\.game)))
        for entry in results.entries {
            let kind=try XCTUnwrap(MiniGameKind(rawValue:entry.game))
            XCTAssertEqual(entry.policies,Dictionary(uniqueKeysWithValues:tracked.levels.map{($0,MiniOpponentPolicy.forGame(kind,profile:$0))}),"\(entry.game): a profile was retuned after calibration; calibrate again")
            let verdict=try MiniGameCalibration.verdict(entry,manifest:tracked)
            XCTAssertEqual(results.verdicts.first{$0.game==entry.game},verdict,entry.game)
            XCTAssertEqual(MiniGameOffering.calibrated[kind],verdict.offered,entry.game);XCTAssertEqual(MiniGameOffering.levels(for:kind),verdict.offered)
            XCTAssertTrue(verdict.offered.contains(MiniGameOffering.fallbackLevel))
        }
        XCTAssertEqual(MiniGameOffering.levels(for:.knightCorners),[])
    }
    func testLevelsAreShownAsGentleSteadyAndStrong(){
        XCTAssertEqual(MiniOpponentPolicy.profiles.map(MiniGameOffering.title),["Gentle","Steady","Strong"])
    }
}
