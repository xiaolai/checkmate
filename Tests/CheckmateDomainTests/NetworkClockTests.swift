import XCTest
@testable import CheckmateDomain

/// D6: settle, flag, apply; increments; pausing; the flag-fall timer; cosmetic clock messages.
final class NetworkClockTests:XCTestCase {
    private func freshID(_ net:TestNetwork)->NetworkID {NetworkID.random(using:net.random.source)}
    func testTheTenEightSevenExample(){
        var clock=NetworkClock(timeControl:.threePlusTwo,at:instant(0))!
        clock.moveApplied(by:.white)
        XCTAssertEqual(clock.active,.black);XCTAssertEqual(clock.remaining(.white),.seconds(180),"the opening move was timed by no clock: no increment")
        clock.settle(at:instant(170));XCTAssertEqual(clock.remaining(.black),.seconds(10))
        clock.settle(at:instant(172));XCTAssertEqual(clock.remaining(.black),.seconds(8),"a refused move settles too")
        clock.settle(at:instant(173));XCTAssertEqual(clock.remaining(.black),.seconds(7),"charged once, from the refusal on")
        clock.moveApplied(by:.black)
        XCTAssertEqual(clock.remaining(.black),.seconds(9),"then the increment");XCTAssertEqual(clock.active,.white);XCTAssertEqual(clock.settledAt,instant(173))
        XCTAssertEqual(clock.flagDeadline,instant(353))
        XCTAssertNil(NetworkClock(timeControl:.untimed,at:.origin),"an untimed game has no clocks at all")
    }
    func testTheTenEightSevenExampleThroughTheHost()throws {
        let net=try TestNetwork(timeControl:.threePlusTwo)
        net.script.illegal=["a7a1"]
        let (guest,_)=try net.startGame()
        try net.hostPlays("e2e4")
        try net.advance(170);XCTAssertEqual(net.host.clock?.clocks(at:net.now).black,10_000)
        try net.advance(2)
        let refused=freshID(net)
        try net.toHost(guest,.move(gameID:net.gameID,commandID:refused,revision:1,uci:"a7a1"));try net.settle()
        XCTAssertTrue(guest.received.contains(.rejected(commandID:refused,reason:.illegal)))
        XCTAssertEqual(net.host.clock?.remaining(.black),.seconds(8));XCTAssertEqual(net.host.clock?.settledAt,instant(172))
        try net.advance(1);try net.play(guest,"e7e5")
        XCTAssertEqual(net.host.clock?.remaining(.black),.seconds(9))
        guard case .moved(let moved)?=guest.received.last else{return XCTFail()}
        XCTAssertEqual(moved.clocks,NetworkClocks(white:180_000,black:9_000,active:.white))
    }
    func testBlacksClockStartsOnceWhitesFirstMoveIsApplied()throws {
        let net=try TestNetwork(timeControl:.threePlusTwo)
        let (guest,_)=try net.startGame()
        XCTAssertNil(net.host.clock?.active);XCTAssertEqual(net.host.clock?.clockStarted,false);XCTAssertNil(net.timers[.flag])
        try net.advance(10);XCTAssertEqual(net.host.clock?.clocks(at:net.now),NetworkClocks(white:180_000,black:180_000,active:nil),"White's clock is off until its first move")
        // A disconnect and resume at zero plies leaves both clocks unchanged (R4-1).
        try net.cut(guest);XCTAssertEqual(net.host.phase,.disconnected);try net.advance(20);try net.connect(guest)
        XCTAssertEqual(net.host.phase,.running);XCTAssertNil(net.host.clock?.active)
        XCTAssertEqual(net.host.clock?.remaining(.white),.seconds(180));XCTAssertEqual(net.host.clock?.remaining(.black),.seconds(180))
        try net.advance(5);try net.hostPlays("e2e4")
        XCTAssertEqual(net.host.clock?.active,.black);XCTAssertEqual(net.host.clock?.clockStarted,true);XCTAssertEqual(net.timers[.flag],instant(215))
        try net.advance(4);XCTAssertEqual(net.host.clock?.clocks(at:net.now),NetworkClocks(white:180_000,black:176_000,active:.black))
        XCTAssertEqual(guest.receiver.clocks(at:net.now)?.black,176_000,"the guest counts down locally between clock messages")
    }
    /// D6 pausing as spectators see it: the clocks stop for them when the guest drops, and run again when it returns.
    func testSpectatorsSeeTheClocksPauseAndResumeWithTheGuest()throws {
        let net=try TestNetwork(timeControl:.threePlusTwo)
        let (guest,watchers)=try net.startGame(spectators:1);let watcher=watchers[0]
        try net.hostPlays("e2e4");try net.advance(2)
        try net.cut(guest);try net.settle();XCTAssertEqual(net.host.phase,.disconnected)
        guard case .clock(let paused)?=watcher.received.last else{return XCTFail("no clock message on the pause: \(watcher.received.map(\.type))")}
        XCTAssertNil(paused.active);XCTAssertEqual(paused.black,178_000)
        try net.advance(30);XCTAssertEqual(watcher.receiver.clocks(at:net.now)?.black,178_000,"the spectator's clock stays stopped")
        try net.connect(guest);XCTAssertEqual(net.host.phase,.running)
        guard case .clock(let running)?=watcher.received.last else{return XCTFail("no clock message on the resume")}
        XCTAssertEqual(running.active,.black);XCTAssertEqual(running.black,178_000)
    }
    func testAFlagBeatsAMatingMoveAndAnAgreement()throws {
        let net=try TestNetwork(timeControl:.threePlusTwo)
        net.script.mating=["d8h4"]
        let (guest,watchers)=try net.startGame(spectators:1)
        try net.hostPlays("f2f3");try net.play(guest,"e7e5");try net.hostPlays("g2g4")
        XCTAssertEqual(net.host.clock?.flagDeadline,instant(182),"180 s and Black's increment")
        net.jump(183)
        let mate=try XCTUnwrap(try guest.receiver.submitMove(uci:"d8h4"))
        guard case .move(_,let commandID,_,_)=mate else{return XCTFail()}
        try net.toHost(guest,mate);try net.settle()
        XCTAssertEqual(net.host.outcome,NetworkOutcome(result:.whiteWins,termination:.time))
        XCTAssertEqual(net.hostMoves,["f2f3","e7e5","g2g4"],"the mating move was never applied")
        XCTAssertTrue(guest.received.contains(.rejected(commandID:commandID,reason:.gameOver)));XCTAssertNil(guest.receiver.pendingMove)
        XCTAssertEqual(watchers[0].receiver.outcome,net.host.outcome);XCTAssertEqual(net.host.clock?.clocks(at:net.now).black,0)
        let agreed=try TestNetwork(timeControl:.threePlusTwo)
        let (other,_)=try agreed.startGame()
        try agreed.hostPlays("e2e4");try agreed.perform(.offerDraw);try agreed.settle()
        agreed.jump(181)
        try agreed.command(other,other.receiver.answerDraw(accept:true))
        XCTAssertEqual(agreed.host.outcome,NetworkOutcome(result:.whiteWins,termination:.time),"the flag fell before the agreement was applied")
    }
    func testADelayedOrEarlyFlagTimerDecidesNothingByItself()throws {
        let net=try TestNetwork(timeControl:.threePlusTwo)
        let (guest,_)=try net.startGame()
        try net.hostPlays("e2e4");XCTAssertEqual(net.timers[.flag],instant(180))
        // An early fire: nothing ends, and the timer stands again.
        net.jump(100);net.timers[.flag]=nil
        try net.take(try net.host.timerFired(.flag,at:net.now));try net.settle()
        XCTAssertNil(net.host.outcome);XCTAssertEqual(net.timers[.flag],instant(180))
        // A late fire: the game ends on time, once, with the flagged clock at zero.
        net.jump(83);net.timers[.flag]=nil
        try net.take(try net.host.timerFired(.flag,at:net.now));try net.settle()
        XCTAssertEqual(net.host.outcome,NetworkOutcome(result:.whiteWins,termination:.time));XCTAssertEqual(net.host.revision,2)
        XCTAssertEqual(guest.receiver.outcome,net.host.outcome);XCTAssertEqual(net.host.clock?.clocks(at:net.now).black,0);XCTAssertNil(net.timers[.flag])
        try net.take(try net.host.timerFired(.flag,at:net.now));XCTAssertEqual(net.host.revision,2,"a second fire changes nothing")
    }
    func testPauseOnDropAndResumeFromNow()throws {
        let net=try TestNetwork(timeControl:.fivePlusThree)
        let (guest,_)=try net.startGame()
        try net.hostPlays("e2e4");try net.advance(10)
        try net.cut(guest)
        XCTAssertNil(net.host.clock?.active);XCTAssertEqual(net.host.clock?.remaining(.black),.seconds(290));XCTAssertNil(net.timers[.flag]);XCTAssertNil(net.timers[.clockMessage])
        try net.advance(60);XCTAssertEqual(net.host.clock?.clocks(at:net.now).black,290_000)
        try net.connect(guest)
        XCTAssertEqual(net.host.clock?.active,.black);XCTAssertEqual(net.host.clock?.settledAt,instant(70));XCTAssertEqual(net.timers[.flag],instant(360))
        XCTAssertEqual(guest.receiver.clocks(at:net.now),NetworkClocks(white:300_000,black:290_000,active:.black),"the resume snapshot carries the clocks")
    }
    func testABareKingFlagIsADrawAndAnythingElseLoses()throws {
        XCTAssertEqual(NetworkClock.flagOutcome(flagged:.black,opponentHasOnlyKing:true),NetworkOutcome(result:.draw,termination:.time))
        XCTAssertEqual(NetworkClock.flagOutcome(flagged:.black,opponentHasOnlyKing:false),NetworkOutcome(result:.whiteWins,termination:.time))
        XCTAssertEqual(NetworkClock.flagOutcome(flagged:.white,opponentHasOnlyKing:false),NetworkOutcome(result:.blackWins,termination:.time))
        let net=try TestNetwork(timeControl:.threePlusTwo)
        _ = try net.startGame()
        try net.hostPlays("e2e4");net.script.bareKing=[.white]
        try net.advance(181)
        XCTAssertEqual(net.host.outcome,NetworkOutcome(result:.draw,termination:.time),"the side with time left has only its king")
    }
    func testClockMessagesAreCosmeticAndAtMostOneASecond()throws {
        let net=try TestNetwork(timeControl:.tenPlusFive)
        let (guest,watchers)=try net.startGame(spectators:1)
        try net.hostPlays("e2e4");try net.advance(10)
        for client in [guest]+watchers {XCTAssertEqual(client.received.filter{if case .clock=$0 {return true};return false}.count,10)}
        XCTAssertEqual(net.host.revision,1,"clock messages never advance the revision")
        XCTAssertEqual(watchers[0].receiver.clocks(at:net.now + .milliseconds(500))?.black,589_500)
        try net.cut(guest);try net.advance(5)
        XCTAssertEqual(watchers[0].received.filter{if case .clock=$0 {return true};return false}.count,11,"only the one saying the clocks stopped, none while paused")
    }
    func testAnUntimedGameHasNoClocks()throws {
        let net=try TestNetwork()
        let (guest,_)=try net.startGame()
        try net.hostPlays("e2e4");try net.advance(30)
        XCTAssertNil(net.host.clock);XCTAssertNil(net.timers[.flag]);XCTAssertNil(net.timers[.clockMessage]);XCTAssertNil(guest.receiver.clocks(at:net.now))
        XCTAssertFalse(guest.received.contains{if case .clock=$0 {return true};return false})
        guard case .moved(let moved)?=guest.received.first(where:{if case .moved=$0 {return true};return false}) else{return XCTFail()}
        XCTAssertNil(moved.clocks);XCTAssertNil(try net.host.publicGame(at:net.now).clocks)
    }
}
