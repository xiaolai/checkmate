import XCTest
@testable import CheckmateApplication
@testable import CheckmateDomain
import CheckmateRules
import CheckmateSupport

/// Records what a runner reports, in order.
final class NetworkEventLog<Event> {
    private(set) var events:[Event]=[]
    func append(_ event:Event){events.append(event)}
}
/// One guest or spectator, its runner and what it reported.
final class MemoryNetworkClient {
    let runner:NetworkClientRunner,log:NetworkEventLog<NetworkClientRunner.Event>
    init(runner:NetworkClientRunner,log:NetworkEventLog<NetworkClientRunner.Event>){self.runner=runner;self.log=log}
    var receiver:NetworkReceiver {runner.receiver}
    var status:NetworkClientStatus? {for case .status(let status) in log.events.reversed() {return status};return nil}
    var link:NetworkClientStatus.Link? {status?.link}
    var receiverEvents:[NetworkReceiverEvent] {log.events.compactMap{if case .receiver(let event)=$0 {return event};return nil}}
    var appliedMoves:[NetworkMoved] {receiverEvents.compactMap{if case .applied(let moved,_)=$0 {return moved};return nil}}
}
/// A hosted game on the real rules, its host runner and its players, over the in-memory transport on one manual
/// scheduler. Time moves only when a test moves it, so every run is the same run; the test thread is the queue.
final class MemoryNetworkGame {
    let scheduler=NetworkManualScheduler()
    let transport:NetworkMemoryTransport
    let gameID=NetworkGameID.random(using:.system)
    let seatCode=NetworkCode.random(using:.system),watchCode=NetworkCode.random(using:.system)
    let hashing=NetworkHashing(reviewHash)
    let hostLog=NetworkEventLog<NetworkHostRunner.Event>()
    let runner:NetworkHostRunner
    init(hostSide:NetworkSide = .white,timeControl:NetworkTimeControl = .untimed,spectators:Bool=true,limits:NetworkHostLimits = .standard,assistance:NetworkAssistance = .off,rules:NetworkRulesFactory=NetworkRulesFactory{try ChessRules()})throws {
        transport=NetworkMemoryTransport(scheduler:scheduler)
        let host=try NetworkHost(gameID:gameID,runEpoch:.random(using:.system),settings:NetworkHostSettings(hostName:"Ana",hostSide:hostSide,timeControl:timeControl,allowSpectators:spectators,assistance:assistance),rules:rules,hashing:hashing,limits:limits,at:scheduler.now)
        let configuration=NetworkHostingConfiguration(gameID:gameID,seatCode:seatCode,watchCode:spectators ? watchCode:nil,serviceName:"Ana's game")
        let log=hostLog
        runner=NetworkHostRunner(host:host,configuration:configuration,transport:transport,scheduler:scheduler){log.append($0)}
        runner.start();scheduler.run()
    }
    var host:NetworkHost {runner.host}
    var hosting:NetworkMemoryHosting {runner.hosting as! NetworkMemoryHosting}
    var endpoints:[NetworkListenerRole:NetworkEndpoint] {for case .listening(let endpoints) in hostLog.events {return endpoints};return [:]}
    /// The guest's open connection, found by the key it used.
    var guestLink:NetworkMemoryLink? {transport.links.last{$0.key.role == .seat && $0.open && $0.connection != nil}}
    func join(_ role:NetworkListenerRole,name:String="Ben",code:NetworkCode?=nil,accepting:NetworkAssistance = .off,reconnect:NetworkReconnectPolicy? = .standard)->MemoryNetworkClient {
        let receiver=NetworkReceiver(gameID:gameID,role:role == .seat ? .guest(claimID:.random(using:.system)):.spectator,name:name,appVersion:"0.8.0",rules:NetworkRulesFactory{try ChessRules()},hashing:hashing,accepting:accepting)
        let log=NetworkEventLog<NetworkClientRunner.Event>()
        let key=NetworkAccessKey(gameID:gameID,role:role,code:code ?? (role == .seat ? seatCode:watchCode))
        let runner=NetworkClientRunner(receiver:receiver,endpoint:endpoints[role]!,key:key,transport:transport,scheduler:scheduler,reconnect:reconnect){log.append($0)}
        runner.start();scheduler.run()
        return MemoryNetworkClient(runner:runner,log:log)
    }
    func perform(_ action:NetworkHostAction){runner.perform(action);scheduler.run()}
    func hostPlays(_ uci:String,file:StaticString=#filePath,line:UInt=#line){
        let before=host.revision;perform(.move(uci:uci))
        XCTAssertEqual(host.revision,before+1,"the host's \(uci) was applied",file:file,line:line)
    }
    func play(_ client:MemoryNetworkClient,_ uci:String,file:StaticString=#filePath,line:UInt=#line){
        let before=host.revision;client.runner.submitMove(uci:uci);scheduler.run()
        XCTAssertEqual(host.revision,before+1,"the guest's \(uci) was applied",file:file,line:line)
        XCTAssertNil(client.receiver.pendingMove,"its receipt cleared the pending move",file:file,line:line)
    }
    /// Messages that crossed one connection in one direction, decoded.
    func messages(on connection:NetworkTransportConnection,toHost:Bool)->[NetworkMessage] {
        transport.trace.filter{$0.connection==connection && $0.toHost==toHost}.compactMap{try? NetworkCodec.decode($0.message)}
    }
}
private func isMessage(_ type:String)->(Data)->Bool {{data in (try? NetworkCodec.decode(data))?.type==type}}
private func isPing(_ message:NetworkMessage)->Bool {if case .ping=message {return true};return false}
private func isPong(_ message:NetworkMessage)->Bool {if case .pong=message {return true};return false}
/// A real game's opening, 30 plies with no repetition and no ending: Ruy Lopez, Breyer-like.
private let ruyLopez=["e2e4","e7e5","g1f3","b8c6","f1b5","a7a6","b5a4","g8f6","e1g1","f8e7","f1e1","b7b5","a4b3","d7d6","c2c3","e8g8","h2h3","c6b8","d2d4","b8d7","b1d2","c8b7","b3c2","f8e8","d2f1","e7f8","f1g3","g7g6","a2a4","c7c5"]

