import CheckmateDomain
import Foundation
/// The transport for tests (D13): listeners and connections in memory on one scheduler, under the contracts of
/// `NetworkTransport` — events only from the scheduler and never during a call, one send at a time per connection, no
/// event after a local close, connection numbers never reused, and the connect deadline. A key is accepted when it
/// equals the listener's (game, role and code), as the real PSK handshake accepts only the same derived key.
///
/// Test controls model the failures a real link has: a cut (either side may not hear of it), a peer that stops reading,
/// a message lost on the way, connections macOS refuses silently, and an event a racing transport delivers late.
public final class NetworkMemoryTransport:NetworkTransport {
    public let scheduler:any NetworkScheduler
    public var limits:NetworkTransportLimits
    /// Connections never become ready, as when macOS refuses one silently: each fails at the connect deadline.
    public var stallConnects=false
    /// Messages from a link to the host lost on the way; the sender still sees `sent`, as with a failing link.
    public var losesToHost:(Data)->Bool={_ in false}
    public private(set) var connectAttempts=0
    public private(set) var hostings:[NetworkMemoryHosting]=[]
    public private(set) var links:[NetworkMemoryLink]=[]
    /// Every message that crossed a connection, in delivery order.
    public struct Delivery:Equatable {public let connection:NetworkTransportConnection,toHost:Bool,message:Data}
    public private(set) var trace:[Delivery]=[]
    fileprivate func record(_ connection:NetworkTransportConnection,toHost:Bool,_ message:Data){trace.append(Delivery(connection:connection,toHost:toHost,message:message))}
    private var listeners:[String:(hosting:NetworkMemoryHosting,role:NetworkListenerRole)]=[:]
    private var nextConnection:UInt64=1,nextHosting=1
    public init(scheduler:any NetworkScheduler,limits:NetworkTransportLimits = .standard){self.scheduler=scheduler;self.limits=limits}
    /// Listeners open now, across every hosting.
    public var openListeners:Int {listeners.count}
    public func startHosting(_ configuration:NetworkHostingConfiguration,events:@escaping (NetworkHostingEvent)->Void)throws -> any NetworkHosting {
        let hosting=NetworkMemoryHosting(transport:self,configuration:configuration,events:events);hostings.append(hosting)
        var endpoints:[NetworkListenerRole:NetworkEndpoint]=[:]
        for role in configuration.roles {
            let name="memory-\(nextHosting)-\(role.rawValue)"
            listeners[name]=(hosting,role);endpoints[role]=NetworkEndpoint(name,description:name)
        }
        nextHosting+=1
        scheduler.enqueue{[weak hosting] in hosting?.deliver(.listening(endpoints))}
        return hosting
    }
    public func connect(to endpoint:NetworkEndpoint,key:NetworkAccessKey,events:@escaping (NetworkLinkEvent)->Void)->any NetworkLink {
        connectAttempts+=1
        let link=NetworkMemoryLink(transport:self,key:key,events:events);links.append(link)
        // As Network.framework does under a local-network denial (D11): the connection waits, with no deadline running,
        // until access is granted.
        if deniesAccess {denied.append((link,endpoint,key));scheduler.enqueue{[weak link] in link?.deliver(.denied)};return link}
        link.deadline=scheduler.schedule(at:scheduler.now+limits.connectDeadline){[weak link] in link?.fail(.timedOut)}
        if !stallConnects {scheduler.enqueue{[weak self,weak link] in if let self,let link {self.complete(link,endpoint,key)}}}
        return link
    }
    /// Connections made while true wait as denied until `grantAccess()`.
    public var deniesAccess=false
    private var denied:[(link:NetworkMemoryLink,endpoint:NetworkEndpoint,key:NetworkAccessKey)]=[]
    /// Access is granted: every waiting connection's deadline starts afresh and it goes on by itself.
    public func grantAccess(){
        deniesAccess=false;let waiting=denied;denied=[]
        for (link,endpoint,key) in waiting where link.open {
            link.deadline=scheduler.schedule(at:scheduler.now+limits.connectDeadline){[weak link] in link?.fail(.timedOut)}
            if !stallConnects {scheduler.enqueue{[weak self,weak link] in if let self,let link {self.complete(link,endpoint,key)}}}
        }
    }
    private func complete(_ link:NetworkMemoryLink,_ endpoint:NetworkEndpoint,_ key:NetworkAccessKey){
        guard link.open,link.pipe==nil else{return}
        guard let name=endpoint.value as? String,let listener=listeners[name] else{link.fail(.unreachable);return}
        let hosting=listener.hosting,role=listener.role
        guard hosting.configuration.key(role)==key else{link.fail(.handshakeFailed);return}
        let pipe=NetworkMemoryPipe(connection:NetworkTransportConnection(number:nextConnection),hosting:hosting,link:link);nextConnection+=1
        hosting.pipes[pipe.connection]=pipe;link.pipe=pipe;link.deadline?.cancel()
        hosting.deliver(.accepted(pipe.connection,role))
        // Ready a step later, so the host holds the connection before the first message arrives.
        scheduler.enqueue{[weak link] in link?.deliver(.ready)}
    }
    fileprivate func removeListeners(of hosting:NetworkMemoryHosting){listeners=listeners.filter{$0.value.hosting !== hosting}}
    // MARK: Faults
    /// The link drops. Either side may not hear of it (`host` or `link` false): its view lags, as on a real network.
    /// Nothing crosses the connection afterwards; a side that has not heard still sees its sends complete.
    public func cut(_ connection:NetworkTransportConnection,host:Bool=true,link:Bool=true){
        guard let pipe=pipe(connection) else{return}
        pipe.severed=true
        if host {scheduler.enqueue{[weak pipe] in pipe?.hostClosed()}}
        if link {scheduler.enqueue{[weak pipe] in pipe?.link?.deliver(.closed(.lost))}}
    }
    /// The peer stops reading: the host's sends to it never complete, and the bytes stay counted.
    public func stall(_ connection:NetworkTransportConnection){pipe(connection)?.stalledToLink=true}
    /// Delivers a host event no matter what, as a transport racing a close would: the runner must drop it.
    public func deliverLate(_ event:NetworkHostingEvent,to hosting:NetworkMemoryHosting){scheduler.enqueue{hosting.events(event)}}
    /// Delivers a link event no matter what, as a transport racing a close would: the runner must drop it.
    public func deliverLate(_ event:NetworkLinkEvent,to link:NetworkMemoryLink){scheduler.enqueue{link.events(event)}}
    private func pipe(_ connection:NetworkTransportConnection)->NetworkMemoryPipe? {
        for hosting in hostings {if let pipe=hosting.pipes[connection] {return pipe}}
        return links.lazy.compactMap(\.pipe).first{$0.connection==connection}
    }
}
/// One connection between a hosting and a link.
final class NetworkMemoryPipe {
    let connection:NetworkTransportConnection
    weak var hosting:NetworkMemoryHosting?
    weak var link:NetworkMemoryLink?
    /// The host side still has the connection: it takes sends and hears events.
    var hostOpen=true
    var severed=false,stalledToLink=false
    var hostSending=false,linkSending=false
    var stalledBytes=0
    init(connection:NetworkTransportConnection,hosting:NetworkMemoryHosting,link:NetworkMemoryLink){self.connection=connection;self.hosting=hosting;self.link=link}
    var crosses:Bool {!severed}
    /// The host hears that the connection closed: its last event.
    func hostClosed(){
        guard hostOpen,let hosting else{return}
        hostOpen=false;stalledBytes=0;hosting.pipes[connection]=nil
        hosting.deliver(.closed(connection))
    }
}
public final class NetworkMemoryHosting:NetworkHosting {
    public let configuration:NetworkHostingConfiguration
    fileprivate let events:(NetworkHostingEvent)->Void
    private unowned let transport:NetworkMemoryTransport
    fileprivate var pipes:[NetworkTransportConnection:NetworkMemoryPipe]=[:]
    public private(set) var listening=true,stopped=false
    fileprivate init(transport:NetworkMemoryTransport,configuration:NetworkHostingConfiguration,events:@escaping (NetworkHostingEvent)->Void){self.transport=transport;self.configuration=configuration;self.events=events}
    private var scheduler:any NetworkScheduler {transport.scheduler}
    public var connections:[NetworkTransportConnection] {pipes.keys.sorted{$0.number<$1.number}}
    public var bufferedBytes:Int {pipes.values.reduce(0){$0+$1.stalledBytes}}
    fileprivate func deliver(_ event:NetworkHostingEvent){if !stopped {events(event)}}
    public func send(_ message:Data,on connection:NetworkTransportConnection){
        guard !stopped,let pipe=pipes[connection],pipe.hostOpen else{return}
        precondition(!pipe.hostSending,"One send at a time per connection.")
        pipe.hostSending=true
        if pipe.stalledToLink && pipe.crosses {pipe.stalledBytes+=message.count;return}
        scheduler.enqueue{[weak pipe] in if let pipe,pipe.crosses {pipe.link?.receive(message,from:pipe)}}
        scheduler.enqueue{[weak self,weak pipe] in
            guard let self,let pipe,pipe.hostOpen else{return}
            pipe.hostSending=false;self.deliver(.sent(pipe.connection))
        }
    }
    public func close(_ connection:NetworkTransportConnection,farewell:Data?){
        guard let pipe=pipes.removeValue(forKey:connection),pipe.hostOpen else{return}
        pipe.hostOpen=false
        let delivered=pipe.crosses && !pipe.stalledToLink;pipe.stalledBytes=0
        if let farewell,delivered {scheduler.enqueue{[weak pipe] in if let pipe,pipe.crosses {pipe.link?.receive(farewell,from:pipe)}}}
        if pipe.crosses {scheduler.enqueue{[weak pipe] in pipe?.link?.deliver(.closed(.lost))}}
    }
    public func stopListening(){guard listening else{return};listening=false;transport.removeListeners(of:self)}
    public func shutdown(){
        guard !stopped else{return}
        stopListening()
        for connection in connections {close(connection,farewell:nil)}
        stopped=true
    }
}
public final class NetworkMemoryLink:NetworkLink {
    private unowned let transport:NetworkMemoryTransport
    public let key:NetworkAccessKey
    fileprivate let events:(NetworkLinkEvent)->Void
    fileprivate var pipe:NetworkMemoryPipe?
    fileprivate var deadline:NetworkScheduledWork?
    /// Until a local close, or the closed event.
    public private(set) var open=true
    fileprivate init(transport:NetworkMemoryTransport,key:NetworkAccessKey,events:@escaping (NetworkLinkEvent)->Void){self.transport=transport;self.key=key;self.events=events}
    public var connection:NetworkTransportConnection? {pipe?.connection}
    public var bufferedBytes:Int {0}
    fileprivate func deliver(_ event:NetworkLinkEvent){
        guard open else{return}
        if case .closed=event {open=false;deadline?.cancel()}
        events(event)
    }
    fileprivate func receive(_ message:Data,from pipe:NetworkMemoryPipe){
        guard open else{return}
        transport.record(pipe.connection,toHost:false,message);deliver(.received(message))
    }
    fileprivate func fail(_ failure:NetworkLinkFailure){guard open,pipe==nil else{return};deliver(.closed(failure))}
    public func send(_ message:Data){
        guard open,let pipe else{return}
        precondition(!pipe.linkSending,"One send at a time per connection.")
        pipe.linkSending=true
        let lost=transport.losesToHost(message)
        transport.scheduler.enqueue{[weak transport=self.transport,weak pipe] in
            guard let transport,let pipe,pipe.crosses,pipe.hostOpen,!lost,let hosting=pipe.hosting,!hosting.stopped else{return}
            transport.record(pipe.connection,toHost:true,message);hosting.deliver(.received(pipe.connection,message))
        }
        transport.scheduler.enqueue{[weak self,weak pipe] in guard let self,let pipe,self.open else{return};pipe.linkSending=false;self.deliver(.sent)}
    }
    public func close(farewell:Data?){
        guard open else{return}
        open=false;deadline?.cancel()
        guard let pipe else{return}
        if let farewell {transport.scheduler.enqueue{[weak transport=self.transport,weak pipe] in
            guard let transport,let pipe,pipe.crosses,pipe.hostOpen,let hosting=pipe.hosting,!hosting.stopped else{return}
            transport.record(pipe.connection,toHost:true,farewell);hosting.deliver(.received(pipe.connection,farewell))
        }}
        if pipe.crosses {transport.scheduler.enqueue{[weak pipe] in pipe?.hostClosed()}}
    }
}
