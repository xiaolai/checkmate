import XCTest
@testable import CheckmateApplication
@testable import CheckmateDomain
import CheckmateRules
import CheckmateSupport

/// The automation-only disconnect hook the `network-ui` and `network-lan` gates use (LAN-play plan, Verification): it
/// cuts the guest's connection and refuses reconnecting for 10 s; the guest then resumes the same seat.
final class NetworkFaultTransportTests:XCTestCase {
    func testADropIsALostLinkThenRefusalThenTheSameSeatResumes()throws {
        let game=try MemoryNetworkGame()
        let fault=NetworkFaultTransport(wrapping:game.transport,scheduler:game.scheduler)
        let receiver=NetworkReceiver(gameID:game.gameID,role:.guest(claimID:.random(using:.system)),name:"Ben",appVersion:"0.8.0",rules:NetworkRulesFactory{try ChessRules()},hashing:game.hashing)
        let log=NetworkEventLog<NetworkClientRunner.Event>()
        let runner=NetworkClientRunner(receiver:receiver,endpoint:game.endpoints[.seat]!,key:NetworkAccessKey(gameID:game.gameID,role:.seat,code:game.seatCode),transport:fault,scheduler:game.scheduler,reconnect:.standard){log.append($0)}
        let guest=MemoryNetworkClient(runner:runner,log:log)
        runner.start();game.scheduler.run()
        XCTAssertEqual(guest.link,.live)
        game.hostPlays("e2e4")
        // The drop lands while the guest's reply is on its way: it stays pending, and nothing is applied twice.
        fault.drop(refusingFor:.seconds(10));game.scheduler.run()
        XCTAssertEqual(fault.drops,1);XCTAssertEqual(guest.link,.reconnecting)
        runner.submitMove(uci:"e7e5");game.scheduler.run()
        XCTAssertEqual(game.host.revision,1,"no move while the link is down")
        game.scheduler.advance(by:.seconds(5));XCTAssertEqual(guest.link,.reconnecting,"still refused at 5 s")
        XCTAssertEqual(game.host.phase,.disconnected,"the host holds the seat")
        game.scheduler.advance(by:.seconds(10))
        XCTAssertEqual(guest.link,.live,"resumed after the refusal ends");XCTAssertEqual(game.host.phase,.running)
        XCTAssertEqual(guest.receiver.revision,game.host.revision)
        game.play(guest,"e7e5")
        XCTAssertEqual(game.host.revision,2)
    }
    /// A stall holds the guest's move in flight: pending on the guest, unknown to the host, applied when it ends.
    func testAStallHoldsAMovePendingUntilItEnds()throws {
        let game=try MemoryNetworkGame()
        let fault=NetworkFaultTransport(wrapping:game.transport,scheduler:game.scheduler)
        let receiver=NetworkReceiver(gameID:game.gameID,role:.guest(claimID:.random(using:.system)),name:"Ben",appVersion:"0.8.0",rules:NetworkRulesFactory{try ChessRules()},hashing:game.hashing)
        let log=NetworkEventLog<NetworkClientRunner.Event>()
        let runner=NetworkClientRunner(receiver:receiver,endpoint:game.endpoints[.seat]!,key:NetworkAccessKey(gameID:game.gameID,role:.seat,code:game.seatCode),transport:fault,scheduler:game.scheduler,reconnect:.standard){log.append($0)}
        let guest=MemoryNetworkClient(runner:runner,log:log)
        runner.start();game.scheduler.run();game.hostPlays("e2e4")
        fault.stall(for:.seconds(3));game.scheduler.run()
        runner.submitMove(uci:"e7e5");game.scheduler.run()
        XCTAssertNotNil(guest.receiver.pendingMove);XCTAssertEqual(game.host.revision,1)
        game.scheduler.advance(by:.seconds(2));XCTAssertEqual(game.host.revision,1,"still held at 2 s");XCTAssertEqual(guest.link,.live)
        game.scheduler.advance(by:.seconds(2))
        XCTAssertEqual(game.host.revision,2);XCTAssertNil(guest.receiver.pendingMove);XCTAssertEqual(fault.stallsApplied,1)
    }
}
