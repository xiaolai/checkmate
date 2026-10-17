import XCTest
@testable import CheckmateDomain

/// Scripted behaviour shared by every fake game a factory makes, so the host's game and a receiver's scratch game
/// agree on what is illegal or mating.
final class FakeScript {
    var illegal:Set<String>=[],mating:Set<String>=[]
    var claimable:NetworkTermination?
    var bareKing:Set<NetworkSide>=[]
    /// Records loaded, so a test can tell a record refused unread from one replayed and then refused.
    var loads=0
}
/// Chess without chess: any well-formed UCI is legal unless scripted otherwise; the position is the move list.
final class FakeRules:NetworkChessRules {
    let script:FakeScript
    private(set) var moves:[String]=[]
    init(script:FakeScript){self.script=script}
    private var side:NetworkSide {moves.count%2==0 ? .white:.black}
    func networkFEN()throws -> String {"\(moves.isEmpty ? "start":moves.joined(separator:",")) \(side.rawValue) - - 0 \(moves.count/2+1)"}
    func networkSideToMove()throws -> NetworkSide {side}
    func networkPlay(uci:String)throws -> NetworkPlayedMove {
        guard ChessNotation.validUCI(uci),!script.illegal.contains(uci) else{throw NetworkRulesError.illegalMove}
        moves.append(uci);return NetworkPlayedMove(uci:uci,san:"S"+uci)
    }
    func networkAutomaticEnding()throws -> NetworkAutomaticEnding? {moves.last.flatMap{script.mating.contains($0) ? .checkmate(winner:side.opponent):nil}}
    func networkClaimableDraw()throws -> NetworkTermination? {script.claimable}
    func networkHasOnlyKing(_ side:NetworkSide)throws -> Bool {script.bareKing.contains(side)}
    func networkPGN()throws -> String {"[Fake]\n"+moves.joined(separator:" ")}
    func networkLoad(pgn:String)throws {
        script.loads+=1
        guard pgn.hasPrefix("[Fake]\n") else{throw NetworkRulesError.unexpected("not a fake record")}
        let list=pgn.dropFirst(7).split(separator:" ").map(String.init)
        guard list.allSatisfy(ChessNotation.validUCI) else{throw NetworkRulesError.unexpected("bad move")}
        moves=list
    }
    func networkMoves()throws -> [String] {moves}
}
/// FNV-1a: deterministic and collision-free enough for tests. Production injects SHA-256.
let testHashing=NetworkHashing{data in var hash:UInt64=0xcbf29ce484222325;for byte in data {hash^=UInt64(byte);hash=hash&*0x100000001b3};return String(hash,radix:16)}
/// SplitMix64 bytes: every identifier differs, and every run makes the same ones.
final class TestRandom {
    private var state:UInt64
    init(seed:UInt64){state=seed}
    func byte()->UInt8 {state&+=0x9E3779B97F4A7C15;var z=state;z=(z^(z>>30))&*0xBF58476D1CE4E5B9;z=(z^(z>>27))&*0x94D049BB133111EB;return UInt8(truncatingIfNeeded:z^(z>>31))}
    var source:NetworkRandom {NetworkRandom{count in (0..<count).map{_ in self.byte()}}}
}
func instant(_ seconds:Double)->NetworkInstant {NetworkInstant(.milliseconds(Int((seconds*1000).rounded())))}
func decoded(_ frames:[Data])->[NetworkMessage] {frames.map{try! NetworkCodec.decode($0)}}
/// A guest or spectator: a real `NetworkReceiver` on one connection at a time.
final class TestClient {
    let receiver:NetworkReceiver,listener:NetworkListenerRole
    var connection:NetworkConnectionID?
    var cursor=0
    var events:[NetworkReceiverEvent]=[]
    /// Every message the host delivered to this client, across connections.
    var received:[NetworkMessage]=[]
    /// Message types lost on the way to the host: a cut link.
    var lose:Set<String>=[]
    /// Set while the client does not answer pings (a frozen peer).
    var silent=false
    var closedWith:NetworkByeReason?
    init(receiver:NetworkReceiver,listener:NetworkListenerRole){self.receiver=receiver;self.listener=listener}
}
/// The host and its clients, wired in memory. Sends complete at once unless `autoComplete` is off; time moves only
/// through `advance` (which fires due timers) or `jump` (which does not, like a queue that is late to run them).
final class TestNetwork {
    let script=FakeScript(),random=TestRandom(seed:7)
    let gameID:NetworkGameID
    private(set) var host:NetworkHost!
    var now=NetworkInstant.origin
    var timers:[NetworkTimer:NetworkInstant]=[:]
    var sent:[NetworkConnectionID:[Data]]=[:]
    var closes:[NetworkConnectionID:NetworkByeReason]=[:]
    var refusals:[NetworkRejectReason]=[]
    var stoppedListening=false
    var autoComplete=true
    /// Connections whose sends never complete: a peer that stopped reading.
    var stalled:Set<NetworkConnectionID>=[]
    var clients:[TestClient]=[]
    init(hostSide:NetworkSide = .white,timeControl:NetworkTimeControl = .untimed,spectators:Bool=true,limits:NetworkHostLimits = .standard,epoch:NetworkID?=nil,assistance:NetworkAssistance = .off)throws {
        gameID=NetworkGameID.random(using:random.source)
        host=try NetworkHost(gameID:gameID,runEpoch:epoch ?? NetworkID.random(using:random.source),settings:NetworkHostSettings(hostName:"Ana",hostSide:hostSide,timeControl:timeControl,allowSpectators:spectators,assistance:assistance),rules:factory,hashing:testHashing,random:random.source,limits:limits,at:now)
    }
    var factory:NetworkRulesFactory {let script=script;return NetworkRulesFactory{FakeRules(script:script)}}
    var hostMoves:[String] {(try? host.publicGame(at:now).pgn).map{$0.dropFirst(7).split(separator:" ").map(String.init)} ?? []}
    func take(_ effects:[NetworkHostEffect])throws {
        var pending=effects
        while !pending.isEmpty {
            switch pending.removeFirst() {
            case .transmit(let id,let data):sent[id,default:[]].append(data);if autoComplete,!stalled.contains(id) {pending+=try host.sendCompleted(id,at:now)}
            case .close(let id,let reason):closes[id]=reason
            case .schedule(let timer,let at):timers[timer]=at
            case .cancel(let timer):timers[timer]=nil
            case .refused(let reason):refusals.append(reason)
            case .stopListening:stoppedListening=true
            }
        }
    }
    // Raw connections, for host tests that speak the protocol by hand.
    func open(_ listener:NetworkListenerRole)throws -> NetworkConnectionID {let (id,effects)=try host.accept(listener,at:now);try take(effects);return id}
    func send(_ message:NetworkMessage,on id:NetworkConnectionID)throws {try take(try host.receive(try NetworkCodec.encode(message),from:id,at:now))}
    func messages(_ id:NetworkConnectionID)->[NetworkMessage] {decoded(sent[id] ?? [])}
    func perform(_ action:NetworkHostAction)throws {try take(try host.perform(action,at:now))}
    func completeSend(_ id:NetworkConnectionID)throws {try take(try host.sendCompleted(id,at:now))}
    // Clients.
    /// `accepting`: the assistance terms a guest accepted before joining (assistance plan A3).
    func client(_ listener:NetworkListenerRole,name:String="Ben",claimID:NetworkSecret?=nil,accepting:NetworkAssistance = .off)->TestClient {
        let role:NetworkReceiverRole=listener == .seat ? .guest(claimID:claimID ?? NetworkSecret.random(using:random.source)):.spectator
        let client=TestClient(receiver:NetworkReceiver(gameID:gameID,role:role,name:name,appVersion:"0.8.0",rules:factory,hashing:testHashing,random:random.source,accepting:accepting),listener:listener)
        clients.append(client);return client
    }
    func connect(_ client:TestClient)throws {
        client.receiver.connectionLost();client.closedWith=nil
        let id=try open(client.listener);client.connection=id;client.cursor=0
        try toHost(client,client.receiver.opening());try settle()
    }
    func toHost(_ client:TestClient,_ message:NetworkMessage)throws {
        guard let id=client.connection,!client.lose.contains(message.type) else{return}
        if client.silent,case .pong=message {return}
        try send(message,on:id)
    }
    /// The link drops: the host hears of it, unless `tell` is false (the host's view lags).
    func cut(_ client:TestClient,tell:Bool=true)throws {
        guard let id=client.connection else{return}
        client.connection=nil;client.receiver.connectionLost()
        if tell {try take(try host.connectionClosed(id,at:now))}
    }
    /// Delivers everything the host has sent until nothing more happens.
    func settle()throws {
        var progressed=true
        while progressed {
            progressed=false
            for client in clients {
                guard let id=client.connection else{continue}
                let frames=sent[id] ?? []
                while client.cursor<frames.count,client.connection==id {
                    let data=frames[client.cursor];client.cursor+=1;progressed=true
                    client.received.append(try NetworkCodec.decode(data))
                    let output=try client.receiver.receive(data,at:now)
                    client.events+=output.events
                    for message in output.send {try toHost(client,message)}
                    if let reason=output.close {client.closedWith=reason;try toHost(client,.bye(reason));try cut(client)}
                }
                if client.connection==id,let reason=closes[id],client.cursor>=(sent[id]?.count ?? 0) {
                    client.events+=try client.receiver.receive(message:.bye(reason),at:now).events
                    client.closedWith=reason;client.connection=nil;client.receiver.connectionLost()
                }
            }
        }
    }
    func advance(_ seconds:Double)throws {
        let target=now + .milliseconds(Int((seconds*1000).rounded()))
        var fires=0
        while case let (timer,at)?=timers.filter({$0.value<=target}).min(by:{$0.value<$1.value || ($0.value==$1.value && NetworkTimer.order($0.key,$1.key))}).map({($0.key,$0.value)}) {
            fires+=1;guard fires<=20_000 else{return XCTFail("timers keep firing at \(now): a deadline the host never resolves")}
            timers[timer]=nil;now=max(now,at)
            try take(try host.timerFired(timer,at:now));try settle()
        }
        now=target
    }
    /// Moves time without firing anything: the next event finds its deadlines overdue.
    func jump(_ seconds:Double){now=now + .milliseconds(Int((seconds*1000).rounded()))}
    /// A guest seated and acknowledged, plus `spectators` watchers, all current.
    func startGame(spectators:Int=0)throws -> (guest:TestClient,watchers:[TestClient]) {
        let guest=client(.seat,accepting:host.settings.assistance);try connect(guest)
        let watchers=try (0..<spectators).map{index->TestClient in let watcher=client(.watch,name:"Watcher \(index)");try connect(watcher);return watcher}
        return (guest,watchers)
    }
    func play(_ client:TestClient,_ uci:String,assisted:Bool=false)throws {guard let message=try client.receiver.submitMove(uci:uci,assisted:assisted) else{return XCTFail("move \(uci) ignored")};try toHost(client,message);try settle()}
    func command(_ client:TestClient,_ message:NetworkMessage?)throws {guard let message else{return XCTFail("command unavailable")};try toHost(client,message);try settle()}
    func hostPlays(_ uci:String,assisted:Bool=false)throws {try perform(.move(uci:uci,assisted:assisted));try settle()}
}
