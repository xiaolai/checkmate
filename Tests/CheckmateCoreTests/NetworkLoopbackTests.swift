import XCTest
import CryptoKit
@preconcurrency import Network
@testable import CheckmateApplication
@testable import CheckmateMacPlatform
@testable import CheckmateDomain
import CheckmateRules
import CheckmateSupport

/// Records a hosting's events; read and written on the network queue only.
private final class HostingLog {
    var events:[NetworkHostingEvent]=[]
    var endpoints:[NetworkListenerRole:NetworkEndpoint]? {for case .listening(let endpoints) in events {return endpoints};return nil}
    var accepted:[(connection:NetworkTransportConnection,role:NetworkListenerRole)] {events.compactMap{if case .accepted(let connection,let role)=$0 {return (connection,role)};return nil}}
    var received:[Data] {events.compactMap{if case .received(_,let data)=$0 {return data};return nil}}
    var closed:[NetworkTransportConnection] {events.compactMap{if case .closed(let connection)=$0 {return connection};return nil}}
}
/// Records a link's events, and can answer them; on the network queue only.
private final class LinkLog {
    var events:[NetworkLinkEvent]=[]
    var onEvent:(NetworkLinkEvent)->Void={_ in}
    var ready:Bool {events.contains(.ready)}
    var closed:NetworkLinkFailure? {for case .closed(let failure) in events {return failure};return nil}
    var messages:[NetworkMessage] {events.compactMap{if case .received(let data)=$0 {return try? NetworkCodec.decode(data)};return nil}}
}
private final class Box<Value> {var value:Value;init(_ value:Value){self.value=value}}

/// Network.framework over loopback (LAN-play plan D12: listeners on 127.0.0.1, no Bonjour, outside local-network
/// privacy): the pinned handshake, wrong keys, role separation, D7's handshake, address and framing bounds, the connect
/// deadline, admission, flooding, and a full game with eight spectators under the 1 MiB bound.
final class NetworkLoopbackTests:XCTestCase {
    private var scheduler:NetworkQueueScheduler!
    private var cleanups:[()->Void]=[]
    private let rawQueue=DispatchQueue(label:"checkmate.network.tests.raw")
    override func setUp(){super.setUp();scheduler=NetworkQueueScheduler(queue:DispatchQueue(label:"checkmate.network.tests"))}
    override func tearDown(){
        let cleanups=self.cleanups;self.cleanups=[]
        scheduler.queue.sync{for cleanup in cleanups.reversed() {cleanup()}}
        super.tearDown()
    }
    private func onQueue<T>(_ body:()throws -> T)rethrows -> T {try scheduler.queue.sync(execute:body)}
    private func eventually(_ what:String,timeout:TimeInterval=10,file:StaticString=#filePath,line:UInt=#line,_ condition:()->Bool){
        let end=Date().addingTimeInterval(timeout)
        while Date()<end {if onQueue(condition) {return};Thread.sleep(forTimeInterval:0.005)}
        XCTFail("Timed out waiting for \(what).",file:file,line:line)
    }
    private func makeTransport(_ limits:NetworkTransportLimits = .standard)->NWNetworkTransport {NWNetworkTransport(scheduler:scheduler,configuration:.loopback(limits:limits))}
    private func makeConfiguration(spectators:Bool=true)->NetworkHostingConfiguration {
        NetworkHostingConfiguration(gameID:.random(using:.system),seatCode:.random(using:.system),watchCode:spectators ? .random(using:.system):nil,serviceName:"Loopback")
    }
    private func startHosting(_ transport:NWNetworkTransport,_ configuration:NetworkHostingConfiguration)throws -> (hosting:NWNetworkHosting,log:HostingLog) {
        let log=HostingLog()
        let hosting=try onQueue{try transport.startHosting(configuration){log.events.append($0)} as! NWNetworkHosting}
        cleanups.append{hosting.shutdown()}
        eventually("both listeners ready"){log.endpoints != nil}
        return (hosting,log)
    }
    private func connect(_ transport:NWNetworkTransport,_ endpoint:NetworkEndpoint,_ key:NetworkAccessKey,_ log:LinkLog=LinkLog())->(link:NWNetworkLink,log:LinkLog) {
        let link=onQueue{transport.connect(to:endpoint,key:key){event in log.events.append(event);log.onEvent(event)} as! NWNetworkLink}
        cleanups.append{link.close(farewell:nil)}
        return (link,log)
    }
    private func port(_ endpoint:NetworkEndpoint)->NWEndpoint.Port {
        guard case .hostPort(_,let port)?=endpoint.value as? NWEndpoint else{preconditionFailure("not a loopback endpoint")}
        return port
    }
    /// A connection that speaks plain TCP, or TLS with any key, and writes whatever bytes it is given.
    private func raw(_ endpoint:NetworkEndpoint,tls key:NetworkAccessKey?)->NWConnection {
        let connection=NWConnection(host:"127.0.0.1",port:port(endpoint),using:key.map{NetworkTLS.parameters($0,loopback:false)} ?? .tcp)
        connection.start(queue:rawQueue)
        cleanups.append{connection.cancel()}
        return connection
    }
    private func ready(_ connection:NWConnection,file:StaticString=#filePath,line:UInt=#line){
        let end=Date().addingTimeInterval(10)
        while Date()<end {if case .ready=connection.state {return};Thread.sleep(forTimeInterval:0.005)}
        XCTFail("A raw connection never became ready.",file:file,line:line)
    }
    private func write(_ connection:NWConnection,_ bytes:Data){connection.send(content:bytes,completion:.idempotent)}
    private func header(_ length:Int)->Data {withUnsafeBytes(of:UInt32(length).bigEndian){Data($0)}}
    private func bytes(_ key:SymmetricKey)->Data {key.withUnsafeBytes{Data($0)}}

