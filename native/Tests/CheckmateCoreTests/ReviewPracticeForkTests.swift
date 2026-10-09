import XCTest
@testable import CheckmateCore
@MainActor final class ReviewPracticeForkTests:XCTestCase {
    func testBlackForkAndHistory()throws {let d=try PGNImporter.parse(Data("1. e4 *".utf8))[0],rules=try d.rules(at:1),session=try GameSession(engine:nil);try session.installPracticeFork(rules,side:"b");XCTAssertEqual(session.humanSide,"b");XCTAssertEqual(session.rules.history,["e4"]);try session.playWhite(from:"e7",to:"e5");XCTAssertEqual(session.rules.turn,"w");XCTAssertEqual(d.mainline.count,1)}
    func testTerminalRefused()throws {let r=try ChessRules(fen:"7k/6Q1/6K1/8/8/8/8/8 b - - 0 1"),s=try GameSession(engine:nil);XCTAssertThrowsError(try s.installPracticeFork(r,side:"b"))}
    func testClaimableDrawForkCanContinueWithoutLosingHistory()throws {
        let d=try PGNImporter.parse(Data("1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 Nf6 4. Ng1 Ng8 *".utf8))[0],node=d.mainline.last!,status=try d.status(at:node)
        XCTAssertTrue(status.claimableThreefold);XCTAssertFalse(status.terminal)
        let session=try GameSession(engine:nil);try session.installPracticeFork(d.rules(at:node),side:"w")
        XCTAssertEqual(session.rules.history.count,8)
        XCTAssertNoThrow(try session.playWhite(from:"e2",to:"e4"),"A claimable draw is not an automatic terminal position")
        XCTAssertEqual(session.rules.history.count,9)
    }

}
