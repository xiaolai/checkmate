import CheckmateApplication
import CheckmateDomain
import Foundation
@preconcurrency import Network
/// The network transport on Network.framework (D1, D3, D7): two TLS-PSK listeners per hosted game, advertised over
/// Bonjour when the build has a service type, and outbound connections to a chosen listener.
///
/// Frames are decoded on the transport's queue by `NetworkFrameDecoder` from the TLS byte stream rather than by an
/// `NWProtocolFramer`: D7 needs inbound partial-frame bytes counted in code and a partial-frame deadline on an
/// injectable clock, and a framer buffers inside Network.framework on its own protocol queue, out of reach of both.
/// The wire format, a 4-byte big-endian length then the JSON, is the same either way.
///
/// Every call must be made on the scheduler's queue, and every event arrives there.
public final class NWNetworkTransport:NetworkTransport {
    public struct Configuration:Equatable {
        /// The build's Bonjour service type (D12), or nil to advertise nothing.
        public var serviceType:String?
        /// Listeners bound to 127.0.0.1 only: routine tests and the loopback gate (D12).
        public var loopbackOnly:Bool
        public var limits:NetworkTransportLimits
        public init(serviceType:String?,loopbackOnly:Bool,limits:NetworkTransportLimits = .standard){self.serviceType=serviceType;self.loopbackOnly=loopbackOnly;self.limits=limits}
        public static func loopback(limits:NetworkTransportLimits = .standard)->Configuration {Configuration(serviceType:nil,loopbackOnly:true,limits:limits)}
    }
    public let scheduler:NetworkQueueScheduler,configuration:Configuration
    public init(scheduler:NetworkQueueScheduler,configuration:Configuration){
        precondition(configuration.serviceType.map{NetworkServiceType.all.contains($0) || $0.hasPrefix("_checkmate-")} ?? true,"Not a Checkmate service type.")
        self.scheduler=scheduler;self.configuration=configuration
    }
    public func startHosting(_ configuration:NetworkHostingConfiguration,events:@escaping (NetworkHostingEvent)->Void)throws -> any NetworkHosting {
        scheduler.assertOnQueue()
        let hosting=try NWNetworkHosting(configuration,transport:self.configuration,scheduler:scheduler,events:events)
        hosting.start()
        return hosting
    }
    public func connect(to endpoint:NetworkEndpoint,key:NetworkAccessKey,events:@escaping (NetworkLinkEvent)->Void)->any NetworkLink {
        scheduler.assertOnQueue()
        let link=NWNetworkLink(endpoint.value as? NWEndpoint,key:key,scheduler:scheduler,limits:configuration.limits,events:events)
        link.start()
        return link
    }
    /// A listener on this Mac, by port: what loopback tests and an injected discovery source connect to.
    public static func loopbackEndpoint(port:UInt16)->NetworkEndpoint {
        NetworkEndpoint(NWEndpoint.hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!),description:"127.0.0.1:\(port)")
    }
    /// The service type `build.sh` declared in `NSBonjourServices` (D11, D12), or nil when there is none to use.
    public static func bonjourServiceType(in bundle:Bundle = .main)->String? {
        guard let type=(bundle.object(forInfoDictionaryKey:"NSBonjourServices") as? [String])?.first,NetworkServiceType.all.contains(type) else{return nil}
        return type
    }
}
/// What the hosting saw, for tests and diagnosis: counts only, never a key or a code.
public struct NetworkHostingDiagnostics:Equatable {
    /// D7: dropped before TLS because the listener already had its handshakes in progress.
    public var refusedBusy=0
    /// D7: dropped before TLS because the remote address failed too often in the last minute.
    public var refusedAddress=0
    /// Handshakes that failed (a wrong key, a reset) or ran past the handshake deadline; each counts against its
    /// address.
    public var handshakeFailures=0,handshakeTimeouts=0
    /// Handshakes that completed at something other than TLS 1.2 with 0xCCAC, and were closed.
    public var insecure=0
    /// D7 inbound violations: a frame header declaring 0 or over 16 KiB, and a partial frame past its deadline.
    public var framingErrors=0,partialFrameTimeouts=0
    /// What the last handshake that completed negotiated, read from `sec_protocol_metadata`.
    public var lastNegotiated:NetworkTLS.Negotiated?
}
public final class NWNetworkHosting:NetworkHosting {
    public private(set) var diagnostics=NetworkHostingDiagnostics()
    private let configuration:NetworkHostingConfiguration,transport:NWNetworkTransport.Configuration
    private let scheduler:NetworkQueueScheduler,events:(NetworkHostingEvent)->Void
    private var listeners:[NetworkListenerRole:NWListener]=[:],ports:[NetworkListenerRole:UInt16]=[:]
    private var slots:[NetworkListenerRole:NetworkSlots]=[:]
    private var failures:NetworkHandshakeFailures
    /// `due`: when the handshake deadline passes. Readiness processed after it, behind a busy queue or a sleep, is too
    /// late, though its timer has not run yet.
    private struct Handshake {let role:NetworkListenerRole,address:String,connection:NWConnection,deadline:NetworkScheduledWork,due:NetworkInstant}
    private var handshakes:[UInt64:Handshake]=[:]
    private var connections:[UInt64:NWFramedConnection]=[:],closing:[UInt64:NWFramedConnection]=[:]
    private var nextNumber:UInt64=1,announced=false,stopped=false
    private var limits:NetworkTransportLimits {transport.limits}
    init(_ configuration:NetworkHostingConfiguration,transport:NWNetworkTransport.Configuration,scheduler:NetworkQueueScheduler,events:@escaping (NetworkHostingEvent)->Void)throws {
        self.configuration=configuration;self.transport=transport;self.scheduler=scheduler;self.events=events
        failures=NetworkHandshakeFailures(limit:transport.limits.failedHandshakesPerAddress,window:transport.limits.failedHandshakeWindow)
        for role in configuration.roles {
            let listener=try NWListener(using:NetworkTLS.parameters(configuration.key(role)!,loopback:transport.loopbackOnly))
            if let type=transport.serviceType {
                listener.service=NWListener.Service(name:configuration.serviceName(for:role),type:type,domain:nil,txtRecord:NWTXTRecord(configuration.txt(role)))
            }
            listeners[role]=listener;slots[role]=NetworkSlots(limit:transport.limits.handshakesPerListener)
        }
    }
    /// Released without `shutdown`: Network.framework objects outlive their owner unless cancelled.
    deinit {
        for listener in listeners.values {listener.cancel()}
        for handshake in handshakes.values {handshake.connection.cancel()}
        for framed in connections.values {framed.cancel()}
    }
    func start(){
        for (role,listener) in listeners {
            listener.stateUpdateHandler={[weak self] state in self?.listenerChanged(role,state)}
            listener.newConnectionHandler={[weak self] connection in
                guard let self else{return connection.cancel()}
                self.incoming(role,connection)
            }
            listener.start(queue:scheduler.queue)
        }
    }
    /// Handshakes in progress on one listener now.
    public func handshaking(_ role:NetworkListenerRole)->Int {slots[role]?.used ?? 0}
    public var openConnections:Int {connections.count}
    public var bufferedBytes:Int {connections.values.reduce(0){$0+$1.bufferedBytes}+closing.values.reduce(0){$0+$1.bufferedBytes}}
    private func listenerChanged(_ role:NetworkListenerRole,_ state:NWListener.State){
        guard !stopped,listeners[role] != nil else{return}
        switch state {
        case .ready:
            guard let port=listeners[role]?.port?.rawValue else{return}
            ports[role]=port
            guard !announced,ports.count==configuration.roles.count else{return}
            announced=true
            events(.listening(ports.mapValues(NWNetworkTransport.loopbackEndpoint)))
        case .failed(let error):events(.listenerFailed(role,"\(error)"))
        default:break
        }
    }
    /// D7 before TLS: an address over its failure limit, or a listener with every handshake slot taken, is dropped at
    /// once. Otherwise the handshake has the handshake deadline to complete.
    private func incoming(_ role:NetworkListenerRole,_ connection:NWConnection){
        let now=scheduler.now
        guard !stopped,listeners[role] != nil else{return connection.cancel()}
        let address=Self.address(connection.endpoint)
        guard failures.allows(address,at:now) else{diagnostics.refusedAddress+=1;return connection.cancel()}
        guard slots[role]!.acquire() else{diagnostics.refusedBusy+=1;return connection.cancel()}
        let number=nextNumber;nextNumber+=1
        let deadline=scheduler.schedule(at:now+limits.handshakeDeadline){[weak self] in self?.handshakeFailed(number,timedOut:true)}
        handshakes[number]=Handshake(role:role,address:address,connection:connection,deadline:deadline,due:now+limits.handshakeDeadline)
        connection.stateUpdateHandler={[weak self] state in self?.handshakeChanged(number,state)}
        connection.start(queue:scheduler.queue)
    }
    private func handshakeChanged(_ number:UInt64,_ state:NWConnection.State){
        guard let handshake=handshakes[number] else{return}
        switch state {
        case .ready:
            guard scheduler.now<handshake.due else{return handshakeFailed(number,timedOut:true)}
            endHandshake(number)
            let negotiated=NetworkTLS.negotiated(handshake.connection)
            diagnostics.lastNegotiated=negotiated
            guard negotiated?.pinned==true else{
                diagnostics.insecure+=1;failures.recordFailure(from:handshake.address,at:scheduler.now)
                handshake.connection.stateUpdateHandler=nil;return handshake.connection.cancel()
            }
            let handle=NetworkTransportConnection(number:number)
            let framed=NWFramedConnection(handshake.connection,scheduler:scheduler,limits:limits)
            framed.onFrame={[weak self] data in self?.deliver(.received(handle,data))}
            framed.onSent={[weak self] in self?.deliver(.sent(handle))}
            framed.onClosed={[weak self] violation in self?.ended(number,violation)}
            connections[number]=framed
            framed.start()
            deliver(.accepted(handle,handshake.role))
        case .failed,.waiting,.cancelled:handshakeFailed(number,timedOut:false)
        case .setup,.preparing:break
        @unknown default:break
        }
    }
    private func endHandshake(_ number:UInt64){
        guard let handshake=handshakes.removeValue(forKey:number) else{return}
        handshake.deadline.cancel();slots[handshake.role]!.release()
    }
    private func handshakeFailed(_ number:UInt64,timedOut:Bool){
        guard let handshake=handshakes[number] else{return}
        endHandshake(number)
        failures.recordFailure(from:handshake.address,at:scheduler.now)
        if timedOut {diagnostics.handshakeTimeouts+=1}else{diagnostics.handshakeFailures+=1}
        handshake.connection.stateUpdateHandler=nil;handshake.connection.cancel()
    }
    private func ended(_ number:UInt64,_ violation:NetworkFramedViolation?){
        guard connections.removeValue(forKey:number) != nil else{return}
        switch violation {case .framing?:diagnostics.framingErrors+=1;case .partialFrameTimeout?:diagnostics.partialFrameTimeouts+=1;case nil:break}
        deliver(.closed(NetworkTransportConnection(number:number)))
    }
    private func deliver(_ event:NetworkHostingEvent){if !stopped {events(event)}}
    public func send(_ message:Data,on connection:NetworkTransportConnection){
        scheduler.assertOnQueue()
        connections[connection.number]?.send(message)
    }
    public func close(_ connection:NetworkTransportConnection,farewell:Data?){
        scheduler.assertOnQueue()
        guard let framed=connections.removeValue(forKey:connection.number) else{return}
        closing[connection.number]=framed
        framed.close(farewell:farewell){[weak self] in self?.closing[connection.number]=nil}
    }
    public func stopListening(){
        scheduler.assertOnQueue()
        for listener in listeners.values {listener.stateUpdateHandler=nil;listener.newConnectionHandler=nil;listener.cancel()}
        listeners=[:]
        for (number,handshake) in handshakes {endHandshake(number);handshake.connection.stateUpdateHandler=nil;handshake.connection.cancel()}
    }
    public func shutdown(){
        scheduler.assertOnQueue()
        guard !stopped else{return}
        stopListening()
        for framed in connections.values {framed.cancel()}
        connections=[:];stopped=true
    }
    public var isListening:Bool {!listeners.isEmpty}
    /// The remote host, without its port: what D7's failure limit counts.
    static func address(_ endpoint:NWEndpoint)->String {if case .hostPort(let host,_)=endpoint {return "\(host)"};return "\(endpoint)"}
}
/// An outbound connection to one listener: ready within the connect deadline, or closed with why.
public final class NWNetworkLink:NetworkLink {
    /// What TLS negotiated, read from `sec_protocol_metadata` once ready.
    public private(set) var negotiated:NetworkTLS.Negotiated?
    private let connection:NWConnection?,scheduler:NetworkQueueScheduler,limits:NetworkTransportLimits,events:(NetworkLinkEvent)->Void
    private var framed:NWFramedConnection?,deadline:NetworkScheduledWork?
    /// When the connect deadline passes; nil while denial suspends it.
    private var due:NetworkInstant?
    private var open=true,denied=false
    init(_ endpoint:NWEndpoint?,key:NetworkAccessKey,scheduler:NetworkQueueScheduler,limits:NetworkTransportLimits,events:@escaping (NetworkLinkEvent)->Void){
        connection=endpoint.map{NWConnection(to:$0,using:NetworkTLS.parameters(key,loopback:false))}
        self.scheduler=scheduler;self.limits=limits;self.events=events
    }
    /// Released without `close`: Network.framework objects outlive their owner unless cancelled.
    deinit {if open {framed?.cancel();connection?.cancel()}}
    func start(){
        guard let connection else{
            // Not an endpoint this transport made: nothing to connect to.
            scheduler.enqueue{[weak self] in self?.fail(.unreachable)};return
        }
        connection.stateUpdateHandler={[weak self] state in self?.changed(state)}
        armDeadline()
        connection.start(queue:scheduler.queue)
    }
    public var bufferedBytes:Int {framed?.bufferedBytes ?? 0}
    private func armDeadline(){
        deadline?.cancel();due=scheduler.now+limits.connectDeadline
        deadline=scheduler.schedule(at:due!){[weak self] in self?.fail(.timedOut)}
    }
    private func changed(_ state:NWConnection.State){
        guard open,framed==nil,let connection else{return}
        switch state {
        case .preparing:if denied {denied=false;armDeadline()}
        case .waiting(let error):
            // Denial waits for access (D11); a TLS error while waiting is fatal, and so is any other refusal.
            guard NetworkTLS.deniesLocalNetwork(error,path:connection.currentPath) else{return fail(NetworkTLS.failure(error))}
            guard !denied else{return}
            denied=true;deadline?.cancel();due=nil;events(.denied)
        case .ready:
            // Ready after the deadline, before its timer ran, is still too late. While local network access is denied
            // no deadline runs (D11), so `due` is nil then.
            if let due,scheduler.now>=due {return fail(.timedOut)}
            deadline?.cancel()
            negotiated=NetworkTLS.negotiated(connection)
            guard negotiated?.pinned==true else{return fail(.insecure)}
            let framed=NWFramedConnection(connection,scheduler:scheduler,limits:limits)
            framed.onFrame={[weak self] data in self?.deliver(.received(data))}
            framed.onSent={[weak self] in self?.deliver(.sent)}
            framed.onClosed={[weak self] _ in self?.deliver(.closed(.lost))}
            self.framed=framed
            framed.start()
            events(.ready)
        case .failed(let error):fail(NetworkTLS.failure(error))
        case .cancelled:fail(.unreachable)
        case .setup:break
        @unknown default:break
        }
    }
    private func deliver(_ event:NetworkLinkEvent){
        guard open else{return}
        if case .closed=event {open=false}
        events(event)
    }
    private func fail(_ failure:NetworkLinkFailure){
        guard open,framed==nil else{return}
        open=false;deadline?.cancel()
        connection?.stateUpdateHandler=nil;connection?.cancel()
        events(.closed(failure))
    }
    public func send(_ message:Data){scheduler.assertOnQueue();if open {framed?.send(message)}}
    public func close(farewell:Data?){
        scheduler.assertOnQueue()
        guard open else{return}
        open=false;deadline?.cancel()
        if let framed {framed.close(farewell:farewell){}}else{connection?.stateUpdateHandler=nil;connection?.cancel()}
    }
}
enum NetworkFramedViolation {case framing,partialFrameTimeout}
/// One ready TLS connection carrying length-prefixed frames (D5) under D7's inbound bounds: a declared length of 0 or
/// over 16 KiB closes it from the header alone, at most one partial frame is buffered (so at most 16 KiB plus a
/// header, counted), and a partial frame must complete within the deadline. One send at a time.
final class NWFramedConnection {
    private let connection:NWConnection,scheduler:NetworkQueueScheduler,limits:NetworkTransportLimits
    private var decoder=NetworkFrameDecoder(),partialWork:NetworkScheduledWork?
    private var open=true,sending=false,inFlightBytes=0,farewellBytes=0
    var onFrame:(Data)->Void={_ in},onSent:()->Void={},onClosed:(NetworkFramedViolation?)->Void={_ in}
    /// One read takes at most a whole frame, so the decoder never holds more than one partial frame after it.
    static let readSize=NetworkFraming.headerBytes+NetworkLimits.maximumMessageBytes
    init(_ connection:NWConnection,scheduler:NetworkQueueScheduler,limits:NetworkTransportLimits){self.connection=connection;self.scheduler=scheduler;self.limits=limits}
    /// The partial frame held, plus the frame (or farewell) handed to the system and not yet taken.
    var bufferedBytes:Int {decoder.bufferedBytes+inFlightBytes+farewellBytes}
    func start(){
        connection.stateUpdateHandler={[weak self] state in
            switch state {case .failed,.cancelled,.waiting:self?.terminate(nil);default:break}
        }
        receive()
    }
    private func receive(){
        connection.receive(minimumIncompleteLength:1,maximumLength:Self.readSize){[weak self] data,_,isComplete,error in
            guard let self,self.open else{return}
            if let data,!data.isEmpty {
                let frames:[Data]
                // Bytes that would complete a frame already past its deadline do not rescue it: the overdue timer may
                // simply not have run yet.
                if let since=self.decoder.partialSince,self.scheduler.now>=since+self.limits.partialFrameDeadline {return self.terminate(.partialFrameTimeout)}
                do{frames=try self.decoder.append(data,at:self.scheduler.now)}catch{return self.terminate(.framing)}
                for frame in frames {
                    self.onFrame(frame)
                    guard self.open else{return}
                }
                self.armPartialDeadline()
            }
            if isComplete || error != nil {return self.terminate(nil)}
            self.receive()
        }
    }
    private func armPartialDeadline(){
        partialWork?.cancel();partialWork=nil
        guard let since=decoder.partialSince else{return}
        partialWork=scheduler.schedule(at:since+limits.partialFrameDeadline){[weak self] in
            guard let self,self.open,let since=self.decoder.partialSince,self.scheduler.now>=since+self.limits.partialFrameDeadline else{return}
            self.terminate(.partialFrameTimeout)
        }
    }
    func send(_ message:Data){
        guard open else{return}
        precondition(!sending,"One send at a time per connection.")
        guard let frame=try? NetworkFraming.frame(message) else{preconditionFailure("A message of \(message.count) bytes cannot be framed; the codec refuses it first.")}
        sending=true;inFlightBytes=frame.count
        connection.send(content:frame,completion:.contentProcessed{[weak self] error in
            guard let self else{return}
            self.sending=false;self.inFlightBytes=0
            guard self.open else{return}
            if error != nil {return self.terminate(nil)}
            self.onSent()
        })
    }
    /// Closes locally: `farewell` goes out if the connection takes it within the farewell deadline, then it is
    /// cancelled. No callback follows except `done`, once.
    func close(farewell:Data?,done:@escaping ()->Void){
        guard open else{return done()}
        open=false;partialWork?.cancel();decoder=NetworkFrameDecoder()
        connection.stateUpdateHandler=nil
        guard let farewell,let frame=try? NetworkFraming.frame(farewell) else{connection.cancel();return done()}
        farewellBytes=frame.count
        let connection=self.connection,once=NetworkScheduledWork()
        let finish:()->Void={[weak self] in
            // `once` is spent by whichever comes first: the send being taken, or the deadline.
            guard !once.cancelled else{return}
            once.cancel();connection.cancel();self?.farewellBytes=0;done()
        }
        let deadline=scheduler.schedule(at:scheduler.now+limits.farewellDeadline,finish)
        connection.send(content:frame,completion:.contentProcessed{_ in deadline.cancel();finish()})
    }
    /// Cancels at once, with no farewell and no callback.
    func cancel(){
        guard open else{return}
        open=false;partialWork?.cancel();decoder=NetworkFrameDecoder()
        connection.stateUpdateHandler=nil;connection.cancel()
    }
    /// The connection ended by itself, or broke a bound: cancel it and report.
    private func terminate(_ violation:NetworkFramedViolation?){
        guard open else{return}
        cancel()
        onClosed(violation)
    }
}
