import CheckmateAssets
import CheckmateDomain
import Foundation
/// What the host's interface shows: a copy made on the network queue whenever an event changed it.
public struct NetworkHostStatus:Equatable {
    public let phase:NetworkHostPhase
    /// The public record: revision, names, PGN, clocks as they read at `at`, the open offer and the result.
    public let game:NetworkPublicGame
    public let fen:String,sideToMove:NetworkSide
    public let guestConnected:Bool
    public let spectators:[String]
    /// The hold passed with the guest away: offer Claim Win or Keep Waiting (D4).
    public let holdExpired:Bool
    public let at:NetworkInstant
}
/// Runs one hosted game on one scheduler, D6's single queue. It opens the listeners, drives `NetworkHost`, carries out
/// its effects in order, keeps its timers, and feeds transport events back. Each accepted connection gets a host
/// generation (`NetworkConnectionID`); once the runner lets a connection go, every later event for it is dropped, so a
/// late close can never pause or detach its replacement (D4).
///
/// Public methods may be called from any thread: they enqueue. Events are delivered on the scheduler's queue, and
/// `stopped` is always the last.
public final class NetworkHostRunner {
    public enum Event:Equatable {
        /// The listeners are ready at these endpoints.
        case listening([NetworkListenerRole:NetworkEndpoint])
        case status(NetworkHostStatus)
        /// The host's own command was refused; nothing changed.
        case refused(NetworkRejectReason)
        case stopped(Stop)
    }
    public enum Stop:Equatable {
        /// The host left: `ended` went to every peer able to take it, then everything closed (R3-2).
        case left
        /// The game could not go on — the listeners failed, or the rules did — and is interrupted, as after a crash.
        /// Peers were told `bye(hostLeft)`.
        case failed(String)
    }
    /// Read it only on the scheduler's queue.
    public let host:NetworkHost
    public let configuration:NetworkHostingConfiguration
    private let transport:any NetworkTransport,scheduler:any NetworkScheduler,leaveGrace:Duration,events:(Event)->Void
    /// Read it only on the scheduler's queue.
    public private(set) var hosting:(any NetworkHosting)?
    private var generations:[NetworkTransportConnection:NetworkConnectionID]=[:],handles:[NetworkConnectionID:NetworkTransportConnection]=[:]
    private var timers:[NetworkTimer:NetworkScheduledWork]=[:]
    private var started=false,leaving=false,leaveDeadline:NetworkScheduledWork?
    public private(set) var stop:Stop?
    private var lastStatus:StatusKey?
    /// The most transport buffer bytes held after any event (D7: under 1 MiB).
    public private(set) var peakBufferedBytes=0
    /// `leaveGrace` bounds Leave: a peer that stops reading cannot hold the host open.
    public init(host:NetworkHost,configuration:NetworkHostingConfiguration,transport:any NetworkTransport,scheduler:any NetworkScheduler,leaveGrace:Duration = .seconds(5),events:@escaping (Event)->Void){
        precondition(host.gameID==configuration.gameID,"The listeners must be keyed for the host's own game.")
        precondition(host.settings.allowSpectators==(configuration.watchCode != nil),"A watch listener opens exactly when spectators are allowed.")
        self.host=host;self.configuration=configuration;self.transport=transport;self.scheduler=scheduler;self.leaveGrace=leaveGrace;self.events=events
    }
    public func start(){scheduler.enqueue{[self] in begin()}}
    public func perform(_ action:NetworkHostAction){scheduler.enqueue{[self] in act(action)}}
    /// Stops the game as interrupted, as a crash would (D9: a host that sleeps cannot be resumed): peers are told
    /// `bye(hostLeft)` and the listeners close.
    public func interrupt(_ reason:String){scheduler.enqueue{[self] in fail(reason)}}
    /// D7's count, on the scheduler's queue: every peer's outbound queue as the host counts it (queued, held behind a
    /// snapshot, or handed over and not completed), the records held for snapshots still being sent, and the
    /// transport's own buffers. A send in flight is counted by both, so the figure errs high.
    public var bufferedBytes:Int {handles.keys.reduce(0){$0+(host.queuedBytes($1) ?? 0)}+host.snapshotBytes+(hosting?.bufferedBytes ?? 0)}
    /// Connections the runner holds, on the scheduler's queue.
    public var connectionCount:Int {handles.count}
    private func begin(){
        guard !started,stop==nil else{return};started=true
        do{hosting=try transport.startHosting(configuration){[weak self] event in self?.transportEvent(event)}}
        catch{finish(.failed(String(localized:"The game could not open its listeners: \(String(describing:error)).",bundle:.checkmate)));return}
        afterEvent()
    }
    private func act(_ action:NetworkHostAction){
        guard stop==nil else{return}
        if action == .leave,!leaving {
            leaving=true
            leaveDeadline=scheduler.schedule(at:scheduler.now+leaveGrace){[weak self] in self?.finish(.left)}
        }
        run{try host.perform(action,at:scheduler.now)}
    }
    private func transportEvent(_ event:NetworkHostingEvent){
        guard stop==nil else{return}
        let now=scheduler.now
        lastEvent=Self.summary(event)
        switch event {
        case .listening(let endpoints):events(.listening(endpoints))
        case .listenerFailed(let role,let detail):fail(String(localized:"The \(role.rawValue) listener failed: \(detail).",bundle:.checkmate))
        case .accepted(let handle,let role):
            guard generations[handle]==nil else{return fail(String(localized:"\(String(describing:handle)) was accepted twice.",bundle:.checkmate))}
            run{
                let accepted=try host.accept(role,at:now)
                generations[handle]=accepted.connection;handles[accepted.connection]=handle
                return accepted.effects
            }
        case .received(let handle,let data):guard let id=generations[handle] else{return};run{try host.receive(data,from:id,at:now)}
        case .sent(let handle):guard let id=generations[handle] else{return};run{try host.sendCompleted(id,at:now)}
        case .closed(let handle):
            guard let id=generations.removeValue(forKey:handle) else{return}
            handles[id]=nil
            run{try host.connectionClosed(id,at:now)}
        }
    }
    /// The latest transport event or timer, named for a failure message.
    private var lastEvent="none"
    static func summary(_ event:NetworkHostingEvent)->String {
        switch event {
        case .listening:return "listening"
        case .listenerFailed(let role,_):return "listenerFailed(\(role.rawValue))"
        case .accepted(let handle,let role):return "accepted(\(handle), \(role.rawValue))"
        case .received(let handle,let data):return "received(\(handle), \(data.count) bytes)"
        case .sent(let handle):return "sent(\(handle))"
        case .closed(let handle):return "closed(\(handle))"
        }
    }
    static func summary(_ effect:NetworkHostEffect)->String {
        switch effect {
        case .transmit(let id,let data):
            let type=(try? NetworkCodec.decode(data))?.type ?? "?"
            return "transmit(\(id), \(type))"
        case .close(let id,let reason):return "close(\(id), \(reason))"
        case .schedule(let timer,_):return "schedule(\(timer))"
        case .cancel(let timer):return "cancel(\(timer))"
        case .refused(let reason):return "refused(\(reason))"
        case .stopListening:return "stopListening"
        }
    }
    private func fire(_ timer:NetworkTimer){
        guard stop==nil else{return}
        lastEvent="timer(\(timer))"
        timers[timer]=nil
        run{try host.timerFired(timer,at:scheduler.now)}
    }
    /// After a rules failure the host's state is undefined (NetworkHost): close everything, the game is interrupted.
    private func run(_ body:()throws -> [NetworkHostEffect]){
        guard stop==nil else{return}
        let effects:[NetworkHostEffect]
        do{effects=try body()}catch{fail(String(localized:"The network game's rules failed: \(String(describing:error)).",bundle:.checkmate));return}
        execute(effects)
        afterEvent()
    }
    private func execute(_ effects:[NetworkHostEffect]){
        for effect in effects {
            guard stop==nil else{return}
            switch effect {
            case .transmit(let id,let data):
                guard let handle=handles[id] else{
                    // Name the whole batch and what the runner holds, so the log shows how the message outlived its link.
                    return fail(String(localized:"A message went to \(String(describing:id)), which the runner does not hold. Effects: \(String(describing:effects.map(Self.summary))); held: \(String(describing:handles.keys.map(\.description).sorted())); last event: \(lastEvent).",bundle:.checkmate))
                }
                hosting?.send(data,on:handle)
            case .close(let id,let reason):
                guard let handle=handles.removeValue(forKey:id) else{continue}
                generations[handle]=nil
                hosting?.close(handle,farewell:try? NetworkCodec.encode(.bye(reason)))
            case .schedule(let timer,let deadline):
                timers[timer]?.cancel()
                timers[timer]=scheduler.schedule(at:deadline){[weak self] in self?.fire(timer)}
            case .cancel(let timer):timers.removeValue(forKey:timer)?.cancel()
            case .refused(let reason):events(.refused(reason))
            case .stopListening:hosting?.stopListening()
            }
        }
    }
    private func afterEvent(){
        guard stop==nil else{return}
        peakBufferedBytes=max(peakBufferedBytes,bufferedBytes)
        publishStatus()
        if leaving,handles.isEmpty {finish(.left)}
    }
    private struct StatusKey:Equatable {
        let phase:NetworkHostPhase,revision:Int,offer:NetworkDrawOffer?,outcome:NetworkOutcome?,guestName:String?
        let guestConnected:Bool,spectators:[String],holdExpired:Bool
    }
    private func publishStatus(){
        let key=StatusKey(phase:host.phase,revision:host.revision,offer:host.openOffer,outcome:host.outcome,guestName:host.guestName,guestConnected:host.guestConnection != nil,spectators:host.spectatorNames,holdExpired:host.holdExpired)
        guard key != lastStatus else{return}
        lastStatus=key
        let now=scheduler.now
        do{events(.status(NetworkHostStatus(phase:host.phase,game:try host.publicGame(at:now),fen:host.fen,sideToMove:host.sideToMove,guestConnected:key.guestConnected,spectators:key.spectators,holdExpired:host.holdExpired,at:now)))}
        catch{fail(String(localized:"The network game's rules failed: \(String(describing:error)).",bundle:.checkmate))}
    }
    private func fail(_ reason:String){
        guard stop==nil else{return}
        let farewell=try? NetworkCodec.encode(.bye(.hostLeft))
        for handle in handles.values.sorted(by:{$0.number<$1.number}) {hosting?.close(handle,farewell:farewell)}
        handles=[:];generations=[:]
        finish(.failed(reason))
    }
    private func finish(_ stop:Stop){
        guard self.stop==nil else{return}
        self.stop=stop
        for work in timers.values {work.cancel()}
        timers=[:];leaveDeadline?.cancel()
        hosting?.shutdown();handles=[:];generations=[:]
        events(.stopped(stop))
    }
}
