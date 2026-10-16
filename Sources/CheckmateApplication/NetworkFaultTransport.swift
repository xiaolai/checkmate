import CheckmateDomain
import Foundation
/// The automation-only disconnect hook (LAN-play plan, Verification: `network-ui` and `network-lan`). It wraps the real
/// transport and, on `drop(refusingFor:)`, closes this Mac's outbound connections as a lost link would and refuses new
/// ones for a while, so a gate can cut a guest's connection without touching the machine's network or its SSH control
/// channel (N13). `stall(for:)` holds this Mac's outgoing messages for a while instead, as a slow network would, so a
/// gate can see a move pending on a loopback link that answers in milliseconds. Hosting passes straight through. Every
/// call and event runs on the transport's scheduler.
public final class NetworkFaultTransport:NetworkTransport {
    private let base:any NetworkTransport,scheduler:any NetworkScheduler
    private var links:[ObjectIdentifier:FaultLink]=[:]
    private var refusingUntil:NetworkInstant?,stalledUntil:NetworkInstant?
    /// How many drops were applied, for the gate's evidence.
    public private(set) var drops=0
    public init(wrapping base:any NetworkTransport,scheduler:any NetworkScheduler){self.base=base;self.scheduler=scheduler}
    public func startHosting(_ configuration:NetworkHostingConfiguration,events:@escaping (NetworkHostingEvent)->Void)throws -> any NetworkHosting {try base.startHosting(configuration,events:events)}
    public func connect(to endpoint:NetworkEndpoint,key:NetworkAccessKey,events:@escaping (NetworkLinkEvent)->Void)->any NetworkLink {
        let link=FaultLink(events:events,scheduler:scheduler,stalledUntil:{[weak self] in self?.stalledUntil})
        if let until=refusingUntil,scheduler.now<until {
            // Refused before TLS, as an unreachable host is; the event comes on the queue, never during this call.
            scheduler.enqueue{link.finish(.unreachable)}
            return link
        }
        links[ObjectIdentifier(link)]=link
        link.inner=base.connect(to:endpoint,key:key){[weak self,weak link] event in
            guard let link,!link.over else{return}
            if case .closed=event{self?.links[ObjectIdentifier(link)]=nil}
            link.events(event)
        }
        link.forget={[weak self,weak link] in if let link{self?.links[ObjectIdentifier(link)]=nil}}
        return link
    }
    /// Holds every outbound message sent from now until `duration` has passed; each then goes in order.
    public func stall(for duration:Duration){scheduler.enqueue{[self] in stallsApplied+=1;stalledUntil=scheduler.now+duration}}
    /// How many stalls were applied, for the gate's evidence.
    public private(set) var stallsApplied=0
    /// Cuts every outbound connection now and refuses new ones until `duration` has passed.
    public func drop(refusingFor duration:Duration){
        scheduler.enqueue{[self] in
            drops+=1;refusingUntil=scheduler.now+duration
            let cut=links.values;links=[:]
            for link in cut {link.inner?.close(farewell:nil);link.finish(.lost)}
        }
    }
}
/// One outbound connection as the runner sees it: the real link, until the hook cuts it.
private final class FaultLink:NetworkLink {
    let events:(NetworkLinkEvent)->Void,scheduler:any NetworkScheduler,stalledUntil:()->NetworkInstant?
    var inner:(any NetworkLink)?,forget:()->Void={},over=false
    init(events:@escaping (NetworkLinkEvent)->Void,scheduler:any NetworkScheduler,stalledUntil:@escaping ()->NetworkInstant?){self.events=events;self.scheduler=scheduler;self.stalledUntil=stalledUntil}
    func finish(_ failure:NetworkLinkFailure){guard !over else{return};over=true;events(.closed(failure))}
    /// The runner sends one message at a time and waits for its `sent`, so holding a send holds everything after it.
    func send(_ message:Data){
        guard let until=stalledUntil(),scheduler.now<until else{inner?.send(message);return}
        _ = scheduler.schedule(at:until){[weak self] in guard let self,!self.over else{return};self.inner?.send(message)}
    }
    func close(farewell:Data?){over=true;forget();inner?.close(farewell:farewell)}
    var bufferedBytes:Int {inner?.bufferedBytes ?? 0}
}