/// The host and client runners over the in-memory transport (LAN-play plan, build order 4): claim and resume, D4's
/// generations, D6's single queue with ping and pong timing, spectators, the end of a game, D7's outbound bounds, and
/// the connect deadline.
final class NetworkRunnerTests:XCTestCase {
    func testACutBeforeOrAfterTheAckResumesTheSameSeat()throws {
        for ackArrives in [false,true] {
            let game=try MemoryNetworkGame()
            if !ackArrives {game.transport.losesToHost=isMessage("seatedAck")}
            let guest=game.join(.seat,reconnect:NetworkReconnectPolicy(delays:[.seconds(1)],window:.seconds(120)))
            XCTAssertEqual(guest.link,.live)
            XCTAssertEqual(game.host.phase,ackArrives ? .running:.reserved,"the ack was \(ackArrives ? "processed":"lost")")
            let credential=try XCTUnwrap(guest.receiver.credential)
            if ackArrives {game.hostPlays("e2e4");game.play(guest,"e7e5")}
            let first=try XCTUnwrap(game.guestLink?.connection)
            game.transport.cut(first);game.scheduler.run()
            XCTAssertEqual(game.host.phase,ackArrives ? .disconnected:.reserved)
            XCTAssertEqual(guest.link,.reconnecting)
            // While the seat is reserved or held, no other claimant gets it.
            let rival=game.join(.seat,name:"Cy")
            XCTAssertEqual(rival.link,.stopped(.closedByHost(.seatTaken)))
            game.transport.losesToHost={_ in false}
            game.scheduler.advance(by:.seconds(1))
            XCTAssertEqual(guest.link,.live);XCTAssertEqual(game.host.phase,.running)
            XCTAssertTrue(guest.receiver.credential!.matches(credential),"the same seat, the same credential")
            XCTAssertEqual(guest.receiverEvents.filter{$0 == .resumed}.count,1,"it came back with resume, never a second hello")
            XCTAssertNotEqual(game.guestLink?.connection,first)
            XCTAssertNil(game.host.reservationDeadline);XCTAssertNil(game.host.holdDeadline)
            game.hostPlays(ackArrives ? "g1f3":"e2e4");game.play(guest,ackArrives ? "b8c6":"e7e5")
            XCTAssertEqual(guest.receiver.fen,game.host.fen);XCTAssertEqual(guest.receiver.revision,game.host.revision)
            XCTAssertEqual(game.transport.connectAttempts,3,"the guest twice and the rival once")
        }
    }
    /// Assistance plan A3 through the runners: terms other than the ones accepted stop the guest with that reason, both
    /// when the host refuses the claim and when a host's snapshot on resume states other terms than were accepted.
    func testOtherTermsStopTheGuestOnJoiningAndOnResuming()throws {
        let refusing=try MemoryNetworkGame(assistance:NetworkAssistance(both:.hints))
        let joiner=refusing.join(.seat,accepting:.off,reconnect:nil)
        XCTAssertEqual(joiner.link,.stopped(.closedByHost(.assistanceChanged)),"the host refuses a claim under other terms")
        XCTAssertNil(joiner.receiver.credential);XCTAssertEqual(refusing.host.phase,.waiting)
        // A host whose snapshot on resume states other terms (the hash covers only the position, so it still matches).
        let terms=NetworkAssistance(both:.hints),game=try MemoryNetworkGame(assistance:terms)
        let guest=game.join(.seat,accepting:terms,reconnect:NetworkReconnectPolicy(delays:[.seconds(1)],window:.seconds(120)))
        XCTAssertEqual(guest.link,.live);game.hostPlays("e2e4")
        var payload=Data()
        game.transport.rewritesToLink={data in
            guard let message=try? NetworkCodec.decode(data) else{return [data]}
            switch message {
            case .snapshotBegin:payload=Data();return []
            case .snapshotPart(_,_,let part):payload.append(part);return []
            case .snapshotEnd:
                guard var forged=try? JSONDecoder().decode(NetworkPublicGame.self,from:payload) else{return [data]};let fen=game.host.fen
                forged.assistance = .off
                let snapshot=NetworkSnapshot(snapshotID:.random(using:.system),revision:forged.revision,hash:game.hashing.positionHash(fen:fen,revision:forged.revision),payload:try! JSONEncoder().encode(forged))
                return snapshot.messages.map{try! NetworkCodec.encode($0)}
            default:return [data]
            }
        }
        game.transport.cut(try XCTUnwrap(game.guestLink?.connection));game.scheduler.advance(by:.seconds(1))
        XCTAssertEqual(guest.link,.stopped(.assistanceChanged),"the guest stops under terms it did not accept, with that reason")
        XCTAssertEqual(guest.receiver.installed?.assistance,terms,"the forged terms were never installed")
    }
    /// The reconnect window is absolute: an attempt still connecting when it ends is closed then, not at its own deadline.
    func testAReconnectAttemptStillConnectingWhenTheWindowEndsIsClosedThen()throws {
        let game=try MemoryNetworkGame()
        let guest=game.join(.seat,reconnect:NetworkReconnectPolicy(delays:[.seconds(1)],window:.seconds(3)))
        XCTAssertEqual(guest.link,.live)
        game.transport.stallConnects=true
        game.transport.cut(try XCTUnwrap(game.guestLink?.connection));game.scheduler.run()
        XCTAssertEqual(guest.link,.reconnecting)
        game.scheduler.advance(by:.seconds(1))
        XCTAssertEqual(game.transport.connectAttempts,2,"one attempt under way, stalled")
        game.scheduler.advance(by:.milliseconds(1990));XCTAssertEqual(guest.link,.reconnecting)
        game.scheduler.advance(by:.milliseconds(10))
        XCTAssertEqual(guest.link,.stopped(.couldNotReach),"stopped at the end of the window, not at the connect deadline")
        game.transport.stallConnects=false
        game.scheduler.advance(by:.seconds(30))
        XCTAssertEqual(guest.link,.stopped(.couldNotReach));XCTAssertEqual(game.transport.connectAttempts,2,"nothing after the stop")
    }
    /// The window holds after a sleep too: waking starts it afresh and arms it, so an attempt that stalls on waking stops
    /// when the window ends, not at its own connect deadline.
    func testAStalledAttemptOnWakingStopsWhenTheWindowEnds()throws {
        let game=try MemoryNetworkGame()
        let guest=game.join(.seat,reconnect:NetworkReconnectPolicy(delays:[.seconds(1)],window:.seconds(3)))
        XCTAssertEqual(guest.link,.live)
        guest.runner.suspend();game.scheduler.run();game.scheduler.advance(by:.seconds(60))
        XCTAssertNotEqual(guest.link,.stopped(.couldNotReach),"asleep, the window does not run")
        game.transport.stallConnects=true
        guest.runner.wake();game.scheduler.run()
        XCTAssertEqual(guest.link,.reconnecting)
        game.scheduler.advance(by:.milliseconds(2990));XCTAssertEqual(guest.link,.reconnecting)
        game.scheduler.advance(by:.milliseconds(10))
        XCTAssertEqual(guest.link,.stopped(.couldNotReach),"stopped at the end of the window counted from waking")
    }
    /// D5: a host speaking another major version closes the guest with that reason, which reads as a version mismatch.
    func testAnotherMajorVersionStopsTheGuestWithAReadableReason()throws {
        let game=try MemoryNetworkGame()
        let guest=game.join(.seat)
        XCTAssertEqual(guest.link,.live)
        let link=try XCTUnwrap(game.guestLink)
        game.transport.deliverLate(.received(Data(#"{"type":"bye","protocol":{"major":2,"minor":0},"reason":"hostLeft"}"#.utf8)),to:link)
        game.scheduler.run()
        XCTAssertEqual(guest.link,.stopped(.closedByHost(.protocolVersion)))
        XCTAssertEqual(NetworkWording.stop(.closedByHost(.protocolVersion),game:"Ana's game",wasLive:true),"Ana's game uses a different version of Checkmate.")
    }
    func testAStaleConnectionsLateEventsNeitherDetachNorMoveTheResumedGuest()throws {
        let game=try MemoryNetworkGame()
        let guest=game.join(.seat)
        game.hostPlays("e2e4");game.play(guest,"e7e5")
        let oldLink=try XCTUnwrap(game.guestLink),old=try XCTUnwrap(oldLink.connection)
        // Only the guest hears of the cut: the host's view lags, as with a half-open TCP connection.
        game.transport.cut(old,host:false);game.scheduler.run()
        XCTAssertEqual(guest.link,.live,"resumed on a fresh connection")
        XCTAssertNotEqual(game.guestLink?.connection,old)
        XCTAssertFalse(game.hosting.connections.contains(old),"the host closed the older connection holding the seat")
        XCTAssertEqual(game.host.phase,.running)
        // A transport racing those closes delivers the old connection's message, send completion and close late.
        let resignation=try NetworkCodec.encode(.resign(gameID:game.gameID,commandID:.random(using:.system)))
        for event:NetworkHostingEvent in [.received(old,resignation),.sent(old),.closed(old)] {game.transport.deliverLate(event,to:game.hosting)}
        game.transport.deliverLate(.received(try NetworkCodec.encode(.bye(.seatTaken))),to:oldLink)
        game.transport.deliverLate(.closed(.lost),to:oldLink)
        game.scheduler.run()
        XCTAssertNil(game.host.outcome,"the late resignation was dropped");XCTAssertEqual(game.host.phase,.running)
        XCTAssertNotNil(game.host.guestConnection,"the resumed guest is still attached");XCTAssertEqual(guest.link,.live)
        game.hostPlays("g1f3");game.play(guest,"b8c6")
        XCTAssertEqual(guest.receiver.fen,game.host.fen)
    }
    func testPingsKeepALiveConnectionAndASilentGuestIsClosedAtThePongDeadline()throws {
        let game=try MemoryNetworkGame()
        let guest=game.join(.seat)
        let connection=try XCTUnwrap(game.guestLink?.connection)
        game.scheduler.advance(by:.seconds(20))
        let pings=game.messages(on:connection,toHost:false).filter(isPing).count
        XCTAssertEqual(pings,10,"one every 2 s");XCTAssertEqual(game.messages(on:connection,toHost:true).filter(isPong).count,pings,"each answered")
        XCTAssertEqual(game.host.outstandingPings,0);XCTAssertEqual(guest.link,.live)
        // The guest's pongs stop arriving: at most two pings are outstanding, and the oldest unanswered for 6 s closes it.
        game.transport.losesToHost=isMessage("pong")
        let silentFrom=game.scheduler.now
        XCTAssertTrue(game.scheduler.advance(until:{guest.receiverEvents.contains(.closedByHost(.timeout))},step:.milliseconds(100),limit:.seconds(30)))
        let closedAfter=game.scheduler.now-silentFrom
        XCTAssertGreaterThan(closedAfter,.seconds(6));XCTAssertLessThanOrEqual(closedAfter,.seconds(8))
        XCTAssertEqual(guest.link,.live,"a timeout is retryable: it resumed at once");XCTAssertEqual(game.host.phase,.running)
        game.transport.losesToHost={_ in false}
        game.scheduler.advance(by:.seconds(30))
        XCTAssertEqual(guest.receiverEvents.filter{$0 == .closedByHost(.timeout)}.count,1,"answered pings keep it open again")
    }
    func testAGuestThatHearsNothingForSixSecondsReconnects()throws {
        let game=try MemoryNetworkGame()
        let guest=game.join(.seat)
        let old=try XCTUnwrap(game.guestLink?.connection)
        // The host's sends to it stop arriving: asleep, or a path that died without a reset.
        game.transport.stall(old)
        let from=game.scheduler.now
        XCTAssertTrue(game.scheduler.advance(until:{game.guestLink?.connection != old && guest.link == .live},step:.milliseconds(100),limit:.seconds(30)))
        let after=game.scheduler.now-from
        XCTAssertGreaterThanOrEqual(after,NetworkClientRunner.hostSilence);XCTAssertLessThanOrEqual(after,NetworkClientRunner.hostSilence + .milliseconds(100))
        XCTAssertTrue(game.messages(on:old,toHost:true).contains(.bye(.timeout)),"it told the host why it left")
        XCTAssertEqual(game.host.phase,.running);XCTAssertEqual(guest.receiverEvents.filter{$0 == .resumed}.count,1)
    }
    func testASpectatorWatchesWithoutAffectingTheGame()throws {
        let game=try MemoryNetworkGame()
        let guest=game.join(.seat),early=game.join(.watch,name:"Cy")
        XCTAssertEqual(early.link,.live);XCTAssertNil(early.status?.side)
        game.hostPlays("e2e4");game.play(guest,"e7e5")
        let late=game.join(.watch,name:"Dee")
        for watcher in [early,late] {
            XCTAssertEqual(watcher.receiver.fen,game.host.fen);XCTAssertEqual(watcher.receiver.revision,2)
            XCTAssertEqual(watcher.status?.game?.whiteName,"Ana");XCTAssertEqual(watcher.status?.game?.blackName,"Ben")
        }
        XCTAssertEqual(game.host.spectatorNames,["Cy","Dee"])
        let sent=game.transport.trace.filter(\.toHost).count
        early.runner.submitMove(uci:"g1f3");early.runner.resign();early.runner.offerDraw();early.runner.claimDraw();game.scheduler.run()
        XCTAssertEqual(game.transport.trace.filter(\.toHost).count,sent,"a spectator's commands never leave it")
        XCTAssertEqual(game.host.revision,2)
        XCTAssertEqual(early.appliedMoves.map(\.uci),["e2e4","e7e5"]);XCTAssertTrue(early.appliedMoves.allSatisfy{$0.receiptFor==nil},"no receipts for spectators")
        XCTAssertEqual(guest.appliedMoves.last?.receiptFor != nil,true,"the guest's own move carries its receipt")
    }
    func testEndedReachesEveryoneBeforeTheConnectionsClose()throws {
        let game=try MemoryNetworkGame(timeControl:.fivePlusThree)
        let guest=game.join(.seat),watchers=[game.join(.watch,name:"Cy"),game.join(.watch,name:"Dee")]
        game.hostPlays("e2e4");game.play(guest,"e7e5")
        game.scheduler.advance(by:.seconds(3))
        game.perform(.leave)
        let outcome=NetworkOutcome(result:.blackWins,termination:.resignation)
        XCTAssertEqual(game.host.outcome,outcome);XCTAssertEqual(game.runner.stop,.left)
        guard case .stopped(.left)?=game.hostLog.events.last else{return XCTFail("stopped is the host runner's last event")}
        XCTAssertEqual(game.transport.openListeners,0);XCTAssertTrue(game.hosting.connections.isEmpty)
        for client in [guest]+watchers {
            XCTAssertEqual(client.receiver.outcome,outcome);XCTAssertEqual(client.link,.stopped(.finished))
            let ended=client.log.events.firstIndex{if case .receiver(.ended(outcome))=$0 {return true};return false}
            let stopped=client.log.events.firstIndex{if case .status(let status)=$0,case .stopped=status.link {return true};return false}
            XCTAssertNotNil(ended);XCTAssertNotNil(stopped)
            if let ended,let stopped {XCTAssertLessThan(ended,stopped,"the result before the close")}
            XCTAssertTrue(client.receiverEvents.contains(.closedByHost(.hostLeft)))
        }
        game.scheduler.advance(by:.seconds(300))
        XCTAssertEqual(game.transport.connectAttempts,3,"nobody reconnects to a finished game")
    }
    func testAGuestLeavingResignsFirst()throws {
        let game=try MemoryNetworkGame()
        let guest=game.join(.seat)
        game.hostPlays("e2e4");game.play(guest,"e7e5")
        guest.runner.leave(resigning:true);game.scheduler.run()
        XCTAssertEqual(game.host.outcome,NetworkOutcome(result:.whiteWins,termination:.resignation))
        XCTAssertEqual(guest.link,.stopped(.left))
        let connection=try XCTUnwrap(game.transport.links.last?.connection)
        XCTAssertEqual(game.messages(on:connection,toHost:true).suffix(2).map(\.type),["resign","bye"],"the resignation, then bye(leaving)")
    }
    func testAStalledConnectIsRetriedOnceThenCannotBeReached()throws {
        let game=try MemoryNetworkGame()
        game.transport.stallConnects=true
        let guest=game.join(.seat)
        XCTAssertEqual(guest.link,.connecting)
        game.scheduler.advance(by:NetworkTransportLimits.standard.connectDeadline)
        XCTAssertEqual(game.transport.connectAttempts,2,"one fresh retry at the deadline");XCTAssertEqual(guest.link,.connecting)
        game.scheduler.advance(by:NetworkTransportLimits.standard.connectDeadline)
        XCTAssertEqual(guest.link,.stopped(.couldNotReach))
        game.scheduler.advance(by:.seconds(300));XCTAssertEqual(game.transport.connectAttempts,2,"nothing after the stop")
        // The one retry is enough when the refusal was transient.
        let retried=try MemoryNetworkGame()
        retried.transport.stallConnects=true
        let second=retried.join(.seat)
        retried.scheduler.advance(by:.seconds(5));retried.transport.stallConnects=false
        retried.scheduler.advance(by:.seconds(5))
        XCTAssertEqual(second.link,.live);XCTAssertEqual(retried.transport.connectAttempts,2)
    }
    func testAJoinerRefusedWhileTheHostIsBusyRetriesBriefly()throws {
        var limits=NetworkHostLimits();limits.pendingPerListener=1
        for slotFrees in [true,false] {
            let game=try MemoryNetworkGame(limits:limits)
            // A connection past TLS that never says hello holds the watch listener's only admission slot (D7).
            let idle=game.transport.connect(to:game.endpoints[.watch]!,key:NetworkAccessKey(gameID:game.gameID,role:.watch,code:game.watchCode)){_ in}
            game.scheduler.run()
            XCTAssertEqual(game.host.pendingConnections.count,1)
            let watcher=game.join(.watch,name:"Cy",reconnect:nil)
            XCTAssertTrue(watcher.receiverEvents.contains(.closedByHost(.busy)));XCTAssertEqual(watcher.link,.connecting,"still joining")
            game.scheduler.advance(by:.milliseconds(700))
            if slotFrees {idle.close(farewell:nil);game.scheduler.run()}
            game.scheduler.advance(by:.seconds(3))
            if slotFrees {
                XCTAssertEqual(watcher.link,.live);XCTAssertEqual(game.transport.connectAttempts,1+3,"refused at 0 and 0.5 s, admitted at 1.5 s")
            }else{
                XCTAssertEqual(watcher.link,.stopped(.couldNotReach),"refused at 0, 0.5, 1.5 and 3.5 s, then it gives up")
                XCTAssertEqual(game.transport.connectAttempts,1+1+NetworkClientRunner.joinRetryDelays.count)
            }
        }
    }
    func testAWrongCodeOrAnotherRolesKeyIsRefusedAndNotRetried()throws {
        let game=try MemoryNetworkGame()
        let wrong=game.join(.seat,code:NetworkCode(typed:"00000000")!)
        XCTAssertEqual(wrong.link,.stopped(.handshakeFailed))
        let crossed=game.join(.watch,code:game.seatCode)
        XCTAssertEqual(crossed.link,.stopped(.handshakeFailed),"the play code does not open the watch listener")
        game.scheduler.advance(by:.seconds(60))
        XCTAssertEqual(game.transport.connectAttempts,2);XCTAssertEqual(game.host.phase,.waiting);XCTAssertTrue(game.host.spectators.isEmpty)
        let noSpectators=try MemoryNetworkGame(spectators:false)
        XCTAssertEqual(Set(noSpectators.endpoints.keys),[.seat],"no watch listener when spectators are not allowed")
    }
    func testASlowSpectatorIsClosedAtItsQueueCapWhileTheGuestIsNeverBlocked()throws {
        var limits=NetworkHostLimits();limits.peerQueueBytes=2*1024
        let game=try MemoryNetworkGame(limits:limits)
        let guest=game.join(.seat)
        let watchers=(0..<8).map{game.join(.watch,name:"Watcher \($0)",reconnect:nil)}
        let guestConnection=try XCTUnwrap(game.guestLink?.connection)
        let spectatorConnections=game.hosting.connections.filter{$0 != guestConnection}
        XCTAssertEqual(spectatorConnections.count,8)
        for connection in spectatorConnections.prefix(4) {game.transport.stall(connection)}
        for (index,uci) in ruyLopez.enumerated() {
            game.scheduler.advance(by:.milliseconds(100))
            if index%2==0 {game.hostPlays(uci)}else{game.play(guest,uci)}
            XCTAssertEqual(guest.receiver.revision,index+1,"the guest's queue is its own")
            for spectator in game.host.spectators {XCTAssertLessThanOrEqual(game.host.queuedBytes(spectator) ?? 0,limits.peerQueueBytes)}
        }
        XCTAssertEqual(game.host.spectators.count,4,"the four that stopped reading were closed as slow; pings could not have")
        XCTAssertEqual(watchers.filter{$0.link == .live}.count,4)
        XCTAssertTrue(watchers.filter{$0.link == .live}.allSatisfy{$0.receiver.fen==game.host.fen})
        XCTAssertLessThan(game.runner.peakBufferedBytes,1024*1024)
    }
    func testStalledSpectatorsAtTheStandardBoundsKeepTheHostUnderOneMebibyte()throws {
        let game=try MemoryNetworkGame(timeControl:.threePlusTwo)
        let guest=game.join(.seat)
        let watchers=(0..<8).map{game.join(.watch,name:"Watcher \($0)",reconnect:nil)}
        let guestConnection=try XCTUnwrap(game.guestLink?.connection)
        for connection in game.hosting.connections where connection != guestConnection {game.transport.stall(connection)}
        var peak=0
        for (index,uci) in ruyLopez.enumerated() {
            game.scheduler.advance(by:.milliseconds(300))
            if index%2==0 {game.hostPlays(uci)}else{game.play(guest,uci)}
            peak=max(peak,game.runner.bufferedBytes)
        }
        game.scheduler.advance(by:.seconds(10))
        XCTAssertTrue(game.host.spectators.isEmpty,"spectators that read nothing cannot answer pings, and are closed")
        XCTAssertTrue(watchers.allSatisfy{$0.link == .stopped(.couldNotReach)})
        XCTAssertGreaterThan(peak,0);XCTAssertGreaterThanOrEqual(game.runner.peakBufferedBytes,peak,"the runner samples after every event")
        XCTAssertLessThan(game.runner.peakBufferedBytes,1024*1024,"D7: the host's total stays under 1 MiB")
        XCTAssertEqual(game.runner.bufferedBytes,game.host.queuedBytes(game.host.guestConnection!)!+game.hosting.bufferedBytes)
        XCTAssertEqual(guest.link,.live)
    }
    /// D7's caps add up to under 1 MiB even at their worst: every spectator queue full, the guest's full, every send in
    /// flight counted twice (by the host and by the transport), and a partial frame on every connection the host may
    /// hold, pending ones included.
    func testTheTransportBoundsAddUpToUnderOneMebibyte(){
        let frame=NetworkFraming.headerBytes+NetworkLimits.maximumMessageBytes
        let admitted=1+NetworkLimits.maximumSpectators,pending=2*NetworkLimits.pendingConnectionsPerListener
        let outbound=NetworkLimits.spectatorQueuesBytes+NetworkLimits.peerQueueBytes,inFlight=admitted*frame,inbound=(admitted+pending)*(frame-1)
        XCTAssertLessThan(outbound+inFlight+inbound,1024*1024)
    }
    func testTheStandardTransportLimitsAreD7s(){
        let limits=NetworkTransportLimits.standard
        XCTAssertEqual(limits.handshakesPerListener,4);XCTAssertEqual(limits.handshakeDeadline,.seconds(5))
        XCTAssertEqual(limits.failedHandshakesPerAddress,5);XCTAssertEqual(limits.failedHandshakeWindow,.seconds(60))
        XCTAssertEqual(limits.partialFrameDeadline,.seconds(5));XCTAssertEqual(limits.connectDeadline,.seconds(10));XCTAssertEqual(limits.farewellDeadline,.seconds(1))
        XCTAssertEqual(NetworkServiceType.all,["_checkmate._tcp","_checkmate-dev._tcp","_checkmate-auto._tcp"])
    }
    func testARulesFailureInterruptsTheGameAndTellsEveryPeer()throws {
        let game=try MemoryNetworkGame(rules:NetworkRulesFactory{FailingRules(failing:"g1f3")})
        let guest=game.join(.seat,reconnect:nil),watcher=game.join(.watch,name:"Cy",reconnect:nil)
        game.perform(.move(uci:"g1f3"))
        guard case .failed?=game.runner.stop else{return XCTFail("\(String(describing:game.runner.stop))")}
        XCTAssertEqual(game.transport.openListeners,0)
        for client in [guest,watcher] {XCTAssertEqual(client.link,.stopped(.closedByHost(.hostLeft)));XCTAssertNil(client.receiver.outcome,"interrupted, no result")}
    }
    func testDiscoveryPairsListenersByGameIDNeverByName()throws {
        // Two games with the same name are told apart by their IDs' last characters: draw until those differ, so the
        // test never fails on a one-in-a-million collision of correct IDs.
        let a=NetworkGameID.random(using:.system),c=NetworkGameID.random(using:.system)
        var b=NetworkGameID.random(using:.system);while b.displaySuffix==a.displaySuffix {b=NetworkGameID.random(using:.system)}
        func record(_ name:String,_ txt:[String:String],_ endpoint:String)->NetworkServiceRecord {NetworkServiceRecord(name:name,txt:txt,endpoint:NetworkEndpoint(endpoint,description:endpoint))}
        let records=[
            record("Ana's game",["game":a.text,"role":"seat"],"a-seat"),
            record("Ana's game",["game":b.text,"role":"seat"],"b-seat"),
            record("Ana's game · watch",["game":a.text,"role":"watch"],"a-watch"),
            record("Ana's game",["game":a.text,"role":"seat"],"a-seat-other-interface"),
            record("Forged",["game":"not-a-game","role":"seat"],"forged"),
            record("No role",["game":a.text],"no-role"),
            record("Odd role",["game":a.text,"role":"host"],"odd-role"),
            record("Ben's game · watch",["game":c.text,"role":"watch","extra":"ignored"],"c-watch"),
        ]
        let games=NetworkDiscoveredGame.pair(records)
        XCTAssertEqual(games.map(\.gameID),[a,b,c])
        XCTAssertEqual(games[0].seat?.endpoint.description,"a-seat");XCTAssertEqual(games[0].watch?.endpoint.description,"a-watch")
        XCTAssertNil(games[1].watch);XCTAssertNil(games[2].seat)
        XCTAssertEqual(games[0].name,games[1].name,"the same name");XCTAssertNotEqual(games[0].displayName,games[1].displayName,"told apart by the game ID")
        XCTAssertEqual(games[0].displayName,"Ana's game · \(a.displaySuffix)");XCTAssertEqual(games[2].name,"Ben's game")
        XCTAssertEqual(games[0].key(.seat,code:NetworkCode(typed:"K7QD-2M9X")!),NetworkAccessKey(gameID:a,role:.seat,code:NetworkCode(typed:"k7qd2m9x")!),"only the code is typed")
        let scheduler=NetworkManualScheduler(),discovery=NetworkFixedDiscovery(records:records,scheduler:scheduler)
        var updates:[NetworkDiscoveryUpdate]=[]
        discovery.start{updates.append($0)}
        XCTAssertTrue(updates.isEmpty,"never during the call");scheduler.run();XCTAssertEqual(updates,[.games(games)])
        discovery.stop();discovery.publish([]);scheduler.run();XCTAssertEqual(updates.count,1,"nothing after stop")
        let long=NetworkHostingConfiguration(gameID:a,seatCode:.random(using:.system),watchCode:.random(using:.system),serviceName:String(repeating:"é",count:40))
        XCTAssertLessThanOrEqual(long.serviceName(for:.watch).utf8.count,63);XCTAssertTrue(long.serviceName(for:.watch).hasSuffix(NetworkHostingConfiguration.watchSuffix))
        XCTAssertEqual(NetworkServiceRecord.published(long,.seat,at:NetworkEndpoint("x",description:"x")).txt,["game":a.text,"role":"seat","assist":"oo"],"the terms, for display only (assistance plan A3)")
    }
}
/// The real rules, except that one move fails as a runtime failure would.
private final class FailingRules:NetworkChessRules {
    private let rules:ChessRules,failing:String
    init(failing:String){rules=try! ChessRules();self.failing=failing}
    func networkFEN()throws -> String {try rules.networkFEN()}
    func networkSideToMove()throws -> NetworkSide {try rules.networkSideToMove()}
    func networkPlay(uci:String)throws -> NetworkPlayedMove {if uci==failing {throw NetworkRulesError.unexpected("the rules runtime failed")};return try rules.networkPlay(uci:uci)}
    func networkAutomaticEnding()throws -> NetworkAutomaticEnding? {try rules.networkAutomaticEnding()}
    func networkClaimableDraw()throws -> NetworkTermination? {try rules.networkClaimableDraw()}
    func networkHasOnlyKing(_ side:NetworkSide)throws -> Bool {try rules.networkHasOnlyKing(side)}
    func networkPGN()throws -> String {try rules.networkPGN()}
    func networkLoad(pgn:String)throws {try rules.networkLoad(pgn:pgn)}
    func networkMoves()throws -> [String] {try rules.networkMoves()}
}
