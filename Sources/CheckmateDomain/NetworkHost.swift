import Foundation
public enum NetworkListenerRole:String,Codable {case seat,watch}
/// An accepted connection, numbered by the host in arrival order: its generation (D4). Every event names one, and an
/// event for a connection the host no longer holds (closed, replaced) is dropped, so closing a replaced connection
/// can never pause or detach its replacement.
public struct NetworkConnectionID:Hashable,Comparable,CustomStringConvertible {
    public let generation:UInt64
    public init(generation:UInt64){self.generation=generation}
    public static func <(a:NetworkConnectionID,b:NetworkConnectionID)->Bool {a.generation<b.generation}
    public var description:String {"connection \(generation)"}
}
/// The host game is always in exactly one phase (D4).
public enum NetworkHostPhase:String,Equatable {
    /// Free seat; one claim may reserve it; spectators may join. Clocks stopped.
    case waiting
    /// Claimed, no `seatedAck` yet. No moves from either side. Clocks stopped.
    case reserved
    /// Moves, offers, claims, resignation. The side to move runs once the first move is applied.
    case running
    /// The guest dropped and its seat is held. Resume, or the host's Claim Win or Keep Waiting. Clocks paused.
    case disconnected
    /// Review and leaving only.
    case ended
}
/// A named timer the Application keeps. `schedule` replaces any earlier schedule of the same timer; when one fires,
/// call `timerFired`. A late, early or duplicate fire is harmless: the host acts on deadlines, not on fires.
public enum NetworkTimer:Hashable {
    case flag,reservation,hold,ping,clockMessage
    case admission(NetworkConnectionID)
    static func order(_ a:NetworkTimer,_ b:NetworkTimer)->Bool {a.key.lexicographicallyPrecedes(b.key)}
    private var key:[UInt64] {switch self{case .flag:return [0];case .reservation:return [1];case .hold:return [2];case .ping:return [3];case .clockMessage:return [4];case .admission(let id):return [5,id.generation]}}
}
/// What the Application must do, in order, after an event.
public enum NetworkHostEffect:Equatable {
    /// Hand this encoded message to the connection (the transport adds the length prefix), then report
    /// `sendCompleted` once the system has taken the bytes. The host hands each peer one message at a time.
    case transmit(NetworkConnectionID,Data)
    /// Send `bye(reason)` if the connection can still take it, then cancel it. No further event is expected for it,
    /// and any that arrives is dropped.
    case close(NetworkConnectionID,NetworkByeReason)
    case schedule(NetworkTimer,at:NetworkInstant)
    case cancel(NetworkTimer)
    /// The host's own action was refused; nothing changed.
    case refused(NetworkRejectReason)
    /// Close both listeners: the host left.
    case stopListening
}
/// The host's own commands. They pass the same rules as the guest's (D5), so the host has no shortcut.
public enum NetworkHostAction:Equatable {
    /// `assisted`: a hint was shown to the host this turn (assistance plan A7).
    case move(uci:String,assisted:Bool=false),resign,offerDraw,answerDraw(accept:Bool),claimDraw
    /// After the hold expires with the guest away: Claim Win (Abandoned), or Keep Waiting another 120 s.
    case claimWin,keepWaiting
    /// Leave or quit normally (R3-2): a started game is resigned and `ended(resignation)` reaches everyone before
    /// each connection closes.
    case leave
}
public struct NetworkHostSettings:Equatable {
    public var hostName:String,hostSide:NetworkSide,timeControl:NetworkTimeControl,allowSpectators:Bool
    /// Fixed for the whole game (assistance plan A2): nothing the host does or receives changes it.
    public let assistance:NetworkAssistance
    /// The declared start (mini-games plan D7); nil for the standard start. Fixed for the whole game. The host's own
    /// settings hold it canonical: `NetworkHost` replaces a given FEN by the one its rules write back.
    public let startFEN:String?
    /// The mini-game ruleset the game is played by (protocol 1.3), or nil for chess. Fixed for the whole game; a
    /// ruleset game has its kind's own start and no assistance.
    public let ruleset:NetworkRuleset?
    public init(hostName:String,hostSide:NetworkSide,timeControl:NetworkTimeControl = .untimed,allowSpectators:Bool=true,assistance:NetworkAssistance = .off,startFEN:String?=nil,ruleset:NetworkRuleset?=nil){self.hostName=hostName;self.hostSide=hostSide;self.timeControl=timeControl;self.allowSpectators=allowSpectators;self.assistance=assistance;self.startFEN=startFEN;self.ruleset=ruleset}
    func starting(at fen:String?)->NetworkHostSettings {NetworkHostSettings(hostName:hostName,hostSide:hostSide,timeControl:timeControl,allowSpectators:allowSpectators,assistance:assistance,startFEN:fen,ruleset:ruleset)}
}
/// D7's numbers for one host. Always `standard` in the app; tests shrink them to reach a bound quickly.
public struct NetworkHostLimits:Equatable {
    public var peerQueueBytes=NetworkLimits.peerQueueBytes,spectatorQueuesBytes=NetworkLimits.spectatorQueuesBytes
    public var maximumSpectators=NetworkLimits.maximumSpectators,pendingPerListener=NetworkLimits.pendingConnectionsPerListener
    /// Distinct snapshot records held for peers still sending them. Queue budgets do not count these payloads, so they
    /// get what D7's 1 MiB leaves once every other buffer is at its worst: all queues full, every admitted connection's
    /// send in flight counted again by the transport, and a partial frame on every connection the host may hold. That
    /// is about 32 KB, a record of some 2,800 moves. A spectator asking past it is closed as slow; the guest's own
    /// snapshot is never refused, so spectators sending other records are closed to make room for it, and only a guest
    /// in a game longer than anyone plays (a record over the whole budget) takes the total past 1 MiB, by that record.
    public var retainedCaptureBytes=NetworkLimits.hostBufferBytes-NetworkLimits.spectatorQueuesBytes-NetworkLimits.peerQueueBytes-(1+NetworkLimits.maximumSpectators)*Self.frameBytes-(1+NetworkLimits.maximumSpectators+2*NetworkLimits.pendingConnectionsPerListener)*(Self.frameBytes-1)-1
    static let frameBytes=NetworkFraming.headerBytes+NetworkLimits.maximumMessageBytes
    public init(){}
    public static let standard=NetworkHostLimits()
}
public enum NetworkHostError:Error,Equatable {
    case invalidName
    /// The start is no position a game could reach (D7: `NetworkChessRules.networkLoad(start:)`), or its FEN is not
    /// one a record may declare (`NetworkStart.wellFormed`).
    case illegalStart
    /// The game is already over at the start: checkmate, stalemate or an automatic draw (D7).
    case startOver
    /// A mini-game is played without assistance (protocol 1.3).
    case assistanceNotAllowed
}
/// Receipts for the last 64 commands (D2): a repeated `commandID` gets its stored replies again and nothing else.
struct NetworkReceipts {
    private var replies:[NetworkID:[NetworkMessage]]=[:],order:[NetworkID]=[]
    subscript(id:NetworkID)->[NetworkMessage]? {replies[id]}
    var count:Int {order.count}
    mutating func store(_ receipt:[NetworkMessage],for id:NetworkID){
        if replies[id]==nil {order.append(id)}
        replies[id]=receipt
        if order.count>NetworkLimits.storedReceipts {replies[order.removeFirst()]=nil}
    }
}
/// The authoritative host of one network game (D2, D4–D7): a pure state machine. It takes events stamped with the
/// moment the host queue starts processing them and returns effects; it does no I/O, keeps no timer and starts no
/// thread. Call it from one queue only.
///
/// Rules failures throw (from any method). After a throw the host's state is undefined: the Application must close
/// everything and treat the game as interrupted, exactly as if the host had crashed.
public final class NetworkHost:CustomReflectable {
    public let gameID:NetworkGameID,settings:NetworkHostSettings
    private let runEpoch:NetworkID,rules:any NetworkChessRules,hashing:NetworkHashing,random:NetworkRandom,limits:NetworkHostLimits
    public private(set) var phase=NetworkHostPhase.waiting
    /// Advanced only by an applied move and by `ended` (D2).
    public private(set) var revision=0
    /// Nil for an untimed game.
    public private(set) var clock:NetworkClock?
    public private(set) var openOffer:NetworkDrawOffer?
    public private(set) var outcome:NetworkOutcome?
    public private(set) var guestName:String?
    public private(set) var sideToMove:NetworkSide
    public private(set) var fen:String
    public private(set) var reservationDeadline:NetworkInstant?
    /// The hold in effect while the guest is away; once it passes, `holdExpired` offers Claim Win or Keep Waiting.
    public private(set) var holdDeadline:NetworkInstant?
    public private(set) var holdExpired=false
    /// The plies whose mover said a hint was shown that turn (A7), in order.
    public private(set) var assistedPlies:[Int]=[]
    /// Every pending timer, as last scheduled.
    public private(set) var scheduled:[NetworkTimer:NetworkInstant]=[:]
    private var seat:Seat?
    private var peers:[NetworkConnectionID:Peer]=[:]
    /// The latest snapshot capture and the public game it records; reused while that game is unchanged.
    private var lastCapture:(game:NetworkPublicGame,capture:NetworkSnapshot)?
    private var receipts=NetworkReceipts()
    private var nextGeneration:UInt64=1
    private var nextPing:NetworkInstant?,nextClockMessage:NetworkInstant?
    private var leaving=false
    private var now:NetworkInstant
    private var effects:[NetworkHostEffect]=[]
    /// The claim and its credential (D4): 256 random bits each, bound to this game, this host run and the guest seat.
    /// Neither appears in any snapshot, spectator message, description or mirror.
    private struct Seat {
        let claimID:NetworkSecret,credential:NetworkSecret,gameID:NetworkGameID,epoch:NetworkID
        var connection:NetworkConnectionID?
        var valid=true
    }
    private enum Role:Equatable {case pending(deadline:NetworkInstant),guest,spectator}
    private struct Peer {
        let listener:NetworkListenerRole
        var role:Role,outbox:NetworkOutbox
        var name:String?
        var pings:[(nonce:NetworkID,sentAt:NetworkInstant)]=[]
        var inbound=NetworkRateWindow()
        var closeWhenFlushed=false
        /// The record changed in a way no message carries (the guest's name) while a snapshot was already on its way:
        /// another follows it.
        var snapshotStale=false
    }
    private enum Origin {case host,guest(NetworkConnectionID,commandID:NetworkID)}
    /// `runEpoch` is made once per app launch; `gameID` is the one published in both TXT records.
    public init(gameID:NetworkGameID,runEpoch:NetworkID,settings:NetworkHostSettings,rules factory:NetworkRulesFactory,hashing:NetworkHashing,random:NetworkRandom = .system,limits:NetworkHostLimits = .standard,at now:NetworkInstant)throws {
        guard NetworkText.valid(settings.hostName) else{throw NetworkHostError.invalidName}
        // Protocol 1.3: a ruleset game starts from its kind's own board, with no declared start and no assistance.
        if settings.ruleset != nil {
            guard settings.startFEN==nil else{throw NetworkHostError.illegalStart}
            guard settings.assistance == .off else{throw NetworkHostError.assistanceNotAllowed}
        }
        var rules=try factory.newGame(settings.ruleset),settings=settings
        // D7: the start is set up once, here, and kept as the rules write it back. The standard start, however it was
        // written, is no declared start: the game is then exactly a 1.1 game.
        if let given=settings.startFEN {
            do{try rules.networkLoad(start:given)}catch NetworkRulesError.illegalStart{throw NetworkHostError.illegalStart}
            let canonical=try rules.networkFEN()
            if try rules.networkStartFEN()==NetworkStart.standard {rules=try factory.newGame();settings=settings.starting(at:nil)}
            else{
                guard NetworkStart.wellFormed(canonical) else{throw NetworkHostError.illegalStart}
                guard try rules.networkAutomaticEnding()==nil else{throw NetworkHostError.startOver}
                settings=settings.starting(at:canonical)
            }
        }
        self.gameID=gameID;self.runEpoch=runEpoch;self.settings=settings;self.hashing=hashing;self.random=random;self.limits=limits;self.now=now
        self.rules=rules;sideToMove=try rules.networkSideToMove();fen=try rules.networkFEN()
        clock=NetworkClock(timeControl:settings.timeControl,at:now)
    }
    public var customMirror:Mirror {Mirror(self,children:["gameID":gameID,"phase":phase,"revision":revision])}
    public var guestSide:NetworkSide {settings.hostSide.opponent}
    /// What every guest and spectator must state in `hello` and `resume` to be admitted (D7): `start` for a declared
    /// start, nothing for the standard start.
    /// A ruleset game requires its ruleset's token instead (protocol 1.3).
    public var requiredCapabilities:NetworkCapabilities {
        if let ruleset=settings.ruleset {return NetworkCapabilities([ruleset.capability])!}
        return settings.startFEN==nil ? .none:NetworkCapabilities([NetworkStart.capability])!
    }
    public var positionHash:String {hashing.positionHash(fen:fen,revision:revision)}
    public var guestConnection:NetworkConnectionID? {seat?.connection}
    public var spectators:[NetworkConnectionID] {peers.filter{$0.value.role == .spectator}.map(\.key).sorted()}
    public var spectatorNames:[String] {spectators.compactMap{peers[$0]?.name}}
    public var pendingConnections:[NetworkConnectionID] {peers.filter{if case .pending=$0.value.role{return true};return false}.map(\.key).sorted()}
    /// D7 byte accounting for one connection, or nil once the host no longer holds it.
    public func queuedBytes(_ connection:NetworkConnectionID)->Int? {peers[connection]?.outbox.bytes}
    public var spectatorQueuedBytes:Int {spectators.reduce(0){$0+(peers[$1]?.outbox.bytes ?? 0)}}
    /// D7: the records held for snapshots still being sent, each distinct capture counted once. Peers asking while the
    /// public game is unchanged share one capture, so eight spectators joining together hold one copy of the record.
    public var snapshotBytes:Int {
        var seen=Set<NetworkID>()
        let pending=peers.values.reduce(0){total,peer in
            guard let capture=peer.outbox.pendingSnapshot,seen.insert(capture.snapshotID).inserted else{return total}
            return total+capture.payload.count
        }
        // The cached capture is released as soon as no peer is sending it (`pump`), so it is always among these.
        return pending
    }
    public var outstandingPings:Int {peers.values.reduce(0){$0+$1.pings.count}}
    public var storedReceipts:Int {receipts.count}
    /// The public record at `now`: what a snapshot carries and the crash file keeps (D9). Never a secret.
    public func publicGame(at now:NetworkInstant)throws -> NetworkPublicGame {
        let host=settings.hostSide
        return NetworkPublicGame(gameID:gameID,revision:revision,hostSide:host,whiteName:host == .white ? settings.hostName:guestName,blackName:host == .black ? settings.hostName:guestName,timeControl:settings.timeControl,pgn:try rules.networkPGN(),clocks:clock?.clocks(at:now),openOffer:openOffer,outcome:outcome,assistance:settings.assistance,assistedPlies:assistedPlies,startFEN:settings.startFEN,ruleset:settings.ruleset?.descriptor)
    }
    // MARK: Events
    /// A connection finished TLS on `listener`. It holds an admission slot until `hello` or `resume`, for at most 5 s.
    public func accept(_ listener:NetworkListenerRole,at now:NetworkInstant)throws -> (connection:NetworkConnectionID,effects:[NetworkHostEffect]) {
        let id=NetworkConnectionID(generation:nextGeneration);nextGeneration+=1
        let output=try event(at:now){
            let pending=peers.values.filter{if case .pending=$0.role{return $0.listener==listener};return false}.count
            var refusal:NetworkByeReason?
            if leaving {refusal = .hostLeft}else if phase == .ended {refusal = .gameOver}else if listener == .watch && !settings.allowSpectators {refusal = .notAllowed}else if pending>=limits.pendingPerListener {refusal = .busy}
            if let refusal {effects.append(.close(id,refusal));return}
            peers[id]=Peer(listener:listener,role:.pending(deadline:self.now+NetworkLimits.admissionDeadline),outbox:NetworkOutbox(capacity:limits.peerQueueBytes))
        }
        return (id,output)
    }
    /// One framed message's payload from a connection.
    public func receive(_ data:Data,from connection:NetworkConnectionID,at now:NetworkInstant)throws -> [NetworkHostEffect] {
        let decoded=Result{try NetworkCodec.decode(data)}
        return try event(at:now,settle:false){try handle(decoded,from:connection)}
    }
    /// An already decoded message (the in-memory transport and tests).
    public func receive(message:NetworkMessage,from connection:NetworkConnectionID,at now:NetworkInstant)throws -> [NetworkHostEffect] {
        try event(at:now,settle:false){try handle(.success(message),from:connection)}
    }
    /// The transport finished sending the last message handed to it on this connection.
    public func sendCompleted(_ connection:NetworkConnectionID,at now:NetworkInstant)throws -> [NetworkHostEffect] {
        try event(at:now){guard peers[connection] != nil else{return};peers[connection]!.outbox.completed();try pump(connection)}
    }
    /// The connection closed or failed on its own.
    public func connectionClosed(_ connection:NetworkConnectionID,at now:NetworkInstant)throws -> [NetworkHostEffect] {
        // The close comes first, before any deadline due at this instant: a ping falling due now must not be queued
        // for the connection the transport has just said is gone.
        try event(at:now,first:{guard let peer=peers.removeValue(forKey:connection) else{return};if peer.role == .guest {try guestDropped()}}){}
    }
    public func timerFired(_ timer:NetworkTimer,at now:NetworkInstant)throws -> [NetworkHostEffect] {
        // The transport's timer is spent; if the deadline still stands it is scheduled again.
        scheduled[timer]=nil
        return try event(at:now){}
    }
    public func perform(_ action:NetworkHostAction,at now:NetworkInstant)throws -> [NetworkHostEffect] {
        try event(at:now){
            let side=settings.hostSide,started=phase == .running || phase == .disconnected
            switch action {
            case .leave:try leave()
            case .claimWin:guard phase == .disconnected,holdExpired else{try refuse(.host,.notRunning);return};try end(NetworkOutcome(result:.win(for:side),termination:.abandoned))
            case .keepWaiting:guard phase == .disconnected,holdExpired else{try refuse(.host,.notRunning);return};holdDeadline=self.now+NetworkLimits.holdDuration;holdExpired=false
            case .resign:guard started else{try refuse(.host,phase == .ended ? .gameOver:.notRunning);return};try resign(side,.host)
            case .move,.offerDraw,.answerDraw,.claimDraw:
                guard phase == .running else{try refuse(.host,phase == .ended ? .gameOver:.notRunning);return}
                switch action {
                case .move(let uci,let assisted):guard sideToMove==side else{try refuse(.host,.notYourTurn);return};try play(uci,by:side,assisted:assisted,.host)
                case .answerDraw(let accept):try answerDraw(nil,accept:accept,by:side,.host)
                case .claimDraw:guard sideToMove==side else{try refuse(.host,.notYourTurn);return};try claimDraw(.host)
                case .offerDraw:try offerDraw(side,.host)
                default:break
                }
            }
        }
    }
    /// Every event: overdue deadlines first, then (unless the event settles at its own point, as a command does after
    /// the D2 checks) settle the clock and check the flag, then the event, then housekeeping and timers.
    private func event(at now:NetworkInstant,settle:Bool=true,first:()throws -> Void={},_ body:()throws -> Void)throws -> [NetworkHostEffect] {
        effects=[];defer{effects=[]}
        self.now=max(self.now,now)
        try first()
        try expireDeadlines()
        if settle {try settleClock()}
        try body()
        try housekeeping()
        return effects
    }
    private func expireDeadlines()throws {
        for id in pendingConnections {if case .pending(let deadline)?=peers[id]?.role,now>=deadline {try close(id,.timeout)}}
        if phase == .reserved,let deadline=reservationDeadline,now>=deadline {
            // No ack within 30 s: the reservation lapses and the seat is free. Only possible before any move.
            if let connection=seat?.connection {detach(connection,.timeout)}
            seat=nil;guestName=nil;reservationDeadline=nil;phase = .waiting;try refreshSpectators()
        }
        if phase == .disconnected,!holdExpired,let deadline=holdDeadline,now>=deadline {holdExpired=true}
        if let due=nextPing,now>=due {
            nextPing=now+NetworkLimits.pingInterval
            for id in admitted() {
                guard let peer=peers[id] else{continue}
                if let oldest=peer.pings.first,now-oldest.sentAt>=NetworkLimits.pongDeadline {try close(id,.timeout);continue}
                guard peer.pings.count<NetworkLimits.maximumOutstandingPings else{continue}
                let nonce=NetworkID.random(using:random);peers[id]!.pings.append((nonce,now));try send(.ping(nonce:nonce),to:id)
            }
        }
    }
    private func housekeeping()throws {
        // After every event: a peer that closed may have been the last one sending the cached capture.
        releaseIdleCapture()
        if phase == .running,let clock,clock.active != nil {
            if let due=nextClockMessage {if now>=due {nextClockMessage=now+NetworkLimits.clockMessageInterval;try broadcast(.clock(clock.clocks(at:now)))}}
            else {nextClockMessage=now+NetworkLimits.clockMessageInterval}
        }else{nextClockMessage=nil}
        if !admitted().isEmpty && !leaving {nextPing=nextPing ?? now+NetworkLimits.pingInterval}else{nextPing=nil}
        var wanted:[NetworkTimer:NetworkInstant]=[:]
        if phase == .running,let deadline=clock?.flagDeadline {wanted[.flag]=deadline}
        if phase == .reserved,let deadline=reservationDeadline {wanted[.reservation]=deadline}
        if phase == .disconnected,!holdExpired,let deadline=holdDeadline {wanted[.hold]=deadline}
        if let due=nextPing {wanted[.ping]=due}
        if let due=nextClockMessage {wanted[.clockMessage]=due}
        for (id,peer) in peers {if case .pending(let deadline)=peer.role {wanted[.admission(id)]=deadline}}
        for timer in scheduled.keys.sorted(by:NetworkTimer.order) where wanted[timer]==nil {effects.append(.cancel(timer))}
        for timer in wanted.keys.sorted(by:NetworkTimer.order) where scheduled[timer] != wanted[timer] {effects.append(.schedule(timer,at:wanted[timer]!))}
        scheduled=wanted
    }
    /// D6 steps 2 and 3: settle, then a flag at zero ends the game on time before the event is applied.
    private func settleClock()throws {
        guard phase == .running,clock != nil else{return}
        clock!.settle(at:now)
        if let flagged=clock!.flagged {try end(NetworkClock.flagOutcome(flagged:flagged,opponentHasOnlyKing:try rules.networkHasOnlyKing(flagged.opponent)))}
    }
    // MARK: Messages
    private func handle(_ decoded:Result<NetworkMessage,Error>,from id:NetworkConnectionID)throws {
        guard peers[id] != nil else{return}
        guard peers[id]!.inbound.admit(at:now) else{try close(id,.rateLimited);return}
        let message:NetworkMessage
        switch decoded {case .success(let value):message=value;case .failure(let error):try close(id,(error as? NetworkCodecError)?.byeReason ?? .malformed);return}
        let role=peers[id]!.role
        if role == .guest,Self.header(message) != nil {try command(message,from:id);return}
        try settleClock()
        if case .bye=message {let wasGuest=role == .guest;detach(id,.leaving);if wasGuest {try guestDropped()};return}
        switch role {
        case .pending:try admit(message,from:id)
        case .spectator:
            switch message {
            case .hello:break
            case .resync:try requestSnapshot(id)
            case .pong(let nonce):try pong(nonce,from:id)
            default:try close(id,.notAllowed)
            }
        case .guest:
            switch message {
            case .seatedAck:if phase == .reserved,seat?.connection==id {phase = .running;reservationDeadline=nil}
            case .resume(let game,let credential,let stated):try resume(game,credential,stating:stated,from:id)
            case .resync:try requestSnapshot(id)
            case .pong(let nonce):try pong(nonce,from:id)
            default:try close(id,.malformed)
            }
        }
    }
    private func admit(_ message:NetworkMessage,from id:NetworkConnectionID)throws {
        // D7: a hello that does not state what the game requires is refused first, before a seat is reserved, a claim
        // answered again, a spectator let in or a snapshot sent. A `resume` is checked the same way in `resume`.
        if case .hello(_,_,_,_,let stated)=message,!capable(stated) {try close(id,.protocolVersion);return}
        switch (peers[id]!.listener,message) {
        // A spectator's stated terms, if any, change nothing: spectators never get assistance (A1).
        case (.watch,.hello(let name,_,_,_,_)):
            guard spectators.count<limits.maximumSpectators else{try close(id,.full);return}
            peers[id]!.role = .spectator;peers[id]!.name=name
            try send(.watching,to:id);try requestSnapshot(id)
        case (.seat,.hello(let name,_,let claimID?,let accepted,_)):
            // A3: the terms the guest accepted are checked before the seat is reserved or the claim answered again.
            if phase == .waiting || phase == .reserved && seat?.claimID.matches(claimID)==true,let refusal=termsRefusal(accepted) {try close(id,refusal);return}
            switch phase {
            case .waiting:
                seat=Seat(claimID:claimID,credential:.random(using:random),gameID:gameID,epoch:runEpoch)
                guestName=name;reservationDeadline=now+NetworkLimits.reservationDuration;phase = .reserved;try refreshSpectators()
                try attachGuest(id);try sendSeated(id)
            case .reserved where seat?.claimID.matches(claimID)==true:try attachGuest(id);try sendSeated(id)
            case .reserved,.running,.disconnected:try close(id,.seatTaken)
            case .ended:try close(id,.gameOver)
            }
        case (.seat,.resume(let game,let credential,let stated)):try resume(game,credential,stating:stated,from:id)
        default:try close(id,.malformed)
        }
    }
    /// A3's table: the same terms are admitted; other terms are `assistanceChanged`; none stated (a 1.0 guest) is
    /// admitted only to a game without assistance, and otherwise refused as another version, which a 1.0 guest words
    /// as "update Checkmate".
    private func termsRefusal(_ accepted:NetworkAssistance?)->NetworkByeReason? {
        guard let accepted else{return settings.assistance == .off ? nil:.protocolVersion}
        return accepted==settings.assistance ? nil:.assistanceChanged
    }
    /// Whether a connection's stated capabilities cover what the game requires (D7). A 1.1 peer states none.
    private func capable(_ stated:NetworkCapabilities?)->Bool {requiredCapabilities.isSubset(of:stated ?? .none)}
    private func sendSeated(_ id:NetworkConnectionID)throws {try send(.seated(credential:seat!.credential),to:id);try requestSnapshot(id)}
    /// The recovery table (R4-4): a valid credential while reserved counts as the ack; while running it replaces the
    /// guest's connection; while disconnected it ends the hold. Resuming the current holder just answers again.
    ///
    /// A connection that does not state what the game requires (D7) is refused before any of it: the seat, the hold, the
    /// clocks and the current connection stay as they were, and no snapshot is sent.
    private func resume(_ game:NetworkGameID,_ credential:NetworkSecret,stating stated:NetworkCapabilities?,from id:NetworkConnectionID)throws {
        guard capable(stated) else{try close(id,.protocolVersion);return}
        guard phase != .ended else{try close(id,.gameOver);return}
        guard let seat,seat.valid,game==gameID,seat.gameID==gameID,seat.epoch==runEpoch,seat.credential.matches(credential) else{try close(id,.badCredential);return}
        let wasDisconnected=phase == .disconnected
        switch phase {
        case .reserved:phase = .running;reservationDeadline=nil
        case .disconnected:phase = .running;holdDeadline=nil;holdExpired=false;clock?.resume(sideToMove:sideToMove,at:now)
        default:break
        }
        try attachGuest(id)
        try send(.resumed,to:id);try requestSnapshot(id)
        // And that they run again, now the guest is back.
        if wasDisconnected,let clock {for watcher in spectators {try send(.clock(clock.clocks(at:now)),to:watcher)}}
    }
    /// The host first closes any older connection holding the seat, then attaches the new generation.
    private func attachGuest(_ id:NetworkConnectionID)throws {
        if let old=seat?.connection,old != id {detach(old,.replaced)}
        peers[id]?.role = .guest;seat?.connection=id
    }
    private func pong(_ nonce:NetworkID,from id:NetworkConnectionID)throws {
        guard let index=peers[id]?.pings.firstIndex(where:{$0.nonce==nonce}) else{try close(id,.malformed);return}
        peers[id]!.pings.remove(at:index)
    }
    private static func header(_ message:NetworkMessage)->(game:NetworkGameID,command:NetworkID,revision:Int?)? {
        switch message {
        case .move(let game,let command,let revision,_,_),.drawOffer(let game,let command,let revision),.claimDraw(let game,let command,let revision):return (game,command,revision)
        case .resign(let game,let command),.drawAnswer(let game,let command,_,_):return (game,command,nil)
        default:return nil
        }
    }
    /// D2's fixed order, before anything changes: generation (the connection is the seat's current one, or the event
    /// was dropped already), game, duplicate, revision, turn. Then D6: settle, flag, apply.
    private func command(_ message:NetworkMessage,from id:NetworkConnectionID)throws {
        guard case let (game,commandID,commandRevision)?=Self.header(message) else{return}
        guard game==gameID else{try send(.rejected(commandID:commandID,reason:.wrongGame),to:id);return}
        if let receipt=receipts[commandID] {for reply in receipt {try send(reply,to:id)};return}
        var verdict:NetworkRejectReason?
        if let commandRevision,commandRevision != revision {verdict = .stale}
        else if phase == .ended {verdict = .gameOver}
        else if phase != .running {verdict = .notRunning}
        else if sideToMove != guestSide {switch message{case .move,.claimDraw:verdict = .notYourTurn;default:break}}
        try settleClock()
        if verdict==nil,phase == .ended {verdict = .gameOver}
        let origin=Origin.guest(id,commandID:commandID)
        if let verdict {try refuse(origin,verdict);return}
        switch message {
        case .move(_,_,_,let uci,let assisted):try play(uci,by:guestSide,assisted:assisted,origin)
        case .resign:try resign(guestSide,origin)
        case .drawOffer:try offerDraw(guestSide,origin)
        case .drawAnswer(_,_,let offerID,let accept):try answerDraw(offerID,accept:accept,by:guestSide,origin)
        case .claimDraw:try claimDraw(origin)
        default:break
        }
    }
    private func refuse(_ origin:Origin,_ reason:NetworkRejectReason)throws {
        switch origin {
        case .host:effects.append(.refused(reason))
        case .guest(let id,let commandID):
            let reply=NetworkMessage.rejected(commandID:commandID,reason:reason)
            receipts.store([reply],for:commandID);try send(reply,to:id)
            // `rejected` never embeds a snapshot; a chunked one follows (D5).
            if reason == .stale {try requestSnapshot(id)}
        }
    }
    private func answered(_ origin:Origin,_ receipt:NetworkMessage?){if case .guest(_,let commandID)=origin,let receipt {receipts.store([receipt],for:commandID)}}
    // MARK: Game
    private func play(_ uci:String,by side:NetworkSide,assisted:Bool,_ origin:Origin)throws {
        let played:NetworkPlayedMove
        do{played=try rules.networkPlay(uci:uci)}catch NetworkRulesError.illegalMove{try refuse(origin,.illegal);return}
        sideToMove=side.opponent;revision+=1;fen=try rules.networkFEN()
        // A ruleset game has no assistance (protocol 1.3): a mover's `assisted` is dropped, never recorded or sent.
        let assisted=assisted && settings.ruleset==nil
        // The revision is the ply count until the game ends: only moves advance it before `ended`.
        if assisted {assistedPlies.append(revision)}
        clock?.moveApplied(by:side)
        // An offer lapses when the player it was made to moves.
        if let offer=openOffer,offer.by != side {openOffer=nil}
        var receiptFor:NetworkID?;if case .guest(_,let commandID)=origin {receiptFor=commandID}
        let moved=NetworkMoved(revision:revision,uci:played.uci,san:played.san,hash:positionHash,clocks:clock?.clocks(at:now),receiptFor:receiptFor,assisted:assisted)
        answered(origin,.moved(moved))
        try broadcast{[self] id in .moved(peers[id]?.role == .guest ? moved:moved.withoutReceipt())}
        if let ending=try rules.networkAutomaticEnding() {try end(ending.outcome)}
    }
    private func resign(_ side:NetworkSide,_ origin:Origin)throws {answered(origin,try end(NetworkOutcome(result:.win(for:side.opponent),termination:.resignation)).map{.ended($0)})}
    /// At most one open offer. An offer meeting the other side's open one is agreement: both are current, since an
    /// offer lapses as soon as the player it was made to moves.
    private func offerDraw(_ side:NetworkSide,_ origin:Origin)throws {
        if let offer=openOffer {
            if offer.by==side {try refuse(origin,.offerPending)}else{answered(origin,try end(NetworkOutcome(result:.draw,termination:.agreement)).map{.ended($0)})}
            return
        }
        let offer=NetworkDrawOffer(offerID:.random(using:random),by:side);openOffer=offer
        answered(origin,.drawOffered(offer));try broadcast(.drawOffered(offer))
    }
    private func answerDraw(_ offerID:NetworkID?,accept:Bool,by side:NetworkSide,_ origin:Origin)throws {
        guard let offer=openOffer,offer.by != side,offerID.map({$0==offer.offerID}) ?? true else{try refuse(origin,.noOffer);return}
        if accept {answered(origin,try end(NetworkOutcome(result:.draw,termination:.agreement)).map{.ended($0)});return}
        openOffer=nil;answered(origin,.drawDeclined(offerID:offer.offerID));try broadcast(.drawDeclined(offerID:offer.offerID))
    }
    /// Checked on this game's own rules, never the practice session's (D5); the caller has checked the turn.
    private func claimDraw(_ origin:Origin)throws {
        guard let termination=try rules.networkClaimableDraw() else{try refuse(origin,.notClaimable);return}
        answered(origin,try end(NetworkOutcome(result:.draw,termination:termination)).map{.ended($0)})
    }
    /// `ended` is the only result. It advances the revision and kills the claim and the credential.
    @discardableResult private func end(_ outcome:NetworkOutcome)throws -> NetworkEnded? {
        guard phase != .ended else{return nil}
        clock?.pause(at:now)
        revision+=1;phase = .ended;self.outcome=outcome;openOffer=nil
        reservationDeadline=nil;holdDeadline=nil;holdExpired=false;seat?.valid=false
        let ended=NetworkEnded(outcome:outcome,revision:revision,clocks:clock?.clocks(at:now))
        try broadcast(.ended(ended))
        return ended
    }
    private func leave()throws {
        guard !leaving else{return}
        if phase == .running || phase == .disconnected {try resign(settings.hostSide,.host)}
        else if phase != .ended {phase = .ended;seat?.valid=false;reservationDeadline=nil}
        leaving=true;effects.append(.stopListening)
        for id in peers.keys.sorted() {
            guard let peer=peers[id] else{continue}
            if peer.role == .guest || peer.role == .spectator {peers[id]!.closeWhenFlushed=true;try pump(id)}else{try close(id,.hostLeft)}
        }
    }
    /// D6 pausing: settle (a flag still falls), then stop the clocks and hold the seat for 120 s.
    private func guestDropped()throws {
        seat?.connection=nil
        guard phase == .running else{return}
        try settleClock()
        guard phase == .running else{return}
        clock?.pause(at:now);phase = .disconnected;holdDeadline=now+NetworkLimits.holdDuration;holdExpired=false
        // Spectators count down locally between clock messages: tell them the clocks stopped.
        if let clock {try broadcast(.clock(clock.clocks(at:now)))}
    }
    // MARK: Outbound
    /// The guest first, then spectators: the guest is never queued behind them.
    private func admitted()->[NetworkConnectionID] {(seat?.connection.map{[$0]} ?? [])+spectators}
    private func broadcast(_ message:NetworkMessage)throws {try broadcast{_ in message}}
    private func broadcast(_ message:(NetworkConnectionID)->NetworkMessage)throws {
        let wasRunning=phase == .running
        for id in admitted() {try send(message(id),to:id)}
        // A guest closed as slow by this broadcast paused the clocks part way through it; spectators sent the message
        // afterwards were given running clocks, so the paused reading goes last.
        if wasRunning,phase == .disconnected,let clock {for watcher in spectators {try send(.clock(clock.clocks(at:now)),to:watcher)}}
    }
    private func send(_ message:NetworkMessage,to id:NetworkConnectionID)throws {
        guard let peer=peers[id] else{return}
        let data=try NetworkCodec.encode(message)
        if peer.role == .spectator,spectatorQueuedBytes+data.count>limits.spectatorQueuesBytes {try close(id,.slow);return}
        if peers[id]!.outbox.enqueue(data) == .overflow {try close(id,.slow);return}
        try pump(id)
    }
    /// `owed`: the refresh a stale flag was waiting to send, which leaving still sends; leaving starts no other.
    private func requestSnapshot(_ id:NetworkConnectionID,owed:Bool=false)throws {
        guard !leaving || owed,let peer=peers[id],!peer.outbox.snapshotPending else{return}
        let game=try publicGame(at:now)
        let capture:NetworkSnapshot
        // Shared while only the clock reading differs: clocks in a snapshot are cosmetic, and the next clock message
        // corrects them, so peers asking at one position hold one copy of the record between them.
        if let last=lastCapture,Self.samePosition(last.game,game) {capture=last.capture}
        else{
            capture=try NetworkSnapshot.capture(game,fen:fen,hashing:hashing,random:random)
            if snapshotBytes+capture.payload.count>limits.retainedCaptureBytes {
                if peer.role == .spectator {try close(id,.slow);return}
                // D7: the guest's snapshot is never refused; spectators still sending other records make room for it.
                for other in spectators where peers[other]?.outbox.pendingSnapshot != nil && snapshotBytes+capture.payload.count>limits.retainedCaptureBytes {try close(other,.slow)}
            }
            lastCapture=(game,capture)
        }
        // A capture of the current game is the refresh a stale flag was waiting to send.
        if peers[id]!.outbox.requestSnapshot(capture) == .queued {peers[id]!.snapshotStale=false}
        try pump(id)
    }
    /// The cached capture goes once no peer still has it to send: it holds a whole record.
    private func releaseIdleCapture(){
        guard let cached=lastCapture?.capture.snapshotID,!peers.values.contains(where:{$0.outbox.pendingSnapshot?.snapshotID==cached}) else{return}
        lastCapture=nil
    }
    /// Only the readings may differ: whether a clock runs, and whose, is part of the position a joiner is shown.
    private static func samePosition(_ a:NetworkPublicGame,_ b:NetworkPublicGame)->Bool {
        guard a.clocks?.active == b.clocks?.active else{return false}
        var a=a,b=b;a.clocks=nil;b.clocks=nil;return a==b
    }
    /// Spectators learn a guest's name only from a snapshot, as no other message names anyone: each gets a fresh one
    /// when the guest's name changes (a seat reserved, a reservation lapsed), after any snapshot already on its way.
    private func refreshSpectators()throws {
        for id in spectators {if peers[id]!.outbox.snapshotPending {peers[id]!.snapshotStale=true}else{try requestSnapshot(id)}}
    }
    private func pump(_ id:NetworkConnectionID)throws {
        guard peers[id] != nil else{return}
        // A refresh owed to a spectator is sent once its snapshot in flight finishes, even when leaving: it carries what
        // changed meanwhile (the guest's name, which `ended` does not), after whatever was queued, and the close follows.
        if peers[id]!.snapshotStale,!peers[id]!.outbox.snapshotPending {peers[id]!.snapshotStale=false;try requestSnapshot(id,owed:true);return}
        defer{releaseIdleCapture()}
        if let message=try peers[id]!.outbox.next() {
            // A snapshot part is only made when it is sent, so its bytes meet both budgets here (D7).
            let peer=peers[id]!
            if peer.outbox.bytes>peer.outbox.capacity || (peer.role == .spectator && spectatorQueuedBytes>limits.spectatorQueuesBytes) {try close(id,.slow);return}
            effects.append(.transmit(id,message))
        }
        if peers[id]!.closeWhenFlushed,peers[id]!.outbox.isIdle {try close(id,.hostLeft)}
    }
    /// Closes a connection the host gives up on. If it held the seat, the guest has dropped.
    private func close(_ id:NetworkConnectionID,_ reason:NetworkByeReason)throws {
        guard let peer=peers.removeValue(forKey:id) else{return}
        effects.append(.close(id,reason))
        if peer.role == .guest {try guestDropped()}
    }
    /// Closes a connection without counting it as the guest dropping: it was replaced, or its reservation lapsed.
    private func detach(_ id:NetworkConnectionID,_ reason:NetworkByeReason){
        guard peers.removeValue(forKey:id) != nil else{return}
        effects.append(.close(id,reason))
        if seat?.connection==id {seat?.connection=nil}
    }
}
