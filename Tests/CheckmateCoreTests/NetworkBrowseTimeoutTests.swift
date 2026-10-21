import XCTest
@testable import CheckmateApplication
@testable import CheckmateRules

/// B-26: a lobby that finds no game within ten seconds says so and points to the Local Network setting, which is the
/// usual reason; a game found clears it, and each new look starts the ten seconds again.
@MainActor final class NetworkBrowseTimeoutTests:XCTestCase {
    func testTenSecondsWithoutAGameTimesOut()throws {
        let lan=MemoryLAN(),ben=try Mac(lan,name:"Ben");ben.game.setShown(true);lan.scheduler.run()
        XCTAssertTrue(ben.game.browsing);XCTAssertFalse(ben.game.browseTimedOut)
        lan.scheduler.advance(by:.seconds(9));XCTAssertFalse(ben.game.browseTimedOut,"not before ten seconds")
        lan.scheduler.advance(by:.seconds(1));XCTAssertTrue(ben.game.browseTimedOut)
        XCTAssertEqual(ben.heard.count(NetworkGameController.browseTimeoutHelp),1,"VoiceOver hears it once")
        XCTAssertTrue(NetworkGameController.browseTimeoutHelp.contains("System Settings ▸ Privacy & Security ▸ Local Network"))
    }
    func testAGameFoundInTimeNeverTimesOut()throws {
        let lan=MemoryLAN(),ben=try Mac(lan,name:"Ben");ben.game.setShown(true);lan.scheduler.run()
        lan.scheduler.advance(by:.seconds(5))
        let ana=try Mac(lan,name:"Ana");XCTAssertTrue(ana.game.host());lan.scheduler.run()
        XCTAssertEqual(ben.game.games.count,1,"fixture: the game is found")
        lan.scheduler.advance(by:.seconds(20));XCTAssertFalse(ben.game.browseTimedOut)
    }
    func testAGameFoundLaterClearsTheTimeout()throws {
        let lan=MemoryLAN(),ben=try Mac(lan,name:"Ben");ben.game.setShown(true);lan.scheduler.run()
        lan.scheduler.advance(by:.seconds(10));XCTAssertTrue(ben.game.browseTimedOut)
        let ana=try Mac(lan,name:"Ana");XCTAssertTrue(ana.game.host());lan.scheduler.run()
        XCTAssertEqual(ben.game.games.count,1);XCTAssertFalse(ben.game.browseTimedOut)
    }
    /// Leaving the lobby resets the state, and the alarm of an earlier look never fires into a later one.
    func testEachLookStartsItsOwnTenSeconds()throws {
        let lan=MemoryLAN(),ben=try Mac(lan,name:"Ben");ben.game.setShown(true);lan.scheduler.run()
        lan.scheduler.advance(by:.seconds(10));XCTAssertTrue(ben.game.browseTimedOut)
        ben.game.setShown(false);lan.scheduler.run();XCTAssertFalse(ben.game.browseTimedOut,"a lobby no longer shown is not waiting")
        lan.scheduler.advance(by:.seconds(3));ben.game.setShown(true);lan.scheduler.run()
        ben.game.setShown(false);ben.game.setShown(true);lan.scheduler.run()
        lan.scheduler.advance(by:.seconds(9));XCTAssertFalse(ben.game.browseTimedOut,"an earlier look's alarm does not count")
        lan.scheduler.advance(by:.seconds(1));XCTAssertTrue(ben.game.browseTimedOut)
    }
}
