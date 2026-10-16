import Foundation
/// At most `limit` events in any window of `window` (D7: 20 messages a second from each peer). Remembers only the last
/// `limit` instants, so its memory is fixed.
public struct NetworkRateWindow {
    public let limit:Int,window:Duration
    private var instants:[NetworkInstant]=[],oldest=0
    public init(limit:Int=NetworkLimits.inboundMessagesPerWindow,window:Duration=NetworkLimits.inboundWindow){precondition(limit>0);self.limit=limit;self.window=window}
    /// Records the event and answers whether it is within the limit. A refused event is not recorded.
    public mutating func admit(at now:NetworkInstant)->Bool {
        if instants.count<limit {instants.append(now);return true}
        guard now-instants[oldest]>=window else{return false}
        instants[oldest]=now;oldest=(oldest+1)%limit;return true
    }
}
/// A fixed number of slots (D7: 4 TLS handshakes in progress per listener). An unbalanced release is a bookkeeping
/// bug that would silently lift the bound, so it traps.
public struct NetworkSlots {
    public let limit:Int
    public private(set) var used=0
    public init(limit:Int=NetworkLimits.handshakesPerListener){self.limit=limit}
    public mutating func acquire()->Bool {guard used<limit else{return false};used+=1;return true}
    public mutating func release(){precondition(used>0,"A network slot was released twice.");used-=1}
}
/// Failed TLS handshakes per remote address (D7: 5 a minute). At most `maximumAddresses` addresses are tracked, the
/// stalest forgotten first, so a flood of sources cannot grow it without bound.
public struct NetworkHandshakeFailures {
    public let limit:Int,window:Duration,maximumAddresses:Int
    private var failures:[String:[NetworkInstant]]=[:]
    public init(limit:Int=NetworkLimits.failedHandshakesPerAddress,window:Duration=NetworkLimits.failedHandshakeWindow,maximumAddresses:Int=256){self.limit=limit;self.window=window;self.maximumAddresses=maximumAddresses}
    private func recent(_ address:String,at now:NetworkInstant)->[NetworkInstant] {(failures[address] ?? []).filter{now-$0<window}}
    /// False once the address has failed `limit` times within the window: refuse its next connection before TLS.
    public func allows(_ address:String,at now:NetworkInstant)->Bool {recent(address,at:now).count<limit}
    public mutating func recordFailure(from address:String,at now:NetworkInstant){
        failures[address]=Array((recent(address,at:now)+[now]).suffix(limit))
        if failures.count>maximumAddresses {
            failures=failures.filter{!$0.value.isEmpty && now-$0.value.last!<window}
            while failures.count>maximumAddresses,let stalest=failures.min(by:{$0.value.last! < $1.value.last!})?.key {failures[stalest]=nil}
        }
    }
    public var trackedAddresses:Int {failures.count}
}