    func testTheHandshakeIsTLS12AtThePinnedSuiteKeyedByTheBootstrap()throws {
        let transport=makeTransport(),configuration=makeConfiguration()
        let key=try XCTUnwrap(configuration.key(.seat))
        // D3: HKDF-SHA256 over the code, salted with the game ID, with the role in `info`; the identity is the game ID.
        let expected=HKDF<SHA256>.deriveKey(inputKeyMaterial:SymmetricKey(data:Data(key.code.text.utf8)),salt:Data(key.gameID.text.utf8),info:Data("checkmate-lan v1 seat".utf8),outputByteCount:32)
        XCTAssertEqual(bytes(NetworkTLS.preSharedKey(key)),bytes(expected))
        XCTAssertNotEqual(bytes(NetworkTLS.preSharedKey(NetworkAccessKey(gameID:key.gameID,role:.watch,code:key.code))),bytes(expected),"the role is in the key")
        let (hosting,hostLog)=try startHosting(transport,configuration)
        let (link,linkLog)=connect(transport,hostLog.endpoints![.seat]!,key)
        eventually("the seat connection"){linkLog.ready && hostLog.accepted.count==1}
        let pinned=NetworkTLS.Negotiated(version:0x0303,suite:0xCCAC)
        onQueue{
            XCTAssertEqual(link.negotiated,pinned,"read from sec_protocol_metadata on the client");XCTAssertEqual(hosting.diagnostics.lastNegotiated,pinned,"and on the host")
            XCTAssertEqual(hostLog.accepted.first?.role,.seat)
        }
        // One frame each way, whole.
        let hello=try NetworkCodec.encode(.hello(name:"Ben",appVersion:"0.8.0",claimID:.random(using:.system)))
        onQueue{link.send(hello)}
        eventually("the hello at the host"){hostLog.received==[hello] && linkLog.events.contains(.sent)}
        let watching=try NetworkCodec.encode(.watching)
        onQueue{hosting.send(watching,on:hostLog.accepted[0].connection)}
        eventually("the answer at the guest"){linkLog.events.contains(.received(watching))}
        onQueue{link.close(farewell:try? NetworkCodec.encode(.bye(.leaving)))}
        eventually("the farewell, then the close"){hostLog.received.count==2 && hostLog.closed.count==1}
        XCTAssertEqual(onQueue{try? NetworkCodec.decode(hostLog.received[1])},.bye(.leaving))
    }
    /// D11 reads only TN3179's signals as denial; a TLS error is a failed handshake even while waiting.
    func testFailuresAreClassifiedWithoutGuessing(){
        XCTAssertTrue(NetworkTLS.deniesLocalNetwork(.dns(-65570),path:nil))
        XCTAssertFalse(NetworkTLS.deniesLocalNetwork(.dns(-65554),path:nil))
        XCTAssertFalse(NetworkTLS.deniesLocalNetwork(.posix(.ECONNREFUSED),path:nil))
        XCTAssertFalse(NetworkTLS.deniesLocalNetwork(.tls(-9820),path:nil))
        XCTAssertEqual(NetworkTLS.failure(.tls(-9820)),.handshakeFailed,"a wrong PSK on the client")
        XCTAssertEqual(NetworkTLS.failure(.posix(.ECONNRESET)),.unreachable)
        XCTAssertEqual(NetworkTLS.failure(.posix(.ECONNREFUSED)),.unreachable)
        XCTAssertNil(NWNetworkTransport.bonjourServiceType(in:Bundle(for:Self.self)),"no NSBonjourServices, no advertising")
    }
    func testAWrongCodeFailsAtOnceRatherThanWaitingForTheDeadline()throws {
        var limits=NetworkTransportLimits();limits.connectDeadline = .seconds(30)
        let transport=makeTransport(limits),configuration=makeConfiguration()
        let (hosting,hostLog)=try startHosting(transport,configuration)
        let started=Date()
        let (_,linkLog)=connect(transport,hostLog.endpoints![.seat]!,NetworkAccessKey(gameID:configuration.gameID,role:.seat,code:NetworkCode(typed:"ZZZZZZZZ")!))
        eventually("the refusal"){linkLog.closed != nil}
        XCTAssertEqual(onQueue{linkLog.closed},.handshakeFailed)
        XCTAssertLessThan(Date().timeIntervalSince(started),5,"a TLS error while waiting is fatal: nothing waits for the 30 s deadline")
        eventually("the host counted it"){hosting.diagnostics.handshakeFailures==1}
        XCTAssertTrue(onQueue{hostLog.accepted.isEmpty})
    }
    func testEachListenerAdmitsOnlyItsOwnRolesKey()throws {
        let transport=makeTransport(),configuration=makeConfiguration()
        let (hosting,hostLog)=try startHosting(transport,configuration)
        let seat=configuration.key(.seat)!,watch=configuration.key(.watch)!
        let cases:[(listener:NetworkListenerRole,key:NetworkAccessKey,admitted:Bool,why:String)]=[
            (.seat,watch,false,"the watch key on the seat listener"),
            (.watch,seat,false,"the seat key on the watch listener"),
            (.watch,NetworkAccessKey(gameID:seat.gameID,role:.watch,code:seat.code),false,"the play code keyed for watching"),
            (.seat,seat,true,"the seat key on the seat listener"),
            (.watch,watch,true,"the watch key on the watch listener"),
        ]
        for item in cases {
            let (_,log)=connect(transport,hostLog.endpoints![item.listener]!,item.key)
            eventually(item.why){log.ready || log.closed != nil}
            // A wrong outcome names how the link ended and what the host counted: a refusal before TLS and a failed
            // handshake look the same from the outcome alone.
            XCTAssertEqual(onQueue{log.ready},item.admitted,"\(item.why); link ended \(String(describing:onQueue{log.closed})); host \(onQueue{hosting.diagnostics})")
        }
        eventually("two admitted"){hostLog.accepted.count==2}
        XCTAssertEqual(onQueue{hostLog.accepted.map(\.role)},[.seat,.watch],"the role comes from the listener")
    }
    func testHandshakeSlotsAndThePerAddressFailureLimit()throws {
        var limits=NetworkTransportLimits();limits.handshakeDeadline = .milliseconds(800)
        let transport=makeTransport(limits),configuration=makeConfiguration()
        let (hosting,hostLog)=try startHosting(transport,configuration)
        let seat=hostLog.endpoints![.seat]!,watch=hostLog.endpoints![.watch]!
        // Four TCP connections that never start TLS hold every handshake slot on the seat listener.
        for _ in 0..<4 {_ = raw(seat,tls:nil)}
        eventually("four handshakes in progress"){hosting.handshaking(.seat)==4}
        let (_,busy)=connect(transport,seat,configuration.key(.seat)!)
        eventually("the fifth is dropped before TLS"){busy.closed != nil}
        onQueue{
            XCTAssertFalse(busy.ready);XCTAssertEqual(hosting.diagnostics.refusedBusy,1);XCTAssertEqual(hosting.diagnostics.handshakeFailures,0,"a refusal is not a failure")
            XCTAssertEqual(busy.closed,.unreachable,"dropped before TLS reads as unreachable, never as a wrong code")
        }
        let (_,watcher)=connect(transport,watch,configuration.key(.watch)!)
        eventually("the watch listener has slots of its own"){watcher.ready}
        // At the deadline the four are dropped, and each counts as a failure from 127.0.0.1.
        eventually("the four time out"){hosting.diagnostics.handshakeTimeouts==4}
        XCTAssertEqual(onQueue{hosting.handshaking(.seat)},0)
        let (_,fifth)=connect(transport,seat,configuration.key(.seat)!)
        eventually("four failures still admit"){fifth.ready}
        let (_,wrong)=connect(transport,seat,NetworkAccessKey(gameID:configuration.gameID,role:.seat,code:NetworkCode(typed:"ZZZZZZZZ")!))
        eventually("the fifth failure"){wrong.closed != nil}
        let (_,blocked)=connect(transport,seat,configuration.key(.seat)!)
        eventually("dropped before TLS"){blocked.closed != nil}
        onQueue{
            XCTAssertFalse(blocked.ready,"even the right key, from an address with five failures this minute")
            XCTAssertEqual(blocked.closed,.unreachable,"dropped before TLS reads as unreachable, never as a wrong code")
            XCTAssertEqual(hosting.diagnostics.refusedAddress,1);XCTAssertEqual(hosting.diagnostics.handshakeFailures,1)
        }
    }
    func testFramingBoundsAPartialFrameAndTheInboundCap()throws {
        var limits=NetworkTransportLimits();limits.partialFrameDeadline = .milliseconds(500)
        let transport=makeTransport(limits),configuration=makeConfiguration()
        let (hosting,hostLog)=try startHosting(transport,configuration)
        let seat=hostLog.endpoints![.seat]!,key=configuration.key(.seat)!
        // A frame begun and never finished closes at the deadline, however the bytes trickle in.
        let slow=raw(seat,tls:key);ready(slow)
        eventually("admitted by TLS"){hostLog.accepted.count==1}
        let started=Date()
        write(slow,header(100)+Data(repeating:0x20,count:10))
        for _ in 0..<3 {Thread.sleep(forTimeInterval:0.15);write(slow,Data([0x20]))}
        eventually("closed for its partial frame",timeout:5){hosting.diagnostics.partialFrameTimeouts==1}
        let elapsed=Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed,0.45);XCTAssertLessThan(elapsed,2,"the trickle did not extend the deadline")
        onQueue{XCTAssertEqual(hostLog.closed,[hostLog.accepted[0].connection])}
        // A header declaring 0 or over 16 KiB closes the connection at once, before any body.
        for (index,length) in [0,NetworkLimits.maximumMessageBytes+1].enumerated() {
            let bad=raw(seat,tls:key);ready(bad)
            write(bad,header(length))
            eventually("a \(length)-byte header refused"){hosting.diagnostics.framingErrors==index+1}
        }
        // A whole 16 KiB frame arrives; while it is partial, at most the header and 16 KiB are held, and counted.
        let full=raw(seat,tls:key);ready(full)
        write(full,header(NetworkLimits.maximumMessageBytes)+Data(repeating:0x20,count:16_000))
        eventually("held"){hosting.bufferedBytes==NetworkFraming.headerBytes+16_000}
        write(full,Data(repeating:0x21,count:NetworkLimits.maximumMessageBytes-16_000))
        eventually("delivered whole"){hostLog.received.contains{$0.count==NetworkLimits.maximumMessageBytes}}
        XCTAssertEqual(onQueue{hosting.bufferedBytes},0)
        XCTAssertLessThanOrEqual(NWFramedConnection.readSize,NetworkFraming.headerBytes+NetworkLimits.maximumMessageBytes)
    }
    func testAConnectThatNeverCompletesTLSHitsTheDeadlineAndIsRetriedOnce()throws {
        // A plain TCP listener that takes connections and never answers: the TLS handshake waits for ever, as a
        // connection macOS refuses silently sits in preparing (spike finding (c)).
        let accepted=Box<[NWConnection]>([])
        let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let stub=try NWListener(using:parameters)
        stub.newConnectionHandler={connection in connection.start(queue:self.scheduler.queue);accepted.value.append(connection)}
        stub.start(queue:scheduler.queue)
        cleanups.append{stub.cancel();accepted.value.forEach{$0.cancel()}}
        eventually("the stub listening"){stub.port != nil && stub.port!.rawValue != 0}
        let endpoint=NWNetworkTransport.loopbackEndpoint(port:onQueue{stub.port!.rawValue})
        var limits=NetworkTransportLimits();limits.connectDeadline = .milliseconds(600)
        let transport=makeTransport(limits)
        let key=NetworkAccessKey(gameID:.random(using:.system),role:.seat,code:.random(using:.system))
        let started=Date()
        let (_,log)=connect(transport,endpoint,key)
        eventually("the deadline"){log.closed != nil}
        XCTAssertEqual(onQueue{log.closed},.timedOut)
        let elapsed=Date().timeIntervalSince(started);XCTAssertGreaterThanOrEqual(elapsed,0.55);XCTAssertLessThan(elapsed,3)
        // The client runner tries one fresh connection after a deadline, then reports "couldn't reach".
        let statuses=NetworkEventLog<NetworkClientRunner.Event>()
        let receiver=NetworkReceiver(gameID:key.gameID,role:.guest(claimID:.random(using:.system)),name:"Ben",appVersion:"0.8.0",rules:NetworkRulesFactory{try ChessRules()},hashing:NetworkHashing(reviewHash))
        let runner=NetworkClientRunner(receiver:receiver,endpoint:endpoint,key:key,transport:transport,scheduler:scheduler){statuses.append($0)}
        runner.start()
        eventually("the runner gave up",timeout:5){runner.stop != nil}
        onQueue{XCTAssertEqual(runner.stop,.couldNotReach);XCTAssertEqual(accepted.value.count,3,"one for the link, two for the runner")}
    }
    // MARK: With the real host and receivers
    private final class Party {
        let runner:NetworkClientRunner,log=NetworkEventLog<NetworkClientRunner.Event>()
        init(_ make:(NetworkEventLog<NetworkClientRunner.Event>)->NetworkClientRunner){runner=make(log)}
        var receiver:NetworkReceiver {runner.receiver}
        var link:NetworkClientStatus.Link? {for case .status(let status) in log.events.reversed() {return status.link};return nil}
        func statusAt(revision:Int)->NetworkInstant? {for case .status(let status) in log.events where status.game?.revision==revision {return status.at};return nil}
    }
    private func hostGame(_ transport:NWNetworkTransport,timeControl:NetworkTimeControl = .untimed)throws -> (runner:NetworkHostRunner,log:NetworkEventLog<NetworkHostRunner.Event>,configuration:NetworkHostingConfiguration) {
        let configuration=makeConfiguration()
        let host=try onQueue{try NetworkHost(gameID:configuration.gameID,runEpoch:.random(using:.system),settings:NetworkHostSettings(hostName:"Ana",hostSide:.white,timeControl:timeControl),rules:NetworkRulesFactory{try ChessRules()},hashing:NetworkHashing(reviewHash),at:scheduler.now)}
        let log=NetworkEventLog<NetworkHostRunner.Event>()
        let runner=NetworkHostRunner(host:host,configuration:configuration,transport:transport,scheduler:scheduler){log.append($0)}
        cleanups.append{runner.hosting?.shutdown()}
        runner.start()
        eventually("listening"){log.events.contains{if case .listening=$0 {return true};return false}}
        return (runner,log,configuration)
    }
    private func endpoints(_ log:NetworkEventLog<NetworkHostRunner.Event>)->[NetworkListenerRole:NetworkEndpoint] {onQueue{for case .listening(let endpoints) in log.events {return endpoints};return [:]}}
    private func join(_ transport:NWNetworkTransport,_ configuration:NetworkHostingConfiguration,_ endpoints:[NetworkListenerRole:NetworkEndpoint],_ role:NetworkListenerRole,name:String)->Party {
        let receiver=NetworkReceiver(gameID:configuration.gameID,role:role == .seat ? .guest(claimID:.random(using:.system)):.spectator,name:name,appVersion:"0.8.0",rules:NetworkRulesFactory{try ChessRules()},hashing:NetworkHashing(reviewHash))
        let party=Party{log in NetworkClientRunner(receiver:receiver,endpoint:endpoints[role]!,key:configuration.key(role)!,transport:transport,scheduler:scheduler,reconnect:nil){log.append($0)}}
        party.runner.start()
        return party
    }
    func testAFullGameOverLoopbackWithEightSpectatorsEndsOnOneHashUnderOneMebibyte()throws {
        let transport=makeTransport()
        let (runner,hostLog,configuration)=try hostGame(transport,timeControl:.fivePlusThree)
        let endpoints=endpoints(hostLog),host=runner.host
        let guest=join(transport,configuration,endpoints,.seat,name:"Ben")
        let watchers=(0..<8).map{join(transport,configuration,endpoints,.watch,name:"Watcher \($0)")}
        let everyone=[guest]+watchers
        eventually("everyone live"){everyone.allSatisfy{$0.link == .live} && host.phase == .running && host.spectators.count==8}
        // Fool's mate: the guest, Black, mates on its second move.
        for (index,uci) in ["f2f3","e7e5","g2g4","d8h4"].enumerated() {
            if index%2==0 {runner.perform(.move(uci:uci))}else{guest.runner.submitMove(uci:uci)}
            eventually("ply \(index+1) everywhere"){host.revision>=index+1 && everyone.allSatisfy{$0.receiver.revision==host.revision}}
        }
        eventually("the result everywhere"){host.outcome != nil && everyone.allSatisfy{$0.receiver.outcome==host.outcome}}
        onQueue{
            XCTAssertEqual(host.outcome,NetworkOutcome(result:.blackWins,termination:.checkmate))
            let hashing=NetworkHashing(reviewHash)
            for party in everyone {
                XCTAssertEqual(party.receiver.fen,host.fen,"\(String(describing:party.link))")
                XCTAssertEqual(party.receiver.fen.map{hashing.positionHash(fen:$0,revision:party.receiver.revision ?? -1)},host.positionHash,"all parties end on the same hash")
            }
            XCTAssertGreaterThan(runner.peakBufferedBytes,0,"the count saw the traffic")
            XCTAssertLessThan(runner.peakBufferedBytes,1024*1024,"D7: the host's total stays under 1 MiB")
        }
        runner.perform(.leave)
        eventually("everyone stopped"){runner.stop != nil && everyone.allSatisfy{$0.runner.stop != nil}}
        onQueue{
            XCTAssertEqual(runner.stop,.left);XCTAssertTrue(everyone.allSatisfy{$0.runner.stop == .finished})
            XCTAssertEqual((runner.hosting as? NWNetworkHosting)?.isListening,false);XCTAssertEqual((runner.hosting as? NWNetworkHosting)?.openConnections,0)
        }
    }
    func testTheFifthPendingConnectionIsRefusedAndIdleOnesTimeOut()throws {
        let transport=makeTransport()
        let (runner,hostLog,configuration)=try hostGame(transport)
        let seat=endpoints(hostLog)[.seat]!,host=runner.host
        // TLS done, no hello: each holds an admission slot (D4, D7).
        let idle=(0..<4).map{_ in connect(transport,seat,configuration.key(.seat)!).log}
        eventually("four pending"){host.pendingConnections.count==4}
        let (_,fifth)=connect(transport,seat,configuration.key(.seat)!)
        eventually("the fifth refused"){fifth.closed != nil}
        XCTAssertEqual(onQueue{fifth.messages},[.bye(.busy)])
        let started=Date()
        eventually("the idle ones time out",timeout:NetworkLimits.admissionDeadline.timeInterval+3){idle.allSatisfy{$0.closed != nil}}
        XCTAssertGreaterThan(Date().timeIntervalSince(started),NetworkLimits.admissionDeadline.timeInterval-1.5)
        onQueue{XCTAssertTrue(idle.allSatisfy{$0.messages==[.bye(.timeout)]});XCTAssertTrue(host.pendingConnections.isEmpty);XCTAssertEqual(host.phase,.waiting)}
    }
    /// A spectator that never reads. On loopback the kernel's socket buffers take its traffic long before the host's
    /// per-peer cap would (the memory transport's test reaches `bye(slow)`), but it cannot answer pings either, so the
    /// pong deadline closes it; meanwhile the guest's moves keep arriving at once and the host stays under 1 MiB.
    func testASpectatorThatNeverReadsIsClosedWhileTheGuestsMovesArriveAtOnce()throws {
        let transport=makeTransport()
        let (runner,hostLog,configuration)=try hostGame(transport)
        let endpoints=endpoints(hostLog),host=runner.host
        let guest=join(transport,configuration,endpoints,.seat,name:"Ben")
        eventually("the guest live"){guest.link == .live && host.phase == .running}
        let silent=raw(endpoints[.watch]!,tls:configuration.key(.watch)!);ready(silent)
        write(silent,try NetworkFraming.frame(try NetworkCodec.encode(.hello(name:"Silent",appVersion:"0.8.0",claimID:nil))))
        let watched={hostLog.events.contains{if case .status(let status)=$0,status.spectators.contains("Silent") {return true};return false}}
        eventually("the silent spectator admitted"){watched()}
        runner.perform(.move(uci:"e2e4"))
        eventually("the move at the guest"){guest.receiver.revision==1}
        let started=Date()
        eventually("the silent spectator closed at the pong deadline",timeout:15){if case .status(let status)?=hostLog.events.last {return status.spectators.isEmpty};return false}
        XCTAssertLessThan(Date().timeIntervalSince(started),12)
        onQueue{
            let hostAt=hostLog.events.compactMap{if case .status(let status)=$0,status.game.revision==1 {return status.at};return nil}.first
            if let hostAt,let guestAt=guest.statusAt(revision:1) {XCTAssertLessThan(guestAt-hostAt,.milliseconds(50),"the guest's move arrived at once")}else{XCTFail("no move timings")}
            XCTAssertLessThan(runner.peakBufferedBytes,1024*1024);XCTAssertEqual(guest.link,.live)
        }
    }
    func testAFloodingSpectatorIsClosedWhileTheGuestsMovesArriveAtOnce()throws {
        let transport=makeTransport()
        let (runner,hostLog,configuration)=try hostGame(transport)
        let endpoints=endpoints(hostLog),host=runner.host
        let guest=join(transport,configuration,endpoints,.seat,name:"Ben")
        eventually("the guest live"){guest.link == .live && host.phase == .running}
        // A spectator says hello, then asks for snapshots as fast as its sends complete: over 20 messages a second.
        let flood=LinkLog(),sentBox=Box(0)
        let link=Box<NWNetworkLink?>(nil)
        let hello=try NetworkCodec.encode(.hello(name:"Flood",appVersion:"0.8.0",claimID:nil)),resync=try NetworkCodec.encode(.resync)
        flood.onEvent={event in
            switch event {
            case .ready:link.value?.send(hello)
            case .sent where sentBox.value<40:sentBox.value+=1;link.value?.send(resync)
            default:break
            }
        }
        link.value=connect(transport,endpoints[.watch]!,configuration.key(.watch)!,flood).link
        runner.perform(.move(uci:"e2e4"))
        eventually("the flooder closed"){flood.closed != nil}
        eventually("the move at the guest"){guest.receiver.revision==1}
        onQueue{
            XCTAssertTrue(flood.messages.contains(.bye(.rateLimited)),"\(flood.messages.map(\.type))")
            let hostAt=hostLog.events.compactMap{if case .status(let status)=$0,status.game.revision==1 {return status.at};return nil}.first
            let guestAt=guest.statusAt(revision:1)
            XCTAssertNotNil(hostAt);XCTAssertNotNil(guestAt)
            if let hostAt,let guestAt {XCTAssertLessThan(guestAt-hostAt,.milliseconds(50),"the guest's move arrived at once")}
        }
    }
    /// Real Bonjour on this Mac (D12 keeps it out of routine tests): run once with CHECKMATE_BONJOUR_SMOKE=1, never in a
    /// gate. It publishes a test-only service type, browses it, pairs both records by game ID and joins through them.
    func testBonjourPublishesBothListenersAndAJoinPairsThemByGameID()throws {
        guard ProcessInfo.processInfo.environment["CHECKMATE_BONJOUR_SMOKE"]=="1" else{throw XCTSkip("No Bonjour in routine tests (D12); CHECKMATE_BONJOUR_SMOKE=1 runs this once.")}
        let type="_checkmate-test._tcp"
        let transport=NWNetworkTransport(scheduler:scheduler,configuration:NWNetworkTransport.Configuration(serviceType:type,loopbackOnly:false))
        let configuration=makeConfiguration()
        _ = try startHosting(transport,configuration)
        let discovery=NWNetworkDiscovery(serviceType:type,scheduler:scheduler)
        let found=Box<[NetworkDiscoveredGame]>([]),denied=Box(false)
        onQueue{discovery.start{update in switch update {case .games(let games):found.value=games;case .denied:denied.value=true;case .failed:break}}}
        cleanups.append{discovery.stop()}
        eventually("both records of this game",timeout:20){found.value.contains{$0.gameID==configuration.gameID && $0.seat != nil && $0.watch != nil}}
        let game=onQueue{found.value.first{$0.gameID==configuration.gameID}!}
        onQueue{discovery.stop()}
        XCTAssertFalse(onQueue{denied.value});XCTAssertEqual(game.name,"Loopback")
        for role in [NetworkListenerRole.seat,.watch] {
            let code=role == .seat ? configuration.seatCode:configuration.watchCode!
            let (link,log)=connect(transport,game.record(role)!.endpoint,game.key(role,code:code))
            eventually("joined the \(role.rawValue) listener through Bonjour",timeout:15){log.ready || log.closed != nil}
            onQueue{XCTAssertTrue(log.ready,"\(String(describing:log.closed))");XCTAssertEqual(link.negotiated?.pinned,true)}
        }
    }
}
private extension Duration {
    var timeInterval:TimeInterval {let (seconds,attoseconds)=components;return TimeInterval(seconds)+TimeInterval(attoseconds)/1e18}
}
