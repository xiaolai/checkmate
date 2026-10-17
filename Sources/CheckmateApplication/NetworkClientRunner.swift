import CheckmateDomain
import Foundation
/// Why a guest's or spectator's game stopped. Every one is final: nothing reconnects after it.
public enum NetworkClientStop:Equatable {
    /// This Mac left.
    case left
    /// The game ended (`ended` arrived) and the connection then closed.
    case finished
    /// The host closed the connection for good: seat taken, bad credential, not allowed, full, game over, host left
    /// before any result (interrupted)…
    case closedByHost(NetworkByeReason)
    /// No connection: not ready within the deadline even after one fresh retry, refused again after brief retries, or
    /// lost and not regained in the reconnect window. D11: "Couldn't reach Ana's game", without a guessed cause.
    case couldNotReach
    /// TLS failed on the first connection: most likely the code is wrong.
    case handshakeFailed
    /// The host negotiated something other than TLS 1.2 with suite 0xCCAC.
    case insecure
    /// The host broke the protocol, or this Mac's own rules failed; the text is readable.
    case failed(String)
}
/// What a guest's or spectator's interface shows: a copy made on the network queue whenever something changed.
public struct NetworkClientStatus:Equatable {
    public enum Link:Equatable {
        /// Connecting, or connected and not yet holding the host's snapshot.
        case connecting
        /// macOS denied local-network access: show the permission help (D11). The connection goes on by itself once
        /// access is granted.
        case denied
        /// Admitted, with a verified snapshot installed on this connection: commands are accepted.
        case live
        /// The connection dropped after the game was live; the runner is reconnecting.
        case reconnecting
        case stopped(NetworkClientStop)
    }
    public let link:Link
    /// The record the receiver holds now (clocks as they read at `at`); nil before the first snapshot.
    public let game:NetworkPublicGame?
    public let fen:String?
    /// The guest's side; nil for a spectator.
    public let side:NetworkSide?
    public let pendingMove:NetworkPendingMove?
    public let at:NetworkInstant
}
/// How a dropped connection is regained: fresh connections after these delays (the last repeats), for as long as the
/// window since the drop lasts. The standard window is D4's hold, so a guest stops trying when the seat stops being held
/// by default.
public struct NetworkReconnectPolicy:Equatable {
    public var delays:[Duration],window:Duration
    public init(delays:[Duration],window:Duration){self.delays=delays;self.window=window}
    public static let standard=NetworkReconnectPolicy(delays:[.zero,.seconds(1),.seconds(2),.seconds(5)],window:NetworkLimits.holdDuration)
}
/// Runs one guest's or spectator's side of a network game on one scheduler. It connects to the chosen listener, sends
/// the receiver's opening (`resume` when a credential is held, else `hello`, R4-4), feeds every frame to the
/// `NetworkReceiver`, sends what it answers one message at a time, and reconnects after a drop. Each connection attempt
/// is a generation; an event from an earlier one is dropped (D4).
///
/// Commands are accepted only while live: admitted, with this connection's snapshot installed. Public methods may be
/// called from any thread: they enqueue. Events arrive on the scheduler's queue.
public final class NetworkClientRunner {
    public enum Event:Equatable {
        /// What the receiver reports, for announcements (moves, offers, the result, the host's bye).
        case receiver(NetworkReceiverEvent)
        case status(NetworkClientStatus)
    }
    /// Read it only on the scheduler's queue.
    public let receiver:NetworkReceiver
    private let transport:any NetworkTransport,scheduler:any NetworkScheduler,endpoint:NetworkEndpoint,key:NetworkAccessKey
    private let reconnect:NetworkReconnectPolicy?,events:(Event)->Void
    /// The host pings every 2 s; this long without a frame means it is gone (asleep, crashed, off the network).
    public static let hostSilence=NetworkLimits.pongDeadline
    /// Bye reasons after which a fresh connection may succeed. Every other reason is final.
    public static let retryable:Set<NetworkByeReason>=[.timeout,.slow,.busy,.badSnapshot]
    /// While joining, a refusal before TLS or `bye(busy)` usually means the host's handshake or admission slots were
    /// full for a moment (D7): try again after these delays before giving up.
    public static let joinRetryDelays:[Duration]=[.milliseconds(500),.seconds(1),.seconds(2)]
    public static let leaveGrace=Duration.seconds(2)
    private var link:(any NetworkLink)?,generation=0
    private var ready=false,admitted=false,denied=false,everAdmitted=false
    /// When this side last lost a live game: the host paused the clocks then (D6), so they read as of that moment
    /// until a fresh snapshot brings the host's own reading.
    private var pausedAt:NetworkInstant?
    private var timedOutRetried=false,joinRetries=0,lostAt:NetworkInstant?,retries=0,suspended=false
    private var retryWork:NetworkScheduledWork?,silenceWork:NetworkScheduledWork?,leaveWork:NetworkScheduledWork?
    /// The end of the reconnect window, absolute: an attempt still running then is closed, whatever state it is in.
    private var expiryWork:NetworkScheduledWork?
    private var lastHeard=NetworkInstant.origin
    private var outbox:[Data]=[],inFlight:Data?,leaving=false
    public private(set) var stop:NetworkClientStop?
    private var installs=0,lastStatus:StatusKey?
    public init(receiver:NetworkReceiver,endpoint:NetworkEndpoint,key:NetworkAccessKey,transport:any NetworkTransport,scheduler:any NetworkScheduler,reconnect:NetworkReconnectPolicy? = .standard,events:@escaping (Event)->Void){
        precondition(receiver.gameID==key.gameID,"The key must be for the receiver's game.")
        switch receiver.role {case .guest:precondition(key.role == .seat,"A guest connects to the seat listener.");case .spectator:precondition(key.role == .watch,"A spectator connects to the watch listener.")}
        self.receiver=receiver;self.endpoint=endpoint;self.key=key;self.transport=transport;self.scheduler=scheduler;self.reconnect=reconnect;self.events=events
    }
    public func start(){scheduler.enqueue{[self] in guard generation==0,stop==nil else{return};connect()}}
    /// Ignored unless live, while a move is pending, or when it is not this guest's turn (D2).
    /// `assisted`: a hint was shown to this player during this turn (assistance plan A7).
    public func submitMove(uci:String,assisted:Bool=false){command{try $0.submitMove(uci:uci,assisted:assisted)}}
    public func resign(){command{$0.resign()}}
    public func offerDraw(){command{$0.offerDraw()}}
    public func answerDraw(accept:Bool){command{$0.answerDraw(accept:accept)}}
    public func claimDraw(){command{$0.claimDraw()}}
    /// Leaves: sends what is queued (with a resignation first when `resigning`, D9's "Leave the game? It counts as a
    /// resignation."), then `bye(leaving)`, within `leaveGrace`.
    public func leave(resigning:Bool=false){scheduler.enqueue{[self] in depart(resigning:resigning)}}
    /// This Mac is going to sleep (D9): the connection closes now with `bye(leaving)`, so the host pauses the clocks at
    /// once instead of at its pong deadline. Nothing reconnects until `wake()`, so the seat cannot come back, and its
    /// clock with it, in the moments before the Mac actually sleeps.
    public func suspend(){scheduler.enqueue{[self] in
        guard stop==nil,!suspended else{return}
        suspended=true;retryWork?.cancel();retryWork=nil;expiryWork?.cancel();expiryWork=nil
        if link != nil {abandon(farewell:.leaving);dropped(.lost)}
        publishStatus()
    }}
    /// The Mac woke: reconnect now, with the reconnect window counted from here.
    public func wake(){scheduler.enqueue{[self] in
        guard stop==nil,suspended else{return}
        suspended=false;lostAt=nil;retries=0
        if link==nil {connect()}
    }}
    /// Bytes this side holds, on the scheduler's queue: messages queued or in flight, plus the link's buffers.
    public var bufferedBytes:Int {outbox.reduce(inFlight?.count ?? 0){$0+$1.count}+(link?.bufferedBytes ?? 0)}
    // MARK: Connection
    private func connect(){
        generation+=1
        let current=generation
        ready=false;admitted=false;denied=false;outbox=[];inFlight=nil
        link=transport.connect(to:endpoint,key:key){[weak self] event in self?.linkEvent(event,generation:current)}
        publishStatus()
    }
    private func linkEvent(_ event:NetworkLinkEvent,generation from:Int){
        guard stop==nil,from==generation,link != nil else{return}
        let now=scheduler.now
        switch event {
        case .denied:denied=true
        case .ready:
            denied=false;ready=true;lastHeard=now;armSilence()
            send(receiver.opening())
        case .received(let data):lastHeard=now;inbound(data,at:now)
        case .sent:inFlight=nil;pump()
        case .closed(let failure):link=nil;dropped(failure)
        }
        publishStatus()
    }
    private func inbound(_ data:Data,at now:NetworkInstant){
        let message:NetworkMessage
        do{message=try NetworkCodec.decode(data)}
        catch let error as NetworkCodecError{
            abandon(farewell:error.byeReason)
            // D5: another major version is a readable reason, not a failure ("… uses a different version").
            if case .protocolMismatch=error{return finish(.closedByHost(.protocolVersion))}
            return finish(.failed(error.description))
        }
        catch{abandon(farewell:.malformed);return finish(.failed("A malformed network message."))}
        let output:NetworkReceiverOutput
        do{output=try receiver.receive(message:message,at:now)}
        catch{abandon(farewell:.leaving);return finish(.failed("This Mac's chess rules failed: \(error)."))}
        // A snapshot landing as the window ends, before its timer runs, is too late as well.
        if output.events.contains(where:{if case .installed=$0 {return true};return false}),let since=lostAt,let policy=reconnect,now-since>=policy.window {abandon(farewell:.leaving);return finish(.couldNotReach)}
        for event in output.events {
            if case .installed=event {admitted=true;everAdmitted=true;lostAt=nil;pausedAt=nil;retries=0;installs+=1;expiryWork?.cancel();expiryWork=nil}
            events(.receiver(event))
        }
        if let reason=output.close {
            abandon(farewell:reason)
            return reason == .badSnapshot ? dropped(.lost):finish(.failed("The host sent a message that breaks the protocol (\(reason.rawValue))."))
        }
        if case .bye(let reason)=message {
            abandon(farewell:nil)
            if receiver.outcome != nil {return finish(.finished)}
            return Self.retryable.contains(reason) ? dropped(.lost):finish(.closedByHost(reason))
        }
        for reply in output.send {send(reply)}
        if case .clock=message {publishStatus(force:true)}
    }
    /// The connection is gone, closed by either side. Decide: stop, retry the join, or reconnect within the window.
    private func dropped(_ failure:NetworkLinkFailure){
        abandon(farewell:nil)
        if receiver.outcome != nil {return finish(.finished)}
        if leaving {return finish(.left)}
        if failure == .insecure {return finish(.insecure)}
        // Asleep, or about to be: nothing retries until `wake()`, which connects afresh.
        if suspended {return}
        // Nothing to come back to yet: no snapshot installed and no seat held.
        guard everAdmitted || receiver.credential != nil else{return rejoin(after:failure)}
        guard let policy=reconnect else{return finish(.couldNotReach)}
        let now=scheduler.now
        let since=lostAt ?? now;lostAt=since
        guard now-since<policy.window else{return finish(.couldNotReach)}
        if expiryWork==nil {
            expiryWork=scheduler.schedule(at:since+policy.window){[weak self] in
                guard let self,self.stop==nil,!self.admitted,!self.suspended else{return}
                self.finish(.couldNotReach)
            }
        }
        let delay=policy.delays.isEmpty ? Duration.zero:policy.delays[min(retries,policy.delays.count-1)]
        retries+=1
        retryWork=scheduler.schedule(at:now+delay){[weak self] in
            guard let self,self.stop==nil,self.link==nil,!self.suspended else{return}
            // The window is absolute: a retry falling due after it gives up rather than starting late.
            if let since=self.lostAt,self.scheduler.now-since>=policy.window {self.finish(.couldNotReach);return}
            self.connect()
        }
    }
    /// Joining failed. A deadline gets one fresh retry (spike finding (c)). A TLS failure is final: most likely the code
    /// is wrong, and each retry would count against this Mac's address (D7). A refusal before TLS, or `bye(busy)`, gets
    /// brief retries, since the host's slots may only have been full for a moment.
    private func rejoin(after failure:NetworkLinkFailure){
        switch failure {
        case .handshakeFailed:return finish(.handshakeFailed)
        case .insecure:return finish(.insecure)
        case .timedOut where !timedOutRetried:timedOutRetried=true;return connect()
        case .timedOut:return finish(.couldNotReach)
        case .unreachable,.lost:
            guard joinRetries<Self.joinRetryDelays.count else{return finish(.couldNotReach)}
            let delay=Self.joinRetryDelays[joinRetries];joinRetries+=1
            retryWork=scheduler.schedule(at:scheduler.now+delay){[weak self] in guard let self,self.stop==nil,self.link==nil else{return};self.connect()}
        }
    }
    /// Closes the current connection locally (no event follows) and forgets everything tied to it.
    private func abandon(farewell reason:NetworkByeReason?){
        silenceWork?.cancel();silenceWork=nil
        if let link {link.close(farewell:reason.flatMap{try? NetworkCodec.encode(.bye($0))})}
        if admitted {pausedAt=scheduler.now}
        link=nil;ready=false;admitted=false;outbox=[];inFlight=nil
        receiver.connectionLost()
    }
    private func armSilence(){
        silenceWork?.cancel()
        silenceWork=scheduler.schedule(at:lastHeard+Self.hostSilence){[weak self] in self?.checkSilence()}
    }
    private func checkSilence(){
        guard stop==nil,link != nil,ready else{return}
        if scheduler.now-lastHeard<Self.hostSilence {return armSilence()}
        abandon(farewell:.timeout);dropped(.lost);publishStatus()
    }
    // MARK: Sending
    private func command(_ make:@escaping (NetworkReceiver)throws -> NetworkMessage?){
        scheduler.enqueue{[self] in
            guard stop==nil,admitted,!leaving else{return}
            do{if let message=try make(receiver) {send(message)}}
            catch{abandon(farewell:.leaving);finish(.failed("This Mac's chess rules failed: \(error)."))}
            publishStatus()
        }
    }
    /// One message at a time on the connection; the rest wait here, bounded like a host's peer queue.
    private func send(_ message:NetworkMessage){
        guard link != nil,ready else{return}
        let data:Data
        do{data=try NetworkCodec.encode(message)}catch{abandon(farewell:.leaving);return finish(.failed("A message could not be sent: \(error)."))}
        guard bufferedBytes+data.count<=NetworkLimits.peerQueueBytes else{abandon(farewell:.slow);return dropped(.lost)}
        outbox.append(data);pump()
    }
    private func pump(){
        guard let link,inFlight==nil else{return}
        guard !outbox.isEmpty else{
            if leaving {abandon(farewell:.leaving);finish(.left)}
            return
        }
        let data=outbox.removeFirst();inFlight=data;link.send(data)
    }
    private func depart(resigning:Bool){
        guard stop==nil,!leaving else{return}
        retryWork?.cancel()
        guard link != nil,ready else{abandon(farewell:nil);return finish(.left)}
        if resigning,admitted,let resignation=receiver.resign() {send(resignation)}
        leaving=true
        leaveWork=scheduler.schedule(at:scheduler.now+Self.leaveGrace){[weak self] in guard let self,self.stop==nil else{return};self.abandon(farewell:.leaving);self.finish(.left)}
        pump()
    }
    private func finish(_ stop:NetworkClientStop){
        guard self.stop==nil else{return}
        abandon(farewell:nil)
        self.stop=stop
        retryWork?.cancel();leaveWork?.cancel();expiryWork?.cancel()
        publishStatus()
    }
    // MARK: Status
    private struct StatusKey:Equatable {
        let link:NetworkClientStatus.Link,revision:Int?,fen:String?,offer:NetworkDrawOffer?,outcome:NetworkOutcome?
        let pending:NetworkPendingMove?,installs:Int
    }
    private var linkState:NetworkClientStatus.Link {
        if let stop {return .stopped(stop)}
        if admitted {return .live}
        if denied {return .denied}
        return everAdmitted ? .reconnecting:.connecting
    }
    private func publishStatus(force:Bool=false){
        let key=StatusKey(link:linkState,revision:receiver.revision,fen:receiver.fen,offer:receiver.openOffer,outcome:receiver.outcome,pending:receiver.pendingMove,installs:installs)
        guard force || key != lastStatus else{return}
        lastStatus=key
        let now=scheduler.now
        var game:NetworkPublicGame?
        do{
            game=try receiver.publicGame(at:admitted ? now:pausedAt ?? now)
            if !admitted,pausedAt != nil {game?.clocks?.active=nil}
        }
        catch{
            // A rules failure stops the game; the stopped status still goes out, without a record.
            guard stop != nil else{abandon(farewell:.leaving);return finish(.failed("This Mac's chess rules failed: \(error)."))}
            game=nil
        }
        events(.status(NetworkClientStatus(link:key.link,game:game,fen:key.fen,side:receiver.side,pendingMove:key.pending,at:now)))
    }
}
