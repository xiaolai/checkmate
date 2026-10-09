import XCTest
@testable import CheckmateCore
final class OpponentPolicyTests:XCTestCase {
    func testMigrationAndModes(){let old=AppSettings(raw:["skill":17]);XCTAssertEqual(old.opponentMode,"skill");XCTAssertEqual(old.skill,17);XCTAssertEqual(OpponentProfile.skill(17).options["UCI_LimitStrength"],"false");XCTAssertEqual(OpponentProfile.elo(1500).options["UCI_LimitStrength"],"true");XCTAssertEqual(AnalysisPolicy.options["Skill Level"],"20")}
    func testQualityAbstains(){XCTAssertEqual(MoveQuality.compare(best:AnalysisScore(kind:"mate",value:3),played:AnalysisScore(kind:"cp",value:300),mover:"b",stable:true),"mate-outcome-changed");XCTAssertEqual(MoveQuality.compare(best:AnalysisScore(kind:"mate",value:3),played:AnalysisScore(kind:"cp",value:300),mover:"b",stable:false),"provisional");XCTAssertEqual(MoveQuality.compare(best:AnalysisScore(kind:"cp",value:10),played:AnalysisScore(kind:"cp",value:20),mover:"b",stable:true),"near-best")}
}
@MainActor final class ReviewAnalyzerTests:XCTestCase {
    func testHistoryIdentityAndRealEngine()async throws {
        let d=try PGNImporter.parse(Data("1. Nf3 Nf6 2. Ng1 Ng8 *".utf8))[0]
        XCTAssertNotEqual(try d.historyHash(to:0),try d.historyHash(to:d.mainline.last!))
        let engine=NativeEngine();let result=try await engine.analyzeHistory(startFEN:d.startingFEN,moves:try d.history(to:4),profile:.skill(20),budget:100,multiPv:2)
        XCTAssertNotNil(result.bestMove);XCTAssertTrue(engine.capabilities.options.contains("UCI_Elo"));XCTAssertTrue(result.lines.allSatisfy{$0.depth==result.lines.first?.depth})
        let terminal=try await engine.analyze(fen:"7k/6Q1/6K1/8/8/8/8/8 b - - 0 1",skill:20,budget:100,multiPv:1)
        XCTAssertNil(terminal.bestMove)
    }
}
