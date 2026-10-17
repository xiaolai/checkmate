import XCTest
@testable import CheckmateDomain

/// D2 and D4: the host's fixed check order, the seat claim and its recovery, resume, phases, spectators and bounds.
final class NetworkHostTests:XCTestCase {
    private func freshID(_ net:TestNetwork)->NetworkID {NetworkID.random(using:net.random.source)}
    private func isSnapshot(_ message:NetworkMessage)->Bool {if case .snapshotBegin=message {return true};return false}
    /// A stalled spectator asks for a snapshot, then moves are held behind it; when the send in flight completes, the
    /// first snapshot part is made. Returns the peer's queued bytes just before and just after that part, and whether
    /// the host closed it, for a host whose per-peer cap is `cap`.
    private func snapshotBehindHeldMoves(cap:Int)throws -> (before:Int,after:Int,closed:NetworkByeReason?) {
        var limits=NetworkHostLimits.standard;limits.peerQueueBytes=cap
        let net=try TestNetwork(limits:limits)
        let (guest,watchers)=try net.startGame(spectators:1);let id=watchers[0].connection!
        net.stalled.insert(id)
        try net.hostPlays("e2e4")
        try net.send(.resync,on:id)
        try net.play(guest,"e7e5");try net.hostPlays("g1f3");try net.play(guest,"b8c6")
        // Still open, with its queue known, right before the send completes: the part is what decides.
        let before=try XCTUnwrap(net.host.queuedBytes(id),"the spectator is still open before the send completes");XCTAssertNil(net.closes[id])
        try net.completeSend(id)
        return (before,net.host.queuedBytes(id) ?? -1,net.closes[id])
    }
    func testADuplicateIsAnsweredBeforeTheRevisionCheck()throws {
        let net=try TestNetwork(hostSide:.black)
        let (guest,_)=try net.startGame()
        let first=try XCTUnwrap(try guest.receiver.submitMove(uci:"e2e4"))
        guard case .move(_,let commandID,_,_,_)=first else{return XCTFail()}
        try net.toHost(guest,first);try net.settle();try net.hostPlays("e7e5")
        XCTAssertEqual(net.host.revision,2)
        // The same command again, now two revisions old: the stored receipt, and nothing else.
        let before=guest.received.count
        try net.toHost(guest,first);try net.settle()
        let replies=Array(guest.received[before...])
        XCTAssertEqual(replies.count,1)
        guard case .moved(let receipt)?=replies.first else{return XCTFail("\(replies)")}
        XCTAssertEqual(receipt.revision,1);XCTAssertEqual(receipt.receiptFor,commandID)
        XCTAssertEqual(net.host.revision,2);XCTAssertEqual(net.hostMoves,["e2e4","e7e5"]);XCTAssertEqual(guest.receiver.revision,2)
        // A new command at that stale revision is refused, then a snapshot follows.
        let stale=freshID(net)
        try net.toHost(guest,.move(gameID:net.gameID,commandID:stale,revision:0,uci:"d2d4"));try net.settle()
        let answer=Array(guest.received[(before+1)...])
        XCTAssertEqual(answer.first,.rejected(commandID:stale,reason:.stale));XCTAssertTrue(answer.dropFirst().contains(where:isSnapshot))
        XCTAssertEqual(net.host.revision,2);XCTAssertEqual(guest.receiver.revision,2)
    }
    func testAWrongTurnCommandChangesNothing()throws {
        let net=try TestNetwork(timeControl:.fivePlusThree)
        let (guest,watchers)=try net.startGame(spectators:1)
        try net.hostPlays("e2e4");try net.play(guest,"e7e5")
        net.jump(0.5)
        let game=try net.host.publicGame(at:net.now),seen=net.sent[watchers[0].connection!]!.count,command=freshID(net)
        try net.toHost(guest,.move(gameID:net.gameID,commandID:command,revision:2,uci:"d7d5"));try net.settle()
        XCTAssertEqual(guest.received.last,.rejected(commandID:command,reason:.notYourTurn))
        XCTAssertEqual(try net.host.publicGame(at:net.now),game,"the same board, record, clocks as they read now, offer and result")
        XCTAssertEqual(net.host.revision,2);XCTAssertEqual(net.sent[watchers[0].connection!]!.count,seen,"spectators saw nothing")
        XCTAssertFalse(guest.received.suffix(2).contains(where:isSnapshot),"only a stale command earns a snapshot")
    }
    func testAnotherGamesCommandAndTheReceiptWindow()throws {
        let net=try TestNetwork(hostSide:.black)
        let (guest,_)=try net.startGame()
        let foreign=freshID(net)
        try net.toHost(guest,.move(gameID:NetworkGameID.random(using:net.random.source),commandID:foreign,revision:0,uci:"e2e4"));try net.settle()
        XCTAssertEqual(guest.received.last,.rejected(commandID:foreign,reason:.wrongGame));XCTAssertEqual(net.host.storedReceipts,0);XCTAssertEqual(net.host.revision,0)
        // 65 refused commands, spaced under the inbound rate: the first receipt is forgotten.
        net.script.illegal=["a2a3"]
        let ids=(0..<65).map{_ in freshID(net)}
        for id in ids {try net.toHost(guest,.move(gameID:net.gameID,commandID:id,revision:0,uci:"a2a3"));try net.advance(0.06)}
        XCTAssertNil(guest.closedWith);XCTAssertEqual(net.host.storedReceipts,64)
        net.script.illegal=[]
        try net.toHost(guest,.move(gameID:net.gameID,commandID:ids[1],revision:0,uci:"a2a3"));try net.settle()
        XCTAssertEqual(guest.received.last,.rejected(commandID:ids[1],reason:.illegal),"still remembered: the stored answer, not a new one")
        try net.toHost(guest,.move(gameID:net.gameID,commandID:ids[0],revision:0,uci:"a2a3"));try net.settle()
        guard case .moved(let moved)?=guest.received.last else{return XCTFail()}
        XCTAssertEqual(moved.receiptFor,ids[0],"forgotten, so processed afresh");XCTAssertEqual(net.host.revision,1)
    }
    func testALostSeatedIsResentAndTheClaimStopsWorkingAfterTheAck()throws {
        let net=try TestNetwork()
        let claim=NetworkSecret.random(using:net.random.source)
        let first=try net.open(.seat);try net.send(.hello(name:"Ben",appVersion:"0.8.0",claimID:claim),on:first)
        guard case .seated(let credential)?=net.messages(first).first else{return XCTFail()}
        XCTAssertEqual(net.host.phase,.reserved);XCTAssertTrue(net.messages(first).contains(where:isSnapshot))
        try net.take(try net.host.connectionClosed(first,at:net.now))
        XCTAssertEqual(net.host.phase,.reserved,"the reservation outlives the connection")
        let second=try net.open(.seat);try net.send(.hello(name:"Ben",appVersion:"0.8.0",claimID:claim),on:second)
        XCTAssertEqual(net.messages(second).first,.seated(credential:credential),"the same seated, the same credential");XCTAssertTrue(net.messages(second).contains(where:isSnapshot))
        let rival=try net.open(.seat);try net.send(.hello(name:"Cy",appVersion:"0.8.0",claimID:NetworkSecret.random(using:net.random.source)),on:rival)
        XCTAssertEqual(net.closes[rival],.seatTaken)
        try net.send(.seatedAck,on:second)
        XCTAssertEqual(net.host.phase,.running);XCTAssertNil(net.timers[.reservation])
        let late=try net.open(.seat);try net.send(.hello(name:"Ben",appVersion:"0.8.0",claimID:claim),on:late)
        XCTAssertEqual(net.closes[late],.seatTaken,"after seatedAck only the credential resumes");XCTAssertEqual(net.host.guestConnection,second)
    }
    func testAReservationWithoutAnAckLapsesAtThirtySeconds()throws {
        let net=try TestNetwork()
        let guest=net.client(.seat);guest.lose=["seatedAck"];try net.connect(guest)
        XCTAssertEqual(net.host.phase,.reserved);XCTAssertEqual(net.host.reservationDeadline,instant(30));XCTAssertEqual(net.timers[.reservation],instant(30))
        try net.advance(29.9);XCTAssertEqual(net.host.phase,.reserved)
        try net.advance(0.1)
        XCTAssertEqual(net.host.phase,.waiting);XCTAssertNil(net.host.guestName);XCTAssertEqual(guest.closedWith,.timeout);XCTAssertEqual(net.host.revision,0)
        let other=net.client(.seat,name:"Cy");try net.connect(other)
        XCTAssertEqual(net.host.phase,.running,"the seat was free");XCTAssertEqual(net.host.guestName,"Cy")
        guest.lose=[];try net.connect(guest)
        XCTAssertEqual(guest.closedWith,.badCredential,"the lapsed reservation's credential is dead")
    }
    func testACutBeforeOrAfterTheAckRecoversTheSameSeat()throws {
        for ackArrived in [false,true] {
            let net=try TestNetwork()
            let guest=net.client(.seat)
            if !ackArrived {guest.lose=["seatedAck"]}
            try net.connect(guest)
            XCTAssertEqual(net.host.phase,ackArrived ? .running:.reserved)
            let credential=try XCTUnwrap(guest.receiver.credential)
            try net.cut(guest)
            XCTAssertEqual(net.host.phase,ackArrived ? .disconnected:.reserved)
            let rival=net.client(.seat,name:"Cy");try net.connect(rival)
            XCTAssertEqual(rival.closedWith,.seatTaken,"no other claimant while the seat is reserved or held")
            guest.lose=[];try net.connect(guest)
            XCTAssertEqual(guest.received.filter{$0 == .resumed}.count,1,"it resumed with its credential")
            XCTAssertEqual(net.host.phase,.running);XCTAssertEqual(net.host.guestConnection,guest.connection)
            XCTAssertTrue(guest.receiver.credential!.matches(credential));XCTAssertNil(net.host.reservationDeadline);XCTAssertNil(net.timers[.reservation]);XCTAssertNil(net.host.holdDeadline)
            try net.advance(40);XCTAssertEqual(net.host.phase,.running,"nothing expires")
            try net.hostPlays("e2e4");try net.play(guest,"e7e5");XCTAssertEqual(net.host.revision,2)
        }
    }
    func testAStaleGenerationsCloseDoesNotDetachTheResumedGuest()throws {
        let net=try TestNetwork()
        let (guest,_)=try net.startGame()
        let old=try XCTUnwrap(guest.connection)
        try net.cut(guest,tell:false)
        try net.connect(guest)
        let new=try XCTUnwrap(guest.connection)
        XCTAssertEqual(net.closes[old],.replaced,"the older connection holding the seat is closed first");XCTAssertEqual(net.host.guestConnection,new)
        try net.take(try net.host.connectionClosed(old,at:net.now))
        try net.take(try net.host.receive(message:.resign(gameID:net.gameID,commandID:freshID(net)),from:old,at:net.now))
        try net.take(try net.host.sendCompleted(old,at:net.now))
        XCTAssertEqual(net.host.phase,.running);XCTAssertEqual(net.host.guestConnection,new);XCTAssertNil(net.host.outcome)
        // A lost `resumed` is safe to retry, from a new connection or from the current holder.
        try net.cut(guest,tell:false);try net.connect(guest)
        try net.toHost(guest,guest.receiver.opening());try net.settle()
        XCTAssertEqual(guest.received.filter{$0 == .resumed}.count,3);XCTAssertEqual(net.host.phase,.running);XCTAssertNil(guest.closedWith)
    }
    func testNoMoveWhileReserved()throws {
        let net=try TestNetwork(hostSide:.black)
        let guest=net.client(.seat);guest.lose=["seatedAck"];try net.connect(guest)
        XCTAssertEqual(net.host.phase,.reserved)
        let move=try XCTUnwrap(try guest.receiver.submitMove(uci:"e2e4"))
        guard case .move(_,let commandID,_,_,_)=move else{return XCTFail()}
        try net.toHost(guest,move);try net.settle()
        XCTAssertEqual(guest.received.last,.rejected(commandID:commandID,reason:.notRunning));XCTAssertNil(guest.receiver.pendingMove)
        try net.hostPlays("e7e5");XCTAssertEqual(net.refusals,[.notRunning],"the host has no shortcut either")
        try net.perform(.resign);XCTAssertEqual(net.refusals,[.notRunning,.notRunning])
        XCTAssertEqual(net.host.revision,0);XCTAssertEqual(net.hostMoves,[])
    }
    func testTheHostsOwnMovesPassTheSameRules()throws {
        let net=try TestNetwork()
        let (guest,_)=try net.startGame()
        net.script.illegal=["e2e5"]
        try net.hostPlays("e2e5");try net.hostPlays("e2e4");try net.hostPlays("d2d4")
        XCTAssertEqual(net.refusals,[.illegal,.notYourTurn]);XCTAssertEqual(net.hostMoves,["e2e4"]);XCTAssertEqual(guest.receiver.revision,1)
    }
    /// D7: a snapshot part made while moves are held must fit the peer's cap like any other message, or the peer is
    /// closed as slow; it may never leave the queue over its cap.
    func testASnapshotPartThatWouldOverfillAPeerClosesItAsSlow()throws {
        let roomy=try snapshotBehindHeldMoves(cap:NetworkLimits.peerQueueBytes)
        XCTAssertNil(roomy.closed)
        // A cap the held moves fit under, but not the part that follows them.
        let tight=try snapshotBehindHeldMoves(cap:roomy.after-1)
        XCTAssertLessThanOrEqual(tight.before,roomy.after-1,"the held moves themselves fit")
        XCTAssertEqual(tight.closed,.slow,"the part would have taken the queue over its cap")
    }
    func testSpectatorsWatchButCannotPlay()throws {
        let net=try TestNetwork(hostSide:.black)
        let (guest,watchers)=try net.startGame(spectators:8)
        XCTAssertEqual(net.host.spectators.count,8);XCTAssertEqual(net.host.spectatorNames.count,8)
        let ninth=net.client(.watch,name:"Late");try net.connect(ninth);XCTAssertEqual(ninth.closedWith,.full)
        for watcher in watchers {XCTAssertEqual(watcher.received.first,.watching);XCTAssertEqual(watcher.receiver.revision,0)}
        try net.play(guest,"e2e4")
        for watcher in watchers {guard case .moved(let moved)?=watcher.received.last else{XCTFail();continue};XCTAssertNil(moved.receiptFor,"no receipt for spectators");XCTAssertEqual(watcher.receiver.revision,1)}
        guard case .moved(let mine)?=guest.received.last else{return XCTFail()}
        XCTAssertNotNil(mine.receiptFor)
        try net.toHost(watchers[0],.move(gameID:net.gameID,commandID:freshID(net),revision:1,uci:"e7e5"));try net.settle()
        XCTAssertEqual(watchers[0].closedWith,.notAllowed);XCTAssertEqual(net.host.spectators.count,7);XCTAssertEqual(net.host.revision,1)
        try net.toHost(watchers[1],.hello(name:"Again",appVersion:"1",claimID:nil));try net.toHost(watchers[1],.resync);try net.settle()
        XCTAssertNil(watchers[1].closedWith);XCTAssertEqual(watchers[1].events.filter{$0 == .installed(revision:1)}.count,1)
        let leaving=try XCTUnwrap(watchers[2].connection)
        try net.toHost(watchers[2],.bye(.leaving));XCTAssertEqual(net.closes[leaving],.leaving);XCTAssertEqual(net.host.spectators.count,6)
        try net.toHost(guest,.bye(.leaving));XCTAssertEqual(net.host.phase,.disconnected,"a guest saying bye has dropped; its seat is held")
        let closed=try TestNetwork(spectators:false)
        let watcher=closed.client(.watch);try closed.connect(watcher);XCTAssertEqual(watcher.closedWith,.notAllowed)
    }
    func testAdmissionSlotsAndTheFiveSecondDeadline()throws {
        let net=try TestNetwork()
        let pending=try (0..<4).map{_ in try net.open(.watch)}
        let fifth=try net.open(.watch);XCTAssertEqual(net.closes[fifth],.busy)
        let seat=try net.open(.seat);XCTAssertNil(net.closes[seat],"slots are counted per listener")
        XCTAssertEqual(net.timers[.admission(pending[0])],instant(5))
        try net.advance(4.9);XCTAssertEqual(net.host.pendingConnections.count,5)
        try net.advance(0.1)
        for id in pending+[seat] {XCTAssertEqual(net.closes[id],.timeout)}
        XCTAssertTrue(net.host.pendingConnections.isEmpty);XCTAssertTrue(net.timers.isEmpty)
        let early=try net.open(.seat);try net.send(.resync,on:early);XCTAssertEqual(net.closes[early],.malformed,"hello or resume first")
        let anonymous=try net.open(.seat);try net.send(.hello(name:"Ben",appVersion:"1",claimID:nil),on:anonymous);XCTAssertEqual(net.closes[anonymous],.malformed,"a seat hello carries a claim")
        let watcher=try net.open(.watch);try net.send(.resume(gameID:net.gameID,credential:NetworkSecret.random(using:net.random.source)),on:watcher);XCTAssertEqual(net.closes[watcher],.malformed)
        let garbage=try net.open(.seat);try net.take(try net.host.receive(Data("{]".utf8),from:garbage,at:net.now));XCTAssertEqual(net.closes[garbage],.malformed)
        let future=try net.open(.seat)
        try net.take(try net.host.receive(Data(#"{"type":"hello","protocol":{"major":2,"minor":0}}"#.utf8),from:future,at:net.now));XCTAssertEqual(net.closes[future],.protocolVersion)
    }
    /// A close that arrives just as a ping falls due is applied first: the host never sends to the connection it is
    /// being told has gone (the network-ui gate once stopped a game this way), and still pings everyone else.
    func testAClosedConnectionIsGoneBeforeAPingDueAtTheSameInstant()throws {
        let net=try TestNetwork(hostSide:.black)
        let (guest,watchers)=try net.startGame(spectators:1)
        let id=try XCTUnwrap(guest.connection),watcher=try XCTUnwrap(watchers[0].connection)
        let toGuest=net.sent[id]?.count ?? 0,toWatcher=net.sent[watcher]?.count ?? 0
        net.jump(2)
        try net.cut(guest)
        XCTAssertEqual(net.sent[id]?.count ?? 0,toGuest,"nothing for the closed connection")
        XCTAssertEqual(net.host.phase,.disconnected)
        XCTAssertGreaterThan(net.sent[watcher]?.count ?? 0,toWatcher,"the spectator is still pinged")
    }
    func testPingsEveryTwoSecondsAndAMissedPongDropsTheGuest()throws {
        let net=try TestNetwork(hostSide:.black,timeControl:.fivePlusThree)
        let (guest,watchers)=try net.startGame(spectators:1)
        try net.play(guest,"e2e4");try net.hostPlays("e7e5")
        XCTAssertEqual(net.timers[.ping],instant(2))
        try net.advance(2)
        XCTAssertEqual(guest.received.filter{if case .ping=$0 {return true};return false}.count,1);XCTAssertEqual(net.host.outstandingPings,0)
        guest.silent=true
        try net.advance(7.9);XCTAssertEqual(net.host.phase,.running,"pings at 4 and 6 unanswered, at most two outstanding")
        try net.advance(0.1)
        XCTAssertEqual(net.host.phase,.disconnected,"six seconds after the first unanswered ping");XCTAssertEqual(guest.closedWith,.timeout)
        XCTAssertNil(net.host.clock?.active);XCTAssertEqual(net.host.clock?.remaining(.white),.seconds(290))
        try net.advance(30);XCTAssertEqual(net.host.clock?.remaining(.white),.seconds(290),"paused while away")
        XCTAssertNil(watchers[0].closedWith,"the spectator answered every ping")
        try net.toHost(watchers[0],.pong(nonce:freshID(net)));try net.settle();XCTAssertEqual(watchers[0].closedWith,.malformed,"a pong must match an outstanding ping")
    }
    func testTwentyOneMessagesInASecondCloseThePeer()throws {
        let net=try TestNetwork()
        let (_,watchers)=try net.startGame(spectators:1)
        for _ in 0..<19 {try net.toHost(watchers[0],.resync)}
        try net.settle();XCTAssertNil(watchers[0].closedWith,"hello and 19 more: twenty")
        try net.toHost(watchers[0],.resync);try net.settle();XCTAssertEqual(watchers[0].closedWith,.rateLimited)
    }
    func testTheHoldOffersClaimWinOrKeepWaiting()throws {
        let net=try TestNetwork(timeControl:.tenPlusFive)
        let (guest,watchers)=try net.startGame(spectators:1)
        try net.hostPlays("e2e4");try net.advance(1);try net.cut(guest)
        XCTAssertEqual(net.host.phase,.disconnected);XCTAssertEqual(net.host.holdDeadline,instant(121));XCTAssertEqual(net.timers[.hold],instant(121))
        XCTAssertEqual(net.host.clock?.remaining(.black),.seconds(599))
        try net.perform(.claimWin);try net.perform(.keepWaiting);XCTAssertEqual(net.refusals,[.notRunning,.notRunning],"not before the hold expires")
        try net.advance(120);XCTAssertTrue(net.host.holdExpired);XCTAssertNil(net.timers[.hold])
        try net.perform(.keepWaiting);XCTAssertEqual(net.host.holdDeadline,instant(241));XCTAssertFalse(net.host.holdExpired)
        try net.advance(120);XCTAssertTrue(net.host.holdExpired);XCTAssertEqual(net.host.clock?.remaining(.black),.seconds(599))
        try net.perform(.claimWin);try net.settle()
        XCTAssertEqual(net.host.outcome,NetworkOutcome(result:.whiteWins,termination:.abandoned));XCTAssertEqual(watchers[0].receiver.outcome,net.host.outcome)
        try net.connect(guest);XCTAssertEqual(guest.closedWith,.gameOver,"ended kills the credential")
        // Resume stays valid after the hold expires, until the host claims.
        let other=try TestNetwork(timeControl:.tenPlusFive)
        let (away,_)=try other.startGame()
        try other.hostPlays("e2e4");try other.cut(away);try other.advance(130)
        XCTAssertTrue(other.host.holdExpired);try other.connect(away)
        XCTAssertEqual(other.host.phase,.running);XCTAssertFalse(other.host.holdExpired);XCTAssertNil(other.host.holdDeadline);XCTAssertEqual(other.host.clock?.active,.black)
    }
    func testLeavingResignsAndEndedReachesEveryoneBeforeTheClose()throws {
        let net=try TestNetwork()
        let (guest,watchers)=try net.startGame(spectators:2)
        try net.hostPlays("e2e4");try net.perform(.leave);try net.settle()
        XCTAssertEqual(net.host.outcome,NetworkOutcome(result:.blackWins,termination:.resignation));XCTAssertTrue(net.stoppedListening)
        for client in [guest]+watchers {
            XCTAssertEqual(client.receiver.outcome,net.host.outcome);XCTAssertEqual(client.closedWith,.hostLeft)
            guard case .ended(let ended)?=client.received.last else{XCTFail();continue}
            XCTAssertEqual(ended.revision,2)
        }
        let late=try net.open(.watch);XCTAssertEqual(net.closes[late],.hostLeft);XCTAssertTrue(net.timers.isEmpty)
        // With the guest away, leaving still resigns.
        let away=try TestNetwork()
        let (absent,_)=try away.startGame()
        try away.hostPlays("e2e4");try away.cut(absent);try away.perform(.leave)
        XCTAssertEqual(away.host.outcome,NetworkOutcome(result:.blackWins,termination:.resignation))
        // Before anyone sits down there is no game to resign: everyone is simply closed.
        let empty=try TestNetwork()
        let watcher=empty.client(.watch);try empty.connect(watcher);try empty.perform(.leave);try empty.settle()
        XCTAssertNil(empty.host.outcome);XCTAssertEqual(empty.host.phase,.ended);XCTAssertEqual(watcher.closedWith,.hostLeft)
    }
    func testCrossingOffersAreAgreement()throws {
        let net=try TestNetwork()
        let (guest,watchers)=try net.startGame(spectators:1)
        try net.hostPlays("e2e4");try net.play(guest,"e7e5")
        let offer=try XCTUnwrap(guest.receiver.offerDraw())
        try net.perform(.offerDraw)
        try net.toHost(guest,offer);try net.settle()
        XCTAssertEqual(net.host.outcome,NetworkOutcome(result:.draw,termination:.agreement));XCTAssertEqual(net.host.revision,3,"offers never advance the revision; ended does")
        XCTAssertEqual(watchers[0].receiver.outcome,net.host.outcome);XCTAssertEqual(guest.receiver.outcome,net.host.outcome)
    }
    func testOffersLapseWhenTheOfferedPlayerMovesAndDeclinesReachEveryone()throws {
        let net=try TestNetwork()
        let (guest,watchers)=try net.startGame(spectators:1)
        try net.perform(.offerDraw);try net.settle()
        XCTAssertEqual(guest.receiver.openOffer?.by,.white);XCTAssertEqual(watchers[0].receiver.openOffer,net.host.openOffer);XCTAssertEqual(net.host.revision,0)
        try net.perform(.offerDraw);XCTAssertEqual(net.refusals,[.offerPending],"at most one open offer")
        try net.hostPlays("e2e4");XCTAssertNotNil(net.host.openOffer,"the offerer moving keeps it open");XCTAssertNotNil(watchers[0].receiver.openOffer)
        try net.play(guest,"e7e5")
        XCTAssertNil(net.host.openOffer,"it lapses when the player it was made to moves");XCTAssertNil(guest.receiver.openOffer);XCTAssertNil(watchers[0].receiver.openOffer)
        try net.command(guest,guest.receiver.offerDraw());XCTAssertEqual(net.host.openOffer?.by,.black)
        XCTAssertNil(guest.receiver.answerDraw(accept:true),"nobody answers their own offer")
        try net.perform(.answerDraw(accept:false));try net.settle()
        XCTAssertNil(net.host.openOffer);XCTAssertNil(watchers[0].receiver.openOffer);XCTAssertTrue(watchers[0].received.contains{if case .drawDeclined=$0 {return true};return false})
        let stray=freshID(net)
        try net.toHost(guest,.drawAnswer(gameID:net.gameID,commandID:stray,offerID:freshID(net),accept:true));try net.settle()
        XCTAssertEqual(guest.received.last,.rejected(commandID:stray,reason:.noOffer));XCTAssertNil(net.host.outcome)
    }
    func testOnlyTheSideToMoveMayClaimAndOnlyWhatTheRulesAllow()throws {
        let net=try TestNetwork()
        let (guest,_)=try net.startGame()
        try net.hostPlays("g1f3")
        net.script.claimable = .repetition
        try net.perform(.claimDraw);XCTAssertEqual(net.refusals,[.notYourTurn],"the host is not to move")
        net.script.claimable=nil
        try net.command(guest,guest.receiver.claimDraw())
        guard case .rejected(_,.notClaimable)?=guest.received.last else{return XCTFail("\(String(describing:guest.received.last))")}
        net.script.claimable = .fiftyMoves
        try net.play(guest,"g8f6")
        let revision=net.host.revision
        try net.command(guest,guest.receiver.claimDraw())
        guard case .rejected(_,.notYourTurn)?=guest.received.last else{return XCTFail()}
        XCTAssertNil(net.host.outcome);XCTAssertEqual(net.host.revision,revision)
        try net.perform(.claimDraw)
        XCTAssertEqual(net.host.outcome,NetworkOutcome(result:.draw,termination:.fiftyMoves));XCTAssertEqual(net.host.revision,revision+1)
    }
    func testResignationAndAMatingMoveEndTheGame()throws {
        let net=try TestNetwork(hostSide:.black)
        net.script.mating=["d1h5"]
        let (guest,watchers)=try net.startGame(spectators:1)
        try net.play(guest,"e2e4");try net.hostPlays("f7f6");try net.play(guest,"d1h5")
        XCTAssertEqual(net.host.outcome,NetworkOutcome(result:.whiteWins,termination:.checkmate));XCTAssertEqual(net.host.revision,4,"three moves, then ended")
        XCTAssertEqual(watchers[0].receiver.outcome,net.host.outcome);XCTAssertEqual(watchers[0].receiver.revision,4)
        XCTAssertNil(try guest.receiver.submitMove(uci:"a2a3"),"nothing to play after the end");try net.hostPlays("a7a6");XCTAssertEqual(net.refusals,[.gameOver])
        let resigned=try TestNetwork()
        let (other,_)=try resigned.startGame()
        try resigned.command(other,other.receiver.resign())
        XCTAssertEqual(resigned.host.outcome,NetworkOutcome(result:.whiteWins,termination:.resignation))
    }
    /// Spectators learn the guest's name only from a snapshot: one watching before the guest arrives gets a fresh one
    /// when a seat is reserved, and again when a reservation lapses, even while an earlier snapshot is on its way.
    func testSpectatorsLearnTheGuestsNameWhenItChanges()throws {
        let net=try TestNetwork()
        let early=net.client(.watch,name:"Cy");try net.connect(early)
        XCTAssertNil(early.receiver.installed?.blackName)
        // A claim that is never acknowledged: Ben's name, then none once the reservation lapses.
        let ben=net.client(.seat,name:"Ben");ben.lose=["seatedAck"];try net.connect(ben)
        XCTAssertEqual(net.host.phase,.reserved);XCTAssertEqual(early.receiver.installed?.blackName,"Ben")
        try net.advance(31);XCTAssertEqual(net.host.phase,.waiting);XCTAssertNil(early.receiver.installed?.blackName,"the lapsed claimant's name goes")
        // Dee claims while the spectator's earlier snapshot is still on its way: a fresh one follows it.
        let id=try XCTUnwrap(early.connection);net.stalled.insert(id)
        try net.toHost(early,.resync);try net.settle()
        let dee=net.client(.seat,name:"Dee");try net.connect(dee)
        XCTAssertEqual(net.host.phase,.running)
        net.stalled.remove(id)
        for _ in 0..<64 where net.host.queuedBytes(id) != 0 {try net.completeSend(id);try net.settle()}
        XCTAssertEqual(early.receiver.installed?.blackName,"Dee");XCTAssertNil(early.closedWith)
        let late=net.client(.watch,name:"Late");try net.connect(late);XCTAssertEqual(late.receiver.installed?.blackName,"Dee")
    }
}
